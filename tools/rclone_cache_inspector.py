#!/usr/bin/env python3
"""
Rclone VFS Cache Inspector & LRU Eviction Management Tool
Inspects rclone VFS cache hierarchies, calculates sparse chunk allocation ratios,
identifies LRU eviction candidates, and safely purges cached items with WinFsp / Win32 lock detection.
"""

import os
import sys
import json
import time
import ctypes
import argparse
import datetime
from pathlib import Path
from typing import Dict, List, Tuple, Optional, Any


def get_sparse_allocated_size(filepath: str) -> int:
    """
    Get actual on-disk allocated byte size of a file (handles NTFS sparse files).
    Falls back to os.path.getsize if Win32 API is unavailable.
    """
    if os.name == 'nt':
        try:
            high_order = ctypes.c_ulong()
            low_order = ctypes.windll.kernel32.GetCompressedFileSizeW(
                str(filepath), ctypes.byref(high_order)
            )
            if low_order == 0xFFFFFFFF:
                err = ctypes.GetLastError()
                if err != 0:
                    return os.path.getsize(filepath)
            return (high_order.value << 32) + low_order
        except Exception:
            pass
    try:
        return os.path.getsize(filepath)
    except OSError:
        return 0


def check_file_lock(filepath: str) -> Tuple[bool, str]:
    """
    Check if a file is actively opened / locked by WinFsp, rclone mount, or media players.
    Returns (is_locked: bool, status_message: str).
    """
    if not os.path.exists(filepath):
        return False, "File does not exist"

    if os.name == 'nt':
        try:
            # GENERIC_READ (0x80000000) | GENERIC_WRITE (0x40000000)
            # ShareMode = 0 (exclusive access request to detect active handles)
            # OPEN_EXISTING = 3
            # FILE_ATTRIBUTE_NORMAL = 0x80
            handle = ctypes.windll.kernel32.CreateFileW(
                str(filepath),
                0x80000000 | 0x40000000,
                0,
                None,
                3,
                0x80,
                None
            )
            if handle == -1 or handle == 0xFFFFFFFFFFFFFFFF:
                err = ctypes.GetLastError()
                # Error 32: ERROR_SHARING_VIOLATION, Error 33: ERROR_LOCK_VIOLATION
                if err in (32, 33):
                    return True, f"Locked by active process (Win32 Sharing Violation #{err})"
                elif err == 5:
                    return True, "Access Denied / File in use (Win32 Error 5)"
                return True, f"Locked or inaccessible (Win32 Error #{err})"
            
            ctypes.windll.kernel32.CloseHandle(handle)
            return False, "Unlocked (Safe to purge)"
        except Exception as ex:
            return True, f"Error checking lock: {ex}"
    else:
        # Unix fallback: test opening for append
        try:
            with open(filepath, 'r+b'):
                pass
            return False, "Unlocked"
        except (IOError, OSError) as e:
            return True, f"Locked ({e})"


def format_bytes(size: float) -> str:
    """Format bytes into human-readable string."""
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    idx = 0
    curr = float(size)
    while curr >= 1024.0 and idx < len(units) - 1:
        curr /= 1024.0
        idx += 1
    return f"{curr:.2f} {units[idx]}"


def parse_iso_datetime(dt_str: Optional[str]) -> Optional[datetime.datetime]:
    """Parse ISO datetime string with robust timezone handling."""
    if not dt_str:
        return None
    try:
        # Standard fromisoformat handles +06:00, Z, etc.
        clean_str = dt_str.replace("Z", "+00:00")
        return datetime.datetime.fromisoformat(clean_str)
    except Exception:
        pass
    return None


