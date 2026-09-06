# Jellyfin Libraries and Resume

This guide explains how Jellyfin libraries are built from stream files, how virtual folders are set up, how TMDB matching works, and what resume behavior to expect during PotPlayer playback.

## Contents

- [Library model](#library-model)
- [Library setup](#library-setup)
- [TMDB matching](#tmdb-matching)
- [Resume expectations](#resume-expectations)
- [Key API calls](#key-api-calls)
- [Verify libraries and views](#verify-libraries-and-views)

## Library model

Libraries are built from small `.strm` text files plus sidecars, not from copied video files.

- Each `.strm` is a tiny text file whose first non-empty line points at the real media inside a VFS mount. TorBox items point at `T:\` paths, Drive items point at `F:\Media\` paths:

```text
T:\Show.S01\Show.S01E01.mkv
```

- The TorBox VFS mount exposes cloud files as `T:\` local paths, and the Drive mount serves `F:\Media\`. Jellyfin scans those folders on library refresh and creates items, views, seasons, and episodes from the `.strm` files.
- A missing or warming VFS mount produces tiny stub streams or missing views, so mounts must be healthy before Jellyfin starts, in the order `gdrive, torboxmount, proxy, bridge, jellyfin, panel` described in [Supervisor](supervisor.md).
- Virtual folders are the source of truth: Jellyfin `GET /Library/VirtualFolders` lists each library name, collection type, and locations. Canonical locations are `F:\Media\Movies` and `F:\Media\Series` plus TorBox media folders.

Keep library folder names stable, because renames force full rescans and lose manual matches. The end-to-end ingest-to-scan flow is diagrammed in [Architecture](architecture.md).

## Library setup

Use the tracked setup helpers with env credentials, never hardcoded secrets. All three read `JELLYFIN_URL` (default localhost Jellyfin), `JELLYFIN_USER`, and `JELLYFIN_PASSWORD` from the environment.

- `clean_and_setup_libraries.ps1` removes known empty stubs (`Movies2`, `Series`, `Movies`) then re-creates the canonical `Movies` library at `MOVIES_PATH` (default `F:\Media\Movies`) via `POST /Library/VirtualFolders/Paths?collectionType=movies&refreshLibrary=true`, then triggers `POST /Library/Refresh`. Supports `-WhatIf` dry-run and `-OlderThanDays` stale threshold for reporting.
- `cleanup_extra_libraries.ps1` and `cleanup_and_check_items.ps1` list virtual folders and delete extras or stubs, also with dry-run preview before any mutating call.
- `delete_stale_views.ps1` removes stale view IDs after library moves.
- `gdrive-library-sync.ps1` keeps the Drive mount and Jellyfin converged in `Run`, `Once`, `WhatIf`, and `OrphanReport` modes: it observes the remote directly, refreshes the mounted VFS, repairs the mount when needed, asks Jellyfin to scan via `POST /Library/Refresh`, and verifies new media appears before acknowledging the change.
- After any sync write, bulk rename, or virtual-folder change, trigger `POST /Library/Refresh` and wait about sixty seconds before judging views. The Drive sync state, heartbeat, and logs live under the config and logs folders described in [Architecture](architecture.md).

## TMDB matching

Jellyfin uses filename parsing plus the TMDB provider to attach titles, posters, seasons, and episode order.

- Name files with show, season, and episode tokens (for example `Show - S01E02.mkv` inside `Show (2025)/Season 01/`) so the parser can group full seasons correctly.
- The launcher uses the same natural sort that pads digit runs, so episode two sorts before episode ten without manual reordering, and the reliable playlist builder merges Jellyfin season episodes when filesystem listings are incomplete.
- When a match is wrong, fix it in the Jellyfin dashboard with Identify, then lock the match so future scans keep it.
- After bulk renames or sync changes, trigger `POST /Library/Refresh` and wait about sixty seconds before judging views.

If posters or episode lists stay wrong after a refresh, confirm the `.strm` first lines resolve to existing `T:\` or `F:\Media\` targets and the thirty-second VFS dir cache has refreshed via RC, as covered in [Troubleshooting](troubleshooting.md).

## Resume expectations

Resume is owned by Jellyfin state plus the PotPlayer tracker, not by the player alone.

- The launcher passes the Jellyfin item ID, user ID, token, and server URL alongside the media path (`target|itemId|userId|token|serverUrl`), then reads `GET /Users/{u}/Items/{id}/UserData` and converts `PlaybackPositionTicks` to seconds for `/seek=`.
- PotPlayer starts with a seek argument at the saved position for in-progress items and from zero for unwatched items. The offset is logged as `RESUME:` in `F:\Jellyfin\logs\potplayer-launcher.log`.
- The sync tracker posts playing progress every five seconds while PotPlayer runs, using a per-item singleton (`Global\PotPlayerTracker_<8char>`) so duplicate trackers cannot double-report, with backoff on transient failures.
- At eighty percent watched, the tracker marks the item played via `POST /Users/{u}/PlayedItems/{id}`, which advances Next Up to the following episode.
- Pauses keep the last reported position, and closing the player keeps that position for the next launch.

Expect resume to lag by a few seconds after a hard kill, because the last interval may not have posted. Expect Next Up to advance only after the eighty-percent mark, not at the credits start.

## Key API calls

The stack uses a small stable subset of the Jellyfin API. Auth uses `POST /Users/AuthenticateByName` with `JELLYFIN_USER` and `JELLYFIN_PASSWORD` from env plus `X-Emby-Authorization`, then `X-Emby-Token` for the rest. No secret is hardcoded.

| Call | Purpose |
| --- | --- |
| `GET /System/Info/Public` | Liveness probe used by the supervisor and panel without auth. `GET /System/Info` is the authenticated variant used by status checks. |
| `POST /Users/AuthenticateByName` | Login with env credentials for automation scripts. |
| `GET /Library/VirtualFolders` | Library listing used by setup and status checks; mutating variants create and delete libraries. |
| `GET /Users/{u}/Views` | Per-user view listing used by view checks. |
| `GET /Users/{u}/Items/{id}` and `/Users/{u}/Items/{id}/UserData` | Item detail plus resume ticks used by the launcher and tracker. |
| `GET /Shows/{series}/Episodes` | Season episode listing with `UserId`, `SeasonId`, and `Fields=Path` used for playlist merge and lazy-next. |
| `POST /Library/Refresh` | Trigger a rescan after sync writes new `.strm` files. |
| `GET /Videos/{id}/stream` | Direct stream URL pattern used only as last-resort fallback when VFS plus proxy both fail. |
| `POST /Sessions/Playing/Progress` | Five-second progress heartbeat from the tracker. |
| `POST /Users/{u}/PlayedItems/{id}` | Mark played at the eighty-percent threshold. |

Full restart order and log locations for these calls are in [Supervisor](supervisor.md).

## Verify libraries and views

```powershell
pwsh -File check_status.ps1 -AsJson
pwsh -File check_user_views.ps1 -AsJson
pwsh -File check_views_after_restart.ps1 -AsJson
pwsh -File clean_and_setup_libraries.ps1 -WhatIf
```

Expect exit code zero for healthy auth plus libraries plus views. Code one means warming or zero views after a restart, while code two means investigate scans, mounts, and logs. `check_status.ps1` checks server info plus auth plus virtual folders, `check_user_views.ps1` also triggers `POST /Library/Refresh`, `check_views_after_restart.ps1` does auth plus views with no refresh trigger, and `clean_and_setup_libraries.ps1 -WhatIf` previews stub deletes plus Movies re-create without mutating. If views are still empty after warming, trigger a refresh, wait sixty seconds, inspect Jellyfin logs, and confirm `T:\` and `F:\Media\` mounts from [Quickstart](quickstart.md) before editing library paths. Playback-side resume checks are in [PotPlayer](potplayer.md), and symptom fixes are in [Troubleshooting](troubleshooting.md).

---

Back to [Docs Index](index.md).
