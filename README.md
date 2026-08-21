# 🎬 NexusMedia: Enterprise High-Performance Jellyfin & PotPlayer Ecosystem

[![Platform](https://img.shields.io/badge/Platform-Windows%2011%20x64-blue.svg?style=flat-square)]()
[![Hardware Transcode](https://img.shields.io/badge/NVIDIA%20NVENC-RTX%205070%20Blackwell-76B900.svg?style=flat-square&logo=nvidia)]()
[![Storage Pipeline](https://img.shields.io/badge/Storage-Rclone%20VFS%20Full%20Cache-green.svg?style=flat-square&logo=google-drive)]()
[![Media Server](https://img.shields.io/badge/Media%20Server-Jellyfin%20v10.11.11-9370DB.svg?style=flat-square&logo=jellyfin)]()
[![External Player](https://img.shields.io/badge/Player-Daum%20PotPlayer%20x64-orange.svg?style=flat-square)]()
[![License](https://img.shields.io/badge/License-MIT-brightgreen.svg?style=flat-square)]()

---

## 🌟 Executive Overview

**NexusMedia** is an ultra-low latency, cloud-backed media server architecture engineered for the **MHJoy Gamers Hub**. It delivers an instant, Netflix-grade streaming experience by bridging **Jellyfin Server**, **Google Drive / Cloud Remotes** (via Rclone VFS Sparse Caching on an NVMe SSD), and **Daum PotPlayer** with real-time bi-directional playback scrobbling.

```
                  ┌────────────────────────────────────────────────────────┐
                  │                 Cloud Remotes & WebDAV                 │
                  │        (Google Drive, Torbox, RackNerd SFTP)           │
                  └───────────────────────────┬────────────────────────────┘
                                              │
                                   Micro-Chunk Streaming
                                   (16MB -> 2GB Scaling)
                                              ▼
                  ┌────────────────────────────────────────────────────────┐
                  │          Rclone VFS Full Sparse Cache Engine           │
                  │       (Mounted to F:\Media, 80GB NVMe SSD Ceiling)      │
                  └─────────────┬────────────────────────────┬─────────────┘
                                │                            │
                      Direct File I/O                  Local Playback
                                │                            │
                                ▼                            ▼
                  ┌───────────────────────────┐    ┌──────────────────────────┐
                  │   Jellyfin Media Server   │    │  Daum PotPlayer Engine   │
                  │   - RTX 5070 NVENC Trans  │    │  - MadVR / 4K HDR Remux  │
                  │   - Custom Netflix Dark UI│    │  - Dynamic Season (.dpl) │
                  │   - Metadata & Next-Up    │    │  - Custom URI Scheme     │
                  └─────────────▲─────────────┘    └─────────────┬────────────┘
                                │                                │
                                └────── Active Scrobbler ────────┘
                                    (potplayer-sync-tracker)
```

---

## ⚡ Key Highlights & Architecture Pillars

1. **Rclone VFS Full Sparse Cache Mount (`F:\Media`)**:
   - High-throughput streaming from Google Drive with a sparse cache ceiling on NVMe SSD `F:`.
   - On-demand chunk streaming (`16M` initial chunk expanding up to `2G`) with `128M` read-ahead.
   - Intelligent 30-second LRU cleaner loop evicting idle media older than 4 hours — ensuring zero disk overflow while keeping library metadata cached for instant browsing.

2. **Hardware-Accelerated Zero-Copy Transcoding**:
   - Powered by **NVIDIA GeForce RTX 5070 (Blackwell Architecture)** with dual 9th-Gen NVENC encoders and 8th-Gen NVDEC.
   - Full hardware decode/encode pipeline for **AV1 10-bit**, **HEVC (H.265) 10-bit**, **H.264**, and **VP9**.
   - GPU-resident CUDA tone mapping (`BT.2390`) converting HDR10 and Dolby Vision to SDR with zero CPU bottleneck.

3. **Custom `potplayer://` URI Protocol Handler**:
   - Integrated into Windows registry (`HKEY_CLASSES_ROOT\potplayer`) executing `potplayer-launcher.ps1`.
   - Generates dynamic, UTF-16 Unicode encoded `.dpl` season playlists containing all sibling files in chronological order for seamless binge-watching.

4. **Real-Time Bi-Directional Playback Scrobbler**:
   - Background daemon (`potplayer-sync-tracker.ps1`) reporting active ticks (`POST /Sessions/Playing/Progress`) every 5 seconds to Jellyfin REST API.
   - Shell COM metadata extraction for true video runtime.
   - Automatically marks episodes as played upon reaching the 80% duration threshold (`POST /Users/{userId}/PlayedItems/{itemId}`) and dynamically advances the **"Next Up"** row.

5. **Netflix Dark Cinematic UI Theme**:
   - Custom CSS injected into Jellyfin Web featuring Netflix Red accents (`#E50914`), hero gradient banners, and responsive card zoom animations.

6. **Model Context Protocol (MCP) Server**:
   - Custom zero-dependency Python MCP server (`rclone-storage-mcp`) enabling LLM agents to execute server-side cloud moves and de-obfuscate Telegram leech bot files in milliseconds without local downloads.

---

## 📂 Repository Directory Layout

```
E:\MediaServer\
├── config\                     # Configuration templates & system specs
│   ├── rclone.conf.template    # Sanitized Rclone remote profile
│   └── system-specs.json       # Host hardware profile
├── docs\                       # In-depth architectural & technical specs
│   ├── GPU_TRANSCODING_NVENC.md# RTX 5070 NVENC/NVDEC setup & CUDA tone-mapping
│   ├── MCP_RCLONE_AUTOMATION.md# MCP stdio JSON-RPC server architecture
│   ├── NETFLIX_THEME_CUSTOMIZATION.md # Netflix dark web theme CSS specification
│   ├── PLAYBACK_SCROBBLER_SYNC.md # Real-time session tracker & Jellyfin scrobbler
│   ├── POTPLAYER_INTEGRATION.md# potplayer:// URI protocol & .dpl playlists
│   ├── RCLONE_VFS_ARCHITECTURE.md # VFS sparse caching & LRU eviction breakdown
│   └── TELEGRAM_MEDIA_PIPELINE.md # Server-side de-obfuscation & renaming pipeline
├── mcp-servers\                # Custom Model Context Protocol implementations
│   └── rclone-storage\
│       └── server.py           # Zero-dependency Rclone MCP JSON-RPC bridge
├── playbooks\                  # Operational runbooks & recovery guides
│   └── DISASTER_RECOVERY_AND_MAINTENANCE.md # Token refresh & service diagnostics
├── scripts\                    # Core deployment, registration & healthcheck scripts
│   ├── healthcheck.ps1         # Full stack automated diagnostic suite
│   ├── install-potplayer-tracker.ps1 # Scrobbler daemon configuration
│   ├── install-rclone-service.ps1   # NSSM Windows service installer
│   ├── potplayer-launcher.ps1       # Protocol dispatcher & .dpl generator
│   ├── potplayer-sync-tracker.ps1   # Background session scrobbler engine
│   └── register-potplayer-protocol.ps1 # HKCR Windows registry handler
└── web\                        # Jellyfin Web modifications & assets
    ├── netflix-theme.css       # Complete Netflix Dark theme stylesheet
    └── potplayer-integration.js# Client-side DOM bridge & button injector
```

---

## 🚀 Quick Start Deployment Guide

### 1. Prerequisites
- **Operating System:** Windows 11 x64
- **Runtime:** PowerShell 7+ or Windows PowerShell 5.1, Python 3.10+
- **Prerequisites:** [WinFsp](https://winfsp.dev/), [Rclone](https://rclone.org/), [Daum PotPlayer x64](https://potplayer.daum.net/), [NSSM](https://nssm.cc/)
- **GPU:** NVIDIA RTX series GPU with latest Game Ready or Studio Drivers

### 2. Configure Rclone Mount Service
Copy the template and fill in your remote credentials:
```powershell
Copy-Item "config\rclone.conf.template" "config\rclone.conf"
# Edit config\rclone.conf with your OAuth tokens
.\scripts\install-rclone-service.ps1
```

### 3. Register PotPlayer URI Handler
Register the custom `potplayer://` protocol in the Windows registry:
```powershell
.\scripts\register-potplayer-protocol.ps1
```

### 4. Deploy Frontend Enhancements
Inject the client scripts and styling int
