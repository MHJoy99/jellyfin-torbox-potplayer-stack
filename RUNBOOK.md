# NexusMedia Jellyfin Stack — Runbook

> Never commit secrets. All credentials are environment variables or the OS
> credential store. Rotate by updating env/registry + restarting services below.

## 1. Boot / restart order (supervisor ordered chain)

Correct order avoids stale VFS, 93-byte `.strm` streams, missing views, and
duplicate listeners. The supervisor (`supervisor.ps1`) is the source of truth:
`Start-OrderedStack` runs `gdrive -> torboxmount -> proxy -> bridge -> jellyfin -> panel`,
aborts on the first failed gate with an explicit `ABORT:` log, and never starts
downstream services on a broken base. `Stop` runs the exact reverse.

| # | Service | Gate (must pass before next starts) | Wait | How it starts |
|---|---------|--------------------------------------|------|---------------|
| 1 | **gdrive** (`F:\Media`) | `Test-Path F:\Media` | up to 15 s after NSSM start, then up to 30 s after fallback script | NSSM `RcloneGdriveMount` (`nssm start`); fallback `mount-gdrive.ps1` if still missing |
| 2 | **torboxmount** (`T:\`) | `Test-Path T:\` | up to 30 s | `mount-torbox.ps1` (no scheduled task — supervisor-only). Idempotent guard: if an `rclone mount torbox` process exists **and** `T:\` is present, it is left alone and never restarted (fixes the 2026-09-05 kill-loop where every retry flapped `T:\`) |
| 3 | **torbox-proxy `:8888`** (`server/torbox-proxy.py`) | `http://127.0.0.1:8888/health` | up to 30 s | `pythonw torbox-proxy.py` only after pre-start dedupe + transient-tolerant re-probe (3 x 2 s); post-start listener guard keeps the `LISTENING` PID on `127.0.0.1:8888` |
| 4 | **bridge `:18099`** (`potplayer_http_bridge.py`) | `http://127.0.0.1:18099/health` **requires proxy OK first** | up to 10 s | Same dedupe/re-probe/guard as proxy. If proxy is down the gate logs `ABORT (requires proxy OK)` and does not start |
| 5 | **Jellyfin `:8096`** | `http://127.0.0.1:8096/System/Info/Public` | up to 60 s | `server\jellyfin.exe` with `--datadir/--configdir/--cachedir/--logdir/--webdir/--ffmpeg` ensured first; fast path logs `OK` without restart when already healthy |
| 6 | **control-panel `:18080`** (`control-panel/control_panel.py`) | `http://127.0.0.1:18080/health` | up to 15 s | `pythonw control_panel.py`; tolerant of `127.0.0.1` or `0.0.0.0` binds (proxy/bridge keep strict loopback) |

Pre-chain dedupe runs first (`Invoke-DedupeAll`): for `:8888`/`:18099` the
`LISTENING` PID is kept and non-listening duplicates are killed with a
`FORENSICS <svc> dupe pid=... ppid=... parentCmd=... created=... count=...`
line. A healthy fast path refreshes the PID file from the live listener or
process instead of restarting. Full gate logs (`GATE <svc>: [1/7] ... [7/7]`)
and mode details live in `docs/supervisor.md`.

Stop order (also `supervisor.ps1 -Mode Stop`):

```powershell
panel -> jellyfin -> bridge -> proxy -> torboxmount -> gdrive
```

So mounts stop last and running services never lose files mid-shutdown.

### 1a. Defer-until-logon behavior (what runs before you sign in)

- **`MediaStackSupervisor` scheduled task: ONLOGON.** Installed by
  `install.ps1` as a per-user `AtLogOn` task (`Interactive`, `Highest`,
  `MultipleInstances IgnoreNew`, `StartWhenAvailable`; `schtasks /SC ONLOGON`
  fallback). Command is `pwsh -NoProfile -ExecutionPolicy Bypass -File supervisor.ps1 -Mode Run`.
- **Control panel: per-user logon task.** Installed by
  `install-control-panel.ps1` as a hidden `AtLogOn` task via `wscript`
  (no console window) + Start Menu shortcut.
- **NSSM `RcloneGdriveMount`: SERVICE_AUTO_START, Session 0.** This is the
  only piece that is up at boot without a logon (mounts `gdrive-media:` to
  `F:\Media`).
- **`mount-torbox.ps1`: no scheduled task.** `T:\` only comes up through the
  supervisor ordered chain after logon.
- **Sync tasks (`MediaServer_TorboxSmartSync`, `MediaServer_GoogleDriveLibrarySync`):
  SYNC ONLY.** Kept enabled, never supervised; the panel/sync scripts request
  them via `schtasks /Run` instead of duplicating their work.

Net effect after a cold reboot with no interactive logon: only the NSSM
gdrive mount is present. Proxy, bridge, Jellyfin, panel, and `T:\` all defer
until the supervisor logon task fires. The supervisor itself creates no
scheduled task and kills nothing on load — every side effect lives inside the
explicitly invoked `-Mode` (`Run`/`Start`/`Stop`/`Status`/`Forensics`).
Secrets are re-read live from Machine then User env at supervisor start, so
children inherit values set after the parent shell opened.

Verify the deferral wiring:

```powershell
schtasks /Query /TN "MediaStackSupervisor" /FO LIST
Get-ScheduledTask -TaskName "MediaStackSupervisor" | Format-List TaskName,State,Triggers
Get-ScheduledTask -TaskName "Jellyfin Control Panel*" | Format-List TaskName,State
Get-Service RcloneGdriveMount | Format-List Name,Status,StartType
```

### 1b. Watchdog backoff (what happens after boot)

`supervisor.ps1 -Mode Run` holds the `Global\MediaStackSupervisor` mutex
(second instance exits immediately), does one ordered start, then loops every
**15 s**. Each tick checks three signals per service: HTTP probe + mount-path
presence + PID liveness with command-line matching (detects PID reuse).

- **Healthy:** fail counter resets to 0 and the PID file under `run/` is
  refreshed from the live listener (`8888`/`18099`/`18080` via netstat-style
  `LISTENING` lookup) or live process (`jellyfin`, `rclone mount ...`).
- **Bridge deferred:** if the bridge is unhealthy but the proxy is also down,
  the watchdog logs `deferring bridge restart until proxy recovers` and skips
  it — the start-chain dependency holds in the watchdog too.
- **Unhealthy:** fail counter `+1`. Fails 1–3 restart immediately
  (`fast retry 1/3 ... 3/3`). Fail 4+ restarts at most once per **60 s
  cooldown** (`backoff: waiting Ns before next restart`); otherwise the tick
  logs and waits.
- **Transient tolerance:** proxy/bridge re-probe 3 x 2 s before any start, so
  one flapped probe never spawns a second listener.
- **Crash-loop alert (log-only):** 5 restarts of one service inside 10 min
  logs `ALERT <svc>: crash-loop suspected ...`; it never changes restart
  behavior — investigate before ports wedge.
- **Log rotation:** `logs\supervisor.log` rotates at 10 MB across 5
  generations; look for `ORDERED START`, `WATCHDOG <svc>: ... (fast retry|backoff ...)`,
  `DEDUPE`/`GUARD` kept-vs-killed PIDs, `FORENSICS` spawner lines, and `ALERT`.

Quick checks:

```powershell
pwsh -File check_status.ps1
pwsh -File check_user_views.ps1 -AsJson
pwsh -File scripts/healthcheck.ps1
pwsh -File supervisor.ps1 -Mode Status
```

## 2. Key rotation

| Secret | Where set | How to rotate |
|--------|-----------|---------------|
| `TORBOX_API_KEY` | `$env:TORBOX_API_KEY` (Machine/User) + registry copy read by supervisor | Set new value in env + registry, restart `torbox-proxy`, `supervisor`, then test `potplayer-launcher` CDN path. Old proxy URLs (`:8888/torbox/...`) stay valid (proxy re-resolves CDN per request); direct CDN URLs expire and must not be cached. |
| `JELLYFIN_USER` / `JELLYFIN_PASSWORD` | `$env:JELLYFIN_USER`, `$env:JELLYFIN_PASSWORD` (never in scripts) | Update env, re-run `check_status.ps1 -AsJson` (expect exit 0). No file edits needed. |
| Jellyfin API key/token | Jellyfin dashboard -> API Keys; `$env:JELLYFIN_API_KEY` for automation | Issue new key, revoke old, update env + `deployments/.env` (untracked), restart panel/proxy. |
| Rclone OAuth (`config/rclone.conf`) | `F:\Jellyfin\config\rclone.conf` (untracked; template at `config/rclone.conf.template`) | `rclone config reconnect <remote>:` then `rclone about <remote>:` to verify, restart mounts. Never commit the real file. |
| Cloudflared / Caddy TLS | `config/cloudflared/config.yml` (from `.template`), Caddy data | Rotate tunnel token/cert via provider dashboard, update untracked config, restart Caddy/tunnel. |

After any rotation: run `test_mcp_server.ps1` (MCP still lists/calls) and
`check_status.ps1` (Jellyfin auth still 0).

## 3. Cold-restart validation checklist

Use this after any reboot, power loss, or `supervisor.ps1 -Mode Stop`. It
follows the boot order in §1 and expects the defer-until-logon delay in §1a:
nothing but the NSSM gdrive mount is up until you sign in and the ONLOGON
task fires. Collect forensics **before** restarting a crashed loop, because
restarts rotate evidence.

### 3a. Before you reboot

- [ ] `TORBOX_API_KEY`, `JELLYFIN_USER`, `JELLYFIN_PASSWORD` present in env (no hardcoded fallbacks).
- [ ] `pwsh -File supervisor.ps1 -Mode Forensics` saved a timestamped zip under `backups/` (send it + `Status` output with any support request).
- [ ] `pwsh -File supervisor.ps1 -Mode Status` shows all six rows `Healthy=True` (or note which gate was already red).

### 3b. After power-on + logon (in order, with waits)

- [ ] Logon task fired: `Get-ScheduledTaskInfo -TaskName "MediaStackSupervisor"` shows a recent `LastRunTime`; `run\supervisor.pid` points at a live PID.
- [ ] **1 — gdrive:** `Test-Path F:\Media` is true; `Get-Service RcloneGdriveMount` is `Running`. If missing, `nssm start RcloneGdriveMount`, wait 15 s, else check `logs\rclone-mount.log`. Allow up to 30 s for the fallback script path.
- [ ] **2 — torboxmount:** `Test-Path T:\` is true; one `rclone mount torbox` process. If stale, do **not** kill a healthy mount — run `mount-torbox.ps1` once and wait the full 30 s for WinFsp init; `T:\` flapping after rapid retries means you restarted too fast.
- [ ] **3 — proxy:** `Invoke-RestMethod http://127.0.0.1:8888/health` OK within 30 s; `Invoke-RestMethod http://127.0.0.1:8888/mylist` fresh (<15 min). Exactly one `LISTENING` PID on `127.0.0.1:8888`.
- [ ] **4 — bridge:** `Invoke-RestMethod http://127.0.0.1:18099/health` OK within 10 s **after** proxy is green. If proxy is red, fix proxy first — bridge restarts are deferred by design.
- [ ] **5 — Jellyfin:** `pwsh -File check_status.ps1 -AsJson` exits 0 within 60 s of start (server reachable + auth OK + libraries present). Exit 1 = warming/degraded (no libraries yet); exit 2 = investigate API/auth.
- [ ] **6 — panel:** `http://127.0.0.1:18080` loads; Play-in-PotPlayer button invokes `potplayer://`. Expect green only after the real endpoint re-probe passes.
- [ ] **Views warming:** `pwsh -File check_views_after_restart.ps1 -AsJson` exits 0. Exit 1 right after reboot is normal — wait 60 s for the library scan and re-run; if still 1/2, trigger `POST /Library/Refresh` via `check_user_views.ps1`, then inspect Jellyfin `data/log/*.log`.
- [ ] **Watchdog settled:** `Select-String "WATCHDOG|ALERT|DEDUPE|GUARD" logs\supervisor.log -Tail 30` shows `fail counter reset` / `restart OK`, no `ALERT ... crash-loop suspected (5+ in 10m)`, and dedupe lines keep exactly one listener per port.
- [ ] **Playback chain:** `test_dpl.ps1 -SkipLaunch` passes; live launch plays full-season `.dpl`. `show-playback-log.ps1` shows 5 s progress; Next-Up advances at 80%.
- [ ] **Disk + backups:** `F:\` prefetch <20 GB; `cache/`, `transcodes/`, `logs/` not filling OS disk. `scripts/backup-and-vacuum-db.ps1` scheduled task succeeded.

If views are empty after reboot: wait 60 s for scan, re-run
`check_views_after_restart.ps1`; if still 1/2, trigger
`POST /Library/Refresh` via `check_user_views.ps1`, then inspect Jellyfin logs.

One-shot ordered re-run without the watchdog loop (safe to retry after fixing a gate):

```powershell
pwsh -File supervisor.ps1 -Mode Start
pwsh -File supervisor.ps1 -Mode Status
pwsh -File check_status.ps1 -AsJson; $LASTEXITCODE
pwsh -File check_views_after_restart.ps1 -AsJson; $LASTEXITCODE
```

## 4. Log locations

| Log | Path | What to look for |
|-----|------|------------------|
| Launcher bridge | `F:\Jellyfin\logs\potplayer-launcher.log` | `RAW:`, `STRM resolve`, `Stale VFS`, `FULL-CACHE`, `Torbox proxy URL`, `RESUME:` |
| Prefetch | `F:\Jellyfin\logs\rclone-prefetch.log` | `copyto` progress/errors (only when `FULLCACHE=1`). |
| Playback watch | `show-playback-log.ps1` console + `logs/` | Episode hint, 5s ticks, 80% played marking. |
| `launcher_debug.log` | `F:\Jellyfin\launcher_debug.log` (root, untracked) | Legacy launcher debug (do not commit). |
| Jellyfin server | Jellyfin `data/log/*.log` + `scripts/export-metrics.ps1` | Scan errors, auth 401, transcode (NVENC) failures. |
| Proxy | stdout of `torbox-proxy.py` + `/metrics` | `mylist` age, token-bucket 429s, `requestdl` failures. |
| Supervisor | `logs\supervisor.log` (10 MB x 5 rotation) + Scheduled task history + `supervisor.ps1 -Mode Status` output | `ORDERED START` / `ABORT` naming the exact failed gate; `WATCHDOG` fast-retry vs `backoff`; `DEDUPE`/`GUARD` kept vs killed PIDs; `FORENSICS` dupe spawner lines; `ALERT` crash-loop (5 in 10 m, log-only). |
| Forensics bundle | `backups\forensics-<timestamp>.zip` via `supervisor.ps1 -Mode Forensics` | Rotated supervisor/launcher logs, proxy+bridge logs when present, every `run\*.pid`, Drive sync state JSON. Staged via temp copy so locked live logs warn-and-skip instead of failing. Collect before restarting a crash. |
| MCP server | stderr of `mcp-servers/rclone-storage/server.py` | Validation rejections (`-32602`), rclone `Error (code)`. |

## 5. Common operations

```powershell
# Supervisor: one ordered start, status table, forensics bundle:
pwsh -File supervisor.ps1 -Mode Start
pwsh -File supervisor.ps1 -Mode Status
pwsh -File supervisor.ps1 -Mode Forensics
# Long-running watchdog (normally via the MediaStackSupervisor ONLOGON task):
pwsh -File supervisor.ps1 -Mode Run
# Reverse-order stop (panel -> ... -> gdrive):
pwsh -File supervisor.ps1 -Mode Stop

# Dry-run cleanups first (no deletes):
pwsh -File clean_and_setup_libraries.ps1 -WhatIf
pwsh -File cleanup_extra_libraries.ps1 -WhatIf -OlderThanDays 7
pwsh -File cleanup_and_check_items.ps1 -WhatIf
pwsh -File delete_stale_views.ps1 -WhatIf -OlderThanDays 30

# JSON health for monitoring (Nagios 0/1/2):
pwsh -File check_status.ps1 -AsJson; $LASTEXITCODE
pwsh -File check_user_views.ps1 -AsJson; $LASTEXITCODE
pwsh -File check_views_after_restart.ps1 -AsJson; $LASTEXITCODE

# Watchdog tail (backoff vs crash-loop):
Select-String "WATCHDOG|ALERT|DEDUPE|GUARD|ABORT" logs\supervisor.log -Tail 40

# MCP smoke:
pwsh -File test_mcp_server.ps1
python -m py_compile mcp-servers/rclone-storage/server.py

# Parser gate (must be 0 errors):
pwsh -NoProfile -Command "$files=@('check_status.ps1','check_user_views.ps1','check_views_after_restart.ps1','clean_and_setup_libraries.ps1','cleanup_and_check_items.ps1','cleanup_extra_libraries.ps1','delete_stale_views.ps1','test_dpl.ps1','test_mcp_server.ps1','annotate_screenshot.ps1','PotPlayerLauncher.ps1'); $e=0; foreach($f in $files){$errs=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$errs); Write-Host \"$f errors=$($errs.Count)\"; $e+=$errs.Count}; exit $e"
```