class CacheItem:
    def __init__(self, rel_path: str, vfs_path: Optional[Path], meta_path: Optional[Path]):
        self.rel_path = rel_path
        self.vfs_path = vfs_path
        self.meta_path = meta_path
        self.nominal_size = 0
        self.disk_allocated_size = 0
        self.sparse_chunk_sum = 0
        self.chunk_count = 0
        self.is_dirty = False
        self.fingerprint = ""
        self.atime: Optional[datetime.datetime] = None
        self.mtime: Optional[datetime.datetime] = None
        self.atime_raw: str = ""
        self.mtime_raw: str = ""
        self.is_locked = False
        self.lock_reason = "Not Checked"
        self._load()

    def _load(self):
        # Load meta if available
        if self.meta_path and self.meta_path.is_file():
            try:
                with open(self.meta_path, 'r', encoding='utf-8', errors='ignore') as f:
                    data = json.load(f)
                    self.nominal_size = int(data.get("Size", 0))
                    self.is_dirty = bool(data.get("Dirty", False))
                    self.fingerprint = str(data.get("Fingerprint", ""))
                    self.atime_raw = data.get("ATime", "")
                    self.mtime_raw = data.get("ModTime", "")
                    self.atime = parse_iso_datetime(self.atime_raw)
                    self.mtime = parse_iso_datetime(self.mtime_raw)
                    rs = data.get("Rs", [])
                    self.chunk_count = len(rs)
                    self.sparse_chunk_sum = sum(int(c.get("Size", 0)) for c in rs)
            except Exception:
                pass

        # Load VFS file stats
        if self.vfs_path and self.vfs_path.is_file():
            if self.nominal_size == 0:
                try:
                    self.nominal_size = self.vfs_path.stat().st_size
                except OSError:
                    pass
            self.disk_allocated_size = get_sparse_allocated_size(str(self.vfs_path))
            
            # If atime was not in meta, fallback to filesystem atime/mtime
            if not self.atime:
                try:
                    st = self.vfs_path.stat()
                    self.atime = datetime.datetime.fromtimestamp(st.st_atime, tz=datetime.timezone.utc)
                    self.mtime = datetime.datetime.fromtimestamp(st.st_mtime, tz=datetime.timezone.utc)
                except OSError:
                    pass
        elif self.meta_path and self.sparse_chunk_sum > 0:
            self.disk_allocated_size = self.sparse_chunk_sum

    @property
    def effective_cached_size(self) -> int:
        """Effective physical bytes stored on disk."""
        if self.disk_allocated_size > 0:
            return self.disk_allocated_size
        return self.sparse_chunk_sum

    @property
    def sparse_ratio(self) -> float:
        """Percentage of file downloaded / allocated."""
        if self.nominal_size <= 0:
            return 100.0 if self.effective_cached_size > 0 else 0.0
        pct = (self.effective_cached_size / float(self.nominal_size)) * 100.0
        return min(pct, 100.0)

    def check_lock(self) -> Tuple[bool, str]:
        if self.vfs_path and self.vfs_path.exists():
            locked, msg = check_file_lock(str(self.vfs_path))
            self.is_locked = locked
            self.lock_reason = msg
            return locked, msg
        if self.meta_path and self.meta_path.exists():
            locked, msg = check_file_lock(str(self.meta_path))
            self.is_locked = locked
            self.lock_reason = msg
            return locked, msg
        return False, "File does not exist"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "rel_path": self.rel_path,
            "vfs_path": str(self.vfs_path) if self.vfs_path else None,
            "meta_path": str(self.meta_path) if self.meta_path else None,
            "nominal_size": self.nominal_size,
            "nominal_size_str": format_bytes(self.nominal_size),
            "allocated_size": self.effective_cached_size,
            "allocated_size_str": format_bytes(self.effective_cached_size),
            "sparse_ratio_pct": round(self.sparse_ratio, 2),
            "chunk_count": self.chunk_count,
            "is_dirty": self.is_dirty,
            "atime": self.atime.isoformat() if self.atime else self.atime_raw,
            "mtime": self.mtime.isoformat() if self.mtime else self.mtime_raw,
            "is_locked": self.is_locked,
            "lock_reason": self.lock_reason
        }


