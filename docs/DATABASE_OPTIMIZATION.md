# Jellyfin SQLite Database Optimization, Live Snapshotting & Cloud Sync Guide

## 1. Executive Summary & Architecture Overview

Jellyfin stores core system configurations, user profiles, play states, device tokens, and library metadata across SQLite database files (primarily `jellyfin.db` and auxiliary/plugin databases). Over time, repeated library scans, metadata updates, item deletions, and play-state scrobbling introduce significant internal page fragmentation, index bloat, and growing Write-Ahead Log (`WAL`) files.

This automated architecture delivers a **zero-downtime, non-blocking maintenance pipeline**:
1. **Passive WAL Checkpointing (`PRAGMA wal_checkpoint(PASSIVE)`):** Transfers accumulated dirty pages from the WAL file into the main database page cache without blocking concurrent Jellyfin readers or writers.
2. **Zero-Lock Online Compaction (`VACUUM INTO`):** Employs SQLite's native `VACUUM INTO` functionality to build a fresh, contiguous, defragmented snapshot of the active database into a temporary NVMe staging path without locking out active streaming clients or transcoder pipelines.
3. **Database Integrity Verification (`PRAGMA integrity_check` & `PRAGMA quick_check`):** Verifies b-tree page coherence and row consistency on the generated snapshot before compression.
4. **7-Day Rolling NVMe Retention:** Automatically rolls and compresses daily/weekly snapshots into timestamped archives (`jellyfin_db_backup_YYYYMMDD_HHMMSS.zip`) on NVMe storage (`F:\Jellyfin\backups`), automatically pruning snapshots older than 7 days.
5. **Encrypted Cloud Mirroring via Rclone:** Stages backups to `E:\MediaServer\backups` and syncs them to encrypted remote cloud targets (e.g., `rclone sync E:\MediaServer\backups gdrive-backup:`).
6. **Weekly Unattended Execution:** Fully scheduled via Windows Task Scheduler XML definitions running with elevated privileges during low-traffic maintenance windows (e.g., Sundays at 03:30 AM).

---

## 2. SQLite Engine Mechanics & Zero-Downtime Principles

### 2.1 The Danger of Traditional `VACUUM`
A conventional in-place `VACUUM;` statement acquires an **exclusive write lock** on the database file. If executed while Jellyfin is running:
- All Jellyfin HTTP endpoints attempting database access will experience `SQLITE_BUSY` (database is locked) exceptions.
- Active video playback reporting, heartbeat pings, and subtitle fetches will stall or timeout.
- Unclean cancellations or sudden aborts risk database corruption.

### 2.2 Why `VACUUM INTO` + WAL Checkpointing is Superior
Starting with SQLite 3.27.0+, `VACUUM INTO <destination_file>` creates a completely defragmented, clean copy into a new destination path using a **shared read lock** rather than an exclusive write lock.
- **Continuous Uptime:** Jellyfin remains online and responsive throughout the entire vacuum procedure.
- **Optimized B-Trees:** Page order is re-sequenced sequentially, index structures are re-balanced, and dead rows are reclaimed.
- **Safe Checkpointing:** `PRAGMA wal_checkpoint(PASSIVE)` gracefully pushes committed transactions from `jellyfin.db-wal` into `jellyfin.db` without waiting for active read transactions to close.

---

## 3. Storage Hierarchy & Path Layout

| Component | Storage Path | Disk Type / Purpose |
| :--- | :--- | :--- |
| **Live Database Directory** | `F:\Jellyfin\data\data` | High-Speed NVMe (Active Read/Write) |
| **NVMe Backup Directory** | `F:\Jellyfin\backups` | High-Speed NVMe (7-Day Rolling Retention) |
| **Local Staging Directory** | `E:\MediaServer\backups` | Persistent Mirror Directory for Rclone Sync |
| **Rclone Cloud Target** | `gdrive-backup:` | Encrypted Off-Site Remote Cloud Storage |
| **Automation Script** | `E:\MediaServer\scripts\backup-and-vacuum-db.ps1` | PowerShell Automation Engine |
| **Task Scheduler XML** | `E:\MediaServer\config\task-scheduler-db-backup.xml` | Windows Task Scheduler XML Definition |
| **Execution Logs** | `E:\MediaServer\logs\db_backup.log` | Structured Operational Logs |

---

## 4. Automation Script Usage & Parameters

The PowerShell automation engine is located at `E:\MediaServer\scripts\backup-and-vacuum-db.ps1`.

