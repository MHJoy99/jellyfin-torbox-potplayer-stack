# Media Stream & Container Quality Analyzer Architecture

The `media_quality_analyzer.py` engine is an advanced inspection, validation, and scoring system designed to analyze media streams (video, audio, subtitles, and container formats) within Jellyfin, Emby, Plex, and hybrid VFS cloud storage environments.

---

## 1. Overview & Core Objectives

Modern high-bitrate media streaming requires strict validation of container properties, video codec efficiency, color space configurations, HDR metadata injection, and multi-channel audio tracks. Misconfigured files cause unexpected client transcoding, purple/green color distortion, audio downmixing issues, and server CPU saturation.

### Key Capabilities
- **Video Stream Inspection**: Codec validation (`HEVC`, `AV1`, `H.264`, `VVC`, `VP9`), bit depth (`8-bit`, `10-bit`, `12-bit`), resolution detection (`4K UHD`, `1080p`, `720p`), chroma subsampling, and frame rate calculation.
- **HDR & Dolby Vision Metadata**: Extraction of SMPTE ST 2086 Mastering Display Color Primaries, ST 2086 Luminance (`min_luminance`, `max_luminance`), CTA-861-G MaxCLL / MaxFALL light levels, HLG curves, and Dolby Vision RPU profiles (Profile 5, Profile 7 Dual-Layer FEL/MEL, Profile 8.1).
- **Audio Stream Analysis**: Lossless audio identification (`TrueHD`, `DTS-HD MA`, `FLAC`), spatial object audio (`Dolby Atmos` over TrueHD or EAC3), channel topology (`7.1`, `5.1`, `stereo`), sample rates, and stream default/forced tagging.
- **Subtitle Linting**: Detection of text-based formats (`SubRip SRT`, `ASS/SSA`, `WebVTT`) versus image-based bitmaps (`PGS HDMV`, `VobSub`) that force server-side CPU subtitle burn-in on web browsers and mobile clients.
- **Quality Profile Scoring (0–100) & Tier Grading**:
  - **Tier S (90–100)**: Reference 4K HDR10+ / Dolby Vision 10-bit master with lossless multi-channel Atmos/DTS-HD MA and text subtitles.
  - **Tier A (80–89)**: High-quality 4K/1080p HEVC/AV1 encode with 5.1/7.1 audio and proper metadata.
  - **Tier B (65–79)**: Standard web release (1080p H.264/HEVC, EAC3/AAC audio).
  - **Tier C (50–64)**: Sub-optimal release (low bitrate, missing HDR metadata, bloated container).
  - **Tier D (<50)**: Unoptimized or problematic release (e.g. 8-bit 4K HDR banding, obsolete codecs like MPEG-2/VC-1, no audio tracks).

---

## 2. Architecture & Scoring Matrix

```
┌────────────────────────────────────────────────────────┐
│                   Input Media File                     │
│               (.mkv / .mp4 / .ts / .m2ts)              │
└───────────────────────────┬────────────────────────────┘
                            │
                   [ FFprobe Engine ]
           (Streams, Chapters, Side Data, Tags)
                            │
       ┌────────────────────┼────────────────────┐
       ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌─────────────────┐
│ Video Stream │    │ Audio Stream │    │ Subtitle Stream │
│  Inspection  │    │  Inspection  │    │   Inspection    │
└──────┬───────┘    └──────┬───────┘    └────────┬────────┘
       │                   │                     │
       └───────────────────┼─────────────────────┘
                           ▼
         ┌───────────────────────────────────┐
         │ Quality Scoring & Rule Engine     │
         │ - Video Points (Max 40)           │
         │ - Audio Points (Max 30)           │
         │ - HDR/Color Points (Max 20)       │
         │ - Container/Subtitle (Max 10)     │
         │ - Penalty System (Deductions)     │
         └─────────────────┬─────────────────┘
                           │
       ┌───────────────────┴───────────────────┐
       ▼                                       ▼
┌──────────────┐                       ┌──────────────┐
│ Human-Readable                       │ JSON Quality │
│ Terminal Card                        │ Score Payload│
└──────────────┘                       └──────────────┘
```

### Scoring Point Breakdown

| Category | Max Score | Evaluation Criteria |
| :--- | :--- | :--- |
| **Video Stream** | **40 pts** | • **Resolution**: 4K (+25), 1080p (+18), 720p (+10)<br>• **Codec**: AV1/HEVC/VVC (+10), H.264 (+7), VP9 (+6)<br>• **Bit Depth**: 10-bit / 12-bit (+5) |
| **Audio Stream** | **30 pts** | • **Channels**: 7.1/8ch (+15), 5.1/6ch (+10), Stereo (+5)<br>• **Format**: Dolby Atmos (+10), Lossless TrueHD/DTS-HD MA (+8), Lossy (+4)<br>• **Metadata**: Language tags present (+5) |
| **HDR & Color** | **20 pts** | • **Dolby Vision**: Profile 7/8 (+20)<br>• **HDR10+**: Dynamic ST 2094 metadata (+18)<br>• **HDR10 / HLG**: Static SMPTE ST 2084 (+15)<br>• **SDR**: Proper Rec.709 color matrix (+10) |
| **Container & Subtitles** | **10 pts** | • **Format**: Standard MKV / MP4 (+10)<br>• **Subtitles**: Text-based SRT/ASS (+0 penalty)<br>• **Bitrate**: Well-balanced bitrate within optimal compression envelope |

