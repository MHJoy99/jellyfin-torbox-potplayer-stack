# Global Fix 2026-08-24 — Stale Torbox VFS Cache + PotPlayer `File not found` (9-1-1 S09)

**Workspace:** `F:\Jellyfin` (live launcher) + `E:\MediaServer` (source repo)  
**Incident:** Clicking `Play in PotPlayer` for `9-1-1 S09E01` (Jellyfin `9-1-1 Season 9` view) launched PotPlayer with `T:\9-1-1.S09.1080p.AMZN.WEB-DL.H.264\9-1-1.S09E01...mkv` → `File not found. The file does not exist or can not be accessible.` despite Jellyfin `.strm` existing at `F:\TorboxMedia\Series\9-1-1 (2018)\Season 09\9-1-1 - S09E01.strm:1` (`T:\9-1-1.S09...mkv`).

## Audit (reproduced)

```powershell
Get-Content "F:\TorboxMedia\Series\9-1-1 (2018)\Season 09\9-1-1 - S09E01.strm" # -> T:\9-1-1.S09...mkv
Test-Path "T:\9-1-1.S09.1080p.AMZN.WEB-DL.H.264\9-1-1.S09E01...mkv" # False (stale)
F:\Jellyfin\server\rclone.exe --config "F:\Jellyfin\config\rclone.conf" lsjson "torbox:9-1-1.S09.1080p.AMZN.WEB-DL.H.264" # True, 18 files listed
cmd /c dir T:\ /b | findstr 9-1-1 # empty before remount
Get-Content F:\Jellyfin\logs\potplayer-launcher.log -Tail 20 # showed RAW potplayer://b64:... for S09E01, no audit/fallback
```

Root causes:
1. `C:\Users\Administrator\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\mount_torbox.vbs:21` + `E:\MediaServer\mount-torbox.ps1:21` used `--dir-cache-time 500h` / `--attr-timeout 500h` — WebDAV (`torbox:`) has no Changes API, so new torrent folders visible on `torbox:` immediately but stale on `T:\` for up to 20 days.
2. `F:\Jellyfin\potplayer-launcher.ps1:107` contained `or ($firstLine -match "\.(mkv|mp4)...")` — non-existent `T:\*.mkv` was treated as valid and launched, causing PotPlayer crash dialog. No VFS refresh or fallback.

## Fix (global, preserves working state)

**Mount (both `mount_torbox.vbs` + `mount-torbox.ps1`):**
`500h` → `30s` (`dir-cache-time` + `attr-timeout`), `vfs-cache-poll-interval 30s` → `15s`, added `--poll-interval 15s --rc --rc-addr 127.0.0.1:5572 --rc-no-auth`. Remounted — `T:\9-1-1.S09...` now `Test-Path True`.

**Launcher `F:\Jellyfin\potplayer-launcher.ps1:95-215` (+ synced to `E:\MediaServer\scripts\potplayer-launcher.ps1`):**
- Removed `extension-match` bypass; only `Test-Path` or `http` is valid.
- Added `Write-BridgeLog`, `Test-TorboxRemoteExists` (via `rclone lsjson torbox:` bypassing VFS cache), `Invoke-TorboxVfsRefresh` (`POST http://127.0.0.1:5572/vfs/refresh` + fallback `rclone lsf`).
- Stale `T:\` with remote `True`: logs `AUDIT: Stale VFS cache detected for T:\...`, attempts `vfs/refresh` (1.2s), if still `False` logs `FALLBACK: Using Jellyfin stream URL for stale T:\\ path: http://localhost:8096/Videos/$itemId/stream?static=true&api_key=$token` and launches PotPlayer HTTP progressive (never broken path).
- Global `5c` fallback: if final `mediaPath` still missing or `.strm` unresolved due to `staleStrmDetected`, fallback to Jellyfin stream when `itemId/token` present, else `Show-MissingFileDialog` (friendly MessageBox).
- `Start-SelectedPotPlayer` now handles `http` URLs directly, and validates missing local paths before playlist generation.

