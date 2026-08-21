# Telegram Media Ingestion & Server-Side Remote Pipeline Specification

## 1. Pipeline Architecture Overview

Modern high-speed media acquisition pipelines frequently utilize automated cloud leech bots (hosted on high-bandwidth VPS infrastructure or Telegram-to-Cloud services) to download, unpack, and mirror media releases directly into cloud remotes (such as Google Drive, Torbox, or WebDAV storage).

However, cloud leech bots routinely output files with randomized, obfuscated alphanumeric hashes or cryptic release hashes (e.g. `5d57b11d38e74e62a849204bf1f0d367.mkv` or `a1b2c3d4e5f6.mp4`) to avoid duplicate detection or platform collisions.

The MediaServer pipeline resolves this by ingesting bot metadata logs, de-obfuscating file mappings, executing **zero-download server-side remote renames** (`rclone moveto`), structuring directories into strict Jellyfin/TMDB hierarchy, and triggering automated library scans.

```
+---------------------------------------------------------------------------------------------------+
|                                  Telegram Leech Bot Execution                                     |
|  - Torrents / NZB / Direct Links processed in cloud                                               |
|  - Uploaded directly to cloud remote: gdrive:/TelegramLeech/                                      |
|  - Output files: Obfuscated hashes (e.g. 5d57b11d38e74e62a849204bf1f0d367.mkv)                    |
|  - Message Logs / Captions: "Breaking Bad S01E01 Pilot 1080p -> 5d57b11d...mkv"                   |
+-------------------------------------------------+-------------------------------------------------+
                                                  |
                                                  v
+---------------------------------------------------------------------------------------------------+
|                                De-obfuscation & Metadata Engine                                   |
|  - Ingests Telegram message logs, webhook JSON, caption text, or `.log` dumps                     |
|  - Regex parser maps hash -> Canonical Show Title, Season, Episode, Resolution, Codec            |
|  - Interrogates TMDB / TVMaze APIs for official episode titles and air dates                      |
+-------------------------------------------------+-------------------------------------------------+
                                                  |
                                                  v
+---------------------------------------------------------------------------------------------------+
|                           Zero-Download Server-Side Remote Pipeline                               |
|  - Generates atomic `rclone moveto` commands                                                      |
|  - Executes pure cloud API metadata mutations (Google Drive / S3 / WebDAV)                        |
|  - ZERO local disk download, ZERO bandwidth consumption on local machine                          |
|  - Relocates: gdrive:/TelegramLeech/5d57b11d...mkv                                                |
|       --> gdrive:/Media/TV Shows/Breaking Bad (2008)/Season 01/Breaking Bad - S01E01 - Pilot.mkv  |
+-------------------------------------------------+-------------------------------------------------+
                                                  |
                                                  v
+---------------------------------------------------------------------------------------------------+
|                             Jellyfin Auto-Discovery & Direct Play                                 |
|  - Mount refreshes via Rclone VFS directory cache poll (`--poll-interval 10s`)                    |
|  - Jellyfin Library API triggered: `/Library/Refresh`                                             |
|  - Native TMDB identification, thumbnail generation, NFO creation, Subtitle extraction            |
+---------------------------------------------------------------------------------------------------+
```

---

## 2. De-Obfuscation Workflow for Telegram Leech Bots

Telegram leech bots (such as *WZML-X*, *Slam-Mirror*, *Mirror-Leech-Telegram-Bot*, or custom Telegram userbot scripts) produce two primary outputs:
1. **Cloud Remote Files**: Streamed straight to cloud folders with unique hashes to prevent filename collisions and avoid automated hash filtering.
2. **Telegram Message Log / Caption**: Sent to an administrative channel, private chat, or log dump file detailing the source torrent name, unpacked file name, file size, MD5/SHA256, and destination file hash.

### Typical Obfuscation Patterns
* **Hex Hash / UUID**: `5d57b11d38e74e62a849204bf1f0d367.mkv`
* **Short Hash with Metadata**: `[720p]_[2a8f9b]_[x264].mkv`
* **Numerical ID**: `1049281928_file.mkv`
* **Base64 / URL-Safe Token**: `c2Vhc29uMV9lcDAx.mkv`

### Matching Telegram Captions & Message Logs to Hashes
Leech bot notifications generally adhere to one of the following message templates:

