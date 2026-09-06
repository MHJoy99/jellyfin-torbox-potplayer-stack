# Troubleshooting

This guide maps symptoms to causes to fixes for the six areas that break most often: mounts, proxy, bridge, panel, Jellyfin, and scheduled tasks. Ports, paths, task names, and health URLs below match [Architecture](architecture.md), [Supervisor](supervisor.md), and the installers.

## How to use this guide

1. Run Status first, then probe the three loopback health URLs from [Quickstart](quickstart.md):

```powershell
pwsh -File supervisor.ps1 -Mode Status
Invoke-RestMethod http://127.0.0.1:8888/health
Invoke-RestMethod http://127.0.0.1:18099/health
Invoke-RestMethod http://127.0.0.1:18080/health
Invoke-RestMethod http://127.0.0.1:8096/System/Info/Public
```

2. Jump to the matching table below. The fastest check is listed first in each Fix cell.
3. Collect forensics before restarting a crash loop (`pwsh -File supervisor.ps1 -Mode Forensics`), then restart in mount-first order. Never post tokens, passwords, or CDN URLs when asking for help — see [Reference](reference.md).

Health-port reference: Jellyfin `8096`, proxy `8888` (`server/torbox-proxy.py`), bridge `18099`, panel `18080` (`control-panel/control_panel.py`), TorBox rclone RC `5572`, GDrive rclone RC `5573`. All bind to `127.0.0.1` by default.

## Mounts (`T:\`, `F:\Media`)

TorBox serves `T:\` via `mount-torbox.ps1` (no scheduled task, RC `127.0.0.1:5572`). Drive serves `F:\Media` via the NSSM service `RcloneGdriveMount` (`gdrive-media:` remotes, RC `127.0.0.1:5573`). `R:\` is a kernel alias to `F:\Media` on this host. Start mounts before Jellyfin, per [Supervisor](supervisor.md).

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Listings exist but files report a few dozen bytes, `.strm` playback fails instantly, Jellyfin scans stubs without posters | Stale VFS dir-cache (default 30s window) or TorBox remote changed without refresh | Confirm `Test-Path T:\` and `Test-Path F:\Media`, confirm `Get-Process rclone` shows both mounts, trigger a targeted refresh `Invoke-RestMethod http://127.0.0.1:5572/vfs/refresh -Method Post -Body (@{dir=(Split-Path $stalePath -Parent)} \| ConvertTo-Json) -ContentType 'application/json'`, wait one dir-cache window, then `POST /Library/Refresh`. |
| `T:\` not browsable after reboot, VFS refresh calls fail, supervisor aborts before proxy | TorBox mount process never started (it has no scheduled task) | Run `pwsh -File supervisor.ps1 -Mode Status`, start the fallback mount script, wait up to 30s for `Test-Path T:\`, then start proxy, bridge, Jellyfin, and panel in order. Never start Jellyfin first on a missing mount. |
| `F:\Media` and `R:\` both unresolvable, TorBox `T:\` unaffected, no `gdrive-media` rclone process | NSSM service `RcloneGdriveMount` stopped or not installed; legacy logon task `Mount Google Shared Drive R` fails while the `R:` DOS-device alias exists | Check the service state, re-run `install-rclone-service.ps1` (Automatic, Session 0, `gdrive-media:` to `F:\Media`), confirm `Get-ChildItem F:\Media, R:\` lists `Movies` and `Series`, then `POST /Library/Refresh`. Prefer the NSSM service over the legacy `R:` logon mount on this host. |
| RC call to `:5572` or `:5573` times out while the drive itself browses fine | RC disabled, wrong port, or rclone restarted without `--rc --rc-addr` flags | Confirm TorBox RC is `http://127.0.0.1:5572` and GDrive RC is `http://127.0.0.1:5573`, confirm the mount command includes `--rc --rc-no-auth` with the matching `--rc-addr`, remount with the documented flag set, then retry `vfs/stats` before `vfs/refresh`. |

## Proxy (`127.0.0.1:8888`, `server/torbox-proxy.py`)

