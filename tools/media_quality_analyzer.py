"""Media Stream & Container Quality Analyzer.

Production-grade media stream inspection and quality scoring engine for MediaServer:
- Utilizes FFprobe (and optional MediaInfo) to deeply inspect video containers (MKV, MP4, TS, etc.)
- Extracts video codec (HEVC/H.264/AV1/VP9/VVC), resolution, bit depth (8/10/12-bit), color matrix/transfer/primaries
- Parses HDR metadata (HDR10, HDR10+, Dolby Vision Profile & Level, Mastering Display Color Primaries, MaxCLL/MaxFALL)
- Inspects audio stream layout (7.1 TrueHD Atmos, 7.1 DTS-HD MA, 5.1 EAC3 Atmos, AC3, AAC, FLAC, Opus)
- Inspects subtitle stream formats (ASS/SSA, SubRip/SRT, PGS/HDMV, VobSub, WebVTT)
- Computes comprehensive JSON Quality Profile Scores (0-100), Tier Classifications (S, A, B, C, D),
  and flags unoptimized/problematic releases (e.g. 8-bit 4K HDR, bloated bitrate, lossy audio on 4K Remux,
  misconfigured color tags, slow image-based subtitles on web clients, missing HDR metadata).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("media_quality_analyzer")


# ---------------------------------------------------------------------------
# Data Models
# ---------------------------------------------------------------------------

@dataclass
class VideoStreamInfo:
    index: int
    codec_name: str
    codec_long_name: str
    profile: Optional[str] = None
    width: Optional[int] = None
    height: Optional[int] = None
    aspect_ratio: Optional[str] = None
    frame_rate: Optional[float] = None
    bit_rate: Optional[int] = None  # in bits/second
    bit_depth: int = 8
    pixel_format: Optional[str] = None
    color_space: Optional[str] = None
    color_transfer: Optional[str] = None
    color_primaries: Optional[str] = None
    is_hdr: bool = False
    hdr_format: Optional[str] = None  # HDR10, HDR10+, Dolby Vision, HLG, SDR
    dv_profile: Optional[int] = None
    dv_level: Optional[int] = None
    dv_rpu_present: bool = False
    mastering_display: Optional[Dict[str, Any]] = None  # primaries, white_point, min/max luminance
    max_cll: Optional[int] = None  # Max Content Light Level (cd/m2 or nits)
    max_fall: Optional[int] = None  # Max Frame-Average Light Level (cd/m2 or nits)


@dataclass
class AudioStreamInfo:
    index: int
    codec_name: str
    codec_long_name: str
    profile: Optional[str] = None
    channels: int = 2
    channel_layout: Optional[str] = None  # e.g., "7.1", "5.1(side)", "stereo"
    sample_rate: Optional[int] = None
    bit_rate: Optional[int] = None
    language: Optional[str] = None
    title: Optional[str] = None
    is_default: bool = False
    is_atmos: bool = False  # TrueHD Atmos or EAC3 Atmos
    is_lossless: bool = False  # TrueHD, DTS-HD MA, FLAC, PCM


@dataclass
class SubtitleStreamInfo:
    index: int
    codec_name: str  # subrip, ass, hdmv_pgs_subtitle, dvd_subtitle, webvtt
    language: Optional[str] = None
    title: Optional[str] = None
    is_default: bool = False
    is_forced: bool = False
    is_sdh: bool = False
    is_text_based: bool = True  # True if SRT/ASS/VTT; False if PGS/VobSub (image-based)


@dataclass
class ContainerMetadata:
    filename: str
    filepath: str
    format_name: str
    size_bytes: int
    duration_seconds: float
    overall_bit_rate: int
    video_tracks_count: int
    audio_tracks_count: int
    subtitle_tracks_count: int


@dataclass
class QualityScoreBreakdown:
    video_score: float = 0.0  # max 40
    audio_score: float = 0.0  # max 30
    hdr_score: float = 0.0    # max 20
    container_score: float = 0.0  # max 10
    penalties: float = 0.0
    total_score: float = 0.0   # 0 to 100
    tier: str = "C"            # S (90+), A (80-89), B (65-79), C (50-64), D (<50)


@dataclass
class AnalysisResult:
    container: ContainerMetadata
    video_streams: List[VideoStreamInfo] = field(default_factory=list)
    audio_streams: List[AudioStreamInfo] = field(default_factory=list)
    subtitle_streams: List[SubtitleStreamInfo] = field(default_factory=list)
    score: QualityScoreBreakdown = field(default_factory=QualityScoreBreakdown)
    optimization_flags: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    recommendations: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


# ---------------------------------------------------------------------------
# Stream & HDR Probing Logic
# ---------------------------------------------------------------------------

class FFprobeRunner:
    """Invokes ffprobe with JSON output to retrieve detailed stream and side data."""

    def __init__(self, ffprobe_binary: str = "ffprobe"):
        self.ffprobe_binary = ffprobe_binary or "ffprobe"

    def probe(self, file_path: str | Path) -> Dict[str, Any]:
        path_str = str(file_path)
        if not os.path.exists(path_str):
            raise FileNotFoundError(f"Media file not found: {path_str}")

        cmd = [
            self.ffprobe_binary,
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            "-show_error",
            "-show_chapters",
            path_str,
        ]

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return json.loads(result.stdout)
        except subprocess.CalledProcessError as e:
            logger.error("FFprobe execution failed: %s", e.stderr)
            raise RuntimeError(f"FFprobe failed to inspect {path_str}: {e.stderr}") from e
        except json.JSONDecodeError as e:
            logger.error("Failed to parse FFprobe JSON: %s", e)
            raise RuntimeError(f"Invalid JSON from FFprobe for {path_str}") from e


class MediaQualityAnalyzer:
    """Core media quality evaluation and container inspection engine."""

    def __init__(self, ffprobe_path: Optional[str] = None):
        self.ffprobe_path = ffprobe_path or shutil.which("ffprobe") or "ffprobe"
        self.runner = FFprobeRunner(self.ffprobe_path)

    def analyze_file(self, file_path: str | Path) -> AnalysisResult:
        """Inspects media file and returns complete AnalysisResult."""
        raw_probe = self.runner.probe(file_path)
        return self.parse_probe_data(raw_probe, str(file_path))

    def parse_probe_data(self, raw_data: Dict[str, Any], file_path: str) -> AnalysisResult:
        """Parses FFprobe raw dictionary into structured models and calculates score."""
        format_info = raw_data.get("format", {})
        streams_info = raw_data.get("streams", [])

        # Parse container summary
        size_bytes = int(format_info.get("size", 0))
        duration_s = float(format_info.get("duration", 0.0))
        bit_rate = int(format_info.get("bit_rate", 0)) if format_info.get("bit_rate") else 0
        if bit_rate == 0 and duration_s > 0 and size_bytes > 0:
            bit_rate = int((size_bytes * 8) / duration_s)

        video_streams: List[VideoStreamInfo] = []
        audio_streams: List[AudioStreamInfo] = []
        subtitle_streams: List[SubtitleStreamInfo] = []

        for st in streams_info:
            codec_type = st.get("codec_type")
            if codec_type == "video":
                # Skip attached picture streams (cover arts, thumbnails, posters)
                disposition = st.get("disposition", {})
                if disposition.get("attached_pic", 0) == 1:
                    continue
                v_info = self._parse_video_stream(st)
                video_streams.append(v_info)
            elif codec_type == "audio":
                a_info = self._parse_audio_stream(st)
                audio_streams.append(a_info)
            elif codec_type == "subtitle":
                s_info = self._parse_subtitle_stream(st)
                subtitle_streams.append(s_info)

        container = ContainerMetadata(
            filename=os.path.basename(file_path),
            filepath=os.path.abspath(file_path),
            format_name=format_info.get("format_name", "unknown"),
            size_bytes=size_bytes,
            duration_seconds=duration_s,
            overall_bit_rate=bit_rate,
            video_tracks_count=len(video_streams),
            audio_tracks_count=len(audio_streams),
            subtitle_tracks_count=len(subtitle_streams),
        )

        score, flags, warnings, recommendations = self._evaluate_quality(
            container, video_streams, audio_streams, subtitle_streams
        )

        return AnalysisResult(
            container=container,
            video_streams=video_streams,
            audio_streams=audio_streams,
            subtitle_streams=subtitle_streams,
            score=score,
            optimization_flags=flags,
            warnings=warnings,
            recommendations=recommendations,
        )

    # -----------------------------------------------------------------------
    # Stream Parsers
    # -----------------------------------------------------------------------

    def _parse_video_stream(self, st: Dict[str, Any]) -> VideoStreamInfo:
        index = int(st.get("index", 0))
        codec_name = st.get("codec_name", "").lower()
        codec_long_name = st.get("codec_long_name", "")
        profile = st.get("profile")
        width = st.get("width")
        height = st.get("height")
        aspect_ratio = st.get("display_aspect_ratio")

        # Frame rate calculation
        r_frame_rate = st.get("r_frame_rate", "0/0")
        frame_rate = None
        if "/" in str(r_frame_rate):
            num, den = r_frame_rate.split("/")
            if float(den) > 0:
                frame_rate = round(float(num) / float(den), 3)

        bit_rate = int(st.get("bit_rate")) if st.get("bit_rate") else None
        pix_fmt = st.get("pix_fmt", "")
        bit_depth = 8
        if "10" in pix_fmt or "p10" in pix_fmt or st.get("bits_per_raw_sample") in (10, "10"):
            bit_depth = 10
        elif "12" in pix_fmt or "p12" in pix_fmt or st.get("bits_per_raw_sample") in (12, "12"):
            bit_depth = 12
        elif "9" in pix_fmt:
            bit_depth = 9

        color_space = st.get("color_space")
        color_transfer = st.get("color_transfer")
        color_primaries = st.get("color_primaries")

        # HDR & DV detection
        is_hdr = False
        hdr_format = "SDR"
        dv_profile = None
        dv_level = None
        dv_rpu_present = False
        mastering_display: Optional[Dict[str, Any]] = None
        max_cll: Optional[int] = None
        max_fall: Optional[int] = None

        # Inspect side data list if present
        side_data_list = st.get("side_data_list", [])
        for sd in side_data_list:
            sd_type = sd.get("side_data_type", "")
            if "DOVI" in sd_type or "Dolby Vision" in sd_type:
                is_hdr = True
                dv_rpu_present = True
                dv_profile = sd.get("dv_profile")
                dv_level = sd.get("dv_level")
                hdr_format = f"Dolby Vision (Profile {dv_profile})" if dv_profile is not None else "Dolby Vision"
            elif "Mastering display metadata" in sd_type or "mastering_display" in sd_type.lower():
                is_hdr = True
                mastering_display = {
                    "red_x": sd.get("red_x"),
                    "red_y": sd.get("red_y"),
                    "green_x": sd.get("green_x"),
                    "green_y": sd.get("green_y"),
                    "blue_x": sd.get("blue_x"),
                    "blue_y": sd.get("blue_y"),
                    "white_point_x": sd.get("white_point_x"),
                    "white_point_y": sd.get("white_point_y"),
                    "min_luminance": sd.get("min_luminance"),
                    "max_luminance": sd.get("max_luminance"),
                }
            elif "Content light level metadata" in sd_type or "content_light_level" in sd_type.lower():
                is_hdr = True
                max_cll = sd.get("max_content")
                max_fall = sd.get("max_average")

        # Fallback inspection on color transfer / color space
        transfer_lower = (color_transfer or "").lower()
        primaries_lower = (color_primaries or "").lower()

        if "smpte2084" in transfer_lower or "arib-std-b67" in transfer_lower or "bt2020" in primaries_lower:
            is_hdr = True
            if "arib-std-b67" in transfer_lower:
                hdr_format = "HLG"
            elif "smpte2084" in transfer_lower:
                if hdr_format == "SDR":
                    hdr_format = "HDR10"

        # Check for HDR10+ tags in stream metadata
        tags = st.get("tags", {})
        for k, v in tags.items():
            if "hdr10+" in str(v).lower() or "hdr10plus" in str(v).lower():
                hdr_format = "HDR10+"
                is_hdr = True

        return VideoStreamInfo(
            index=index,
            codec_name=codec_name,
            codec_long_name=codec_long_name,
            profile=profile,
            width=width,
            height=height,
            aspect_ratio=aspect_ratio,
            frame_rate=frame_rate,
            bit_rate=bit_rate,
            bit_depth=bit_depth,
            pixel_format=pix_fmt,
            color_space=color_space,
            color_transfer=color_transfer,
            color_primaries=color_primaries,
            is_hdr=is_hdr,
            hdr_format=hdr_format,
            dv_profile=dv_profile,
            dv_level=dv_level,
            dv_rpu_present=dv_rpu_present,
            mastering_display=mastering_display,
            max_cll=max_cll,
            max_fall=max_fall,
        )

    def _parse_audio_stream(self, st: Dict[str, Any]) -> AudioStreamInfo:
        index = int(st.get("index", 0))
        codec_name = st.get("codec_name", "").lower()
        codec_long_name = st.get("codec_long_name", "")
        profile = st.get("profile")
        channels = int(st.get("channels", 2))
        channel_layout = st.get("channel_layout")
        sample_rate = int(st.get("sample_rate", 48000)) if st.get("sample_rate") else None
        bit_rate = int(st.get("bit_rate")) if st.get("bit_rate") else None

        tags = st.get("tags", {})
        language = tags.get("language")
        title = tags.get("title", "")
        disposition = st.get("disposition", {})
        is_default = disposition.get("default", 0) == 1

        # Atmos detection
        is_atmos = False
        if "atmos" in title.lower() or "atmos" in codec_long_name.lower():
            is_atmos = True

        # Lossless detection
        is_lossless = False
        if codec_name in ("truehd", "flac", "alac", "pcm_s16le", "pcm_s24le", "pcm_s32le"):
            is_lossless = True
        elif codec_name in ("dts", "dca") and profile and "ma" in profile.lower():
            is_lossless = True

        return AudioStreamInfo(
            index=index,
            codec_name=codec_name,
            codec_long_name=codec_long_name,
            profile=profile,
            channels=channels,
            channel_layout=channel_layout,
            sample_rate=sample_rate,
            bit_rate=bit_rate,
            language=language,
            title=title if title else None,
            is_default=is_default,
            is_atmos=is_atmos,
            is_lossless=is_lossless,
        )

    def _parse_subtitle_stream(self, st: Dict[str, Any]) -> SubtitleStreamInfo:
        index = int(st.get("index", 0))
        codec_name = st.get("codec_name", "").lower()
        tags = st.get("tags", {})
        language = tags.get("language")
        title = tags.get("title", "")
        disposition = st.get("disposition", {})
        is_default = disposition.get("default", 0) == 1
        is_forced = disposition.get("forced", 0) == 1
        is_sdh = "sdh" in title.lower() or "cc" in title.lower() or disposition.get("hearing_impaired", 0) == 1

        # Text-based vs image-based
        # Text: subrip (srt), ass, ssa, webvtt, mov_text
        # Image: hdmv_pgs_subtitle, dvd_subtitle, dvb_subtitle
        is_text = codec_name in ("subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text")

        return SubtitleStreamInfo(
            index=index,
            codec_name=codec_name,
            language=language,
            title=title if title else None,
            is_default=is_default,
            is_forced=is_forced,
            is_sdh=is_sdh,
            is_text_based=is_text,
        )

    # -----------------------------------------------------------------------
    # Quality Evaluation & Optimization Rule Engine
    # -----------------------------------------------------------------------

    def _evaluate_quality(
        self,
        container: ContainerMetadata,
        video_streams: List[VideoStreamInfo],
        audio_streams: List[AudioStreamInfo],
        subtitle_streams: List[SubtitleStreamInfo],
    ) -> Tuple[QualityScoreBreakdown, List[str], List[str], List[str]]:
        """Calculates granular quality score and applies heuristic lint rules."""
        flags: List[str] = []
        warnings: List[str] = []
        recommendations: List[str] = []

        video_score = 0.0
        audio_score = 0.0
        hdr_score = 0.0
        container_score = 10.0
        penalties = 0.0

        if not video_streams:
            flags.append("NO_VIDEO_STREAM")
            warnings.append("Container has no primary video stream.")
            return QualityScoreBreakdown(tier="D"), flags, warnings, recommendations

        primary_video = video_streams[0]
        width = primary_video.width or 0
        height = primary_video.height or 0

        # --- 1. Video Stream Evaluation (Max 40 pts) ---
        # Resolution tier
        is_4k = width >= 3800 or height >= 2100
        is_1080p = (width >= 1900 or height >= 1000) and not is_4k
        is_720p = (width >= 1200 or height >= 700) and not is_4k and not is_1080p

        if is_4k:
            video_score += 25.0
        elif is_1080p:
            video_score += 18.0
        elif is_720p:
            video_score += 10.0
        else:
            video_score += 4.0
            warnings.append(f"Low resolution detected: {width}x{height}.")

        # Video Codec Efficiency
        v_codec = primary_video.codec_name
        if v_codec in ("av1", "hevc", "h265", "vvc"):
            video_score += 10.0
        elif v_codec in ("h264", "avc"):
            video_score += 7.0
            if is_4k:
                flags.append("INEFFICIENT_4K_CODEC_H264")
                warnings.append("4K video encoded in legacy H.264 instead of HEVC or AV1.")
                recommendations.append("Transcode or replace with HEVC/AV1 for 50%+ bandwidth savings.")
                penalties += 5.0
        elif v_codec in ("vp9", "vp8"):
            video_score += 6.0
        elif v_codec in ("mpeg2video", "vc1", "wmv3", "mpeg4"):
            video_score += 2.0
            flags.append("LEGACY_OBSOLETE_VIDEO_CODEC")
            warnings.append(f"Legacy video codec: {v_codec}. Poor compression efficiency.")
            recommendations.append("Remux or re-encode using modern HEVC / AV1.")
            penalties += 8.0

        # Bit Depth
        if primary_video.bit_depth >= 10:
            video_score += 5.0
        else:
            if is_4k or primary_video.is_hdr:
                flags.append("8BIT_HDR_BANDING_RISK")
                warnings.append("4K/HDR release encoded in 8-bit color depth (high banding risk).")
                recommendations.append("Acquire 10-bit HDR master to prevent severe gradient banding.")
                penalties += 10.0

        video_score = min(40.0, video_score)

        # --- 2. Audio Stream Evaluation (Max 30 pts) ---
        if audio_streams:
            # Pick best audio track
            best_channels = max(a.channels for a in audio_streams)
            has_lossless = any(a.is_lossless for a in audio_streams)
            has_atmos = any(a.is_atmos for a in audio_streams)

            if best_channels >= 8:  # 7.1
                audio_score += 15.0
            elif best_channels >= 6:  # 5.1
                audio_score += 10.0
            else:
                audio_score += 5.0

            if has_atmos:
                audio_score += 10.0
            elif has_lossless:
                audio_score += 8.0
            else:
                audio_score += 4.0

            # Language / metadata check
            if any(a.language for a in audio_streams):
                audio_score += 5.0
            else:
                warnings.append("Audio streams are missing ISO language tags.")
                recommendations.append("Tag audio streams with proper language codes (e.g. 'eng', 'fra').")

            # Check if 4K Remux has poor audio
            if is_4k and container.overall_bit_rate > 35_000_000 and not has_lossless and not (best_channels >= 6):
                flags.append("HIGH_BITRATE_WEAK_AUDIO")
                warnings.append("High bitrate 4K container with only stereo/low-bitrate audio.")
        else:
            flags.append("NO_AUDIO_STREAM")
            warnings.append("Container has no audio streams.")
            penalties += 15.0

        audio_score = min(30.0, audio_score)

        # --- 3. HDR & Color Space Evaluation (Max 20 pts) ---
        if primary_video.is_hdr:
            if "Dolby Vision" in (primary_video.hdr_format or ""):
                hdr_score += 20.0
                if primary_video.dv_profile == 5:
                    # DV Profile 5 has no HDR10 fallback layer
                    flags.append("DV_PROFILE_5_FALLBACK_RISK")
                    warnings.append("Dolby Vision Profile 5 has no HDR10 base layer. Playback on non-DV screens will show magenta/green tint.")
                    recommendations.append("Ensure target client natively supports Dolby Vision Profile 5.")
                elif primary_video.dv_profile == 7:
                    flags.append("DV_PROFILE_7_DUAL_LAYER")
                elif primary_video.dv_profile == 8:
                    flags.append("DV_PROFILE_8_COMPATIBLE")
            elif "HDR10+" in (primary_video.hdr_format or ""):
                hdr_score += 18.0
            elif "HDR10" in (primary_video.hdr_format or "") or "HLG" in (primary_video.hdr_format or ""):
                hdr_score += 15.0

            # Check for missing mastering display metadata on HDR
            if not primary_video.mastering_display and not primary_video.max_cll:
                flags.append("MISSING_HDR_METADATA")
                warnings.append("HDR video stream is missing Mastering Display Color Primaries / MaxCLL metadata.")
                recommendations.append("Inject standard HDR10 SEI metadata for proper TV tone-mapping.")
        else:
            # SDR: full points if standard Rec.709 8-bit/10-bit
            hdr_score += 10.0

        hdr_score = min(20.0, hdr_score)

        # --- 4. Container & Subtitle Linting (Max 10 pts) ---
        container_ext = Path(container.filepath).suffix.lower()
        if container_ext not in (".mkv", ".mp4", ".m2ts"):
            flags.append("NON_STANDARD_CONTAINER")
            warnings.append(f"Non-standard container format: {container_ext}")
            penalties += 5.0

        # Subtitle analysis
        has_text_subs = any(s.is_text_based for s in subtitle_streams)
        has_image_subs = any(not s.is_text_based for s in subtitle_streams)

        if has_image_subs and not has_text_subs:
            flags.append("IMAGE_SUBTITLES_ONLY_PGS_VOBSUB")
            warnings.append("Only image-based subtitles (PGS/VobSub) found. Web browsers and mobile clients will require heavy CPU server-side transcoding to burn-in subtitles.")
            recommendations.append("Extract or download SRT / WebVTT text subtitles for direct play on all clients.")
            penalties += 4.0

        if subtitle_streams and not any(s.language for s in subtitle_streams):
            warnings.append("Subtitle streams lack language tags.")
            recommendations.append("Tag subtitle streams with correct language codes.")

        # Bitrate Bloat vs Starvation Check
        if is_4k:
            if container.overall_bit_rate > 100_000_000:
                flags.append("EXCESSIVE_BITRATE_OVER_100MBPS")
                warnings.append("Bitrate exceeds 100 Mbps, which may cause local network or VFS buffering.")
            elif container.overall_bit_rate < 8_000_000 and container.overall_bit_rate > 0:
                flags.append("STARVED_4K_BITRATE")
                warnings.append("4K bitrate is under 8 Mbps (high risk of compression artifacts and macroblocking).")
                penalties += 6.0
        elif is_1080p:
            if container.overall_bit_rate < 1_500_000 and container.overall_bit_rate > 0:
                flags.append("STARVED_1080P_BITRATE")
                warnings.append("1080p bitrate is under 1.5 Mbps.")
                penalties += 4.0

        container_score = max(0.0, container_score)

        # --- Compute Total Score & Tier ---
        total_raw = video_score + audio_score + hdr_score + container_score - penalties
        final_score = max(0.0, min(100.0, round(total_raw, 1)))

        if final_score >= 90.0:
            tier = "S"
        elif final_score >= 80.0:
            tier = "A"
        elif final_score >= 65.0:
            tier = "B"
        elif final_score >= 50.0:
            tier = "C"
        else:
            tier = "D"

        breakdown = QualityScoreBreakdown(
            video_score=video_score,
            audio_score=audio_score,
            hdr_score=hdr_score,
            container_score=container_score,
            penalties=penalties,
            total_score=final_score,
            tier=tier,
        )

        return breakdown, flags, warnings, recommendations


# ---------------------------------------------------------------------------
# CLI & Reporting
# ---------------------------------------------------------------------------

def format_human_report(result: AnalysisResult) -> str:
    """Formats the analysis result into a clean terminal report."""
    lines: List[str] = []
    sep = "=" * 65
    sub_sep = "-" * 65

    c = result.container
    v = result.video_streams[0] if result.video_streams else None
    s = result.score

    lines.append(sep)
    lines.append(f"  MEDIA CONTAINER QUALITY REPORT: {c.filename}")
    lines.append(sep)
    lines.append(f"• Container:    {c.format_name} | Size: {c.size_bytes / (1024*1024*1024):.2f} GB | Bitrate: {c.overall_bit_rate / 1_000_000:.1f} Mbps")
    lines.append(f"• Duration:     {int(c.duration_seconds // 3600):02d}:{int((c.duration_seconds % 3600) // 60):02d}:{int(c.duration_seconds % 60):02d}")
    lines.append(f"• Overall Tier: [{s.tier}] (Score: {s.total_score}/100)")
    lines.append(f"  └─ Video: {s.video_score}/40 | Audio: {s.audio_score}/30 | HDR: {s.hdr_score}/20 | Container: {s.container_score}/10 | Penalties: -{s.penalties}")
    lines.append(sub_sep)

    # Video Details
    if v:
        lines.append("▶ VIDEO STREAMS:")
        lines.append(f"  - Stream #{v.index}: {v.codec_name.upper()} ({v.codec_long_name})")
        lines.append(f"    Resolution: {v.width}x{v.height} ({v.aspect_ratio or 'N/A'}) @ {v.frame_rate or 0} fps")
        lines.append(f"    Color:      {v.bit_depth}-bit ({v.pixel_format}) | Space: {v.color_space} | Transfer: {v.color_transfer}")
        lines.append(f"    HDR Format: {v.hdr_format} (Is HDR: {v.is_hdr})")
        if v.dv_profile is not None:
            lines.append(f"    Dolby Vis:  Profile {v.dv_profile}, Level {v.dv_level} (RPU Present: {v.dv_rpu_present})")
        if v.max_cll or v.max_fall:
            lines.append(f"    Light Meta: MaxCLL: {v.max_cll} nits | MaxFALL: {v.max_fall} nits")
        if v.mastering_display:
            lines.append(f"    Mastering:  Min Lum: {v.mastering_display.get('min_luminance')} | Max Lum: {v.mastering_display.get('max_luminance')}")

    # Audio Details
    if result.audio_streams:
        lines.append("\n▶ AUDIO STREAMS:")
        for a in result.audio_streams:
            def_flag = " [DEFAULT]" if a.is_default else ""
            atmos_flag = " [ATMOS]" if a.is_atmos else ""
            lossless_flag = " [LOSSLESS]" if a.is_lossless else ""
            lang = f"[{a.language}] " if a.language else ""
            lines.append(f"  - Stream #{a.index}: {lang}{a.codec_name.upper()} ({a.channel_layout or f'{a.channels}ch'}) @ {a.sample_rate or 0}Hz{atmos_flag}{lossless_flag}{def_flag}")

    # Subtitle Details
    if result.subtitle_streams:
        lines.append("\n▶ SUBTITLE STREAMS:")
        for sub in result.subtitle_streams:
            text_badge = "TEXT" if sub.is_text_based else "IMAGE (PGS/VobSub)"
            forced = " [FORCED]" if sub.is_forced else ""
            sdh = " [SDH]" if sub.is_sdh else ""
            lines.append(f"  - Stream #{sub.index}: [{sub.language or 'und'}] {sub.codec_name.upper()} ({text_badge}){forced}{sdh}")

    # Flags & Warnings
    if result.optimization_flags:
        lines.append("\n⚠ OPTIMIZATION FLAGS TRIGGERED:")
        for flg in result.optimization_flags:
            lines.append(f"  [!] {flg}")

    if result.warnings:
        lines.append("\n⚠ LINT WARNINGS:")
        for w in result.warnings:
            lines.append(f"  - {w}")

    if result.recommendations:
        lines.append("\n✔ RECOMMENDATIONS:")
        for r in result.recommendations:
            lines.append(f"  + {r}")

    lines.append(sep)
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Media Quality & Stream Analyzer for Jellyfin / Emby / Plex Media Servers"
    )
    parser.add_argument("paths", nargs="+", help="Path to video file(s) or directories to inspect")
    parser.add_argument("--json", action="store_true", help="Output analysis in raw JSON format")
    parser.add_argument("--min-tier", choices=["S", "A", "B", "C", "D"], default=None, help="Exit with code 1 if tier is lower than specified")
    parser.add_argument("--ffprobe-path", default=None, help="Custom path to ffprobe executable")
    parser.add_argument("--recursive", "-r", action="store_true", help="Recursively inspect directories")
    args = parser.parse_args()

    analyzer = MediaQualityAnalyzer(ffprobe_path=args.ffprobe_path)
    files_to_inspect: List[Path] = []

    valid_exts = {".mkv", ".mp4", ".avi", ".mov", ".ts", ".m2ts", ".webm", ".wmv", ".m4v"}

    for p_str in args.paths:
        p = Path(p_str)
        if p.is_file():
            files_to_inspect.append(p)
        elif p.is_dir():
            pattern = "**/*" if args.recursive else "*"
            for child in p.glob(pattern):
                if child.is_file() and child.suffix.lower() in valid_exts:
                    files_to_inspect.append(child)

    if not files_to_inspect:
        logger.error("No valid video files found to analyze.")
        print("No valid video files found.", file=sys.stderr)
        return 1

    results: List[AnalysisResult] = []
    has_tier_failure = False
    tier_rank = {"S": 5, "A": 4, "B": 3, "C": 2, "D": 1}

    for target_file in files_to_inspect:
        try:
            res = analyzer.analyze_file(target_file)
            results.append(res)
            if args.min_tier:
                if tier_rank.get(res.score.tier, 0) < tier_rank.get(args.min_tier, 0):
                    has_tier_failure = True
        except Exception as e:
            logger.error("Error analyzing %s: %s", target_file, e)
            print(f"Error analyzing {target_file}: {e}", file=sys.stderr)

    if args.json:
        out_data = [r.to_dict() for r in results]
        print(json.dumps(out_data if len(out_data) > 1 else out_data[0], indent=2))
    else:
        for r in results:
            print(format_human_report(r))
            print()

    if has_tier_failure:
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
