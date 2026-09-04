<#
.SYNOPSIS
    Thin compatibility shim for potplayer:// URL handling.
.DESCRIPTION
    Delegates all work to potplayer-launcher.ps1 (no duplicated launch logic).
    Keeps backward-compatible args: -RawUrl (positional) plus passthrough of
    -FullSeason / -Single and any remaining raw args.
.PARAMETER RawUrl
    Raw potplayer:// URL (positional, optional for compat).
.EXAMPLE
    pwsh -File PotPlayerLauncher.ps1 'potplayer://F:\Media\Movie.mkv'
    pwsh -File PotPlayerLauncher.ps1 -RawUrl 'potplayer://...' -Single
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$RawUrl = '',
    [switch]$FullSeason,
    [switch]$Single,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
)

$ErrorActionPreference = 'Stop'

function Resolve-Launcher {
    $candidates = @(
        (Join-Path $PSScriptRoot 'potplayer-launcher.ps1'),
        (Join-Path (Get-Location) 'potplayer-launcher.ps1'),
        (Join-Path $PSScriptRoot 'scripts/potplayer-launcher.ps1'),
        (Join-Path (Get-Location) 'scripts/potplayer-launcher.ps1'),
        'F:\Jellyfin\potplayer-launcher.ps1'
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

$launcher = Resolve-Launcher
if (-not $launcher) {
    Write-Error "potplayer-launcher.ps1 not found (searched PSSCriptRoot, cwd, scripts/)."
}

$forward = @()
if (-not [string]::IsNullOrWhiteSpace($RawUrl)) { $forward += $RawUrl }
if ($FullSeason) { $forward += '-FullSeason' }
if ($Single) { $forward += '-Single' }
if ($RemainingArgs -and $RemainingArgs.Count -gt 0) { $forward += $RemainingArgs }

& $launcher @forward
exit $LASTEXITCODE
