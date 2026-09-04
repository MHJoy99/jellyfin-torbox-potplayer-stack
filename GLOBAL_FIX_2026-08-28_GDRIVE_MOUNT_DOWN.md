# Global Fix 2026-08-28 — Google Drive Mount Down (`R:` alias conflict) + Control Panel UX Redesign

**Workspace:** `F:\Jellyfin` (live) + `E:\MediaServer` (source repo)
**Incident:** GDrive media disappeared from Jellyfin. No `gdrive-media` rclone process; `R:\` and `F:\Media` both unresolved. TorBox `T:\` unaffected.

## Audit (reproduced)

```powershell
Get-Process rclone                      # only torbox mount PID (T:\)
Test-Path R:\; Test-Path F:\Media       # False / False
rclone --config F:\Jellyfin\config\rclone.conf lsd gdrive-media:   # OK: Movies, Series (OAuth auto-refresh works)
rclone mount gdrive-media: R: ...       # ERROR: "Cannot create WinFsp-FUSE file system: mount point in use."
```

Root causes:
1. `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\DOS Devices` contains `"R:"="\??\F:\Media"` (persistent kernel alias). WinFsp refuses to mount on `R:` while the alias exists ("mount point in use"), so the logon task `Mount Google Shared Drive R` (which mounts `R:`) can never succeed on this machine.
2. The NSSM service `RcloneGdriveMount` (documented production topology: mount `gdrive-media:` → `F:\Media`) was not installed/running, so nothing served `F:\Media`.
3. Mounting onto a pre-created non-empty-or-existing `F:\Media` dir also fails ("mountpoint path already exists") — rclone must create the mountpoint itself.

## Fix (permanent, documented topology restored)

1. Ran `F:\Jellyfin\install-rclone-service.ps1`: installs NSSM service `RcloneGdriveMount` (StartType **Automatic**, Session 0) mounting `gdrive-media:` → `F:\Media` with the production flag set (80G/4h VFS cache, dir-cache 1000h, pacer burst 200). Service now `Running`.
2. `R:\` kernel alias now resolves through `F:\Media` — both paths list `Movies` + `Series`.
3. Jellyfin virtual folders already span `F:\Media\Movies|Series` + `F:\TorboxMedia\...`; triggered `POST /Library/Refresh` → library repopulated: **53 Series / 110 Movies** (incl. GDrive title `Cursed`).
4. Logon task `Mount Google Shared Drive R` is now harmless: its idempotency guard `if (Test-Path R:\) { exit 0 }` exits early while the service holds the mount.

Verification:

```powershell
Get-Service RcloneGdriveMount            # Running, Automatic
Get-ChildItem F:\Media, R:\              # Movies, Series on both
# Jellyfin API /Users/{id}/Items?IncludeItemTypes=Series|Movie → 53 / 110
```

## Control Panel UX redesign (same session)

`F:\Jellyfin\control-panel\{index.html,app.css,app.js}` rewritten (backend `control_panel.py`, `.vbs`, installers untouched):
- Sticky topbar: brand, live stack chip ("All systems healthy" / degraded states), last-checked ticker, refresh, global Start/Restart/Stop all.
- Service cards with HEALTHY badges, state accent bars, meta chips (version, host, process count, PotPlayer idle/active), per-service actions with busy/spinner/disabled handling.
- Activity timeline with relative + absolute timestamps, auto-refresh; 5s status polling (paused when tab hidden); responsive breakpoints; no CDN deps.
- Verified: `node --check app.js` clean; `/`, `/app.css`, `/app.js` = 200; headless render desktop+mobile with 0 console errors; screenshot `F:\Jellyfin\control-panel-final.png`.

## Full-season playlist fix (global rule)

**Incident:** Clicking Lock Upp S02E01 (GDrive) launched PotPlayer with a 1-entry playlist; user rule = every episode click must load the full season with direct links.
**Root cause:** `potplayer-launcher.ps1:563` `$hasOriginal` gate matched only `^[Tt]:\\`, but GDrive plays set `originalTPathForHttp = F:\Media\...`, so the existing GDrive multi-episode `.dpl` branch (line ~742) was unreachable → single-file launch.
**Fix:** gate now accepts `T:\`, `F:\Media\`, `G:\`. Verified live: Lock Upp S02 launch wrote `potplayer-http-*.dpl` with all 6 season episodes as `127.0.0.1:8888/gdrive/...` proxy links (log: `HTTP GDrive playlist full 6`). Synced to `E:\MediaServer\scripts\potplayer-launcher.ps1`; codified as Golden Rule 8 in `E:\MediaServer\AGENTS.md`. UTF-8 BOM + parser check OK.
**Note:** S02E02 absent on GDrive itself (library gap; user will add) — playlist mirrors source contents.

## Notes / follow-ups

- **DONE 2026-08-28:** `gdrive-media` now uses a custom OAuth client (`client_id`/`client_secret` from `C:\Users\Administrator\Downloads\client_secret_321463669656-....json`, project `massive-boulder-503110-h8`) added to `F:\Jellyfin\config\rclone.conf`; re-authed via `rclone config reconnect gdrive-media:` (browser consent), fresh token written, shared-client NOTICE gone, `RcloneGdriveMount` restarted. Backup of old conf: `rclone.conf.bak-20260828`.
- `E:\MediaServer\mount-gdrive.ps1` mounts `R:` directly and will always fail on this host while the DOS alias exists; prefer `install-rclone-service.ps1` (F:\Media). Consider updating `mount-gdrive.ps1` + the logon task script `C:\Users\Administrator\Documents\Codex\2026-07-27\how-fast\work\start-gdrive-mount.ps1` to target `F:\Media` (left as-is; guard makes them no-ops while service is up).
