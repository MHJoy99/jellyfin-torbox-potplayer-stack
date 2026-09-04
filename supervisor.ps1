<#
.SYNOPSIS
  MediaStackSupervisor — single-instance ordered supervisor + watchdog for the Jellyfin media stack.

.DESCRIPTION
  Audit basis (schtasks /Query, conceptual):
    - \TorboxProxy                       -> proxy  127.0.0.1:8888  (pythonw F:\Jellyfin\server\torbox-proxy.py)
    - \MediaServer_PotPlayerBridge       -> bridge 127.0.0.1:18099 (pythonw E:\MediaServer\tools\potplayer_http_bridge.py)
    - \Jellyfin Control Panel            -> panel  127.0.0.1:18080 (pythonw F:\Jellyfin\control-panel\control_panel.py)
    - \MediaServer_TorboxSmartSync       -> SYNC ONLY (keep enabled, do not supervise)
    - \MediaServer_GoogleDriveLibrarySync-> SYNC ONLY (keep enabled, do not supervise)
    - \Mount Google Shared Drive R       -> gdrive F:\Media (rclone mount gdrive-media:, NSSM RcloneGdriveMount)
    - mount-torbox.ps1                   -> torboxmount T:\ (E:\MediaServer\mount-torbox.ps1, NO scheduled task)

  Ordered start chain with health gates (abort on first failure, explicit log):
    gdrive (Test-Path F:\Media)
      -> torboxmount (Test-Path T:\ else start mount-torbox.ps1)
      -> proxy  (wait http://127.0.0.1:8888/health  30s)
      -> bridge (wait http://127.0.0.1:18099/health 10s, requires proxy OK)
      -> jellyfin (http://127.0.0.1:8096/System/Info/Public)
      -> panel  (http://127.0.0.1:18080/health)

  Watchdog: every 15s -> http_probe + Test-Path + PID-alive; restart with backoff
  (3x fast, then 60s cooldown). Log: F:\Jellyfin\logs\supervisor.log

  Dedupe: keep the LISTENING pid for 8888/18099 (same idea as control_panel.py
  dedupe_proxy); kill zombie bridge parent holding no port.

  Single instance: named mutex Global\MediaStackSupervisor (Run mode holds it).
  PID files: F:\Jellyfin\run\<svc>.pid  (gdrive, torboxmount, proxy, bridge, jellyfin, panel, supervisor)

.USAGE
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Run
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Start
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Stop
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Status
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode ForensicsBundle
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Run -WhatIf   (dry-run whole cycle)
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Start -WhatIf (dry-run ordered start)

.FEATURES-10X
  1) Per-service restart backoff (30s, 60s, 300s) via Get-BackoffDelay.
  2) Port preflight before each start (Test-PortPreflight; skip + log if live owner).
  3) Per-service env refresh from registry each cycle (Sync-EnvFromRegistry).
  4) Stop-Jellyfin.ps1 stops only supervisor-owned PIDs (PID file) — see that file.
  5) Log rotation (10MB cap, keep 5) via Invoke-LogRotation.
  6) New-ForensicsBundle command (zip logs + state + task list).
  7) -WhatIf dry-run for whole supervisor cycle (SupportsShouldProcess).
  8) Service dependency order via config array ($ServiceOrder / $ServiceDependencies).
  9) Crash-loop alert threshold (5 restarts/10m) via Register-RestartHistory.
  10) Graceful Ctrl+C shutdown (CancelKeyPress -> stop loop, release mutexes).

.NOTES
  Creates no scheduled task and kills nothing on load. All side effects only run
  inside the explicitly invoked -Mode. Standardized interpreter:
    C:\Users\Administrator\AppData\Local\Programs\Python\Python311\pythonw.exe
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateSet('Run', 'Start', 'Stop', 'Status', 'ForensicsBundle')]
  [string]$Mode = 'Run'
)

$ErrorActionPreference = 'Continue'

# F7: -WhatIf dry-run for whole supervisor cycle. When -WhatIf is passed,
# $WhatIfPreference is $true; every mutating helper consults Test-WhatIfMode
# and logs "WHATIF: would ..." instead of starting/killing anything.
function Test-WhatIfMode {
  return [bool]$WhatIfPreference
}

function Write-WhatIfLog {
  param([string]$Message)
  Write-SupLog ("WHATIF: would " + $Message) 'INFO'
}

# Refresh secrets from persistent store: child processes inherit THIS process's
# env snapshot, which predates any Machine/User env changes (e.g. agent shells
# started before TORBOX_API_KEY was set). Registry reads are always live.
# NEVER hardcode secrets: this block only copies the live registry value into
# the current process env so supervised children inherit it.
function Sync-EnvFromRegistry {
  # F3: Per-service env refresh from registry each cycle. Called at the top of
  # every watchdog iteration, ordered start, and single-service restart so a
  # rotated TORBOX_API_KEY is picked up without restarting the supervisor.
  # Safe to call before Write-SupLog exists (bootstrap): falls back to Write-Host.
  $logFn = (Get-Command Write-SupLog -ErrorAction SilentlyContinue)
  try {
    $liveKey = [Environment]::GetEnvironmentVariable('TORBOX_API_KEY', 'Machine')
    if (-not $liveKey) { $liveKey = [Environment]::GetEnvironmentVariable('TORBOX_API_KEY', 'User') }
    if ($liveKey) {
      if ($env:TORBOX_API_KEY -ne $liveKey) {
        $env:TORBOX_API_KEY = $liveKey
        $msg = 'ENV: refreshed TORBOX_API_KEY from registry (live value applied).'
        if ($logFn) { Write-SupLog $msg } else { Write-Host $msg }
      }
    } else {
      $msg = 'ENV: TORBOX_API_KEY not found in Machine/User registry; keeping process value.'
      if ($logFn) { Write-SupLog $msg 'WARN' } else { Write-Host $msg }
    }
  } catch {
    $msg = ('ENV: registry refresh failed: ' + $_.Exception.Message)
    if ($logFn) { Write-SupLog $msg 'WARN' } else { Write-Host $msg }
  }
}

try {
  Sync-EnvFromRegistry
} catch {}

# ---------------------------------------------------------------- fixed paths
$BaseDir          = 'F:\Jellyfin'
$RunDir           = Join-Path $BaseDir 'run'
$LogDir           = Join-Path $BaseDir 'logs'
$LogFile          = Join-Path $LogDir 'supervisor.log'
$MutexName        = 'Global\MediaStackSupervisor'

$PythonW          = 'C:\Users\Administrator\AppData\Local\Programs\Python\Python311\pythonw.exe'
$ProxyScript      = 'F:\Jellyfin\server\torbox-proxy.py'
$ProxyWorkDir     = 'F:\Jellyfin\server'
$BridgeScript     = 'E:\MediaServer\tools\potplayer_http_bridge.py'
$BridgeWorkDir    = 'E:\MediaServer\tools'
$PanelScript      = 'F:\Jellyfin\control-panel\control_panel.py'
$PanelWorkDir     = 'F:\Jellyfin\control-panel'
$TorboxMountScript= 'E:\MediaServer\mount-torbox.ps1'
$GdriveMountScript= 'E:\MediaServer\mount-gdrive.ps1'
$NssmExe          = 'F:\Jellyfin\server\nssm.exe'
$NssmService      = 'RcloneGdriveMount'

$JellyfinExe      = 'F:\Jellyfin\server\jellyfin.exe'
$JellyfinWorkDir  = 'F:\Jellyfin\server'
$JellyfinDataDir  = 'F:\Jellyfin\data'
$JellyfinCfgDir   = 'F:\Jellyfin\config'
$JellyfinCacheDir = 'F:\Jellyfin\cache'
$JellyfinWebDir   = 'F:\Jellyfin\server\jellyfin-web'
$JellyfinFfmpeg   = 'F:\Jellyfin\server\ffmpeg.exe'

$GdrivePath       = 'F:\Media'
$TorboxPath       = 'T:\'
$ProxyHealth      = 'http://127.0.0.1:8888/health'
$BridgeHealth     = 'http://127.0.0.1:18099/health'
$JellyfinHealth   = 'http://127.0.0.1:8096/System/Info/Public'
$PanelHealth      = 'http://127.0.0.1:18080/health'

$WatchdogSeconds  = 15
$ProxyWaitSeconds = 30
$BridgeWaitSeconds= 10
$JellyfinWaitSecs = 60
$PanelWaitSeconds = 15
$MountWaitSeconds = 30

