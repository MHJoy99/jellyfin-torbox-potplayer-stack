<#
.SYNOPSIS
    Installs the full NexusMedia Jellyfin stack in dependency order.
.DESCRIPTION
    Feature 10 orchestrator: calls each installer in dependency order, stops on
    the first failure, verifies version stamps, and supports -Uninstall (which
    runs the same steps in reverse order).

    Dependency order (install):
      1. install-rclone-service.ps1      (cloud mount service — foundation)
      2. create_rclone_mcp.ps1            (MCP bridge over rclone + config)
      3. register-potplayer-protocol.ps1  (potplayer:// protocol handlers)
      4. update_registry.ps1              (wrapper-launcher handler)
      5. lock_registry.ps1                (final locked handler state)
      6. install-control-panel.ps1        (top-level UI, last)

    Never hardcodes secrets: only paths/ports/switches are forwarded, no tokens.
.EXAMPLE
    pwsh -File install-all.ps1
.EXAMPLE
    pwsh -File install-all.ps1 -Uninstall
#>

param (
    [string]$BaseDir = 'F:\Jellyfin',
    [switch]$RegisterMcpTask,
    [string]$VersionDir = "",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsPrincipalRole]::Administrator)
}

function Test-Interactive {
    try {
        return [Environment]::UserInteractive -and (-not [Console]::IsInputRedirected)
    } catch { return $false }
}

if ([string]::IsNullOrWhiteSpace($VersionDir)) {
    $rootHint = $PSScriptRoot
    if ((Split-Path $rootHint -Leaf) -ieq 'scripts') { $rootHint = Split-Path $rootHint -Parent }
    $VersionDir = Join-Path $rootHint '.install-versions'
}

# F9: orchestrator preflight (pwsh version + installer files present).
if ($PSVersionTable.PSVersion -lt [version]'7.0') {
    throw ("pwsh 7.0+ is required (found {0}). Install PowerShell 7 and re-run." -f $PSVersionTable.PSVersion)
}
Write-Host ("[+] Preflight: pwsh {0} OK" -f $PSVersionTable.PSVersion) -ForegroundColor Green
if (-not (Test-Path -LiteralPath $BaseDir)) {
    Write-Host "[!] Preflight: BaseDir $BaseDir does not exist; child installers will report missing paths." -ForegroundColor Yellow
}

# F2: friendly admin note + single self-elevate offer (avoids one UAC prompt
# per child installer, since every child also self-elevates on demand).
if (-not (Test-IsAdmin)) {
    Write-Host "[!] install-all is not elevated. Child installers will each offer elevation," -ForegroundColor Yellow
    Write-Host "    or re-run this orchestrator from an elevated pwsh session to elevate once." -ForegroundColor Yellow
    if (Test-Interactive) {
        $answer = Read-Host '    Re-launch install-all as Administrator now? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($answer) -or ($answer -match '^(?i)y(es)?$')) {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                '-BaseDir', $BaseDir, '-VersionDir', $VersionDir)
            if ($RegisterMcpTask) { $argList += '-RegisterMcpTask' }
            if ($Uninstall) { $argList += '-Uninstall' }
            $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if (-not $pwsh) { $pwsh = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
            Start-Process -FilePath $pwsh -ArgumentList $argList -Verb RunAs
            exit 0
        }
    }
}

$steps = @(
    @{ File = 'install-rclone-service.ps1';      Stamp = 'install-rclone-service';      Args = @() },
    @{ File = 'create_rclone_mcp.ps1';            Stamp = 'create_rclone_mcp';            Args = @('-BaseDir', $BaseDir) },
    @{ File = 'register-potplayer-protocol.ps1'; Stamp = 'register-potplayer-protocol'; Args = @() },
    @{ File = 'update_registry.ps1';              Stamp = 'update_registry';              Args = @() },
    @{ File = 'lock_registry.ps1';                Stamp = 'lock_registry';                Args = @() },
    @{ File = 'install-control-panel.ps1';        Stamp = 'install-control-panel';        Args = @('-BaseDir', $BaseDir) }
)

if ($RegisterMcpTask) {
    $steps[1].Args += '-RegisterTask'
}
if ($Uninstall) {
    foreach ($s in $steps) { $s.Args += '-Uninstall' }
    [array]::Reverse($steps)  # uninstall in reverse dependency order
    Write-Host "=== Uninstalling full stack (reverse order) ===" -ForegroundColor Cyan
} else {
    Write-Host "=== Installing full stack (dependency order) ===" -ForegroundColor Cyan
}

foreach ($s in $steps) {
    $s.Args += @('-VersionDir', $VersionDir)
}

$results = @()
$failed = $false
foreach ($s in $steps) {
    $path = Join-Path $PSScriptRoot $s.File
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ("Orchestrator step missing: {0}" -f $path)
    }
    Write-Host ("--- Step: {0} {1} ---" -f $s.File, ($s.Args -join ' ')) -ForegroundColor Cyan
    & $PSScriptRoot\$($s.File) @($s.Args)
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    $results += [PSCustomObject]@{ Step = $s.File; ExitCode = $code }
    if ($code -ne 0) {
        Write-Host ("[ERROR] Step failed: {0} (exit {1}). Stopping." -f $s.File, $code) -ForegroundColor Red
        $failed = $true
        break
    }
    Write-Host ("[ok] {0}" -f $s.File) -ForegroundColor Green
}

# Post-run stamp audit (F8 verification across all installers).
Write-Host "--- Version stamp audit ---" -ForegroundColor Cyan
foreach ($s in $steps) {
    $stamp = Join-Path $VersionDir ("{0}.version.json" -f $s.Stamp)
    if ($Uninstall) {
        if (Test-Path -LiteralPath $stamp) {
            Write-Host ("[!] Stamp still present after uninstall: {0}" -f $stamp) -ForegroundColor Yellow
        } else {
            Write-Host ("[ok] Stamp removed: {0}" -f $s.Stamp) -ForegroundColor Green
        }
    } else {
        if (Test-Path -LiteralPath $stamp) {
            Write-Host ("[ok] Stamp present: {0}" -f $stamp) -ForegroundColor Green
        } else {
            Write-Host ("[!] Stamp missing: {0}" -f $stamp) -ForegroundColor Yellow
        }
    }
}

$results | Format-Table -AutoSize | Out-String | Write-Host
if ($failed) { exit 1 }
Write-Host ("[SUCCESS] install-all {0} complete (orchestrator v{1})." -f ($Uninstall ? 'uninstall' : 'install'), $ScriptVersion) -ForegroundColor Green
exit 0
