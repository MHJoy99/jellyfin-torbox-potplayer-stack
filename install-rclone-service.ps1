<#
.SYNOPSIS
    Installs and configures Rclone Mount as a persistent Windows Service via NSSM.
.DESCRIPTION
    Sets up high-performance VFS cache parameters, ensures WinFsp integration,
    creates the service with auto-restart, and performs an immediate mount health check.

    InstallOps hardening (10 features):
      1. Idempotent re-runs (existing service is upgraded in place).
      2. Admin-rights check with friendly message + self-elevate offer.
      3. Post-creation verification (service state + NSSM parameters; scheduled-task
         verification helper included for orchestrated/task scenarios).
      4. Rollback on failure (restores *.bak files, removes partial service).
      5. -Uninstall switch (stops/removes the service and version stamp).
      6. Registry backup helper (.reg export) included; skipped with a note when
         no registry writes are required.
      7. rclone.conf ACL lockdown to Administrators + owner.
      8. Version stamp file after successful install.
      9. Preflight checks (pwsh version, paths exist, RC port free).
     10. Called by install-all.ps1 in dependency order.

    Never hardcodes secrets: all paths/ports are parameters, no tokens or passwords.
#>

param (
    [string]$ServiceName = "RcloneMount",
    [string]$RemoteName = "gdrive:",
    [string]$MountDrive = "X:",
    [string]$RcloneExePath = "C:\rclone\rclone.exe",
    [string]$ConfigPath = "E:\MediaServer\config\rclone.conf",
    [string]$CacheDir = "E:\MediaServer\cache\rclone_vfs",
    [string]$LogFile = "E:\MediaServer\logs\rclone-mount.log",
    [string]$NssmExePath = "C:\nssm\nssm.exe",
    [string]$VersionDir = "",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'install-rclone-service'
$ScriptVersion = '1.0.0'
$RcPort = 5572

#region InstallOps shared helpers
$script:BackupLedger = New-Object System.Collections.Generic.List[string]
$script:RegBackups = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($VersionDir)) {
    $rootHint = $PSScriptRoot
    if ((Split-Path $rootHint -Leaf) -ieq 'scripts') { $rootHint = Split-Path $rootHint -Parent }
    $script:VersionDir = Join-Path $rootHint '.install-versions'
} else {
    $script:VersionDir = $VersionDir
}

# Snapshot of bound parameters so elevation can forward them (incl. -Uninstall).
$script:ElevateArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [switch]) { if ($v.IsPresent) { $script:ElevateArgs += "-$k" } }
    elseif ($null -ne $v -and "$v" -ne '') { $script:ElevateArgs += "-$k"; $script:ElevateArgs += "$v" }
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsPrincipalRole]::Administrator)
}

function Test-Interactive {
    try {
        return [Environment]::UserInteractive -and (-not [Console]::IsInputRedirected)
    } catch { return $false }
}

function Request-Elevation {
    param([string]$Reason)
    Write-Host "[!] Administrator rights required. $Reason" -ForegroundColor Yellow
    Write-Host "    Please re-run this script from an elevated (Run as Administrator) pwsh session." -ForegroundColor Yellow
    if (Test-Interactive) {
        $answer = Read-Host '    Re-launch automatically as Administrator now? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($answer) -or ($answer -match '^(?i)y(es)?$')) {
            $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if (-not $pwsh) { $pwsh = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
            Start-Process -FilePath $pwsh -ArgumentList $script:ElevateArgs -Verb RunAs
            exit 0
        }
    }
    throw 'Administrator rights are required. Re-run as Administrator.'
}

function Test-PortFree {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(500)
        $connected = $ok -and $client.Connected
        $client.Close()
        return (-not $connected)
    } catch { return $true }
}