Owns `/health`, `/metrics`, `/mylist`, and `/torbox/{torrent}/{file}/{name}` 302 redirects to fresh CDN links. Requires HTTP/1.0 clients and a valid `TORBOX_API_KEY` at Machine or User scope (name only — never paste the value).

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Health probe times out, panel metrics stall, playback waits forever | Proxy process down, duplicate listener on `8888`, or client using HTTP/1.1 without `Content-Length` | Confirm one listener owns `8888` via Status mode, keep the listening PID and stop non-listening duplicates, keep proxy clients on HTTP/1.0 (default — do not front `:8888` with a buffering reverse proxy), restart only the proxy before touching downstream services. Design and counters are in [Architecture](architecture.md). |
| Proxy logs auth failures, `mylist` never refreshes, launcher falls back without CDN links | Missing env value in this shell, or header-only auth which returns HTTP 422 | In a fresh shell confirm the `TORBOX_API_KEY` variable name resolves, confirm the supervisor re-read the live Machine-then-User value on start, confirm the proxy builds query auth, then restart proxy plus supervisor and retest `/health` plus `/mylist`. Rotate a suspect key with the order in [TorBox](torbox.md). |
| Download-link calls return rate-limit responses, `mylist` takes many seconds, refreshes pile up | Token bucket empty, cooldown active, or callers polling past the 10-minute shared cache | Check `http://127.0.0.1:8888/metrics` for bucket tokens, cooldown state, and singleflight coalescing, reduce manual `/mylist` refreshes to the shared window, let background tokens recover before bulk plays. Tuning is in [Architecture](architecture.md). |
| Two `torbox-proxy.py` processes for one port, health flaps between OK and down | Manual `python server/torbox-proxy.py` launch racing the watchdog or panel Start all | Run Status mode to find the listening PID, keep that PID, stop the non-listening duplicates, let the watchdog listener guard settle, then use panel Start all or `supervisor.ps1 -Mode Start` instead of launching scripts by hand. |

## Bridge (`127.0.0.1:18099`, `potplayer_http_bridge.py`)

Health at `/health`, player status at `/status`. Requires proxy healthy first; the supervisor waits 10s on bridge health and aborts the chain on failure.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Bridge health fails while proxy health also fails | Dependency order violated — bridge is deferred while proxy is down by design | Fix the proxy table above first, confirm `http://127.0.0.1:8888/health`, then recheck `http://127.0.0.1:18099/health`. Do not restart the bridge in isolation when the proxy is red. |
| Two `potplayer_http_bridge.py` processes, health flaps, restarts spawn more owners | Duplicate bridge listener on `18099` from manual start plus watchdog | Run Status mode, keep the listening PID for `18099`, stop the non-listening duplicates, let the listener guard settle before any manual start. Process pattern and ports are in [Panel](panel.md) and [Supervisor](supervisor.md). |
| Panel playback card shows a stale play or no playlist entries | Bridge restarted so `/status` freshness window expired, or playlist used direct CDN URLs instead of stable `:8888` proxy URLs | Replay one episode through Jellyfin or the panel, confirm the playlist stores `http://127.0.0.1:8888/torbox/...` or `.../gdrive/...` URLs (never raw CDN), then recheck `/status` within the freshness window. Resume semantics are in [PotPlayer](potplayer.md). |

## Panel (`127.0.0.1:18080`, `control-panel/control_panel.py`)

Per-user hidden logon task `Jellyfin Control Panel` (Interactive, Limited) plus Start Menu shortcut `Jellyfin Control Panel.lnk`. Endpoints under `/api/*`, liveness at `/health`. Loopback-only with no login by design — never port-forward it without auth, per [Reference](reference.md).

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Installer warns the panel port is busy, or panel health returns another app | Conflicting app owns `18080` or a duplicated panel task spawned a second listener | Find the listener PID for `18080`, stop the conflicting app or move the panel port parameter, upgrade the existing `Jellyfin Control Panel` task in place rather than registering a duplicate, then recheck `http://127.0.0.1:18080/health`. Reinstall steps are in [Panel](panel.md). |
| Shortcut or logon task missing after sign-in, no console window ever appears | Task deleted, disabled, or installed under a different user | Confirm `Get-ScheduledTask -TaskName 'Jellyfin Control Panel'`, re-run `install-control-panel.ps1` to upgrade in place and recreate the shortcut, `Start-ScheduledTask -TaskName 'Jellyfin Control Panel'`, then recheck health. |
| Page loads but Start/Stop/Restart actions fail | Supervisor holds the ordered-start lock, or the panel allowlist rejected the service | Confirm `pwsh -File supervisor.ps1 -Mode Status` state, retry one service at a time, collect forensics before a crash-loop restart. Restart allowlist and locks are in [Panel](panel.md) and [Supervisor](supervisor.md). |

