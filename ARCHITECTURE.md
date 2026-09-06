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
                               | ^
                     potplayer-sync-tracker.ps1 (5s progress) |
                               | | bridge /status :18099
                               v |
                     +---------+---------+   +-------------------+
                     | control-panel     |-->| potplayer bridge  |
                     | web :18080        |<--| gated on proxy OK |
                     | status/metrics/   |   | E:\MediaServer\   |
                     | playback buttons  |   | tools\*.bridge.py |
                     +-------------------+   +-------------------+
                               ^
                     supervisor.ps1 watchdog (Session 1)
                     gdrive -> torboxmount -> proxy -> bridge
                       -> jellyfin -> panel (abort on 1st fail)
```

Bridge detail: `E:\MediaServer\tools\potplayer_http_bridge.py` on
`127.0.0.1:18099` (`/health` + `/status`, requires proxy healthy).
Panel reads bridge `/status` for playback cards; supervisor gates bridge
start on proxy health and dedupes by LISTENING PID. Supervisor, proxy,
bridge, Jellyfin, and panel all run in the interactive logon session
(Session 1); only the NSSM Drive mount service runs in Session 0.
See sections 6 (session model) and 7 (boot order).

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
| 8888 | torbox-proxy (`server/torbox-proxy.py`) | HTTP | `/health`, `/torbox/{torrent}/{file}/{name}` 302 to fresh CDN, `/mylist` shared cache, `/metrics` Prometheus. Launcher probes once per launch. HTTP/1.0 must stay (PotPlayer range reads). |
| 18099 | PotPlayer bridge (`E:\MediaServer\tools\potplayer_http_bridge.py`) | HTTP | `/health` + player `/status` for panel playback cards and supervisor gate. Requires proxy healthy first. Dedupe keeps the LISTENING PID on `127.0.0.1:18099`. |
| 18080 | control-panel (`control-panel/control_panel.py`) | HTTP | Status, metrics (5s proxy cache), activity, timeline, playback buttons. Per-user AtLogOn task + Start Menu shortcut. |
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
   `potplayer-launcher.ps1` (one cached `:8888/health` probe per launch; resolve `item:` GUIDs, `.strm` -> `T:\`, stale-VFS
   refresh via RC `:5572`, TorBox CDN/proxy fallback, `F:\Media`/`G:\` -> `:8888/gdrive/` for bar).
4. **Playback:** PotPlayer opens full-season `.dpl` (UTF-16 `DAUMPLAYLIST`) or
   direct HTTP (`:8888/torbox/...` never-expires proxy -> 302 fresh CDN, Range + Accept-Ranges so the bar fills).
   `potplayer-sync-tracker.ps1` POSTs `/Sessions/Playing/Progress` every 5s,
   marks played at 80% (`POST /Users/{u}/PlayedItems/{id}`), updates Next-Up.
   Bridge `:18099/status` reports player state to panel playback cards; panel freshness window decides still-running.
5. **Proxy / bridge / panel leg (detail):** proxy hides expiring CDN tokens behind stable loopback URLs (only the short resolver result is cached; expiry becomes a redirect); bridge exposes `/health` + `/status` and refuses to start unless proxy is healthy (supervisor + panel enforce the same gate); panel merges live process scans with proxy `/metrics` (5s cache) for status/metrics, merges proxy/bridge/sync/gdrive logs for timeline, and runs bulk Start/Restart in mount-first order with health waits (Stop reverses the order). Panel Sync TorBox triggers the existing `MediaServer_TorboxSmartSync` task via `schtasks /Run`.
6. **Automation:** `mcp-servers/rclone-storage/server.py` (stdio JSON-RPC) exposes
   `rclone_list_files`, `rclone_rename_or_move`, `rclone_command`,
   `list_remotes`, `transfer_status` with strict validation (allowlisted
   subcommands, no `--config` override, no shell metachars).
7. **Observability:** `scripts/healthcheck.ps1`, `check_*.ps1` (Nagios 0/1/2 +
   `-AsJson`), `scripts/export-metrics.ps1` + proxy `/metrics` -> Prometheus;
   logs under `F:\Jellyfin\logs\` (see RUNBOOK.md). Failure shorthand: proxy down = launcher fallback/fail-fast + bridge abort; bridge down = stale playback cards; panel down = no UI but watchdog keeps the chain.

## 4. Key paths

| Path | Role |
|------|------|
| `F:\Media\` / `R:\` alias | Local canonical media (Movies/Series). `R:\` rewritten to `F:\Media\`. |
| `T:\` | TorBox rclone VFS mount (via `E:\MediaServer\mount-torbox.ps1`; session-scoped drive letter, always pair `Test-Path` with live `rclone mount torbox` process + RC `:5572` probe). |
| `G:\` | Google Drive VFS mount. |
| `F:\Jellyfin\logs\` | `potplayer-launcher.log`, `rclone-prefetch.log`, playback logs, `supervisor.log` (10MB x5 rotation), `torbox-proxy.log`, `potplayer-bridge.log`, `control-panel.log`. |
| `F:\Jellyfin\cache\prefetch\` | Full-file prefetch LRU (gated by `FULLCACHE=1` for copy). |
| `F:\Jellyfin\cache\playlists\` | Generated `season_playlist.dpl` (UTF-16 full-season). |
| `F:\Jellyfin\run\` | PID files per service (`gdrive`, `torboxmount`, `proxy`, `bridge`, `jellyfin`, `panel`, `supervisor`) written on healthy start. |
| `F:\Jellyfin\config\rclone.conf` | Rclone remotes (never committed; use `config/rclone.conf.template`). |
| `E:\MediaServer\tools\potplayer_http_bridge.py` | Bridge helper source (outside `F:\Jellyfin`; supervised via health + LISTENING PID, not via repo path). |
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

## 6. Session model (Session 0 vs 1)

Windows isolates SYSTEM services (Session 0: non-interactive, no desktop)
from the logged-on user (Session 1+: interactive, owns PotPlayer windows
and drive-letter visibility). Split by design:

- **Session 0:** only the Drive mount service `RcloneGdriveMount` via NSSM.
  Auto-starts at boot, survives logoff. Never hosts PotPlayer, bridge,
  proxy, panel, or the supervisor loop.
- **Session 1+:** everything the user sees or clicks. `MediaStackSupervisor`
  (AtLogOn, Interactive, Highest via `install.ps1`), `Jellyfin Control Panel`
  (AtLogOn, Interactive, Limited via `install-control-panel.ps1`), audited
  `\TorboxProxy` + `\MediaServer_PotPlayerBridge` tasks, TorBox mount script
  (`E:\MediaServer\mount-torbox.ps1`, no scheduled task on this base),
  Jellyfin (`server\jellyfin.exe`), proxy, bridge, panel, launcher shim +
  full launcher, tracker, and PotPlayer itself.

Rules:

- PotPlayer UI must spawn in the interactive session. A Session 0-spawned
  PotPlayer is invisible (no window handle, never foregroundable); always
  launch via the `potplayer://` handler chain in the logon session.
