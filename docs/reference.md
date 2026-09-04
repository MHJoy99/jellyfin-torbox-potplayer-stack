# Reference: Glossary, Security, and Backup

This reference collects the shared vocabulary, the security rules, and the backup plus restore plan in one place.

## Contents

- [Glossary](#glossary)
- [Security](#security)
- [Backup](#backup)
- [Restore](#restore)

## Glossary

Fifteen terms appear across every other guide, so definitions stay here and guides link back.

### 1. Stream file (.strm)

A tiny text file that holds one media URL or mount path instead of video bytes. Jellyfin scans these files into playable items, which is why [Jellyfin](jellyfin.md) treats them as the library source of truth.

### 2. Virtual filesystem (VFS)

A rclone layer that presents cloud remotes as local files with caching. The stack uses one VFS mount for TorBox and one for Drive, both gated before Jellyfin starts in [Supervisor](supervisor.md).

### 3. Singleflight

A proxy pattern where concurrent requests for the same torrent and file join one in-flight upstream call instead of firing duplicates. It protects the shared mylist path described in [TorBox](torbox.md).

### 4. Token bucket

A rate limiter that holds a capped number of tokens, refills over time, and spends one token per download-link call, with cooldown on rate-limit responses. Bucket counters appear on the metrics endpoint in [Panel](panel.md).

### 5. CDN redirect (302)

A short proxy response that points the player at a fresh expiring CDN link. Playlists store stable proxy URLs that redirect per request, so expiry never breaks saved seasons, per [Architecture](architecture.md).

### 6. Directory cache (dir-cache)

A short-lived VFS listing cache that keeps browsing fast. The default thirty-second window balances freshness with API cost, with targeted refresh calls for stale paths in [Troubleshooting](troubleshooting.md).

### 7. Remote control (RC)

The localhost rclone control port used for directory refresh, cache fetch, and transfer stats. The launcher and MCP helpers call it when present, as listed in [Architecture](architecture.md).

### 8. DAUM playlist (.dpl)

A UTF-16 PotPlayer playlist with a DAUMPLAYLIST header that queues a full season in natural sort order. Generation and tests are covered in [PotPlayer](potplayer.md).

### 9. Protocol handler

Registry keys that map `potplayer://` and the 64-bit variant to the installed player plus clicked URL. Registration, backup, verify, and removal live in [PotPlayer](potplayer.md) and [Install](install.md).

### 10. Watchdog

The supervisor loop that probes every service every fifteen seconds with HTTP, path, and PID checks and restarts with fast retries then cooldown. Modes and backoff are in [Supervisor](supervisor.md).

### 11. Forensics bundle

A timestamped zip of logs, PID files, and sync state built by Forensics mode for support. Contents and timing are in [Supervisor](supervisor.md).

### 12. Next Up

The Jellyfin queue that advances to the following episode after the current item is marked played at eighty percent. Tracker posts that drive it are in [Jellyfin](jellyfin.md).

### 13. TMDB

The metadata provider Jellyfin uses for titles, posters, seasons, and episode order. Matching behavior is in [Jellyfin](jellyfin.md).

### 14. NSSM

The service wrapper that runs rclone mounts persistently with auto-restart. Install and removal through the mount installer are in [Install](install.md).

### 15. Prometheus and Nagios codes

Prometheus scrapes proxy metrics with latency histograms, while health scripts exit zero for healthy, one for warming, and two for investigate, plus JSON modes for automation. Both surfaces are summarized in [Architecture](architecture.md).

## Security

Secrets stay in the environment, services stay on loopback, and remote access requires an explicit authenticated edge.

- Env-only secrets: `TORBOX_API_KEY`, Jellyfin user and password, Jellyfin API key, rclone OAuth config, and tunnel tokens live only in Machine or User env, OS stores, or untracked config, and never in tracked files, command lines, screenshots, or bundles. Rotation is in [TorBox](torbox.md).
- Localhost binding: Jellyfin, proxy, bridge, panel, and rclone RC all bind to loopback by default, which is why [Quickstart](quickstart.md) and [Architecture](architecture.md) use loopback URLs everywhere.
- No-auth LAN warning: the panel and proxy have no login by design, so binding them to LAN or port-forwarding them without authentication lets anyone on the network control playback, restart services, or spend TorBox quota. Do not do this.
- Safer remote use: expose Jellyfin only through a TLS reverse proxy or authenticated tunnel with its own login, keep the panel and proxy on loopback, and use VPN or authenticated remote desktop when panel control is needed away from the host.
- Least privilege: run installers elevated only for protocol and service steps, keep per-user panel tasks at limited run level, lock the rclone config ACL to Administrators plus owner, and keep MCP subcommands allowlisted with no config override or shell metacharacters.
- Evidence hygiene: redact tokens from logs and bundles before sharing, because proxy URLs are safe to share while CDN tokens and env dumps are not.

## Backup

Back up the small irreplaceable state and exclude the large regenerable runtime.

Back up these items:

- Install receipts: the version stamp folder with one JSON per installer, plus registry backup exports taken before protocol writes.
- Answers and intent: your recorded installer choices such as task names, ports, mount selections, and panel options, kept as a short note alongside the receipts.
- Sync state: the Drive sync state JSON that records what was already imported, so a reinstall does not duplicate libraries.
- Untracked config: the live rclone config, tunnel config, and env export with secrets redacted, plus the template diff when you changed defaults.
- Jellyfin data: the Jellyfin data folder when you want to keep manual matches, watch state, and API keys across machines.

Do not back up logs, cache, prefetch, transcodes, PID files, or CDN URLs, because all of them regenerate or expire. The forensics bundle is diagnostic evidence, not a backup, and must never stand in for the items above.

## Restore

1. Reinstall the OS prerequisites plus PowerShell 7, Python, PotPlayer, rclone with WinFsp, and NSSM when services are used.
2. Clone the repo branch fresh and re-run the one-click installer from [Install](install.md) before restoring state.
3. Restore the rclone config and tunnel config to their untracked locations, re-apply ACLs, and re-set env secrets from [TorBox](torbox.md) in a fresh shell.
4. Restore sync state and Jellyfin data, then start with the supervisor in Start mode and run every verify step from [Quickstart](quickstart.md).
5. Trigger a library refresh, confirm views return exit code zero, play one episode through [PotPlayer](potplayer.md), and confirm tracker progress reaches the panel in [Panel](panel.md).

Keep one tested restore note with your receipts so the next migration repeats the same order without guessing.

---

Back to [Docs Index](index.md).
