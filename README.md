# Jellyfin + TorBox + PotPlayer Stack for Windows — Direct-Stream 4K Media Server with Resume Sync & Web Control Panel

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D6.svg)](https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack)
[![PowerShell: 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg)](https://learn.microsoft.com/powershell/)
[![Python: 3.11](https://img.shields.io/badge/Python-3.11-3776AB.svg)](https://www.python.org/)
[![Jellyfin: 10.x](https://img.shields.io/badge/Jellyfin-10.x-00A4DC.svg)](https://jellyfin.org/)

> Jellyfin library + TorBox cloud + PotPlayer playback — on Windows, with no transcoding.
>
> Cloud torrents mount as local drives (`T:\`), Jellyfin keeps metadata, resume, and Next-Up, and PotPlayer direct-streams full-season 4K through a local proxy. A loopback-only panel owns start/stop, health, and Play-in-PotPlayer.
>
> **Scope:** Windows 10/11 x64 only · Jellyfin 10.x + TorBox + PotPlayer x64 + rclone VFS · PowerShell 7+ + Python 3.11 · Loopback-only by default.
> **Not in scope:** Linux / macOS / Docker, Plex / Emby, remote hosting. Google Drive sync is optional secondary; TorBox is the primary cloud. Caddy / tunnel edge is roadmap, not current.

## Table of Contents

- [⚡ 30-Second Quickstart](#-30-second-quickstart)
- [✨ Features](#-features)
- [🏗️ Architecture](#️-architecture)
- [🔌 Ports](#-ports)
- [🖥️ Requirements](#️-requirements)
- [⚙️ Configuration](#️-configuration)
- [▶️ Usage — Play an Episode End-to-End](#️-usage--play-an-episode-end-to-end)
- [📸 Screenshots](#-screenshots)
- [🆚 Comparison — Why Not Plain Jellyfin, Plex, or Plex+Debrid?](#-comparison--why-not-plain-jellyfin-plex-or-plexdebrid)
- [🚀 Performance Notes & Tuning](#-performance-notes--tuning)
- [🛠️ Troubleshooting](#️-troubleshooting)
- [❓ FAQ](#-faq)
- [🗺️ Roadmap](#️-roadmap)
- [🤝 Contributing](#-contributing)
- [⭐ Support — Star History](#-support--star-history)
- [📄 License](#-license)
- [🙏 Acknowledgments](#-acknowledgments)

## ⚡ 30-Second Quickstart

For a fresh PC with prerequisites already installed (PotPlayer x64, rclone + WinFsp, Python 3.11, Jellyfin 10.x files, TorBox account). Pick one path:

**A — One-click (recommended):**

```powershell
git clone https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack.git
cd jellyfin-torbox-potplayer-stack
pwsh -File install.ps1 -WhatIf
pwsh -File install.ps1
```

`install.ps1` prompts for `TORBOX_API_KEY` (masked), validates it once, installs to `F:\Jellyfin`, registers `potplayer://`, creates the supervisor task, starts the stack, and health-checks `:8888` / `:18099` / `:18080` / `:8096`. Options (`-SkipTasks`, `-Portable`, `-Uninstall`) and receipts are in `docs/install.md`.

**B — Guided:** `pwsh -File setup-wizard.ps1` for step-by-step key, library, Jellyfin, PotPlayer, rclone, and port checks with a dry-run before anything changes.

**C — Manual (advanced):** `pwsh -File install-all.ps1` runs the six installers in dependency order, then `pwsh -File supervisor.ps1 -Mode Start` does one ordered start (mounts → proxy → bridge → Jellyfin → panel). Full order and verify steps are in `docs/install.md` and `docs/quickstart.md`.

Then open the panel:

```text
http://127.0.0.1:18080
```

Click **Start all**, wait for green, open Jellyfin at `http://127.0.0.1:8096`, use Play-in-PotPlayer → the full-season playlist opens at your resume point. Done.

> 🔐 Secrets live only in environment variables (`$env:TORBOX_API_KEY`, placeholder value `<your-torbox-key>`). This repo is public MIT — never paste keys into files, issues, or commits.

## ✨ Features

| Feature | What it does for you | Service / Script |
|---|---|---|
| TorBox proxy | Stable local URLs that never expire; refreshes short-lived CDN links per request and caches `mylist` to stay fast | `server/torbox-proxy.py` (`:8888`) |
| One-click play | Jellyfin Play hands a `potplayer://` link to Windows; the launcher picks the right file, refreshes stale cache, and opens the full season at your resume point | `potplayer-launcher.ps1` + bridge `:18099` |
| Resume sync | Posts progress every 5s, marks Played at 80% so Next-Up keeps working on every client | `potplayer-sync-tracker.ps1` |
| Watch console | Live tail of launcher + playback ticks, episode hints, and 80% Played events | `show-playback-log.ps1` |
| Control panel | Loopback-only Start/Stop/Restart, status, metrics, and Play buttons — no console juggling | `control-panel/control_panel.py` (`:18080`) |
| Supervisor | Ordered start (mounts → proxy → bridge → Jellyfin → panel) plus watchdog, mutex, and PID files | `supervisor.ps1` (`-Mode Run` / `Start` / `Stop` / `Status`) |

Optional / secondary: Google Drive `.strm` sync (`gdrive-library-sync.ps1`), `FULLCACHE=1` full-file prefetch for a solid seek bar, full-season `.dpl` with `/seek=` resume, Nagios-style `check_*.ps1` probes (`-AsJson`), and an rclone MCP bridge under `mcp-servers/`.

## 🏗️ Architecture

Single required flow — every play follows this chain:

```text
TorBox cloud
  |
  v
rclone VFS mount (T:\ TorBox, G:\ Drive, RC :5572/:5573)
  |
  v (.strm + sidecars)
Jellyfin :8096 (TMDB metadata, Views, resume, Next-Up, stream API)
  |
  v (potplayer:// itemId|userId|token|serverUrl)
PotPlayer Bridge :18099 (resolves request, health gate)
  |
  v
Launcher (potplayer-launcher.ps1: GUID resolve, stale-VFS refresh, CDN fallback)
  |
  v (never-expires proxy URL)
Proxy :8888 (/torbox/... -> 302 fresh CDN, /mylist cache, /metrics)
  |
  v (direct HTTP / full-season .dpl)
PotPlayer x64 (instant 4K direct-stream, sync-tracker POSTs progress back to Jellyfin)
```

Detailed service map, data-flow steps, and key paths live in [ARCHITECTURE.md](ARCHITECTURE.md). Day-2 operations (restart order, rotation, reboot checklist) live in [RUNBOOK.md](RUNBOOK.md). Panel behavior lives in [CONTROL_PANEL.md](CONTROL_PANEL.md).

## 🔌 Ports

All services bind loopback-only by default. Expose remotely only via Caddy / Cloudflared tunnel.

| Port | Service | URL / Notes |
|---|---|---|
| `8888` | TorBox Proxy (`server/torbox-proxy.py`) | `http://127.0.0.1:8888/health`, `/torbox/{torrent}/{file}/{name}` 302 to fresh CDN, `/mylist`, `/metrics` |
| `18099` | PotPlayer Bridge | `http://127.0.0.1:18099/health`, `/status`; health gate before every launch |
| `18080` | Control Panel (`control-panel/control_panel.py`) | `http://127.0.0.1:18080/` — status, metrics, playback buttons |
| `8096` | Jellyfin HTTP | `http://127.0.0.1:8096/` — web UI, `/System/Info/Public`, `/Library/*`, `/Videos/{id}/stream` |
| `5572` | rclone RC — TorBox mount | `http://127.0.0.1:5572/` — `vfs/refresh`, `vfs/cache/fetch`, `core/stats` |
| `5573` | rclone RC — GDrive mount | `http://127.0.0.1:5573/` — same RC verbs for `G:\` / `F:\Media` |

## 🖥️ Requirements

- **Windows 10/11 x64** with PowerShell 7+ (`pwsh`) — primary and only supported OS.
- **Jellyfin Server 10.x** (local `server/jellyfin.exe` or existing install on `:8096`).
- **PotPlayer x64** installed + `potplayer://` protocol registered via `register-potplayer-protocol.ps1`.
- **rclone** with TorBox + Google Drive remotes configured (`rclone listremotes` shows `torbox:`, `gdrive-media:`).
- **TorBox API key** (Machine or User scope) exported as `$env:TORBOX_API_KEY` — never hardcode or commit it.
- **Python 3.11** for proxy / bridge / panel (`pythonw`), TMDB metadata via Jellyfin plugins.

Disk: ~20 GB headroom for `cache/prefetch` LRU + Jellyfin `data/`, `transcodes/`, `logs/`.

## ⚙️ Configuration

All secrets come from the environment. No tokens in files, no `.env` committed.

| Variable | Required | Default | Used By |
|---|---|---|---|
| `TORBOX_API_KEY` | Yes | _(empty — refuses to start)_ | proxy, launcher, supervisor (re-read live from Machine/User registry) |
| `JELLYFIN_URL` | No | `http://localhost:8096` | all `check_*.ps1`, library sync, launcher token exchange |
| `JELLYFIN_USER` | Yes for health checks | _(empty)_ | `check_status.ps1`, `check_user_views.ps1` (no hardcoded fallback) |
| `JELLYFIN_PASSWORD` | Yes for health checks | _(empty)_ | same as above, never logged |
| `JELLYFIN_API_KEY` | No (automation) | _(empty)_ | `gdrive-library-sync.ps1` for `POST /Library/Refresh` |
| `FULLCACHE` | No | `0` | `potplayer-launcher.ps1` — set to `1` to prefetch the full file for a solid seek bar |
| `RCLONE_EXE` | No | `rclone` on `PATH` | `mcp-servers/rclone-storage/server.py` MCP bridge |
| `RCLONE_CONFIG` | No | `F:\Jellyfin\config\rclone.conf` | same MCP bridge (real file is untracked; commit only the `.template`) |

```powershell
# Persistent (survives reboot, read live by supervisor):
[Environment]::SetEnvironmentVariable("TORBOX_API_KEY", "<your-key>", "User")
$env:TORBOX_API_KEY = [Environment]::GetEnvironmentVariable("TORBOX_API_KEY", "User")

# Verify without leaking the key:
pwsh -File check_status.ps1 -AsJson; $LASTEXITCODE  # expect 0
Invoke-RestMethod http://127.0.0.1:8888/health
```

See [RUNBOOK.md](RUNBOOK.md) for rotation (env + registry → restart proxy/supervisor → test CDN path).

## ▶️ Usage — Play an Episode End-to-End

1. **Start everything:** open `http://127.0.0.1:18080`, click **Start all**. Mounts come first (`T:\`, `F:\Media`), then proxy `:8888`, bridge `:18099`, Jellyfin `:8096`, panel itself.
2. **Pick a show in Jellyfin:** open `http://127.0.0.1:8096`, browse Libraries → Series → your show. Metadata, posters, and Next-Up come from TMDB + `.strm` scan.
3. **Press Play-in-PotPlayer:** the web UI / panel builds a `potplayer://<base64|target|itemId|userId|token|serverUrl>` link and hands it to Windows.
4. **Launcher resolves:** `PotPlayerLauncher.ps1` (thin shim) → `potplayer-launcher.ps1` resolves the Jellyfin item GUID to a `.strm`, maps it to `T:\`, refreshes stale VFS via RC `:5572` if needed, and picks TorBox CDN or `:8888` proxy fallback.
5. **PotPlayer opens:** a full-season UTF-16 `.dpl` playlist loads with the clicked episode queued and `/seek=` set to your Jellyfin resume position.
6. **Watch the bar fill:** direct HTTP from `:8888/torbox/...` 302s to a fresh CDN URL, so 4K REMUX direct-streams with an instant full-cache seek bar (set `FULLCACHE=1` for full-file prefetch).
7. **Resume stays in sync:** `potplayer-sync-tracker.ps1` POSTs `/Sessions/Playing/Progress` every 5s and marks Played at 80%. Pause Jellyfin Web, resume in PotPlayer — Next-Up advances. Verify with `pwsh -File show-playback-log.ps1`.

## 📸 Screenshots

> Status: no PNG screenshots are committed yet — `assets/screenshots/` contains only `PLACEHOLDER.md`. The table below is a capture checklist, not embedded images, so there are no broken image links. The only committed visual is the vector banner `assets/social-preview.svg` (1200x630).

| Pending file (`assets/screenshots/`) | Surface | Must show (demo data only) | Alt text for future embed |
|---|---|---|---|
| `01-control-panel.png` | Control panel at `http://127.0.0.1:18080` | Full window, all services green, Start all and metrics visible | `Control panel overview showing all media-stack services running` |
| `02-jellyfin-nextup.png` | Jellyfin at `http://127.0.0.1:8096`, Series view | Demo posters, Next-Up row, and the Play-in-PotPlayer entry point | `Jellyfin Series page with demo posters, Next-Up row, and Play-in-PotPlayer entry` |
| `03-potplayer-direct-stream.png` | PotPlayer x64 via local `:8888` proxy | Direct-stream playback with the full-season playlist queue visible | `PotPlayer playing a direct stream with the full-season playlist visible` |
| `04-watch-console.png` | Watch console (`show-playback-log.ps1`) | Progress ticks and 80% Played marking with demo titles | `Watch console showing playback progress ticks and Played marking` |

Capture rules (full checklist in `assets/screenshots/PLACEHOLDER.md`): PNG ≤ 1600 px wide, maximized window, cropped chrome, demo library only, blur tokens, hostnames, and private titles before saving. Name files exactly as above so future embeds stay stable.

## 🆚 Comparison — Why Not Plain Jellyfin, Plex, or Plex+Debrid?

An honest comparison across media setups on Windows:

| Capability | This Stack (Jellyfin + TorBox + PotPlayer) | Plain Jellyfin on Windows | Plex (Standard / Plex Pass) | Plex + Debrid / Zurg / Infuse |
|---|---|---|---|---|
| Primary cloud storage | TorBox cloud torrents/Usenet mounted to `T:\` via rclone VFS with auto-refresh | Local storage or plain mounts; manual torrent management | Local storage; cloud requires unsupported third-party tools | Real-Debrid / TorBox via Zurg/WebDAV/rclone |
| 4K REMUX direct-play on Windows | ✅ PotPlayer x64 + full-season `.dpl`, hardware decoding, no transcoding overhead | ⚠️ Web/ExoPlayer client codec limits often trigger CPU-heavy server transcoding | ⚠️ Direct-play requires tuned desktop app; Web client transcodes HDR/high-bitrate | ✅ Direct-play on supported players (Infuse on Apple, desktop player on PC) |
| Resume & Next-Up sync | ✅ 5s tracker posts to Jellyfin `/Sessions/Playing/Progress`, marks Played at 80% | ✅ Native when using built-in web/app clients; ❌ broken with external players | ✅ Native in Plex clients; ❌ broken with external players | ⚠️ Dependent on sync scrobbler / webhook bridges; Infuse uses iCloud |
| Stale link & CDN expiry resilience | ✅ Local proxy (`:8888`) mints fresh CDN 302s on demand; never fails on expired links | N/A | N/A | ⚠️ Stale debrid links in `.strm` require whole-library rescans or fail playback |
| Control & operations panel | ✅ Dedicated loopback panel (`:18080`) with Start/Stop/Restart, metrics, and health gates | ❌ Server dashboard only (no service watchdog or mount lifecycle control) | ❌ Server settings only | ❌ Scattered scripts / CLI-only management |
| Supervision & watchdog | ✅ Supervisor mutex, ordered start chain, 15s watchdog, backoff, and PID tracking | ❌ Windows Service / manual process only | ❌ Manual tray / service launcher | ❌ Requires separate NSSM / Docker supervision |
| Portability & license | ✅ MIT licensed, loopback-only, env-based secrets, zero telemetry lock-in | ✅ Open-source (GPL) | ❌ Proprietary, requires Plex account & telemetry, paid Plex Pass for HW transcode | ⚠️ Mix of paid services, proprietary players (Infuse), and community scripts |
| Ideal user | Windows cinephiles wanting an open Jellyfin library + instant 4K PotPlayer streaming from TorBox | Self-hosters with local storage playing via official Jellyfin web/mobile apps | Non-technical households wanting polished turnkey apps on TVs and mobile | Multi-device users wanting cloud debrid with Apple TV / multi-client setups |

## 🚀 Performance Notes & Tuning

The stack is pre-tuned for high-bitrate 4K streaming over residential gigabit connections. Key tuning knobs and defaults:

### 1. rclone VFS Mount (`mount-torbox.ps1`)

- **Cache mode:** `--vfs-cache-mode full` — allows sparse caching on disk so seeking does not stall the entire stream.
- **Cache sizing:** `--vfs-cache-max-size 25G` with `--vfs-cache-max-age 12h` and `--vfs-cache-min-free-space 30G`. Keep the cache directory on an NVMe SSD for instant chunk access.
- **Chunk reads:** `--vfs-read-chunk-size 32M` (starts small for fast TTFB) doubling up to `--vfs-read-chunk-size-limit 256M` with `--vfs-read-ahead 128M` for smooth scrubbing.
- **Directory caching:** `--dir-cache-time 15m` with `--attr-timeout 5m` keeps Windows Explorer and Jellyfin library scans responsive. Stale paths are refreshed on-demand via rclone RC (`:5572`).

### 2. Local Proxy (`server/torbox-proxy.py` on `:8888`)

- **Link resolution:** Proxy mints fresh CDN download links via 302 redirects with a token-bucket rate limiter, avoiding TorBox API rate limits.
- **Shared cache:** Caches `mylist` for 10 minutes with singleflight coalescing to eliminate redundant API roundtrips during multi-episode season loads.
- **HTTP protocol:** Uses HTTP/1.0 progressive streaming by default to prevent client connection hangs when upstream CDN response lengths vary.

### 3. Seek Bar & Prefetch

- **Instant seek:** PotPlayer receives progressive HTTP streams directly from the proxy, allowing instant seeking across the timeline.
- **Full prefetch (optional):** Set `$env:FULLCACHE = "1"` before launch to trigger background full-file caching for a solid seek bar on ultra-high-bitrate REMUX files.

## 🛠️ Troubleshooting

| Symptom | Likely Cause | One-Line Fix |
|---|---|---|
| `T:\` empty / `Test-Path T:\` false | Stale rclone VFS mount or expired dir-cache | Restart mount, then `Invoke-RestMethod http://127.0.0.1:5572/vfs/refresh -Method Post` |
| Jellyfin plays 93-byte file / `.strm` text | Scan ran while VFS was down; stub `.strm` indexed | Remount `T:\`, delete stubs, re-run `gdrive-library-sync.ps1`, then `POST /Library/Refresh` |
| Proxy `/mylist` 422 / `requestdl` fails | `TORBOX_API_KEY` missing or sent as header not `?token=` | Set `$env:TORBOX_API_KEY` (User/Machine), restart proxy + supervisor, retry `/health` |
| Playback hangs on open, no data | Proxy forced to HTTP/1.1 without `Content-Length` | Keep proxy on HTTP/1.0 (default); do not put a buffering reverse proxy in front of `:8888` |
| Libraries / Views empty after reboot | Jellyfin started before mounts; scan raced VFS | Start order mounts → proxy → Jellyfin; run `pwsh -File check_views_after_restart.ps1 -AsJson` and rescan |

Full restart order, log paths, and Nagios probes: [RUNBOOK.md](RUNBOOK.md).

## ❓ FAQ

**What exactly does this stack do that plain Jellyfin cannot do on Windows?**

It mounts TorBox and Google Drive as local drives with rclone, serves fresh CDN URLs through a local proxy on port 8888, and launches PotPlayer with a full-season playlist at your exact resume point. Jellyfin keeps library, metadata, and watched state, while PotPlayer handles flawless 4K direct-stream playback without transcoding or browser codec limits.

**Where do I store my TorBox API key so it never leaks to GitHub?**

Store it only as a Windows environment variable named TORBOX_API_KEY at User or Machine scope, then restart the proxy and supervisor so child processes inherit it. Never paste the key into scripts, configs, issues, or commits. The proxy refuses to start when the variable is empty, and rotation means updating env plus registry and restarting services.

**Why does PotPlayer start instantly while Jellyfin Web sometimes buffers on the same file?**

Jellyfin Web often remuxes or transcodes high-bitrate 4K REMUX files due to browser codec and subtitle limits, which costs CPU and adds buffering. PotPlayer direct-streams the original file over HTTP from the local TorBox proxy, so it seeks instantly with a full-cache bar and uses negligible server CPU while preserving original video, audio, and subtitle tracks.

**How does resume and watched status stay in sync between PotPlayer and Jellyfin?**

A lightweight tracker posts playback position to Jellyfin Sessions Playing Progress endpoint every five seconds while PotPlayer runs. When you pass eighty percent, it marks the episode Played, so Next-Up advances and other clients resume correctly. Pausing, closing, or switching episodes updates Jellyfin immediately, which you can verify live in the watch console window.

**What should I do when T drive looks stale or libraries are empty after reboot?**

Always start mounts before Jellyfin, because a scan that races a downed VFS indexes stub files and empty views. Verify drive paths exist, refresh the rclone RC cache on ports 5572 to 5573, confirm proxy health on port 8888, then trigger a Jellyfin library refresh. The included status scripts return Nagios codes and JSON for fast automated checks.

## 🗺️ Roadmap

- One-click `install-all.ps1` wizard with preflight, elevation-once, and version stamps.
- Panel UX refresh: dark mode, per-service logs, one-click Play + Next-Up buttons.
- Prometheus `/metrics` dashboards + Grafana template for proxy, mounts, and tracker.
- Smarter prefetch: LRU-aware full-cache, bandwidth caps, and per-series pinning.
- Docker / Caddy / Cloudflared edge profile for secure remote Jellyfin access.
- Automated `.dpl` + MCP test harness with CI gating on every PR.

Have an idea? [Open a feature request](https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack/issues) — small, focused PRs welcome.

## 🤝 Contributing

PRs and issues welcome — please [open an issue](https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack/issues) first for big changes, keep secrets out of diffs, and run the parser gate + health probes before pushing.

## ⭐ Support — Star History

If this stack saved you a transcode, gave you instant 4K seeks, or tamed your TorBox library — **⭐ star the repo**, **👁️ watch** for releases, and **🍴 fork** it for your own Windows media server. Stars drive roadmap priority (panel UX, metrics, Docker edge) and help other Jellyfin + TorBox + PotPlayer users find a no-transcode Windows setup that just plays.

## 📄 License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 MHJoy99. Free to use, modify, and distribute; keep the copyright notice in copies. No warranty.

## 🙏 Acknowledgments

- [Jellyfin](https://jellyfin.org/) — open-source media server, metadata, resume, and streaming APIs that power the library.
- [TorBox](https://torbox.app/) — cloud torrent / Usenet debrid with fast CDN links that make instant 4K possible.
- [rclone](https://rclone.org/) — VFS mounts, dir-cache, and RC (`:5572`/`:5573`) that turn cloud remotes into `T:\` / `G:\`.
- [PotPlayer](https://potplayer.daum.net/) — reference Windows player for direct-stream 4K, full-season `.dpl`, and `/seek=` resume.

---

*Jellyfin + TorBox + PotPlayer on Windows: rclone VFS direct-stream 4K media server with resume sync, watch console, supervisor watchdog, and web control panel — no transcoding, no lock-in, just press Play.*
