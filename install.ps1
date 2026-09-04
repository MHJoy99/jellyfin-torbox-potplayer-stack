<#
.SYNOPSIS
    One-click installer for the NexusMedia Jellyfin stack (PUBLIC repo, MIT).

.DESCRIPTION
    Installs the Jellyfin + TorBox + PotPlayer stack in one step on stock
    Windows PowerShell 5.1 and PowerShell 7 using only built-in cmdlets,
    .NET Framework/Core and inbox executables (reg.exe, schtasks.exe,
    icacls.exe). No extra modules are imported.

    The 20 required behaviors (each marked [Req N] in the code):
      1. -Uninstall switch removing everything it installed.
      2. -WhatIf dry-run printing all planned actions (no changes).
      3. Admin check with friendly message (never a silent fail).
      4. Detect pwsh/python/node/rclone, print versions table, offer
         download links for anything missing.
      5. Prompt for TORBOX_API_KEY (masked input option) and offer
         Machine/User scope persist.
      6. Validate the key with one TorBox API call before continuing.
      7. Create F:\Jellyfin directory layout (logs, cache, run, backups).
      8. Register potplayer:// protocol handler (potplayer + potplayer64).
      9. Create MediaStackSupervisor scheduled task (or report the exact
         manual schtasks command when creation is skipped/fails).
     10. Start supervisor once (supervisor.ps1 -Mode Start) and verify.
     11. Health-check all ports (8888/18099/18080/8096) with pass/fail table.
     12. Idempotent re-run (detect existing install, upgrade in place).
     13. Rollback on failure (restore .bak of anything overwritten,
         re-import .reg backups, remove a partially created task).
     14. Write install receipt (version stamp + date + options JSON,
         key material NEVER written).
     15. -SkipTasks switch (files only, no scheduled tasks).
     16. -Portable switch (no registry/task writes, current-dir mode).
     17. Colored step output (green ok, yellow warn, red fail).
     18. Final summary screen: panel URL, next steps, log locations.
     19. Log everything to install-<date>.log.
     20. Exit codes: 0 ok, 1 failed, 2 preflight failed.

    Secrets policy: TORBOX_API_KEY is read from the operator (or -TorboxApiKey
    for automation) and persisted to the Machine/User environment only. It is
    NEVER written to the receipt, the log, or the repository. Logs and receipts
    record only key length / validation result / scope.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
    pwsh -File install.ps1
    Interactive one-click install to F:\Jellyfin.

.EXAMPLE
    pwsh -File install.ps1 -WhatIf
    Dry-run: print every planned action, change nothing.

.EXAMPLE
    pwsh -File install.ps1 -Uninstall
    Remove the task, protocol handlers, env key and receipt.

.EXAMPLE
    pwsh -File install.ps1 -SkipTasks
    Files/directories/registry only; create no scheduled task.

.EXAMPLE
    pwsh -File install.ps1 -Portable
    Current-directory mode; no registry or scheduled-task writes.

.EXAMPLE
    pwsh -File install.ps1 -TorboxApiKey $env:TORBOX_API_KEY -KeyScope User -NonInteractive
    Non-interactive install (automation); exits 2 on preflight failure.

.NOTES
    Compatible: Windows PowerShell 5.1+ and PowerShell 7+. Stdlib only.
    License: MIT. Repo: MHJoy99/jellyfin-torbox-potplayer-stack (PUBLIC).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BaseDir = 'F:\Jellyfin',
    [string]$TorboxApiKey = '',
    [ValidateSet('Machine', 'User')]
    [string]$KeyScope = 'Machine',
    [string]$TaskName = 'MediaStackSupervisor',
    [string]$PotPlayerExe = '',
    [string]$SupervisorScript = '',
    [string]$VersionDir = '',
    [switch]$SkipTasks,
    [switch]$Portable,
    [switch]$Uninstall,
    [switch]$NonInteractive,
    [switch]$ShowKeyInput
)

$ErrorActionPreference = 'Stop'
$script:InstallerVersion = '1.0.0'
$script:InstallerName = 'oneclick-install'

# --------------------------------------------------------------------------
# [Req 16] Portable mode: current-dir mode, no registry/task writes.
# --------------------------------------------------------------------------
function Get-ScriptDirectory {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
    try { return (Get-Location).Path } catch { return '.' }
}

$script:ScriptDir = Get-ScriptDirectory
$script:BaseDirExplicit = $PSBoundParameters.ContainsKey('BaseDir')
$script:KeyScopeExplicit = $PSBoundParameters.ContainsKey('KeyScope')
if ($Portable -and (-not $script:BaseDirExplicit)) {
    $BaseDir = $script:ScriptDir
}
if ([string]::IsNullOrWhiteSpace($SupervisorScript)) {
    $candidateA = Join-Path $BaseDir 'supervisor.ps1'
    $candidateB = Join-Path $script:ScriptDir 'supervisor.ps1'
    if (Test-Path -LiteralPath $candidateA -PathType Leaf) {
        $SupervisorScript = $candidateA
    } else {
        $SupervisorScript = $candidateB
    }
}
if ([string]::IsNullOrWhiteSpace($VersionDir)) {
    $VersionDir = Join-Path $BaseDir '.install-versions'
}
$script:BaseDir = $BaseDir
$script:VersionDir = $VersionDir
$script:RegBackupDir = Join-Path $script:VersionDir 'registry-backups'
$script:ReceiptPath = Join-Path $script:VersionDir 'install.receipt.json'
$script:StampPath = Join-Path $script:VersionDir ($script:InstallerName + '.version.json')

# Rollback ledgers: "original|backup" entries + exported .reg files.
$script:BackupLedger = New-Object System.Collections.Generic.List[string]
$script:RegBackups = New-Object System.Collections.Generic.List[string]
$script:TaskBackupFile = $null
$script:CreatedTask = $false
$script:CreatedDirs = New-Object System.Collections.Generic.List[string]
$script:ExistingInstall = $false
$script:ValidatedKey = $false
$script:KeyLength = 0
$script:ToolRows = @()
$script:HealthRows = @()

# --------------------------------------------------------------------------
# [Req 19] Logging: everything is appended to install-<date>.log.
# --------------------------------------------------------------------------
$script:LogFile = $null
function Initialize-Logging {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = 'install-{0}.log' -f $stamp
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($script:BaseDir)) {
        $candidates += (Join-Path $script:BaseDir (Join-Path 'logs' $name))
    }
    $candidates += (Join-Path $script:ScriptDir $name)
    $tmp = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($tmp)) { $tmp = $env:TMP }
    if ([string]::IsNullOrWhiteSpace($tmp)) { $tmp = 'C:\Windows\Temp' }
    $candidates += (Join-Path $tmp $name)
    foreach ($c in $candidates) {
        try {
            $dir = Split-Path -Parent $c
            if (-not [string]::IsNullOrWhiteSpace($dir) -and (-not (Test-Path -LiteralPath $dir))) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
            Add-Content -LiteralPath $c -Value ('[{0}] install.ps1 v{1} starting. BaseDir={2} Portable={3} SkipTasks={4} Uninstall={5}' -f (Get-Date -Format 'o'), $script:InstallerVersion, $script:BaseDir, $Portable.IsPresent, $SkipTasks.IsPresent, $Uninstall.IsPresent) -Encoding UTF8 -ErrorAction Stop
            $script:LogFile = $c
            return $c
        } catch { }
    }
    $script:LogFile = $null
    return $null
}

