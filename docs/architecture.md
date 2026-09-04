# Architecture, Data Flow, and Performance

This guide shows how the stack fits together, which ports it uses, how a play flows end to end, and how to tune it for fast direct play.

## Contents

- [Stack diagram](#stack-diagram)
- [Ports](#ports)
- [Data flow](#data-flow)
- [Key folders and scripts](#key-folders-and-scripts)
- [Performance tuning](#performance-tuning)
- [Observability](#observability)

## Stack diagram

Cloud remotes sit at the top, the VFS cache engine in the middle, Jellyfin and the proxy side by side, PotPlayer at the edge, and panel plus supervisor observing everything.

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
              |                   |  | bucket, metrics     |
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
                           |
                 progress tracker every 5s
                           |
                           v
                 +---------+---------+
                 | Control panel web |
                 | status, metrics,  |
                 | playback buttons  |
                 +-------------------+
                           |
                 supervisor watchdog
                 ordered start, PIDs
```

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
3. Play request: the web UI or panel builds a `potplayer://` link with target plus item, user, token, and server fields, the registry handler forwards it to the shim, and the full launcher resolves GUIDs, `.strm` targets, stale VFS entries, and CDN or proxy fallbacks. See [PotPlayer](potplayer.md).
4. Playback: PotPlayer opens a full-season UTF-16 playlist or a direct proxy URL that redirects to a fresh CDN link per request, while the tracker posts progress every five seconds and marks played at eighty percent.
5. Automation: the rclone MCP bridge exposes allowlisted list, move, command, remotes, and transfer calls over stdio JSON-RPC with strict validation and no config override or shell metacharacters.
6. Observability: health scripts with Nagios codes plus JSON modes, metrics exporters, and proxy metrics feed Prometheus, while logs under the logs folder record launcher, prefetch, playback, Jellyfin, proxy, supervisor, and MCP evidence.

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