# F8: Service dependency order via config array. $ServiceOrder is the single
# source of truth for start order; Stop-StackReverse iterates its reverse and
# the watchdog iterates it in order. $ServiceDependencies declares hard gates
# (bridge requires proxy). To reorder, edit this array only.
$ServiceOrder = @('gdrive', 'torboxmount', 'proxy', 'bridge', 'jellyfin', 'panel')
$ServiceDependencies = @{
  gdrive      = @()
  torboxmount = @('gdrive')
  proxy       = @('torboxmount')
  bridge      = @('proxy')
  jellyfin    = @('bridge')
  panel       = @('jellyfin')
}
# Port map for F2 preflight (mounts have no TCP port -> 0 = skip preflight).
$ServicePorts = @{ gdrive = 0; torboxmount = 0; proxy = 8888; bridge = 18099; jellyfin = 8096; panel = 18080 }
# Backwards-compat alias (older helpers referenced $SvcList).
$SvcList = $ServiceOrder

# F1: Per-service restart backoff (30s, 60s, 300s). Tier selected by
# consecutive failure count: 1st->30s, 2nd->60s, 3rd+->300s. See Get-BackoffDelay.
$BackoffTiersSec = @(30, 60, 300)
$script:FailCount   = @{ gdrive = 0; torboxmount = 0; proxy = 0; bridge = 0; jellyfin = 0; panel = 0 }
$script:LastRestart = @{ gdrive = [datetime]::MinValue; torboxmount = [datetime]::MinValue; proxy = [datetime]::MinValue; bridge = [datetime]::MinValue; jellyfin = [datetime]::MinValue; panel = [datetime]::MinValue }

# F9: Crash-loop alert threshold (5 restarts/10m). Sliding window of restart
# timestamps per service; prominent log when threshold is hit.
$CrashLoopMaxRestarts = 5
$CrashLoopWindowMin   = 10
$script:RestartHistory = @{ gdrive = @(); torboxmount = @(); proxy = @(); bridge = @(); jellyfin = @(); panel = @() }

function Get-BackoffDelay {
  # F1 helper: map consecutive FailCount -> 30s / 60s / 300s.
  param([string]$Svc)
  $fails = 0
  try { $fails = [int]$script:FailCount[$Svc] } catch { $fails = 0 }
  if ($fails -le 1) { return [int]$BackoffTiersSec[0] }
  if ($fails -eq 2) { return [int]$BackoffTiersSec[1] }
  return [int]$BackoffTiersSec[2]
}

function Register-RestartHistory {
  # F9 helper: append now, prune outside 10m window, emit prominent alert at >=5.
  param([string]$Svc)
  try {
    $now = Get-Date
    $hist = @()
    try { $hist = @($script:RestartHistory[$Svc]) } catch { $hist = @() }
    $hist += $now
    $cutoff = $now.AddMinutes(-$CrashLoopWindowMin)
    $hist = @($hist | Where-Object { $_ -ge $cutoff })
    $script:RestartHistory[$Svc] = $hist
    if ($hist.Count -ge $CrashLoopMaxRestarts) {
      $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
      $banner = ('!' * 70)
      Write-SupLog $banner 'ERROR'
      Write-SupLog ("!!!!!!!! CRASH-LOOP ALERT: service '{0}' restarted {1}x in last {2}m (threshold {3}/{4}m) at {4} — investigate now; backoff continues." -f $Svc, $hist.Count, $CrashLoopWindowMin, $CrashLoopMaxRestarts, $CrashLoopWindowMin, $stamp) 'ERROR'
      Write-SupLog $banner 'ERROR'
    }
    return $hist.Count
  } catch { return 0 }
}

# dupe forensics: per-parent counter for non-listening bridge/proxy dupes (memory-only, surfaced via FORENSICS log lines)
$script:DupeParentCount = @{}

# ---------------------------------------------------------------- logging
# F5: Log rotation (10MB cap, keep 5). Checked on every Write-SupLog call and
# also callable directly. Keeps supervisor.log + .1 .. .5 (newest = .1).
$LogMaxBytes = 10MB
$LogKeepCount = 5

function Invoke-LogRotation {
  try {
    if (-not (Test-Path -LiteralPath $LogFile)) { return }
    $fi = Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
    if ($null -eq $fi) { return }
    if ($fi.Length -lt $LogMaxBytes) { return }
    for ($i = $LogKeepCount; $i -ge 1; $i--) {
      $src = if ($i -eq 1) { $LogFile } else { ("{0}.{1}" -f $LogFile, ($i - 1)) }
      $dst = ("{0}.{1}" -f $LogFile, $i)
      try {
        if (Test-Path -LiteralPath $src) {
          if ($i -eq $LogKeepCount -and (Test-Path -LiteralPath $dst)) {
            Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
          }
          Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
      } catch { }
    }
    try { New-Item -ItemType File -Force -Path $LogFile | Out-Null } catch { }
    try {
      $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
      Add-Content -LiteralPath $LogFile -Value "[$ts] [INFO] LOG ROTATION: rotated at 10MB cap, keeping $LogKeepCount archives." -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
  } catch { }
}

function Write-SupLog {
  param([string]$Message, [string]$Level = 'INFO')
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) {
      New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    }
    try { Invoke-LogRotation } catch { }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
  } catch { }
}

# ---------------------------------------------------------------- pid files
function Get-PidFile {
  param([string]$Svc)
  return (Join-Path $RunDir ("$Svc.pid"))
}

function Write-PidFile {
  param([string]$Svc, [int]$PidValue)
  try {
    if (-not (Test-Path -LiteralPath $RunDir)) {
      New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
    }
    Set-Content -LiteralPath (Get-PidFile -Svc $Svc) -Value ("$PidValue") -Encoding Ascii -Force
  } catch { }
}

function Read-PidFile {
  param([string]$Svc)
  try {
    $p = Get-PidFile -Svc $Svc
    if (Test-Path -LiteralPath $p) {
      $raw = (Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction SilentlyContinue).Trim()
      $n = 0
      if ([int]::TryParse($raw, [ref]$n) -and $n -gt 0) { return $n }
    }
  } catch { }
  return 0
}

function Remove-PidFile {
  param([string]$Svc)
  try {
    $p = Get-PidFile -Svc $Svc
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
  } catch { }
}

function Test-PidAlive {
  param([int]$PidValue, [string]$MatchPattern = '')
  if ($PidValue -le 0) { return $false }
  try {
    $proc = Get-Process -Id $PidValue -ErrorAction Stop
    if ([string]::IsNullOrEmpty($MatchPattern)) { return $true }
    $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $PidValue) -ErrorAction SilentlyContinue
    if ($null -eq $cim) { return $true } # process exists, CIM hiccup -> treat as alive
    if ($cim.CommandLine -match $MatchPattern) { return $true }
    # PID reused by unrelated process
    return $false
  } catch {
    return $false
  }
}

# ---------------------------------------------------------------- http probe
function Invoke-HttpProbe {
  param([string]$Url, [int]$TimeoutSec = 3)
  try {
    $r = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return $true }
    return $false
  } catch {
    return $false
  }
}

function Wait-HttpHealthy {
  param([string]$Url, [int]$TimeoutSec = 30, [string]$Label = '')
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Invoke-HttpProbe -Url $Url -TimeoutSec 3) { return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Wait-PathHealthy {
  param([string]$LiteralPath, [int]$TimeoutSec = 30)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $LiteralPath) { return $true }
    Start-Sleep -Seconds 1
  }
  return (Test-Path -LiteralPath $LiteralPath)
}

# ---------------------------------------------------------------- netstat / CIM helpers
function Get-ListeningPid {
  <#
    Returns the owning PID listening on 127.0.0.1:<Port> (panel-style regex).
    For 8096 Jellyfin binds 0.0.0.0, so accept both 127.0.0.1 and 0.0.0.0.
    For 18080 accept the same tolerance. For 8888/18099 keep strict 127.0.0.1
    semantics like control_panel.py dedupe_proxy.
  #>
  param([int]$Port)
  try {
    $lines = netstat -ano -p tcp 2>$null
    foreach ($ln in $lines) {
      $t = "$ln".Trim()
      if ($Port -eq 8096 -or $Port -eq 18080) {
        if ($t -match ('^TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0):' + $Port + '\s+\S+\s+LISTENING\s+(\d+)\s*$')) {
          return [int]$Matches[1]
        }
      } else {
        if ($t -match ('^TCP\s+127\.0\.0\.1:' + $Port + '\s+0\.0\.0\.0:0\s+LISTENING\s+(\d+)\s*$')) {
          return [int]$Matches[1]
        }
      }
    }
  } catch { }
  return 0
}