```text
Task Completed:
Name: Shogun.2024.S01E01.Anjin.1080p.WEB-DL.DDP5.1.Atmos.H.264.mkv
Size: 2.34 GB
Hash: 5d57b11d38e74e62a849204bf1f0d367.mkv
Folder: /LeechBot/Uploads/
Status: Uploaded to Google Drive
```

Or JSON webhook payload:
```json
{
  "event": "upload_complete",
  "source_title": "Severance.S01E01.Good.News.About.Hell.2160p.ATVP.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265.mkv",
  "file_hash_name": "a8f09d7c11234e89bb45c0192e.mkv",
  "remote_path": "TelegramLeech/a8f09d7c11234e89bb45c0192e.mkv",
  "bytes": 5294821044
}
```

The de-obfuscation engine matches the `file_hash_name` (or `Hash`) with the clean `source_title` (or `Name`) using regular expressions and string distance matching.

---

## 3. Jellyfin & TMDB Library Naming Conventions

For Jellyfin (and external metadata providers like TheMovieDB and TheTVDB) to identify media with 100% precision and zero manual identification intervention, files and folder structures must adhere strictly to the following standards.

### TV Show Hierarchy
```
Media/TV Shows/
└── Series Name (Year) [tmdbid-XXXXX]/
    ├── Season 00/                                  <-- Specials / Extras
    │   └── Series Name - S00E01 - Special Title.mkv
    ├── Season 01/
    │   ├── Series Name - S01E01 - Pilot.mkv
    │   ├── Series Name - S01E02 - Episode Title.mkv
    │   └── Series Name - S01E02 - Episode Title.eng.default.srt
    └── Season 02/
        └── Series Name - S02E01 - Season Premiere.mkv
```

### Movie Hierarchy
```
Media/Movies/
└── Movie Title (Year) [tmdbid-XXXXX]/
    ├── Movie Title (Year) [tmdbid-XXXXX] - [1080p HEVC].mkv
    └── Movie Title (Year) [tmdbid-XXXXX] - [1080p HEVC].eng.srt
```

### Key Formatting Rules
1. **Show / Movie Folder**: Always include release year in parentheses `(YYYY)`. Adding the TMDB ID tag `[tmdbid-12345]` eliminates all disambiguation issues for remakes (e.g. `Shogun (2024)` vs `Shogun (1980)`).
2. **Season Subfolders**: Two-digit zero-padded folder naming: `Season 01`, `Season 02`, `Season 10`.
3. **Episode Files**: Standard pattern: `<Show Name> - S<XX>E<YY> - <Episode Title>.<ext>`.
4. **Clean Character Replacement**: Replace illegal Windows filesystem characters (`\ / : * ? " < > |`) with clean hyphens `-` or standard spaces.

---

## 4. Zero-Download Server-Side Remote Renaming (`rclone moveto`)

### Core Concept: Cloud-Side Metadata Mutation
When managing multi-gigabyte or terabyte-scale media libraries in cloud remotes (Google Drive, Torbox WebDAV, Proton Drive, S3), downloading video files locally merely to rename them wastes gigabytes of local SSD I/O, consumes network bandwidth, and incurs massive latency.

`rclone moveto` instructs the remote storage provider's API to update the file's metadata (parent folder ID and filename) directly on the cloud server.