- Loopback HTTP (`127.0.0.1:8888/:18099/:18080/:8096/:5572`) is reachable
  from either session, so a healthy probe does not prove same-session
  ownership. Window handles and `T:\` visibility do not cross sessions.
- `Test-Path T:\` alone is never authoritative from Session 0; pair it with
  live `rclone mount torbox` process + RC `:5572` probe.
- Sync-only tasks (`\MediaServer_TorboxSmartSync`,
  `\MediaServer_GoogleDriveLibrarySync`) stay enabled but unsupervised;
  panel/supervisor trigger them via `schtasks /Run`.

Diagnose with `(Get-Process -Id $PID).SessionId`,
`Get-Process PotPlayer* | Select-Object Name, Id, SessionId`,
`Get-Process explorer | Select-Object SessionId` (non-zero = interactive
logon present), `qwinsta` Active id > 0, and
`supervisor.ps1 -Mode Status` listener PIDs vs `run/*.pid`.

## 7. Boot order

Machine boot and user logon are two phases; the ordered chain spans both
and aborts on the first failed gate (downstream never starts on a broken
base). Supervisor and panel Start-all share this order.

1. **Boot (Session 0):** NSSM starts `RcloneGdriveMount`; `F:\Media` appears.
2. **Logon (Session 1):** AtLogOn tasks fire. `MediaStackSupervisor -Mode Run`
   takes `Global\MediaStackSupervisor` mutex (second instance exits),
   refreshes `TORBOX_API_KEY` from live Machine then User env, and runs one
   ordered start; panel starts hidden via wscript + shortcut.
3. **Ordered chain:** gdrive (`Test-Path F:\Media`, NSSM start then fallback
   script) -> torboxmount (`Test-Path T:\` else `mount-torbox.ps1`, 30s wait)
   -> proxy (`server\torbox-proxy.py`, `http://127.0.0.1:8888/health`, 30s,
   dedupe keeps LISTENING PID, transient-tolerant re-probe) -> bridge
   (`http://127.0.0.1:18099/health`, 10s, aborts unless proxy healthy) ->
   Jellyfin (`server\jellyfin.exe --datadir --configdir --cachedir --logdir
   --webdir --ffmpeg`, `http://127.0.0.1:8096/System/Info/Public`, 60s) ->
   panel (`control-panel\control_panel.py`,
   `http://127.0.0.1:18080/health`, 15s). Healthy fast path logs OK and
   refreshes `run/<svc>.pid` without restart; each starter writes its PID
   file on success.
4. **Steady state:** watchdog every 15s (HTTP probe + path + PID-alive with
   command-line match), bridge deferred while proxy down, 3x fast restart
   then 60s cooldown, crash-loop alert at 5 restarts/10m (log-only),
   single-instance mutex, post-start listener guard. Stop reverses the
   order: panel -> jellyfin -> bridge -> proxy -> torboxmount -> gdrive.
5. **Play time:** `potplayer://` -> shim -> full launcher (one cached
   `:8888/health` probe, GUID/`.strm`/stale-VFS/CDN resolution, UTF-16
   full-season `.dpl`) -> PotPlayer + `potplayer-sync-tracker.ps1` (5s
   progress, 80% played). Proxy/bridge/panel stay up throughout.

Pre-logon, expect only the Session 0 mount healthy. Verify with
`supervisor.ps1 -Mode Status` + the four health URLs
(`:8888/health`, `:18099/health`, `:8096/System/Info/Public`,
`:18080/health`).