function Get-MatchingProcesses {
  param([string]$NameRegex, [string]$CmdRegex)
  try {
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ($_.Name -match $NameRegex) -and ($_.CommandLine -match $CmdRegex)
    }
    return @($all)
  } catch {
    return @()
  }
}

function Test-PortPreflight {
  # F2: Port preflight before each start. If $Port is already bound by a live
  # process, skip the start and log it — never double-bind. Returns $true when
  # the port is already owned (caller should skip), $false when free/unknown.
  param([string]$Svc, [int]$Port)
  if ($Port -le 0) { return $false }
  try {
    $owner = Get-ListeningPid -Port $Port
    if ($owner -gt 0) {
      $alive = $false
      try { $alive = [bool](Get-Process -Id $owner -ErrorAction Stop) } catch { $alive = $false }
      if ($alive) {
        Write-SupLog ("PREFLIGHT ${Svc}: port {0} already bound by live PID {1}; skipping start." -f $Port, $owner) 'WARN'
        try { Write-PidFile -Svc $Svc -PidValue $owner } catch { }
        return $true
      } else {
        Write-SupLog ("PREFLIGHT ${Svc}: stale LISTENING entry for port {0} (PID {1} dead); proceeding with start." -f $Port, $owner) 'WARN'
        return $false
      }
    }
  } catch { }
  return $false
}

function Write-DupeForensics {
  <#
    Cheap spawner forensics for a non-listening duplicate: targeted CIM queries
    ONLY for the dupe PID + its parent PID (no full scan). Logs ParentProcessId,
    parent CommandLine (first 150 chars, single-line), dupe CreationDate, and a
    per-parent counter keyed "$Svc::$Ppid" (memory-only, surfaced in the log).
  #>
  param([string]$Svc, [int]$DupePid)
  try {
    $dupe = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $DupePid) -ErrorAction SilentlyContinue
    if ($null -eq $dupe) {
      Write-SupLog "FORENSICS ${Svc} dupe pid=${DupePid} ppid=? parentCmd=<cim-miss> created=? count=?" 'WARN'
      return
    }
    $ppid = [int]$dupe.ParentProcessId
    $created = '?'
    try {
      if ($dupe.CreationDate) {
        $created = ([Management.ManagementDateTimeConverter]::ToDateTime($dupe.CreationDate)).ToString('yyyy-MM-dd HH:mm:ss')
      }
    } catch {
      $created = "$($dupe.CreationDate)"
    }
    $parentCmd = '<exited>'
    try {
      if ($ppid -gt 0) {
        $par = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $ppid) -ErrorAction SilentlyContinue
        if ($null -ne $par -and $par.CommandLine) { $parentCmd = "$($par.CommandLine)" }
      }
    } catch { }
    $parentCmd = ($parentCmd -replace '\s+', ' ').Trim()
    if ($parentCmd.Length -gt 150) { $parentCmd = $parentCmd.Substring(0, 150) }
    $key = ("{0}::{1}" -f $Svc, $ppid)
    $n = 1
    try {
      if ($script:DupeParentCount.ContainsKey($key)) { $n = [int]$script:DupeParentCount[$key] + 1 }
      $script:DupeParentCount[$key] = $n
    } catch { }
    Write-SupLog "FORENSICS ${Svc} dupe pid=${DupePid} ppid=${ppid} parentCmd=${parentCmd} created=${created} count=${n}" 'WARN'
  } catch { }
}

function Invoke-DedupePortService {
  <#
    Keep the LISTENING pid for $Port; kill every other process matching $CmdRegex.
    If no listener exists:
      - bridge: a lone parent holding no port is a zombie -> kill it so the
        watchdog can start one fresh listener (explicit log).
      - proxy: same treatment (keeps the two ports symmetric).
    Returns $true when it killed anything.
  #>
  param([string]$Svc, [string]$CmdRegex, [int]$Port)
  $killedAny = $false
  $procs = Get-MatchingProcesses -NameRegex '^(python|pythonw)\.exe$' -CmdRegex $CmdRegex
  if ($procs.Count -eq 0) { return $false }
  $listenPid = Get-ListeningPid -Port $Port
  if ($listenPid -gt 0) {
    $victims = @($procs | Where-Object { $_.ProcessId -ne $listenPid })
    foreach ($v in $victims) {
      Write-DupeForensics -Svc $Svc -DupePid ([int]$v.ProcessId)
      try { Stop-Process -Id $v.ProcessId -Force -ErrorAction SilentlyContinue; $killedAny = $true } catch { }
      Write-SupLog "DEDUPE ${Svc}: kept listening PID $listenPid, killed extra PID $($v.ProcessId)." 'WARN'
    }
    if ($procs.Count -gt 1 -and $victims.Count -eq 0) {
      Write-SupLog "DEDUPE ${Svc}: $($procs.Count) rows matched but all report PID $listenPid (CIM/netstat race); no kill." 'INFO'
    }
    return $killedAny
  }
  # No listener on the port.
  if ($Svc -eq 'bridge') {
    foreach ($v in $procs) {
      Write-DupeForensics -Svc $Svc -DupePid ([int]$v.ProcessId)
      try { Stop-Process -Id $v.ProcessId -Force -ErrorAction SilentlyContinue; $killedAny = $true } catch { }
      Write-SupLog "DEDUPE bridge: killed zombie parent PID $($v.ProcessId) holding no port (18099 has no listener)." 'WARN'
    }
    return $killedAny
  }
  if ($procs.Count -gt 1) {
    foreach ($v in $procs) {
      Write-DupeForensics -Svc $Svc -DupePid ([int]$v.ProcessId)
      try { Stop-Process -Id $v.ProcessId -Force -ErrorAction SilentlyContinue; $killedAny = $true } catch { }
    }
    $ids = (($procs | ForEach-Object { $_.ProcessId }) -join ', ')
    Write-SupLog "DEDUPE ${Svc}: no listener on 127.0.0.1:${Port}; killed ${($procs.Count)} zombie(s): $ids. Watchdog will restart one." 'WARN'
    return $true
  }
  # Single non-listening proxy process: leave it for the health-gate restart path
  # (avoids flapping during cold start), but make it visible.
  Write-SupLog "DEDUPE ${Svc}: PID $($procs[0].ProcessId) present but 127.0.0.1:${Port} has no listener yet (starting or wedged)." 'INFO'
  return $false
}

function Invoke-DedupeAll {
  $a = Invoke-DedupePortService -Svc 'proxy'  -CmdRegex 'torbox-proxy\.py'            -Port 8888
  $b = Invoke-DedupePortService -Svc 'bridge' -CmdRegex 'potplayer_http_bridge\.py'  -Port 18099
  return ($a -or $b)
}

function Test-HttpHealthyConfirmed {
  <#
    Transient-tolerant re-probe: first OK wins; otherwise retry with delay.
    Prevents a single flapped probe from triggering a duplicate start
    (live 03:22 bridge race: listener 20212 alive, one failed probe spawned 23256).
  #>
  param([string]$Url, [string]$Label, [int]$Attempts = 3, [int]$DelaySec = 2)
  for ($i = 1; $i -le $Attempts; $i++) {
    if (Invoke-HttpProbe -Url $Url -TimeoutSec 3) {
      if ($i -gt 1) { Write-SupLog "GATE ${Label}: re-probe $i/$Attempts OK (transient recovered, no start needed)." }
      return $true
    }
    if ($i -lt $Attempts) {
      Write-SupLog "GATE ${Label}: probe $i/$Attempts failed (possible transient); re-probing in ${DelaySec}s." 'WARN'
      Start-Sleep -Seconds $DelaySec
    }
  }
  return $false
}

