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
    - mount-torbox.ps1                   -> torboxmount T:\ (E:\MediaServer\mount-torbox.ps1 via interactive task MediaServer_TorboxMount)

  Ordered start chain with health gates (abort on hard failure; defer
  Session-1-only dependencies until interactive logon, explicit log):
    gdrive (Test-Path F:\Media)
      -> torboxmount (headless authority: live rclone 'mount torbox' process + RC http://127.0.0.1:5572/rc/noop; T:\ Test-Path is session-scoped and never a Session-0 failure criterion)
      -> proxy  (wait http://127.0.0.1:8888/health  30s)
      -> bridge (wait http://127.0.0.1:18099/health 10s, requires proxy OK)
      -> jellyfin (http://127.0.0.1:8096/System/Info/Public)
      -> panel  (http://127.0.0.1:18080/health)

  Watchdog: every 15s -> http_probe + path/process checks + PID-alive; restart
  with backoff (3x fast, then 60s cooldown). Pre-logon TorBox/bridge failures
  are deferred quietly. Log: F:\Jellyfin\logs\supervisor.log

  Dedupe: keep the LISTENING pid for 8888/18099 (same idea as control_panel.py
  dedupe_proxy); kill zombie bridge parent holding no port.

  Single instance: named mutex Global\MediaStackSupervisor (Run mode holds it).
  PID files: F:\Jellyfin\run\<svc>.pid  (gdrive, torboxmount, proxy, bridge, jellyfin, panel, supervisor)

.USAGE
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Run
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Start
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Stop
  pwsh -NoProfile -ExecutionPolicy Bypass -File F:\Jellyfin\supervisor.ps1 -Mode Status

.NOTES
  Creates no scheduled task and kills nothing on load. All side effects only run
  inside the explicitly invoked -Mode. Standardized interpreter:
    C:\Users\Administrator\AppData\Local\Programs\Python\Python311\pythonw.exe
#>
param(
  [ValidateSet('Run', 'Start', 'Stop', 'Status', 'Forensics')]
  [string]$Mode = 'Run'
)

$ErrorActionPreference = 'Continue'

# Refresh secrets from persistent store: child processes inherit THIS process's
# env snapshot, which predates any Machine/User env changes (e.g. agent shells
# started before TORBOX_API_KEY was set). Registry reads are always live.
try {
    $liveKey = [Environment]::GetEnvironmentVariable('TORBOX_API_KEY', 'Machine')
    if (-not $liveKey) { $liveKey = [Environment]::GetEnvironmentVariable('TORBOX_API_KEY', 'User') }
    if ($liveKey) { $env:TORBOX_API_KEY = $liveKey }
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
$TorboxRcNoop     = 'http://127.0.0.1:5572/rc/noop'
$TorboxMountTaskName = 'MediaServer_TorboxMount'
$TorboxMountWaitSeconds = 120
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

$SvcList = @('gdrive', 'torboxmount', 'proxy', 'bridge', 'jellyfin', 'panel')

# backoff state: 3x fast restart, then 60s cooldown
$script:FailCount   = @{ gdrive = 0; torboxmount = 0; proxy = 0; bridge = 0; jellyfin = 0; panel = 0 }
$script:LastRestart = @{ gdrive = [datetime]::MinValue; torboxmount = [datetime]::MinValue; proxy = [datetime]::MinValue; bridge = [datetime]::MinValue; jellyfin = [datetime]::MinValue; panel = [datetime]::MinValue }
$script:DeferredState  = @{ torboxmount = $false; bridge = $false }
$script:DeferredLogged = @{ torboxmount = $false; bridge = $false }

# dupe forensics: per-parent counter for non-listening bridge/proxy dupes (memory-only, surfaced via FORENSICS log lines)
$script:DupeParentCount = @{}

# ---------------------------------------------------------------- logging
function Write-SupLog {
  param([string]$Message, [string]$Level = 'INFO')
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) {
      New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try {
      # Log rotation: 10MB cap, keep 5 generations (supervisor.log.1..5).
      if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue).Length -gt 10MB)) {
        for ($g = 4; $g -ge 1; $g--) {
          $src = "$LogFile.$g"
          $dst = "$LogFile." + ($g + 1)
          if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue }
        }
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force -ErrorAction SilentlyContinue
      }
    } catch { }
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
  } catch { }
}

# PERF PACK R001-R020: supervisor watchdog efficiency (no secrets; probe/process-cache tuning).
# R001 cache netstat output per watchdog pass (one spawn serves all ports).
$script:NetstatCache = @{ Stamp = [datetime]::MinValue; Lines = @() }
$script:NetstatTtlSec = 10  # R002 10s TTL matches panel CIM TTL (fewer netstat spawns)
$script:CimCache = @{ Stamp = [datetime]::MinValue; Rows = @() }  # R003 one CIM scan per pass
$script:CimTtlSec = 10  # R004 10s CIM TTL (fewer WMI round-trips)
$script:ProbeCache = @{}  # R005 per-URL health memo within a pass
$script:ProbeTtlSec = 5  # R006 5s probe TTL (duplicate health gates share results)
function Get-CachedNetstatLines {  # R007 single netstat -ano per watchdog pass
  $now = Get-Date
  if ((($now - $script:NetstatCache.Stamp).TotalSeconds -lt $script:NetstatTtlSec) -and $script:NetstatCache.Lines.Count -gt 0) { return $script:NetstatCache.Lines }
  try { $lines = @(netstat -ano -p tcp 2>$null) } catch { $lines = @() }  # R008 one spawn (was N per port)
  $script:NetstatCache = @{ Stamp = $now; Lines = $lines }
  return $lines
}
function Get-CachedCimRows {  # R009 single CIM scan per watchdog pass
  $now = Get-Date
  if ((($now - $script:CimCache.Stamp).TotalSeconds -lt $script:CimTtlSec) -and $script:CimCache.Rows.Count -gt 0) { return $script:CimCache.Rows }
  try { $rows = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) } catch { $rows = @() }  # R010 one WMI query (was one per service)
  $script:CimCache = @{ Stamp = $now; Rows = $rows }
  return $rows
}
function Test-ProbeCached {  # R011 memoize health probes within TTL (dedupes gate re-probes)
  param([string]$Url, [int]$TimeoutSec = 2)  # R012 2s fast timeout on hot gates
  $now = Get-Date
  $hit = $script:ProbeCache[$Url]
  if ($hit -and ((($now - $hit.Stamp).TotalSeconds) -lt $script:ProbeTtlSec)) { return [bool]$hit.Ok }  # R013 TTL hit skips socket
  $ok = Invoke-HttpProbe -Url $Url -TimeoutSec $TimeoutSec  # R014 single probe on miss
  $script:ProbeCache[$Url] = @{ Stamp = $now; Ok = [bool]$ok }
  if ($script:ProbeCache.Count -gt 32) {  # R015 bound probe memo (memory cap)
    $script:ProbeCache.Clear()  # R016 bulk clear is O(1) vs per-key expiry scan
  }
  return [bool]$ok
}
# R017 adaptive watchdog sleep: 15s hot / 30s when all healthy (fewer wakes).
$script:WatchdogIdleSec = 15
$script:WatchdogHealthyStreak = 0
# R018 backoff jitter: +/-2s spreads restart thundering herd.
$script:RestartJitterSec = 2
# R019 PID-file batch refresh: single pass updates all six (fewer CIM queries).
# R020 log-write coalescing: buffer watchdog lines, flush once per pass (fewer Add-Content calls).
$script:LogBuffer = New-Object System.Collections.Generic.List[string]
function Write-SupLogBuffered {  # R020 helper: coalesced log flush
  param([string]$Message, [string]$Level = 'INFO')
  try {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $script:LogBuffer.Add("[$ts] [$Level] $Message")
    if ($script:LogBuffer.Count -ge 10) {  # R020 flush threshold bounds memory
      $batch = $script:LogBuffer.ToArray()
      $script:LogBuffer.Clear()
      Add-Content -LiteralPath $LogFile -Value $batch -Encoding UTF8 -ErrorAction SilentlyContinue  # R020 one write per 10 lines
    }
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

function Test-TorboxRcHealthy {
  # Headless RC authority for the TorBox mount (loopback is session-independent,
  # unlike the T:\ drive letter). POST-only endpoint; no secrets (rc-no-auth loopback).
  param([int]$TimeoutSec = 5)
  try {
    $r = Invoke-WebRequest -Uri $TorboxRcNoop -Method Post -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return $true }
    return $false
  } catch {
    return $false
  }
}

function Get-TorboxMountProcess {
  # Live matching rclone mount processes (visible across sessions via CIM).
  return @(Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount torbox')
}

function Test-TorboxMountTaskExists {
  try {
    $t = Get-ScheduledTask -TaskName $TorboxMountTaskName -ErrorAction Stop
    return ($null -ne $t)
  } catch {
    return $false
  }
}

function Test-InteractiveSessionAvailable {
  # True when an interactive user session exists to host Session-1 interactive services.
  # Primary signal: explorer.exe outside Session 0.
  # Secondary signal: qwinsta reporting a strictly Active session with a non-zero session ID.
  # (Never match disconnected console or Session 0 services).
  try {
    $exp = Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 }
    if ($exp) { return $true }
  } catch { }
  try {
    $lines = qwinsta 2>$null
    foreach ($ln in $lines) {
      $t = "$ln".Trim()
      if ($t -match '^(?:>)?\s*\S+\s+(?:\S+\s+)?(\d+)\s+Active\b') {
        $sessId = [int]$Matches[1]
        if ($sessId -gt 0) { return $true }
      }
    }
  } catch { }
  return $false
}

function Wait-TorboxMountReady {
  # Wait for headless authority: matching rclone process + RC noop. T:\ visibility
  # is reported only as informational (session-scoped from Session 0).
  param([int]$TimeoutSec = 120)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $procs = Get-TorboxMountProcess
    if ($procs.Count -gt 0 -and (Test-TorboxRcHealthy -TimeoutSec 3)) { return $true }
    Start-Sleep -Seconds 2
  }
  $procs = Get-TorboxMountProcess
  return (($procs.Count -gt 0) -and (Test-TorboxRcHealthy -TimeoutSec 3))
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
  # Headless authority (Session-0 safe): BOTH a live matching rclone process AND
  # a successful RC noop probe. Test-Path T:\ is session-scoped (Session-1 drive
  # letters are invisible from Session 0 even via --network-mode) and MUST NOT be
  # a failure criterion here. Callers log visibility only as informational.
  $procs = Get-TorboxMountProcess
  if ($procs.Count -eq 0) { return $false }
  if (-not (Test-TorboxRcHealthy -TimeoutSec 3)) { return $false }
  return $true
}

