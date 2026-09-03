# NexusMedia Jellyfin Stack

High-performance Jellyfin media stack: TorBox → rclone VFS (`T:\`) → `.strm`
libraries → Jellyfin + TMDB → PotPlayer direct-stream via local bridge/proxy,
with a web control panel and a watchdog supervisor.

## Layout

| Path | Role |
|---|---|
| `server/torbox-proxy.py` | Local HTTP proxy `:8888` (TorBox link cache, token bucket, `/metrics`, `/mylist`) |
| `potplayer-launcher.ps1` | Full-season launcher, resume `/seek=`, shared-mylist-first |
| `potplayer-sync-tracker.ps1` | Jellyfin resume/progress sync, pause-aware |
| `show-playback-log.ps1` | Watch-logs console window |
| `supervisor.ps1` (+ `Start-/Stop-Jellyfin.ps1`) | Watchdog that owns all services |
| `control-panel/` | Web panel `:18080` (status, metrics, playback) |
| `gdrive-library-sync.ps1` | Google Drive library sync into Jellyfin |
| `mcp-servers/` | MCP server helpers (e.g. rclone storage) |

## Setup

1. Set secrets **as environment variables** (never commit them):
   - `$env:TORBOX_API_KEY` (Machine or User scope) — required by the proxy,
     launcher and supervisor (which re-reads it from the registry).
2. `pwsh -File supervisor.ps1` (or run the `MediaStackSupervisor` scheduled task).
3. Panel: http://127.0.0.1:18080 · Proxy: http://127.0.0.1:8888 · Jellyfin: http://127.0.0.1:8096

## Notes

- `server/`, `data/`, `config/`, `logs/`, `cache/`, `transcodes/` are local
  runtime artifacts and are intentionally **not** tracked (see `.gitignore`).
- TorBox API calls require `?token=` query auth (header-only returns HTTP 422).
- Proxy stays on HTTP/1.0; HTTP/1.1 hangs on missing `Content-Length`.