function Write-LogLine {
    param([string]$Message)
    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
}

# [Req 17] Colored step output (green ok, yellow warn, red fail).
function Write-Step {
    param([string]$Message)
    Write-Host ('[..] {0}' -f $Message) -ForegroundColor Cyan
    Write-LogLine ('STEP: ' + $Message)
}
function Write-Ok {
    param([string]$Message)
    Write-Host ('[ok] {0}' -f $Message) -ForegroundColor Green
    Write-LogLine ('OK: ' + $Message)
}
function Write-Warn {
    param([string]$Message)
    Write-Host ('[warn] {0}' -f $Message) -ForegroundColor Yellow
    Write-LogLine ('WARN: ' + $Message)
}
function Write-Fail {
    param([string]$Message)
    Write-Host ('[fail] {0}' -f $Message) -ForegroundColor Red
    Write-LogLine ('FAIL: ' + $Message)
}
function Write-Info {
    param([string]$Message)
    Write-Host ('[*] {0}' -f $Message) -ForegroundColor Gray
    Write-LogLine ('INFO: ' + $Message)
}

# --------------------------------------------------------------------------
# Small helpers (5.1-safe: no ternary, no ??, no chain operators).
# --------------------------------------------------------------------------
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-Interactive {
    if ($NonInteractive) { return $false }
    try {
        return ([Environment]::UserInteractive -and (-not [Console]::IsInputRedirected))
    } catch { return $false }
}

function Test-PortTcp {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(800)
        $connected = ($ok -and $client.Connected)
        $client.Close()
        return $connected
    } catch { return $false }
}

function Test-HttpOk {
    param([string]$Url, [int]$TimeoutSec = 4)
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return $true }
        return $false
    } catch { return $false }
}

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $bak = "$Path.bak"
    if (Test-Path -LiteralPath $bak) {
        $stamped = '{0}.{1}' -f $bak, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $bak -Destination $stamped -Force
        Write-Info ('Rotated old backup {0} -> {1}' -f $bak, $stamped)
    }
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    [void]$script:BackupLedger.Add(('{0}|{1}' -f $Path, $bak))
    Write-Info ('Backup {0} -> {1}' -f $Path, $bak)
    return $bak
}

function Restore-Backups {
    foreach ($entry in $script:BackupLedger) {
        $parts = $entry -split '\|', 2
        if ($parts.Count -eq 2 -and (Test-Path -LiteralPath $parts[1] -PathType Leaf)) {
            try {
                Copy-Item -LiteralPath $parts[1] -Destination $parts[0] -Force
                Write-Warn ('[rollback] Restored {0} from {1}' -f $parts[0], $parts[1])
            } catch {
                Write-Fail ('[rollback] Could not restore {0}: {1}' -f $parts[0], $_.Exception.Message)
            }
        }
    }
}

# [Req 8/13] Registry backup via reg.exe (works on 5.1 and 7, no modules).
function Backup-RegistryKey {
    param([string]$RegPath)
    try {
        New-Item -ItemType Directory -Force -Path $script:RegBackupDir | Out-Null
    } catch { }
    $leaf = ($RegPath -split '\\')[-1]
    $out = Join-Path $script:RegBackupDir ('{0}-{1}.reg' -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\reg.exe') -ArgumentList 'export', ('"{0}"' -f $RegPath), ('"{0}"' -f $out), '/y' -Wait -PassThru -NoNewWindow
        if (($p.ExitCode -eq 0) -and (Test-Path -LiteralPath $out)) {
            [void]$script:RegBackups.Add($out)
            Write-Info ('Registry backup {0} -> {1}' -f $RegPath, $out)
            return $out
        }
    } catch { }
    Write-Info ('Registry backup of {0} unavailable (fresh install).' -f $RegPath)
    return $null
}

function Restore-RegistryBackups {
    foreach ($f in $script:RegBackups) {
        if (Test-Path -LiteralPath $f) {
            try {
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\reg.exe') -ArgumentList 'import', ('"{0}"' -f $f) -Wait -NoNewWindow | Out-Null
                Write-Warn ('[rollback] Re-imported registry backup {0}' -f $f)
            } catch {
                Write-Fail ('[rollback] Could not re-import {0}: {1}' -f $f, $_.Exception.Message)
            }
        }
    }
}

function Get-PotPlayerExe {
    param([string]$Hint)
    if (-not [string]::IsNullOrWhiteSpace($Hint) -and (Test-Path -LiteralPath $Hint)) { return $Hint }
    $paths = @(
        'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
        'C:\Program Files\DAUM\PotPlayer\PotPlayer64.exe',
        'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe',
        'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayer.exe',
        'E:\PotPlayer\PotPlayerMini64.exe',
        'E:\MediaServer\apps\PotPlayer\PotPlayerMini64.exe'
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    try {
        $appPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini64.exe'
        if (Test-Path -LiteralPath $appPath) {
            $v = (Get-ItemProperty -LiteralPath $appPath -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
            if (-not [string]::IsNullOrWhiteSpace($v) -and (Test-Path -LiteralPath $v)) { return $v }
        }
    } catch { }
    return $null
}

# --------------------------------------------------------------------------
# [Req 5] Prompt for TORBOX_API_KEY with a masked-input option (5.1-safe via
# -AsSecureString, which exists on both 5.1 and 7).
# --------------------------------------------------------------------------
function Read-ApiKeyFromOperator {
    param([string]$Prefill)
    if (-not [string]::IsNullOrWhiteSpace($Prefill)) { return $Prefill.Trim() }
    $existing = $env:TORBOX_API_KEY
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Info 'TORBOX_API_KEY already present in this session; reusing it (not echoed).'
        return $existing.Trim()
    }
    if (-not (Test-Interactive)) {
        throw 'TORBOX_API_KEY is required. Re-run interactively or pass -TorboxApiKey (automation).'
    }
    Write-Host '' 
    Write-Host 'TorBox API key required. Find it at https://torbox.app -> Settings -> API.' -ForegroundColor Cyan
    $maskAnswer = 'Y'
    if (-not $ShowKeyInput) {
        $maskAnswer = Read-Host 'Mask input while typing? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($maskAnswer)) { $maskAnswer = 'Y' }
    } else {
        $maskAnswer = 'N'
    }
    $plain = ''
    if ($maskAnswer -match '^(?i)y(es)?$') {
        $sec = Read-Host 'Enter TORBOX_API_KEY (masked)' -AsSecureString
        if ($null -eq $sec) { throw 'No API key entered.' }
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    } else {
        $plain = Read-Host 'Enter TORBOX_API_KEY (visible)'
    }
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'No API key entered.' }
    return $plain.Trim()
}

