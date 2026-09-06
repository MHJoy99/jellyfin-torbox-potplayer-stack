# Control Panel Cards and Endpoints

This guide explains every panel card and every HTTP endpoint, so a green button always maps to a real process plus a real health probe.

## Contents

- [Opening the panel](#opening-the-panel)
- [Service cards](#service-cards)
- [Badge semantics](#badge-semantics)
- [Bulk actions and sync](#bulk-actions-and-sync)
- [Status, metrics, and timeline](#status-metrics-and-timeline)
- [Playback cards](#playback-cards)
- [HTTP endpoints](#http-endpoints)
- [Safety and reinstall](#safety-and-reinstall)

## Opening the panel

Open `http://127.0.0.1:18080/` from the Start Menu shortcut named for the control panel. The panel is registered as a hidden per-user logon task, so it is available after sign-in without a console window. It binds to localhost only and never exposes credentials or service command lines through its HTTP API. If the shortcut or task is missing, reinstall with the panel installer from [Install](install.md), then recheck health as shown in [Quickstart](quickstart.md).

## Service cards

Each card shows process matches, listener PID, health state, and start, stop, and restart actions with per-service locks that prevent overlapping operations.

| Card | What it manages | Healthy means |
| --- | --- | --- |
| Jellyfin | Server process plus web API on the Jellyfin HTTP port | Public system info answers without auth. |
| TorBox Proxy | Python proxy in `server/torbox-proxy.py` on the proxy port | Proxy health answers and metrics are fresh. |
| PotPlayer Bridge | Bridge helper on the bridge port, requires proxy first | Bridge health answers while proxy is also healthy. |
| Drive Mount | Drive VFS mount through the mount service | Media folder path is browsable plus mount process exists. |
| TorBox Mount | TorBox VFS mount process plus rclone RC | **rclone process plus RC `POST :5572/rc/noop` OK; `T:\` visibility is informational only.** |
| Panel self | The panel process itself | Panel health answers on the panel port. |

Drive health is path plus process, not config alone. **TorBox health is process plus RC authoritative:** the panel treats `rc_ok` (loopback `POST http://127.0.0.1:5572/rc/noop`, no auth, ~2s timeout) together with a matching `mount torbox` rclone process as the verdict. `T:\` drive-letter visibility is session-scoped and informational only — `path_visible=false` from Session 0 while the mount runs in Session 1 is normal and never fails the card on its own. The payload exposes both `rc_ok` and `path_visible`, with details like `Serving T:\ (rclone PID <pid> + RC :5572 OK; path visible=...)`, `rclone process present; waiting for RC :5572` (starting), or `not mounted (no rclone process, RC :5572 down)` (stopped). Duplicate proxy listeners are reconciled on Start all so a green state never hides two owners for one port. The same service list and restart backoff are enforced by [Supervisor](supervisor.md).

## Badge semantics

Badges are rendered from `/api/health` first, with fallback to the last `/api/status` payload in memory, then `/api/metrics`, then the current DOM. The badge tooltip is the server `detail` string, and the card border (`st-healthy`, `st-warning`, `st-starting`, `st-stopped`) always matches the badge. Unknown states map to `stopped`.

| Badge | Meaning | Safe next step |
| --- | --- | --- |
| `Healthy` (green) | Process **and** probe both OK. For TorBox this means rclone process plus RC `:5572` OK regardless of `T:\` visibility. | Nothing; polling with `?light=1` is enough. |
| `Starting` | Process present but probe/path not yet OK. For TorBox: process present while waiting for RC `:5572`. | Wait 10–30s (Jellyfin up to 60s) for the health gate; do not hammer restart. |
| `Sync errors`, `No process`, `Duplicate process` (amber `warning`) | Responding or visible but needs attention: Drive sync errors at or above threshold in the last day; path visible without an rclone process; two or more proxy processes owning one port. | Check timeline and metrics, let dedupe finish, then restart only the named service. |
| `Stopped` (red/grey) | Neither process nor probe OK. For TorBox: no rclone process **and** RC `:5572` down. | Start that service, or use Start all in dependency order; collect forensics first if it crash-loops. |

## Bulk actions and sync

Bulk buttons follow mount-first ordering in both directions, with per-service locks and health waits so manual clicks cannot fight the watchdog.

- Start all starts mounts first, then proxy, bridge, Jellyfin, and panel, aborting on the first unhealthy gate.
- Restart all restarts in the same dependency order with health waits between steps (10–30s per service, Jellyfin up to 60s).
- Stop all stops in reverse order, with mounts last so running services do not lose files mid-shutdown.
- Sync TorBox requests the existing smart-sync scheduled task rather than duplicating its work, so manual clicks and the thirty-minute schedule share one single-instance path.

All launches use hidden background processes, and the panel re-probes real endpoints after each action before flipping a card to green. Safe-action rules: overlapping actions on the same bucket return `409 busy` (buckets are `proxy`, `bridge`, `panel`, `mount`, `sync`; `all` takes every bucket with a 60s timeout), so wait for the toast plus status refresh instead of double-clicking. Restarts are allowlisted to `jellyfin`, `proxy`, `bridge`, `gdrive`, and `torboxmount` (or `all`); anything else is rejected with the allowed list. Starting the proxy also dedupes listeners, so never launch mount or proxy scripts by hand. Never start Jellyfin on a missing mount.

## Status, metrics, and timeline

The status view merges live process scans with proxy metrics and log tailing.

- Status shows per-service state, PIDs, listener PIDs, VFS details, and playback summary, with `?light=1` for fast polling (cached process scan, skips Drive log parse, skips TorBox VFS cache detail and last-play enrichment). Full polls add proxy uptime and active-stream enrichment plus TorBox VFS cache bytes, file, and directory counts.
- Metrics proxy the TorBox proxy metrics with a 5s cache and map live counters onto stable keys, including request counts, token bucket state, link-cache hit ratio, latency histograms, stream slots, and range coalescing. It is also the last badge fallback source before the DOM.
- Activity tails recent log lines across launcher, proxy, bridge, and sync sources with a shared limit.
- Timeline merges timestamped entries by source with quotas per source, including Drive sync errors from the last day and TorBox VFS null counters.
- Config exposes non-secret panel settings for the UI without leaking tokens.

Use metrics for rate-limit questions from [TorBox](torbox.md) and timeline for who-restarted-what questions from [Supervisor](supervisor.md). For TorBox, trust `rc_ok` plus the rclone process in status; `path_visible` only tells whether this panel session can see the `T:\` letter.

## Playback cards

Playback cards show the last bridge play, the parsed playlist entries, and the freshness window that decides whether PotPlayer is considered still running. Playlist context parses the proxy URL layout of torrent, file, and display name to recover show and season hints. Playing detail combines the base file detail with live player status when the freshness window passes. For resume semantics behind these cards, see [PotPlayer](potplayer.md) and [Jellyfin](jellyfin.md).

## HTTP endpoints

All endpoints bind `127.0.0.1` only, with security headers (`Content-Security-Policy: default-src 'self'`, `nosniff`, `no-referrer`), loopback `Origin` checks, and structured JSON errors (unknown API paths are `404`, never stack traces).

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/health` | GET | Minimal liveness `{"status":"ok","service":"jellyfin-control-panel"}` for supervisors, installers, and the VBS opener. No per-service detail. |
| `/api/health` | GET | Fast aggregate for badges: proxy `:8888/health`, bridge `:18099/health`, Jellyfin public info `:8096/System/Info/Public`, and TorBox RC noop `POST :5572/rc/noop` (about 2s per probe). Returns `{status, overall, services, time}` where `overall` is `healthy` only when every listed service is healthy. Primary badge source. |
| `/api/status` | GET | Full service plus playback plus VFS payload `{panel, services, playback, activity, timeline}`. Each service carries `state`, `state_label`, `detail`, `process_count`, `pids`, and `last_code` (plus `player` for bridge and `version`/`server_name` for Jellyfin; TorBox also carries `rc_ok` and `path_visible`). Append `?light=1` for polling. |
| `/api/activity` | GET | Recent merged log lines with a limit parameter. |
| `/api/metrics` | GET | Cached (5s TTL) proxy `/metrics` plus derived panel states and TorBox VFS stats. Maps request counts, token bucket, link-cache hit ratio, latency histograms, stream slots, and range coalescing onto stable keys. Badge fallback source. |
| `/api/timeline` | GET | Merged timeline entries with per-source quotas and pagination. |
| `/api/config` | GET and POST | Read non-secret config, with writes restricted to allowed keys. `POST` is read-only rejected (`405`); only static ports, safe paths, and versions are ever returned. |
| `/api/action` | POST | `{"service","action"}` for `start`, `stop`, or `restart` on one service or `all`, plus `{"service":"torbox-sync","action":"sync"}`. Returns `{ok, message, status}` with a fresh re-probe. Enforces the restart allowlist, per-bucket locks (`409` when busy), admin rate limit (`30/min/IP` → `429` with `Retry-After`), and `Origin` check (`403` on cross-origin). |
| `/api/restart` | POST | `{"service"}` restart for allowlisted services only (`jellyfin`, `proxy`, `bridge`, `gdrive`, `torboxmount`), rejecting anything else with `400` plus the allowed list. |

Static files serve the single-page UI with gzip when accepted. Poll with `GET /api/status?light=1` plus `GET /api/health` for badges, and use `POST /api/action` for all mutations. Port numbers and loopback defaults are listed in [Architecture](architecture.md).

## Safety and reinstall

The panel never returns env secrets, tokens, or full command lines, binds loopback only, checks `Origin` against loopback or the same `Host`, and rate-limits admin POSTs. Restart is allowlisted to known services, and overlapping actions are serialized by per-service locks rather than queued. Safe-action checklist: prefer bulk actions in dependency order, wait for each health gate before the next click, treat `409 busy` and `429 rate-limited` as wait signals (not errors to force-retry), use Sync TorBox instead of hand-running sync, and never launch proxy or mount processes outside the panel or supervisor. If the page loads but actions fail, confirm the supervisor state with Status mode and collect forensics as shown in [Supervisor](supervisor.md). To reinstall or repair, re-run the panel installer, which upgrades the task and shortcut in place, verifies task existence, and rechecks health. Full removal is covered in [Install](install.md), and every failure pattern with a red card is covered in [Troubleshooting](troubleshooting.md).

---

Back to [Docs Index](index.md).
