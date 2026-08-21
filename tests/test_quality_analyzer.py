"""Unit tests for Media Quality Analyzer."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

# Ensure tools package is in path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest

from tools.media_quality_analyzer import (
    AnalysisResult,
    AudioStreamInfo,
    ContainerMetadata,
    FFprobeRunner,
    MediaQualityAnalyzer,
    QualityScoreBreakdown,
    SubtitleStreamInfo,
    VideoStreamInfo,
    format_human_report,
)


@pytest.fixture
def mock_4k_dv_atmos_probe() -> dict:
    return {
        "format": {
            "filename": "E:/MediaServer/test/Dune.Part.Two.2024.2160p.mkv",
            "format_name": "matroska,webm",
            "size": "53687091200",
            "duration": "9600.0",
            "bit_rate": "44739242",
        },
        "streams": [
            {
                "index": 0,
                "codec_type": "video",
                "codec_name": "hevc",
                "codec_long_name": "H.265 / HEVC",
                "profile": "Main 10",
                "width": 3840,
                "height": 2160,
                "display_aspect_ratio": "16:9",
                "r_frame_rate": "24000/1001",
                "pix_fmt": "yuv420p10le",
                "color_space": "bt2020nc",
                "color_transfer": "smpte2084",
                "color_primaries": "bt2020",
                "side_data_list": [
                    {
                        "side_data_type": "DOVI configuration record",
                        "dv_profile": 7,
                        "dv_level": 6,
                    },
                    {
                        "side_data_type": "Mastering display metadata",
                        "red_x": "34000/50000",
                        "red_y": "16000/50000",
                        "min_luminance": "50/10000",
                        "max_luminance": "40000000/10000",
                    },
                    {
                        "side_data_type": "Content light level metadata",
                        "max_content": 1000,
                        "max_average": 400,
                    },
                ],
            },
            {
                "index": 1,
                "codec_type": "audio",
                "codec_name": "truehd",
                "codec_long_name": "Dolby TrueHD with Dolby Atmos",
                "channels": 8,
                "channel_layout": "7.1",
                "sample_rate": "48000",
                "tags": {
                    "language": "eng",
                    "title": "Dolby TrueHD Atmos 7.1",
                },
                "disposition": {"default": 1},
            },
            {
                "index": 2,
                "codec_type": "subtitle",
                "codec_name": "subrip",
                "tags": {
                    "language": "eng",
                    "title": "English SDH",
                },
                "disposition": {"default": 1, "hearing_impaired": 1},
            },
        ],
    }


@pytest.fixture
def mock_unoptimized_8bit_hdr_probe() -> dict:
    return {
        "format": {
            "filename": "E:/MediaServer/test/Bad.Release.2160p.mkv",
            "format_name": "matroska",
            "size": "2000000000",
            "duration": "7200.0",
            "bit_rate": "2222222",  # Starved 4k
        },
        "streams": [
            {
                "index": 0,
                "codec_type": "video",
                "codec_name": "h264",
                "codec_long_name": "H.264 / AVC",
                "width": 3840,
                "height": 2160,
                "pix_fmt": "yuv420p",  # 8-bit
                "color_transfer": "smpte2084",  # HDR on 8-bit H264
                "color_primaries": "bt2020",
                "r_frame_rate": "24/1",
            },
            {
                "index": 1,
                "codec_type": "audio",
                "codec_name": "aac",
                "codec_long_name": "AAC (Advanced Audio Coding)",
                "channels": 2,
                "channel_layout": "stereo",
                "sample_rate": "44100",
                "tags": {},
            },
            {
                "index": 2,
                "codec_type": "subtitle",
                "codec_name": "hdmv_pgs_subtitle",  # PGS image-only
                "tags": {},
            },
        ],
    }


def test_4k_dv_atmos_analysis(mock_4k_dv_atmos_probe: dict):
    analyzer = MediaQualityAnalyzer()
    result = analyzer.parse_probe_data(mock_4k_dv_atmos_probe, "E:/MediaServer/test/Dune.Part.Two.2024.2160p.mkv")

    # Assert Video
    assert len(result.video_streams) == 1
    v = result.video_streams[0]
    assert v.codec_name == "hevc"
    assert v.width == 3840
    assert v.height == 2160
    assert v.bit_depth == 10
    assert v.is_hdr is True
    assert v.dv_profile == 7
    assert v.dv_rpu_present is True
    assert v.max_cll == 1000

    # Assert Audio
    assert len(result.audio_streams) == 1
    a = result.audio_streams[0]
    assert a.codec_name == "truehd"
    assert a.channels == 8
    assert a.is_atmos is True
    assert a.is_lossless is True
    assert a.language == "eng"

    # Assert Subtitles
    assert len(result.subtitle_streams) == 1
    sub = result.subtitle_streams[0]
    assert sub.codec_name == "subrip"
    assert sub.is_text_based is True
    assert sub.is_sdh is True

    # Assert Score & Tier
    assert result.score.tier == "S"
    assert result.score.total_score >= 90.0
    assert "DV_PROFILE_7_DUAL_LAYER" in result.optimization_flags
    assert len(result.warnings) == 0


def test_unoptimized_flags_detection(mock_unoptimized_8bit_hdr_probe: dict):
    analyzer = MediaQualityAnalyzer()
    result = analyzer.parse_probe_data(mock_unoptimized_8bit_hdr_probe, "E:/MediaServer/test/Bad.Release.2160p.mkv")

    v = result.video_streams[0]
    assert v.bit_depth == 8
    assert v.is_hdr is True

    # Assert unoptimized release flags
    assert "8BIT_HDR_BANDING_RISK" in result.optimization_flags
    assert "INEFFICIENT_4K_CODEC_H264" in result.optimization_flags
    assert "STARVED_4K_BITRATE" in result.optimization_flags
    assert "IMAGE_SUBTITLES_ONLY_PGS_VOBSUB" in result.optimization_flags
    assert "MISSING_HDR_METADATA" in result.optimization_flags

    # Score should be degraded heavily (Tier D or C)
    assert result.score.tier in ("C", "D")
    assert result.score.penalties > 15.0
    assert len(result.warnings) > 0
    assert len(result.recommendations) > 0


def test_human_report_formatting(mock_4k_dv_atmos_probe: dict):
    analyzer = MediaQualityAnalyzer()
    result = analyzer.parse_probe_data(mock_4k_dv_atmos_probe, "E:/MediaServer/test/Dune.Part.Two.2024.2160p.mkv")
    report = format_human_report(result)

    assert "MEDIA CONTAINER QUALITY REPORT" in report
    assert "[S]" in report
    assert "HEVC" in report
    assert "Dolby Vision" in report
    assert "TRUEHD" in report
    assert "[ATMOS]" in report
    assert "[LOSSLESS]" in report
    assert "SUBRIP (TEXT)" in report


def test_dv_profile_5_detection():
    raw_probe = {
        "format": {"filename": "test_dv5.mp4", "format_name": "mov,mp4,m4a", "size": "1000000", "duration": "100.0"},
        "streams": [
            {
                "index": 0,
                "codec_type": "video",
                "codec_name": "hevc",
                "width": 3840,
                "height": 2160,
                "pix_fmt": "yuv420p10le",
                "side_data_list": [
                    {"side_data_type": "DOVI configuration record", "dv_profile": 5, "dv_level": 6}
                ],
            },
            {
                "index": 1,
                "codec_type": "audio",
                "codec_name": "eac3",
                "channels": 6,
                "channel_layout": "5.1",
                "tags": {"title": "E-AC3 Atmos", "language": "eng"},
            }
        ]
    }
    analyzer = MediaQualityAnalyzer()
    res = analyzer.parse_probe_data(raw_probe, "test_dv5.mp4")
    assert "DV_PROFILE_5_FALLBACK_RISK" in res.optimization_flags
    assert res.audio_streams[0].is_atmos is True


def test_missing_streams():
    raw_probe = {
        "format": {"filename": "empty.mkv", "format_name": "matroska", "size": "0", "duration": "0"},
        "streams": []
    }
    analyzer = MediaQualityAnalyzer()
    res = analyzer.parse_probe_data(raw_probe, "empty.mkv")
    assert res.score.tier == "D"
    assert "NO_VIDEO_STREAM" in res.optimization_flags