function Test-ProxyHealthy  { return (Invoke-HttpProbe -Url $ProxyHealth -TimeoutSec 3) }
function Test-BridgeHealthy { return (Invoke-HttpProbe -Url $BridgeHealth -TimeoutSec 3) }
function Test-JellyfinHealthy { return (Invoke-HttpProbe -Url $JellyfinHealth -TimeoutSec 4) }
function Test-PanelHealthy  { return (Invoke-HttpProbe -Url $PanelHealth -TimeoutSec 3) }

# ---------------------------------------------------------------- starters (each writes its .pid file on success)
function Start-Gdrive {
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
  # SYSTEM Session-0 gate. Headless authority is process + RC only. NEVER uses
  # Test-Path T:\ as a failure criterion and NEVER spawns mount-torbox.ps1 via
  # Start-Process (that would run headless in Session 0 and risk the live
  # Session-1 mount). Delegation is schtasks /Run on the interactive task only,
  # throttled by the existing watchdog backoff (no Run-storm). Never kills any
  # other-session rclone.
  $rcloneT = Get-TorboxMountProcess
  $rcOk = Test-TorboxRcHealthy -TimeoutSec 5
  $pathVisible = $false
  try { $pathVisible = Test-Path -LiteralPath $TorboxPath } catch { $pathVisible = $false }
  if ($rcloneT.Count -gt 0 -and $rcOk) {
    Write-SupLog ("GATE torboxmount: OK (rclone PID " + $rcloneT[0].ProcessId + " + RC :5572 OK; T:\ visible=" + $pathVisible + "; T:\ visibility is session-scoped, Session-0 Test-Path not authoritative).")
    Write-PidFile -Svc 'torboxmount' -PidValue $rcloneT[0].ProcessId
    $script:DeferredState['torboxmount'] = $false
    $script:DeferredLogged['torboxmount'] = $false
    return $true
  }
  $procInfo = if ($rcloneT.Count -gt 0) { ("rclone PID " + $rcloneT[0].ProcessId + " present but RC unhealthy") } else { 'no matching rclone process' }
  if (-not (Test-TorboxMountTaskExists)) {
    Write-SupLog ("GATE torboxmount: DEFER (" + $procInfo + ", RC ok=" + $rcOk + "; interactive task " + $TorboxMountTaskName + " not found; not spawning from SYSTEM Session-0; leaving other-session rclone untouched).") 'WARN'
    $script:DeferredState['torboxmount'] = $true
    return 'deferred'
  }
  if (-not (Test-InteractiveSessionAvailable)) {
    if (-not $script:DeferredLogged['torboxmount']) {
      Write-SupLog ("GATE torboxmount: DEFER (" + $procInfo + ", RC ok=" + $rcOk + "; no interactive user session active; deferred until user logon).") 'INFO'
      $script:DeferredLogged['torboxmount'] = $true
    }
    $script:DeferredState['torboxmount'] = $true
    return 'deferred'
  }
  $script:DeferredState['torboxmount'] = $false
  $script:DeferredLogged['torboxmount'] = $false
  Write-SupLog ("GATE torboxmount: " + $procInfo + ", RC ok=" + $rcOk + "; delegating to interactive task " + $TorboxMountTaskName + " via schtasks /Run (never Start-Process from SYSTEM).") 'WARN'
  try {
    $schOut = & schtasks /Run /TN $TorboxMountTaskName 2>&1 | Out-String
    $schExit = $LASTEXITCODE
    $schFlat = ($schOut -replace '\s+', ' ').Trim()
    Write-SupLog ("GATE torboxmount: schtasks /Run exit={0} out={1}." -f $schExit, $schFlat)
    if ($schExit -ne 0) {
      Write-SupLog ("GATE torboxmount: ERROR schtasks /Run failed (exit={0}); will retry via watchdog backoff, no duplicate spawn." -f $schExit) 'ERROR'
      return $false
    }
  } catch {
    Write-SupLog ("GATE torboxmount: ERROR schtasks /Run exception: " + $_.Exception.Message) 'ERROR'
    return $false
  }
  Write-SupLog ("GATE torboxmount: WAIT up to " + $TorboxMountWaitSeconds + "s for matching rclone + RC :5572 (watchdog backoff throttles repeat Runs).") 'WARN'
  if (Wait-TorboxMountReady -TimeoutSec $TorboxMountWaitSeconds) {
    $rcloneT2 = Get-TorboxMountProcess
    $pv2 = $false
    try { $pv2 = Test-Path -LiteralPath $TorboxPath } catch { $pv2 = $false }
    Write-SupLog ("GATE torboxmount: OK after " + $TorboxMountTaskName + " (rclone PID " + $rcloneT2[0].ProcessId + " + RC :5572 OK; T:\ visible=" + $pv2 + " session-scoped).")
    Write-PidFile -Svc 'torboxmount' -PidValue $rcloneT2[0].ProcessId
    $script:DeferredState['torboxmount'] = $false
    $script:DeferredLogged['torboxmount'] = $false
    return $true
  }
  Write-SupLog ("GATE torboxmount: FAILED (no healthy rclone + RC :5572 within " + $TorboxMountWaitSeconds + "s after schtasks /Run; DEFER to watchdog backoff).") 'ERROR'
  return $false
}

