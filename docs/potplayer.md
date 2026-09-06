# PotPlayer Playback and Resume

This guide explains the protocol handler, the full-season playlist, and how resume with seek stays in sync with Jellyfin.

## Contents

- [Protocol handler](#protocol-handler)
- [Bridge :18099 wiring](#bridge-18099-wiring)
- [Launcher resolution order](#launcher-resolution-order)
- [Playlist format](#playlist-format)
- [Resume with seek](#resume-with-seek)
- [Playback settings](#playback-settings)
- [Tracker behavior](#tracker-behavior)
- [Verify playback](#verify-playback)

## Protocol handler

Jellyfin and browsers play through custom `potplayer://` links that Windows forwards to PotPlayer.

- Two protocol keys are registered under the classes root, one for `potplayer` and one for `potplayer64`, both pointing at the installed player executable plus the clicked URL.
- Registration is done by `register-potplayer-protocol.ps1` from an elevated prompt, with registry backups before any write, read-back verification after, and rollback on failure. The same script removes both keys in uninstall mode, as described in [Install](install.md).
- The link payload is either base64 after a `b64:` prefix for lossless transport or URL-escaped text as a fallback.
- After decoding, the payload splits on pipe characters into media path plus Jellyfin item ID, user ID, token, and server URL.
- Item payloads shaped like `item:` plus a Jellyfin GUID are resolved inside the launcher, so the browser does not wait for API calls, with undashed IDs normalized to dashed form first.

If clicking does nothing, confirm both protocol command values read back correctly and that only the intended player path is registered. See [Troubleshooting](troubleshooting.md) for the fix order.

## Bridge :18099 wiring

The PotPlayer bridge is a small loopback HTTP helper that the panel and supervisor use to observe bridge health and player status. It is not the launcher itself: the launcher resolves playlists and starts PotPlayer, while the bridge answers health and status probes.

- Loopback only on `127.0.0.1:18099` with two routes: `/health` for liveness and `/status` for player status (`player_running` plus `player_process` JSON used by the panel).
- The bridge script lives outside this repo and is referenced by config. The supervisor and panel both point at the same external helper plus workdir:

```powershell
# supervisor.ps1 / control-panel/control_panel.py wiring (truthful paths)
$BridgeScript = 'E:\MediaServer\tools\potplayer_http_bridge.py'
# health: http://127.0.0.1:18099/health
# status: http://127.0.0.1:18099/status
```

### Bridge Endpoints

| Method & Route | Consumer | Expected Status | Response Format | Purpose |
| --- | --- | --- | --- | --- |
| `GET /health` | Supervisor watchdog, Setup wizard, Control panel | `200 OK` | Plain text or JSON (`{"status": "ok"}` / `OK`) | Fast liveness probe to verify bridge process is listening on `:18099`. |
| `GET /status` | Control panel (`bridge_player_status()`) | `200 OK` | JSON object | Player process inspection returning active PotPlayer execution state. |

#### Example Responses

`GET http://127.0.0.1:18099/health`:
```json
{
  "status": "ok",
  "service": "potplayer_http_bridge",
  "port": 18099
}
```

`GET http://127.0.0.1:18099/status` (Player Active):
```json
{
  "player_running": true,
  "player_process": {
    "pid": 14280,
    "name": "PotPlayerMini64.exe",
    "title": "Show - S01E02 - Episode Title - PotPlayer"
  }
}
```

`GET http://127.0.0.1:18099/status` (Player Idle / Closed):
```json
{
  "player_running": false,
  "player_process": null
}
```

- Supervised as scheduled task `MediaServer_PotPlayerBridge` in the ordered chain `gdrive, torboxmount, proxy, bridge, jellyfin, panel`. The bridge gate requires proxy `:8888/health` OK first, then waits up to ten seconds for `127.0.0.1:18099/health` (proxy gets thirty seconds). Downstream services do not start when the bridge gate fails.
- Dedupe keeps the single LISTENING PID on `127.0.0.1:18099` for `potplayer_http_bridge.py` and kills zombie non-listening duplicates; PID files live under the run folder and health is re-probed as TCP plus HTTP.
- The panel shows the bridge as `PotPlayer Bridge` on port `18099`, probing `/health` for badges and `/status` for the playback card. Install and setup-wizard health tables check `:8888/health`, `:18099/health`, `:18080/health`, and Jellyfin public info together.
- Important scoping: the launcher probes the proxy `:8888/health` once per launch (cached for sixty seconds) and does not probe `:18099` per launch. A dead bridge therefore surfaces in panel badges plus supervisor logs, not as a launcher fallback branch.

If the panel shows proxy healthy but bridge down, check the scheduled task, the LISTENING PID for `:18099`, and supervisor logs for `GATE bridge` lines before re-testing playback.

## Launcher resolution order

The thin shim `PotPlayerLauncher.ps1` forwards to `potplayer-launcher.ps1`, which resolves in this order and logs each branch to `F:\Jellyfin\logs\potplayer-launcher.log`.

Default mode is full-season. Opt out with `-Single` or `POTPLAYER_SINGLE=1` for instant single plus lazy-next. `-WhatIf` logs the resolved `mediaPath` and `itemId` without launching. The watch console is shown unless `NOWATCH=1`, and full-file prefetch only runs with `FULLCACHE=1`.

1. Parse and decode the protocol payload and split `target|itemId|userId|token|serverUrl` fields (server defaults to localhost Jellyfin). `b64:` payloads decode as UTF-8 Base64, otherwise URL-unescaped text is used.
2. Resolve `item:` GUIDs through Jellyfin (`GET /Users/{u}/Items/{id}` with `X-Emby-Token`) to a concrete media path when needed. Undashed 32-char IDs are normalized to dashed form first; Series and Season IDs resolve to their first episode so the browser never waits on API calls.
3. Normalize aliases and slashes: legacy `R:\` maps to `F:\Media\`, forward slashes become backslashes for drive paths.
4. Resolve `.strm` files by reading the first non-empty line to its target inside `T:\` or `F:\Media\`. Unresolved `.strm` entries are never written to playlists.
5. Detect stale VFS entries with an `rclone lsjson` check against the remote, then trigger an RC `vfs/refresh` on `:5572` when present (lightweight remote poll fallback). This avoids the old failure where a missing `T:\` file was treated as valid.
6. Probe proxy health exactly once per launch and cache the result for sixty seconds. Prefer the shared `mylist` bulk cache to stable proxy URLs that redirect to fresh CDN links per request, then local VFS paths, then Jellyfin stream as last resort. Drive paths map to the `:8888/gdrive/` helper path that keeps the full-cache progress bar working.
7. Build the playlist with natural sort (digit runs zero-padded so episode two sorts before episode ten), read resume offset, spawn the hidden per-play tracker, and launch PotPlayer with `/seek=` when resume is greater than zero.

The live log window opens immediately after click so long waits have feedback instead of a silent opening splash, and every launch emits a `TELEMETRY` line with total milliseconds, mode (`fullseason` or `single`), and resume seconds.

## Playlist format

Reliable full-season playback uses DAUM playlist files with a `.dpl` extension. This is the reliable flow, not a single-file launch.

### Reliable Playlist (.dpl) Format Specification

| Field / Key | Format / Value | Description |
| --- | --- | --- |
| Encoding | UTF-16 Little Endian (`Unicode` in PowerShell) with BOM (`FF FE`) | Required for PotPlayer unicode title and international character handling. |
| Header (Line 1) | `DAUMPLAYLIST` | Mandatory signature identifying the file as a Daum playlist. |
| `playname=` (Line 2) | `<active-target-path-or-url>` | Path or URL of the item selected to begin playing immediately on launch. |
| `playindex=` (Line 3) | `<zero-based-index>` (integer) | Zero-based index within the item list corresponding to the active target item. |
| `topindex=` (Line 4) | `0` | Zero-based index of the top visible item in PotPlayer's playlist UI sidebar. |
| `N*file*<path>` | `1*file*...`, `2*file*...` | 1-based indexed file path (local VFS `T:\...`, `F:\Media\...`, or proxy `http://127.0.0.1:8888/...`). |
| `N*title*<title>` | `1*title*...`, `2*title*...` | 1-based indexed display title matching the item at index N. |

#### Example .dpl Content (UTF-16 LE)

```text
DAUMPLAYLIST
playname=http://127.0.0.1:8888/torbox/98765/102/Show%20S01E02.mkv
playindex=1
topindex=0
1*file*http://127.0.0.1:8888/torbox/98765/101/Show%20S01E01.mkv
1*title*Show - S01E01 - Pilot
2*file*http://127.0.0.1:8888/torbox/98765/102/Show%20S01E02.mkv
2*title*Show - S01E02 - Chapter 2
3*file*http://127.0.0.1:8888/torbox/98765/103/Show%20S01E03.mkv
3*title*Show - S01E03 - Chapter 3
```

- PotPlayer is launched against the `.dpl`, not the raw video, with extra args in this order:

```powershell
PotPlayerMini64.exe "playlist.dpl" /seek=<resumeSec>
PotPlayerMini64.exe "single.dpl" /current /seek=<resumeSec>
```

- Generated files live under `F:\Jellyfin\cache\playlists` and are rebuilt per launch with a SHA-16 hash of the season identity: `potplayer-<hash>.dpl` for local seasons, `potplayer-reliable-<hash>.dpl` for the merged reliable path, `potplayer-http-<hash>.dpl` for HTTP proxy seasons, and `potplayer-single-<hash>.dpl` for `-Single` instant start.
- The reliable builder merges three sources and dedupes by resolved source: visible local season directory, authoritative `rclone lsjson` remote listing for the same parent (covers stale `T:\` where WinFsp shows zero or one file), and Jellyfin season episodes via `GET /Shows/{series}/Episodes`. Unresolved `.strm` entries are skipped, and a validated target-only `.dpl` is kept as final safe fallback. The launcher never writes an empty or stale entry.
- Entry URLs prefer stable proxy URLs that redirect per request (`/torbox/{torrent}/{file}/{name}` for TorBox, `/gdrive/{path}` for Drive) over expiring direct CDN links, with local `T:\` or `F:\Media\` paths when healthy and Jellyfin `/Videos/{id}/stream` only as last resort. TorBox bulk resolution reuses the cached `mylist` so a full season does not hammer the API.
- `-Single` mode writes a one-entry `.dpl` and launches with `/current` for instant start without killing the existing player, then a hidden background worker resolves only selected-plus-one (Jellyfin `IndexNumber+1` first, filename `SxxEyy+1` guess second) and appends it with `/add`. Full-season mode kills stale player processes, waits briefly, then launches the full list so next-episode navigation never needs another browser click.
- Long parent paths are mapped through a temporary virtual drive when needed, `FULLCACHE=1` gates background full-file prefetch plus `vfs/cache/fetch`, and a missing-file dialog replaces the raw PotPlayer file-not-found prompt when nothing resolved.
- The repo ships sample playlists plus `test_dpl.ps1`, which asserts header, BOM, and entry count and exits nonzero on failure. Use the samples to compare encoding when a hand-edited playlist refuses to open.

## Resume with seek

Resume is passed as a player `/seek=` argument in seconds, not as a playlist timestamp.

- The launcher queries `GET /Users/{u}/Items/{id}/UserData` before starting the player and converts `PlaybackPositionTicks / 10,000,000` to `resumeSec`.
- New items start from zero, while in-progress items start with `/seek=<resumeSec>` on both full-season and single launches.
- The seek value is logged as `RESUME: <itemId> at <sec>s` plus seek seconds in `PLAYLIST:` and `SINGLE:` lines and the `TELEMETRY` line, so support can confirm what offset was requested.
- Stopping and replaying the same `potplayer://` link re-reads the latest position, so replay always picks up the newest tracker post.

If playback always restarts from zero, confirm the item ID and user ID survived the pipe split and that the tracker is posting, as covered below and in [Jellyfin](jellyfin.md).

## Playback settings

For predictable 4K HDR, multi-channel audio, and smooth progressive streaming, configure PotPlayer with these reference settings:

| Category | Option / Preference | Recommended Value | Reason / Impact |
| --- | --- | --- | --- |
| General | Multiple instances | Disable ("Single process only" / `/current`) | Prevents duplicate players from conflicting with sync tracker singletons. |
| Playback | Auto-load playlist items | Add similar files in folder | Automatically indexes neighboring episodes when opened via direct file. |
| Video | Video Renderer | Built-in Direct3D 11 Video Renderer | High-performance hardware acceleration with HDR tone mapping support. |
| Video | Hardware Acceleration (DXVA) | Enabled (D3D11 / D3D9 Copy-Back) | Offloads 4K HEVC/AV1 decode from CPU to GPU. |
| Audio | Audio Renderer | Default WaveOut or WASAPI Exclusive | Bit-perfect passthrough for Dolby Atmos and DTS-HD tracks. |
| Subtitles | Subtitle Processing | Built-in S/W Subtitle Renderer | Renders styled ASS/SSA and image-based PGS subtitles without stutter. |
| Network | Buffer Size | 64 MB (or maximum progressive buffer) | Smoothes playback over TorBox proxy and Google Drive streams. |
| Launch Flags | CLI switches | `"playlist.dpl" /seek=<sec>` | Enforces accurate position resume and full-season playlist order. |

## Tracker behavior

The tracker `potplayer-sync-tracker.ps1` runs hidden per play and owns progress sync.

- It takes media path, item ID, user ID, token, and server URL, with five-second timeouts and silent failure so playback never blocks on telemetry. `-DryRun` logs without HTTP for manual testing; the launcher never passes it.
- One global mutex per item prefix (`Global\PotPlayerTracker_<8char>`) guarantees a singleton per episode, so a second instance exits immediately.
- It posts playing progress every five seconds to `POST /Sessions/Playing/Progress` with `PositionTicks`, tolerates transient failures with exponential backoff up to sixty seconds (critical Played and Stopped posts bypass backoff with force), and marks played at eighty percent via `POST /Users/{u}/PlayedItems/{id}`, which drives Next Up.
- The console viewer `show-playback-log.ps1` tails episode hints, five-second ticks, and played markings for live debugging.

The tracker never throws to the player, so a silent tracker means Jellyfin auth or item IDs, not PotPlayer itself. See [Troubleshooting](troubleshooting.md) for the log lines to search.

## Verify playback

```powershell
pwsh -File test_dpl.ps1 -SkipLaunch
Invoke-RestMethod http://127.0.0.1:8888/health
Invoke-RestMethod http://127.0.0.1:18099/health
Invoke-RestMethod http://127.0.0.1:18099/status
pwsh -File supervisor.ps1 -Mode Status
```

Expect a passing playlist test (header plus BOM plus entries), a healthy proxy, healthy bridge `/health` plus player `/status`, and a healthy bridge row in supervisor status. Then click one episode, confirm the full season queues in natural order with the clicked episode selected, close at mid-episode, reopen the same link, and confirm it resumes near the close point with `RESUME:` plus five-second ticks visible in the log viewer. Panel playback cards for the same session are explained in [Panel](panel.md), and the overall flow is in [Architecture](architecture.md).

---

Back to [Docs Index](index.md).