function Invoke-Preflight {
    # F9: pwsh version check.
    if ($PSVersionTable.PSVersion -lt [version]'7.0') {
        throw ("pwsh 7.0+ is required (found {0}). Install PowerShell 7 and re-run." -f $PSVersionTable.PSVersion)
    }
    Write-Host ("[+] Preflight: pwsh {0} OK" -f $PSVersionTable.PSVersion) -ForegroundColor Green
    # F9: required parent paths must exist or be creatable.
    foreach ($p in @((Split-Path $ConfigPath -Parent), (Split-Path $LogFile -Parent))) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Write-Host "[+] Preflight: created directory $p" -ForegroundColor Gray
        }
    }
    # F9: RC port should be free unless we are upgrading an existing install.
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ((Test-PortFree -Port $RcPort)) {
        Write-Host "[+] Preflight: TCP port $RcPort is free" -ForegroundColor Green
    } elseif ($existing) {
        Write-Host "[*] Preflight: port $RcPort in use but service '$ServiceName' exists (upgrade in place)." -ForegroundColor Yellow
    } else {
        Write-Host "[!] Preflight: TCP port $RcPort is already in use; install may fail if another RC endpoint owns it." -ForegroundColor Yellow
    }
}

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $bak = "$Path.bak"
    if (Test-Path -LiteralPath $bak) {
        Move-Item -LiteralPath $bak -Destination ("$bak.{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    }
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    [void]$script:BackupLedger.Add("$Path|$bak")
    Write-Host "[backup] $Path -> $bak" -ForegroundColor Gray
    return $bak
}

function Restore-Backups {
    foreach ($entry in $script:BackupLedger) {
        $parts = $entry -split '\|', 2
        if (($parts.Count -eq 2) -and (Test-Path -LiteralPath $parts[1])) {
            Copy-Item -LiteralPath $parts[1] -Destination $parts[0] -Force
            Write-Host ("[rollback] Restored {0} from {1}" -f $parts[0], $parts[1]) -ForegroundColor Yellow
        }
    }
}

function Backup-RegistryKey {
    param([string]$RegPath, [string]$BackupDir)
    # F6: .reg export before any registry write. Skipped with note when N/A.
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $leaf = ($RegPath -split '\\')[-1]
    $out = Join-Path $BackupDir ("{0}-{1}.reg" -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $p = Start-Process -FilePath "$env:WINDIR\System32\reg.exe" `
        -ArgumentList 'export', ('"{0}"' -f $RegPath), ('"{0}"' -f $out), '/y' `
        -Wait -PassThru -NoNewWindow
    if (($p.ExitCode -eq 0) -and (Test-Path -LiteralPath $out)) {
        [void]$script:RegBackups.Add($out)
        Write-Host "[backup] Registry $RegPath -> $out" -ForegroundColor Gray
        return $out
    }
    Write-Host "[*] Registry backup of $RegPath unavailable (key may not exist yet; fresh install)." -ForegroundColor Gray
    return $null
}

function Restore-RegistryBackups {
    foreach ($f in $script:RegBackups) {
        if (Test-Path -LiteralPath $f) {
            Start-Process -FilePath "$env:WINDIR\System32\reg.exe" `
                -ArgumentList 'import', ('"{0}"' -f $f) -Wait -NoNewWindow | Out-Null
            Write-Host "[rollback] Re-imported registry backup $f" -ForegroundColor Yellow
        }
    }
}

function Confirm-ScheduledTaskExists {
    param([string]$TaskName)
    # F3: scheduled-task existence verification after creation.
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { throw "Scheduled task '$TaskName' was not found after creation." }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ("[verify] Task '{0}' state={1} lastRun={2} result={3}" -f $t.TaskName, $t.State, $info.LastRunTime, $info.LastTaskResult) -ForegroundColor Green
    return $t
}

function Lock-RcloneConfAcl {
    param([string]$Path)
    # F7: ACL lockdown to Administrators + owner only.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "[*] rclone.conf not found at $Path; skipping ACL lockdown." -ForegroundColor Gray
        return $false
    }
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    & "$env:WINDIR\System32\icacls.exe" $Path /inheritance:r | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /inheritance:r failed on $Path (exit $LASTEXITCODE)." }
    & "$env:WINDIR\System32\icacls.exe" $Path /grant:r 'Administrators:F' ('{0}:F' -f $user) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /grant failed on $Path (exit $LASTEXITCODE)." }
    Write-Host "[+] ACL lockdown applied to $Path (Administrators + $user only)" -ForegroundColor Green
    return $true
}

function Write-VersionStamp {
    param([string]$Name, [string]$Version, [hashtable]$Extra)
    New-Item -ItemType Directory -Force -Path $script:VersionDir | Out-Null
    $obj = [ordered]@{
        name        = $Name
        version     = $Version
        installedAt = (Get-Date).ToString('o')
        user        = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        computer    = $env:COMPUTERNAME
        status      = 'installed'
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }
    $out = Join-Path $script:VersionDir ("$Name.version.json")
    ($obj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $out -Encoding UTF8
    Write-Host "[+] Version stamp written: $out" -ForegroundColor Green
    return $out
}

function Remove-VersionStamp {
    param([string]$Name)
    $out = Join-Path $script:VersionDir ("$Name.version.json")
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
}
#endregion

# F2: Admin-rights check with friendly message + self-elevate offer.
if (-not (Test-IsAdmin)) {
    Request-Elevation -Reason 'Installing a Windows service via NSSM requires elevation.'
}

if ($Uninstall) {
    # F5: Uninstall path.
    Write-Host "Removing service '$ServiceName'..." -ForegroundColor Cyan
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($NssmExePath) -and (Test-Path -LiteralPath $NssmExePath)) {
        & $NssmExePath stop $ServiceName 2>$null | Out-Null
        & $NssmExePath remove $ServiceName confirm 2>$null | Out-Null
    }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        & "$env:WINDIR\System32\sc.exe" delete $ServiceName | Out-Null
    }
    Remove-VersionStamp -Name $ScriptName
    Write-Host "[SUCCESS] Service '$ServiceName' uninstalled (config/cache files preserved)." -ForegroundColor Green
    exit 0
}

try {
    # F9: preflight before any change.
    Invoke-Preflight

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "       Rclone Windows Service Installation (NSSM)           " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # F1: idempotency probe (upgrade in place when the service already exists).
    $preExisting = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($preExisting) {
        Write-Host "[*] Existing service '$ServiceName' detected (state=$($preExisting.Status)). Upgrading in place..." -ForegroundColor Yellow
    }

    # 2. Prerequisites Validation
    # A. Ensure directory structures exist
    @((Split-Path $ConfigPath), $CacheDir, (Split-Path $LogFile)) | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_) -and -not (Test-Path $_)) {
            New-Item -ItemType Directory -Path $_ -Force | Out-Null
            Write-Host "[+] Created directory: $_" -ForegroundColor Gray
        }
    }

    # B. Locate rclone.exe
    if (-not (Test-Path $RcloneExePath)) {
        $found = Get-Command rclone.exe -ErrorAction SilentlyContinue
        if ($found) {
            $RcloneExePath = $found.Source
        } elseif (Test-Path "E:\MediaServer\apps\rclone\rclone.exe") {
            $RcloneExePath = "E:\MediaServer\apps\rclone\rclone.exe"
        } else {
            throw "Could not find rclone.exe at '$RcloneExePath' or in system PATH."
        }
    }
    Write-Host "[+] Using Rclone executable: $RcloneExePath" -ForegroundColor Green

    # C. Locate nssm.exe
    if (-not (Test-Path $NssmExePath)) {
        $foundNssm = Get-Command nssm.exe -ErrorAction SilentlyContinue
        if ($foundNssm) {
            $NssmExePath = $foundNssm.Source
        } elseif (Test-Path "E:\MediaServer\apps\nssm\nssm.exe") {
            $NssmExePath = "E:\MediaServer\apps\nssm\nssm.exe"
        } else {
            throw "Could not find nssm.exe. Please install NSSM or specify -NssmExePath."
        }
    }
    Write-Host "[+] Using NSSM executable: $NssmExePath" -ForegroundColor Green

    # F4/F7: back up rclone.conf (*.bak) then lock its ACL before the service consumes it.
    [void](Backup-File -Path $ConfigPath)
    [void](Lock-RcloneConfAcl -Path $ConfigPath)

    # D. Verify WinFsp
    $winfspService = Get-Service -Name "WinFsp.Launcher" -ErrorAction SilentlyContinue
    if (-not $winfspService) {
        Write-Host "[!] WinFsp does not appear to be installed or registered as a service." -ForegroundColor Yellow
        Write-Host "    Rclone mount on Windows requires WinFsp (https://winfsp.dev/)." -ForegroundColor Yellow
    } else {
        Write-Host "[+] WinFsp is detected and ready." -ForegroundColor Green
    }

    # 3. Build Rclone Mount Arguments
    $rcloneArgs = @(
        "mount",
        $RemoteName,
        $MountDrive,
        "--config", "`"$ConfigPath`"",
        "--vfs-cache-mode", "full",
        "--vfs-cache-max-size", "200G",
        "--vfs-cache-max-age", "24h",
        "--vfs-read-chunk-size", "64M",
        "--vfs-read-chunk-size-limit", "2G",
        "--buffer-size", "128M",
        "--dir-cache-time", "72h",
        "--cache-dir", "`"$CacheDir`"",
        "--log-file", "`"$LogFile`"",
        "--log-level", "INFO",
        "--network-mode",
        "--rc",
        "--rc-no-auth",
        "--rc-addr", "127.0.0.1:5572"
    ) -join " "

    Write-Host "[*] Service Arguments: $rcloneArgs" -ForegroundColor Gray

    # 4. Stop and Remove Existing Service if present (upgrade in place)
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[*] Existing service '$ServiceName' found. Stopping and removing..." -ForegroundColor Yellow
        & $NssmExePath stop $ServiceName | Out-Null
        Start-Sleep -Seconds 2
        & $NssmExePath remove $ServiceName confirm | Out-Null
    }

    # 5. Install Service via NSSM
    Write-Host "[*] Creating service '$ServiceName'..." -ForegroundColor Cyan
    & $NssmExePath install $ServiceName $RcloneExePath $rcloneArgs
    if ($LASTEXITCODE -ne 0) { throw "NSSM install failed with exit code $LASTEXITCODE." }
    & $NssmExePath set $ServiceName DisplayName "MediaServer Rclone Cloud Mount ($RemoteName -> $MountDrive)"
    & $NssmExePath set $ServiceName Description "High-performance VFS cached cloud mount for Jellyfin Media Server."
    & $NssmExePath set $ServiceName Start SERVICE_AUTO_START
    & $NssmExePath set $ServiceName AppStdout "$LogFile"
    & $NssmExePath set $ServiceName AppStderr "$LogFile"
    & $NssmExePath set $ServiceName AppRotateFiles 1
    & $NssmExePath set $ServiceName AppRotateOnline 1
    & $NssmExePath set $ServiceName AppRotateBytes 10485760

    # 6. Start Service & Perform Health Check
    Write-Host "[*] Starting service '$ServiceName'..." -ForegroundColor Cyan
    & $NssmExePath start $ServiceName

    Write-Host "[*] Waiting for mount initialization on $MountDrive..." -ForegroundColor Cyan
    $mounted = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Path "$MountDrive\") {
            $mounted = $true
            break
        }
    }

    if ($mounted) {
        Write-Host "[SUCCESS] Rclone mount service is ACTIVE and drive '$MountDrive' is accessible!" -ForegroundColor Green
    } else {
        Write-Host "[WARNING] Mount drive '$MountDrive' is not yet mounted. Checking log file..." -ForegroundColor Yellow
        if (Test-Path $LogFile) {
            Get-Content $LogFile -Tail 10 | Write-Host -ForegroundColor Gray
        }
    }

    # F3: existence + state verification after creation (service equivalent of task verification).
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') { throw "Service '$ServiceName' is in state '$($svc.Status)' (expected Running)." }
    $configured = (& $NssmExePath get $ServiceName AppParameters | Out-String)
    if ($configured -notmatch '127\.0\.0\.1:5572') { throw 'NSSM AppParameters do not contain the expected RC address.' }
    Write-Host ("[verify] Service '{0}' state={1} startType={2}" -f $svc.Name, $svc.Status, $svc.StartType) -ForegroundColor Green

    # F6 note: this installer performs no registry writes, so no .reg backup is required.
    # F8: version stamp after successful install.
    [void](Write-VersionStamp -Name $ScriptName -Version $ScriptVersion -Extra @{
            service = $ServiceName; remote = $RemoteName; mount = $MountDrive
        })

    Get-Service -Name $ServiceName | Select-Object Name, Status, StartType
} catch {
    Write-Host ("[ERROR] Install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    # F4: rollback on failure (restore *.bak files; remove partial service).
    Restore-Backups
    Restore-RegistryBackups
    $partial = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($partial -and -not $preExisting) {
        Write-Host "[rollback] Removing partially created service '$ServiceName'..." -ForegroundColor Yellow
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & $NssmExePath remove $ServiceName confirm 2>$null | Out-Null
    }
    exit 1
}
