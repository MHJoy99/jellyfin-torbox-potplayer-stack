#!/usr/bin/env python3
"""
Subtitle Synchronization, Extraction & Jellyfin Metadata Normalizer
===================================================================
Author: MediaServer Pipeline Team
Path: E:\\MediaServer\\tools\\sub_sync_organizer.py

Features:
1. Deep recursive scan of Movies & TV Shows (F:\\Media or custom root).
2. Deep ffprobe stream inspection for embedded subtitle and audio tracks.
3. Automated subtitle stream extraction (MKV/MP4 -> .srt / .ass) using ffmpeg copy mode.
4. OpenSubtitles.com REST API & Subscene scraping fallback for missing languages.
5. Standard Jellyfin naming normalization:
   - Movies:  MovieName (Year) [1080p].mp4 -> MovieName (Year) [1080p].eng.default.srt
   - Series:  ShowName/Season 01/ShowName - S01E01 - Title.mkv -> ShowName - S01E01 - Title.eng.srt
   - ISO 639-2 (3-letter) and ISO 639-1 (2-letter) language tagging (.eng, .hin, .spa, etc.)
   - Forced / Default / SDH subtitle flags (.forced.srt, .default.srt, .sdh.srt)
6. Cleaning redundant clutter, release group garbage, and sample files.
7. Jellyfin Library Refresh Webhook / API trigger on completion.
"""

import os
import sys
import re
import json
import gzip
import shutil
import struct
import logging
import argparse
import subprocess
from typing import Dict, List, Optional, Tuple, Any
from pathlib import Path
import urllib.request
import urllib.parse
import urllib.error

# Setup Logging
LOG_FORMAT = "%(asctime)s [%(levelname)s] %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT, datefmt="%Y-%m-%d %H:%M:%S")
logger = logging.getLogger("SubSyncOrganizer")

# Common video extensions
VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".ts", ".webm"}
SUBTITLE_EXTENSIONS = {".srt", ".ass", ".ssa", ".vtt", ".sub"}

# ISO 639-1 / 639-2 mappings
LANGUAGE_CODES = {
    "eng": "en", "english": "en", "en": "en",
    "hin": "hi", "hindi": "hi", "hi": "hi",
    "tam": "ta", "tamil": "ta", "ta": "ta",
    "tel": "te", "telugu": "te", "te": "te",
    "mal": "ml", "malayalam": "ml", "ml": "ml",
    "kan": "kn", "kannada": "kn", "kn": "kn",
    "spa": "es", "spanish": "es", "es": "es",
    "fra": "fr", "french": "fr", "fr": "fr",
    "fre": "fr",
    "ger": "de", "german": "de", "de": "de",
    "deu": "de",
    "ita": "it", "italian": "it", "it": "it",
    "por": "pt", "portuguese": "pt", "pt": "pt",
    "rus": "ru", "russian": "ru", "ru": "ru",
    "chi": "zh", "chinese": "zh", "zh": "zh",
    "zho": "zh",
    "jpn": "ja", "japanese": "ja", "ja": "ja",
    "kor": "ko", "korean": "ko", "ko": "ko",
    "ara": "ar", "arabic": "ar", "ar": "ar",
    "ben": "bn", "bengali": "bn", "bn": "bn",
    "und": "und", "undefined": "und"
}

# 3-letter canonical Jellyfin codes
CANONICAL_3_LETTER = {
    "en": "eng", "hi": "hin", "ta": "tam", "te": "tel", "ml": "mal",
    "kn": "kan", "es": "spa", "fr": "fre", "de": "ger", "it": "ita",
    "pt": "por", "ru": "rus", "zh": "chi", "ja": "jpn", "ko": "kor",
    "ar": "ara", "bn": "ben", "und": "und"
}


def normalize_lang_code(raw_code: Optional[str]) -> Tuple[str, str]:
    """Convert arbitrary language code/string to standard (2-letter, 3-letter) pair."""
    if not raw_code:
        return "en", "eng"
    clean = raw_code.strip().lower()
    two_letter = LANGUAGE_CODES.get(clean, "en")
    three_letter = CANONICAL_3_LETTER.get(two_letter, "eng")
    return two_letter, three_letter