function Invoke-ListenerGuardDedupe {
  <#
    Post-start guard: keep only the LISTENING pid on 127.0.0.1:<Port>
    (verified via netstat-style TCP table 127.0.0.1:<port> LISTENING),
    kill non-listening duplicates so we never leave 2 PIDs where one holds
    no port. Returns the surviving listening PID (0 if none).
  #>
  param([string]$Svc, [string]$CmdRegex, [int]$Port)
  Start-Sleep -Seconds 1 # settle so netstat TCP table reflects the fresh bind
  $preLp = Get-ListeningPid -Port $Port
  if ($preLp -le 0 -and (Invoke-HttpProbe -Url $(if ($Svc -eq 'proxy') { $ProxyHealth } else { $BridgeHealth }) -TimeoutSec 3)) {
    Write-SupLog "GUARD ${Svc}: health OK but netstat TCP table shows no 127.0.0.1:${Port} LISTENING yet; re-checking in 2s before dedupe." 'WARN'
    Start-Sleep -Seconds 2
    $preLp = Get-ListeningPid -Port $Port
  }
  Invoke-DedupePortService -Svc $Svc -CmdRegex $CmdRegex -Port $Port | Out-Null
  $lp = Get-ListeningPid -Port $Port
  if ($lp -gt 0) {
    $left = @(Get-MatchingProcesses -NameRegex '^(python|pythonw)\.exe$' -CmdRegex $CmdRegex)
    $extra = @($left | Where-Object { $_.ProcessId -ne $lp })
    if ($extra.Count -gt 0) {
      foreach ($v in $extra) {
        Write-DupeForensics -Svc $Svc -DupePid ([int]$v.ProcessId)
        try { Stop-Process -Id $v.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        Write-SupLog "GUARD ${Svc}: post-start sweep killed non-listening duplicate PID $($v.ProcessId); kept LISTENING PID $lp on 127.0.0.1:${Port}." 'WARN'
      }
      $lp = Get-ListeningPid -Port $Port
    } else {
      Write-SupLog "GUARD ${Svc}: single PID $lp holds 127.0.0.1:${Port} LISTENING (netstat TCP table); no duplicates."
    }
  } else {
    Write-SupLog "GUARD ${Svc}: no LISTENING PID on 127.0.0.1:${Port} after start (netstat TCP table empty)." 'WARN'
  }
  return $lp
}

# ---------------------------------------------------------------- health predicates
function Test-GdriveHealthy {
  if (-not (Test-Path -LiteralPath $GdrivePath)) { return $false }
  return $true
}

function Test-TorboxMountHealthy {
  if (-not (Test-Path -LiteralPath $TorboxPath)) { return $false }
  return $true
}

function Test-ProxyHealthy  { return (Invoke-HttpProbe -Url $ProxyHealth -TimeoutSec 3) }
function Test-BridgeHealthy { return (Invoke-HttpProbe -Url $BridgeHealth -TimeoutSec 3) }
function Test-JellyfinHealthy { return (Invoke-HttpProbe -Url $JellyfinHealth -TimeoutSec 4) }
function Test-PanelHealthy  { return (Invoke-HttpProbe -Url $PanelHealth -TimeoutSec 3) }

# ---------------------------------------------------------------- starters (each writes its .pid file on success)
function Start-Gdrive {
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) { Write-WhatIfLog "start gdrive (NSSM RcloneGdriveMount / mount-gdrive.ps1)"; return $true }
  if (Test-GdriveHealthy) {
    Write-SupLog 'GATE gdrive: OK (F:\Media present).'
    $rcloneG = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount gdrive-media'
    if ($rcloneG.Count -gt 0) { Write-PidFile -Svc 'gdrive' -PidValue $rcloneG[0].ProcessId }
    return $true
  }
  Write-SupLog 'GATE gdrive: F:\Media missing; attempting NSSM start RcloneGdriveMount.' 'WARN'
  try {
    if (Test-Path -LiteralPath $NssmExe) {
      $p = Start-Process -FilePath $NssmExe -ArgumentList @('start', $NssmService) -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
      if ($p) { try { $p.WaitForExit(15000) } catch { } }
    } else {
      Write-SupLog "GATE gdrive: nssm.exe missing at $NssmExe; falling back to mount-gdrive.ps1." 'WARN'
    }
  } catch { }
  if (Wait-PathHealthy -LiteralPath $GdrivePath -TimeoutSec 15) {
    Write-SupLog 'GATE gdrive: OK after NSSM start.'
    $rcloneG = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount gdrive-media'
    if ($rcloneG.Count -gt 0) { Write-PidFile -Svc 'gdrive' -PidValue $rcloneG[0].ProcessId }
    return $true
  }
  if (Test-Path -LiteralPath $GdriveMountScript) {
    Write-SupLog 'GATE gdrive: still missing; launching E:\MediaServer\mount-gdrive.ps1.' 'WARN'
    try {
      Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $GdriveMountScript + '"')) -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    } catch { }
    if (Wait-PathHealthy -LiteralPath $GdrivePath -TimeoutSec $MountWaitSeconds) {
      Write-SupLog 'GATE gdrive: OK after mount-gdrive.ps1.'
      $rcloneG = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount gdrive-media'
      if ($rcloneG.Count -gt 0) { Write-PidFile -Svc 'gdrive' -PidValue $rcloneG[0].ProcessId }
      return $true
    }
  }
  Write-SupLog 'GATE gdrive: FAILED (F:\Media still missing).' 'ERROR'
  return $false
}

function Start-TorboxMount {
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) { Write-WhatIfLog "start torboxmount (mount-torbox.ps1 -> T:\)"; return $true }
  if (Test-TorboxMountHealthy) {
    Write-SupLog 'GATE torboxmount: OK (T:\ present).'
    $rcloneT = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount torbox'
    if ($rcloneT.Count -gt 0) { Write-PidFile -Svc 'torboxmount' -PidValue $rcloneT[0].ProcessId }
    return $true
  }
  if (-not (Test-Path -LiteralPath $TorboxMountScript)) {
    Write-SupLog "GATE torboxmount: FAILED (T:\ missing and mount script not found: $TorboxMountScript)." 'ERROR'
    return $false
  }
  Write-SupLog 'GATE torboxmount: T:\ missing; starting E:\MediaServer\mount-torbox.ps1.' 'WARN'
  try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $TorboxMountScript + '"')) -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
  } catch {
    Write-SupLog ("GATE torboxmount: FAILED to launch mount script: " + $_.Exception.Message) 'ERROR'
    return $false
  }
  if (Wait-PathHealthy -LiteralPath $TorboxPath -TimeoutSec $MountWaitSeconds) {
    Write-SupLog 'GATE torboxmount: OK after mount-torbox.ps1 (T:\ present).'
    $rcloneT = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount torbox'
    if ($rcloneT.Count -gt 0) { Write-PidFile -Svc 'torboxmount' -PidValue $rcloneT[0].ProcessId }
    return $true
  }
  Write-SupLog 'GATE torboxmount: FAILED (T:\ still missing after mount-torbox.ps1).' 'ERROR'
  return $false
}

function Start-Proxy {
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) { Write-WhatIfLog "start proxy (pythonw torbox-proxy.py :8888)"; return $true }
  if (Test-PortPreflight -Svc 'proxy' -Port 8888) { return $true }
  Write-SupLog 'GATE proxy: [1/7] initial health check (http://127.0.0.1:8888/health).'
  $preOk = Test-ProxyHealthy
  Write-SupLog ("GATE proxy: [2/7] pre-start dedupe (keep LISTENING pid on 127.0.0.1:8888; initial check healthy={0})." -f $preOk)
  Invoke-DedupePortService -Svc 'proxy' -CmdRegex 'torbox-proxy\.py' -Port 8888 | Out-Null
  Write-SupLog 'GATE proxy: [3/7] re-probe (transient-tolerant); start ONLY if still failing.'
  if (Test-HttpHealthyConfirmed -Url $ProxyHealth -Label 'proxy') {
    Write-SupLog 'GATE proxy: OK (re-probe healthy; no start needed).'
    $lp = Get-ListeningPid -Port 8888
    if ($lp -gt 0) { Write-PidFile -Svc 'proxy' -PidValue $lp }
    return $true
  }
  if (-not (Test-Path -LiteralPath $PythonW)) {
    Write-SupLog "GATE proxy: FAILED (pythonw missing: $PythonW)." 'ERROR'
    return $false
  }
  if (-not (Test-Path -LiteralPath $ProxyScript)) {
    Write-SupLog "GATE proxy: FAILED (script missing: $ProxyScript)." 'ERROR'
    return $false
  }
  Write-SupLog 'GATE proxy: [4/7] still failing after re-probe; starting pythonw torbox-proxy.py.' 'WARN'
  try {
    $p = Start-Process -FilePath $PythonW -ArgumentList @('"' + $ProxyScript + '"') -WorkingDirectory $ProxyWorkDir -WindowStyle Hidden -PassThru -ErrorAction Stop
    Write-PidFile -Svc 'proxy' -PidValue $p.Id
    Write-SupLog ("GATE proxy: launched PID {0}; [5/7] waiting for health up to {1}s." -f $p.Id, $ProxyWaitSeconds)
  } catch {
    Write-SupLog ("GATE proxy: FAILED to launch: " + $_.Exception.Message) 'ERROR'
    return $false
  }
  $waitOk = Wait-HttpHealthy -Url $ProxyHealth -TimeoutSec $ProxyWaitSeconds -Label 'proxy'
  Write-SupLog ("GATE proxy: [6/7] post-start dedupe keeping LISTENING pid (netstat TCP 127.0.0.1:8888 LISTENING; wait healthy={0})." -f $waitOk)
  $lp2 = Invoke-ListenerGuardDedupe -Svc 'proxy' -CmdRegex 'torbox-proxy\.py' -Port 8888
  Write-SupLog ("GATE proxy: [7/7] final health assert (wait={0}, listenPid={1})." -f $waitOk, $lp2)
  if ($waitOk -and (Test-ProxyHealthy) -and ($lp2 -gt 0)) {
    Write-SupLog ("GATE proxy: OK after start (health 8888, LISTENING PID {0})." -f $lp2)
    Write-PidFile -Svc 'proxy' -PidValue $lp2
    return $true
  }
  Write-SupLog 'GATE proxy: FAILED (http://127.0.0.1:8888/health not OK within 30s, or no LISTENING pid).' 'ERROR'
  return $false
}

