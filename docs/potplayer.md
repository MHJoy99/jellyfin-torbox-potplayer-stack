# PotPlayer Playback and Resume

This guide explains the protocol handler, the full-season playlist, and how resume with seek stays in sync with Jellyfin.

## Contents

- [Protocol handler](#protocol-handler)
- [Launcher resolution order](#launcher-resolution-order)
- [Playlist format](#playlist-format)
- [Resume with seek](#resume-with-seek)
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

## Launcher resolution order

The thin shim `PotPlayerLauncher.ps1` forwards to `potplayer-launcher.ps1`, which resolves in this order and logs each branch.

1. Parse and decode the protocol payload and split metadata fields.
2. Resolve `item:` GUIDs through Jellyfin to a concrete media path when needed.
3. Resolve `.strm` files to their target inside the VFS mounts.
4. Detect stale VFS entries and trigger an rclone RC refresh before giving up.
5. Prefer the shared `mylist` cache and local VFS path, then fall back to the TorBox proxy URL that never stores expiring CDN tokens.
6. Map Drive paths to the proxy helper path that keeps the full-cache progress bar working.
7. Build a full-season natural-sorted playlist and launch PotPlayer with resume seek.

The launcher probes proxy health once per launch and shows the live log window immediately so long waits have feedback instead of a silent opening splash.

## Playlist format

Full-season playback uses DAUM playlist files with a `.dpl` extension.

- Files are UTF-16 encoded with the DAUMPLAYLIST header so PotPlayer opens the whole season in order.
- The generated season file lives under the playlists cache folder and is rebuilt per launch.
- Entries are natural-sorted so multi-digit episodes stay in numeric order.
- Direct HTTP entries use stable proxy URLs that redirect to fresh CDN links per request, while VFS entries use mount paths that must already be healthy.
- The repo ships sample playlists plus `test_dpl.ps1`, which asserts structure and exits nonzero on failure.

Use the sample files to compare encoding when a hand-edited playlist refuses to open.

## Resume with seek

Resume is passed as a player seek argument, not as a playlist timestamp.

- The launcher queries Jellyfin for the saved position of the item ID before starting the player.
- New items start from zero, while in-progress items start with a seek argument at the saved offset.
- The seek value is logged with a resume marker so support can confirm what offset was requested.
- Stopping and replaying the same `potplayer://` link re-reads the latest position, so replay always picks up the newest tracker post.

If playback always restarts from zero, confirm the item ID and user ID survived the pipe split and that the tracker is posting, as covered below and in [Jellyfin](jellyfin.md).

## Tracker behavior

The tracker `potplayer-sync-tracker.ps1` runs hidden per play and owns progress sync.

- It takes media path, item ID, user ID, token, and server URL, with short timeouts and silent failure so playback never blocks on telemetry.
- One global mutex per item prefix guarantees a singleton per episode, so a second instance exits immediately.
- It posts playing progress every five seconds, tolerates transient failures with backoff, and marks played at eighty percent, which drives Next Up.
- The console viewer `show-playback-log.ps1` tails episode hints, five-second ticks, and played markings for live debugging.

The tracker never throws to the player, so a silent tracker means Jellyfin auth or item IDs, not PotPlayer itself. See [Troubleshooting](troubleshooting.md) for the log lines to search.

## Verify playback

```powershell
pwsh -File test_dpl.ps1
Invoke-RestMethod http://127.0.0.1:8888/health
pwsh -File supervisor.ps1 -Mode Status
```

Expect a passing playlist test, a healthy proxy, and a healthy bridge row. Then click one episode, confirm the full season queues, close at mid-episode, reopen the same link, and confirm it resumes near the close point with progress visible in the log viewer. Panel playback cards for the same session are explained in [Panel](panel.md), and the overall flow is in [Architecture](architecture.md).

---

Back to [Docs Index](index.md).
