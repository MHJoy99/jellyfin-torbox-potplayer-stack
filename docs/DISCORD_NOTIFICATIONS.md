# Discord Webhook Notification System for MediaServer

Comprehensive documentation for the production-grade Discord Webhook notification engine (`E:\MediaServer\tools\discord_notifier.py`).

---

## 1. Overview & Architecture

The Discord Notifier is a standalone, resilient event dispatch engine tailored for the MediaServer ecosystem. It converts infrastructure state transitions, media pipeline ingestion, storage cache capacity, and database maintenance milestones into aesthetically styled, color-coded Discord Embeds.

```
                    ┌──────────────────────────────────────────────┐
                    │            MediaServer Ecosystem             │
                    └───────┬──────────────┬─────────────┬─────────┘
                            │              │             │
              ┌─────────────▼────┐  ┌──────▼──────┐ ┌────▼──────────────┐
              │   Media Ingest   │  │ Rclone VFS  │ │   Nightly Backup   │
              │ (Telegram/Rclone)│  │ & Storage   │ │ & SQLite VACUUM   │
              └─────────────┬────┘  └──────┬──────┘ └────┬───────────────┘
                            │              │             │
                            └──────────────┼─────────────┘
                                           │
                        ┌──────────────────▼──────────────────┐
                        │   tools/discord_notifier.py         │
                        │   - Rate Limit Backoff (HTTP 429)   │
                        │   - TMDB Poster Art & Overview Sync │
                        │   - Local ffprobe Stream Extraction │
                        │   - Live Health & Disk Inspection   │
                        └──────────────────┬──────────────────┘
                                           │
                                ┌──────────▼──────────┐
                                │   Discord Webhook   │
                                │   (Channel Embeds)  │
                                └─────────────────────┘
```

---

## 2. Core Notification Channels & Visual Styling

| Notification Event | Theme Color | Hex Code | Visual Triggers |
| :--- | :--- | :--- | :--- |
| **Movie Ingest** | Amethyst Purple | `#9B59B6` | New movie moved/indexed, TMDB poster, resolution, audio/video codecs |
| **TV Episode Ingest** | Turquoise Teal | `#1ABC9C` | New episode/season added with episode thumbnail, season/ep tags |
| **Rclone VFS Cache** | Cyan / Orange / Burgundy | `#00BCD4` / `#F39C12` / `#962D3E` | Mount status, cache capacity %, free disk threshold alerts (<15 GB) |
| **Jellyfin Service** | Jellyfin Purple / Crimson | `#AA5CC8` / `#E74C3C` | Service startup, restart notices, heartbeat, crash/hang watchdog |
| **SQLite Backup & VACUUM** | Emerald Green / Red | `#2ECC71` / `#E74C3C` | Zero-downtime VACUUM INTO, WAL checkpoint, compression savings, cloud sync |

---

## 3. Environment Variables & Setup

Configure the following environment variables in your system environment or `deployments\.env`:

```env
# Discord Webhook Target URL (Required for live sending)
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz

# TMDB API Key v3 (Optional: automatically queries poster art, ratings, and plot summaries)
TMDB_API_KEY=your_tmdb_v3_api_key_here

# Jellyfin Endpoint (Default: http://localhost:8096)
JELLYFIN_URL=http://localhost:8096
```

---

## 4. CLI Usage & Subcommands

### 4.1 Media Ingest Notifications (`media-ingest`)

Triggered upon completion of `tools\media_ingest_processor.py` or new file detection:

```bash
# Ingest notification for a 4K HDR Movie (with TMDB auto-lookup)
python E:\MediaServer\tools\discord_notifier.py media-ingest \
    --title "Dune: Part Two" \
    --type movie \
    --year 2024 \
    --resolution "2160p" \
    --source "Remux" \
    --hdr "DV HDR10+" \
    --video-codec "HEVC" \
    --audio-codec "TrueHD Atmos" \
    --runtime "2h 46m" \
    --filesize "64.8 GB" \
    --dest "Movies/Dune Part Two (2024)/Dune Part Two (2024) [2160p Remux DV HDR10+ HEVC TrueHD Atmos].mkv"

# Ingest notification for a TV Show Episode
python E:\MediaServer\tools\discord_notifier.py media-ingest \
    --title "Severance" \
    --type tv \
    --year 2022 \
    --season 1 \
    --episode 1 \
    --episode-name "Good News About Hell" \
    --resolution "1080p" \
    --source "WEB-DL" \
    --video-codec "HEVC" \
    --audio-codec "EAC3 Atmos"

# Auto-probe resolution, codecs, and runtime from a local video file
python E:\MediaServer\tools\discord_notifier.py media-ingest \
    --title "Oppenheimer" \
    --type movie \
    --year 2023 \
    --file "E:\Media\Movies\Oppenheimer (2023)\Oppenheimer.mkv"
```

---

### 4.2 Rclone VFS Cache & Low Disk Alerts (`vfs-cache`)

Monitors the Rclone local NVMe cache (`E:\MediaServer\cache\rclone_vfs`) and virtual mount drive (`X:`):