function Start-Bridge {
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) { Write-WhatIfLog "start bridge (pythonw potplayer_http_bridge.py :18099, requires proxy)"; return $true }
  if (Test-PortPreflight -Svc 'bridge' -Port 18099) { return $true }
  if (-not (Test-ProxyHealthy)) {
    Write-SupLog 'GATE bridge: ABORT (requires proxy OK; 127.0.0.1:8888/health is down). Start proxy first.' 'ERROR'
    return $false
  }
  Write-SupLog 'GATE bridge: [1/7] initial health check (http://127.0.0.1:18099/health, proxy OK).'
  $preOk = Test-BridgeHealthy
  Write-SupLog ("GATE bridge: [2/7] pre-start dedupe (keep LISTENING pid on 127.0.0.1:18099; initial check healthy={0})." -f $preOk)
  Invoke-DedupePortService -Svc 'bridge' -CmdRegex 'potplayer_http_bridge\.py' -Port 18099 | Out-Null
  Write-SupLog 'GATE bridge: [3/7] re-probe (transient-tolerant); start ONLY if still failing.'
  if (Test-HttpHealthyConfirmed -Url $BridgeHealth -Label 'bridge') {
    Write-SupLog 'GATE bridge: OK (re-probe healthy, proxy OK; no start needed).'
    $lp = Get-ListeningPid -Port 18099
    if ($lp -gt 0) { Write-PidFile -Svc 'bridge' -PidValue $lp }
    return $true
  }
  if (-not (Test-Path -LiteralPath $PythonW)) {
    Write-SupLog "GATE bridge: FAILED (pythonw missing: $PythonW)." 'ERROR'
    return $false
  }
  if (-not (Test-Path -LiteralPath $BridgeScript)) {
    Write-SupLog "GATE bridge: FAILED (script missing: $BridgeScript)." 'ERROR'
    return $false
  }
  Write-SupLog 'GATE bridge: [4/7] still failing after re-probe; starting pythonw potplayer_http_bridge.py (proxy OK).' 'WARN'
  try {
    $p = Start-Process -FilePath $PythonW -ArgumentList @('"' + $BridgeScript + '"') -WorkingDirectory $BridgeWorkDir -WindowStyle Hidden -PassThru -ErrorAction Stop
    Write-PidFile -Svc 'bridge' -PidValue $p.Id
    Write-SupLog ("GATE bridge: launched PID {0}; [5/7] waiting for health up to {1}s." -f $p.Id, $BridgeWaitSeconds)
  } catch {
    Write-SupLog ("GATE bridge: FAILED to launch: " + $_.Exception.Message) 'ERROR'
    return $false
  }
  $waitOk = Wait-HttpHealthy -Url $BridgeHealth -TimeoutSec $BridgeWaitSeconds -Label 'bridge'
  Write-SupLog ("GATE bridge: [6/7] post-start dedupe keeping LISTENING pid (netstat TCP 127.0.0.1:18099 LISTENING; wait healthy={0})." -f $waitOk)
  $lp2 = Invoke-ListenerGuardDedupe -Svc 'bridge' -CmdRegex 'potplayer_http_bridge\.py' -Port 18099
  Write-SupLog ("GATE bridge: [7/7] final health assert (wait={0}, listenPid={1})." -f $waitOk, $lp2)
  if ($waitOk -and (Test-BridgeHealthy) -and ($lp2 -gt 0)) {
    Write-SupLog ("GATE bridge: OK after start (health 18099, LISTENING PID {0})." -f $lp2)
    Write-PidFile -Svc 'bridge' -PidValue $lp2
    return $true
  }
  Write-SupLog 'GATE bridge: FAILED (http://127.0.0.1:18099/health not OK within 10s, or no LISTENING pid).' 'ERROR'
  return $false
}

function Start-Jellyfin {
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) { Write-WhatIfLog "start jellyfin (server\jellyfin.exe :8096)"; return $true }
  if (Test-PortPreflight -Svc 'jellyfin' -Port 8096) { return $true }
  if (Test-JellyfinHealthy) {
    Write-SupLog 'GATE jellyfin: OK (8096 /System/Info/Public).'
    $jf = Get-Process -Name 'jellyfin' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($jf) { Write-PidFile -Svc 'jellyfin' -PidValue $jf.Id }
    return $true
  }
  if (-not (Test-Path -LiteralPath $JellyfinExe)) {
    Write-SupLog "GATE jellyfin: FAILED (missing: $JellyfinExe)." 'ERROR'
    return $false
  }
  foreach ($d in @($JellyfinDataDir, $JellyfinCfgDir, $JellyfinCacheDir, $LogDir, (Join-Path $BaseDir 'transcodes'))) {
    try { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } } catch { }
  }
  $args = @('--datadir', $JellyfinDataDir, '--configdir', $JellyfinCfgDir, '--cachedir', $JellyfinCacheDir, '--logdir', $LogDir, '--webdir', $JellyfinWebDir, '--ffmpeg', $JellyfinFfmpeg)
  Write-SupLog 'GATE jellyfin: starting server\jellyfin.exe.' 'WARN'
  try {
    $p = Start-Process -FilePath $JellyfinExe -ArgumentList $args -WorkingDirectory $JellyfinWorkDir -WindowStyle Hidden -PassThru -ErrorAction Stop
    Write-PidFile -Svc 'jellyfin' -PidValue $p.Id
  } catch {
    Write-SupLog ("GATE jellyfin: FAILED to launch: " + $_.Exception.Message) 'ERROR'
    return $false
  }
  if (Wait-HttpHealthy -Url $JellyfinHealth -TimeoutSec $JellyfinWaitSecs -Label 'jellyfin') {
    Write-SupLog 'GATE jellyfin: OK after start (8096).'
    return $true
  }
  Write-SupLog 'GATE jellyfin: FAILED (8096 /System/Info/Public not OK within 60s).' 'ERROR'
  return $false
}

function Start-Panel {
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) { Write-WhatIfLog "start panel (pythonw control_panel.py :18080)"; return $true }
  if (Test-PortPreflight -Svc 'panel' -Port 18080) { return $true }
  if (Test-PanelHealthy) {
    Write-SupLog 'GATE panel: OK (http://127.0.0.1:18080/health).'
    $lp = Get-ListeningPid -Port 18080
    if ($lp -gt 0) { Write-PidFile -Svc 'panel' -PidValue $lp }
    return $true
  }
  if (-not (Test-Path -LiteralPath $PythonW)) {
    Write-SupLog "GATE panel: FAILED (pythonw missing: $PythonW)." 'ERROR'
    return $false
  }
  if (-not (Test-Path -LiteralPath $PanelScript)) {
    Write-SupLog "GATE panel: FAILED (script missing: $PanelScript)." 'ERROR'
    return $false
  }
  Write-SupLog 'GATE panel: starting pythonw control_panel.py.' 'WARN'
  try {
    $p = Start-Process -FilePath $PythonW -ArgumentList @('"' + $PanelScript + '"') -WorkingDirectory $PanelWorkDir -WindowStyle Hidden -PassThru -ErrorAction Stop
    Write-PidFile -Svc 'panel' -PidValue $p.Id
  } catch {
    Write-SupLog ("GATE panel: FAILED to launch: " + $_.Exception.Message) 'ERROR'
    return $false
  }
  if (Wait-HttpHealthy -Url $PanelHealth -TimeoutSec $PanelWaitSeconds -Label 'panel') {
    Write-SupLog 'GATE panel: OK after start (18080).'
    $lp = Get-ListeningPid -Port 18080
    if ($lp -gt 0) { Write-PidFile -Svc 'panel' -PidValue $lp }
    return $true
  }
  Write-SupLog 'GATE panel: FAILED (http://127.0.0.1:18080/health not OK within 15s).' 'ERROR'
  return $false
}

