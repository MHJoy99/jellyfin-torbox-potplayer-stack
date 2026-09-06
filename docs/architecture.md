# Architecture, Data Flow, and Performance

This guide shows how the stack fits together, which ports it uses, how a play flows end to end, and how to tune it for fast direct play.

## Contents

- [Stack diagram](#stack-diagram)
- [Ports](#ports)
- [Data flow](#data-flow)
- [Proxy, bridge, and panel](#proxy-bridge-and-panel)
- [Session model (Session 0 vs 1)](#session-model-session-0-vs-1)
- [Boot order](#boot-order)
- [Key folders and scripts](#key-folders-and-scripts)
- [Performance tuning](#performance-tuning)
- [Observability](#observability)

## Stack diagram

Cloud remotes sit at the top, the VFS cache engine in the middle, Jellyfin and the proxy side by side, the bridge beside the panel, PotPlayer at the edge, and the supervisor observing everything.

```text
                    +-----------------------------+
                    | Cloud remotes over HTTPS    |
                    | TorBox, Drive, other VFS    |
                    +--------------+--------------+
                                   | HTTPS and API
                                   v
                    +--------------+--------------+
                    | rclone VFS cache engine     |
                    | TorBox mount, Drive mount   |
                    | dir-cache 30s, RC control   |
                    +------+---------------+------+
                           |               |
                .strm plus file I/O   HTTP progressive
                           |               |
                            v               v
               +------------+------+  +-----+---------------+
               | Jellyfin web+API  |  | TorBox proxy        |
               | metadata, stream, |  | CDN redirect,       |
               | resume, Next Up   |  | mylist, token       |
               | :8096 (loopback)  |  | bucket, metrics     |
               |                   |  | :8888 (loopback)    |
               +------------+------+  +-----+---------------+
                            |                       |
                 potplayer protocol link            |
                 launcher shim plus resolver        |
                            |                       |
                            v                       v
                  +---------+---------+   +---------+---------+
                  | PotPlayer 64-bit  |<--| HTTP and CDN media|
                  | full-season lists |   | full-cache bar    |
                  +---------+---------+   +-------------------+
                            | ^
                  progress tracker every 5s |
                            | | bridge player status :18099
                            v |
                  +---------+---------+   +-------------------+
                  | Control panel web |-->| PotPlayer bridge  |
                  | status, metrics,  |<--| helper, gated on  |
                  | playback buttons  |   | proxy healthy     |
                  | :18080 (loopback) |   | :18099 (loopback) |
                  +-------------------+   +-------------------+
                            ^
                  supervisor watchdog (ordered start, PIDs)
                  gdrive -> torboxmount -> proxy -> bridge
                    -> jellyfin -> panel (abort on first fail)
```

Bridge detail: the helper lives at `E:\MediaServer\tools\potplayer_http_bridge.py` (outside `F:\Jellyfin`), exposes `/health` plus player `/status`, and requires the proxy healthy first. The panel reads bridge status for its playback cards, and the supervisor gates bridge start on proxy health. Supervisor, proxy, bridge, Jellyfin, and panel all run in the interactive logon session (Session 1); only the Drive mount service runs in Session 0. See [Session model](#session-model-session-0-vs-1) and [Boot order](#boot-order).

Optional edge profile places a TLS reverse proxy in front of Jellyfin and an indexer helper beside it, with forwarded ports only when that profile is enabled. See [Panel](panel.md) and [Supervisor](supervisor.md) for the runtime side of this picture.

## Ports

| Port | Service | Protocol | Notes |
| --- | --- | --- | --- |
| 8096 | Jellyfin HTTP | HTTP | Primary web and API with public info, auth, library, and stream routes. Default server URL uses localhost plus this port. |
| 8920 | Jellyfin HTTPS | HTTPS | Container TLS port used when the TLS profile is enabled. |
| 8888 | TorBox proxy in `server/torbox-proxy.py` | HTTP | Health, stable TorBox redirect URLs, shared mylist, and Prometheus metrics. Launcher probes once per launch. |
| 18080 | Control panel in `control-panel/control_panel.py` | HTTP | Status, metrics, activity, timeline, playback, and actions. |
| 18099 | PotPlayer bridge helper | HTTP | Bridge health and player status used by panel and supervisor. |
| 5572 | rclone RC | HTTP | VFS refresh, cache fetch, and transfer stats used by launcher and MCP helpers. |
| 80 / 443 | Caddy reverse proxy | HTTP, HTTPS, QUIC | Automatic TLS that forwards to Jellyfin when the edge profile is enabled. |
| 8191 | FlareSolverr | HTTP | Cloudflare bypass for indexers when enabled. |

Loopback-only is the default for the proxy, bridge, panel, Jellyfin, and rclone RC ports. Expose them remotely only through the reverse proxy or tunnel pattern warned about in [Reference](reference.md).

## Data flow

1. Ingest: TorBox torrents and Drive media arrive through rclone VFS mounts with a thirty-second dir cache plus LRU prefetch capped by size and age.
2. Library: the Drive sync script writes `.strm` files plus sidecars, Jellyfin scans them on library refresh, TMDB attaches metadata, and views, seasons, episodes, and stream routes appear. See [Jellyfin](jellyfin.md).
3. Play request: the web UI or panel builds a `potplayer://` link with target plus item, user, token, and server fields, the registry handler forwards it to the shim (`PotPlayerLauncher.ps1`), and the full launcher (`potplayer-launcher.ps1`) resolves GUIDs, `.strm` targets, stale VFS entries, and CDN or proxy fallbacks. See [PotPlayer](potplayer.md).
4. Playback: PotPlayer opens a full-season UTF-16 playlist or a direct proxy URL that redirects to a fresh CDN link per request, while the tracker (`potplayer-sync-tracker.ps1`) posts progress every five seconds and marks played at eighty percent.
5. Automation: the rclone MCP bridge exposes allowlisted list, move, command, remotes, and transfer calls over stdio JSON-RPC with strict validation and no config override or shell metacharacters.
6. Observability: health scripts with Nagios codes plus JSON modes, metrics exporters, and proxy metrics feed Prometheus, while logs under the logs folder record launcher, prefetch, playback, Jellyfin, proxy, supervisor, and MCP evidence.

The proxy, bridge, and panel legs of steps 3-4 are expanded in [Proxy, bridge, and panel](#proxy-bridge-and-panel) below.

## Proxy, bridge, and panel

Three loopback HTTP services carry a play from click to pixels. All bind `127.0.0.1` only; the panel and supervisor reach them the same way whether the caller runs in Session 0 or Session 1, but the owning processes all live in the interactive logon session except the Session 0 mount service (see session model).

- TorBox proxy (`server/torbox-proxy.py`, `127.0.0.1:8888`, HTTP/1.0 must stay for PotPlayer range reads). Translates stable `http://127.0.0.1:8888/torbox/<torrent>/<file>/<name>` URLs into a fresh TorBox `requestdl?token=` lookup per request, then streams CDN bytes locally with Range, Content-Length, and Accept-Ranges so the PotPlayer bar fills to full. Never caches expiring CDN URLs; only the short resolver result is cached, so expiry becomes a redirect instead of a failure. Also serves `/health` (launcher probes exactly once per launch and reuses the result), shared `/mylist` (ten-minute cache with singleflight coalescing, avoids per-click rate limits), token-bucket throttle, per-IP stream cap, and Prometheus `/metrics` (latency histograms, active-stream gauges). Requires `TORBOX_API_KEY` from the live Machine then User environment; refuses to start without it. See [TorBox](torbox.md).
- PotPlayer bridge (`E:\MediaServer\tools\potplayer_http_bridge.py`, `127.0.0.1:18099`). Exposes `/health` plus player `/status` for the panel and supervisor. Start is gated on proxy healthy first; the supervisor dedupes by keeping the LISTENING PID on `127.0.0.1:18099` and killing non-listening duplicates. The panel polls `/status` for its playback cards (last bridge play, parsed playlist entries, freshness window that decides whether PotPlayer still counts as running). Bridge log is `logs/potplayer-bridge.log`.
- Control panel (`control-panel/control_panel.py`, `127.0.0.1:18080`). Stdlib-only pythonw process with `/health`, status, metrics, activity, timeline, playback, and action endpoints. Status merges live process scans with proxy `/metrics` through a five-second cache plus VFS details and playback summary. Timeline merges proxy, bridge, sync, and Drive sources with per-source quotas. Bulk Start all and Restart all follow mount-first order (mounts, proxy, bridge, Jellyfin, panel) with health waits between steps and abort on the first failed gate; Stop all reverses the order so mounts go last. Restart allowlist is fixed to jellyfin, proxy, bridge, gdrive, and torboxmount. Sync TorBox reuses the existing `MediaServer_TorboxSmartSync` scheduled task via `schtasks /Run` instead of duplicating its work. The panel itself runs as a hidden per-user AtLogOn task with a Start Menu shortcut, so it is present after sign-in with no console window.

Failure shorthand: proxy down means launcher falls back or fails fast and bridge start aborts; bridge down means playback cards go stale but Jellyfin web still plays; panel down means no UI but the watchdog keeps the chain alive. Check `supervisor.log` plus `torbox-proxy.log` and `potplayer-bridge.log` in that order.

## Session model (Session 0 vs 1)

Windows isolates services (Session 0, non-interactive, no desktop) from the logged-on user (Session 1 and higher, interactive, owns PotPlayer windows and drive-letter visibility). The stack is split on that boundary by design:

- Session 0 (SYSTEM, no UI): only the Drive mount service `RcloneGdriveMount` via NSSM. It auto-starts at boot and survives logoff. It never hosts PotPlayer, the bridge, the proxy, the panel, or the supervisor loop.
- Session 1+ (interactive logon, owns the desktop): everything the user sees or clicks. `MediaStackSupervisor` (AtLogOn, Interactive, Highest via `install.ps1`), `Jellyfin Control Panel` (AtLogOn, Interactive, Limited via `install-control-panel.ps1`), plus the audited `\TorboxProxy` and `\MediaServer_PotPlayerBridge` tasks, the TorBox mount script (`E:\MediaServer\mount-torbox.ps1`, no scheduled task on this base), Jellyfin (`server\jellyfin.exe`), proxy (`server\torbox-proxy.py`), bridge, panel, launcher shim plus full launcher, tracker, and PotPlayer itself.

Rules that follow from the split:

- PotPlayer UI must spawn in the same interactive session that owns the desktop. A PotPlayer process started from Session 0 is invisible (no window handle) and can never be foregrounded; always launch playback from the logon session via the `potplayer://` handler chain, never from a SYSTEM service.
- Loopback HTTP (`127.0.0.1:8888`, `:18099`, `:18080`, `:8096`, `:5572`) is reachable from either session on the same host, which is why health probes work cross-session while window handles and drive-letter visibility do not. A healthy probe does not prove the process shares your session.
- Drive letters are session-scoped. `Test-Path T:\` from Session 0 can report missing while Session 1 plays fine, so treat mount health as path plus live `rclone mount torbox` process plus RC `:5572` probe, not path alone.
- Sync-only tasks (`\MediaServer_TorboxSmartSync`, `\MediaServer_GoogleDriveLibrarySync`) stay enabled but are never supervised; the panel and supervisor trigger them via `schtasks /Run` instead of owning them.

Diagnose a suspected session split with `(Get-Process -Id $PID).SessionId`, `Get-Process PotPlayer* | Select-Object Name, Id, SessionId`, `Get-Process explorer | Select-Object SessionId` (non-zero means an interactive session exists), `qwinsta` Active session with id greater than zero, and `supervisor.ps1 -Mode Status` listener PIDs versus PID files under `run/`.

## Boot order

Machine boot and user logon are two phases; the ordered chain spans both and aborts on the first failed gate with an explicit log (downstream services are never started on a broken base).

1. Machine boot (Session 0): NSSM starts `RcloneGdriveMount`; `F:\Media` appears. No panel, proxy, bridge, or Jellyfin yet.
2. User logon (Session 1): AtLogOn tasks fire. `MediaStackSupervisor -Mode Run` acquires the `Global\MediaStackSupervisor` mutex (second instance exits), refreshes `TORBOX_API_KEY` from live Machine then User environment so children inherit it, and runs one ordered start; `Jellyfin Control Panel` starts hidden via wscript plus shortcut. `install.ps1` creates the supervisor task; `install-control-panel.ps1` creates the panel task.
3. Ordered start chain (supervisor and panel Start all share this order): Drive mount gated on `Test-Path F:\Media` (NSSM start, then fallback mount script) -> TorBox mount gated on `Test-Path T:\` else `mount-torbox.ps1` (thirty-second wait on this base) -> proxy `server\torbox-proxy.py` gated on `http://127.0.0.1:8888/health` (thirty-second wait, dedupe keeps the LISTENING PID, transient-tolerant re-probe before any start) -> bridge gated on `http://127.0.0.1:18099/health` (ten-second wait, aborts unless proxy is healthy) -> Jellyfin `server\jellyfin.exe --datadir --configdir --cachedir --logdir --webdir --ffmpeg` gated on `http://127.0.0.1:8096/System/Info/Public` (sixty-second wait) -> panel `control-panel\control_panel.py` gated on `http://127.0.0.1:18080/health` (fifteen-second wait). Healthy fast path logs OK and refreshes `run/<svc>.pid` without restarting. Each starter writes its PID file on success.
4. Steady state: watchdog every fifteen seconds checks HTTP probe plus path presence plus PID-alive with command-line matching (detects PID reuse), refreshes PID files from live listeners, defers bridge restart while proxy is down, restarts unhealthy services with three fast retries then sixty-second cooldown, and logs a crash-loop alert at five restarts in ten minutes (log-only). Stop reverses the order: panel, Jellyfin, bridge, proxy, TorBox mount, Drive mount.
5. Play time: `potplayer://` -> `PotPlayerLauncher.ps1` shim -> `potplayer-launcher.ps1` (one cached `:8888/health` probe, GUID and `.strm` resolution, stale-VFS RC `:5572` refresh, proxy-or-CDN URL choice, UTF-16 full-season `.dpl`) -> PotPlayer plus `potplayer-sync-tracker.ps1` progress loop. Proxy, bridge, and panel stay up throughout; see [PotPlayer](potplayer.md) for resume semantics.

If logon has not happened yet, expect only the Session 0 mount to be healthy; interactive gates log DEFER-style waits rather than failures. Verify with `supervisor.ps1 -Mode Status` plus the four health URLs in [Quickstart](quickstart.md).

## Key folders and scripts

| Path | Role |
| --- | --- |
| `server/torbox-proxy.py` | Local HTTP proxy with link cache, token bucket, metrics, and mylist. |
| `control-panel/control_panel.py` plus web assets | Panel backend and single-page UI. |
| `supervisor.ps1` plus start and stop helpers | Watchdog that owns all services in order. |
| `potplayer-launcher.ps1` plus thin shim | Full-season launcher with resume seek and fallback. |
| `potplayer-sync-tracker.ps1` | Jellyfin resume and progress sync, pause-aware. |
| `show-playback-log.ps1` | Watch-log console window for live ticks. |
| `gdrive-library-sync.ps1` | Drive library sync that writes stream files. |
| `mcp-servers/rclone-storage/server.py` | MCP bridge with env-selected rclone binary and config. |
| `install-all.ps1` and per-service installers | Ordered install, verify, version stamps, and reverse uninstall. |
| `check_status.ps1` and view check scripts | System, auth, library, and post-restart probes with JSON modes. |
| `run/` | PID files per service written on healthy start. |
| `logs/` | Launcher, prefetch, playback, supervisor, and proxy logs. |
| `cache/` | Prefetch LRU plus generated playlists. |
| `config/` | Untracked live config plus tracked templates for sharing. |

Runtime folders for server binaries, data, config, logs, cache, and transcodes are intentionally untracked. See [Install](install.md) and [Reference](reference.md) for what to keep.

## Performance tuning

Tune in this order: network and VFS first, then proxy, then Jellyfin, then disk.

- Chunk size: raise the proxy chunk byte size for high-bandwidth links and lower it when memory or small-file latency matters, keeping write timeouts generous enough for slow CDN first bytes.
- Link cache: keep proxy URLs in playlists and never cache direct CDN URLs, because proxy re-resolution turns expiry from a failure into a redirect, as explained in [TorBox](torbox.md).
- Shared mylist: rely on the ten-minute shared cache with singleflight coalescing instead of polling TorBox per click, which avoids rate-limit cooldowns.
- Dir cache: keep the thirty-second VFS dir cache for snappy listings, and trigger targeted RC refreshes for stale paths rather than shortening the global cache to zero.
- Prefetch: enable full-file copy only with the explicit full-cache flag, respect the LRU size and age cap, and monitor the prefetch log for copy progress versus errors.
- Concurrency: keep the per-IP stream cap tight enough to protect the proxy during multi-room plays, and watch active-stream gauges on the metrics endpoint.
- Range coalescing: prefer sequential player reads over scattered seeks when scrubbing, because coalesced ranges hit cache while random ranges miss.
- NVMe tips: keep the Jellyfin cache, transcode, and VFS cache folders on NVMe, keep bulk media on larger spinning or network volumes, leave headroom so logs and transcodes never fill the OS disk, and schedule DB vacuum plus backup so cold starts stay fast.
- Jellyfin: prefer direct play through PotPlayer over server transcoding, enable hardware acceleration only when direct play is impossible, and rescan incrementally rather than rebuilding libraries weekly.

Verify each change with proxy metrics latency histograms, status light polling from [Panel](panel.md), and one full-season play with resume from [PotPlayer](potplayer.md).

## Observability

Health scripts return Nagios zero, one, and two plus JSON for monitoring, the proxy exposes Prometheus metrics with per-endpoint latency buckets, and the panel re-exposes a cached subset for the UI. Logs record raw protocol payloads, stream resolution, stale-VFS refreshes, full-cache decisions, proxy URLs, and resume offsets, which is exactly what [Troubleshooting](troubleshooting.md) searches when a play fails.

---

Back to [Docs Index](index.md).