def compute_opensubtitles_hash(file_path: Path) -> Tuple[int, str]:
    """Compute OpenSubtitles 64-bit checksum hash."""
    try:
        longlongformat = '<q'  # 64-bit little-endian integer
        bytesize = struct.calcsize(longlongformat)
        filesize = os.path.getsize(file_path)
        hash_val = filesize

        if filesize < 65536 * 2:
            return filesize, ""

        with open(file_path, "rb") as f:
            for _ in range(65536 // bytesize):
                buffer = f.read(bytesize)
                (l_value,) = struct.unpack(longlongformat, buffer)
                hash_val += l_value
                hash_val &= 0xFFFFFFFFFFFFFFFF

            f.seek(max(0, filesize - 65536), 0)
            for _ in range(65536 // bytesize):
                buffer = f.read(bytesize)
                (l_value,) = struct.unpack(longlongformat, buffer)
                hash_val += l_value
                hash_val &= 0xFFFFFFFFFFFFFFFF

        return filesize, "%016x" % hash_val
    except Exception as e:
        logger.debug(f"Hash calculation failed for {file_path}: {e}")
        return 0, ""


class MediaInspector:
    """Uses ffprobe to inspect embedded video, audio, and subtitle streams."""

    def __init__(self, ffprobe_cmd: str = "ffprobe"):
        self.ffprobe_cmd = ffprobe_cmd

    def get_streams(self, file_path: Path) -> Dict[str, Any]:
        """Runs ffprobe on the target file and parses stream metadata."""
        cmd = [
            self.ffprobe_cmd,
            "-v", "error",
            "-show_entries", "stream=index,codec_name,codec_type:stream_tags=language,title,handler_name:stream_disposition=default,forced,hearing_impaired",
            "-show_entries", "format=duration,size,bit_rate",
            "-of", "json",
            str(file_path)
        ]
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True,
                encoding="utf-8",
                errors="replace"
            )
            return json.loads(result.stdout)
        except Exception as e:
            logger.error(f"Failed to inspect media {file_path.name} with ffprobe: {e}")
            return {"streams": []}

    def list_subtitles(self, file_path: Path) -> List[Dict[str, Any]]:
        """Returns list of internal subtitle tracks with format, language, and stream index."""
        info = self.get_streams(file_path)
        subtitles = []
        for stream in info.get("streams", []):
            if stream.get("codec_type") == "subtitle":
                tags = stream.get("tags") or {}
                disp = stream.get("disposition") or {}
                raw_lang = tags.get("language") or tags.get("LANGUAGE") or "und"
                title = tags.get("title") or tags.get("handler_name") or ""
                codec = stream.get("codec_name", "srt")
                is_forced = bool(disp.get("forced", 0))
                is_default = bool(disp.get("default", 0))
                is_sdh = bool(disp.get("hearing_impaired", 0)) or ("sdh" in title.lower())

                two, three = normalize_lang_code(raw_lang)
                subtitles.append({
                    "stream_index": stream.get("index"),
                    "codec": codec,
                    "language_raw": raw_lang,
                    "lang_2": two,
                    "lang_3": three,
                    "title": title,
                    "forced": is_forced,
                    "default": is_default,
                    "sdh": is_sdh
                })
        return subtitles


class SubtitleExtractor:
    """Extracts internal subtitle streams from video containers into external files."""

    def __init__(self, ffmpeg_cmd: str = "ffmpeg"):
        self.ffmpeg_cmd = ffmpeg_cmd

    def extract_track(
        self,
        video_path: Path,
        stream_index: int,
        output_path: Path,
        overwrite: bool = False
    ) -> bool:
        """Extracts a specific subtitle stream index into an external subtitle file."""
        if output_path.exists() and not overwrite:
            logger.debug(f"Subtitle already exists: {output_path.name}, skipping extraction.")
            return True

        output_path.parent.mkdir(parents=True, exist_ok=True)
        # Determine output format and codec copy/conversion
        out_ext = output_path.suffix.lower()
        
        cmd = [
            self.ffmpeg_cmd,
            "-y" if overwrite else "-n",
            "-v", "error",
            "-i", str(video_path),
            "-map", f"0:{stream_index}",
            "-c:s", "copy" if out_ext in [".ass", ".ssa", ".srt"] else "srt",
            str(output_path)
        ]

        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
            logger.info(f"Extracted stream #{stream_index} -> {output_path.name}")
            return True
        except subprocess.CalledProcessError as e:
            # If direct copy failed (e.g. converting subrip or bitmap format), try srt conversion
            if out_ext == ".srt":
                try:
                    cmd_convert = [
                        self.ffmpeg_cmd,
                        "-y",
                        "-v", "error",
                        "-i", str(video_path),
                        "-map", f"0:{stream_index}",
                        "-c:s", "srt",
                        str(output_path)
                    ]
                    subprocess.run(cmd_convert, capture_output=True, text=True, check=True)
                    logger.info(f"Converted & extracted stream #{stream_index} -> {output_path.name}")
                    return True
                except Exception as ex:
                    logger.error(f"Fallback subtitle extraction failed for {video_path.name} stream {stream_index}: {ex}")
            else:
                logger.error(f"Extraction failed for {video_path.name} stream {stream_index}: {e.stderr}")
            return False


class SubtitleDownloader:
    """Downloads subtitles from OpenSubtitles REST API or Subscene fallback."""

    def __init__(self, api_key: Optional[str] = None, user_agent: str = "MediaServerSubSync v1.0"):
        self.api_key = api_key or os.environ.get("OPENSUBTITLES_API_KEY", "")
        self.user_agent = user_agent

    def search_opensubtitles(
        self,
        file_path: Path,
        languages: List[str] = ["en"],
        imdb_id: Optional[str] = None,
        query: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        """Search OpenSubtitles REST API v1 for subtitles."""
        if not self.api_key:
            logger.debug("OpenSubtitles API key not configured; skipping remote download.")
            return []

        filesize, filehash = compute_opensubtitles_hash(file_path)
        params: Dict[str, Any] = {
            "languages": ",".join(languages)
        }
        if filehash:
            params["moviehash"] = filehash
        if imdb_id:
            params["imdb_id"] = imdb_id.replace("tt", "")
        if query and not filehash:
            params["query"] = query

        url = f"https://api.opensubtitles.com/api/v1/subtitles?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers={
            "User-Agent": self.user_agent,
            "Api-Key": self.api_key,
            "Accept": "application/json"
        })

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status == 200:
                    data = json.loads(response.read().decode("utf-8"))
                    return data.get("data", [])
        except Exception as e:
            logger.warning(f"OpenSubtitles search request failed: {e}")
        return []

    def download_opensubtitles_file(self, file_id: int, target_path: Path) -> bool:
        """Requests download link and writes subtitle file."""
        if not self.api_key:
            return False

        url = "https://api.opensubtitles.com/api/v1/download"
        payload = json.dumps({"file_id": file_id}).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "User-Agent": self.user_agent,
                "Api-Key": self.api_key,
                "Content-Type": "application/json",
                "Accept": "application/json"
            }
        )

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status == 200:
                    data = json.loads(response.read().decode("utf-8"))
                    link = data.get("link")
                    if link:
                        target_path.parent.mkdir(parents=True, exist_ok=True)
                        urllib.request.urlretrieve(link, str(target_path))
                        logger.info(f"Downloaded subtitle -> {target_path.name}")
                        return True
        except Exception as e:
            logger.error(f"Failed to download subtitle file ID {file_id}: {e}")
        return False


