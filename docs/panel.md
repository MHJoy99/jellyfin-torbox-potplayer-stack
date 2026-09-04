# Control Panel Cards and Endpoints

This guide explains every panel card and every HTTP endpoint, so a green button always maps to a real process plus a real health probe.

## Contents

- [Opening the panel](#opening-the-panel)
- [Service cards](#service-cards)
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
| TorBox Mount | TorBox VFS mount process | TorBox mount path is browsable plus mount process exists. |
| Panel self | The panel process itself | Panel health answers on the panel port. |

Mount health is checked against real mount paths and live rclone processes, not config alone. Duplicate proxy listeners are reconciled on Start all so a green state never hides two owners for one port. The same service list and restart backoff are enforced by [Supervisor](supervisor.md).

## Bulk actions and sync

Bulk buttons follow mount-first ordering in both directions.

- Start all starts mounts first, then proxy, bridge, Jellyfin, and panel, aborting on the first unhealthy gate.
- Restart all restarts in the same dependency order with health waits between steps.
- Stop all stops in reverse order, with mounts last so running services do not lose files mid-shutdown.
- Sync TorBox requests the existing smart-sync scheduled task rather than duplicating its work, so manual clicks and the thirty-minute schedule share one single-instance path.

All launches use hidden background processes, and the panel re-probes real endpoints after each action before flipping a card to green.

## Status, metrics, and timeline

The status view merges live process scans with proxy metrics and log tailing.

- Status shows per-service state, PIDs, listener PIDs, VFS details, and playback summary, with a light mode that skips expensive scans.
- Metrics proxy the TorBox proxy metrics with a short cache and map live counters onto stable keys, including request counts, token bucket state, link-cache hit ratio, latency histograms, stream slots, and range coalescing.
- Activity tails recent log lines across launcher, proxy, bridge, and sync sources with a shared limit.
- Timeline merges timestamped entries by source with quotas per source, including Drive sync errors from the last day and TorBox VFS null counters.
- Config exposes non-secret panel settings for the UI without leaking tokens.

Use metrics for rate-limit questions from [TorBox](torbox.md) and timeline for who-restarted-what questions from [Supervisor](supervisor.md).

## Playback cards

Playback cards show the last bridge play, the parsed playlist entries, and the freshness window that decides whether PotPlayer is considered still running. Playlist context parses the proxy URL layout of torrent, file, and display name to recover show and season hints. Playing detail combines the base file detail with live player status when the freshness window passes. For resume semantics behind these cards, see [PotPlayer](potplayer.md) and [Jellyfin](jellyfin.md).

## HTTP endpoints

All endpoints are loopback-only GET or POST handlers with security headers and origin checks.

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/health` | GET | Minimal liveness for supervisors and installers. |
| `/api/health` | GET | JSON health with the same liveness plus version info. |
| `/api/status` | GET | Full service plus playback plus VFS payload, with light mode for polling. |
| `/api/activity` | GET | Recent merged log lines with a limit parameter. |
| `/api/metrics` | GET | Cached proxy metrics plus derived panel states. |
| `/api/timeline` | GET | Merged timeline entries with per-source quotas and pagination. |
| `/api/config` | GET and POST | Read non-secret config, with writes restricted to allowed keys. |
| `/api/action` | POST | Start, stop, or restart one service or all, with lock buckets. |
| `/api/restart` | POST | Restart allowlisted services only, rejecting anything else. |

Static files serve the single-page UI with gzip when accepted, while unknown API paths return structured errors rather than stack traces. Port numbers and loopback defaults are listed in [Architecture](architecture.md).

## Safety and reinstall

The panel never returns env secrets, tokens, or full command lines, and restart is allowlisted to known services. If the page loads but actions fail, confirm the supervisor state with Status mode and collect forensics as shown in [Supervisor](supervisor.md). To reinstall or repair, re-run the panel installer, which upgrades the task and shortcut in place, verifies task existence, and rechecks health. Full removal is covered in [Install](install.md), and every failure pattern with a red card is covered in [Troubleshooting](troubleshooting.md).

---

Back to [Docs Index](index.md).