class RcloneCacheInspector:
    def __init__(self, cache_root: str):
        self.cache_root = Path(cache_root).resolve()
        self.vfs_root = self.cache_root / "vfs"
        self.meta_root = self.cache_root / "vfsMeta"
        self.items: List[CacheItem] = []

    def scan(self) -> List[CacheItem]:
        """Scan cache directory and index all cached files."""
        self.items = []
        found_paths: Dict[str, Dict[str, Path]] = {}

        # Scan VFS data files
        if self.vfs_root.exists() and self.vfs_root.is_dir():
            for root, _, files in os.walk(self.vfs_root):
                for f in files:
                    full_p = Path(root) / f
                    try:
                        rel = full_p.relative_to(self.vfs_root).as_posix()
                        if rel not in found_paths:
                            found_paths[rel] = {}
                        found_paths[rel]["vfs"] = full_p
                    except ValueError:
                        pass

        # Scan VFS meta files
        if self.meta_root.exists() and self.meta_root.is_dir():
            for root, _, files in os.walk(self.meta_root):
                for f in files:
                    full_p = Path(root) / f
                    try:
                        rel = full_p.relative_to(self.meta_root).as_posix()
                        if rel not in found_paths:
                            found_paths[rel] = {}
                        found_paths[rel]["meta"] = full_p
                    except ValueError:
                        pass

        for rel, paths in found_paths.items():
            item = CacheItem(
                rel_path=rel,
                vfs_path=paths.get("vfs"),
                meta_path=paths.get("meta")
            )
            self.items.append(item)

        return self.items

    def get_summary(self) -> Dict[str, Any]:
        """Calculate aggregate cache stats."""
        total_items = len(self.items)
        total_nominal = sum(it.nominal_size for it in self.items)
        total_allocated = sum(it.effective_cached_size for it in self.items)
        overall_sparse_ratio = (
            (total_allocated / float(total_nominal) * 100.0) if total_nominal > 0 else 0.0
        )
        dirty_items = sum(1 for it in self.items if it.is_dirty)

        return {
            "cache_root": str(self.cache_root),
            "total_items": total_items,
            "total_nominal_size": total_nominal,
            "total_nominal_size_str": format_bytes(total_nominal),
            "total_allocated_size": total_allocated,
            "total_allocated_size_str": format_bytes(total_allocated),
            "sparse_allocation_pct": round(overall_sparse_ratio, 2),
            "dirty_items": dirty_items
        }

    def get_lru_sorted(self) -> List[CacheItem]:
        """Return items sorted from oldest accessed to newest accessed."""
        min_dt = datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)
        return sorted(
            self.items,
            key=lambda x: (x.atime if x.atime is not None else min_dt)
        )

    def print_hierarchy(self, max_items: int = 50):
        """Display visual tree hierarchy and allocation details."""
        summary = self.get_summary()
        print("=" * 80)
        print(f" RCLONE VFS CACHE INSPECTOR - HIERARCHY")
        print(f" Root: {summary['cache_root']}")
        print(f" Total Cached Files: {summary['total_items']}")
        print(f" Total Nominal Size: {summary['total_nominal_size_str']}")
        print(f" Actual Disk Allocated: {summary['total_allocated_size_str']} ({summary['sparse_allocation_pct']}%)")
        print(f" Dirty (Un-uploaded) Files: {summary['dirty_items']}")
        print("=" * 80)

        if not self.items:
            print("  (No cached files found)")
            print("=" * 80)
            return

        print(f"{'Path':<45} | {'Nominal':<10} | {'Allocated':<10} | {'Cached %':<8} | {'Chunks':<6}")
        print("-" * 80)

        displayed = self.items[:max_items]
        for it in displayed:
            name_display = it.rel_path
            if len(name_display) > 43:
                name_display = "..." + name_display[-40:]
            nom = format_bytes(it.nominal_size)
            alloc = format_bytes(it.effective_cached_size)
            ratio = f"{it.sparse_ratio:.1f}%"
            chunks = str(it.chunk_count)
            print(f"{name_display:<45} | {nom:<10} | {alloc:<10} | {ratio:<8} | {chunks:<6}")

        if len(self.items) > max_items:
            print(f"... and {len(self.items) - max_items} more items.")
        print("=" * 80)

    def print_lru(self, limit: int = 20):
        """Display oldest items eligible for LRU eviction."""
        lru_list = self.get_lru_sorted()
        print("=" * 85)
        print(f" RCLONE VFS LRU EVICTION CANDIDATES (Oldest {min(limit, len(lru_list))} items)")
        print("=" * 85)
        if not lru_list:
            print("  (No items to display)")
            print("=" * 85)
            return

        print(f"{'#':<3} | {'Last Access (ATime)':<20} | {'Allocated':<10} | {'Dirty':<5} | {'Path'}")
        print("-" * 85)

        for i, it in enumerate(lru_list[:limit], 1):
            atime_str = it.atime.strftime("%Y-%m-%d %H:%M:%S") if it.atime else "Unknown"
            alloc = format_bytes(it.effective_cached_size)
            dirty_str = "YES" if it.is_dirty else "No"
            path_display = it.rel_path
            if len(path_display) > 40:
                path_display = "..." + path_display[-37:]
            print(f"{i:<3} | {atime_str:<20} | {alloc:<10} | {dirty_str:<5} | {path_display}")
        print("=" * 85)

    def purge_item(self, target_subpath: str, force: bool = False) -> Dict[str, Any]:
        """
        Safely purge a specific file or subpath matching rel_path.
        Checks WinFsp locks and dirty status before deletion.
        """
        # Find matching items
        target_norm = target_subpath.replace("\\", "/").strip("/")
        matching = [
            it for it in self.items
            if it.rel_path.replace("\\", "/").startswith(target_norm)
            or target_norm in it.rel_path.replace("\\", "/")
        ]

        if not matching:
            return {
                "success": False,
                "message": f"No cached items matched '{target_subpath}'",
                "purged_count": 0,
                "freed_bytes": 0,
                "skipped": []
            }

        purged_count = 0
        freed_bytes = 0
        skipped = []

        for it in matching:
            # Step 1: Check Dirty Flag
            if it.is_dirty and not force:
                skipped.append({
                    "path": it.rel_path,
                    "reason": "File is DIRTY (has un-uploaded modifications). Use --force to override."
                })
                continue

            # Step 2: Live WinFsp / OS lock check
            locked, lock_msg = it.check_lock()
            if locked and not force:
                skipped.append({
                    "path": it.rel_path,
                    "reason": f"File is LOCKED by active process ({lock_msg}). Use --force to override."
                })
                continue

            # Step 3: Remove VFS file & Meta file
            item_freed = it.effective_cached_size
            deleted_any = False
            try:
                if it.vfs_path and it.vfs_path.exists():
                    it.vfs_path.unlink()
                    deleted_any = True
                if it.meta_path and it.meta_path.exists():
                    it.meta_path.unlink()
                    deleted_any = True

                # Clean up empty parent directories
                for p in [it.vfs_path, it.meta_path]:
                    if p:
                        parent = p.parent
                        while parent not in (self.vfs_root, self.meta_root, self.cache_root) and parent.exists():
                            try:
                                if not any(parent.iterdir()):
                                    parent.rmdir()
                                    parent = parent.parent
                                else:
                                    break
                            except OSError:
                                break

                if deleted_any:
                    purged_count += 1
                    freed_bytes += item_freed
            except Exception as e:
                skipped.append({
                    "path": it.rel_path,
                    "reason": f"Failed to delete: {e}"
                })

        return {
            "success": purged_count > 0 or len(skipped) == 0,
            "message": f"Purged {purged_count} item(s), freed {format_bytes(freed_bytes)}.",
            "purged_count": purged_count,
            "freed_bytes": freed_bytes,
            "skipped": skipped
        }

    def purge_all(self, force: bool = False, older_than_days: Optional[float] = None) -> Dict[str, Any]:
        """
        Safely purge all items or items older than given threshold.
        """
        cutoff_dt = None
        if older_than_days is not None:
            cutoff_dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=older_than_days)

        purged_count = 0
        freed_bytes = 0
        skipped = []

        for it in self.items:
            # Filter by age if requested
            if cutoff_dt and it.atime and it.atime > cutoff_dt:
                continue

            # Check dirty
            if it.is_dirty and not force:
                skipped.append({
                    "path": it.rel_path,
                    "reason": "File is DIRTY (un-uploaded modifications)."
                })
                continue

            # Lock check
            locked, lock_msg = it.check_lock()
            if locked and not force:
                skipped.append({
                    "path": it.rel_path,
                    "reason": f"LOCKED: {lock_msg}"
                })
                continue

            item_freed = it.effective_cached_size
            deleted_any = False
            try:
                if it.vfs_path and it.vfs_path.exists():
                    it.vfs_path.unlink()
                    deleted_any = True
                if it.meta_path and it.meta_path.exists():
                    it.meta_path.unlink()
                    deleted_any = True

                for p in [it.vfs_path, it.meta_path]:
                    if p:
                        parent = p.parent
                        while parent not in (self.vfs_root, self.meta_root, self.cache_root) and parent.exists():
                            try:
                                if not any(parent.iterdir()):
                                    parent.rmdir()
                                    parent = parent.parent
                                else:
                                    break
                            except OSError:
                                break

                if deleted_any:
                    purged_count += 1
                    freed_bytes += item_freed
            except Exception as e:
                skipped.append({
                    "path": it.rel_path,
                    "reason": str(e)
                })

        return {
            "success": True,
            "message": f"Purged {purged_count} item(s), freed {format_bytes(freed_bytes)}.",
            "purged_count": purged_count,
            "freed_bytes": freed_bytes,
            "skipped": skipped
        }


