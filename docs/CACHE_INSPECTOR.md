# Rclone VFS Cache Inspector & LRU Eviction Manager

## 1. Overview
The `rclone_cache_inspector.py` tool provides real-time visibility, telemetry, and safe eviction controls for Rclone VFS sparse caches (`F:\rclone-cache\gdrive-media`). 

When Rclone runs with `--vfs-cache-mode full`, media files are cached sparsely: only requested byte chunks (e.g. video headers, seeking targets, and buffered segments) are downloaded and stored on disk. This tool inspects the dual-hierarchy (`vfs/` binary payloads and `vfsMeta/` JSON tracking descriptors), computes physical on-disk allocation vs nominal file sizes, tracks LRU (Least Recently Used) access times, and provides safe purge capabilities integrated with WinFsp / Win32 process lock detection.

---

## 2. Key Architecture & Features

### 2.1 Sparse Chunk Allocation Ratios
- **Nominal Size vs Actual Allocated Size:** Rclone sparse files allocate only populated byte ranges on NTFS. The tool uses `kernel32.GetCompressedFileSizeW` on Windows alongside `vfsMeta` chunk index aggregation (`Rs` array) to determine real disk consumption.
- **Sparse Ratio Percentage:** Shows the proportion of the media file cached on the local drive (e.g., 2.9% cached when Jellyfin only probed metadata and first few minutes).

### 2.2 LRU (Least Recently Used) Eviction Tracking
- Parses ISO 8601 timestamps (`ATime` in `vfsMeta` or filesystem `st_atime`).
- Sorts cache entries chronologically to identify cold, eligible candidates for eviction before cache limits are exceeded.

### 2.3 WinFsp / Win32 Lock Detection
- Before purging any cached item, the tool invokes Win32 `CreateFileW` with exclusive share mode (`0`).
- **Sharing Violations (`ERROR_SHARING_VIOLATION #32`)** are caught in real-time if Jellyfin, PotPlayer, or WinFsp active mount handles are reading or streaming the file.
- **Dirty File Protection:** Files flagged as `"Dirty": true` in `vfsMeta` (pending remote upload) are protected from accidental purge unless `--force` is explicitly provided.

---

## 3. Command-Line Reference

### Basic Inspection (Tree Hierarchy & LRU Summary)
```bash
python E:\MediaServer\tools\rclone_cache_inspector.py
```
*Output snippet:*
```text
================================================================================
 RCLONE VFS CACHE INSPECTOR - HIERARCHY
 Root: F:\rclone-cache\gdrive-media
 Total Cached Files: 23
 Total Nominal Size: 27.50 GB
 Actual Disk Allocated: 3.52 GB (12.81%)
 Dirty (Un-uploaded) Files: 1
================================================================================
Path                                          | Nominal    | Allocated  | Cached % | Chunks
--------------------------------------------------------------------------------
...B.DL.Hindi.DDP5.1.x264-Vegamovies.is.mkv   | 1.19 GB    | 389.62 MB  | 32.0%    | 3     
...
=====================================================================================
 RCLONE VFS LRU EVICTION CANDIDATES (Oldest 5 items)
=====================================================================================
#   | Last Access (ATime)  | Allocated  | Dirty | Path
-------------------------------------------------------------------------------------
1   | 2026-08-21 18:54:55  | 1.01 GB    | No    | ...indi_AAC5_1_SDR_H_264_1VeGamovies.mkv
2   | 2026-08-21 20:02:45  | 11.12 MB   | No    | .../2dd940185c7047e6f7a75a36b6a671c4.mkv
```

### Check Active Locks
Check which cached files are currently locked by Jellyfin or active streaming sessions:
```bash
python E:\MediaServer\tools\rclone_cache_inspector.py --check-locks
```

### List Oldest LRU Items
List top N oldest accessed items:
```bash
python E:\MediaServer\tools\rclone_cache_inspector.py --lru 25
```

### Safe Item Purge
Purge a single file or directory from the cache:
```bash
python E:\MediaServer\tools\rclone_cache_inspector.py --purge-item "Series/The Traitor (2025)/Season 1"
```
*(Will automatically skip locked or dirty files)*

### Safe Global / Aging Purge
Purge all unlocked, non-dirty items older than 3 days:
```bash
python E:\MediaServer\tools\rclone_cache_inspector.py --purge-all --older-than-days 3
```

### Force Purge (Override Locks and Dirty Flags)
```bash
python E:\MediaServer\tools\rclone_cache_inspector.py --purge-item "filename.mkv" --force
```

### JSON Output (API / Automation Integration)
```bash
python E:\MediaServer\tools\rclone_cache_inspector.py --json
```

---

## 4. Test Suite

Unit tests are located in `E:\MediaServer\tests\test_cache_inspector.py`.
Run tests via:
```bash
python -m unittest E:/MediaServer/tests/test_cache_inspector.py -v
```

Covered test cases:
1. `test_format_bytes`: Byte unit conversion formatting.
2. `test_parse_iso_datetime`: ISO-8601 timezone parsing.
3. `test_cache_item_sparse_calculation`: Chunk sum & allocation ratio calculation.
4. `test_inspector_scan_and_summary`: Cache tree traversal and aggregate telemetry.
5. `test_lru_ordering`: Correct chronology sorting for LRU eviction.
6. `test_safe_purge_item`: File and meta cleanup.
7. `test_purge_protection_for_dirty_item`: Safeguards against un-uploaded files.
8. `test_purge_protection_for_locked_item`: WinFsp active lock detection & skip handling.
9. `test_purge_all_with_age_filter`: Time-bounded mass evictions.