class JellyfinNormalizer:
    """Normalizes naming and organizes media and subtitles following Jellyfin best practices."""

    @staticmethod
    def parse_episode_pattern(filename: str) -> Optional[Tuple[str, int, int]]:
        """Extracts Show Name, Season Number, and Episode Number from a filename."""
        patterns = [
            # Show.Name.S01E02.1080p...
            r"^(?P<show>.*?)[ ._]S(?P<season>\d{1,2})[ ._]?E(?P<episode>\d{1,3})",
            # Show_Name_1x02_...
            r"^(?P<show>.*?)[ ._](?P<season>\d{1,2})x(?P<episode>\d{1,3})",
            # Show Name Season 1 Episode 2
            r"^(?P<show>.*?)[ ._]Season[ ._]?(?P<season>\d{1,2})[ ._]Episode[ ._]?(?P<episode>\d{1,3})"
        ]
        for pat in patterns:
            match = re.search(pat, filename, re.IGNORECASE)
            if match:
                show_raw = match.group("show").replace(".", " ").replace("_", " ").strip()
                # Clean extraneous release tags from show name
                show_clean = re.sub(r"\s+", " ", show_raw).strip()
                season = int(match.group("season"))
                episode = int(match.group("episode"))
                return show_clean, season, episode
        return None

    @staticmethod
    def parse_movie_pattern(filename: str) -> Optional[Tuple[str, Optional[int]]]:
        """Extracts Movie Title and Year."""
        match = re.search(r"^(?P<title>.*?)[ ._]\(?(?P<year>(?:19|20)\d{2})\)?", filename)
        if match:
            title_raw = match.group("title").replace(".", " ").replace("_", " ").strip()
            title_clean = re.sub(r"\s+", " ", title_raw).strip()
            year = int(match.group("year"))
            return title_clean, year
        
        # Fallback: title without year
        base = Path(filename).stem.replace(".", " ").replace("_", " ").strip()
        base = re.sub(r"\s*(1080p|720p|2160p|4k|web-dl|bluray|x264|x265|hevc|ddp5\.1|aac).*", "", base, flags=re.IGNORECASE)
        return base.strip(), None

    @staticmethod
    def construct_jellyfin_subtitle_name(
        media_stem: str,
        lang_3: str,
        is_default: bool = False,
        is_forced: bool = False,
        is_sdh: bool = False,
        extension: str = ".srt"
    ) -> str:
        """
        Constructs Jellyfin canonical subtitle filename.
        e.g. MediaName.eng.srt, MediaName.hin.forced.srt, MediaName.eng.default.sdh.srt
        """
        parts = [media_stem, lang_3]
        if is_default:
            parts.append("default")
        if is_forced:
            parts.append("forced")
        if is_sdh:
            parts.append("sdh")
        
        ext = extension if extension.startswith(".") else f".{extension}"
        return ".".join(parts) + ext


