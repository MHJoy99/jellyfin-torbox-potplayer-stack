# Jellyfin + TorBox + PotPlayer Stack for Windows — Direct-Stream 4K Media Server with Resume Sync & Web Control Panel

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D6.svg)](https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack)
[![PowerShell: 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg)](https://learn.microsoft.com/powershell/)
[![Python: 3.11](https://img.shields.io/badge/Python-3.11-3776AB.svg)](https://www.python.org/)
[![Jellyfin: 10.x](https://img.shields.io/badge/Jellyfin-10.x-00A4DC.svg)](https://jellyfin.org/)

> Turn Jellyfin on Windows into a TorBox-powered 4K direct-stream powerhouse: cloud torrents mount as local drives, click Play in Jellyfin, and PotPlayer streams the full season instantly — with resume sync, no transcoding, and a one-click web control panel.

## Table of Contents

- [⚡ 30-Second Quickstart](#-30-second-quickstart)
- [✨ Features](#-features)
- [🏗️ Architecture](#️-architecture)
- [🔌 Ports](#-ports)
- [🖥️ Requirements](#️-requirements)
- [⚙️ Configuration](#️-configuration)
- [▶️ Usage — Play an Episode End-to-End](#️-usage--play-an-episode-end-to-end)
- [📸 Screenshots](#-screenshots)
- [🆚 Comparison — Why Not Plain Jellyfin, Plex, or Infuse?](#-comparison--why-not-plain-jellyfin-plex-or-infuse)
- [🛠️ Troubleshooting](#️-troubleshooting)
- [❓ FAQ](#-faq)
- [🗺️ Roadmap](#️-roadmap)
- [🤝 Contributing](#-contributing)
- [⭐ Support — Star History](#-support--star-history)
- [📄 License](#-license)
- [🙏 Acknowledgments](#-acknowledgments)

## ⚡ 30-Second Quickstart

Get from zero to playing in under a minute (after prerequisites are installed):

```powershell
git clone https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack.git
cd jellyfin-torbox-potplayer-stack
$env:TORBOX_API_KEY = "paste-your-torbox-key-here"  # session-only, never committed
pwsh -File install-all.ps1
```

Then open the panel:

```text
http://127.0.0.1:18080
```

Click **Start all**, wait for all services green, open Jellyfin at `http://127.0.0.1:8096`, press Play → PotPlayer opens the full season. Done.

> 🔐 Secrets live only in environment variables (`$env:TORBOX_API_KEY`). This repo is public MIT — never paste keys into files, issues, or commits.

## ✨ Features

| Feature | What It Does | Service / Script |
|---|---|---|
| TorBox Proxy | Caches TorBox `mylist`, mints fresh CDN 302s per request, token-bucket rate limiting, `/metrics` for Prometheus | `server/torbox-proxy.py` (`:8888`) |
| Resume Sync | POSTs playback progress to Jellyfin every 5s, marks Played at 80%, drives Next-Up | `potplayer-sync-tracker.ps1` |
| Watch Console | Live tail of launcher + playback ticks, episode hints, and 80% played events | `show-playback-log.ps1` |
| Supervisor | Ordered start chain + 15s watchdog with backoff, single-instance mutex, PID files | `supervisor.ps1`, `Start-Jellyfin.ps1`, `Stop-Jellyfin.ps1` |
| Control Panel | Start/stop/restart mounts, proxy, bridge, Jellyfin; status, metrics, Play-in-PotPlayer buttons; loopback-only | `control-panel/control_panel.py` (`:18080`) |
| GDrive Sync | Writes `.strm` + sidecars from Google Drive into Jellyfin, triggers `POST /Library/Refresh` | `gdrive-library-sync.ps1` |

Extras: `potplayer://` protocol handler with full-season `.dpl` playlists and `/seek=` resume, stale-VFS auto-refresh, `FULLCACHE=1` full-file prefetch bar, Nagios-style `check_*.ps1` health probes (`-AsJson`), and an rclone MCP bridge under `mcp-servers/`.

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

> Drop zone: save PNGs under `docs/screenshots/` (relative links below). Suggested size 1600x900, hide personal library names before committing.

![Control panel — services green, Start all, metrics](docs/screenshots/01-control-panel.png)
_Control panel at `http://127.0.0.1:18080` — mounts, proxy, bridge, and Jellyfin all green._

![Jellyfin Series page with Next-Up and Play-in-PotPlayer](docs/screenshots/02-jellyfin-nextup.png)
_Jellyfin Series page — TMDB metadata, Next-Up, and the Play-in-PotPlayer button._

![PotPlayer playing 4K direct-stream with full-cache seek bar](docs/screenshots/03-potplayer-direct-stream.png)
_PotPlayer x64 — full-season `.dpl`, instant seek, solid full-cache bar via `:8888` proxy._

![Watch console showing 5s progress ticks and 80 percent played marking](docs/screenshots/04-watch-console.png)
_Watch console (`show-playback-log.ps1`) — 5s progress ticks and 80% Played marking._

## 🆚 Comparison — Why Not Plain Jellyfin, Plex, or Infuse?

| Capability | This Stack | Plain Jellyfin | Plex | Infuse |
|---|---|---|---|---|
| TorBox cloud torrents as local drives | ✅ rclone VFS `T:\` + proxy CDN refresh | ❌ manual downloads | ❌ no native TorBox | ⚠️ via WebDAV only, no 302 refresh |
| 4K REMUX direct-play on Windows | ✅ PotPlayer + full-season `.dpl`, no transcode | ⚠️ browser/ExoPlayer limits, often transcodes | ⚠️ Plex transcodes without Plex Pass / tuned client | ✅ direct-play, but Apple-only |
| Resume + Next-Up stay in sync externally | ✅ 5s tracker, 80% Played, Next-Up advances | ❌ external players break resume | ❌ external players break resume | ⚠️ iCloud sync only |
| One-click local ops panel | ✅ `:18080` Start/Stop/Restart + metrics + playback | ❌ dashboard only, no process control | ❌ server settings only | ❌ no server panel |
| Self-hosted, no account lock-in, MIT | ✅ Windows + Jellyfin + rclone, all local | ✅ fully self-hosted | ❌ account + paywalled features | ❌ paid Pro, Apple ecosystem |
| Best for | Windows cinephiles wanting Jellyfin library + PotPlayer playback + TorBox cloud | General self-hosters OK with web playback | Remote sharing with Plex clients | Apple TV / iOS direct-play |

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
