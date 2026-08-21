#!/usr/bin/env python3
"""
Unit tests for rclone_cache_inspector tool.
Tests cache hierarchy scanning, sparse allocation calculations, LRU ordering,
WinFsp lock checks, and safe purge operations.
"""

import os
import sys
import json
import time
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

# Add tools directory to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

from rclone_cache_inspector import (
    RcloneCacheInspector,
    CacheItem,
    get_sparse_allocated_size,
    check_file_lock,
    format_bytes,
    parse_iso_datetime
)


class TestRcloneCacheInspector(unittest.TestCase):

    def setUp(self):
        # Create a mock cache root hierarchy
        self.temp_dir = tempfile.mkdtemp(prefix="test_rclone_cache_")
        self.cache_root = Path(self.temp_dir)
        self.vfs_dir = self.cache_root / "vfs" / "remote"
        self.meta_dir = self.cache_root / "vfsMeta" / "remote"
        self.vfs_dir.mkdir(parents=True, exist_ok=True)
        self.meta_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _create_mock_item(self, rel_path: str, size: int, chunks: list, atime_str: str, dirty: bool = False):
        vfs_file = self.vfs_dir / rel_path
        meta_file = self.meta_dir / rel_path
        vfs_file.parent.mkdir(parents=True, exist_ok=True)
        meta_file.parent.mkdir(parents=True, exist_ok=True)

        # Write dummy vfs payload
        with open(vfs_file, "wb") as f:
            f.write(b"\x00" * 1024)

        # Write meta JSON
        meta_data = {
            "ModTime": "2026-08-21T10:00:00+00:00",
            "ATime": atime_str,
            "Size": size,
            "Rs": chunks,
            "Fingerprint": f"{size},test-fp",
            "Dirty": dirty
        }
        with open(meta_file, "w", encoding="utf-8") as f:
            json.dump(meta_data, f, indent=2)

        return vfs_file, meta_file

    def test_format_bytes(self):
        self.assertEqual(format_bytes(500), "500.00 B")
        self.assertEqual(format_bytes(1024), "1.00 KB")
        self.assertEqual(format_bytes(1024 * 1024 * 5.5), "5.50 MB")
        self.assertEqual(format_bytes(1024 * 1024 * 1024 * 2), "2.00 GB")

    def test_parse_iso_datetime(self):
        dt1 = parse_iso_datetime("2026-08-21T20:05:59.692971+06:00")
        self.assertIsNotNone(dt1)
        self.assertEqual(dt1.year, 2026)
        self.assertEqual(dt1.hour, 20)

        dt2 = parse_iso_datetime("2026-08-21T14:05:59Z")
        self.assertIsNotNone(dt2)
        self.assertEqual(dt2.hour, 14)

        dt_none = parse_iso_datetime(None)
        self.assertIsNone(dt_none)

    def test_cache_item_sparse_calculation(self):
        chunks = [{"Pos": 0, "Size": 1000}, {"Pos": 5000, "Size": 2000}]
        vfs, meta = self._create_mock_item("Movies/sample.mkv", 10000, chunks, "2026-08-21T12:00:00+00:00")

        item = CacheItem("remote/Movies/sample.mkv", vfs, meta)
        self.assertEqual(item.nominal_size, 10000)
        self.assertEqual(item.chunk_count, 2)
        self.assertEqual(item.sparse_chunk_sum, 3000)
        self.assertFalse(item.is_dirty)
        self.assertGreaterEqual(item.sparse_ratio, 0.0)

    def test_inspector_scan_and_summary(self):
        self._create_mock_item("A.mkv", 100000, [{"Pos": 0, "Size": 10000}], "2026-08-21T10:00:00+00:00")
        self._create_mock_item("B.mkv", 200000, [{"Pos": 0, "Size": 40000}], "2026-08-21T12:00:00+00:00")

        inspector = RcloneCacheInspector(str(self.cache_root))
        items = inspector.scan()
        self.assertEqual(len(items), 2)

        summary = inspector.get_summary()
        self.assertEqual(summary["total_items"], 2)
        self.assertEqual(summary["total_nominal_size"], 300000)
        self.assertGreater(summary["total_allocated_size"], 0)

    def test_lru_ordering(self):
        self._create_mock_item("Old.mkv", 5000, [{"Pos": 0, "Size": 500}], "2026-08-20T08:00:00+00:00")
        self._create_mock_item("New.mkv", 5000, [{"Pos": 0, "Size": 500}], "2026-08-21T15:00:00+00:00")
        self._create_mock_item("Mid.mkv", 5000, [{"Pos": 0, "Size": 500}], "2026-08-21T10:00:00+00:00")

        inspector = RcloneCacheInspector(str(self.cache_root))
        inspector.scan()
        lru_list = inspector.get_lru_sorted()

        self.assertEqual(len(lru_list), 3)
        self.assertIn("Old.mkv", lru_list[0].rel_path)
        self.assertIn("Mid.mkv", lru_list[1].rel_path)
        self.assertIn("New.mkv", lru_list[2].rel_path)

    def test_safe_purge_item(self):
        vfs, meta = self._create_mock_item("DeleteMe.mkv", 5000, [{"Pos": 0, "Size": 1000}], "2026-08-20T08:00:00+00:00")
        self.assertTrue(vfs.exists())
        self.assertTrue(meta.exists())

        inspector = RcloneCacheInspector(str(self.cache_root))
        inspector.scan()

        res = inspector.purge_item("DeleteMe.mkv")
        self.assertTrue(res["success"])
        self.assertEqual(res["purged_count"], 1)
        self.assertFalse(vfs.exists())
        self.assertFalse(meta.exists())

    def test_purge_protection_for_dirty_item(self):
        vfs, meta = self._create_mock_item("Dirty.mkv", 5000, [{"Pos": 0, "Size": 1000}], "2026-08-20T08:00:00+00:00", dirty=True)

        inspector = RcloneCacheInspector(str(self.cache_root))
        inspector.scan()

        # Purge without force should skip dirty file
        res = inspector.purge_item("Dirty.mkv", force=False)
        self.assertEqual(res["purged_count"], 0)
        self.assertEqual(len(res["skipped"]), 1)
        self.assertTrue(vfs.exists())

        # Purge with force should succeed
        res_force = inspector.purge_item("Dirty.mkv", force=True)
        self.assertEqual(res_force["purged_count"], 1)
        self.assertFalse(vfs.exists())

    def test_purge_protection_for_locked_item(self):
        vfs, meta = self._create_mock_item("Locked.mkv", 5000, [{"Pos": 0, "Size": 1000}], "2026-08-20T08:00:00+00:00")

        inspector = RcloneCacheInspector(str(self.cache_root))
        inspector.scan()

        # Mock check_lock returning (True, "Locked by WinFsp")
        with patch.object(CacheItem, "check_lock", return_value=(True, "Locked by WinFsp")):
            res = inspector.purge_item("Locked.mkv", force=False)
            self.assertEqual(res["purged_count"], 0)
            self.assertEqual(len(res["skipped"]), 1)
            self.assertIn("LOCKED", res["skipped"][0]["reason"])
            self.assertTrue(vfs.exists())

            # Overriding with force
            res_force = inspector.purge_item("Locked.mkv", force=True)
            self.assertEqual(res_force["purged_count"], 1)
            self.assertFalse(vfs.exists())

    def test_purge_all_with_age_filter(self):
        self._create_mock_item("Old1.mkv", 5000, [{"Pos": 0, "Size": 500}], "2026-08-10T08:00:00+00:00")
        self._create_mock_item("Old2.mkv", 5000, [{"Pos": 0, "Size": 500}], "2026-08-12T08:00:00+00:00")
        self._create_mock_item("Recent.mkv", 5000, [{"Pos": 0, "Size": 500}], "2026-08-21T15:00:00+00:00")

        inspector = RcloneCacheInspector(str(self.cache_root))
        inspector.scan()

        # Purge items older than 2 days
        res = inspector.purge_all(older_than_days=2.0)
        self.assertTrue(res["success"])
        self.assertEqual(res["purged_count"], 2)


if __name__ == "__main__":
    unittest.main()
