# TorBox Setup and Key Rotation

This guide explains where the TorBox API key comes from, how to expose it to every service through the environment, how the TorBox rclone mount is built, and how to rotate the key without breaking playback.

The mount, remote-control, cache-tuning, and session sections below describe the production defaults in `mount-torbox.ps1` and the supervisor order. They are reference only and contain no secrets or copy-paste live commands.

## Contents

- [Where to get the key](#where-to-get-the-key)
- [Environment setup](#environment-setup)
- [TorBox mount flags explained](#torbox-mount-flags-explained)
- [rclone RC on loopback port 5572](#rclone-rc-on-loopback-port-5572)
- [VFS cache tuning](#vfs-cache-tuning)
- [Session-1 interactive task requirement](#session-1-interactive-task-requirement)
- [How the proxy uses the key](#how-the-proxy-uses-the-key)
- [Rotation without downtime](#rotation-without-downtime)
- [Verify after any change](#verify-after-any-change)

## Where to get the key

Get the key from the TorBox web dashboard under settings and API access, where you can create a Machine or User scoped key for automation. Use a dedicated key for this stack so revoking it affects only local playback and sync. Copy the value once into a password manager, because the dashboard may only show it at creation time. Never paste the key into chat logs, screenshots, or tracked files. If you suspect exposure, revoke it in the same dashboard screen and issue a replacement.

## Environment setup

All credentials come from the environment or the OS credential store, and no script in this repo accepts a token as a committed default.

- Set `TORBOX_API_KEY` at Machine or User scope so the proxy, launcher, and supervisor all see the same value.
- The supervisor re-reads the live Machine value, then the User value, on every start, which repairs child shells that were opened before the key was set.
- Keep `JELLYFIN_USER`, `JELLYFIN_PASSWORD`, and `JELLYFIN_API_KEY` in the same scopes and never in scripts.
- Keep the real rclone config untracked and edit only the template copy when sharing examples.

Open a fresh terminal after setting Machine scope, because existing processes keep their old snapshot. Confirm visibility with the status scripts before starting the proxy, as described in [Quickstart](quickstart.md) and [Supervisor](supervisor.md).

## TorBox mount flags explained

The TorBox mount is built by `mount-torbox.ps1` as WebDAV remote `torbox:` mounted to drive `T:` with WinFsp in network mode. The table below explains each flag group in that script and why it matters for TorBox. Values are the current production defaults; change them in the script, not on the command line, so supervisor, panel, and reboot behavior stay consistent.

| Flag group | What it does | Why it matters for TorBox |
| --- | --- | --- |
| `mount torbox: T:` | Presents the TorBox WebDAV remote as drive `T:`. | All `.strm` targets, launcher resolution, and Jellyfin paths assume this one letter. |
| `--volname` | Sets the Explorer volume label. | Cosmetic only; makes the drive identifiable in file dialogs. |
| `--network-mode` | Presents the WinFsp mount as a network drive instead of a local disk. | Required on Windows for the drive to be browsable in the interactive session; see the Session-1 section below. |
| `--cache-dir` | Points VFS file cache at the NVMe scratch folder. | Keeps partial and full-file chunks on fast disk; never point this at the OS disk root. |
| `--vfs-cache-mode full` | Caches full file ranges on disk, not just directory structure. | Required for PotPlayer seeking and sequential reads; `off` or `minimal` breaks scrubbing. |
| `--vfs-cache-max-size 25G`, `--vfs-cache-max-age 12h` | Caps cache footprint by size and age with LRU eviction. | Bounds NVMe use for a few concurrent plays; old chunks age out without manual cleanup. |
| `--vfs-cache-min-free-space 30G` | Stops caching before the cache disk fills. | Protects logs, transcodes, and the OS from a full-disk stall. |
| `--vfs-cache-poll-interval 1m` | How often the cache poller scans for expired items. | One minute keeps eviction responsive without constant wakeups. |
| `--vfs-write-back 10s` | Delays upload of buffered writes. | TorBox is read-mostly here; a short write-back absorbs tiny sidecar writes. |
| `--vfs-read-ahead 128M` | Pre-reads ahead of sequential playback. | Smooths high-bitrate direct play; lower it only when memory is tight. |
| `--vfs-read-chunk-size 32M`, `--vfs-read-chunk-size-limit 256M` | Starts ranged reads small and grows them for sequential streams. | Small first chunk keeps start latency low; growth rewards sequential play and penalizes random seeks, which is the desired trade-off. |
| `--buffer-size 32M`, `--async-read` | Buffers and overlaps reads. | Hides CDN first-byte latency during continuous playback. |
| `--dir-cache-time 15m`, `--attr-timeout 5m` | How long directory listings and attributes are trusted before re-read. | Fifteen minutes keeps listings snappy while bounding staleness; targeted RC refresh covers the gap. The old multi-hundred-hour value kept new torrent folders invisible for days and must not return. |
| `--poll-interval 0` | Disables Changes-API polling. | TorBox WebDAV exposes no Changes feed, so polling would only add load; freshness comes from dir-cache expiry plus explicit RC refresh. |
| `--tpslimit 5`, `--tpslimit-burst 10` | Paces API transactions with a short burst allowance. | Avoids TorBox rate-limit cooldowns during scans and parallel probes. |
| `--timeout 30s`, `--contimeout 20s`, `--retries 5`, `--low-level-retries 10`, `--retries-sleep 2s` | Timeouts and retry budget for slow CDN first bytes. | Tolerates transient stalls without hanging the mount forever. |
| `--rc --rc-addr 127.0.0.1:5572 --rc-no-auth` | Enables the loopback-only remote-control endpoint. | Required for launcher refresh, panel stats, and graceful unmount; loopback-only is why no-auth is safe. Never bind this to a LAN address. |
| `--vfs-fast-fingerprint`, `--no-checksum`, `--no-modtime` | Skips hash and modtime checks WebDAV does not serve cheaply. | Faster listings and fewer failed comparisons; correctness comes from size plus path, not hash. |
| `--vfs-disk-space-total-size 10T` | Reports a fixed total size to Explorer and Jellyfin. | Prevents quota-flap empty/full views when the cloud quota response varies. |
| `--exclude` patterns | Skips unwanted categories from the listing. | Keeps library scans focused; edit the pattern list in the script when categories change. |
| `--log-level INFO` plus log file | Records mount activity with rotation when the log grows past its cap. | `INFO` is the support default; raise verbosity only for a short repro, then revert. |

Idempotent guard: the script never restarts a healthy live mount. When the mount process plus the drive path are both present it logs and returns, which fixed the old supervisor kill-loop where every retry killed a good mount and the cold WinFsp init never finished inside the wait. Only a missing path or a missing process triggers a graceful RC unmount followed by a process stop and a fresh start. See [Supervisor](supervisor.md) for the gate that calls this script.

## rclone RC on loopback port 5572

The TorBox mount enables rclone remote control on loopback port 5572. It is HTTP on `127.0.0.1` only, with no auth, which is safe only because it never leaves the machine. Do not rebind it to a LAN address or put it behind a tunnel.

### Endpoint reference

| Endpoint | Purpose | Who calls it | Request body |
| --- | --- | --- | --- |
| `rc/noop` | Liveness and connectivity check without modifying mount state. | Health checks, sync scripts, and preflight probes. | `{}` |
| `vfs/refresh` | Refreshes one stale directory without dropping the whole dir cache. | Launcher on a missing path, troubleshooting flow for stale listings. | `{"dir": "<path>"}` or `{}` for full refresh |
| `vfs/cache/fetch` | Queues one file for full-file fetch into the VFS cache. | Launcher prefetch path before PotPlayer opens the file. | `{"file": "<media-path>"}` |
| `vfs/stats` | Returns VFS metadata and disk-cache counters for the TorBox drive. | Panel TorBox health card and metrics collectors. | `{}` |
| `core/stats` | Returns real-time transfer counters and speed statistics. | MCP storage helper and diagnostics when RC is reachable. | `{}` |
| `mount/unmount` | Gracefully unmounts the VFS mount before a process stop. | Mount guard in `mount-torbox.ps1` when replacing a stale mount. | `{"mountPoint": "T:"}` or `{}` |

### `vfs/stats` example output

The control panel queries `POST http://127.0.0.1:5572/vfs/stats` with an empty JSON body to compute live cache usage, cached item count, and directory metadata count:

```json
{
  "diskCache": {
    "bytesUsed": 4831838208,
    "files": 14,
    "uploads": 0,
    "transforms": 0
  },
  "metadataCache": {
    "dirs": 192,
    "files": 1284
  },
  "inUse": 1,
  "files": 14,
  "bytesUsed": 4831838208
}
```

Field interpretation:
- `diskCache.bytesUsed`: Total bytes occupied on NVMe scratch disk by cached media chunks (parsed by panel as `bytes_used`).
- `diskCache.files`: Number of media files currently holding cached chunks on disk.
- `metadataCache.dirs` and `files`: Number of directory and file metadata nodes cached in memory for directory listings.
- `inUse`: Number of files actively open with active read/write handles.

Behavior notes:

- All calls are loopback POSTs from local components; there is no browser or remote caller.
- When RC is unreachable the launcher falls back to an authoritative remote listing and then to the Jellyfin HTTP stream path, and the MCP helper reports a degraded note instead of live stats. A missing RC therefore degrades to slower but working playback rather than a hard failure.
- The TorBox RC port and the Drive RC port are different instances; keep them distinct so refresh and stats never cross mounts.
- Changing the port requires updating the mount script plus the launcher, panel, supervisor, and MCP helper together. Changing it in one place only breaks refresh and stats silently.

Port and loopback conventions for the whole stack are in [Architecture](architecture.md). Stale-listing symptoms and the refresh-then-rescan order are in [Troubleshooting](troubleshooting.md).

## VFS cache tuning

Tune in this order: footprint first, then freshness, then read performance, then API pacing. Change one knob at a time and re-check with a full-season play plus panel health from [Panel](panel.md).

### VFS cache sizing and mode trade-offs

Selecting the proper `--vfs-cache-mode` and sizing limits determines RAM, NVMe disk wear, and player seeking stability. The table below details the trade-offs:

| Cache mode | RAM overhead | Disk usage | Seeking & random reads | Write support | Verdict for TorBox media stack |
| --- | --- | --- | --- | --- | --- |
| `off` | Minimal (<64 MB) | 0 GB (no disk caching) | Broken or extreme latency (re-downloads stream from 0 on seek) | Read-only | Not recommended: player seeks fail or stall on high-bitrate WebDAV streams. |
| `minimal` | Low (<128 MB) | Minimal (only open files in read-and-write mode) | Fragile; simultaneous reads fail without complete chunks | Sequential only | Not recommended: does not cache read-only streams opened by PotPlayer. |
| `writes` | Low (<128 MB) | Moderate (only files opened for writing) | Same as `minimal` for read-only playback | Full file buffered before upload | Not recommended: TorBox is primarily a read-only streaming remote. |
| `full` **(Recommended)** | Controlled by `--buffer-size` (32 MB) | Bounded by `--vfs-cache-max-size` (25 GB on NVMe) | Instant seeking in cached ranges; sparse chunk downloads on jump | Full read/write with chunked download | **Production standard:** sparse file chunks enable instant scrub, smooth playback, and LRU age-out. |

- Footprint: `max-size` bounds NVMe use and `max-age` bounds staleness of cached bytes. Raise `max-size` when concurrent plays evict each other; lower it when the cache disk fills. `min-free-space` is a floor, not a target — keep headroom for logs and transcodes and never set it to zero.
- Freshness: `dir-cache-time` plus `attr-timeout` control how long listings are trusted. Shorter values show new torrents sooner but add listing load; longer values are snappier but hide new folders until expiry or an explicit `vfs/refresh`. The current fifteen-minute directory window with targeted refresh is the balance for a remote with no Changes feed. Do not return to hour- or day-scale caching and do not set the cache to zero globally — refresh the stale path instead, as described in [Architecture](architecture.md).
- Read path: `read-ahead`, `read-chunk-size` and limit, `buffer-size`, and async reads favor sequential playback. Raise `read-ahead` and the chunk limit for high-bandwidth links; lower them when memory pressure or small-file latency matters. Random scrubbing will always miss more than sequential play because chunks grow for sequential ranges.
- API pacing: `tpslimit` and burst protect the shared TorBox quota. Loosening them speeds bulk scans but risks rate-limit cooldowns that slow `mylist` for every caller; the proxy token bucket in [Architecture](architecture.md) is the second half of the same protection.
- Cache location: keep the cache folder on NVMe and keep bulk media on larger volumes. A growing log file alongside the cache can also fill the disk, so the script rotates the mount log past its size cap.
- Polling: `poll-interval 0` plus `cache-poll-interval 1m` is intentional. The first disables a Changes feed that does not exist; the second keeps local expiry and eviction responsive.
- Verification: after any tuning change confirm the drive is browsable, the RC endpoint answers for stats, one previously stale path refreshes on demand, and proxy metrics show no sustained rate-limit counters. Full tuning order with proxy, Jellyfin, and disk knobs is in [Architecture](architecture.md).

## Session-1 interactive task requirement

The TorBox drive must be started from the interactive user session (Session 1), not from a Session 0 service. This is a Windows WinFsp visibility rule, not a preference.

- The TorBox mount (`torbox:` to drive `T:`) uses `--network-mode`, so the drive letter only appears in the session that started it. A mount started in Session 0 (NSSM service, headless agent, or remote shell without an interactive logon) runs as a process but stays invisible to Explorer, PotPlayer, and Jellyfin in Session 1.
- The Drive folder mount is the contrast: a directory mount can run as the `RcloneGdriveMount` service in Session 0, while the TorBox network-mode `T:` drive cannot. Do not move the TorBox mount into that service.
- Required topology: the supervisor scheduled task is registered as AtLogOn for the media user with Interactive logon type and Highest run level, so it starts in Session 1 on every logon. That task starts the supervisor, and the supervisor starts `mount-torbox.ps1` in the same session through its ordered gate (Drive mount, then TorBox mount, then proxy, bridge, Jellyfin, panel). The TorBox mount script itself has no separate scheduled task; supervisor owns it.
- Symptoms of a wrong-session mount: an `rclone` process matching the TorBox remote exists, yet the drive path is not browsable in the user shell, RC calls from the user session fail, and downstream gates abort with Jellyfin scanning stubs or empty views.
- After any reboot: log on interactively as the same media user so the AtLogOn task fires in Session 1, wait for the supervisor ordered start to report the TorBox gate healthy, then start proxy and above. Do not validate the mount from a different user or from a non-interactive session and conclude it is down.
- Keep the task as AtLogOn Interactive Highest and keep single instance: a second supervisor or a manual mount from another session creates a duplicate owner for the same letter and the same RC port. Use supervisor Start and Status plus panel bulk actions from [Supervisor](supervisor.md) and [Panel](panel.md) instead of launching the mount by hand.

Mounts missing after reboot and the never-start-Jellyfin-first rule are covered in [Troubleshooting](troubleshooting.md).

## How the proxy uses the key

The local proxy in `server/torbox-proxy.py` is the only component that calls TorBox with the key, which keeps the secret in one place.

- TorBox requires the key as a `token` query parameter, while header-only auth returns HTTP 422, so the proxy always builds query auth.
- The proxy serves stable local URLs shaped like proxy host plus torrent, file, and display name, then302-redirects each request to a fresh CDN link, so playlists never store expiring CDN tokens.
- A shared `mylist` cache is refreshed from TorBox at most once per ten minutes, with concurrent callers coalesced so parallel probes cause one upstream call.
- A token bucket paces download-link calls and backs off on rate-limit responses, with live counters on the metrics endpoint.
- The proxy stays on HTTP version 1.0 for compatibility, and per-IP stream slots plus latency histograms are exposed for the panel and Prometheus.

Because proxy URLs re-resolve the CDN on every request, they stay valid across rotation, while direct CDN URLs expire and must never be cached. Architecture and tuning details are in [Architecture](architecture.md).

## Rotation without downtime

Rotate in this order so playback keeps working while the old key drains.

1. Issue the new key in the TorBox dashboard and store it in your password manager.
2. Update `TORBOX_API_KEY` at the same Machine or User scope the stack already uses.
3. Restart the TorBox proxy first, then the supervisor or panel so children inherit the fresh snapshot.
4. Test the CDN path with a launcher play and a direct proxy health plus `mylist` check.
5. Revoke the old key in the dashboard only after the new path plays and sync succeeds.
6. Re-run the MCP smoke test and the Jellyfin status check to confirm automation still authenticates.

If you also rotate Jellyfin credentials, update their env values and re-run the status scripts with no file edits, then restart panel and proxy. The reboot checklist in [Supervisor](supervisor.md) applies after any rotation.

## Verify after any change

```powershell
pwsh -File check_status.ps1 -AsJson
pwsh -File test_mcp_server.ps1
Invoke-RestMethod http://127.0.0.1:8888/health
Invoke-RestMethod http://127.0.0.1:8888/mylist
Invoke-RestMethod http://127.0.0.1:8888/metrics
```

Expect exit code zero, a fresh `mylist` payload, and metrics without sustained rate-limit counters. If `mylist` looks stale, confirm the proxy age header and force one refresh rather than hammering the API. If every TorBox call returns auth errors, confirm the live env value the supervisor sees and check for an extra header-only client in [Troubleshooting](troubleshooting.md). Security rules for storing and sharing keys are in [Reference](reference.md).

---

Back to [Docs Index](index.md).
