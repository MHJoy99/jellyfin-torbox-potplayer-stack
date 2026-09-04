# NexusMedia Jellyfin Stack — Architecture

> Owned by tooling/docs track. Secrets are never hardcoded; all credentials come
> from environment variables (see RUNBOOK.md). Ports below are defaults and can
> be overridden via env / compose variables.

## 1. Stack diagram (text)

```
                        +-----------------------------+
                        |  Cloud Remotes / WebDAV     |
                        |  Google Drive, TorBox, SFTP |
                        +--------------+--------------+
                                       |  HTTPS / API
                                       v
                        +--------------+--------------+
                        |  rclone VFS cache engine    |
                        |  T:\ (TorBox)  G:\ / F:\   |
                        |  dir-cache 30s, RC :5572    |
                        +------+---------------+------+
                               |               |
                    .strm + file I/O    HTTP progressive
                               |               |
                               v               v
                  +------------+------+  +-----+---------------+
                  | Jellyfin :8096/8920|  | torbox-proxy :8888  |
                  | metadata, stream,   |  | CDN 302, /mylist,   |
                  | resume, Next-Up     |  | token-bucket,/metrics|
                  +------------+--------+  +-----+---------------+
                               |                       |
                    potplayer:// protocol              |
                    potplayer-launcher.ps1             |
                    PotPlayerLauncher.ps1 (shim)       |
                               |                       |
                               v                       v
                     +---------+---------+   +---------+---------+
                     | PotPlayer x64     |<--| HTTP/CDN media    |
                     | .dpl playlists    |   | (full-cache bar)  |
                     +---------+---------+   +-------------------+
                               |
                     potplayer-sync-tracker.ps1 (5s progress)
                               |
                               v
                     +---------+---------+
                     | control-panel     |
                     | web :18080        |
                     | status/metrics/   |
                     | playback buttons  |
                     +-------------------+
                               |
                     supervisor.ps1 watchdog
                     Start-/Stop-Jellyfin.ps1
```

Optional edge (docker profile):

```
  Internet :80/:443 -> Caddy (TLS, :80/:443) -> Jellyfin :8096
  FlareSolverr :8191 -> indexers/scrapers
```

## 2. Ports

| Port | Service | Protocol | Notes |
|------|---------|----------|-------|
| 8096 | Jellyfin HTTP | HTTP | Primary API + web (`/System/Info`, `/Users/AuthenticateByName`, `/Library/*`, `/Videos/{id}/stream`). Default `JELLYFIN_URL=http://localhost:8096`. |
| 8920 | Jellyfin HTTPS | HTTPS | Container TLS port (compose `${JELLYFIN_HTTPS_PORT:-8920}`). |
| 8888 | torbox-proxy (`server/torbox-proxy.py`) | HTTP | `/health`, `/torbox/{torrent}/{file}/{name}` 302 to fresh CDN, `/mylist` shared cache, `/metrics` Prometheus. Launcher probes once per launch. |
| 18080 | control-panel (`control-panel/control_panel.py`) | HTTP | Status, metrics, playback buttons. |
| 5572 | rclone RC (`vfs/refresh`, `vfs/cache/fetch`, `core/stats`) | HTTP | Enabled on TorBox mount; launcher + MCP `transfer_status` use it when present. |
| 80 / 443 | Caddy reverse proxy | HTTP/HTTPS + QUIC | Auto Let's Encrypt, forwards to Jellyfin/FlareSolverr. Compose `${CADDY_HTTP_PORT:-80}` / `${CADDY_HTTPS_PORT:-443}`. |
| 8191 | FlareSolverr | HTTP | Cloudflare bypass for indexers. Compose `${FLARESOLVERR_PORT:-8191}`. |

Loopback-only by default: `127.0.0.1:8888`, `127.0.0.1:5572`, `127.0.0.1:18080`,
`127.0.0.1:8096`. Expose via Caddy / Cloudflared tunnel only (see
`config/cloudflared/config.yml.template`).

## 3. Data flow