function Read-KeyScopeChoice {
    param([string]$DefaultScope)
    if ($script:KeyScopeExplicit) { return $DefaultScope }
    if ($Portable) {
        Write-Info 'Portable mode: key stays in this session + portable.env (no Machine/User persist).'
        return $DefaultScope
    }
    if (-not (Test-Interactive)) { return $DefaultScope }
    $answer = Read-Host ('Persist TORBOX_API_KEY to Machine or User scope? [M]achine/{0} (default {1})' -f 'User', $DefaultScope)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultScope }
    if ($answer -match '^(?i)u(ser)?$') { return 'User' }
    return 'Machine'
}

# --------------------------------------------------------------------------
# [Req 6] Validate the key with exactly one TorBox API call before mutating.
# TorBox requires ?token= query auth (header-only returns HTTP 422).
# --------------------------------------------------------------------------
function Test-TorboxKey {
    param([string]$Key)
    $url = 'https://api.torbox.app/v1/api/user/me?token=' + [Uri]::EscapeDataString($Key)
    Write-Step 'Validating TORBOX_API_KEY with one TorBox API call (GET /v1/api/user/me)...'
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $ok = $false
        if ($null -ne $resp) {
            if ($resp.PSObject.Properties.Name -contains 'success') {
                if ($resp.success) { $ok = $true }
            } else {
                $ok = $true
            }
        }
        if ($ok) {
            Write-Ok 'TorBox key validated (user/me returned success).'
            Write-LogLine 'TorBox validation: success (key material not logged).'
            return $true
        }
        Write-Fail 'TorBox validation returned an unexpected payload (success=false).'
        return $false
    } catch {
        $msg = $_.Exception.Message
        $status = 0
        try {
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
        } catch { }
        Write-LogLine ('TorBox validation error: {0} (status {1}; key material not logged).' -f $msg, $status)
        if ($status -eq 401 -or $status -eq 403 -or $status -eq 422) {
            Write-Fail ('TorBox rejected the key (HTTP {0}). Get a fresh key at https://torbox.app -> Settings -> API.' -f $status)
            return $false
        }
        Write-Warn ('TorBox validation network error: {0}' -f $msg)
        if (Test-Interactive) {
            $answer = Read-Host 'Continue anyway without validation? [y/N]'
            if ($answer -match '^(?i)y(es)?$') {
                Write-Warn 'Continuing without TorBox validation (operator override).'
                return $true
            }
        }
        Write-Fail 'TorBox validation failed and was not overridden.'
        return $false
    }
}