### Script Parameters

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-SourceDbDir` | String | `F:\Jellyfin\data\data` | Path to active Jellyfin SQLite database files. |
| `-BackupDir` | String | `F:\Jellyfin\backups` | NVMe target directory for local backups. |
| `-RetentionDays` | Int | `7` | Number of days to retain local snapshot archives. |
| `-RcloneRemote` | String | `gdrive-backup:` | Configured Rclone remote for cloud sync. |
| `-LocalSyncDir` | String | `E:\MediaServer\backups` | Local mirror folder monitored and synced by Rclone. |
| `-SkipCloudSync` | Switch | `False` | Bypasses cloud sync (useful for local-only testing). |
| `-LogPath` | String | `E:\MediaServer\logs\db_backup.log` | Destination file for detailed runtime logging. |

### Execution Examples

#### 1. Full Production Run (Local Compaction + 7-Day Prune + Encrypted Cloud Sync)
```powershell
powershell.exe -ExecutionPolicy Bypass -File "E:\MediaServer\scripts\backup-and-vacuum-db.ps1"
```

#### 2. Local-Only Execution (Skip Cloud Upload)
```powershell
powershell.exe -ExecutionPolicy Bypass -File "E:\MediaServer\scripts\backup-and-vacuum-db.ps1" -SkipCloudSync
```

#### 3. Custom Retention Window (e.g., 14 Days) & Custom Rclone Target
```powershell
powershell.exe -ExecutionPolicy Bypass -File "E:\MediaServer\scripts\backup-and-vacuum-db.ps1" -RetentionDays 14 -RcloneRemote "gdrive-backup:media-server-backups"
```

---

## 5. Rclone Encrypted Cloud Sync Setup

To back up database archives securely to cloud storage without exposing sensitive Jellyfin tokens, user password hashes, or network paths:

### 5.1 Configure Encrypted Remote in Rclone
Run `rclone config` and create:
1. **Base Remote (e.g., `gdrive-media:`):** Standard Google Drive / S3 / WebDAV connection.
2. **Encrypted Wrapper Remote (`gdrive-backup:`):**
   - **Type:** `crypt`
   - **Remote:** `gdrive-media:/Backups/JellyfinDB`
   - **Filename Encryption:** `standard`
   - **Directory Name Encryption:** `true`
   - **Password & Salt:** Set secure encryption passphrases.

### 5.2 Manual Sync Verification
To test encrypted upload manually:
```powershell
rclone sync "E:\MediaServer\backups" "gdrive-backup:" --transfers 4 --checkers 8 -v
```

---

## 6. Windows Task Scheduler Automated Registration

The task definition is pre-configured in `E:\MediaServer\config\task-scheduler-db-backup.xml`.

### 6.1 Register Task via PowerShell
Run PowerShell as Administrator:
```powershell
Register-ScheduledTask -Xml (Get-Content "E:\MediaServer\config\task-scheduler-db-backup.xml" -Raw) -TaskName "Jellyfin Database Backup and Vacuum" -Force
```

### 6.2 Register Task via `schtasks.exe` (CLI)
```cmd
schtasks /create /tn "Jellyfin Database Backup and Vacuum" /xml "E:\MediaServer\config\task-scheduler-db-backup.xml" /f
```

### 6.3 Trigger Scheduled Task On-Demand
```powershell
Start-ScheduledTask -TaskName "Jellyfin Database Backup and Vacuum"
```

---

## 7. Disaster Recovery & Database Restoration

If `jellyfin.db` or library data becomes corrupted or unrecoverable, follow these steps to restore from a vacuumed snapshot archive:

### Step-by-Step Restoration Protocol

1. **Stop Jellyfin Media Server:**
   ```powershell
   Stop-Process -Name "jellyfin" -Force -ErrorAction SilentlyContinue
   ```

2. **Navigate to the Backup Directory & Identify Target Snapshot:**
   ```powershell
   Get-ChildItem "F:\Jellyfin\backups\jellyfin_db_backup_*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
   ```

3. **Extract the Desired Snapshot:**
   ```powershell
   $snapshotZip = "F:\Jellyfin\backups\jellyfin_db_backup_20260821_205035.zip"
   $tempRestoreDir = "F:\Jellyfin\temp_restore"
   Expand-Archive -Path $snapshotZip -DestinationPath $tempRestoreDir -Force
   ```

4. **Verify Extracted Database Integrity:**
   ```powershell
   python -c "import sqlite3; con = sqlite3.connect('F:/Jellyfin/temp_restore/jellyfin.db'); cur = con.cursor(); cur.execute('PRAGMA integrity_check;'); print('Integrity:', cur.fetchall()); con.close()"
   ```

5. **Deploy Restored Database & Remove Stale WAL/SHM Files:**
   ```powershell
   # Move old corrupted database to emergency quarantine
   Move-Item "F:\Jellyfin\data\data\jellyfin.db" "F:\Jellyfin\data\data\jellyfin.db.corrupted" -Force
   Remove-Item "F:\Jellyfin\data\data\jellyfin.db-wal" -Force -ErrorAction SilentlyContinue
   Remove-Item "F:\Jellyfin\data\data\jellyfin.db-shm" -Force -ErrorAction SilentlyContinue

   # Copy restored vacuumed database
   Copy-Item "F:\Jellyfin\temp_restore\jellyfin.db" "F:\Jellyfin\data\data\jellyfin.db" -Force
   Remove-Item $tempRestoreDir -Recurse -Force
   ```

6. **Start Jellyfin Media Server:**
   ```powershell
   Start-Process "F:\Jellyfin\server\jellyfin.exe"
   ```

7. **Verify Service Health:**
   ```powershell
   Invoke-RestMethod -Uri "http://localhost:8096/System/Info/Public"
   ```