1. **Ingest:** TorBox torrents / Google Drive media -> rclone VFS (`T:\`, `G:\`)
   with 30s dir-cache + LRU prefetch (`F:\Jellyfin\cache\prefetch`, 20 GB / 24 h cap).
2. **Library:** `gdrive-library-sync.ps1` writes `.strm` + sidecars ->
   Jellyfin scan (`POST /Library/Refresh`) -> TMDB metadata -> `Views`,
   `Shows/{id}/Episodes`, `Videos/{id}/stream`.
3. **Play request:** Web / panel builds `potplayer://<b64|target|itemId|userId|token|serverUrl>`
   -> registry handler -> `PotPlayerLauncher.ps1` (thin shim) ->
   `potplayer-launcher.ps1` (resolve `item:` GUIDs, `.strm` -> `T:\`, stale-VFS
   refresh, TorBox CDN/proxy fallback, `F:\Media`/`G:\` -> `:8888/gdrive/` for bar).
4. **Playback:** PotPlayer opens full-season `.dpl` (UTF-16 `DAUMPLAYLIST`) or
   direct HTTP (`:8888/torbox/...` never-expires proxy -> 302 fresh CDN).
   `potplayer-sync-tracker.ps1` POSTs `/Sessions/Playing/Progress` every 5s,
   marks played at 80% (`POST /Users/{u}/PlayedItems/{id}`), updates Next-Up.
5. **Automation:** `mcp-servers/rclone-storage/server.py` (stdio JSON-RPC) exposes
   `rclone_list_files`, `rclone_rename_or_move`, `rclone_command`,
   `list_remotes`, `transfer_status` with strict validation (allowlisted
   subcommands, no `--config` override, no shell metachars).
6. **Observability:** `scripts/healthcheck.ps1`, `check_*.ps1` (Nagios 0/1/2 +
   `-AsJson`), `scripts/export-metrics.ps1` + proxy `/metrics` -> Prometheus;
   logs under `F:\Jellyfin\logs\` (see RUNBOOK.md).

## 4. Key paths

| Path | Role |
|------|------|
| `F:\Media\` / `R:\` alias | Local canonical media (Movies/Series). `R:\` rewritten to `F:\Media\`. |
| `T:\` | TorBox rclone VFS mount. |
| `G:\` | Google Drive VFS mount. |
| `F:\Jellyfin\logs\` | `potplayer-launcher.log`, `rclone-prefetch.log`, playback logs. |
| `F:\Jellyfin\cache\prefetch\` | Full-file prefetch LRU (gated by `FULLCACHE=1` for copy). |
| `F:\Jellyfin\cache\playlists\` | Generated `season_playlist.dpl`. |
| `F:\Jellyfin\config\rclone.conf` | Rclone remotes (never committed; use `config/rclone.conf.template`). |
| `mcp-servers/rclone-storage/server.py` | MCP bridge (env `RCLONE_EXE`, `RCLONE_CONFIG`). |

## 5. Tooling scripts (this track)

| Script | Purpose | New flags |
|--------|---------|-----------|
| `check_status.ps1` | System/Info + auth + libraries probe | `-AsJson`, Nagios 0/1/2 |
| `check_user_views.ps1` | User views + refresh trigger | `-AsJson`, Nagios 0/1/2 |
| `check_views_after_restart.ps1` | Post-restart views probe | `-AsJson`, Nagios 0/1/2 |
| `clean_and_setup_libraries.ps1` | Reset stubs, create Movies, scan | `-WhatIf`, `-OlderThanDays` (30) |
| `cleanup_and_check_items.ps1` | Delete stubs, sample + stale report | `-WhatIf`, `-OlderThanDays` (30) |
| `cleanup_extra_libraries.ps1` | Delete Movies2/Series | `-WhatIf`, `-OlderThanDays` (30) |
| `delete_stale_views.ps1` | Delete stale item/view IDs | `-WhatIf`, `-OlderThanDays` (30) |
| `test_dpl.ps1` | Assert-based .dpl test | pass/fail summary, exit 1 on fail |
| `test_mcp_server.ps1` | Assert-based MCP smoke test | pass/fail summary, exit 1 on fail |
| `PotPlayerLauncher.ps1` | Thin shim -> `potplayer-launcher.ps1` | compat `-RawUrl`, `-FullSeason`, `-Single` |
| `annotate_screenshot.ps1` | PNG callout annotator | `-InputPath`, `-OutputPath` |
