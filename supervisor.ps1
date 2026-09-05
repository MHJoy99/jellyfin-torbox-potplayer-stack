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
  $rcloneT = Get-MatchingProcesses -NameRegex '^rclone\.exe$' -CmdRegex 'mount torbox'
  if ($rcloneT.Count -gt 0) {
    # A mount process is already alive but T:\ is not visible yet (slow WinFsp
    # init or transient flap). Spawning a second mount on the same drive letter
    # + RC port hard-kills the live instance — wait for it instead (2026-09-05).
    Write-SupLog ("GATE torboxmount: rclone already alive (PID " + $rcloneT[0].ProcessId + "); waiting up to 90s for T:\ instead of spawning a duplicate.") 'WARN'
    if (Wait-PathHealthy -LiteralPath $TorboxPath -TimeoutSec 90) {
      Write-SupLog 'GATE torboxmount: OK after wait (T:\ present, no duplicate spawned).'
      Write-PidFile -Svc 'torboxmount' -PidValue $rcloneT[0].ProcessId
      return $true
    }
    Write-SupLog 'GATE torboxmount: FAILED (live rclone never produced T:\ in 90s).' 'ERROR'
    return $false
  }
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
  Write-SupLog ("WATCHDOG: loop every ${WatchdogSeconds}s (http_probe + Test-Path + PID-alive; 3x fast then 60s backoff). Log: $LogFile")
  while ($true) {
    try {
      Invoke-WatchdogOnce
    } catch {
      Write-SupLog ("WATCHDOG: iteration error: " + $_.Exception.Message) 'ERROR'
    }
    Start-Sleep -Seconds $WatchdogSeconds
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