## Jellyfin (`127.0.0.1:8096`, `server/jellyfin.exe`)

Liveness without auth at `/System/Info/Public`. Data in `data/`, PID in `run/jellyfin.pid`, logs under `logs/`. Libraries are `.strm` files scanned on `POST /Library/Refresh`; verify with `check_status.ps1`, `check_user_views.ps1`, and `check_views_after_restart.ps1` (exit 0 healthy, 1 warming, 2 investigate).

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| User views empty immediately after restart, status auth passes | Warming scan still running (up to 60s) rather than a broken library | Wait 60s, re-run `check_views_after_restart.ps1 -AsJson`, trigger `POST /Library/Refresh` only when the code reports warming, inspect Jellyfin logs only when the code reports investigate. Confirm mounts were healthy before Jellyfin started, per [Jellyfin](jellyfin.md). |
| Views populated stubs or lost posters after a reboot | Scan raced a downed VFS mount and indexed tiny stubs | Confirm `Test-Path T:\` and `Test-Path F:\Media`, refresh the stale VFS path via RC `:5572`/`:5573`, delete stubs with the dry-run cleanup helpers, trigger `POST /Library/Refresh`, wait 60s, then recheck views. |
| Episodes always restart from zero, progress never moves, Next Up never advances | Launched link missed item/user/token/server fields, tracker singleton not running, or Jellyfin auth expired | Confirm the `potplayer://` link carried all four fields, confirm one tracker per item prefix is posting five-second ticks to `/Sessions/Playing/Progress`, tail the playback log for the 80%-played mark that drives `/PlayedItems`, then re-authenticate. Tracker timing is in [PotPlayer](potplayer.md). |

## Scheduled tasks and services

Supervisor owns services in order and creates no task itself. Sync tasks are run-only — keep them enabled but never supervise them as services.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Panel Sync TorBox does nothing or duplicates imports | `MediaServer_TorboxSmartSync` disabled, missing, or run twice (manual plus 30-minute schedule racing) | Confirm `Get-ScheduledTask -TaskName 'MediaServer_TorboxSmartSync'` exists and is Ready, use the panel Sync button (it requests the existing task — same single-instance path as the schedule) instead of running the sync script by hand. |
| Drive libraries never update or duplicate on every run | `MediaServer_GoogleDriveLibrarySync` (AtStartup, SYSTEM) removed, or sync state JSON deleted so every run looks new | Confirm the `MediaServer_GoogleDriveLibrarySync` task exists, restore the sync-state JSON from backup per [Reference](reference.md) instead of rescanning blind, run the task once on demand, then `POST /Library/Refresh`. Installer is `gdrive-library-sync.ps1`. |
| Panel never auto-starts at logon, or two panel tasks exist | `Jellyfin Control Panel` task deleted/disabled, or a reinstall duplicated it instead of upgrading in place | Keep exactly one `Jellyfin Control Panel` task (AtLogOn, current user, Limited), remove duplicates, `Start-ScheduledTask` once, confirm `/health`. Same rule applies to `MediaStackSupervisor` (ONLOGON, HIGHEST) — upgrade in place. |
| `Mount Google Shared Drive R` always fails with mountpoint in use | `R:` DOS-device alias plus NSSM `RcloneGdriveMount` already serving `F:\Media` — the legacy `R:` mount can never succeed on this host | Leave the NSSM `RcloneGdriveMount` service (Automatic) as the owner of `F:\Media`, disable the legacy `Mount Google Shared Drive R` logon task, confirm both `F:\Media` and `R:\` browse via the alias. |
| Rclone MCP health checks never run | Optional `Rclone MCP Health Check` task (Daily 04:30) not registered for this profile | Re-run `create_rclone_mcp.ps1` to register the Daily 04:30 probe, confirm with `Get-ScheduledTaskInfo`, keep it only when the MCP bridge profile is in use. |

---

Back to [Docs Index](index.md).
