<#
.SYNOPSIS
  Stop-Jellyfin — stops ONLY supervisor-owned Jellyfin processes (PID file).

.DESCRIPTION
  Reads F:\Jellyfin\run\jellyfin.pid and stops that PID only after verifying
  it is still a live jellyfin process (Get-Process + CIM CommandLine match).
  Never blanket-kills unrelated jellyfin processes. Supports -WhatIf dry-run.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Continue'

$baseDir = 'F:\Jellyfin'
$runDir  = Join-Path $baseDir 'run'
$pidFile = Join-Path $runDir 'jellyfin.pid'
$logDir  = Join-Path $baseDir 'logs'
$supLog  = Join-Path $logDir 'supervisor.log'

function Write-StopLog {
  param([string]$Message, [string]$Level = 'INFO')
  try {
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $supLog -Value "[$ts] [$Level] Stop-Jellyfin: $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch { }
  Write-Host $Message
}

function Test-PidIsJellyfin {
  param([int]$PidValue)
  if ($PidValue -le 0) { return $false }
  try {
    $p = Get-Process -Id $PidValue -ErrorAction Stop
    if ($p.ProcessName -ne 'jellyfin') { return $false }
    try {
      $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $PidValue) -ErrorAction SilentlyContinue
      if ($null -eq $cim) { return $true }
      if ($cim.CommandLine -match 'jellyfin') { return $true }
      return $false
    } catch { return $true }
  } catch { return $false }
}

if ($WhatIfPreference) {
  Write-StopLog 'WHATIF: would stop supervisor-owned PID from F:\Jellyfin\run\jellyfin.pid only (no kill).'
  return
}

if (-not (Test-Path -LiteralPath $pidFile)) {
  Write-StopLog 'No supervisor-owned PID file (run\jellyfin.pid); refusing to kill unrelated jellyfin processes. Nothing stopped.' 'WARN'
  Write-Host 'No supervisor-owned Jellyfin PID file; nothing stopped (safety: will not kill foreign processes).'
  return
}

$raw = ''
try { $raw = (Get-Content -LiteralPath $pidFile -TotalCount 1 -ErrorAction Stop).Trim() } catch { $raw = '' }
$ownedPid = 0
if (-not ([int]::TryParse($raw, [ref]$ownedPid) -and $ownedPid -gt 0)) {
  Write-StopLog ("PID file unreadable ('{0}'); removing stale file, stopping nothing." -f $raw) 'WARN'
  try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue } catch { }
  return
}

if (-not (Test-PidIsJellyfin -PidValue $ownedPid)) {
  Write-StopLog ("Supervisor-owned PID {0} is dead or reused by non-jellyfin process; removing stale PID file, stopping nothing else." -f $ownedPid) 'WARN'
  try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue } catch { }
  return
}

if ($PSCmdlet.ShouldProcess("jellyfin PID $ownedPid (supervisor-owned)", 'Stop-Process')) {
  try {
    Stop-Process -Id $ownedPid -Force -ErrorAction Stop
    Write-StopLog ("Stopped supervisor-owned Jellyfin PID {0}." -f $ownedPid)
    Write-Host 'Jellyfin Server stopped (supervisor-owned PID {0}).' -f $ownedPid
  } catch {
    Write-StopLog (("Failed to stop supervisor-owned PID {0}: " -f $ownedPid) + $_.Exception.Message) 'ERROR'
    return
  } finally {
    try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue } catch { }
  }
}
