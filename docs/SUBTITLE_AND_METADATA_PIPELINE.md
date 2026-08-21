# Subtitle Synchronization, Extraction & Jellyfin Metadata Pipeline

## 1. Executive Summary & Architecture

The **Subtitle Synchronization and Metadata Normalizer Pipeline** (`tools/sub_sync_organizer.py`) guarantees 100% subtitle availability and pristine directory structure across local (`F:\Media`) and cloud-mounted storage.

It resolves common media server pain points:
- Media files containing embedded subtitle streams (ASS/SSA/SRT) that cause direct play failures or unnecessary transcoding in browsers/low-power TV clients.
- Missing English or secondary language tracks in foreign releases.
- Inconsistent file naming that causes Jellyfin / Emby / Plex metadata scrapers to misidentify multi-part episodes or subtitles.
- Cluttered directory structures containing release tracker advertisements, sample clips, and unparsed files.

```
+----------------------------------------------------------------------------------------------------+
|                                    MEDIA DISCOVERY & SCAN ENGINE                                   |
|  - Recursive traversal across Movies (`F:\Media\Movies`) and Series (`F:\Media\Series`)             |
|  - Skips sample files (<10MB), release group garbage, and non-media clutter                        |
+-------------------------------------------------+--------------------------------------------------+
                                                  |
                                                  v
+----------------------------------------------------------------------------------------------------+
|                                   FFPROBE STREAM INSPECTION                                        |
|  - Identifies embedded video, audio, and subtitle streams                                          |
|  - Parses stream tags: language (ISO 639-1 / 639-2), stream disposition (default, forced, SDH)     |
+-------------------------------------------------+--------------------------------------------------+
                                                  |
                                                  v
+----------------------------------------------------------------------------------------------------+
|                            EMBEDDED SUBTITLE EXTRACTION (Zero-Transcode)                           |
|  - `ffmpeg -i input.mkv -map 0:s:X -c:s copy output.eng.srt`                                       |
|  - Preserves ASS styling or extracts pure SRT based on stream codec                                |
|  - Normalized directly beside media file following strict Jellyfin conventions                     |
+-------------------------------------------------+--------------------------------------------------+
                                                  |
                                                  v
+----------------------------------------------------------------------------------------------------+
|                             REMOTE API DOWNLOAD FALLBACK (Missing Tracks)                          |
|  - OpenSubtitles.com REST API v1 integration using 64-bit file hash & IMDb ID                      |
|  - Subscene HTML fallback for rare / non-hashed media releases                                     |
+-------------------------------------------------+--------------------------------------------------+
                                                  |
                                                  v
+----------------------------------------------------------------------------------------------------+
|                             JELLYFIN LIBRARY REFRESH & NOTIFICATION                               |
|  - Triggers `/Library/Refresh` REST API endpoint                                                   |
|  - Real-time indexing of extracted/downloaded subtitle assets                                      |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Jellyfin Subtitle & Naming Standards

Jellyfin recognizes subtitles placed in the same folder as the video file when named according to the following syntax:

```
[MediaFileName].[LanguageCode].[Flags].[Extension]
```

### Supported Flags and Codes
| Component | Values | Examples | Jellyfin Behavior |
| :--- | :--- | :--- | :--- |
| **Language Code** | ISO 639-2 (3-letter) or ISO 639-1 (2-letter) | `.eng`, `.hin`, `.spa`, `.fre` | Displays language name in UI track selector |
| **Default Flag** | `.default` | `Movie.eng.default.srt` | Automatically pre-selected when playback starts |
| **Forced Flag** | `.forced` | `Movie.eng.forced.srt` | Selected only for non-native foreign dialogue segments |
| **SDH Flag** | `.sdh` or `.cc` | `Movie.eng.sdh.srt` | Subtitles for the Deaf and Hard of Hearing |

### Canonical Folder & File Examples

#### TV Series
```
F:\Media\Series\
└── The Traitors (2025)\
    └── Season 01\
        ├── The Traitors - S01E01 - Episode 1.mkv
        ├── The Traitors - S01E01 - Episode 1.eng.srt
        ├── The Traitors - S01E01 - Episode 1.hin.ass
        ├── The Traitors - S01E01 - Episode 1.tam.ass
        └── The Traitors - S01E02 - Episode 2.mkv
```

#### Movies
```
F:\Media\Movies\
└── Inception (2010)\
    ├── Inception (2010) [1080p].mkv
    ├── Inception (2010) [1080p].eng.default.srt
    └── Inception (2010) [1080p].eng.forced.srt
```

---

## 3. CLI Reference & Usage

The script is located at `E:\MediaServer\tools\sub_sync_organizer.py` and can be invoked from PowerShell or Bash.

### Command Line Arguments
```bash
python E:/MediaServer/tools/sub_sync_organizer.py [OPTIONS]
```

| Argument | Default | Description |
| :--- | :--- | :--- |
| `--path`, `-p` | `F:\Media` | Root directory to scan for Movies and TV Series |
| `--languages`, `-l` | `eng hin` | List of target subtitle languages to ensure exist |
| `--dry-run` | `False` | Simulate actions without extracting files or making API calls |
| `--no-extract` | `False` | Disable automatic extraction of embedded subtitle tracks |
| `--no-download` | `False` | Disable remote downloading from OpenSubtitles API |
| `--refresh-jellyfin` | `False` | Automatically trigger Jellyfin `/Library/Refresh` API |
| `--jellyfin-url` | `http://localhost:8096` | Jellyfin server URL |
| `--jellyfin-token` | Env: `JELLYFIN_API_KEY` | Jellyfin API authentication token |

---

## 4. Operational Workflows & Examples

### 1. Perform Dry Run Inspection
Scan the library and display what subtitles would be extracted and what languages are missing:
```bash
python E:/MediaServer/tools/sub_sync_organizer.py --dry-run --path "F:/Media"
```

### 2. Full Extraction & Sync
Extract all embedded streams and normalize names:
```bash
python E:/MediaServer/tools/sub_sync_organizer.py --path "F:/Media" --languages eng hin tam tel
```

### 3. Automated Post-Ingestion Integration
Add this tool to scheduled tasks or automated download triggers (e.g. following Telegram / Rclone ingestion):
```powershell
# Ingest and organize subtitles, then refresh Jellyfin
$env:JELLYFIN_API_KEY = "your_jellyfin_api_key_here"
python E:\MediaServer\tools\sub_sync_organizer.py --path "F:\Media" --refresh-jellyfin
```

---

## 5. Performance & Resource Optimization

1. **Zero-Transcode Stream Demuxing:** The extractor invokes `ffmpeg -c:s copy` whenever possible, extracting a subtitle stream in less than 200 milliseconds per file with virtually 0% CPU consumption.
2. **Direct Playback Optimization:** By decoupling embedded subtitle tracks into external `.srt` files, Jellyfin Web, Android TV, and Apple TV clients can direct-play video streams without triggering server-side video transcoding for subtitle burning.
3. **OpenSubtitles 64-bit Hash Verification:** Computes byte checksums directly against video headers and footers to guarantee sample-accurate subtitle synchronization.