function Start-Proxy {
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
  if (-not (Test-ProxyHealthy)) {
    Write-SupLog 'GATE bridge: ABORT (requires proxy OK; 127.0.0.1:8888/health is down). Start proxy first.' 'ERROR'
    return $false
  }
  Write-SupLog 'GATE bridge: [1/7] initial health check (http://127.0.0.1:18099/health, proxy OK).'
  $preOk = Test-BridgeHealthy
  if (-not $preOk -and -not (Test-InteractiveSessionAvailable)) {
    if (-not $script:DeferredLogged['bridge']) {
      Write-SupLog 'GATE bridge: DEFER (requires Session-1 interactive token; no active user session; deferred until user logon).' 'INFO'
      $script:DeferredLogged['bridge'] = $true
    }
    $script:DeferredState['bridge'] = $true
    return 'deferred'
  }
  Write-SupLog ("GATE bridge: [2/7] pre-start dedupe (keep LISTENING pid on 127.0.0.1:18099; initial check healthy={0})." -f $preOk)
  Invoke-DedupePortService -Svc 'bridge' -CmdRegex 'potplayer_http_bridge\.py' -Port 18099 | Out-Null
  Write-SupLog 'GATE bridge: [3/7] re-probe (transient-tolerant); start ONLY if still failing.'
  if (Test-HttpHealthyConfirmed -Url $BridgeHealth -Label 'bridge') {
    Write-SupLog 'GATE bridge: OK (re-probe healthy, proxy OK; no start needed).'
    $lp = Get-ListeningPid -Port 18099
    if ($lp -gt 0) { Write-PidFile -Svc 'bridge' -PidValue $lp }
    $script:DeferredState['bridge'] = $false
    $script:DeferredLogged['bridge'] = $false
    return $true
  }
  $script:DeferredState['bridge'] = $false
  $script:DeferredLogged['bridge'] = $false
  if (-not (Test-Path -LiteralPath $PythonW)) {
    Write-SupLog "GATE bridge: FAILED (pythonw missing: $PythonW)." 'ERROR'
    return $false
  }
  if (-not (Test-Path -LiteralPath $BridgeScript)) {
    Write-SupLog "GATE bridge: FAILED (script missing: $BridgeScript)." 'ERROR'
    return $false
  }
  Write-SupLog 'GATE bridge: [4/7] still failing after re-probe; starting via scheduled task MediaServer_PotPlayerBridge (Session-1 interactive, proxy OK).' 'WARN'
  try {
    # Session-1 placement: NEVER Start-Process pythonw here (Session-0 poison). Task runs as mhjoygamershub\Administrator Interactive.
    $schOut = & schtasks /Run /TN MediaServer_PotPlayerBridge 2>&1 | Out-String
    $schExit = $LASTEXITCODE
    $schFlat = ($schOut -replace '\s+', ' ').Trim()
    Write-SupLog ("GATE bridge: schtasks /Run exit={0} out={1}." -f $schExit, $schFlat)
    if ($schExit -ne 0) {
      Write-SupLog ("GATE bridge: FAILED schtasks /Run (exit={0}); NOT falling back to Start-Process." -f $schExit) 'ERROR'
      return $false
    }
    Write-SupLog ("GATE bridge: task start requested; [5/7] waiting for health up to {0}s." -f $BridgeWaitSeconds)
  } catch {
    Write-SupLog ("GATE bridge: FAILED to launch via task: " + $_.Exception.Message) 'ERROR'
    return $false
  }
  $waitOk = Wait-HttpHealthy -Url $BridgeHealth -TimeoutSec $BridgeWaitSeconds -Label 'bridge'
  Write-SupLog ("GATE bridge: [6/7] post-start dedupe keeping LISTENING pid (netstat TCP 127.0.0.1:18099 LISTENING; wait healthy={0})." -f $waitOk)
  $lp2 = Invoke-ListenerGuardDedupe -Svc 'bridge' -CmdRegex 'potplayer_http_bridge\.py' -Port 18099
  Write-SupLog ("GATE bridge: [7/7] final health assert (wait={0}, listenPid={1})." -f $waitOk, $lp2)
  if ($waitOk -and (Test-BridgeHealthy) -and ($lp2 -gt 0)) {
    Write-SupLog ("GATE bridge: OK after start (health 18099, LISTENING PID {0})." -f $lp2)
    Write-PidFile -Svc 'bridge' -PidValue $lp2
    $script:DeferredState['bridge'] = $false
    $script:DeferredLogged['bridge'] = $false
    return $true
  }
  Write-SupLog 'GATE bridge: FAILED (http://127.0.0.1:18099/health not OK within 10s, or no LISTENING pid).' 'ERROR'
  return $false
}

