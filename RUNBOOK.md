# NexusMedia Jellyfin Stack — Runbook

> Never commit secrets. All credentials are environment variables or the OS
> credential store. Rotate by updating env/registry + restarting services below.

## 1. Restart order

Correct order avoids stale VFS, 93-byte `.strm` streams, and missing views.

1. **rclone mounts** (`T:\` TorBox, `G:\` Drive) — VFS must be up first.
   - Service: `mount_torbox` / NSSM `install-rclone-service.ps1`, or `mount-gdrive.ps1`.
   - Verify: `Test-Path T:\`, `Test-Path G:\`, `rclone rc vfs/refresh` on `:5572`.
2. **torbox-proxy `:8888`** (`server/torbox-proxy.py`).
   - Verify: `Invoke-RestMethod http://127.0.0.1:8888/health`.
3. **Jellyfin `:8096`** (`supervisor.ps1` or `Start-Jellyfin.ps1`).
   - Verify: `pwsh -File check_status.ps1 -AsJson` exits 0.
   - Post-restart: `pwsh -File check_views_after_restart.ps1 -AsJson` exits 0 (1 = warming, 2 = investigate).
4. **control-panel `:18080`** (`control-panel/control_panel.py` via `install-control-panel.ps1`).
5. **Playback chain:** `potplayer-launcher.ps1` + tracker (launched on demand; no manual start).
6. **Optional edge:** Caddy `:80/:443`, Cloudflared tunnel, FlareSolverr `:8191`.

Quick checks:

```powershell
pwsh -File check_status.ps1
pwsh -File check_user_views.ps1 -AsJson
pwsh -File scripts/healthcheck.ps1
```

## 2. Key rotation

| Secret | Where set | How to rotate |
|--------|-----------|---------------|
| `TORBOX_API_KEY` | `$env:TORBOX_API_KEY` (Machine/User) + registry copy read by supervisor | Set new value in env + registry, restart `torbox-proxy`, `supervisor`, then test `potplayer-launcher` CDN path. Old proxy URLs (`:8888/torbox/...`) stay valid (proxy re-resolves CDN per request); direct CDN URLs expire and must not be cached. |
| `JELLYFIN_USER` / `JELLYFIN_PASSWORD` | `$env:JELLYFIN_USER`, `$env:JELLYFIN_PASSWORD` (never in scripts) | Update env, re-run `check_status.ps1 -AsJson` (expect exit 0). No file edits needed. |
| Jellyfin API key/token | Jellyfin dashboard -> API Keys; `$env:JELLYFIN_API_KEY` for automation | Issue new key, revoke old, update env + `deployments/.env` (untracked), restart panel/proxy. |
| Rclone OAuth (`config/rclone.conf`) | `F:\Jellyfin\config\rclone.conf` (untracked; template at `config/rclone.conf.template`) | `rclone config reconnect <remote>:` then `rclone about <remote>:` to verify, restart mounts. Never commit the real file. |
| Cloudflared / Caddy TLS | `config/cloudflared/config.yml` (from `.template`), Caddy data | Rotate tunnel token/cert via provider dashboard, update untracked config, restart Caddy/tunnel. |

After any rotation: run `test_mcp_server.ps1` (MCP still lists/calls) and
`check_status.ps1` (Jellyfin auth still 0).

## 3. Reboot checklist

- [ ] `TORBOX_API_KEY`, `JELLYFIN_USER`, `JELLYFIN_PASSWORD` present in env (no hardcoded fallbacks).
- [ ] `F:\Jellyfin\config\rclone.conf` exists and `rclone listremotes` shows `torbox:`, `gdrive-media:`.
- [ ] Mounts: `T:\`, `G:\`/`F:\Media\` browsable; if stale, `Invoke-RestMethod :5572/vfs/refresh`.
- [ ] Proxy: `http://127.0.0.1:8888/health` OK; `/mylist` fresh (<15 min).
- [ ] Jellyfin: `check_status.ps1` exit 0; `check_views_after_restart.ps1` exit 0.
- [ ] Panel `:18080` loads; Play-in-PotPlayer button invokes `potplayer://`.
- [ ] PotPlayer: `test_dpl.ps1 -SkipLaunch` passes; live launch plays full-season `.dpl`.
- [ ] Tracker: `show-playback-log.ps1` shows 5s progress; Next-Up advances at 80%.
- [ ] Disk: `F:\` prefetch <20 GB; `cache/`, `transcodes/`, `logs/` not filling OS disk.
- [ ] Backups: `scripts/backup-and-vacuum-db.ps1` scheduled task succeeded.

If views are empty after reboot: wait 60s for scan, re-run
`check_views_after_restart.ps1`; if still 1/2, trigger
`POST /Library/Refresh` via `check_user_views.ps1`, then inspect Jellyfin logs.

## 4. Log locations

| Log | Path | What to look for |
|-----|------|------------------|
| Launcher bridge | `F:\Jellyfin\logs\potplayer-launcher.log` | `RAW:`, `STRM resolve`, `Stale VFS`, `FULL-CACHE`, `Torbox proxy URL`, `RESUME:` |
| Prefetch | `F:\Jellyfin\logs\rclone-prefetch.log` | `copyto` progress/errors (only when `FULLCACHE=1`). |
| Playback watch | `show-playback-log.ps1` console + `logs/` | Episode hint, 5s ticks, 80% played marking. |
| `launcher_debug.log` | `F:\Jellyfin\launcher_debug.log` (root, untracked) | Legacy launcher debug (do not commit). |
| Jellyfin server | Jellyfin `data/log/*.log` + `scripts/export-metrics.ps1` | Scan errors, auth 401, transcode (NVENC) failures. |
| Proxy | stdout of `torbox-proxy.py` + `/metrics` | `mylist` age, token-bucket 429s, `requestdl` failures. |
| Supervisor | Scheduled task history + `supervisor.ps1` output | Service restarts, missing `TORBOX_API_KEY` warnings. |
| MCP server | stderr of `mcp-servers/rclone-storage/server.py` | Validation rejections (`-32602`), rclone `Error (code)`. |

## 5. Common operations

```powershell
# Dry-run cleanups first (no deletes):
pwsh -File clean_and_setup_libraries.ps1 -WhatIf
pwsh -File cleanup_extra_libraries.ps1 -WhatIf -OlderThanDays 7
pwsh -File cleanup_and_check_items.ps1 -WhatIf
pwsh -File delete_stale_views.ps1 -WhatIf -OlderThanDays 30

# JSON health for monitoring (Nagios 0/1/2):
pwsh -File check_status.ps1 -AsJson; $LASTEXITCODE
pwsh -File check_user_views.ps1 -AsJson; $LASTEXITCODE

# MCP smoke:
pwsh -File test_mcp_server.ps1
python -m py_compile mcp-servers/rclone-storage/server.py

# Parser gate (must be 0 errors):
pwsh -NoProfile -Command "$files=@('check_status.ps1','check_user_views.ps1','check_views_after_restart.ps1','clean_and_setup_libraries.ps1','cleanup_and_check_items.ps1','cleanup_extra_libraries.ps1','delete_stale_views.ps1','test_dpl.ps1','test_mcp_server.ps1','annotate_screenshot.ps1','PotPlayerLauncher.ps1'); $e=0; foreach($f in $files){$errs=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$errs); Write-Host \"$f errors=$($errs.Count)\"; $e+=$errs.Count}; exit $e"
```