---

## 3. Unoptimized Release Flags & Heuristics

The engine flags common release defects:

1. `8BIT_HDR_BANDING_RISK`: HDR or 4K release encoded in 8-bit instead of 10-bit, causing severe banding artifacts on gradients.
2. `INEFFICIENT_4K_CODEC_H264`: 4K video encoded in legacy H.264 instead of HEVC or AV1.
3. `DV_PROFILE_5_FALLBACK_RISK`: Dolby Vision Profile 5 has no standard HDR10 base layer. Playback on non-DV screens results in purple/green color shifts.
4. `MISSING_HDR_METADATA`: HDR stream lacking mastering display color primaries or MaxCLL/MaxFALL metadata, degrading TV tone mapping.
5. `IMAGE_SUBTITLES_ONLY_PGS_VOBSUB`: Container has only bitmap PGS/VobSub subtitles. Browsers and mobile players require server-side video transcoding to display them.
6. `STARVED_4K_BITRATE` / `STARVED_1080P_BITRATE`: Excessively low bitrates (<8 Mbps for 4K, <1.5 Mbps for 1080p) that introduce macroblocking.
7. `EXCESSIVE_BITRATE_OVER_100MBPS`: Extremely bloated bitrates that can saturate 100M LAN interfaces or cloud VFS read streams.
8. `HIGH_BITRATE_WEAK_AUDIO`: 4K high-bitrate container accompanied only by low-quality stereo audio.

---

## 4. CLI Usage & Examples

### Basic Terminal Inspection
```bash
python E:\MediaServer\tools\media_quality_analyzer.py "D:\Movies\Dune.Part.Two.2024.2160p.UHD.BluRay.TrueHD.Atmos.7.1.DV.mkv"
```

### JSON Output Mode for Automated CI/CD or Scripts
```bash
python E:\MediaServer\tools\media_quality_analyzer.py --json "D:\Movies\Dune.Part.Two.2024.mkv"
```

### Automated Ingestion Quality Gate (`--min-tier`)
Fail and return exit code 2 if a release does not meet the minimum tier (e.g. Reject anything below Tier A):
```bash
python E:\MediaServer\tools\media_quality_analyzer.py --min-tier A "D:\Downloads\Incomplete_Release.mkv"
```

### Batch & Recursive Directory Scanning
```bash
python E:\MediaServer\tools\media_quality_analyzer.py -r "E:\MediaServer\test_media"
```

---

## 5. Sample JSON Output

```json
{
  "container": {
    "filename": "Dune.Part.Two.2024.2160p.Remux.mkv",
    "filepath": "/media/movies/Dune.Part.Two.2024.2160p.Remux.mkv",
    "format_name": "matroska,webm",
    "size_bytes": 62419128320,
    "duration_seconds": 9960.0,
    "overall_bit_rate": 50135846,
    "video_tracks_count": 1,
    "audio_tracks_count": 2,
    "subtitle_tracks_count": 3
  },
  "video_streams": [
    {
      "index": 0,
      "codec_name": "hevc",
      "codec_long_name": "H.265 / HEVC (High Efficiency Video Coding)",
      "profile": "Main 10",
      "width": 3840,
      "height": 2160,
      "aspect_ratio": "16:9",
      "frame_rate": 23.976,
      "bit_depth": 10,
      "pixel_format": "yuv420p10le",
      "color_space": "bt2020nc",
      "color_transfer": "smpte2084",
      "color_primaries": "bt2020",
      "is_hdr": true,
      "hdr_format": "Dolby Vision (Profile 7)",
      "dv_profile": 7,
      "dv_level": 6,
      "dv_rpu_present": true,
      "mastering_display": {
        "red_x": "34000/50000",
        "red_y": "16000/50000",
        "green_x": "13250/50000",
        "green_y": "34500/50000",
        "blue_x": "7500/50000",
        "blue_y": "3000/50000",
        "white_point_x": "15635/50000",
        "white_point_y": "16450/50000",
        "min_luminance": "50/10000",
        "max_luminance": "40000000/10000"
      },
      "max_cll": 1000,
      "max_fall": 400
    }
  ],
  "audio_streams": [
    {
      "index": 1,
      "codec_name": "truehd",
      "codec_long_name": "Dolby TrueHD with Dolby Atmos",
      "channels": 8,
      "channel_layout": "7.1",
      "sample_rate": 48000,
      "language": "eng",
      "title": "TrueHD Atmos 7.1",
      "is_default": true,
      "is_atmos": true,
      "is_lossless": true
    }
  ],
  "subtitle_streams": [
    {
      "index": 2,
      "codec_name": "subrip",
      "language": "eng",
      "title": "English SDH",
      "is_default": true,
      "is_forced": false,
      "is_sdh": true,
      "is_text_based": true
    }
  ],
  "score": {
    "video_score": 40.0,
    "audio_score": 30.0,
    "hdr_score": 20.0,
    "container_score": 10.0,
    "penalties": 0.0,
    "total_score": 100.0,
    "tier": "S"
  },
  "optimization_flags": [
    "DV_PROFILE_7_DUAL_LAYER"
  ],
  "warnings": [],
  "recommendations": []
}
```
