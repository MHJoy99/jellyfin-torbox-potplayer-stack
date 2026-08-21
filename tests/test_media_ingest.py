"""Unit and integration test suite for media_ingest_processor.py."""

import json
import unittest
from unittest.mock import MagicMock, patch

from tools.media_ingest_processor import (
    DestinationPathBuilder,
    ParsedMediaInfo,
    RcloneIngestEngine,
    ReleaseNameParser,
    TMDBClient,
)


class TestReleaseNameParser(unittest.TestCase):
    """Test scene release name pattern extraction."""

    def test_parse_tv_standard(self):
        filename = "Breaking.Bad.S01E01.Pilot.1080p.BluRay.x264-ROVERS.mkv"
        info = ReleaseNameParser.parse(filename)

        self.assertEqual(info.media_type, "tv")
        self.assertEqual(info.title, "Breaking Bad")
        self.assertEqual(info.season, 1)
        self.assertEqual(info.episode, 1)
        self.assertEqual(info.resolution, "1080p")
        self.assertEqual(info.source, "BluRay")
        self.assertEqual(info.video_codec, "H.264")
        self.assertEqual(info.extension, ".mkv")

    def test_parse_tv_multi_episode(self):
        filename = "Game.of.Thrones.S01E01-E02.2160p.UHD.Remux.DV.HEVC.TrueHD.Atmos-FLUX.mkv"
        info = ReleaseNameParser.parse(filename)

        self.assertEqual(info.media_type, "tv")
        self.assertEqual(info.title, "Game of Thrones")
        self.assertEqual(info.season, 1)
        self.assertEqual(info.episode, 1)
        self.assertEqual(info.episode_end, 2)
        self.assertEqual(info.resolution, "2160p")
        self.assertEqual(info.source, "Remux")
        self.assertEqual(info.hdr, "DV")
        self.assertEqual(info.video_codec, "HEVC")
        self.assertEqual(info.audio_codec, "Atmos")

    def test_parse_tv_alternate_patterns(self):
        # 1x05 pattern
        filename = "Severance.1x05.720p.WEB-DL.AAC.mp4"
        info = ReleaseNameParser.parse(filename)
        self.assertEqual(info.media_type, "tv")
        self.assertEqual(info.title, "Severance")
        self.assertEqual(info.season, 1)
        self.assertEqual(info.episode, 5)
        self.assertEqual(info.resolution, "720p")
        self.assertEqual(info.source, "WEB-DL")
        self.assertEqual(info.audio_codec, "AAC")

    def test_parse_movie_standard(self):
        filename = "Dune.Part.Two.2024.2160p.UHD.BluRay.x265.10bit.HDR.DTS-HD.MA.7.1-SPARKS.mkv"
        info = ReleaseNameParser.parse(filename)

        self.assertEqual(info.media_type, "movie")
        self.assertEqual(info.title, "Dune Part Two")
        self.assertEqual(info.year, 2024)
        self.assertEqual(info.resolution, "2160p")
        self.assertEqual(info.source, "BluRay")
        self.assertEqual(info.video_codec, "HEVC")
        self.assertEqual(info.hdr, "HDR")
        self.assertEqual(info.audio_codec, "DTS-HD MA")

    def test_parse_movie_remux_truehd(self):
        filename = "Oppenheimer.2023.REMUX.1080p.BluRay.AVC.TrueHD.7.1.Atmos-FGT.mkv"
        info = ReleaseNameParser.parse(filename)

        self.assertEqual(info.media_type, "movie")
        self.assertEqual(info.title, "Oppenheimer")
        self.assertEqual(info.year, 2023)
        self.assertEqual(info.source, "Remux")
        self.assertEqual(info.resolution, "1080p")
        self.assertEqual(info.video_codec, "H.264")
        self.assertEqual(info.audio_codec, "Atmos")