# --------------------------------------------------------------------------
# [Req 4] Tool detection table + download links for anything missing.
# --------------------------------------------------------------------------
function Get-CommandVersionText {
    param([string]$Name, [string[]]$VersionArgs)
    try {
        $cmd = Get-Command $Name -ErrorAction Stop
        $path = $cmd.Source
        if ([string]::IsNullOrWhiteSpace($path)) { $path = "$Name (in PATH)" }
        foreach ($a in $VersionArgs) {
            try {
                $out = & $cmd.Source $a 2>&1 | Out-String
                if (-not [string]::IsNullOrWhiteSpace($out)) {
                    $first = ($out -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
                    if (-not [string]::IsNullOrWhiteSpace($first)) { return @($true, $first.Trim(), $path) }
                }
            } catch { }
        }
        return @($true, '(installed, version unknown)', $path)
    } catch {
        return @($false, '(missing)', '')
    }
}

function Invoke-ToolDetection {
    Write-Step 'Detecting required tools (pwsh/python/node/rclone)...'
    $rows = @()
    $pwshVer = $PSVersionTable.PSVersion.ToString()
    $pwshPath = ''
    try {
        $c = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($c) { $pwshPath = $c.Source }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        try {
            $c2 = Get-Command powershell -ErrorAction SilentlyContinue
            if ($c2) { $pwshPath = $c2.Source }
        } catch { }
    }
    $rows += (New-Object PSObject -Property @{ Tool = 'pwsh'; Found = 'yes'; Version = $pwshVer; Path = $pwshPath; Download = 'https://aka.ms/pwsh' })
    $py = Get-CommandVersionText -Name 'python' -VersionArgs @('--version')
    if ($py[0] -eq $false) { $py = Get-CommandVersionText -Name 'python3' -VersionArgs @('--version') }
    if ($py[0]) {
        $rows += (New-Object PSObject -Property @{ Tool = 'python'; Found = 'yes'; Version = $py[1]; Path = $py[2]; Download = '-' })
    } else {
        $rows += (New-Object PSObject -Property @{ Tool = 'python'; Found = 'NO'; Version = '(missing)'; Path = ''; Download = 'https://www.python.org/downloads/windows/' })
    }
    $node = Get-CommandVersionText -Name 'node' -VersionArgs @('--version')
    if ($node[0]) {
        $rows += (New-Object PSObject -Property @{ Tool = 'node'; Found = 'yes'; Version = $node[1]; Path = $node[2]; Download = '-' })
    } else {
        $rows += (New-Object PSObject -Property @{ Tool = 'node'; Found = 'NO'; Version = '(missing)'; Path = ''; Download = 'https://nodejs.org/en/download' })
    }
    $rclone = Get-CommandVersionText -Name 'rclone' -VersionArgs @('version', '--version')
    if ($rclone[0]) {
        $rows += (New-Object PSObject -Property @{ Tool = 'rclone'; Found = 'yes'; Version = $rclone[1]; Path = $rclone[2]; Download = '-' })
    } else {
        $rows += (New-Object PSObject -Property @{ Tool = 'rclone'; Found = 'NO'; Version = '(missing)'; Path = ''; Download = 'https://rclone.org/downloads/' })
    }
    $script:ToolRows = $rows
    $rows | Select-Object Tool, Found, Version, Download | Format-Table -AutoSize | Out-String | Write-Host
    try {
        $logText = ($rows | Select-Object Tool, Found, Version, Download | Format-Table -AutoSize | Out-String)
        Write-LogLine ("Tools:`n" + $logText)
    } catch { }
    $missing = @($rows | Where-Object { $_.Found -eq 'NO' })
    foreach ($m in $missing) {
        if ($m.Tool -eq 'python') {
            Write-Warn ('Missing python: install from {0} (required by torbox-proxy, bridge, panel).' -f $m.Download)
        } elseif ($m.Tool -eq 'rclone') {
            Write-Warn ('Missing rclone: install from {0} (required for T:\\ / F:\\Media mounts).' -f $m.Download)
        } else {
            Write-Warn ('Missing {0}: install from {1}.' -f $m.Tool, $m.Download)
        }
    }
    if ($missing.Count -eq 0) { Write-Ok 'All tools present.' }
}

# --------------------------------------------------------------------------
# [Req 7] Directory layout. [Req 12] Idempotent (existing dirs are kept).
# --------------------------------------------------------------------------
function Ensure-DirectoryLayout {
    Write-Step ('Creating directory layout under {0} (logs, cache, run, backups)...' -f $script:BaseDir)
    $subs = @('logs', 'cache', 'run', 'backups')
    try {
        if (-not (Test-Path -LiteralPath $script:BaseDir)) {
            New-Item -ItemType Directory -Force -Path $script:BaseDir | Out-Null
            [void]$script:CreatedDirs.Add($script:BaseDir)
            Write-Ok ('Created {0}' -f $script:BaseDir)
        } else {
            Write-Info ('BaseDir exists, reusing: {0}' -f $script:BaseDir)
        }
        foreach ($s in $subs) {
            $p = Join-Path $script:BaseDir $s
            if (-not (Test-Path -LiteralPath $p)) {
                New-Item -ItemType Directory -Force -Path $p | Out-Null
                [void]$script:CreatedDirs.Add($p)
                Write-Ok ('Created {0}' -f $p)
            } else {
                Write-Info ('Exists, keeping: {0}' -f $p)
            }
        }
        New-Item -ItemType Directory -Force -Path $script:VersionDir | Out-Null
        Write-Ok 'Directory layout ready.'
    } catch {
        throw ('Directory layout failed: {0}' -f $_.Exception.Message)
    }
}

# --------------------------------------------------------------------------
# [Req 8] potplayer:// protocol handler (idempotent, verified, backed up).
# --------------------------------------------------------------------------
function Register-ProtocolHandler {
    Write-Step 'Registering potplayer:// protocol handler...'
    $launcher = Join-Path $script:BaseDir 'potplayer-launcher.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        $fallback = Join-Path $script:ScriptDir 'potplayer-launcher.ps1'
        if (Test-Path -LiteralPath $fallback -PathType Leaf) { $launcher = $fallback }
    }
    $exe = Get-PotPlayerExe -Hint $PotPlayerExe
    if ((Test-Path -LiteralPath $launcher -PathType Leaf)) {
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '" "%1"'
        Write-Info ('Handler target: wrapper launcher {0}' -f $launcher)
    } elseif ($exe) {
        $cmd = '"' + $exe + '" "%1"'
        Write-Warn ('Launcher script not found; handler points at PotPlayer directly: {0}' -f $exe)
    } else {
        if ($Portable -or $SkipTasks) {
            Write-Warn 'Neither potplayer-launcher.ps1 nor PotPlayer.exe found; skipping protocol registration (no target).'
            return $false
        }
        throw 'Cannot register potplayer:// : potplayer-launcher.ps1 and PotPlayer.exe both missing (pass -PotPlayerExe).'
    }
    [void](Backup-RegistryKey -RegPath 'HKCR\potplayer')
    [void](Backup-RegistryKey -RegPath 'HKCR\potplayer64')
    $protos = @('potplayer', 'potplayer64')
    foreach ($proto in $protos) {
        $root = 'Registry::HKEY_CLASSES_ROOT\' + $proto
        $cmdKey = $root + '\shell\open\command'
        $iconKey = $root + '\DefaultIcon'
        try {
            $current = (Get-ItemProperty -LiteralPath $cmdKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
        } catch { $current = $null }
        if ($current -ceq $cmd) {
            Write-Info ('Protocol {0}:// already up to date; leaving in place.' -f $proto)
            continue
        }
        try {
            if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -Force | Out-Null }
            Set-ItemProperty -LiteralPath $root -Name '(Default)' -Value 'URL:PotPlayer Protocol' -Force
            Set-ItemProperty -LiteralPath $root -Name 'URL Protocol' -Value '' -Force
            if (-not (Test-Path -LiteralPath $iconKey)) { New-Item -Path $iconKey -Force | Out-Null }
            if ($exe) {
                Set-ItemProperty -LiteralPath $iconKey -Name '(Default)' -Value ('"' + $exe + '",0') -Force
            }
            if (-not (Test-Path -LiteralPath $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
            Set-ItemProperty -LiteralPath $cmdKey -Name '(Default)' -Value $cmd -Force
            Write-Ok ('Registered {0}://' -f $proto)
        } catch {
            throw ('Protocol registration failed for {0}: {1}' -f $proto, $_.Exception.Message)
        }
    }
    foreach ($proto in $protos) {
        $cmdKey = 'Registry::HKEY_CLASSES_ROOT\' + $proto + '\shell\open\command'
        $verified = (Get-ItemProperty -LiteralPath $cmdKey -ErrorAction Stop).'(default)'
        if ([string]::IsNullOrWhiteSpace($verified)) { throw ('Verification failed: {0} handler is empty.' -f $proto) }
        Write-LogLine ('Verify {0} -> {1}' -f $proto, $verified)
    }
    Write-Ok 'Protocol handler verified (potplayer + potplayer64).'
    return $true
}

# --------------------------------------------------------------------------
# [Req 9] MediaStackSupervisor scheduled task (cmdlets first, schtasks fallback).
# --------------------------------------------------------------------------
function Get-TaskExists {
    param([string]$Name)
    try {
        $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if ($t) { return $true }
    } catch { }
    try {
        $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\schtasks.exe') -ArgumentList '/Query', '/TN', ('"{0}"' -f $Name), '/FO', 'LIST' -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) { return $true }
    } catch { }
    return $false
}

function Backup-TaskXml {
    param([string]$Name)
    try {
        $out = Join-Path $script:VersionDir ('task-{0}-{1}.xml' -f ($Name -replace '[^\w\-]+', '_'), (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\schtasks.exe') -ArgumentList '/Query', '/TN', ('"{0}"' -f $Name), '/XML' -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out
        if (($p.ExitCode -eq 0) -and (Test-Path -LiteralPath $out)) {
            $script:TaskBackupFile = $out
            Write-Info ('Task backup {0} -> {1}' -f $Name, $out)
            return $out
        }
    } catch { }
    return $null
}

function Get-ManualTaskStep {
    param([string]$PwshExe)
    $tr = '{0} -NoProfile -ExecutionPolicy Bypass -File "{1}" -Mode Run' -f $PwshExe, $SupervisorScript
    return ('schtasks /Create /TN "{0}" /TR "{1}" /SC ONLOGON /RL HIGHEST /F' -f $TaskName, $tr)
}

function Register-SupervisorTask {
    param([string]$PwshExe)
    Write-Step ('Creating scheduled task {0}...' -f $TaskName)
    $existed = Get-TaskExists -Name $TaskName
    if ($existed) {
        Write-Info ('Existing task {0} detected; upgrading in place.' -f $TaskName)
        [void](Backup-TaskXml -Name $TaskName)
    }
    $created = $false
    $cmdletsAvailable = $false
    try {
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) { $cmdletsAvailable = $true }
    } catch { $cmdletsAvailable = $false }
    if ($cmdletsAvailable) {
        try {
            $userId = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
            $action = New-ScheduledTaskAction -Execute $PwshExe -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Run' -f $SupervisorScript)
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
            $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Media stack supervisor (proxy/bridge/Jellyfin/panel watchdog).' -Force | Out-Null
            $created = $true
            Write-Ok ('Scheduled task {0} registered (cmdlets).' -f $TaskName)
        } catch {
            Write-Warn ('Cmdlet task registration failed ({0}); trying schtasks.exe.' -f $_.Exception.Message)
            $created = $false
        }
    }
    if (-not $created) {
        $tr = '{0} -NoProfile -ExecutionPolicy Bypass -File "{1}" -Mode Run' -f $PwshExe, $SupervisorScript
        $args = @('/Create', '/TN', $TaskName, '/TR', $tr, '/SC', 'ONLOGON', '/RL', 'HIGHEST', '/F')
        try {
            $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\schtasks.exe') -ArgumentList $args -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -ne 0) { throw ('schtasks.exe exited with code {0}.' -f $p.ExitCode) }
            $created = $true
            Write-Ok ('Scheduled task {0} registered (schtasks.exe).' -f $TaskName)
        } catch {
            throw ('Task creation failed: {0}. Manual step: {1}' -f $_.Exception.Message, (Get-ManualTaskStep -PwshExe $PwshExe))
        }
    }
    if (-not $existed) { $script:CreatedTask = $true }
    if (-not (Get-TaskExists -Name $TaskName)) {
        throw ('Task verification failed: {0} not found after creation. Manual step: {1}' -f $TaskName, (Get-ManualTaskStep -PwshExe $PwshExe))
    }
    Write-Ok ('Task {0} verified present.' -f $TaskName)
}

# --------------------------------------------------------------------------
# [Req 10] Start supervisor once (-Mode Start) and verify.
# --------------------------------------------------------------------------
function Start-SupervisorOnce {
    param([string]$PwshExe)
    Write-Step 'Starting supervisor once (supervisor.ps1 -Mode Start)...'
    if (-not (Test-Path -LiteralPath $SupervisorScript -PathType Leaf)) {
        Write-Warn ('Supervisor script not found: {0}; skipping Start (files installed, services not started).' -f $SupervisorScript)
        return $false
    }
    try {
        $p = Start-Process -FilePath $PwshExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $SupervisorScript), '-Mode', 'Start') -Wait -PassThru -NoNewWindow
        Write-LogLine ('supervisor -Mode Start exit code: {0}' -f $p.ExitCode)
        if ($p.ExitCode -ne 0) {
            Write-Warn ('Supervisor Start exited with code {0} (mounts/services may still be warming; see health table).' -f $p.ExitCode)
            return $false
        }
        Write-Ok 'Supervisor Start completed (exit 0).'
        return $true
    } catch {
        Write-Warn ('Supervisor Start launch failed: {0}' -f $_.Exception.Message)
        return $false
    }
}

# --------------------------------------------------------------------------
# [Req 11] Health-check all ports with a pass/fail table.
# --------------------------------------------------------------------------
function Invoke-HealthChecks {
    Write-Step 'Health-checking ports 8888 / 18099 / 18080 / 8096...'
    $defs = @(
        @{ Port = 8888; Service = 'torbox-proxy'; Url = 'http://127.0.0.1:8888/health' },
        @{ Port = 18099; Service = 'bridge'; Url = 'http://127.0.0.1:18099/health' },
        @{ Port = 18080; Service = 'panel'; Url = 'http://127.0.0.1:18080/health' },
        @{ Port = 8096; Service = 'jellyfin'; Url = 'http://127.0.0.1:8096/System/Info/Public' }
    )
    $rows = @()
    foreach ($d in $defs) {
        $tcp = Test-PortTcp -Port $d.Port
        $http = $false
        if ($tcp) { $http = Test-HttpOk -Url $d.Url -TimeoutSec 4 }
        $result = 'FAIL'
        if ($tcp -and $http) { $result = 'PASS' }
        elseif ($tcp) { $result = 'PORT-ONLY' }
        $tcpText = 'closed'
        if ($tcp) { $tcpText = 'listening' }
        $httpText = 'fail'
        if ($http) { $httpText = 'pass' }
        $rows += (New-Object PSObject -Property @{ Port = $d.Port; Service = $d.Service; TCP = $tcpText; HTTP = $httpText; Result = $result })
        Write-LogLine ('health {0}/{1}: tcp={2} http={3} result={4}' -f $d.Port, $d.Service, $tcpText, $httpText, $result)
    }
    $script:HealthRows = $rows
    $rows | Select-Object Port, Service, TCP, HTTP, Result | Format-Table -AutoSize | Out-String | Write-Host
    $fails = @($rows | Where-Object { $_.Result -eq 'FAIL' })
    if ($fails.Count -eq 0) {
        Write-Ok 'Health: all ports responding.'
    } else {
        Write-Warn ('Health: {0} of 4 checks failing (fresh installs show FAIL until Jellyfin/proxy finish first start).' -f $fails.Count)
    }
}

# --------------------------------------------------------------------------
# [Req 14] Install receipt (version stamp + date + options JSON, no secrets).
# --------------------------------------------------------------------------
function Write-Receipt {
    param([string]$ScopeUsed, [bool]$TasksSkipped, [bool]$RegistrySkipped, [bool]$Upgraded)
    Write-Step 'Writing install receipt...'
    [void](Backup-File -Path $script:ReceiptPath)
    [void](Backup-File -Path $script:StampPath)
    $toolInfo = @()
    foreach ($t in $script:ToolRows) {
        $toolInfo += @{ tool = $t.Tool; found = $t.Found; version = $t.Version }
    }
    $healthInfo = @()
    foreach ($h in $script:HealthRows) {
        $healthInfo += @{ port = $h.Port; service = $h.Service; tcp = $h.TCP; http = $h.HTTP; result = $h.Result }
    }
    $receipt = [ordered]@{
        installer   = $script:InstallerName
        version     = $script:InstallerVersion
        installedAt = (Get-Date).ToString('o')
        user        = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        computer    = $env:COMPUTERNAME
        baseDir     = $script:BaseDir
        taskName    = $TaskName
        upgraded    = $Upgraded
        options     = [ordered]@{
            skipTasks = $TasksSkipped
            portable  = $Portable.IsPresent
            keyScope  = $ScopeUsed
        }
        torboxKey   = [ordered]@{
            persisted   = (-not $Portable.IsPresent)
            scope       = $ScopeUsed
            length      = $script:KeyLength
            validated   = $script:ValidatedKey
            validatedAt = (Get-Date).ToString('o')
        }
        tools       = $toolInfo
        health      = $healthInfo
        status      = 'installed'
    }
    try {
        New-Item -ItemType Directory -Force -Path $script:VersionDir | Out-Null
        ($receipt | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $script:ReceiptPath -Encoding UTF8
        ($receipt | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $script:StampPath -Encoding UTF8
        Write-Ok ('Receipt written: {0}' -f $script:ReceiptPath)
    } catch {
        throw ('Receipt write failed: {0}' -f $_.Exception.Message)
    }
}

# --------------------------------------------------------------------------
# [Req 18] Final summary screen.
# --------------------------------------------------------------------------
function Show-FinalSummary {
    param([bool]$TasksSkipped, [bool]$RegistrySkipped, [string]$ScopeUsed)
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  Jellyfin stack install complete' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  Panel:   http://127.0.0.1:18080' -ForegroundColor White
    Write-Host '  Proxy:   http://127.0.0.1:8888/health' -ForegroundColor White
    Write-Host '  Bridge:  http://127.0.0.1:18099/health' -ForegroundColor White
    Write-Host '  Jellyfin: http://127.0.0.1:8096' -ForegroundColor White
    Write-Host '' 
    Write-Host '  Next steps:' -ForegroundColor Cyan
    Write-Host '    1. Ensure rclone remotes exist: rclone listremotes (torbox:, gdrive-media:)' -ForegroundColor Gray
    Write-Host '    2. Open the panel above; use Start all if mounts are down.' -ForegroundColor Gray
    Write-Host '    3. Play via potplayer:// links (protocol registered unless -Portable).' -ForegroundColor Gray
    if ($TasksSkipped) {
        Write-Host '    4. Tasks were skipped: start services with supervisor.ps1 -Mode Start.' -ForegroundColor Yellow
    }
    Write-Host '' 
    Write-Host '  Log locations:' -ForegroundColor Cyan
    Write-Host ('    Installer log : {0}' -f $script:LogFile) -ForegroundColor Gray
    Write-Host ('    Receipt       : {0}' -f $script:ReceiptPath) -ForegroundColor Gray
    Write-Host ('    Supervisor    : {0}' -f (Join-Path $script:BaseDir 'logs\supervisor.log')) -ForegroundColor Gray
    Write-Host ('    Launcher      : {0}' -f (Join-Path $script:BaseDir 'logs\potplayer-launcher.log')) -ForegroundColor Gray
    Write-Host ('    Jellyfin data : {0}' -f (Join-Path $script:BaseDir 'data\log')) -ForegroundColor Gray
    Write-Host ('  Key scope: {0} (TORBOX_API_KEY persisted{1}).' -f $ScopeUsed, $(if ($Portable) { ' to session/portable.env only' } else { '' })) -ForegroundColor Gray
    Write-LogLine 'Final summary displayed.'
}

# --------------------------------------------------------------------------
# [Req 2] WhatIf dry-run: print every planned action, change nothing.
# --------------------------------------------------------------------------
function Show-WhatIfPlan {
    param([bool]$IsUninstall)
    Write-Host '================ WHATIF PLAN (no changes) ================' -ForegroundColor Cyan
    if ($IsUninstall) {
        Write-Host ('Would remove scheduled task: {0} (schtasks /Delete /TN "{0}" /F)' -f $TaskName) -ForegroundColor White
        Write-Host 'Would remove registry keys: HKCR\potplayer, HKCR\potplayer64 (skipped when -Portable)' -ForegroundColor White
        Write-Host 'Would remove env TORBOX_API_KEY from Machine+User scopes (session var cleared too; skipped when -Portable)' -ForegroundColor White
        Write-Host ('Would delete receipt: {0}' -f $script:ReceiptPath) -ForegroundColor White
        Write-Host ('Would delete stamp: {0}' -f $script:StampPath) -ForegroundColor White
        Write-Host 'Would attempt: supervisor.ps1 -Mode Stop (best effort, if present)' -ForegroundColor White
        Write-Host 'Would keep: media/data/logs (user data is never deleted by -Uninstall)' -ForegroundColor White
        Write-LogLine 'WhatIf uninstall plan displayed.'
        return
    }
    Write-Host ('BaseDir layout: {0}\logs,cache,run,backups + {1}' -f $script:BaseDir, $script:VersionDir) -ForegroundColor White
    Write-Host 'Tool detection: pwsh/python/node/rclone versions table + download links for missing' -ForegroundColor White
    Write-Host 'Prompt TORBOX_API_KEY (masked option), choose Machine/User scope (default Machine)' -ForegroundColor White
    Write-Host 'Validate key: GET https://api.torbox.app/v1/api/user/me?token=<key> (one call)' -ForegroundColor White
    if ($Portable) {
        Write-Host 'Persist: session env + portable.env in BaseDir (NO Machine/User, NO registry, NO task)' -ForegroundColor White
    } else {
        Write-Host ('Persist: [Environment]::SetEnvironmentVariable TORBOX_API_KEY/<scope> + $env: (scope {0})' -f $KeyScope) -ForegroundColor White
    }
    if ($Portable) {
        Write-Host 'Registry: SKIPPED (portable mode writes no registry keys)' -ForegroundColor White
    } else {
        Write-Host 'Registry: backup HKCR\potplayer(+64) to .reg, write potplayer:// handler, verify by read-back' -ForegroundColor White
    }
    if ($Portable -or $SkipTasks) {
        Write-Host 'Scheduled task: SKIPPED (-Portable/-SkipTasks); manual step would be printed instead' -ForegroundColor White
        Write-Host 'Supervisor Start: SKIPPED (files only); health table still printed as informational' -ForegroundColor White
    } else {
        Write-Host ('Scheduled task: create/upgrade {0} (AtLogOn, highest); verify present' -f $TaskName) -ForegroundColor White
        Write-Host 'Supervisor: run supervisor.ps1 -Mode Start once, report exit code' -ForegroundColor White
    }
    Write-Host 'Health: TCP+HTTP checks for 8888/18099/18080/8096 with pass/fail table' -ForegroundColor White
    Write-Host ('Receipt: {0} (+ version stamp), .bak of anything overwritten' -f $script:ReceiptPath) -ForegroundColor White
    Write-Host ('Log: install-<date>.log under {0}\logs (fallback shown at runtime)' -f $script:BaseDir) -ForegroundColor White
    Write-Host 'Summary: panel URL + next steps + log locations; exit 0' -ForegroundColor White
    Write-LogLine 'WhatIf install plan displayed.'
}

# --------------------------------------------------------------------------
# [Req 1] Uninstall: remove everything this installer created.
# --------------------------------------------------------------------------
function Invoke-UninstallFlow {
    Write-Step 'Uninstalling one-click stack (installer artifacts only; user data kept)...'
    $errors = 0
    try {
        if (Test-Path -LiteralPath $SupervisorScript -PathType Leaf) {
            try {
                $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
                if ([string]::IsNullOrWhiteSpace($pwshExe)) { $pwshExe = (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') }
                Write-Info 'Attempting supervisor.ps1 -Mode Stop (best effort)...'
                Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $SupervisorScript), '-Mode', 'Stop') -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
            } catch { Write-Info ('Supervisor stop skipped: {0}' -f $_.Exception.Message) }
        }
    } catch { }
    if (-not $Portable -and (-not $SkipTasks)) {
        try {
            if (Get-TaskExists -Name $TaskName) {
                [void](Backup-TaskXml -Name $TaskName)
                try { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\schtasks.exe') -ArgumentList '/End', '/TN', ('"{0}"' -f $TaskName) -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null } catch { }
                try {
                    $cmd = Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue
                    if ($cmd) {
                        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
                    } else {
                        $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\schtasks.exe') -ArgumentList '/Delete', '/TN', ('"{0}"' -f $TaskName), '/F' -Wait -PassThru -NoNewWindow
                        if ($p.ExitCode -ne 0) { throw ('schtasks /Delete exited {0}.' -f $p.ExitCode) }
                    }
                    Write-Ok ('Removed scheduled task {0}.' -f $TaskName)
                } catch {
                    Write-Fail ('Could not remove task {0}: {1}' -f $TaskName, $_.Exception.Message)
                    $errors++
                }
            } else {
                Write-Info ('Scheduled task {0} already absent.' -f $TaskName)
            }
        } catch {
            Write-Fail ('Task uninstall error: {0}' -f $_.Exception.Message)
            $errors++
        }
    } else {
        Write-Info 'Task removal skipped (-Portable/-SkipTasks: no task was created by this mode).'
    }
    if (-not $Portable) {
        [void](Backup-RegistryKey -RegPath 'HKCR\potplayer')
        [void](Backup-RegistryKey -RegPath 'HKCR\potplayer64')
        foreach ($proto in @('potplayer', 'potplayer64')) {
            $key = 'Registry::HKEY_CLASSES_ROOT\' + $proto
            try {
                if (Test-Path -LiteralPath $key) {
                    Remove-Item -LiteralPath $key -Recurse -Force
                    Write-Ok ('Removed protocol key {0}.' -f $key)
                } else {
                    Write-Info ('Protocol key {0} already absent.' -f $key)
                }
            } catch {
                Write-Fail ('Could not remove {0}: {1}' -f $key, $_.Exception.Message)
                $errors++
            }
        }
        foreach ($scope in @('Machine', 'User')) {
            try {
                $cur = [Environment]::GetEnvironmentVariable('TORBOX_API_KEY', $scope)
                if (-not [string]::IsNullOrWhiteSpace($cur)) {
                    [Environment]::SetEnvironmentVariable('TORBOX_API_KEY', $null, $scope)
                    Write-Ok ('Removed TORBOX_API_KEY from {0} scope.' -f $scope)
                } else {
                    Write-Info ('TORBOX_API_KEY already absent from {0} scope.' -f $scope)
                }
            } catch {
                Write-Fail ('Could not clear {0} TORBOX_API_KEY: {1}' -f $scope, $_.Exception.Message)
                $errors++
            }
        }
        try {
            if (Test-Path 'env:TORBOX_API_KEY') { Remove-Item 'env:TORBOX_API_KEY' -ErrorAction SilentlyContinue }
        } catch { }
    } else {
        Write-Info 'Registry/env removal skipped (portable mode never wrote them).'
        try {
            $penv = Join-Path $script:BaseDir 'portable.env'
            if (Test-Path -LiteralPath $penv) {
                Remove-Item -LiteralPath $penv -Force
                Write-Ok ('Removed {0}.' -f $penv)
            }
        } catch {
            Write-Fail ('Could not remove portable.env: {0}' -f $_.Exception.Message)
            $errors++
        }
    }
    foreach ($f in @($script:ReceiptPath, $script:StampPath)) {
        try {
            if (Test-Path -LiteralPath $f) {
                Remove-Item -LiteralPath $f -Force
                Write-Ok ('Removed {0}.' -f $f)
            } else {
                Write-Info ('Already absent: {0}.' -f $f)
            }
        } catch {
            Write-Fail ('Could not remove {0}: {1}' -f $f, $_.Exception.Message)
            $errors++
        }
    }
    Write-Host '' 
    if ($errors -eq 0) {
        Write-Ok 'Uninstall complete. User data (media/data/logs) was left untouched.'
        Write-LogLine 'Uninstall complete, exit 0.'
        exit 0
    }
    Write-Fail ('Uninstall finished with {0} error(s). See log: {1}' -f $errors, $script:LogFile)
    exit 1
}

# --------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------
Initialize-Logging | Out-Null
Write-Info ('Log file: {0}' -f $script:LogFile)
Write-Info ('PowerShell {0} on {1}. Portable={2} SkipTasks={3}.' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString, $Portable.IsPresent, $SkipTasks.IsPresent)

# [Req 2] Dry-run short-circuits before any mutation.
if ($WhatIfPreference) {
    Show-WhatIfPlan -IsUninstall $Uninstall.IsPresent
    Write-LogLine 'WhatIf exit 0.'
    exit 0
}

# [Req 1] Uninstall path.
if ($Uninstall) {
    if ($Portable) {
        Write-Info 'Portable uninstall: registry/task steps are no-ops by design.'
    }
    Invoke-UninstallFlow
}

try {
    # [Req 3] Admin check with a friendly message (never silent).
    $isAdmin = Test-IsAdmin
    if ($Portable) {
        Write-Info 'Portable mode needs no admin rights; continuing without elevation.'
    } elseif (-not $isAdmin) {
        Write-Warn 'Administrator rights are required (registry + Machine env + scheduled task).'
        Write-Warn 'Right-click PowerShell -> Run as Administrator, then re-run install.ps1.'
        Write-Warn ('Portable alternative (no admin): pwsh -File install.ps1 -Portable')
        if (Test-Interactive) {
            $answer = Read-Host 'Re-launch install.ps1 as Administrator now? [Y/n]'
            if ([string]::IsNullOrWhiteSpace($answer) -or ($answer -match '^(?i)y(es)?$')) {
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
                if ($script:BaseDirExplicit) { $argList += @('-BaseDir', ('"{0}"' -f $script:BaseDir)) }
                if (-not [string]::IsNullOrWhiteSpace($TorboxApiKey)) { $argList += @('-TorboxApiKey', ('"{0}"' -f $TorboxApiKey)) }
                if ($script:KeyScopeExplicit) { $argList += @('-KeyScope', $KeyScope) }
                if (-not [string]::IsNullOrWhiteSpace($TaskName)) { $argList += @('-TaskName', ('"{0}"' -f $TaskName)) }
                if ($SkipTasks) { $argList += '-SkipTasks' }
                if ($Portable) { $argList += '-Portable' }
                if ($NonInteractive) { $argList += '-NonInteractive' }
                $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
                if ([string]::IsNullOrWhiteSpace($pwshExe)) { $pwshExe = (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') }
                Start-Process -FilePath $pwshExe -ArgumentList $argList -Verb RunAs
                Write-LogLine 'Elevation re-launch requested, exit 0.'
                exit 0
            }
        }
        Write-Fail 'Preflight failed: not elevated. Re-run as Administrator (or use -Portable).'
        Write-LogLine 'Exit 2 (preflight: admin).'
        exit 2
    } else {
        Write-Ok 'Running with Administrator rights.'
    }

    # Preflight: PowerShell version (5.1+ required, 7 also supported).
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        Write-Fail ('Preflight failed: PowerShell 5.1+ required (found {0}).' -f $PSVersionTable.PSVersion)
        Write-LogLine 'Exit 2 (preflight: pwsh version).'
        exit 2
    }
    Write-Ok ('Preflight: PowerShell {0} OK (5.1+ supported).' -f $PSVersionTable.PSVersion)

    # [Req 12] Idempotency probe: existing receipt / task / protocol.
    $priorReceipt = Test-Path -LiteralPath $script:ReceiptPath
    $priorTask = $false
    if (-not $Portable -and (-not $SkipTasks)) { $priorTask = Get-TaskExists -Name $TaskName }
    $priorProto = $false
    try {
        if (Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command') { $priorProto = $true }
    } catch { }
    if ($priorReceipt -or $priorTask -or $priorProto) {
        $script:ExistingInstall = $true
        Write-Warn 'Existing install detected (receipt/task/protocol); upgrading in place (idempotent re-run).'
    } else {
        Write-Info 'No existing install detected; fresh install.'
    }

    # Resolve pwsh exe for the scheduled task / supervisor start.
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($pwshExe)) {
        $pwshExe = (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
        Write-Info 'pwsh 7 not found; scheduled task will use Windows PowerShell 5.1.'
    }

    # [Req 4] Tools table.
    Invoke-ToolDetection

    # [Req 5] Key prompt + scope choice (scope prompt skipped when -KeyScope given).
    $key = Read-ApiKeyFromOperator -Prefill $TorboxApiKey
    $script:KeyLength = $key.Length
    $scopeUsed = Read-KeyScopeChoice -DefaultScope $KeyScope
    Write-Info ('Key scope selected: {0} (length {1}; value never logged).' -f $scopeUsed, $script:KeyLength)

    # [Req 6] One-call validation BEFORE any mutation.
    $script:ValidatedKey = Test-TorboxKey -Key $key
    if (-not $script:ValidatedKey) {
        Write-Fail 'Aborting before changes: TorBox key did not validate.'
        Write-LogLine 'Exit 1 (key validation).'
        exit 1
    }

    # [Req 7] Directory layout.
    Ensure-DirectoryLayout

    # Persist the key (Portable => session + portable.env only, no registry).
    if ($Portable) {
        $env:TORBOX_API_KEY = $key
        try {
            $penv = Join-Path $script:BaseDir 'portable.env'
            [void](Backup-File -Path $penv)
            '# Portable env (untracked at runtime; never commit).' | Out-File -LiteralPath $penv -Encoding UTF8
            Add-Content -LiteralPath $penv -Value 'TORBOX_API_KEY is loaded from this session only; re-export after reboot:' -Encoding UTF8
            Write-Ok 'Portable: key loaded into this session only (no Machine/User write).'
        } catch {
            Write-Warn ('Portable env note write skipped: {0}' -f $_.Exception.Message)
        }
    } else {
        Write-Step ('Persisting TORBOX_API_KEY to {0} scope...' -f $scopeUsed)
        try {
            [Environment]::SetEnvironmentVariable('TORBOX_API_KEY', $key, $scopeUsed)
            $env:TORBOX_API_KEY = $key
            $back = [Environment]::GetEnvironmentVariable('TORBOX_API_KEY', $scopeUsed)
            if ([string]::IsNullOrWhiteSpace($back)) { throw 'read-back of persisted key returned empty.' }
            Write-Ok ('TORBOX_API_KEY persisted to {0} scope (verified by read-back).' -f $scopeUsed)
        } catch {
            throw ('Could not persist TORBOX_API_KEY to {0} scope: {1}' -f $scopeUsed, $_.Exception.Message)
        }
    }
    $key = $null

    $tasksSkipped = ($SkipTasks.IsPresent -or $Portable.IsPresent)
    $registrySkipped = $Portable.IsPresent

    # [Req 8] Protocol handler (skipped in Portable).
    if ($registrySkipped) {
        Write-Info 'Registry writes skipped (-Portable). potplayer:// handler not registered.'
        Write-Info 'Portable manual step: run register-potplayer-protocol.ps1 from an elevated shell to enable potplayer:// links.'
    } else {
        [void](Register-ProtocolHandler)
    }

    # [Req 9] Scheduled task (skipped with -SkipTasks / -Portable).
    if ($tasksSkipped) {
        Write-Info 'Scheduled-task creation skipped (-SkipTasks/-Portable: files only).'
        Write-Info ('Manual step when ready: {0}' -f (Get-ManualTaskStep -PwshExe $pwshExe))
    } else {
        try {
            Register-SupervisorTask -PwshExe $pwshExe
        } catch {
            Write-Fail $_.Exception.Message
            throw
        }
    }

    # [Req 10] Supervisor Run-once Start + verify (skipped when tasks skipped).
    $started = $false
    if ($tasksSkipped) {
        Write-Info 'Supervisor Start skipped (-SkipTasks/-Portable: files only, services not started).'
    } else {
        $started = Start-SupervisorOnce -PwshExe $pwshExe
        if (-not $started) {
            Write-Warn 'Supervisor Start did not report success; continuing to health checks (mounts may need rclone remotes first).'
        }
    }

    # [Req 11] Port health table (informational; fresh installs may show FAIL).
    Invoke-HealthChecks

    # [Req 14] Receipt (redacted).
    Write-Receipt -ScopeUsed $scopeUsed -TasksSkipped $tasksSkipped -RegistrySkipped $registrySkipped -Upgraded $script:ExistingInstall

    # [Req 18] Summary.
    Show-FinalSummary -TasksSkipped $tasksSkipped -RegistrySkipped $registrySkipped -ScopeUsed $scopeUsed

    Write-LogLine 'Exit 0.'
    exit 0
} catch {
    # [Req 13] Rollback on failure.
    Write-Fail ('Install failed: {0}' -f $_.Exception.Message)
    Write-LogLine ('Exception: {0}' -f $_.ToString())
    Restore-Backups
    Restore-RegistryBackups
    if ($script:CreatedTask) {
        try {
            Write-Warn ('[rollback] Removing partially created task {0}...' -f $TaskName)
            $cmd = Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue
            if ($cmd) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            } else {
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\schtasks.exe') -ArgumentList '/Delete', '/TN', ('"{0}"' -f $TaskName), '/F' -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
            }
        } catch { }
    }
    Write-Fail ('Rolled back .bak/.reg artifacts. See log: {0}' -f $script:LogFile)
    Write-LogLine 'Exit 1.'
    exit 1
}
