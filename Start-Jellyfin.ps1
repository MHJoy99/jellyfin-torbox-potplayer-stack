<#
.SYNOPSIS
  Start-Jellyfin — supervisor-aware Jellyfin starter (PID-owned, preflight, WhatIf).

.DESCRIPTION
  Baseline behavior preserved (F:\Jellyfin\server\jellyfin.exe with datadir/
  configdir/cachedir/logdir/webdir/ffmpeg). 10x additions:
  - Port preflight on 8096 (skip + log if already bound by live process).
  - Writes supervisor-owned PID file F:\Jellyfin\run\jellyfin.pid.
  - -WhatIf dry-run (SupportsShouldProcess).
  - Log rotation (10MB cap, keep 5) for supervisor.log.
  Never hardcodes secrets.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

$baseDir   = 'F:\Jellyfin'
$serverExe = Join-Path $baseDir 'server\jellyfin.exe'
$dataDir   = Join-Path $baseDir 'data'
$configDir = Join-Path $baseDir 'config'
$cacheDir  = Join-Path $baseDir 'cache'
$logDir    = Join-Path $baseDir 'logs'
$webDir    = Join-Path $baseDir 'server\jellyfin-web'
$ffmpegExe = Join-Path $baseDir 'server\ffmpeg.exe'
$runDir    = Join-Path $baseDir 'run'
$pidFile   = Join-Path $runDir 'jellyfin.pid'
$supLog    = Join-Path $logDir 'supervisor.log'
$LogMaxBytes  = 10MB
$LogKeepCount = 5

function Invoke-LogRotation {
  param([string]$Path = $supLog)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $fi -or $fi.Length -lt $LogMaxBytes) { return }
    for ($i = $LogKeepCount; $i -ge 1; $i--) {
      $src = if ($i -eq 1) { $Path } else { ("{0}.{1}" -f $Path, ($i - 1)) }
      $dst = ("{0}.{1}" -f $Path, $i)
      if (Test-Path -LiteralPath $src) {
        if ($i -eq $LogKeepCount -and (Test-Path -LiteralPath $dst)) {
          Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
      }
    }
  } catch { }
}

function Get-ListeningPid8096 {
  try {
    $lines = netstat -ano -p tcp 2>$null
    foreach ($ln in $lines) {
      $t = "$ln".Trim()
      if ($t -match '^TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0):8096\s+\S+\s+LISTENING\s+(\d+)\s*$') {
        return [int]$Matches[1]
      }
    }
  } catch { }
  return 0
}

function Write-StarterLog {
  param([string]$Message)
  try {
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    try { Invoke-LogRotation } catch { }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $supLog -Value "[$ts] [INFO] Start-Jellyfin: $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch { }
  Write-Host $Message
}

New-Item -ItemType Directory -Force -Path $dataDir, $configDir, $cacheDir, $logDir, (Join-Path $baseDir 'transcodes') | Out-Null
if (-not (Test-Path -LiteralPath $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }

if ($WhatIfPreference) {
  Write-StarterLog 'WHATIF: would preflight port 8096 and start server\jellyfin.exe (no process started).'
  return
}

# Port preflight before each start (skip + log if port already bound by live process).
$owner = Get-ListeningPid8096
if ($owner -gt 0) {
  try {
    $p = Get-Process -Id $owner -ErrorAction Stop
    Write-StarterLog ("PREFLIGHT jellyfin: port 8096 already bound by live PID {0} ({1}); skipping start." -f $owner, $p.ProcessName)
    try { Set-Content -LiteralPath $pidFile -Value ("$owner") -Encoding Ascii -Force } catch { }
    Write-Host "Jellyfin is already running (port 8096 owner PID: $owner)"
    exit 0
  } catch { }
}

$running = Get-Process -Name jellyfin -ErrorAction SilentlyContinue
if ($running) {
    Write-StarterLog ("Jellyfin process already running (PID: {0}); refreshing PID file, no new start." -f (($running.Id -join ', ')))
    try {
      $first = @($running)[0].Id
      Set-Content -LiteralPath $pidFile -Value ("$first") -Encoding Ascii -Force
    } catch { }
    Write-Host "Jellyfin is already running (PID: $($running.Id -join ', '))"
    exit 0
}

$arguments = @(
    '--datadir', $dataDir,
    '--configdir', $configDir,
    '--cachedir', $cacheDir,
    '--logdir', $logDir,
    '--webdir', $webDir,
    '--ffmpeg', $ffmpegExe
)

if ($PSCmdlet.ShouldProcess($serverExe, 'Start Jellyfin Server')) {
  $proc = Start-Process -FilePath $serverExe -ArgumentList $arguments -WorkingDirectory (Join-Path $baseDir 'server') -WindowStyle Hidden -PassThru
  try { Set-Content -LiteralPath $pidFile -Value ("$($proc.Id)") -Encoding Ascii -Force } catch { }
  Write-StarterLog ("Started Jellyfin Server on F:\ drive (supervisor-owned PID {0})." -f $proc.Id)
  Write-Host "Started Jellyfin Server on F:\ drive."
}