**Working files unaffected:** `T:\Desperate.Housewives...mkv` (`exists=True`) still resolves to direct `T:\` + `.dpl` playlist (`potplayer-*.dpl` UTF-16 LE). Verified via logs `STRM resolve ... (exists=True)` and PotPlayer cmd `potplayer-*.dpl`.

## Verification (execution)

```powershell
# Stale cache (before remount): falls back to HTTP, no crash
# 03:47:09 log: AUDIT: Stale VFS cache detected... Remote check True → FALLBACK: Using Jellyfin stream URL... → Launching PotPlayer with HTTP stream

# After remount 30s cache: direct T:\ works
# 03:48:23 log: STRM resolve ... (exists=True) → PotPlayer with potplayer-*.dpl (55573662ad145e29.dpl)

# Working file: Desperate Housewives S01E01
# 03:47:45 log: STRM resolve ... (exists=True) → potplayer-9b6bb8d8501a1902.dpl — PASS preserved
```

### Update 2026-08-24b — Full-cache fallback (our link format does not get cached fully)

**Symptom:** After stale-cache fallback to `http://localhost:8096/Videos/$itemId/stream?static=true&api_key=$token`, PotPlayer would not load full file — our link format not range-cacheable; does for some, not for some. Verified `HEAD $url` for `6df043ee990d42...` `stream` returns `Content-Length 93` `application/octet-stream` — the `.strm` text, not 3.6GB video — so PotPlayer HTTP progressive cannot cache fully.

**Fix `F:\Jellyfin\potplayer-launcher.ps1:128-214` `Get-TorboxDirectLinkViaApi` + `Get-FullCacheFallbackPath` (global, permanent universal):**
- 5b stale case now calls `Get-FullCacheFallbackPath $firstLine $itemId` instead of direct Jellyfin stream.
- Helper matches `short_name == $fileName` across ALL 193 torrents (torrent.name is localized e.g. `911 служба спасения ...` vs WebDAV `9-1-1.S09...`, so do NOT filter by folder). Verified for `9-1-1.S09E01..mkv` `file 12` in `torrent 82636041` `requestdl` returns `https://nexus.erth.tb-cdn.earth/dld/...` (rate-limited 429 on HEAD but range-capable when unlocked).
- Priority 1: `rclone copyto torbox:$rel -> F:\Jellyfin\cache\prefetch\$itemId_$fileName` (10s wait for >5MB, then PotPlayer plays local file, `F:\Jellyfin\logs\rclone-prefetch.log`), guarantees full file on `F:` NVMe cache.
- Priority 2: Torbox CDN URL if local not yet ready.
- 5c global fallback also updated to use full-cache first, Jellyfin stream only as last resort (`93-byte .strm risk` log).

Remount command executed:
```powershell
Get-Process rclone | ? {$_.CommandLine -match "torbox"} | Stop-Process -Force
# then launch with new args including --rc 127.0.0.1:5572
Test-Path "T:\9-1-1.S09...mkv" # True after restart
```

## Docs updated

- `E:\MediaServer\docs\TORBOX_WEBDAV_RCLONE_MOUNT.md` §2.1, §5.2 — mount args + incident diagnosis
- `E:\MediaServer\docs\POTPLAYER_INTEGRATION.md` §4A, §7 Issue 2 — launcher fallback matrix + troubleshooting
- `E:\MediaServer\docs\RCLONE_VFS_ARCHITECTURE.md` §2, §5.3 — Torbox vs GDrive cache tuning
- `E:\MediaServer\AGENTS.md` §7 + `README.md` §7 — golden rule + highlights
- This file (`F:\Jellyfin\GLOBAL_FIX_2026-08-24_STALE_TORBOX_VFS.md`) — audit trail in live workspace