def main():
    parser = argparse.ArgumentParser(
        description="Rclone VFS Cache Inspector & LRU Eviction Tool for Windows / Linux",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--cache-dir",
        default=r"F:\rclone-cache\gdrive-media",
        help="Path to rclone cache directory (default: F:\\rclone-cache\\gdrive-media)"
    )
    parser.add_argument(
        "--tree",
        action="store_true",
        help="Show file cache hierarchy with sparse allocation ratios"
    )
    parser.add_argument(
        "--lru",
        type=int,
        nargs="?",
        const=20,
        help="List oldest cached items eligible for LRU eviction (default top 20)"
    )
    parser.add_argument(
        "--check-locks",
        action="store_true",
        help="Perform live WinFsp / Win32 lock check on cached items"
    )
    parser.add_argument(
        "--purge-item",
        metavar="SUBPATH",
        help="Safely purge a specific file or directory from cache"
    )
    parser.add_argument(
        "--purge-all",
        action="store_true",
        help="Safely purge all unlocked, non-dirty items from cache"
    )
    parser.add_argument(
        "--older-than-days",
        type=float,
        help="Filter purge-all to items older than N days"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Override active lock and dirty warnings during purge"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results in structured JSON format"
    )

    args = parser.parse_args()

    inspector = RcloneCacheInspector(args.cache_dir)
    inspector.scan()

    if args.json:
        if args.purge_item:
            res = inspector.purge_item(args.purge_item, force=args.force)
            print(json.dumps(res, indent=2))
        elif args.purge_all:
            res = inspector.purge_all(force=args.force, older_than_days=args.older_than_days)
            print(json.dumps(res, indent=2))
        else:
            if args.check_locks:
                for it in inspector.items:
                    it.check_lock()
            data = {
                "summary": inspector.get_summary(),
                "items": [it.to_dict() for it in inspector.items],
                "lru": [it.to_dict() for it in inspector.get_lru_sorted()]
            }
            print(json.dumps(data, indent=2))
        return

    # CLI human-friendly execution
    if args.purge_item:
        print(f"\n[PURGE] Initiating purge for item matching: '{args.purge_item}' (Force: {args.force})")
        res = inspector.purge_item(args.purge_item, force=args.force)
        print(f"Status: {res['message']}")
        if res["skipped"]:
            print("\n[WARNING] Skipped items:")
            for s in res["skipped"]:
                print(f" - {s['path']}: {s['reason']}")
        return

    if args.purge_all:
        age_info = f" older than {args.older_than_days} days" if args.older_than_days else ""
        print(f"\n[PURGE] Initiating purge of all cache items{age_info} (Force: {args.force})...")
        res = inspector.purge_all(force=args.force, older_than_days=args.older_than_days)
        print(f"Status: {res['message']}")
        if res["skipped"]:
            print(f"\n[WARNING] Skipped {len(res['skipped'])} item(s):")
            for s in res["skipped"][:10]:
                print(f" - {s['path']}: {s['reason']}")
            if len(res["skipped"]) > 10:
                print(f"   ... and {len(res['skipped']) - 10} more.")
        return

    if args.check_locks:
        print("\n" + "=" * 80)
        print(" LIVE WIN32 / WINFSP LOCK STATUS CHECK")
        print("=" * 80)
        for it in inspector.items:
            locked, msg = it.check_lock()
            status_tag = "[LOCKED]  " if locked else "[UNLOCKED]"
            print(f"{status_tag} {it.rel_path} -> {msg}")
        print("=" * 80)
        return

    if args.lru is not None:
        inspector.print_lru(limit=args.lru)
        return

    # Default action: show hierarchy tree & summary
    inspector.print_hierarchy()
    inspector.print_lru(limit=5)


if __name__ == "__main__":
    main()
