# Jellyfin Control Panel

The local control panel is available at:

`http://127.0.0.1:18080/`

It is bound to localhost only. The panel can start, stop, and restart:

- Google Drive Mount (`F:\Media` + `R:` alias) — via the `RcloneGdriveMount` NSSM service
- TorBox Mount (`T:\`) — via `E:\MediaServer\mount-torbox.ps1` / process stop
- Jellyfin on port `8096`
- TorBox Proxy on port `8888`
- PotPlayer Bridge on port `18099`

Mount health is checked against live processes plus real probes (not just config). **Start all / Restart all / Stop all** include the mounts (mounts start first, stop last). **Sync TorBox** requests the existing `MediaServer_TorboxSmartSync` scheduled task, so manual runs use the same single-instance path as the 30-minute schedule.

All launches use hidden background processes. The panel checks the real health endpoints and process listeners, so a green badge is never based on configuration alone.

> **TorBox health contract (authoritative):** `T:\` health is **rclone process + RC `POST http://127.0.0.1:5572/rc/noop`**. That loopback RC proves the mount is alive from any session. `T:\` drive-letter visibility (`os.path.isdir`) is **informational only** — `False` from Session 0 while the mount runs in Session 1 is normal and is never a failure criterion on its own. The UI exposes `rc_ok` plus `path_visible` so `Serving T:\ (RC :5572 OK; path visible=...)` stays green even when the letter is invisible to the panel session.

## Endpoints (loopback only, `127.0.0.1:18080`)

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/health` | GET | Minimal liveness `{"status":"ok"}` for supervisors, installers, and the VBS opener. No per-service detail. |
| `/api/health` | GET | Fast aggregate for badges: proxy (`:8888/health`), bridge (`:18099/health`), Jellyfin public info (`:8096/System/Info/Public`), TorBox RC noop (`:5572/rc/noop`). Returns `{status, overall, services, time}`. |
| `/api/status` | GET | Full payload for cards: `{panel, services, playback, activity, timeline}`. Supports `?light=1` for fast polling (cached process scan, skips Drive log parse and VFS cache detail). |
| `/api/metrics` | GET | Cached (5s) TorBox proxy `/metrics` plus derived panel states: request counts, token bucket, link-cache hit ratio, latency histograms, stream slots, range coalescing, TorBox VFS cache. Badge fallback source. |
| `/api/action` | POST | `{"service","action"}` for `start` / `stop` / `restart` on one service or `all`, plus `{"service":"torbox-sync","action":"sync"}`. Returns `{ok, message, status}` with a fresh `status` re-probe. Restart is allowlisted; overlapping calls get `409 busy`. |

`GET /api/status?light=1` is the poll loop; `GET /api/health` is the badge fast path with fallback to last `/api/status`, then `/api/metrics`. `POST /api/restart` (`{"service"}`) is the allowlisted restart alias. See `docs/panel.md` for the full table.

## Badge semantics

Badges render from `/api/health` first, then last `/api/status`, then `/api/metrics`. The tooltip (`title`) is the server `detail` string.

| Badge | Meaning | What to do |
| --- | --- | --- |
| `Healthy` (green) | Process **and** probe both OK. Proxy/bridge/Jellyfin: HTTP probe OK. Drive: `F:\Media` browsable + rclone process. TorBox: rclone process + RC `:5572` OK (path visibility ignored). | Nothing. |
| `Starting` | Process present, probe/path not yet OK (for TorBox: process present, waiting for RC `:5572`). | Wait 10–30s (Jellyfin up to 60s); do not hammer restart. |
| `Sync errors` / `No process` / `Duplicate process` (amber `warning`) | Responding/visible but needs attention: Drive sync errors ≥3/24h; path visible without rclone process; 2+ proxy owners for one port. | Check timeline/metrics; let Start-all dedupe finish before manual starts. |
| `Stopped` (red/grey) | Neither process nor probe OK (for TorBox: no process **and** RC down). Unknown states map here. | Start that service (or Start all in dependency order). |

## Safe actions

- **Order matters:** Start (and restart) goes mounts → proxy → bridge → Jellyfin; Stop goes reverse so services never lose files mid-shutdown. Never start Jellyfin on a missing mount.
- **One flight at a time:** per-service locks (`proxy`, `bridge`, `panel`, `mount`, `sync`; `all` takes all) serialize actions with a 60s timeout. A second click while busy gets `409`; wait for the toast plus status refresh instead of retrying.
- **Allowlisted restarts only:** `jellyfin`, `proxy`, `bridge`, `gdrive`, `torboxmount` (or `all`). Anything else is `400` with the allowed list.
- **Sync is single-instance:** Sync TorBox only triggers the existing scheduled task; it never duplicates the 30-minute pipeline. Do not run the sync script by hand.
- **No duplicate launches:** Start-all reconciles duplicate proxy listeners (keeps one owner); never launch the Python mount/proxy scripts manually.
- **Loopback + no secrets:** the API binds `127.0.0.1` only, enforces same-origin/loopback `Origin`, rate-limits admin POSTs (30/min/IP → `429`), and never returns tokens, env secrets, or full command lines.
- **When red:** check Status plus timeline, collect supervisor forensics before a crash-loop restart, then follow `docs/troubleshooting.md` red-card patterns.

## Opening it

Search Windows for **Jellyfin Control Panel**. The shortcut is installed in the user Start menu. The panel itself is registered as the hidden **Jellyfin Control Panel** logon task, so the page is available after sign-in without opening a terminal or a window.

## Permanent duplicate-proxy fix

The old `torbox_proxy_hidden.vbs` Startup entry duplicated the `TorboxProxy` scheduled task. The Startup entry was removed after a verified backup at:

`F:\Jellyfin\backups\startup-cleanup-20260824\torbox_proxy_hidden.vbs`

The panel also reconciles any duplicate TorBox proxy listeners when **Start all** is pressed.

## Reinstall or repair the panel

Run this from PowerShell if the shortcut or logon task ever needs to be recreated:

```powershell
PowerShell -ExecutionPolicy Bypass -File F:\Jellyfin\install-control-panel.ps1
```

The panel does not expose credentials or service command lines through its HTTP API.
