# Supervisor Modes, Watchdog, and Forensics

This guide explains the supervisor modes, the ordered start chain, the watchdog with backoff, defer-until-logon behavior, and the forensics bundle used for support.

## Contents

- [Modes](#modes)
- [Ordered start chain (boot order)](#ordered-start-chain-boot-order)
- [Watchdog and backoff](#watchdog-and-backoff)
- [Boot vs logon (defer-until-logon)](#boot-vs-logon-defer-until-logon)
- [Cold-restart validation procedure](#cold-restart-validation-procedure)
- [Dedupe and single instance](#dedupe-and-single-instance)
- [Status output](#status-output)
- [Forensics bundle](#forensics-bundle)
- [Logs and alerts](#logs-and-alerts)

## Modes

Run every command from the repo root with PowerShell 7 or newer.

| Mode | Command | What it does |
| --- | --- | --- |
| Run | `pwsh -File supervisor.ps1 -Mode Run` | Default. Acquires the global mutex, does one ordered start, then loops the watchdog forever. Normally launched by the `MediaStackSupervisor` ONLOGON scheduled task. |
| Start | `pwsh -File supervisor.ps1 -Mode Start` | Does one ordered start with health gates and exits, without looping. Safe to retry after fixing a failed gate. |
| Stop | `pwsh -File supervisor.ps1 -Mode Stop` | Stops panel, Jellyfin, bridge, proxy, and mounts in reverse order and clears the supervisor PID. |
| Status | `pwsh -File supervisor.ps1 -Mode Status` | Prints a table of path checks, PID files, live processes, listener PIDs, and healthy flags. |
| Forensics | `pwsh -File supervisor.ps1 -Mode Forensics` | Builds a timestamped zip of logs, PID files, and sync state for support. |

The supervisor creates no scheduled task and kills nothing on load. All side effects happen only inside the explicitly invoked mode. Secrets are refreshed from the live Machine then User environment at start, so children inherit values that were set after the parent shell opened. See [TorBox](torbox.md) for the env setup behind this step.

## Ordered start chain (boot order)

`Start-OrderedStack` always runs mounts first and panel last, aborting on the first failed gate with an explicit `ABORT:` log naming the exact service. Downstream services are never started on a broken base. The same order drives bulk panel actions in [Panel](panel.md) and the reboot flow in the repo `RUNBOOK.md`.

| # | Service | Gate | Wait | Start detail |
| --- | --- | --- | --- | --- |
| 1 | gdrive | `Test-Path F:\Media` | up to 15 s after `nssm start RcloneGdriveMount`, then up to 30 s after fallback `mount-gdrive.ps1` | Fast path logs `GATE gdrive: OK` and refreshes `run\gdrive.pid` from the live `rclone mount gdrive-media` process when already healthy. |
| 2 | torboxmount | `Test-Path T:\` | up to 30 s (`$MountWaitSeconds`) | Launches `mount-torbox.ps1` only when `T:\` is missing. Idempotent guard inside the mount script: a live `rclone mount torbox` process serving `T:\` is never killed or restarted (fixes the 2026-09-05 kill-loop with 700+ torboxmount fails and `T:\` flapping when a cold mount could not finish WinFsp init inside the wait). |
| 3 | proxy | `http://127.0.0.1:8888/health` | up to 30 s (`$ProxyWaitSeconds`) | 7-step gate: initial probe, pre-start dedupe keeping the `LISTENING` PID on `127.0.0.1:8888`, transient-tolerant re-probe (3 x 2 s, start only if still failing), `pythonw torbox-proxy.py` launch, health wait, post-start listener-guard dedupe, final health + listener assert. |
| 4 | bridge | `http://127.0.0.1:18099/health`, requires proxy OK | up to 10 s (`$BridgeWaitSeconds`) | Same 7-step dedupe/re-probe/guard as proxy. Aborts with `GATE bridge: ABORT (requires proxy OK ...)` when the proxy is down, so the watchdog dependency is enforced at start time too. |
| 5 | jellyfin | `http://127.0.0.1:8096/System/Info/Public` | up to 60 s (`$JellyfinWaitSecs`) | Ensures data, config, cache, log, transcodes, web, and ffmpeg paths, then starts `server\jellyfin.exe` with `--datadir/--configdir/--cachedir/--logdir/--webdir/--ffmpeg`. Fast path returns `OK` when `8096` already answers. |
| 6 | panel | `http://127.0.0.1:18080/health` | up to 15 s (`$PanelWaitSeconds`) | Starts `pythonw control_panel.py`. Probe tolerates both loopback and all-interface binds; proxy and bridge keep strict `127.0.0.1` semantics. |

Dedupe runs before the chain (`Invoke-DedupeAll`): for `:8888`/`:18099` the listening PID is kept and extras are killed with per-parent forensics. A healthy fast path never restarts — it logs `OK`, refreshes the PID file from the live listener or process, and moves on. On failure the chain logs e.g. `ABORT: ordered start chain halted at proxy (127.0.0.1:8888/health failed after 30s). Downstream services NOT started.` In `Run` mode an aborted start still enters the watchdog loop, which keeps retrying with backoff (see below).

Stop is the exact reverse, mounts last:

```powershell
pwsh -File supervisor.ps1 -Mode Stop
# panel -> jellyfin -> bridge -> proxy -> torboxmount -> gdrive
```

## Watchdog and backoff

The `Run`-mode watchdog loops every **15 s** (`$WatchdogSeconds`) and checks three signals per service on every tick:

1. **HTTP probe** (`Invoke-HttpProbe`, 3–4 s timeout) for proxy/bridge/Jellyfin/panel.
2. **Mount path presence** (`Test-Path F:\Media` / `Test-Path T:\`) for the two mounts.
3. **PID liveness with command-line matching** (`Test-PidAlive` + `Win32_Process.CommandLine`) — a PID file pointing at a dead process or a reused PID owned by an unrelated command counts as down.

Tick logic in `Invoke-WatchdogOnce`:

- **Dedupe first.** Duplicate listeners are swept before health is judged, so two PIDs on one port never look like healthy redundancy.
- **Healthy: reset + refresh.** The per-service fail counter resets to 0 (`WATCHDOG <svc>: recovered (fail counter reset)` when it was non-zero) and `run\<svc>.pid` is rewritten from the live listener PID (`8888`/`18099`/`18080`) or live process (`jellyfin`, `rclone mount ...`). This keeps PID-alive meaningful across restarts.
- **Bridge deferred while proxy is down.** `WATCHDOG bridge: unhealthy but proxy is also down; deferring bridge restart until proxy recovers.` The start-chain dependency holds in the watchdog too — fix proxy first.
- **Unhealthy: 3 fast retries, then 60 s cooldown.** Fail counter `+1` per consecutive failing tick:

| Fail count | Action | Log shape |
| --- | --- | --- |
| 1–3 | Restart immediately | `WATCHDOG <svc>: unhealthy (pidAlive=...); restarting (fast retry N/3).` then `restart OK` or `restart FAILED; will retry with backoff.` |
| 4+ | Restart at most once per 60 s since the last restart | `WATCHDOG <svc>: still down (fail #N, pidAlive=...); backoff: waiting Ns before next restart.` When the cooldown has elapsed: `restarting (backoff elapsed (Ns >= 60s, fail #N))`. |

- **Transient-tolerant re-probes.** Proxy/bridge do `Test-HttpHealthyConfirmed` (3 attempts, 2 s apart) before any start, so a single flapped probe never spawns a second listener (`GATE <svc>: probe 1/3 failed (possible transient); re-probing ...`).
- **Post-start listener guard.** After each proxy/bridge start the guard settles ~1 s, re-checks health when netstat lags, sweeps non-listening duplicates, and reports the surviving `LISTENING` PID (`GUARD <svc>: single PID ... holds 127.0.0.1:<port> LISTENING ...`).
- **Crash-loop alert (log-only, 5 in 10 min).** Every restart timestamp feeds `Register-RestartForAlert`; five or more restarts of one service inside ten minutes logs `ALERT <svc>: crash-loop suspected (N restarts in last 10m); investigate logs before it wedges ports.` It never changes restart behavior — treat it as an investigation signal, not an auto-stop.
- **Rotation + mutex.** `logs\supervisor.log` rotates at 10 MB across 5 generations. `Run` holds `Global\MediaStackSupervisor`; a second `Run` exits immediately (`single-instance`).

Tail the backoff state with:

```powershell
Select-String "WATCHDOG|ALERT|DEDUPE|GUARD|ABORT" logs\supervisor.log -Tail 40
pwsh -File supervisor.ps1 -Mode Status
```

## Boot vs logon (defer-until-logon)

The stack deliberately defers everything but the NSSM mount until a user signs in:

- **`MediaStackSupervisor` task — ONLOGON.** Created by `install.ps1` (`Register-SupervisorTask`) as a per-user `AtLogOn` trigger (`Interactive`, `Highest`, `MultipleInstances IgnoreNew`, `StartWhenAvailable`; `schtasks /SC ONLOGON /RL HIGHEST` fallback). Action: `pwsh -NoProfile -ExecutionPolicy Bypass -File supervisor.ps1 -Mode Run`.
- **Control panel task — per-user logon.** Created by `install-control-panel.ps1` as a hidden `AtLogOn` task via `wscript` (no console window) plus a Start Menu shortcut. Binds localhost only.
- **NSSM `RcloneGdriveMount` — SERVICE_AUTO_START, Session 0.** Installed by `install-rclone-service.ps1`. This is the only component up at boot with no logon (`gdrive-media:` to `F:\Media`).
- **`mount-torbox.ps1` — no scheduled task.** `T:\` only appears through the supervisor chain after logon (see the idempotent guard above).
- **Sync tasks — SYNC ONLY, never supervised.** `MediaServer_TorboxSmartSync` and `MediaServer_GoogleDriveLibrarySync` stay enabled; panel and sync scripts trigger them with `schtasks /Run` instead of duplicating the pipeline.

Consequences:

1. A cold reboot with no logon leaves only `F:\Media` (NSSM) up. Proxy, bridge, Jellyfin, panel, and `T:\` wait for the ONLOGON supervisor run.
2. After logon, expect the full gate waits to elapse (proxy 30 s, Jellyfin 60 s, views scan ~60 s) before every health check is green — that delay is normal, not a hang.
3. Env secrets set at Machine/User scope are picked up because the supervisor re-reads the live values at start; open a fresh shell after changing them.

Verify the wiring:

```powershell
schtasks /Query /TN "MediaStackSupervisor" /FO LIST
Get-ScheduledTask -TaskName "MediaStackSupervisor" | Format-List TaskName,State,Triggers
Get-ScheduledTask -TaskName "Jellyfin Control Panel*" | Format-List TaskName,State
Get-Service RcloneGdriveMount | Format-List Name,Status,StartType
Test-Path F:\Media; Test-Path T:\
Invoke-RestMethod http://127.0.0.1:8888/health
Invoke-RestMethod http://127.0.0.1:18099/health
```

Portable (`-Portable`) and files-only (`-SkipTasks`) installs intentionally create no tasks — use `supervisor.ps1 -Mode Start` / `-Mode Run` manually in the current session. Uninstall removes the supervisor task (`schtasks /Delete /TN "MediaStackSupervisor" /F`) plus the panel logon task; see [Install](install.md).

## Cold-restart validation procedure

Follow this step-by-step procedure to validate the stack after a host reboot, crash recovery, or cold restart.

> **Rule:** Always capture forensics **before** restarting a crashed stack to prevent losing logs from rotation.

```powershell
# Pre-restart snapshot
pwsh -File supervisor.ps1 -Mode Forensics
pwsh -File supervisor.ps1 -Mode Status
```

### Exact verification steps & pass criteria

#### Step 1: Confirm supervisor logon task & mutex
```powershell
# Query logon task status
Get-ScheduledTask -TaskName "MediaStackSupervisor" | Format-Table TaskName, State, @{N='LastRun';E={(Get-ScheduledTaskInfo $_).LastRunTime}}, @{N='LastResult';E={(Get-ScheduledTaskInfo $_).LastTaskResult}}

# Confirm PID in run\supervisor.pid matches active supervisor
$supPid = Get-Content -LiteralPath "F:\Jellyfin\run\supervisor.pid" -ErrorAction SilentlyContinue
Get-Process -Id $supPid -ErrorAction SilentlyContinue | Format-Table Id, ProcessName, StartTime
```
- **Pass criteria:** Task state is `Ready` or `Running`, `LastResult` is `0`, and `supervisor.pid` holds a single active `pwsh` process owning `Global\MediaStackSupervisor`.

#### Step 2: Verify live process table and single listening PIDs
```powershell
# 1. Check supervisor status table
pwsh -File supervisor.ps1 -Mode Status

# 2. Check listening TCP ports
netstat -ano -p tcp | Select-String -Pattern ":(8888|18099|18080|8096)\s+.*LISTENING"
```
- **Pass criteria:**
  - `supervisor.ps1 -Mode Status` prints 6 rows, all with `Healthy=True` and `PidAlive=True`.
  - PID files under `run\*.pid` match live process IDs for all 6 components.
  - `netstat` shows **exactly one** `LISTENING` row for each of `:8888`, `:18099`, `:18080`, and `:8096`. No duplicate zombie python/rclone processes.

#### Step 3: Explicit HTTP 200 checks & path verification
```powershell
# Verify mount paths
Test-Path -LiteralPath "F:\Media" # Must return True
Test-Path -LiteralPath "T:\"      # Must return True

# Query all HTTP health gates
$gates = @(
    @{ Name = 'TorboxProxy';     Url = 'http://127.0.0.1:8888/health' },
    @{ Name = 'TorboxMyList';    Url = 'http://127.0.0.1:8888/mylist' },
    @{ Name = 'PotPlayerBridge'; Url = 'http://127.0.0.1:18099/health' },
    @{ Name = 'JellyfinPublic';  Url = 'http://127.0.0.1:8096/System/Info/Public' },
    @{ Name = 'ControlPanel';    Url = 'http://127.0.0.1:18080/health' }
)
foreach ($g in $gates) {
    try {
        $res = Invoke-WebRequest -Uri $g.Url -Method Get -TimeoutSec 5 -UseBasicParsing
        [PSCustomObject]@{ Gate = $g.Name; StatusCode = $res.StatusCode; Result = 'PASS'; Url = $g.Url }
    } catch {
        [PSCustomObject]@{ Gate = $g.Name; StatusCode = $_.Exception.Response.StatusCode.value__; Result = 'FAIL'; Url = $g.Url }
    }
}
```
- **Pass criteria:** Both `Test-Path` calls return `True`. All 5 endpoints return `StatusCode: 200` with `Result: PASS`.

#### Step 4: Jellyfin auth & views check
```powershell
pwsh -File check_status.ps1 -AsJson; Write-Host "Status Exit: $LASTEXITCODE"
pwsh -File check_views_after_restart.ps1 -AsJson; Write-Host "Views Exit: $LASTEXITCODE"
```
- **Pass criteria:** Both scripts return JSON payloads with `status: "OK"` and exit code **`0`**. (Exit `1` on views check within the first 60 seconds indicates library warming; re-test after 60s).

#### Step 5: Check watchdog quietness (no retry noise or alerts)
```powershell
# Inspect supervisor log tail
Select-String "WATCHDOG|ALERT|DEDUPE|GUARD|ABORT" F:\Jellyfin\logs\supervisor.log -Tail 40

# Check for error noise
$errors = Select-String "ALERT|crash-loop|restart FAILED|ABORT" F:\Jellyfin\logs\supervisor.log -Tail 100
if ($errors) {
    Write-Host "[!] Found watchdog error noise in recent logs:" -ForegroundColor Red
    $errors | Format-Table -AutoSize
} else {
    Write-Host "[+] Supervisor log is clean and quiet." -ForegroundColor Green
}
```
- **Pass criteria:** Zero `ALERT` lines, no `restart FAILED`, no `crash-loop suspected`, and no repeating `backoff: waiting` loops.

#### Step 6: Playback smoke test
```powershell
pwsh -File test_dpl.ps1 -SkipLaunch
pwsh -File test_mcp_server.ps1
```
- **Pass criteria:** Both test suites finish with 0 errors.

---

## Dedupe and single instance

Only one process may own Run mode at a time through a global mutex, with a second instance exiting immediately. PID files live under the run folder, one per service plus supervisor. Dedupe keeps the listening PID for the proxy and bridge ports and kills non-listening duplicates, with per-parent forensics that log parent PID, truncated parent command, creation time, and a per-parent counter. A post-start listener guard settles, rechecks health, sweeps duplicates, and reports the surviving listener PID. Jellyfin and panel ports tolerate both loopback and all-interface binds, while proxy and bridge keep strict loopback semantics.

A single non-listening proxy process is left for the health-gate restart path (avoids flapping during cold start) but logged as `present but 127.0.0.1:8888 has no listener yet (starting or wedged)`. Multiple non-listening processes with no listener are treated as zombies and swept so the watchdog can start one fresh listener.

## Status output

Status mode prints one row per service with the check that was run, path or probe result, PID file value, PID-alive flag, live process IDs, listener PID, and final healthy flag. Use it before and after any restart, and paste it into support requests alongside the forensics bundle. The expected healthy values match the health probes in [Quickstart](quickstart.md) and the ports in [Architecture](architecture.md).

```powershell
pwsh -File supervisor.ps1 -Mode Status
```

## Forensics bundle

Forensics mode stages and zips the current support evidence without touching tracked files.

- Included: rotated supervisor and launcher logs, proxy and bridge logs when present, every PID file under the run folder, and the Drive sync state JSON.
- Naming: timestamped zip under the backups folder, built through a temp staging copy so locked live logs are skipped with a warning instead of failing the bundle.
- Empty case: logs an explicit nothing-to-bundle warning when no files exist.
- Send the bundle plus Status output plus the exact failing health URL when asking for help.

Collect forensics before restarting a crashed loop, because restarts rotate evidence. Log locations for deeper digging are listed below and in [Troubleshooting](troubleshooting.md).

```powershell
pwsh -File supervisor.ps1 -Mode Forensics
```

## Logs and alerts

The supervisor log lives under the logs folder with ten-megabyte rotation across five generations. Launcher, prefetch, playback, Jellyfin, proxy metrics, and MCP logs each have their own file or endpoint, all covered in the runbook flow. Watch for ordered-start aborts, watchdog restarts with fast-retry versus backoff reasons, dedupe lines that name kept versus killed PIDs, forensics lines with bundle paths, and crash-loop alerts that signal investigation before ports wedge. Pair this guide with [Panel](panel.md) for card meanings and [Reference](reference.md) for what to back up before deleting logs.

Key strings to grep:

```powershell
Select-String "ORDERED START|ABORT" logs\supervisor.log -Tail 20
Select-String "WATCHDOG.*(fast retry|backoff|deferring)" logs\supervisor.log -Tail 20
Select-String "DEDUPE|GUARD|FORENSICS|ALERT" logs\supervisor.log -Tail 20
```

---

Back to [Docs Index](index.md).
