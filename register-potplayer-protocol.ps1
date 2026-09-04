<#
.SYNOPSIS
    Registers custom potplayer:// and potplayer64:// protocol handlers in Windows Registry.
.DESCRIPTION
    Ensures PotPlayer is launched cleanly when custom URI schemes are invoked from Jellyfin Web,
    browsers, or external scrobblers/trackers. Requires Administrator privileges.

    InstallOps hardening (10 features):
      1. Idempotent re-runs (matching handler values are left in place / updated).
      2. Admin-rights check with friendly message + self-elevate offer.
      3. Post-creation verification (registry values read back; scheduled-task
         verification helper included for orchestrated scenarios).
      4. Rollback on failure (re-imports .reg backups).
      5. -Uninstall switch (removes potplayer/potplayer64 protocol keys).
      6. Registry backup (.reg export) before any write.
      7. rclone.conf ACL helper included; skipped with a note (no rclone.conf here).
      8. Version stamp file after successful install.
      9. Preflight checks (pwsh version, PotPlayer/launcher paths).
     10. Called by install-all.ps1 in dependency order.

    Never hardcodes secrets: all paths are parameters, no tokens or passwords.
#>

param (
    [string]$PotPlayerExe = "",
    [string]$VersionDir = "",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'register-potplayer-protocol'
$ScriptVersion = '1.0.0'

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
$script:RegBackupDir = Join-Path $script:VersionDir 'registry-backups'

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
    Write-Host "    Writing to HKEY_CLASSES_ROOT requires an elevated (Run as Administrator) pwsh session." -ForegroundColor Yellow
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
    param([string]$RegPath)
    # F6: .reg export before any registry write.
    New-Item -ItemType Directory -Force -Path $script:RegBackupDir | Out-Null
    $leaf = ($RegPath -split '\\')[-1]
    $out = Join-Path $script:RegBackupDir ("{0}-{1}.reg" -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    # F7: ACL lockdown helper (N/A here: this installer never touches rclone.conf).
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "[*] No rclone.conf managed by this installer; skipping ACL lockdown." -ForegroundColor Gray
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

function Ensure-HkcrDrive {
    if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script | Out-Null
    }
}
#endregion

# F2: Admin-rights check with friendly message + self-elevate offer.
if (-not (Test-IsAdmin)) {
    Request-Elevation -Reason 'Registering a protocol handler writes to HKEY_CLASSES_ROOT.'
}

if ($Uninstall) {
    # F5: Uninstall path (registry backup first so removal is recoverable).
    Ensure-HkcrDrive
    [void](Backup-RegistryKey -RegPath 'HKCR\potplayer')
    [void](Backup-RegistryKey -RegPath 'HKCR\potplayer64')
    foreach ($proto in @('potplayer', 'potplayer64')) {
        $key = "HKCR:\$proto"
        if (Test-Path -LiteralPath $key) {
            Remove-Item -LiteralPath $key -Recurse -Force
            Write-Host "[remove] Deleted protocol key $key" -ForegroundColor Yellow
        } else {
            Write-Host "[*] Protocol key $key already absent." -ForegroundColor Gray
        }
    }
    Remove-VersionStamp -Name $ScriptName
    Write-Host "[SUCCESS] potplayer:// protocol handlers uninstalled." -ForegroundColor Green
    exit 0
}

try {
    # F9: preflight (pwsh version; PotPlayer path resolution happens below).
    if ($PSVersionTable.PSVersion -lt [version]'7.0') {
        throw ("pwsh 7.0+ is required (found {0}). Install PowerShell 7 and re-run." -f $PSVersionTable.PSVersion)
    }
    Write-Host ("[+] Preflight: pwsh {0} OK" -f $PSVersionTable.PSVersion) -ForegroundColor Green

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   PotPlayer Custom URI Protocol Registration Utility      " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Ensure-HkcrDrive

    # 1. Locate PotPlayer Executable
    $potentialPaths = @(
        "C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe",
        "C:\Program Files\DAUM\PotPlayer\PotPlayer64.exe",
        "C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe",
        "C:\Program Files (x86)\DAUM\PotPlayer\PotPlayer.exe",
        "E:\PotPlayer\PotPlayerMini64.exe",
        "E:\MediaServer\apps\PotPlayer\PotPlayerMini64.exe"
    )

    $potPlayerExe = $null
    if (-not [string]::IsNullOrWhiteSpace($PotPlayerExe) -and (Test-Path -LiteralPath $PotPlayerExe)) {
        $potPlayerExe = $PotPlayerExe
    } else {
        foreach ($path in $potentialPaths) {
            if (Test-Path -Path $path) {
                $potPlayerExe = $path
                break
            }
        }
    }

    if (-not $potPlayerExe) {
        # Check registry App Paths
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini64.exe"
        if (Test-Path $regPath) {
            $potPlayerExe = (Get-ItemProperty -Path $regPath).'(default)'
        }
    }

    if (-not $potPlayerExe -or -not (Test-Path $potPlayerExe)) {
        Write-Host "[!] Could not automatically detect PotPlayer executable." -ForegroundColor Yellow
        $potPlayerExe = Read-Host "Please enter the full path to PotPlayerMini64.exe (e.g. C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe)"
        if (-not (Test-Path $potPlayerExe)) {
            throw "Provided path does not exist: $potPlayerExe"
        }
    }

    Write-Host "[+] Found PotPlayer executable at: $potPlayerExe" -ForegroundColor Green

    # F6: registry backup (.reg export) before any write.
    [void](Backup-RegistryKey -RegPath 'HKCR\potplayer')
    [void](Backup-RegistryKey -RegPath 'HKCR\potplayer64')

    # 2. Define Protocols to Register
    $protocols = @("potplayer", "potplayer64")

    foreach ($proto in $protocols) {
        $rootKey = "HKCR:\$proto"
        # F1: idempotency — compare current value before writing.
        $desired = "`"$potPlayerExe`" `"%1`""
        $current = (Get-ItemProperty -Path "$rootKey\shell\open\command" -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
        if ($current -ceq $desired) {
            Write-Host "[=] Protocol '${proto}://' already up to date; leaving in place." -ForegroundColor Gray
            continue
        }
        Write-Host "[*] Registering '${proto}://' protocol handler..." -ForegroundColor Cyan

        # Create / Overwrite root protocol key
        if (-not (Test-Path $rootKey)) {
            New-Item -Path $rootKey -Force | Out-Null
        }
        Set-ItemProperty -Path $rootKey -Name "(Default)" -Value "URL:PotPlayer Protocol" -Force
        Set-ItemProperty -Path $rootKey -Name "URL Protocol" -Value "" -Force

        # DefaultIcon
        $iconKey = "$rootKey\DefaultIcon"
        if (-not (Test-Path $iconKey)) {
            New-Item -Path $iconKey -Force | Out-Null
        }
        Set-ItemProperty -Path $iconKey -Name "(Default)" -Value "`"$potPlayerExe`",0" -Force

        # shell\open\command
        $cmdKey = "$rootKey\shell\open\command"
        if (-not (Test-Path $cmdKey)) {
            New-Item -Path $cmdKey -Force | Out-Null
        }
        # Windows command line syntax to pass %1 as parameter
        $commandValue = "`"$potPlayerExe`" `"%1`""
        Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value $commandValue -Force

        Write-Host "[+] Successfully registered protocol '${proto}://'" -ForegroundColor Green
    }

    # F3: verification — read every protocol command back (no scheduled task is
    # created by this installer, so Confirm-ScheduledTaskExists stays available
    # for orchestrated/task scenarios only).
    Write-Host ""
    Write-Host "[+] Verification:" -ForegroundColor Cyan
    foreach ($proto in $protocols) {
        $cmd = (Get-ItemProperty -Path "HKCR:\$proto\shell\open\command" -ErrorAction Stop).'(default)'
        if ([string]::IsNullOrWhiteSpace($cmd)) { throw "Verification failed: '$proto' command value is empty." }
        Write-Host "    $proto -> $cmd" -ForegroundColor White
    }

    # F8: version stamp after successful install.
    [void](Write-VersionStamp -Name $ScriptName -Version $ScriptVersion -Extra @{ exe = $potPlayerExe })

    Write-Host ""
    Write-Host "[SUCCESS] Protocol registration completed successfully." -ForegroundColor Green
} catch {
    Write-Host ("[ERROR] Protocol registration failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    # F4: rollback on failure (restore *.bak files + re-import .reg backups).
    Restore-Backups
    Restore-RegistryBackups
    exit 1
}
