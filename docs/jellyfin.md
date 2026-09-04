# Jellyfin Libraries and Resume

This guide explains how Jellyfin libraries are built from stream files, how TMDB matching works, and what resume behavior to expect during PotPlayer playback.

## Contents

- [Library model](#library-model)
- [TMDB matching](#tmdb-matching)
- [Resume expectations](#resume-expectations)
- [Key API calls](#key-api-calls)
- [Verify libraries and views](#verify-libraries-and-views)

## Library model

Libraries are built from small `.strm` text files plus sidecars, not from copied video files.

- The Drive sync script writes one `.strm` per episode or movie into the local media folder, alongside metadata sidecars when available.
- The TorBox VFS mount exposes cloud files as local paths, which the same `.strm` files can point to.
- Jellyfin scans the media folder on a library refresh and creates items, views, seasons, and episodes from those files.
- A missing or warming VFS mount produces tiny stub streams or missing views, so mounts must be healthy before Jellyfin starts, in the order described in [Supervisor](supervisor.md).
- Reset and cleanup helpers support dry-run flags that preview deletes before removing stubs, extra libraries, or stale view IDs.

Keep library folder names stable, because renames force full rescans and lose manual matches. The end-to-end ingest-to-scan flow is diagrammed in [Architecture](architecture.md).

## TMDB matching

Jellyfin uses filename parsing plus the TMDB provider to attach titles, posters, seasons, and episode order.

- Name files with show, season, and episode tokens so the parser can group full seasons correctly.
- The launcher uses natural sort that pads digit runs, so episode two sorts before episode ten without manual reordering.
- When a match is wrong, fix it in the Jellyfin dashboard with Identify, then lock the match so future scans keep it.
- After bulk renames or sync changes, trigger `POST /Library/Refresh` and wait about sixty seconds before judging views.

If posters or episode lists stay wrong after a refresh, confirm the `.strm` targets resolve and the VFS dir cache has refreshed, as covered in [Troubleshooting](troubleshooting.md).

## Resume expectations

Resume is owned by Jellyfin state plus the PotPlayer tracker, not by the player alone.

- The launcher passes the Jellyfin item ID, user ID, token, and server URL alongside the media path, then resolves the current resume offset.
- PotPlayer starts with a seek argument at the saved position for in-progress items and from zero for unwatched items.
- The sync tracker posts playing progress every five seconds while PotPlayer runs, using a per-item singleton so duplicate trackers cannot double-report.
- At eighty percent watched, the tracker marks the item played, which advances Next Up to the following episode.
- Pauses keep the last reported position, and closing the player keeps that position for the next launch.

Expect resume to lag by a few seconds after a hard kill, because the last interval may not have posted. Expect Next Up to advance only after the eighty-percent mark, not at the credits start.

## Key API calls

The stack uses a small stable subset of the Jellyfin API.

| Call | Purpose |
| --- | --- |
| `GET /System/Info/Public` | Liveness probe used by the supervisor and panel without auth. |
| `POST /Users/AuthenticateByName` | Login with env credentials for automation scripts. |
| `GET /UserViews` and library queries | View and episode listing used by check scripts. |
| `POST /Library/Refresh` | Trigger a rescan after sync writes new `.strm` files. |
| `GET /Videos/{id}/stream` | Direct stream URL pattern for API clients. |
| `POST /Sessions/Playing/Progress` | Five-second progress heartbeat from the tracker. |
| `POST /Users/{u}/PlayedItems/{id}` | Mark played at the eighty-percent threshold. |

Full restart order and log locations for these calls are in [Supervisor](supervisor.md).

## Verify libraries and views

```powershell
pwsh -File check_status.ps1 -AsJson
pwsh -File check_user_views.ps1 -AsJson
pwsh -File check_views_after_restart.ps1 -AsJson
```

Expect exit code zero for healthy auth plus libraries plus views. Code one means warming after a restart, while code two means investigate scans, mounts, and logs. If views are still empty after warming, trigger a refresh, inspect Jellyfin logs, and confirm the mounts from [Quickstart](quickstart.md) before editing library paths. Playback-side resume checks are in [PotPlayer](potplayer.md), and symptom fixes are in [Troubleshooting](troubleshooting.md).

---

Back to [Docs Index](index.md).