class TestDestinationPathBuilder(unittest.TestCase):
    """Test Jellyfin/Emby/Plex destination formatting."""

    def test_build_tv_destination(self):
        info = ParsedMediaInfo(
            raw_name="Loki.S02E01.1080p.WEB-DL.HEVC.mkv",
            media_type="tv",
            title="Loki",
            year=2021,
            season=2,
            episode=1,
            resolution="1080p",
            source="WEB-DL",
            video_codec="HEVC",
            extension=".mkv",
        )
        folder, filename = DestinationPathBuilder.build_destination_path(info)

        self.assertEqual(folder, "TV Shows/Loki (2021)/Season 02")
        self.assertEqual(
            filename,
            "Loki (2021) - S02E01 [1080p WEB-DL HEVC].mkv",
        )

    def test_build_movie_destination(self):
        info = ParsedMediaInfo(
            raw_name="Inception.2010.2160p.Remux.HEVC.DV.TrueHD.mkv",
            media_type="movie",
            title="Inception",
            year=2010,
            resolution="2160p",
            source="Remux",
            hdr="DV",
            video_codec="HEVC",
            audio_codec="TrueHD",
            extension=".mkv",
        )
        folder, filename = DestinationPathBuilder.build_destination_path(info)

        self.assertEqual(folder, "Movies/Inception (2010)")
        self.assertEqual(
            filename,
            "Inception (2010) [2160p Remux DV HEVC TrueHD].mkv",
        )

    def test_sanitize_characters(self):
        sanitized = DestinationPathBuilder.sanitize("Mission: Impossible / Dead Reckoning * 2023?")
        self.assertEqual(sanitized, "Mission Impossible Dead Reckoning 2023")


class TestTMDBClient(unittest.TestCase):
    """Test TMDB querying and caching logic."""

    @patch("urllib.request.urlopen")
    def test_search_media_success(self, mock_urlopen):
        mock_response = MagicMock()
        mock_response.read.return_value = json.dumps(
            {
                "results": [
                    {
                        "id": 157336,
                        "title": "Interstellar",
                        "release_date": "2014-11-05",
                    }
                ]
            }
        ).encode("utf-8")
        mock_response.__enter__.return_value = mock_response
        mock_urlopen.return_value = mock_response

        client = TMDBClient(api_key="mock_api_key")
        res = client.search_media(title="Interstellar", media_type="movie", year=2014)

        self.assertIsNotNone(res)
        self.assertEqual(res["title"], "Interstellar")
        self.assertEqual(res["year"], 2014)
        self.assertEqual(res["tmdb_id"], 157336)

        # Ensure caching works (mock called only once)
        cached_res = client.search_media(title="Interstellar", media_type="movie", year=2014)
        self.assertEqual(cached_res, res)
        mock_urlopen.assert_called_once()

    def test_search_media_no_key(self):
        client = TMDBClient(api_key="")
        res = client.search_media("Any Movie")
        self.assertIsNone(res)


class TestRcloneIngestEngine(unittest.TestCase):
    """Test rclone ingest planning and dry-run execution."""

    def test_plan_ingest(self):
        engine = RcloneIngestEngine(dry_run=True)
        files = [
            "The.Matrix.1999.2160p.Remux.HEVC.mkv",
            "Shogun.2024.S01E03.1080p.WEB-DL.H264.mkv",
            "sample.txt",  # Should be ignored
        ]

        plan = engine.plan_ingest(
            source_remote="gdrive:Downloads/Telegram",
            dest_remote="gdrive:Media",
            files=files,
        )

        self.assertEqual(len(plan), 2)

        matrix_item = plan[0]
        self.assertEqual(matrix_item["source_file"], "The.Matrix.1999.2160p.Remux.HEVC.mkv")
        self.assertEqual(
            matrix_item["dest_full"],
            "gdrive:Media/Movies/The Matrix (1999)/The Matrix (1999) [2160p Remux HEVC].mkv",
        )
        self.assertIn("moveto", matrix_item["rclone_command"])

        shogun_item = plan[1]
        self.assertEqual(shogun_item["source_file"], "Shogun.2024.S01E03.1080p.WEB-DL.H264.mkv")
        self.assertEqual(
            shogun_item["dest_full"],
            "gdrive:Media/TV Shows/Shogun (2024)/Season 01/Shogun (2024) - S01E03 [1080p WEB-DL H.264].mkv",
        )

    @patch("subprocess.run")
    def test_execute_plan(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0, stdout="Transferred successfully", stderr="")

        engine = RcloneIngestEngine(dry_run=False)
        files = ["Dune.2021.1080p.BluRay.x264.mkv"]
        plan = engine.plan_ingest("remote:src", "remote:dst", files=files)

        results = engine.execute_plan(plan)
        self.assertEqual(len(results), 1)
        self.assertTrue(results[0]["success"])
        mock_run.assert_called_once()


if __name__ == "__main__":
    unittest.main()