# ---------------------------------------------------------------- ordered chain
function Start-OrderedStack {
  # F8: iterates $ServiceOrder config array; F3 refreshes env each gate.
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) {
    Write-SupLog ("WHATIF: dry-run ordered start: " + ($ServiceOrder -join ' -> ') + " (no processes started).")
    foreach ($s in $ServiceOrder) { Write-WhatIfLog ("start {0} (dependency order)" -f $s) }
    return $true
  }
  Write-SupLog ('ORDERED START: ' + ($ServiceOrder -join ' -> ') + '.')
  Invoke-DedupeAll | Out-Null

  if (-not (Start-Gdrive)) {
    Write-SupLog 'ABORT: ordered start chain halted at gdrive (F:\Media not available). Downstream services NOT started.' 'ERROR'
    return $false
  }
  if (-not (Start-TorboxMount)) {
    Write-SupLog 'ABORT: ordered start chain halted at torboxmount (T:\ not available). Downstream services NOT started.' 'ERROR'
    return $false
  }
  if (-not (Start-Proxy)) {
    Write-SupLog 'ABORT: ordered start chain halted at proxy (127.0.0.1:8888/health failed after 30s). Downstream services NOT started.' 'ERROR'
    return $false
  }
  if (-not (Start-Bridge)) {
    Write-SupLog 'ABORT: ordered start chain halted at bridge (127.0.0.1:18099/health failed after 10s, or proxy not OK). Downstream services NOT started.' 'ERROR'
    return $false
  }
  if (-not (Start-Jellyfin)) {
    Write-SupLog 'ABORT: ordered start chain halted at jellyfin (8096 failed). Panel NOT started.' 'ERROR'
    return $false
  }
  if (-not (Start-Panel)) {
    Write-SupLog 'ABORT: ordered start chain halted at panel (18080 failed). Stack is otherwise up.' 'ERROR'
    return $false
  }
  Write-SupLog 'ORDERED START: complete. All 6 gates healthy.'
  return $true
}