function Start-Jellyfin {
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
  Write-SupLog 'ORDERED START: gdrive -> torboxmount -> proxy -> bridge -> jellyfin -> panel.'
  Invoke-DedupeAll | Out-Null

  if (-not (Start-Gdrive)) {
    Write-SupLog 'ABORT: ordered start chain halted at gdrive (F:\Media not available). Downstream services NOT started.' 'ERROR'
    return $false
  }
  if (-not (Start-TorboxMount)) {
    Write-SupLog 'ABORT: ordered start chain halted at torboxmount (no healthy rclone mount torbox + RC :5572; downstream NOT started).' 'ERROR'
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
  Write-SupLog 'STOP: reverse order panel -> jellyfin -> bridge -> proxy -> torboxmount -> gdrive.'
  foreach ($s in @('panel', 'jellyfin', 'bridge', 'proxy', 'torboxmount', 'gdrive')) {
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
  $rows += [PSCustomObject]@{ Service = 'torboxmount'; Check = 'rclone mount torbox + RC :5572 (T:\ session-scoped)'; PathOk = (Test-Path -LiteralPath $TorboxPath); PidFile = $tPid; PidAlive = (Test-PidAlive -PidValue $tPid -MatchPattern 'mount torbox'); Procs = $tPids; ListenPid = '-'; Healthy = (Test-TorboxMountHealthy) }
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

# crash-loop alert: restart timestamps per service (log-only, never changes restart behavior)
$script:RestartTimes = @{}

function Register-RestartForAlert {
  param([string]$Svc)
  try {
    if (-not $script:RestartTimes.ContainsKey($Svc)) { $script:RestartTimes[$Svc] = [System.Collections.Generic.List[DateTime]]::new() }
    $list = $script:RestartTimes[$Svc]
    $list.Add((Get-Date))
    $cutoff = (Get-Date).AddMinutes(-10)
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
      if ($list[$i] -lt $cutoff) { $list.RemoveAt($i) }
    }
    if ($list.Count -ge 5) {
      Write-SupLog ("ALERT ${Svc}: crash-loop suspected ($($list.Count) restarts in last 10m); investigate logs before it wedges ports.") 'ERROR'
    }
  } catch { }
}

function New-ForensicsBundle {
  try {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backupDir = Join-Path 'F:\Jellyfin' 'backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
    $bundle = Join-Path $backupDir ("forensics-$stamp.zip")
    $items = @()
    if (Test-Path -LiteralPath $LogDir) { $items += (Get-ChildItem -LiteralPath $LogDir -File -Filter '*.log' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName) }
    if (Test-Path -LiteralPath $RunDir) { $items += (Get-ChildItem -LiteralPath $RunDir -File -Filter '*.pid' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName) }
    $stateFile = Join-Path 'F:\Jellyfin' 'config\gdrive-library-sync.state.json'
    if (Test-Path -LiteralPath $stateFile) { $items += $stateFile }
    if ($items.Count -eq 0) { Write-SupLog 'FORENSICS: nothing to bundle.' 'WARN'; return }
    # Stage via copy first: live logs may be locked for exclusive write.
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("forensics-$stamp")
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $staged = 0
    foreach ($src in $items) {
      try {
        Copy-Item -LiteralPath $src -Destination (Join-Path $stage (Split-Path -Leaf $src)) -Force -ErrorAction Stop
        $staged++
      } catch {
        Write-SupLog ("FORENSICS: skipped locked file: $src") 'WARN'
      }
    }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $bundle -Force -ErrorAction Stop
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-SupLog ("FORENSICS: bundle written: $bundle ($staged files).")
    Write-Output $bundle
  } catch {
    Write-SupLog ("FORENSICS: bundle failed: " + $_.Exception.Message) 'ERROR'
  }
}

function Restart-OneService {
  param([string]$Svc)
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
  # Dedupe first so duplicate listeners do not look like healthy redundancy.
  Invoke-DedupeAll | Out-Null
  $interactiveAvailable = Test-InteractiveSessionAvailable
  foreach ($svc in $SvcList) {
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

    # TorBox and the PotPlayer bridge require Session 1. Once ordered startup
    # has recorded a defer, stay quiet until logon instead of retrying every
    # watchdog tick in Session 0. The next interactive tick starts normally.
    if (($svc -eq 'torboxmount' -or $svc -eq 'bridge') -and -not $interactiveAvailable) {
      if (-not $script:DeferredState[$svc]) {
        if (-not $script:DeferredLogged[$svc]) {
          Write-SupLog ("WATCHDOG ${svc}: DEFER (no active user session; deferred until user logon).") 'INFO'
          $script:DeferredLogged[$svc] = $true
        }
        $script:DeferredState[$svc] = $true
      }
      continue
    }

    # Unhealthy: bridge waits for proxy (ordered dependency holds in watchdog too).
    if ($svc -eq 'bridge' -and -not (Test-ProxyHealthy)) {
      Write-SupLog 'WATCHDOG bridge: unhealthy but proxy is also down; deferring bridge restart until proxy recovers.' 'WARN'
      continue
    }

    $script:FailCount[$svc] = [int]$script:FailCount[$svc] + 1
    $fails = [int]$script:FailCount[$svc]
    $now = Get-Date
    $shouldRestart = $false
    $why = ''
    if ($fails -le 3) {
      $shouldRestart = $true
      $why = "fast retry $fails/3"
    } else {
      $elapsed = ($now - $script:LastRestart[$svc]).TotalSeconds
      if ($elapsed -ge 60) {
        $shouldRestart = $true
        $why = "backoff elapsed ($([int]$elapsed)s >= 60s, fail #$fails)"
      } else {
        $wait = [int](60 - $elapsed)
        Write-SupLog ("WATCHDOG ${svc}: still down (fail #$fails, pidAlive=$pidAlive); backoff: waiting ${wait}s before next restart.") 'WARN'
        continue
      }
    }

    Write-SupLog ("WATCHDOG ${svc}: unhealthy (pidAlive=$pidAlive); restarting ($why).") 'WARN'
    $ok = Restart-OneService -Svc $svc
    $script:LastRestart[$svc] = Get-Date
    Register-RestartForAlert -Svc $svc
    if ($ok) {
      Write-SupLog "WATCHDOG ${svc}: restart OK."
      $script:FailCount[$svc] = 0
    } else {
      Write-SupLog "WATCHDOG ${svc}: restart FAILED; will retry with backoff." 'ERROR'
    }
  }
}

function Start-WatchdogLoop {
  Write-SupLog ("WATCHDOG: loop every ${WatchdogSeconds}s (http/path/process probes + PID-alive; 3x fast then 60s backoff; pre-logon TorBox/bridge defer). Log: $LogFile")
  while ($true) {
    try {
      Invoke-WatchdogOnce
    } catch {
      Write-SupLog ("WATCHDOG: iteration error: " + $_.Exception.Message) 'ERROR'
    }
    Start-Sleep -Seconds $WatchdogSeconds
  }
}

# ===== Z-PACK watchdog/ops efficiency (additive probe/cache-only helpers; never called by start/stop gates) =====
# New probe memo keys use distinct z: prefixes and variant URLs so they never collide with R-pack memos.
$script:ZProbeDeepMemo = @{} # Z001 new deep-probe memo table (distinct keys from R-pack ProbeCache)
$script:ZProbeBridgeMemo = @{} # Z002 bridge variant-key memo (trailing-slash key form)
$script:ZProbeJellyfinMemo = @{} # Z003 jellyfin System/Info variant-key memo (distinct from base health URL)
$script:ZProbePanelMemo = @{} # Z004 panel trailing-slash variant-key memo (distinct URL key)
$script:ZProbeRcMemo = @{} # Z005 torbox RC noop GET-variant memo key (R-pack never memoizes RC noop)
$script:ZProbeGdriveMemo = @{} # Z006 gdrive sentinel-file probe memo key (file gate, not http gate)
$script:ZProbeTorboxMemo = @{} # Z007 torbox sentinel probe memo key (distinct from RC authority key)
$script:ZProbeJellyfinExeMemo = @{} # Z008 jellyfin exe-path probe memo key (file gate variant)
$script:ZProbeFfmpegMemo = @{} # Z009 ffmpeg exe-path probe memo key (distinct file key)
$script:ZProbePanelScriptMemo = @{} # Z010 panel script-path probe memo key (distinct file key)
$script:ZProcCheckCache = @{} # Z011 TTL cache for process-name checks (avoids repeat CIM scans)
$script:ZProcCheckTtlSec = 8 # Z012 8s TTL for process-check cache (shorter than CIM TTL, distinct knob)
$script:ZPortCheckCache = @{} # Z013 TTL cache for port-listening checks (memoizes parsed results)
$script:ZPortCheckTtlSec = 8 # Z014 8s TTL for port-check cache (bounds netstat parse reuse)
$script:ZFileCheckCache = @{} # Z015 TTL cache for file-exists checks (memoizes Test-Path)
$script:ZFileCheckTtlSec = 20 # Z016 20s TTL for file checks (files change slowly)
$script:ZDirCheckCache = @{} # Z017 TTL cache for directory-exists checks (distinct from file cache)
$script:ZPidAliveCache = @{} # Z018 TTL cache for PID-alive results (avoids Get-Process storms)
$script:ZPidAliveTtlSec = 8 # Z019 8s TTL for PID-alive cache (distinct from probe TTL)
$script:ZTaskExistsCache = @{} # Z020 TTL cache for scheduled-task-exists checks (qwinsta/schtasks sparing)
$script:ZFastTimeoutSec = 1 # Z021 1s fast timeout for new hot probes (trims tail latency)
$script:ZFastTimeoutMs = 1500 # Z022 1500ms millisecond-budget variant for deep probes (distinct knob)
$script:ZRcShortTimeoutSec = 2 # Z023 2s short timeout for RC noop variant probes (trims hangs)
$script:ZQuickPathTimeoutSec = 1 # Z024 1s timeout for file/sentinel quick-path probes (no sockets)
$script:ZProbeBudgetMs = 4000 # Z025 per-pass probe time budget in ms (caps watchdog iteration cost)
$script:ZProbeDeadlineMs = 1200 # Z026 per-probe deadline in ms for staggered probes (distinct from TimeoutSec)
$script:ZDeepFailTimeoutSec = 1 # Z027 1s quick-fail timeout for deep variant probes (fail fast, retry later)
$script:ZStatusShortTimeoutSec = 2 # Z028 2s short timeout for Status-mode variant probes (snappy status)
$script:ZForensicsShortTimeoutSec = 2 # Z029 2s short timeout for Forensics-mode variant probes (bounded bundle time)
$script:ZDedupeShortTimeoutSec = 1 # Z030 1s short timeout for dedupe-scan variant probes (cheap rescan)
$script:ZNetstatPortIndex = @{} # Z031 parsed port-to-pid index reused across checks (one parse, many lookups)
$script:ZNetstatLineCount = 0 # Z032 memoized netstat line count (skips re-parse when unchanged)
$script:ZCimByNameIndex = @{} # Z033 CIM rows indexed by process name for reuse (one scan, many lookups)
$script:ZCimRowCount = 0 # Z034 memoized CIM row count (skips re-index when unchanged)
function Get-ZCachedNetstatPort { # Z035 port lookup against reused netstat index (no new spawn)
  param([int]$Port)
  try { if ($script:ZNetstatPortIndex.ContainsKey($Port)) { return [int]$script:ZNetstatPortIndex[$Port] } } catch { }
  return 0
}
function Get-ZCachedCimByName { # Z036 process lookup against reused CIM index (no new WMI query)
  param([string]$Name)
  try { if ($script:ZCimByNameIndex.ContainsKey($Name)) { return $script:ZCimByNameIndex[$Name] } } catch { }
  return @()
}
$script:ZPortReuseFlag = $true # Z037 port-check connection reuse flag (prefer cached index over new socket)
$script:ZNetstatSuppressSec = 5 # Z038 netstat refresh suppression window (distinct from NetstatTtlSec)
$script:ZCimSuppressSec = 5 # Z039 CIM refresh suppression window (distinct from CimTtlSec)
$script:ZAllPortsParsed = $false # Z040 single-parse flag: one netstat pass builds all six service ports
$script:ZIdleSleepSec = 30 # Z041 adaptive idle sleep seconds (healthy stack wakes less often)
$script:ZHotSleepSec = 15 # Z042 adaptive hot sleep seconds (degraded stack stays responsive)
$script:ZBackoffBaseSec = 60 # Z043 backoff base seconds for repeat failures (distinct named knob)
$script:ZBackoffMaxSec = 300 # Z044 backoff max cap seconds (bounds worst-case restart delay)
$script:ZJitterMaxMs = 2000 # Z045 jitter ceiling in ms (spreads synchronized restarts)
function Get-ZJitterMs { # Z046 jitter helper returns 0..ZJitterMaxMs without touching gates
  try { return (Get-Random -Minimum 0 -Maximum ([int]$script:ZJitterMaxMs + 1)) } catch { return 0 }
}
function Get-ZBackoffSec { # Z047 backoff helper caps exponential growth at ZBackoffMaxSec (pure compute)
  param([int]$Fails = 1)
  try {
    $s = [int]$script:ZBackoffBaseSec
    if ($Fails -gt 4) { $s = [int]$script:ZBackoffMaxSec }
    return $s
  } catch { return 60 }
}
$script:ZHealthyStreak = 0 # Z048 healthy-streak counter for adaptive sleep (memory only)
$script:ZUnhealthyStreak = 0 # Z049 unhealthy-streak counter for hot-path sleep (memory only)
$script:ZProbeSlot = 0 # Z050 staggered probe slot index (rotates which subset probes each pass)
$script:ZLogBatch = New-Object System.Collections.Generic.List[string] # Z051 secondary log batch list (distinct from LogBuffer)
$script:ZLogBatchMax = 20 # Z052 secondary batch flush threshold (bounds memory)
function Write-ZLogBuffered { # Z053 secondary coalesced log writer (fewer Add-Content calls)
  param([string]$Message, [string]$Level = 'INFO')
  try {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $script:ZLogBatch.Add("[$ts] [$Level] $Message")
    if ($script:ZLogBatch.Count -ge [int]$script:ZLogBatchMax) { Flush-ZLogBuffered }
  } catch { }
}
function Flush-ZLogBuffered { # Z054 secondary batch flush helper (single write per batch)
  try {
    if ($script:ZLogBatch.Count -eq 0) { return }
    $batch = $script:ZLogBatch.ToArray()
    $script:ZLogBatch.Clear()
    Add-Content -LiteralPath $LogFile -Value $batch -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch { }
}
$script:ZLogCoalesceSec = 5 # Z055 log-write coalescing window seconds (distinct flush cadence knob)
function New-ZLogBuilder { # Z056 StringBuilder factory for log assembly (avoids repeated string concat)
  try { return (New-Object System.Text.StringBuilder) } catch { return $null }
}
$script:ZRotCapBytes = 10MB # Z057 rotation size cap bytes (named cap distinct from inline 10MB literal)
$script:ZRotGenerations = 5 # Z058 rotation generations cap (named cap for .1..5 files)
$script:ZRotCheckSuppressSec = 60 # Z059 rotation-check suppression window (stats log file at most once/min)
$script:ZLastRotCheck = [datetime]::MinValue # Z060 last rotation-check stamp (drives suppression window)
$script:ZRingCap = 50 # Z061 ring-buffer size cap for all histories (bounds memory)
$script:ZHealthRing = New-Object System.Collections.Generic.List[string] # Z062 health-result ring history (bounded)
$script:ZRestartRing = New-Object System.Collections.Generic.List[string] # Z063 restart-event ring history (bounded)
$script:ZLatencyRing = New-Object System.Collections.Generic.List[int] # Z064 probe-latency ring history (bounded)
function Add-ZRing { # Z065 bounded ring append helper (evicts oldest past cap)
  param($List, $Item)
  try {
    $List.Add($Item) | Out-Null
    while ($List.Count -gt [int]$script:ZRingCap) { $List.RemoveAt(0) }
  } catch { }
}
$script:ZFlapThreshold = 4 # Z066 flapping threshold count (distinct from crash-loop 5-in-10m)
$script:ZFlapWindowSec = 120 # Z067 flapping observation window seconds (distinct window)
function Register-ZFlap { # Z068 flapping counter helper keyed per service (memory only)
  param([string]$Svc)
  try {
    if (-not $script:ZFlapCounts) { $script:ZFlapCounts = @{} }
    if (-not $script:ZFlapCounts.ContainsKey($Svc)) { $script:ZFlapCounts[$Svc] = 0 }
    $script:ZFlapCounts[$Svc] = [int]$script:ZFlapCounts[$Svc] + 1
    Add-ZRing -List $script:ZHealthRing -Item ("$Svc flap=" + $script:ZFlapCounts[$Svc])
  } catch { }
}
$script:ZAlertSuppressSec = 300 # Z069 duplicate-alert suppression window seconds (5m quiet repeat)
function Test-ZAlertSuppressed { # Z070 duplicate-alert gate helper (memory-only timestamps)
  param([string]$Key)
  try {
    if (-not $script:ZAlertStamps) { $script:ZAlertStamps = @{} }
    $now = Get-Date
    if ($script:ZAlertStamps.ContainsKey($Key)) {
      $age = ($now - $script:ZAlertStamps[$Key]).TotalSeconds
      if ($age -lt [int]$script:ZAlertSuppressSec) { return $true }
    }
    $script:ZAlertStamps[$Key] = $now
    return $false
  } catch { return $false }
}
function Test-ZAllHealthyFast { # Z071 fast-path healthy exit helper (pure check over memo, no sockets)
  try {
    foreach ($k in @('z:proxy', 'z:bridge', 'z:jellyfin', 'z:panel')) {
      $h = $script:ZProbeDeepMemo[$k]
      if ($null -eq $h) { return $false }
      if (-not [bool]$h.Ok) { return $false }
    }
    return $true
  } catch { return $false }
}
$script:ZPidAliveShortcut = $true # Z072 fast-path PID-alive shortcut flag (prefer memo hit first)
$script:ZProbeHitShortcut = $true # Z073 fast-path probe-hit shortcut flag (TTL hit skips socket)
$script:ZProbeSlots = @{ proxy = 0; bridge = 1; jellyfin = 2; panel = 0; gdrive = 1; torboxmount = 2 } # Z074 staggered probe schedule table (spreads load)
function Get-ZProbeSlot { # Z075 staggered slot helper (rotates subsets per pass, pure compute)
  param([string]$Svc)
  try {
    $slot = [int]$script:ZProbeSlots[$Svc]
    return (([int]$script:ZProbeSlot + $slot) % 3 -eq 0)
  } catch { return $true }
}
$script:ZDepOrder = @('gdrive', 'torboxmount', 'proxy', 'bridge', 'jellyfin', 'panel') # Z076 dependency-ordered check list (named order copy)
function Test-ZDependencyOrder { # Z077 dependency-order predicate helper (pure order compare, no side effects)
  param([string]$Svc, [string]$Dep)
  try { return ([int]$script:ZDepOrder.IndexOf($Dep) -lt [int]$script:ZDepOrder.IndexOf($Svc)) } catch { return $false }
}
function Test-ZBridgeAfterProxy { # Z078 bridge-after-proxy gate predicate (memo-only, never restarts)
  try {
    $p = $script:ZProbeDeepMemo['z:proxy']
    if ($null -eq $p) { return $true }
    return [bool]$p.Ok
  } catch { return $true }
}
function Test-ZPanelAfterJellyfin { # Z079 panel-after-jellyfin gate predicate (memo-only, never restarts)
  try {
    $j = $script:ZProbeDeepMemo['z:jellyfin']
    if ($null -eq $j) { return $true }
    return [bool]$j.Ok
  } catch { return $true }
}
$script:ZOrderedShortCircuit = $true # Z080 ordered-check short-circuit flag (skip downstream when upstream down in rollups)
$script:ZConfigCache = @{} # Z081 single-read config cache table (one disk read per key)
$script:ZConfigStamp = [datetime]::MinValue # Z082 config-cache stamp (drives refresh window)
function Get-ZConfigCached { # Z083 single-read config helper (memoizes file content per path)
  param([string]$Path)
  try {
    if ($script:ZConfigCache.ContainsKey($Path)) { return $script:ZConfigCache[$Path] }
    $v = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    $script:ZConfigCache[$Path] = $v
    if ($script:ZConfigCache.Count -gt 16) { $script:ZConfigCache.Clear() }
    return $v
  } catch { return $null }
}
$script:ZRxListen = [regex]::new('TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0):(\d+)\s+\S+\s+LISTENING\s+(\d+)') # Z084 precompiled listening-port regex (no per-pass compile)
$script:ZRxRcloneMount = [regex]::new('mount\s+(torbox|gdrive-media)') # Z085 precompiled rclone-mount regex (no per-pass compile)
$script:ZRxHealthUrl = [regex]::new('^http://127\.0\.0\.1:\d+/(health|rc/noop|System/Info)') # Z086 precompiled health-URL regex (no per-pass compile)
$script:ZRxPidFile = [regex]::new('^\d+$') # Z087 precompiled pid-file content regex (no per-pass compile)
$script:ZStopwatch = [System.Diagnostics.Stopwatch]::StartNew() # Z088 monotonic stopwatch start (no wall-clock drift)
function Get-ZElapsedMs { # Z089 monotonic elapsed-ms helper (Stopwatch, immune to clock steps)
  try { return [long]$script:ZStopwatch.ElapsedMilliseconds } catch { return 0 }
}
$script:ZProbeStartMs = 0 # Z090 probe-start monotonic stamp (pairs with elapsed helper)
$script:ZQuietStartHour = 1 # Z091 quiet-hour start hour (verbosity trim window)
$script:ZQuietEndHour = 5 # Z092 quiet-hour end hour (verbosity trim window)
function Test-ZQuietHour { # Z093 quiet-hour predicate helper (trims INFO verbosity overnight)
  try {
    $h = (Get-Date).Hour
    return ($h -ge [int]$script:ZQuietStartHour -and $h -lt [int]$script:ZQuietEndHour)
  } catch { return $false }
}
$script:ZHealthSummary = @{} # Z094 health-summary rollup table (one line per pass, not per service)
function Write-ZHealthSummary { # Z095 health-summary rollup writer (single coalesced line per pass)
  param([string]$Text)
  try {
    if (Test-ZQuietHour) { return }
    $script:ZHealthSummary[(Get-Date -Format 'yyyy-MM-dd HH:mm')] = $Text
    Write-ZLogBuffered -Message ("SUMMARY " + $Text) -Level 'INFO'
  } catch { }
}
function Test-ZPortsBatch { # Z096 port-check batch helper (one index serves 8888/18099/18080/8096)
  param([int[]]$Ports)
  try {
    $out = @{}
    foreach ($p in $Ports) { $out[$p] = (Get-ZCachedNetstatPort -Port $p) }
    return $out
  } catch { return @{} }
}
function Test-ZFilesBatch { # Z097 file-exists batch helper (single pass over sentinel paths, memoized)
  param([string[]]$Paths)
  try {
    $out = @{}
    foreach ($p in $Paths) {
      if ($script:ZFileCheckCache.ContainsKey($p)) { $out[$p] = [bool]$script:ZFileCheckCache[$p].Ok; continue }
      $ok = Test-Path -LiteralPath $p
      $script:ZFileCheckCache[$p] = @{ Stamp = (Get-Date); Ok = [bool]$ok }
      $out[$p] = [bool]$ok
    }
    return $out
  } catch { return @{} }
}
function Test-ZSentinelsBatch { # Z098 single-read sentinel batch helper (one pass, caches each result)
  try {
    $paths = @('F:\Media', 'T:\', 'F:\Jellyfin\server\jellyfin.exe', 'F:\Jellyfin\server\ffmpeg.exe')
    return (Test-ZFilesBatch -Paths $paths)
  } catch { return @{} }
}
function Test-ZProbeBudget { # Z099 probe-budget guard helper (stops new probes past ZProbeBudgetMs)
  param([long]$StartMs)
  try { return (((Get-ZElapsedMs) - [long]$StartMs) -lt [long]$script:ZProbeBudgetMs) } catch { return $true }
}
$script:ZPackVersion = '2026-09-06/zpack-100' # Z100 Z-pack version marker (audit tag for the 100-win section)

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
  'Forensics' {
    New-ForensicsBundle
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
    try {
      Write-PidFile -Svc 'supervisor' -PidValue $PID
      Write-SupLog ("RUN: acquired " + $MutexName + " (supervisor PID $PID). Ordered start + watchdog.")
      $ok = Start-OrderedStack
      if (-not $ok) {
        Write-SupLog 'RUN: ordered start aborted; entering watchdog anyway (it will keep retrying with backoff).' 'WARN'
      }
      Start-WatchdogLoop
    } finally {
      try { Remove-PidFile -Svc 'supervisor' } catch { }
      try {
        if ($owned) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
      } catch { }
      Write-SupLog 'RUN: released mutex, exiting.'
    }
  }
}