```bash
# Auto-probe live system disk capacity and VFS cache directory:
python E:\MediaServer\tools\discord_notifier.py vfs-cache --auto-probe

# Manual metric reporting with custom alert thresholds:
python E:\MediaServer\tools\discord_notifier.py vfs-cache \
    --mount-drive "X:" \
    --mount-status "ONLINE" \
    --cache-dir "E:\MediaServer\cache\rclone_vfs" \
    --cache-used-gb 34.2 \
    --cache-max-gb 50.0 \
    --disk-drive "E:" \
    --disk-free-gb 11.4 \
    --disk-total-gb 340.0 \
    --low-disk-threshold-gb 15.0
```

*When `disk-free-gb` drops below `low-disk-threshold-gb`, the embed dynamically changes to a prominent Warning state (`#F39C12`) instructing maintenance.*

---

### 4.3 Jellyfin Service Lifecycle & Crash Alerts (`jellyfin-service`)

Used by the watchdog script and task manager to broadcast health changes:

```bash
# Auto-probe live Jellyfin server status
python E:\MediaServer\tools\discord_notifier.py jellyfin-service --auto-probe

# Broadcast Service Restart Event
python E:\MediaServer\tools\discord_notifier.py jellyfin-service \
    --event restart \
    --url "http://localhost:8096" \
    --version "10.9.9" \
    --streams 0

# Broadcast Critical Service Crash Event
python E:\MediaServer\tools\discord_notifier.py jellyfin-service \
    --event crash \
    --url "http://localhost:8096" \
    --error "Jellyfin.Server terminated unexpectedly: Port 8096 connection refused"
```

---

### 4.4 Nightly Database Backup Summary (`db-backup`)

Invoked at the conclusion of `scripts\backup-and-vacuum-db.ps1`:

```bash
python E:\MediaServer\tools\discord_notifier.py db-backup \
    --archive-name "jellyfin_db_backup_20260821_040000.zip" \
    --backup-size-mb 38.4 \
    --initial-size-mb 118.2 \
    --compacted-size-mb 72.1 \
    --savings-pct 39.0 \
    --integrity "PASS" \
    --wal-status "PASSIVE / TRUNCATED" \
    --pruned-count 1 \
    --cloud-sync "SUCCESS (gdrive-backup:)" \
    --duration 4.2 \
    --log-path "E:\MediaServer\logs\db_backup.log"
```

---

### 4.5 Dry-Run Simulation Mode

To verify payloads without broadcasting to Discord, pass `--dry-run`:

```bash
python E:\MediaServer\tools\discord_notifier.py --dry-run db-backup
```

---

## 5. Integration Recipes

### 5.1 Integrating with PowerShell Backup Script (`backup-and-vacuum-db.ps1`)

Add the following snippet at the end of `scripts\backup-and-vacuum-db.ps1`:

```powershell
# Dispatch Discord summary notification
$discordScript = "E:\MediaServer\tools\discord_notifier.py"
if (Test-Path $discordScript) {
    & $pythonExe $discordScript db-backup `
        --archive-name $zipArchiveName `
        --backup-size-mb ([math]::Round($zipSize / 1MB, 2)) `
        --initial-size-mb ([math]::Round($initialTotalSize / 1MB, 2)) `
        --compacted-size-mb ([math]::Round($compactedTotalSize / 1MB, 2)) `
        --savings-pct $savingPct `
        --integrity "PASS" `
        --wal-status "PASSIVE / TRUNCATED" `
        --pruned-count $prunedCount `
        --cloud-sync "SUCCESS ($RcloneRemote)" `
        --log-path $LogPath
}
```

### 5.2 Integrating with Media Ingest Processor (`media_ingest_processor.py`)

Import and call directly in Python:

```python
from tools.discord_notifier import DiscordNotificationBuilder, DiscordWebhookClient

client = DiscordWebhookClient()
embed = DiscordNotificationBuilder.build_media_ingest_embed(
    title=item["parsed"]["title"],
    media_type=item["parsed"]["media_type"],
    year=item["parsed"]["year"],
    season=item["parsed"].get("season"),
    episode=item["parsed"].get("episode"),
    resolution=item["parsed"].get("resolution"),
    source=item["parsed"].get("source"),
    video_codec=item["parsed"].get("video_codec"),
    audio_codec=item["parsed"].get("audio_codec"),
    hdr=item["parsed"].get("hdr"),
    destination_path=item["dest_full"]
)
client.send(embeds=[embed])
```

---

## 6. Resilience & Production Features

1. **HTTP 429 Rate Limit Handling:** Inspects Discord's `retry_after` response header and pauses execution before retrying automatically.
2. **Zero-Crash Design:** Network timeouts, missing API keys, or invalid payloads degrade gracefully without interrupting primary server automation jobs.
3. **Payload Truncation Protection:** Embed titles are bounded to 256 characters, descriptions to 4096 characters, and field values to 1024 characters, strictly adhering to Discord's API specifications.
