<#
.SYNOPSIS
    Installs the quiet local Jellyfin Control Panel (logon scheduled task + shortcut).
.DESCRIPTION
    Registers a per-user AtLogOn scheduled task that starts the control panel via
    wscript (no console window), creates a Start Menu shortcut, starts the task,
    and checks panel health.

    InstallOps hardening (10 features):
      1. Idempotent re-runs (existing task/shortcut upgraded in place).
      2. Admin-rights check with friendly message; elevation is optional here
         because a per-user logon task needs no admin rights (offer only).
      3. Scheduled-task existence verification step after creation.
      4. Rollback on failure (restores *.bak files, unregisters partial task).
      5. -Uninstall switch (removes task, shortcut, version stamp).
      6. Registry backup helper (.reg export) included; skipped with a note
         (this installer performs no registry writes).
      7. rclone.conf ACL helper included; skipped with a note (no rclone.conf).
      8. Version stamp file after successful install.
      9. Preflight checks (pwsh version, panel files exist, health port free).
     10. Called by install-all.ps1 in dependency order (last: top-level UI).

    Never hardcodes secrets: all paths/ports are parameters, no tokens or passwords.
#>

param (
    [string]$BaseDir = 'F:\Jellyfin',
    [string]$TaskName = 'Jellyfin Control Panel',
    [int]$PanelPort = 18080,
    [string]$VersionDir = "",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'install-control-panel'
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
    param([string]$Name)
    # F3: scheduled-task existence verification after creation.
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) { throw "Scheduled task '$Name' was not found after creation." }
    $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
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

function Get-PanelShortcutPath {
    $startMenuPrograms = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    return (Join-Path $startMenuPrograms 'Jellyfin Control Panel.lnk')
}
#endregion

$controlDir = Join-Path $BaseDir 'control-panel'
$startScript = Join-Path $controlDir 'start-control-panel.vbs'
$openScript = Join-Path $controlDir 'open-control-panel.vbs'
$jellyfinExe = Join-Path $BaseDir 'server\jellyfin.exe'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'

# F2: admin-rights check with friendly message. A per-user logon task needs no
# elevation, so we continue without admin but say so explicitly.
if (-not (Test-IsAdmin)) {
    Write-Host "[*] Not running as Administrator. This per-user panel install does not require elevation; continuing." -ForegroundColor Yellow
    Write-Host "    (Re-run from an elevated pwsh session if your Start Menu location requires admin rights.)" -ForegroundColor Gray
} else {
    Write-Host "[+] Running with Administrator rights." -ForegroundColor Green
}

if ($Uninstall) {
    # F5: Uninstall path.
    Write-Host "Uninstalling control panel task '$TaskName'..." -ForegroundColor Cyan
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[remove] Unregistered scheduled task '$TaskName'." -ForegroundColor Yellow
    } else {
        Write-Host "[*] Scheduled task '$TaskName' already absent." -ForegroundColor Gray
    }
    $shortcutPath = Get-PanelShortcutPath
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "[remove] Deleted shortcut $shortcutPath" -ForegroundColor Yellow
    }
    Remove-VersionStamp -Name $ScriptName
    Write-Host "[SUCCESS] Control panel uninstalled." -ForegroundColor Green
    exit 0
}

$createdTask = $false
$preExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

try {
    # F9: preflight (pwsh version, required paths, health port).
    if ($PSVersionTable.PSVersion -lt [version]'7.0') {
        throw ("pwsh 7.0+ is required (found {0}). Install PowerShell 7 and re-run." -f $PSVersionTable.PSVersion)
    }
    Write-Host ("[+] Preflight: pwsh {0} OK" -f $PSVersionTable.PSVersion) -ForegroundColor Green
    foreach ($path in @($startScript, $openScript)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing panel file: $path" }
    }
    Write-Host "[+] Preflight: control-panel files exist" -ForegroundColor Green
    if (-not (Test-PortFree -Port $PanelPort)) {
        if ($preExistingTask) {
            Write-Host "[*] Preflight: port $PanelPort in use but task '$TaskName' exists (upgrade in place)." -ForegroundColor Yellow
        } else {
            Write-Host "[!] Preflight: TCP port $PanelPort is already in use; health check may hit another service." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[+] Preflight: TCP port $PanelPort is free" -ForegroundColor Green
    }

    # F1: idempotency probe.
    if ($preExistingTask) {
        Write-Host "[*] Existing task '$TaskName' detected (state=$($preExistingTask.State)). Upgrading in place..." -ForegroundColor Yellow
    }

    $userId = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute $wscript -Argument ('"{0}"' -f $startScript) -WorkingDirectory $controlDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Quiet local Jellyfin control panel; no console window.' -Force | Out-Null
    if (-not $preExistingTask) { $createdTask = $true }

    # F3: scheduled-task existence verification immediately after creation.
    $task = Confirm-ScheduledTaskExists -Name $TaskName

    $startMenuPrograms = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    New-Item -ItemType Directory -Force -Path $startMenuPrograms | Out-Null
    $shortcutPath = Get-PanelShortcutPath
    # F4: back up existing shortcut (*.bak) before overwriting.
    [void](Backup-File -Path $shortcutPath)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $wscript
    $shortcut.Arguments = ('"{0}"' -f $openScript)
    $shortcut.WorkingDirectory = $controlDir
    $shortcut.IconLocation = "$jellyfinExe,0"
    $shortcut.Description = 'Open the local Jellyfin Control Panel'
    $shortcut.Save()

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Milliseconds 1000
    $health = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $PanelPort) -TimeoutSec 5
    $task = Get-ScheduledTask -TaskName $TaskName

    # F8: version stamp after successful install.
    [void](Write-VersionStamp -Name $ScriptName -Version $ScriptVersion -Extra @{
            task = $TaskName; port = $PanelPort; shortcut = $shortcutPath
        })

    [PSCustomObject]@{
        TaskName    = $task.TaskName
        TaskState   = $task.State
        Shortcut    = $shortcutPath
        PanelHealth = ($health | ConvertTo-Json -Compress)
    }
} catch {
    Write-Host ("[ERROR] Control-panel install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    # F4: rollback on failure (restore *.bak files; remove task only if we created it).
    Restore-Backups
    Restore-RegistryBackups
    if ($createdTask) {
        Write-Host "[rollback] Unregistering partially created task '$TaskName'..." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    exit 1
}