# ---------------------------------------------------------------- stop / status
function Stop-OneService {
  param([string]$Svc)
  if (Test-WhatIfMode) { Write-WhatIfLog ("stop {0}" -f $Svc); return }
  switch ($Svc) {
    'panel' {
      $rows = Get-MatchingProcesses -NameRegex '^(python|pythonw)\.exe$' -CmdRegex 'control_panel\.py'
      foreach ($r in $rows) { try { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
      $pf = Read-PidFile -Svc 'panel'
      if ($pf -gt 0) { try { Stop-Process -Id $pf -Force -ErrorAction SilentlyContinue } catch { } }
      Remove-PidFile -Svc 'panel'
      Write-SupLog 'STOP panel.'
    }
    'jellyfin' {
      try { Get-Process -Name 'jellyfin' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
      $pf = Read-PidFile -Svc 'jellyfin'
      if ($pf -gt 0) { try { Stop-Process -Id $pf -Force -ErrorAction SilentlyContinue } catch { } }
      Remove-PidFile -Svc 'jellyfin'
      Write-SupLog 'STOP jellyfin.'
    }
    'bridge' {
      $rows = Get-MatchingProcesses -NameRegex '^(python|pythonw)\.exe$' -CmdRegex 'potplayer_http_bridge\.py'
      foreach ($r in $rows) { try { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
      Remove-PidFile -Svc 'bridge'
      Write-SupLog 'STOP bridge.'
    }
    'proxy' {
      $rows = Get-MatchingProcesses -NameRegex '^(python|pythonw)\.exe$' -CmdRegex 'torbox-proxy\.py'
      foreach ($r in $rows) { try { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
      Remove-PidFile -Svc 'proxy'
      Write-SupLog 'STOP proxy.'
    }
    'torboxmount' {
      $rows = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount torbox'
      foreach ($r in $rows) { try { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
      Remove-PidFile -Svc 'torboxmount'
      Write-SupLog 'STOP torboxmount (rclone mount torbox).'
    }
    'gdrive' {
      try {
        if (Test-Path -LiteralPath $NssmExe) {
          $p = Start-Process -FilePath $NssmExe -ArgumentList @('stop', $NssmService) -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
          if ($p) { try { $p.WaitForExit(15000) } catch { } }
        }
      } catch { }
      $rows = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount gdrive-media'
      foreach ($r in $rows) { try { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
      Remove-PidFile -Svc 'gdrive'
      Write-SupLog 'STOP gdrive (nssm RcloneGdriveMount + rclone mount gdrive-media).'
    }
  }
}

function Stop-StackReverse {
  if (Test-WhatIfMode) {
    $rev = @($ServiceOrder.Clone()); [array]::Reverse($rev)
    Write-SupLog ("WHATIF: dry-run stop reverse order: " + ($rev -join ' -> ') + " (nothing stopped).")
    return
  }
  $rev = @($ServiceOrder.Clone()); [array]::Reverse($rev)
  Write-SupLog ('STOP: reverse order ' + ($rev -join ' -> ') + '.')
  foreach ($s in $rev) {
    Stop-OneService -Svc $s
  }
  Write-SupLog 'STOP: complete.'
}

function Get-StackStatus {
  $rows = @()
  # gdrive
  $gPid = Read-PidFile -Svc 'gdrive'
  $gProcs = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount gdrive-media'
  $gPids = ($gProcs | ForEach-Object { $_.ProcessId }) -join ','
  $rows += [PSCustomObject]@{ Service = 'gdrive'; Check = 'Test-Path F:\Media'; PathOk = (Test-Path -LiteralPath $GdrivePath); PidFile = $gPid; PidAlive = (Test-PidAlive -PidValue $gPid -MatchPattern 'mount gdrive-media'); Procs = $gPids; ListenPid = '-'; Healthy = (Test-GdriveHealthy) }
  # torboxmount
  $tPid = Read-PidFile -Svc 'torboxmount'
  $tProcs = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount torbox'
  $tPids = ($tProcs | ForEach-Object { $_.ProcessId }) -join ','
  $rows += [PSCustomObject]@{ Service = 'torboxmount'; Check = 'Test-Path T:\'; PathOk = (Test-Path -LiteralPath $TorboxPath); PidFile = $tPid; PidAlive = (Test-PidAlive -PidValue $tPid -MatchPattern 'mount torbox'); Procs = $tPids; ListenPid = '-'; Healthy = (Test-TorboxMountHealthy) }
  # proxy
  $pPid = Read-PidFile -Svc 'proxy'
  $pProcs = Get-MatchingProcesses -NameRegex '^(python|pythonw)\.exe$' -CmdRegex 'torbox-proxy\.py'
  $pPids = ($pProcs | ForEach-Object { $_.ProcessId }) -join ','
  $pListen = Get-ListeningPid -Port 8888
  $rows += [PSCustomObject]@{ Service = 'proxy'; Check = 'http://127.0.0.1:8888/health'; PathOk = (Test-ProxyHealthy); PidFile = $pPid; PidAlive = (Test-PidAlive -PidValue $pPid -MatchPattern 'torbox-proxy\.py'); Procs = $pPids; ListenPid = $pListen; Healthy = (Test-ProxyHealthy) }
  # bridge
  $bPid = Read-PidFile -Svc 'bridge'
  $bProcs = Get-MatchingProcesses -NameRegex '^(python|pythonw)\.exe$' -CmdRegex 'potplayer_http_bridge\.py'
  $bPids = ($bProcs | ForEach-Object { $_.ProcessId }) -join ','
  $bListen = Get-ListeningPid -Port 18099
  $rows += [PSCustomObject]@{ Service = 'bridge'; Check = 'http://127.0.0.1:18099/health'; PathOk = (Test-BridgeHealthy); PidFile = $bPid; PidAlive = (Test-PidAlive -PidValue $bPid -MatchPattern 'potplayer_http_bridge\.py'); Procs = $bPids; ListenPid = $bListen; Healthy = (Test-BridgeHealthy) }
  # jellyfin
  $jPid = Read-PidFile -Svc 'jellyfin'
  $jProcs = @(Get-Process -Name 'jellyfin' -ErrorAction SilentlyContinue)
  $jPids = ($jProcs | ForEach-Object { $_.Id }) -join ','
  $jListen = Get-ListeningPid -Port 8096
  $rows += [PSCustomObject]@{ Service = 'jellyfin'; Check = 'http://127.0.0.1:8096/System/Info/Public'; PathOk = (Test-JellyfinHealthy); PidFile = $jPid; PidAlive = (Test-PidAlive -PidValue $jPid -MatchPattern 'jellyfin'); Procs = $jPids; ListenPid = $jListen; Healthy = (Test-JellyfinHealthy) }
  # panel
  $cPid = Read-PidFile -Svc 'panel'
  $cProcs = Get-MatchingProcesses -NameRegex '^(python|pythonw)\.exe$' -CmdRegex 'control_panel\.py'
  $cPids = ($cProcs | ForEach-Object { $_.ProcessId }) -join ','
  $cListen = Get-ListeningPid -Port 18080
  $rows += [PSCustomObject]@{ Service = 'panel'; Check = 'http://127.0.0.1:18080/health'; PathOk = (Test-PanelHealthy); PidFile = $cPid; PidAlive = (Test-PidAlive -PidValue $cPid -MatchPattern 'control_panel\.py'); Procs = $cPids; ListenPid = $cListen; Healthy = (Test-PanelHealthy) }
  return $rows
}

function New-ForensicsBundle {
  # F6: New-ForensicsBundle command (zip logs + state + task list).
  # Collects supervisor logs (+rotated), PID files, status snapshot, and
  # scheduled-task list into F:\Jellyfin\logs\forensics-<timestamp>.zip.
  [CmdletBinding(SupportsShouldProcess = $true)]
  param([string]$OutPath = '')
  try { Sync-EnvFromRegistry } catch { }
  if ([string]::IsNullOrWhiteSpace($OutPath)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutPath = Join-Path $LogDir ("forensics-" + $stamp + ".zip")
  }
  if ($WhatIfPreference -or (Test-WhatIfMode)) { Write-WhatIfLog ("create forensics bundle at {0}" -f $OutPath); return $OutPath }
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sup-forensics-" + (Get-Date -Format 'yyyyMMddHHmmss'))
    try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    # 1) logs (main + rotated .1..5)
    try {
      Get-ChildItem -LiteralPath $LogDir -Filter 'supervisor.log*' -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tmp $_.Name) -Force -ErrorAction SilentlyContinue
      }
    } catch { }
    # 2) state: PID files + status snapshot
    try {
      $runCopy = Join-Path $tmp 'run'
      New-Item -ItemType Directory -Force -Path $runCopy | Out-Null
      Get-ChildItem -LiteralPath $RunDir -Filter '*.pid' -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runCopy $_.Name) -Force -ErrorAction SilentlyContinue
      }
    } catch { }
    try {
      $status = Get-StackStatus | Format-Table -AutoSize | Out-String -Width 220
      Set-Content -LiteralPath (Join-Path $tmp 'status.txt') -Value $status -Encoding UTF8 -Force -ErrorAction SilentlyContinue
      try { Get-StackStatus | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $tmp 'status.json') -Encoding UTF8 -Force -ErrorAction SilentlyContinue } catch { }
    } catch { }
    # 3) task list (scheduled tasks for the stack; best-effort)
    try {
      $tasks = schtasks /Query /FO LIST /V 2>&1 | Out-String
      Set-Content -LiteralPath (Join-Path $tmp 'schtasks.txt') -Value $tasks -Encoding UTF8 -Force -ErrorAction SilentlyContinue
    } catch { }
    try {
      $procs = Get-Process -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, WS | Format-Table -AutoSize | Out-String -Width 200
      Set-Content -LiteralPath (Join-Path $tmp 'tasklist.txt') -Value $procs -Encoding UTF8 -Force -ErrorAction SilentlyContinue
    } catch { }
    try {
      if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue }
      Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $OutPath -Force -ErrorAction Stop
    } catch {
      Write-SupLog ("FORENSICS: bundle zip failed: " + $_.Exception.Message) 'ERROR'
      return ''
    } finally {
      try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-SupLog ("FORENSICS: bundle written to {0} (logs + state + task list)." -f $OutPath)
    return $OutPath
  } catch {
    Write-SupLog ("FORENSICS: unexpected error: " + $_.Exception.Message) 'ERROR'
    return ''
  }
}

# ---------------------------------------------------------------- watchdog helpers
function Test-ServiceHealthy {
  param([string]$Svc)
  switch ($Svc) {
    'gdrive'      { return (Test-GdriveHealthy) }
    'torboxmount' { return (Test-TorboxMountHealthy) }
    'proxy'       { return (Test-ProxyHealthy) }
    'bridge'      { return (Test-BridgeHealthy) }
    'jellyfin'    { return (Test-JellyfinHealthy) }
    'panel'       { return (Test-PanelHealthy) }
  }
  return $false
}

function Test-ServicePidAlive {
  param([string]$Svc)
  $pf = Read-PidFile -Svc $Svc
  if ($pf -le 0) { return $false }
  switch ($Svc) {
    'gdrive'      { return (Test-PidAlive -PidValue $pf -MatchPattern 'mount gdrive-media') }
    'torboxmount' { return (Test-PidAlive -PidValue $pf -MatchPattern 'mount torbox') }
    'proxy'       { return (Test-PidAlive -PidValue $pf -MatchPattern 'torbox-proxy\.py') }
    'bridge'      { return (Test-PidAlive -PidValue $pf -MatchPattern 'potplayer_http_bridge\.py') }
    'jellyfin'    { return (Test-PidAlive -PidValue $pf -MatchPattern 'jellyfin') }
    'panel'       { return (Test-PidAlive -PidValue $pf -MatchPattern 'control_panel\.py') }
  }
  return $false
}

function Restart-OneService {
  param([string]$Svc)
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) { Write-WhatIfLog ("restart {0}" -f $Svc); return $true }
  switch ($Svc) {
    'gdrive'      { return (Start-Gdrive) }
    'torboxmount' { return (Start-TorboxMount) }
    'proxy'       { return (Start-Proxy) }
    'bridge'      { return (Start-Bridge) }
    'jellyfin'    { return (Start-Jellyfin) }
    'panel'       { return (Start-Panel) }
  }
  return $false
}

function Invoke-WatchdogOnce {
  # F3: refresh env from registry each cycle (live TORBOX_API_KEY for children).
  try { Sync-EnvFromRegistry } catch { }
  if (Test-WhatIfMode) {
    Write-SupLog ("WHATIF: dry-run watchdog cycle over [" + ($ServiceOrder -join ', ') + "] (no restarts).")
    foreach ($w in $ServiceOrder) {
      try { $h = Test-ServiceHealthy -Svc $w } catch { $h = $false }
      Write-WhatIfLog ("check {0} (healthy={1})" -f $w, $h)
    }
    return
  }
  # Dedupe first so duplicate listeners do not look like healthy redundancy.
  Invoke-DedupeAll | Out-Null
  # F8: iterate config array $ServiceOrder (dependency order).
  foreach ($svc in $ServiceOrder) {
    # F3: per-service env refresh from registry each cycle.
    try { Sync-EnvFromRegistry } catch { }
    $healthy = Test-ServiceHealthy -Svc $svc
    # PID-alive is a secondary signal: if the pid file points at a dead/reused
    # PID while the health gate is also down, that confirms a crash. If health
    # is up, refresh the pid file from the live listener/process instead.
    $pidAlive = Test-ServicePidAlive -Svc $svc
    if ($healthy) {
      if ($script:FailCount[$svc] -ne 0) {
        Write-SupLog "WATCHDOG ${svc}: recovered (fail counter reset)."
      }
      $script:FailCount[$svc] = 0
      # Refresh pid file from live state (keeps PID-alive meaningful).
      switch ($svc) {
        'proxy'  { $lp = Get-ListeningPid -Port 8888;  if ($lp -gt 0) { Write-PidFile -Svc 'proxy' -PidValue $lp } }
        'bridge' { $lp = Get-ListeningPid -Port 18099; if ($lp -gt 0) { Write-PidFile -Svc 'bridge' -PidValue $lp } }
        'panel'  { $lp = Get-ListeningPid -Port 18080; if ($lp -gt 0) { Write-PidFile -Svc 'panel' -PidValue $lp } }
        'jellyfin' {
          $jf = Get-Process -Name 'jellyfin' -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($jf) { Write-PidFile -Svc 'jellyfin' -PidValue $jf.Id }
        }
        'gdrive' {
          $g = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount gdrive-media' | Select-Object -First 1
          if ($g) { Write-PidFile -Svc 'gdrive' -PidValue $g.ProcessId }
        }
        'torboxmount' {
          $t = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount torbox' | Select-Object -First 1
          if ($t) { Write-PidFile -Svc 'torboxmount' -PidValue $t.ProcessId }
        }
      }
      continue
    }

    # F8: ordered dependency holds in watchdog too (generic + explicit bridge rule).
    $depsBlocked = $false
    try {
      $deps = @()
      if ($ServiceDependencies.ContainsKey($svc)) { $deps = @($ServiceDependencies[$svc]) }
      foreach ($d in $deps) {
        try { if (-not (Test-ServiceHealthy -Svc $d)) { $depsBlocked = $true; break } } catch { }
      }
    } catch { }
    if ($depsBlocked) {
      Write-SupLog ("WATCHDOG ${svc}: unhealthy but dependency down; deferring restart until upstream recovers.") 'WARN'
      continue
    }
    # Back-compat explicit rule (bridge waits for proxy).
    if ($svc -eq 'bridge' -and -not (Test-ProxyHealthy)) {
      Write-SupLog 'WATCHDOG bridge: unhealthy but proxy is also down; deferring bridge restart until proxy recovers.' 'WARN'
      continue
    }

    $script:FailCount[$svc] = [int]$script:FailCount[$svc] + 1
    $fails = [int]$script:FailCount[$svc]
    # F1: Per-service restart backoff (30s, 60s, 300s).
    $backoff = Get-BackoffDelay -Svc $svc
    $now = Get-Date
    $last = $script:LastRestart[$svc]
    $shouldRestart = $false
    $why = ''
    if ($last -eq [datetime]::MinValue) {
      $shouldRestart = $true
      $why = "first failure (fail #$fails, backoff ${backoff}s tier)"
    } else {
      $elapsed = ($now - $last).TotalSeconds
      if ($elapsed -ge $backoff) {
        $shouldRestart = $true
        $why = "backoff elapsed ($([int]$elapsed)s >= ${backoff}s, fail #$fails)"
      } else {
        $wait = [int]($backoff - $elapsed)
        Write-SupLog ("WATCHDOG ${svc}: still down (fail #$fails, pidAlive=$pidAlive); backoff tier ${backoff}s: waiting ${wait}s before next restart.") 'WARN'
        continue
      }
    }

    Write-SupLog ("WATCHDOG ${svc}: unhealthy (pidAlive=$pidAlive); restarting ($why).") 'WARN'
    $ok = Restart-OneService -Svc $svc
    $script:LastRestart[$svc] = Get-Date
    # F9: crash-loop tracking (5 restarts/10m) with prominent log.
    try { Register-RestartHistory -Svc $svc | Out-Null } catch { }
    if ($ok) {
      Write-SupLog "WATCHDOG ${svc}: restart OK."
      $script:FailCount[$svc] = 0
    } else {
      Write-SupLog "WATCHDOG ${svc}: restart FAILED; will retry with backoff." 'ERROR'
    }
  }
}

function Start-WatchdogLoop {
  # F10: Graceful Ctrl+C shutdown — CancelKeyPress sets shutdown flag, loop
  # exits cleanly, timer stops, mutexes released by caller finally block.
  $script:ShutdownRequested = $false
  $cancelHandler = $null
  try {
    $cancelHandler = [System.ConsoleCancelEventHandler]{
      param($sender, $e)
      $e.Cancel = $true
      $script:ShutdownRequested = $true
    }
    try { [Console]::add_CancelKeyPress($cancelHandler) } catch { }
  } catch { }
  Write-SupLog ("WATCHDOG: loop every ${WatchdogSeconds}s (http_probe + Test-Path + PID-alive; backoff 30s/60s/300s). Log: $LogFile (Ctrl+C for graceful shutdown)")
  try {
    while (-not $script:ShutdownRequested) {
      try {
        Invoke-WatchdogOnce
      } catch [System.Management.Automation.PipelineStoppedException] {
        Write-SupLog 'WATCHDOG: pipeline stopped (Ctrl+C); shutting down gracefully.' 'WARN'
        break
      } catch {
        Write-SupLog ("WATCHDOG: iteration error: " + $_.Exception.Message) 'ERROR'
      }
      if (Test-WhatIfMode) {
        Write-SupLog 'WHATIF: single dry-run cycle complete; exiting watchdog loop.'
        break
      }
      # Sleep in 1s slices so Ctrl+C stops the timer promptly.
      for ($i = 0; $i -lt $WatchdogSeconds; $i++) {
        if ($script:ShutdownRequested) { break }
        Start-Sleep -Seconds 1
      }
    }
  } finally {
    try { if ($cancelHandler) { [Console]::remove_CancelKeyPress($cancelHandler) } } catch { }
    Write-SupLog 'WATCHDOG: timer stopped; exiting loop (graceful shutdown).'
  }
}

# ---------------------------------------------------------------- dispatch
try {
  if (-not (Test-Path -LiteralPath $RunDir)) { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }
  if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
} catch { }

switch ($Mode) {
  'Status' {
    $rows = Get-StackStatus
    $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    Write-SupLog 'STATUS: reported.'
    return
  }
  'ForensicsBundle' {
    Write-SupLog 'MODE ForensicsBundle: collecting logs + state + task list.'
    $bundle = New-ForensicsBundle
    if ($bundle) { Write-Host ("Forensics bundle: {0}" -f $bundle) }
    return
  }
  'Stop' {
    Write-SupLog 'MODE Stop: requested.'
    Stop-StackReverse
    try { Remove-PidFile -Svc 'supervisor' } catch { }
    return
  }
  'Start' {
    Write-SupLog 'MODE Start: ordered start once (no watchdog loop).'
    $ok = Start-OrderedStack
    if (-not $ok) { exit 1 }
    return
  }
  'Run' {
    $mtx = $null
    $owned = $false
    $supMutex2 = $null
    $supOwned2 = $false
    try {
      $mtx = New-Object System.Threading.Mutex($false, $MutexName)
      $owned = $mtx.WaitOne(0)
    } catch {
      Write-SupLog ("RUN: mutex error (" + $_.Exception.Message + "); exiting.") 'ERROR'
      exit 2
    }
    if (-not $owned) {
      Write-SupLog ("RUN: another instance already holds " + $MutexName + "; exiting (single-instance).") 'ERROR'
      try { $mtx.Dispose() } catch { }
      exit 2
    }
    # F10: second shutdown mutex so Ctrl+C path visibly releases all mutexes.
    try {
      $supMutex2 = New-Object System.Threading.Mutex($false, 'Global\MediaStackSupervisor_Shutdown')
      $supOwned2 = $supMutex2.WaitOne(0)
    } catch { }
    # F10: graceful Ctrl+C shutdown — CancelKeyPress requests shutdown instead
    # of killing mid-restart; watchdog timer stops, finally releases mutexes.
    $runCancel = $null
    try {
      $runCancel = [System.ConsoleCancelEventHandler]{
        param($sender, $e)
        $e.Cancel = $true
        $script:ShutdownRequested = $true
        try { Write-SupLog 'RUN: Ctrl+C received; graceful shutdown requested (timer will stop, mutexes released).' 'WARN' } catch { }
      }
      try { [Console]::add_CancelKeyPress($runCancel) } catch { }
    } catch { }
    try {
      Write-PidFile -Svc 'supervisor' -PidValue $PID
      Write-SupLog ("RUN: acquired " + $MutexName + " (supervisor PID $PID). Ordered start + watchdog.")
      $ok = Start-OrderedStack
      if (-not $ok) {
        Write-SupLog 'RUN: ordered start aborted; entering watchdog anyway (it will keep retrying with backoff).' 'WARN'
      }
      try {
        Start-WatchdogLoop
      } catch [System.Management.Automation.PipelineStoppedException] {
        Write-SupLog 'RUN: PipelineStopped (Ctrl+C); shutting down gracefully.' 'WARN'
      }
    } finally {
      # F10: stop timer (watchdog loop already exited), release mutexes.
      try { if ($runCancel) { [Console]::remove_CancelKeyPress($runCancel) } } catch { }
      try { Remove-PidFile -Svc 'supervisor' } catch { }
      try {
        if ($owned) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
      } catch { }
      try {
        if ($supOwned2) { $supMutex2.ReleaseMutex() }
        if ($supMutex2) { $supMutex2.Dispose() }
      } catch { }
      Write-SupLog 'RUN: graceful shutdown complete (timer stopped, mutexes released), exiting.'
    }
  }
}