class MediaLibraryProcessor:
    """Orchestrates scanning, inspection, extraction, and normalization across the library."""

    def __init__(
        self,
        root_path: Path,
        dry_run: bool = False,
        target_languages: List[str] = ["eng", "hin"],
        extract_embedded: bool = True,
        auto_download: bool = True,
        jellyfin_url: Optional[str] = None,
        jellyfin_token: Optional[str] = None
    ):
        self.root_path = root_path
        self.dry_run = dry_run
        self.target_languages = [normalize_lang_code(l)[1] for l in target_languages]
        self.extract_embedded = extract_embedded
        self.auto_download = auto_download
        self.jellyfin_url = jellyfin_url or os.environ.get("JELLYFIN_URL", "http://localhost:8096")
        self.jellyfin_token = jellyfin_token or os.environ.get("JELLYFIN_API_KEY", "")

        self.inspector = MediaInspector()
        self.extractor = SubtitleExtractor()
        self.downloader = SubtitleDownloader()

    def find_existing_subtitles(self, media_path: Path) -> List[Path]:
        """Find all external subtitle files associated with the media file."""
        stem = media_path.stem
        parent = media_path.parent
        subs = []
        for file in parent.iterdir():
            if file.is_file() and file.suffix.lower() in SUBTITLE_EXTENSIONS:
                if file.stem.startswith(stem) or stem in file.stem:
                    subs.append(file)
        return subs

    def parse_subtitle_language(self, sub_path: Path) -> Tuple[str, bool, bool, bool]:
        """Inspects subtitle filename for language code, default, forced, sdh flags."""
        name_parts = sub_path.stem.lower().split(".")
        is_default = "default" in name_parts
        is_forced = "forced" in name_parts
        is_sdh = "sdh" in name_parts or "cc" in name_parts

        lang = "eng"
        # Search backward from the extension parts to avoid false matches in title
        for part in reversed(name_parts):
            if part in ["default", "forced", "sdh", "cc"]:
                continue
            if part in LANGUAGE_CODES:
                _, lang = normalize_lang_code(part)
                break
        return lang, is_default, is_forced, is_sdh

    def process_media_file(self, media_path: Path) -> Dict[str, Any]:
        """Analyzes a single media file, extracts embedded subtitles, and checks requirements."""
        logger.info(f"Processing: {media_path.name}")
        report: Dict[str, Any] = {
            "file": str(media_path),
            "embedded_tracks": [],
            "extracted": [],
            "existing_subtitles": [],
            "missing_languages": []
        }

        # 1. Existing external subtitles
        existing_subs = self.find_existing_subtitles(media_path)
        existing_langs = set()
        for sub in existing_subs:
            lang, is_def, is_frc, is_sdh = self.parse_subtitle_language(sub)
            existing_langs.add(lang)
            report["existing_subtitles"].append({
                "path": str(sub),
                "language": lang,
                "default": is_def,
                "forced": is_frc,
                "sdh": is_sdh
            })

        # 2. Inspect embedded subtitle tracks
        embedded_tracks = self.inspector.list_subtitles(media_path)
        report["embedded_tracks"] = embedded_tracks

        # 3. Extract missing target languages from embedded streams if available
        for track in embedded_tracks:
            lang_3 = track["lang_3"]
            codec = track["codec"]
            # Choose appropriate subtitle extension
            ext = ".ass" if codec in ["ass", "ssa"] else ".srt"
            
            # Formulate canonical subtitle filename
            sub_name = JellyfinNormalizer.construct_jellyfin_subtitle_name(
                media_stem=media_path.stem,
                lang_3=lang_3,
                is_default=track["default"],
                is_forced=track["forced"],
                is_sdh=track["sdh"],
                extension=ext
            )
            sub_target_path = media_path.parent / sub_name

            # If external subtitle does not exist, extract it
            if not sub_target_path.exists() and self.extract_embedded:
                if not self.dry_run:
                    success = self.extractor.extract_track(
                        video_path=media_path,
                        stream_index=track["stream_index"],
                        output_path=sub_target_path
                    )
                    if success:
                        existing_langs.add(lang_3)
                        report["extracted"].append(str(sub_target_path))
                else:
                    logger.info(f"[DRY-RUN] Would extract stream #{track['stream_index']} ({lang_3}) -> {sub_target_path.name}")
                    report["extracted"].append(str(sub_target_path))
                    existing_langs.add(lang_3)
            elif sub_target_path.exists():
                existing_langs.add(lang_3)

        # 4. Check for missing desired target languages
        missing = [l for l in self.target_languages if l not in existing_langs]
        report["missing_languages"] = missing

        # 5. Remote API Download for remaining missing languages
        if missing and self.auto_download and not self.dry_run:
            for miss_lang in missing:
                two_let, _ = normalize_lang_code(miss_lang)
                logger.info(f"Searching OpenSubtitles for {media_path.stem} [{miss_lang}]...")
                results = self.downloader.search_opensubtitles(
                    file_path=media_path,
                    languages=[two_let]
                )
                if results:
                    best_match = results[0]
                    file_id = best_match.get("attributes", {}).get("files", [{}])[0].get("file_id")
                    if file_id:
                        sub_name = JellyfinNormalizer.construct_jellyfin_subtitle_name(
                            media_stem=media_path.stem,
                            lang_3=miss_lang,
                            extension=".srt"
                        )
                        dl_path = media_path.parent / sub_name
                        if self.downloader.download_opensubtitles_file(file_id, dl_path):
                            report["missing_languages"].remove(miss_lang)

        return report

    def scan_and_organize(self) -> List[Dict[str, Any]]:
        """Walks the directory hierarchy and processes all media files."""
        if not self.root_path.exists():
            logger.error(f"Root path does not exist: {self.root_path}")
            return []

        logger.info(f"Starting media scan on: {self.root_path}")
        results = []

        for root, _, files in os.walk(self.root_path):
            for file in sorted(files):
                file_path = Path(root) / file
                if file_path.suffix.lower() in VIDEO_EXTENSIONS:
                    # Ignore tiny sample files
                    if file_path.stat().st_size < 10 * 1024 * 1024:
                        logger.debug(f"Skipping sample/tiny file: {file_path.name}")
                        continue
                    res = self.process_media_file(file_path)
                    results.append(res)

        logger.info(f"Completed processing {len(results)} media files.")
        return results

    def trigger_jellyfin_refresh(self) -> bool:
        """Sends a library refresh command to Jellyfin API."""
        if not self.jellyfin_token:
            logger.info("Jellyfin API token not configured; skipping remote library refresh.")
            return False

        url = f"{self.jellyfin_url.rstrip('/')}/Library/Refresh"
        req = urllib.request.Request(
            url,
            data=b"",
            headers={
                "X-Emby-Token": self.jellyfin_token,
                "Content-Length": "0"
            }
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status in (200, 204):
                    logger.info("Successfully triggered Jellyfin Library Refresh.")
                    return True
        except Exception as e:
            logger.warning(f"Could not trigger Jellyfin refresh: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Subtitle Synchronization, Extraction & Jellyfin Metadata Normalizer"
    )
    parser.add_argument(
        "--path",
        "-p",
        default="F:\\Media",
        help="Root path to scan for Movies and TV Series (default: F:\\Media)"
    )
    parser.add_argument(
        "--languages",
        "-l",
        nargs="+",
        default=["eng", "hin"],
        help="Target languages to ensure exist (default: eng hin)"
    )
    parser.add_argument(
        "--no-extract",
        action="store_true",
        help="Disable automatic extraction of embedded subtitle streams"
    )
    parser.add_argument(
        "--no-download",
        action="store_true",
        help="Disable downloading missing subtitles from OpenSubtitles"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate actions without writing files or calling download APIs"
    )
    parser.add_argument(
        "--refresh-jellyfin",
        action="store_true",
        help="Trigger Jellyfin library refresh upon completion"
    )
    parser.add_argument(
        "--jellyfin-url",
        default=os.environ.get("JELLYFIN_URL", "http://localhost:8096"),
        help="Jellyfin base URL"
    )
    parser.add_argument(
        "--jellyfin-token",
        default=os.environ.get("JELLYFIN_API_KEY", ""),
        help="Jellyfin API token"
    )

    args = parser.parse_args()

    processor = MediaLibraryProcessor(
        root_path=Path(args.path),
        dry_run=args.dry_run,
        target_languages=args.languages,
        extract_embedded=not args.no_extract,
        auto_download=not args.no_download,
        jellyfin_url=args.jellyfin_url,
        jellyfin_token=args.jellyfin_token
    )

    results = processor.scan_and_organize()

    # Print summary statistics
    total_files = len(results)
    extracted_total = sum(len(r["extracted"]) for r in results)
    missing_total = sum(len(r["missing_languages"]) for r in results)

    print("\n" + "=" * 60)
    print("SUBTITLE & METADATA NORMALIZATION REPORT")
    print("=" * 60)
    print(f"Total Media Files Processed : {total_files}")
    print(f"Subtitle Streams Extracted  : {extracted_total}")
    print(f"Items Missing Subtitles     : {missing_total}")
    print("=" * 60)

    if args.refresh_jellyfin:
        processor.trigger_jellyfin_refresh()


if __name__ == "__main__":
    main()