### Performance & Bandwidth Comparison
| Method | Data Transferred | Time per 4K Remux (50 GB) | Disk Space Required |
| :--- | :--- | :--- | :--- |
| **Download -> Rename -> Re-upload** | 100 GB (50 GB In + 50 GB Out) | 15–45 minutes | 50 GB Free Local SSD |
| **Local Mount Path Rename (`G:\`)** | 0 GB (VFS metadata sync) | 1–3 seconds | 0 bytes |
| **Direct API `rclone moveto`** | < 1 KB (REST API Payload) | **100–300 milliseconds** | **0 bytes** |

### `rclone moveto` Syntax
```bash
# General Syntax
rclone moveto <remote>:<path/to/source_hash.mkv> <remote>:<path/to/clean_destination.mkv>

# Production Example: Renaming Telegram Obfuscated Hash to Jellyfin Standard
rclone moveto \
  "gdrive:TelegramLeech/5d57b11d38e74e62a849204bf1f0d367.mkv" \
  "gdrive:Media/TV Shows/Breaking Bad (2008)/Season 01/Breaking Bad - S01E01 - Pilot.mkv" \
  --fast-list \
  --stats=1s \
  -v
```

---

## 5. Automated Python Batch De-Obfuscation Pipeline

The following production Python automation script (`telegram_media_pipeline.py`) parses Telegram leech logs/captions, extracts show titles and episode numbering, queries TheMovieDB (TMDB) API for canonical episode names, and executes `rclone moveto` directly.

```python
#!/usr/bin/env python3
"""
Telegram Media Ingestion & Server-Side De-Obfuscation Engine
Matches Telegram Leech Bot hash files to canonical media names and executes
instant cloud-side rclone moveto operations.
"""

import os
import re
import sys
import json
import subprocess
import argparse
import urllib.request
import urllib.parse
from typing import Dict, List, Optional, Tuple

TMDB_API_KEY = os.getenv("TMDB_API_KEY", "")
RCLONE_REMOTE = "gdrive"
LEECH_FOLDER = "TelegramLeech"
TARGET_TV_ROOT = "Media/TV Shows"
TARGET_MOVIE_ROOT = "Media/Movies"

# Regex for standard scene/P2P release titles
SCENE_EPISODE_REGEX = re.compile(
    r"^(?P<title>.+?)[._\s]+[sS](?P<season>\d{1,2})[eE](?P<episode>\d{1,2})"
    r"(?:[._\s]+(?P<ep_title>.+?))?"
    r"(?:[._\s]+(?P<extra>(?:1080p|720p|2160p|4k|HDR|DV|WEB-DL|BluRay|x264|x265|HEVC|AAC|DDP).*))?$"
)

MOVIE_REGEX = re.compile(
    r"^(?P<title>.+?)[._\s]+(?P<year>(?:19|20)\d{2})"
    r"(?:[._\s]+(?P<extra>(?:1080p|720p|2160p|4k|HDR|DV|WEB-DL|BluRay|x264|x265|HEVC).*))?$"
)

def sanitize_filename(name: str) -> str:
    """Removes illegal filesystem characters."""
    return re.sub(r'[\\/*?:"<>|]', "", name).strip()

def fetch_tmdb_episode_title(show_name: str, season: int, episode: int) -> Optional[str]:
    """Queries TMDB API for exact episode title."""
    if not TMDB_API_KEY:
        return None
    try:
        # Search for TV Show ID
        query = urllib.parse.quote(show_name)
        search_url = f"https://api.themoviedb.org/3/search/tv?api_key={TMDB_API_KEY}&query={query}"
        with urllib.request.urlopen(search_url, timeout=5) as res:
            data = json.loads(res.read().decode("utf-8"))
            if not data.get("results"):
                return None
            show_id = data["results"][0]["id"]
        
        # Get Episode Details
        ep_url = f"https://api.themoviedb.org/3/tv/{show_id}/season/{season}/episode/{episode}?api_key={TMDB_API_KEY}"
        with urllib.request.urlopen(ep_url, timeout=5) as res:
            ep_data = json.loads(res.read().decode("utf-8"))
            return ep_data.get("name")
    except Exception as e:
        sys.stderr.write(f"[WARN] TMDB lookup failed for {show_name} S{season}E{episode}: {e}\n")
        return None

def parse_release_name(release_name: str) -> Dict[str, str]:
    """Parses raw scene/P2P string into structured metadata."""
    name_clean = os.path.splitext(release_name)[0]
    ext = os.path.splitext(release_name)[1] or ".mkv"
    
    # TV Show Matching
    match_tv = SCENE_EPISODE_REGEX.match(name_clean)
    if match_tv:
        raw_title = match_tv.group("title").replace(".", " ").replace("_", " ").strip()
        season = int(match_tv.group("season"))
        episode = int(match_tv.group("episode"))
        
        official_ep_title = fetch_tmdb_episode_title(raw_title, season, episode)
        ep_title = official_ep_title or match_tv.group("ep_title") or f"Episode {episode}"
        ep_title = ep_title.replace(".", " ").replace("_", " ").strip()
        
        dest_rel_path = (
            f"{TARGET_TV_ROOT}/{sanitize_filename(raw_title)}/"
            f"Season {season:02d}/"
            f"{sanitize_filename(raw_title)} - S{season:02d}E{episode:02d} - {sanitize_filename(ep_title)}{ext}"
        )
        return {"type": "tv", "dest_path": dest_rel_path, "show": raw_title, "season": season, "episode": episode}

    # Movie Matching
    match_movie = MOVIE_REGEX.match(name_clean)
    if match_movie:
        raw_title = match_movie.group("title").replace(".", " ").replace("_", " ").strip()
        year = match_movie.group("year")
        dest_rel_path = (
            f"{TARGET_MOVIE_ROOT}/{sanitize_filename(raw_title)} ({year})/"
            f"{sanitize_filename(raw_title)} ({year}){ext}"
        )
        return {"type": "movie", "dest_path": dest_rel_path, "title": raw_title, "year": year}

    # Fallback
    return {"type": "unknown", "dest_path": f"{TARGET_MOVIE_ROOT}/Unsorted/{release_name}"}

def execute_remote_move(src_hash_path: str, dest_clean_path: str, dry_run: bool = False):
    """Executes atomic rclone moveto command."""
    src = f"{RCLONE_REMOTE}:{src_hash_path}"
    dest = f"{RCLONE_REMOTE}:{dest_clean_path}"
    
    cmd = ["rclone", "moveto", src, dest, "--fast-list", "-v"]
    
    print(f"[*] Moving remote object:")
    print(f"    SRC : {src}")
    print(f"    DEST: {dest}")
    
    if dry_run:
        print("    [DRY-RUN] Command skipped.")
        return True
        
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode == 0:
        print("    [SUCCESS] File moved server-side.")
        return True
    else:
        sys.stderr.write(f"    [ERROR] Rclone failed: {res.stderr}\n")
        return False

def process_log_entry(raw_log: str, dry_run: bool = False):
    """
    Accepts log lines such as:
    5d57b11d38e74e62a849204bf1f0d367.mkv -> Shogun.2024.S01E01.Anjin.1080p.mkv
    or JSON mappings.
    """
    pairs: List[Tuple[str, str]] = []
    
    # Check if JSON
    try:
        data = json.loads(raw_log)
        if isinstance(data, list):
            for item in data:
                pairs.append((item["hash_file"], item["original_name"]))
        elif isinstance(data, dict):
            pairs.append((data.get("hash_file") or data.get("file_hash_name"), 
                          data.get("original_name") or data.get("source_title")))
    except json.JSONDecodeError:
        # Line-by-line parsing
        for line in raw_log.strip().splitlines():
            if "->" in line:
                parts = line.split("->")
                pairs.append((parts[0].strip(), parts[1].strip()))
            elif "\t" in line:
                parts = line.split("\t")
                pairs.append((parts[0].strip(), parts[1].strip()))

    for hash_file, orig_name in pairs:
        if not hash_file or not orig_name:
            continue
        
        parsed = parse_release_name(orig_name)
        src_path = f"{LEECH_FOLDER}/{hash_file}"
        dest_path = parsed["dest_path"]
        
        execute_remote_move(src_path, dest_path, dry_run=dry_run)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Telegram Media De-obfuscation Pipeline")
    parser.add_argument("--log-file", help="Path to text/json file containing hash-to-name mappings")
    parser.add_argument("--raw-map", help="Single mapping string: 'hash.mkv -> Title.S01E01.mkv'")
    parser.add_argument("--dry-run", action="store_true", help="Simulate without moving files")
    args = parser.parse_args()

    if args.log_file and os.path.exists(args.log_file):
        with open(args.log_file, "r", encoding="utf-8") as f:
            process_log_entry(f.read(), dry_run=args.dry_run)
    elif args.raw_map:
        process_log_entry(args.raw_map, dry_run=args.dry_run)
    else:
        print("Provide --log-file or --raw-map. Example usage:")
        print('  python telegram_media_pipeline.py --raw-map "5d57b11d.mkv -> Shogun.2024.S01E01.Anjin.1080p.mkv"')
```

---

## 6. Native PowerShell Automation Engine

For automated scheduled tasks or Windows event triggers, the following PowerShell script (`Invoke-TelegramMediaIngestion.ps1`) monitors a local log directory, de-obfuscates filenames, executes server-side moves via `rclone`, and commands Jellyfin to refresh its library via REST API.

```powershell
<#
.SYNOPSIS
    Automated Telegram Media De-Obfuscation & Jellyfin Ingestion Engine.
.DESCRIPTION
    Monitors incoming Telegram bot upload logs, runs server-side rclone moveto,
    and invalidates Jellyfin library caches via API.
#>

param (
    [string]$RemoteName = "gdrive",
    [string]$LeechFolder = "TelegramLeech",
    [string]$MediaRoot = "Media/TV Shows",
    [string]$MappingFile = "E:\MediaServer\config\telegram_ingest_queue.json",
    [string]$JellyfinUrl = "http://127.0.0.1:8096",
    [string]$JellyfinApiKey = $env:JELLYFIN_API_KEY,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log-Message {
    param([string]$Msg, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Msg"
}

if (-not (Test-Path $MappingFile)) {
    Log-Message "Mapping file not found at: $MappingFile" "WARN"
    exit 0
}

Log-Message "Reading batch queue from $MappingFile"
$queueContent = Get-Content -Raw -Path $MappingFile | ConvertFrom-Json

$processedCount = 0

foreach ($item in $queueContent) {
    $hashFile = $item.hash_file
    $cleanName = $item.clean_name
    
    if (-not $hashFile -or -not $cleanName) {
        continue
    }

    # Match SxxEyy
    if ($cleanName -match '^(?<Show>.+?)[._\s]+[sS](?<Season>\d{1,2})[eE](?<Episode>\d{1,2})(?:[._\s]+(?<Title>.*?))?(?:\.(?<Ext>[^.]+))?$') {
        $showName  = $Matches['Show'].Replace('.', ' ').Trim()
        $seasonNum = [int]$Matches['Season']
        $epNum     = [int]$Matches['Episode']
        $epTitle   = if ($Matches['Title']) { $Matches['Title'].Replace('.', ' ').Trim() } else { "Episode $epNum" }
        $ext       = if ($Matches['Ext']) { $Matches['Ext'] } else { "mkv" }

        # Format 2-digit zero-padded names
        $seasonPad = "{0:D2}" -f $seasonNum
        $epPad     = "{0:D2}" -f $epNum
        
        $destPath = "$MediaRoot/$showName/Season $seasonPad/$showName - S${seasonPad}E${epPad} - $epTitle.$ext"
        $srcRemote = "${RemoteName}:${LeechFolder}/$hashFile"
        $destRemote = "${RemoteName}:${destPath}"

        Log-Message "Processing Episode: $showName S${seasonPad}E${epPad}"
        Log-Message "  SOURCE: $srcRemote"
        Log-Message "  DEST  : $destRemote"

        if ($DryRun) {
            Log-Message "  [DRY-RUN] rclone moveto command skipped" "WARN"
        } else {
            & rclone moveto "$srcRemote" "$destRemote" --fast-list -v
            if ($LASTEXITCODE -eq 0) {
                Log-Message "  [SUCCESS] Cloud move completed."
                $processedCount++
            } else {
                Log-Message "  [ERROR] Rclone failed with exit code $LASTEXITCODE" "ERROR"
            }
        }
    }
}

# Clear queue file if not dry run
if (-not $DryRun -and $processedCount -gt 0) {
    Set-Content -Path $MappingFile -Value "[]"
    Log-Message "Ingestion queue cleared."

    # Trigger Jellyfin Library Refresh
    if ($JellyfinApiKey) {
        Log-Message "Triggering Jellyfin Library Refresh API..."
        $headers = @{
            "X-Emby-Token" = $JellyfinApiKey
        }
        try {
            $response = Invoke-RestMethod -Uri "$JellyfinUrl/Library/Refresh" -Method Post -Headers $headers
            Log-Message "Jellyfin Library Refresh triggered successfully."
        } catch {
            Log-Message "Failed to trigger Jellyfin API: $_" "WARN"
        }
    }
}
```

---

## 7. Operational Diagnostics & Best Practices

1. **Rclone VFS Invalidation**: When files are moved server-side via `rclone moveto`, mounts running with `--poll-interval 10s` pick up the changes on the next polling cycle. If instant visibility is required, trigger `rclone rc vfs/refresh` via the local Rclone Remote Control port:
   ```bash
   curl -X POST http://127.0.0.1:5572/vfs/refresh?recursive=true
   ```
2. **Duplicate Detection**: Maintain an SQLite or JSON history of processed hashes (`hash -> tmdb_id -> final_path`) to prevent re-processing dropped transfers.
3. **Avoid Rate Limits**: When moving hundreds of files on Google Drive, pass `--tpslimit 10` to avoid 403 `User Rate Limit Exceeded` API errors.
4. **Permissions & Ownership**: When using mounted drives with Jellyfin running as a Windows Service, ensure the WinFsp mount runs in the same user session or as `SYSTEM` with appropriate global flags.
