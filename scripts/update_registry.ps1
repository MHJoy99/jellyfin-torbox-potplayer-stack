<#
.SYNOPSIS
    Updates the potplayer:// protocol handler to use the robust wrapper launcher.
.DESCRIPTION
    Points HKEY_CLASSES_ROOT\potplayer at the wrapper launcher script so playback
    URLs are handled consistently. Safe to re-run: matching values are left alone.

    InstallOps hardening (10 features):
      1. Idempotent re-runs (current value compared; upgrade in place).
      2. Admin-rights check with friendly message + self-elevate offer.
      3. Post-write verification (values read back; scheduled-task helper
         included for orchestrated scenarios).
      4. Rollback on failure (re-imports .reg backups).
      5. -Uninstall switch (removes the potplayer key, restorable from .reg).
      6. Registry backup (.reg export) before any write.
      7. rclone.conf ACL helper included; skipped with a note (no rclone.conf).
      8. Version stamp file after successful install.
      9. Preflight checks (pwsh version, launcher path).
     10. Called by install-all.ps1 in dependency order (before lock_registry).

    Never hardcodes secrets: all paths are parameters, no tokens or passwords.
#>

param (
    [string]$LauncherScript = 'F:\Jellyfin\potplayer-launcher.ps1',
    [string]$VersionDir = "",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'update_registry'
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
    # F3: scheduled-task existence verification (for orchestrated/task scenarios;
    # this registry installer creates no scheduled task itself).
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { throw "Scheduled task '$TaskName' was not found after creation." }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ("[verify] Task '{0}' state={1} lastRun={2} result={3}" -f $t.TaskName, $t.State, $info.LastRunTime, $info.LastTaskResult) -ForegroundColor Green
    return $t
}

function Lock-RcloneConfAcl {
    param([string]$Path)
    # F7 helper (N/A here: this installer never touches rclone.conf).
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
#endregion

# F2: Admin-rights check with friendly message + self-elevate offer.
if (-not (Test-IsAdmin)) {
    Request-Elevation -Reason 'Updating the protocol handler writes to HKEY_CLASSES_ROOT.'
}

if ($Uninstall) {
    # F5: Uninstall path (backup first so removal is recoverable from .reg).
    [void](Backup-RegistryKey -RegPath 'HKCR\potplayer')
    $key = 'Registry::HKEY_CLASSES_ROOT\potplayer'
    if (Test-Path -LiteralPath $key) {
        Remove-Item -LiteralPath $key -Recurse -Force
        Write-Host "[remove] Deleted registry key $key" -ForegroundColor Yellow
    } else {
        Write-Host "[*] Registry key $key already absent." -ForegroundColor Gray
    }
    Remove-VersionStamp -Name $ScriptName
    Write-Host "[SUCCESS] potplayer handler (wrapper) uninstalled." -ForegroundColor Green
    exit 0
}

try {
    # F9: preflight (pwsh version, launcher path must exist).
    if ($PSVersionTable.PSVersion -lt [version]'7.0') {
        throw ("pwsh 7.0+ is required (found {0}). Install PowerShell 7 and re-run." -f $PSVersionTable.PSVersion)
    }
    Write-Host ("[+] Preflight: pwsh {0} OK" -f $PSVersionTable.PSVersion) -ForegroundColor Green
    if (-not (Test-Path -LiteralPath $LauncherScript -PathType Leaf)) {
        throw "Launcher script not found: $LauncherScript (pass -LauncherScript with the correct path)."
    }
    Write-Host "[+] Preflight: launcher script exists ($LauncherScript)" -ForegroundColor Green

    # Setup robust launcher
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $LauncherScript + '" "%1"'

    # F6: registry backup (.reg export) before any write.
    [void](Backup-RegistryKey -RegPath 'HKCR\potplayer')

    # F1: idempotency — skip writes when the handler already matches.
    $current = (Get-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Name '(Default)' -ErrorAction SilentlyContinue).'(Default)'
    if ($current -ceq $cmd) {
        Write-Host "[=] Registry handler already up to date; nothing to change." -ForegroundColor Gray
    } else {
        New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Force | Out-Null
        Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Name '(Default)' -Value 'URL:PotPlayer Protocol'
        Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Name 'URL Protocol' -Value ''

        New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Force | Out-Null
        Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Name '(Default)' -Value $cmd
        Write-Host "Registry updated to use wrapper script." -ForegroundColor Green
    }

    # F3: verification — read the handler value back.
    $verified = (Get-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -ErrorAction Stop).'(Default)'
    if ($verified -cne $cmd) { throw 'Verification failed: handler value does not match the expected command.' }
    Write-Host "[verify] potplayer handler = $verified" -ForegroundColor Green

    # F8: version stamp after successful install.
    [void](Write-VersionStamp -Name $ScriptName -Version $ScriptVersion -Extra @{ launcher = $LauncherScript })
} catch {
    Write-Host ("[ERROR] Registry update failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    # F4: rollback on failure (restore *.bak files + re-import .reg backups).
    Restore-Backups
    Restore-RegistryBackups
    exit 1
}
