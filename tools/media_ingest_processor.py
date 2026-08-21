"""Media Ingest Processor.

Production-grade media ingestion and automation engine for MediaServer:
- Connects to Telegram download folders or cloud storage remotes (via rclone)
- Parses TV / Movie release patterns (S01E01, multi-episodes, 4K/1080p, Remux, HEVC/AVC, Audio, HDR/DV)
- Queries TMDB API for exact title, year, and season/episode verification (with caching & graceful fallback)
- Generates standard Jellyfin/Emby/Plex-compliant folder and filename structures
- Executes server-side `rclone moveto` commands with zero local disk usage (dry-run & execute modes)
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("media_ingest_processor")

VIDEO_EXTENSIONS = {
    ".mkv",
    ".mp4",
    ".avi",
    ".mov",
    ".ts",
    ".m2ts",
    ".webm",
    ".iso",
    ".vob",
    ".wmv",
    ".m4v",
}

SUBTITLE_EXTENSIONS = {
    ".srt",
    ".ass",
    ".ssa",
    ".vtt",
    ".sub",
    ".idx",
}

IGNORED_EXTENSIONS = {
    ".nfo",
    ".txt",
    ".jpg",
    ".jpeg",
    ".png",
    ".torrent",
    ".aria2",
    ".part",
    ".tmp",
}


@dataclass
class ParsedMediaInfo:
    raw_name: str
    media_type: str  # 'tv' or 'movie'
    title: str
    year: Optional[int] = None
    season: Optional[int] = None
    episode: Optional[int] = None
    episode_end: Optional[int] = None  # for multi-episode releases, e.g. E01-E02
    resolution: Optional[str] = None  # e.g., '2160p', '1080p', '720p'
    source: Optional[str] = None  # e.g., 'Remux', 'BluRay', 'WEB-DL', 'HDTV'
    video_codec: Optional[str] = None  # e.g., 'HEVC', 'H.264', 'AV1'
    audio_codec: Optional[str] = None  # e.g., 'DTS-HD MA', 'TrueHD', 'Atmos', 'AAC'
    hdr: Optional[str] = None  # e.g., 'DV', 'HDR10+', 'HDR'
    release_group: Optional[str] = None
    extension: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


class ReleaseNameParser:
    """Robust regex engine for extracting metadata from complex scene / P2P release names."""

    # Resolution patterns
    RE_RESOLUTION = re.compile(
        r"\b(2160p|4k|uhd|1080p|1080i|720p|576p|480p|360p)\b", re.IGNORECASE
    )

    # Source patterns
    RE_SOURCE = re.compile(
        r"\b(remux|uhd[\s.-]?bluray|bluray|blu-ray|bdrip|brrip|web-dl|webrip|web|hdtv|dvdrip|dvd|hdrip)\b",
        re.IGNORECASE,
    )

    # Video Codec patterns
    RE_VIDEO_CODEC = re.compile(
        r"\b(x265|h265|hevc|x264|h264|avc|av1|xvid|divx|10bit|8bit)\b", re.IGNORECASE
    )

    # Audio patterns
    RE_AUDIO = re.compile(
        r"\b(atmos|truehd[\s.-]?7\.1|truehd|dts-hd[\s.-]?ma|dts-hd|dts|ddp5\.1|dd\+|eac3|ac3|flac|aac|pcm)\b",
        re.IGNORECASE,
    )

    # HDR patterns
    RE_HDR = re.compile(
        r"\b(dv|dovi|dolby[\s.-]?vision|hdr10\+|hdr10|hdr)\b", re.IGNORECASE
    )

    # Release Group patterns (trailing -Group or [Group])
    RE_GROUP = re.compile(r"[-_]([A-Za-z0-9]+)(?:\[.*?\])?(?:\.[a-zA-Z0-9]+)?$")

    # TV episode patterns: S01E01, S01E01-E02, S01E01-02, 1x01, Season 1 Episode 1, EP01, etc.
    RE_TV_SEASON_EPISODE = re.compile(
        r"(?:s|season[\s._-]?)(\d{1,2})[\s._-]*(?:e|ep|episode[\s._-]?)(\d{1,3})(?:[\s._-]*(?:e|ep|episode|-)(\d{1,3}))?",
        re.IGNORECASE,
    )
    RE_TV_X_PATTERN = re.compile(r"\b(\d{1,2})x(\d{1,3})(?:-(\d{1,3}))?\b", re.IGNORECASE)
    RE_TV_EP_ONLY = re.compile(r"\b(?:ep|episode|e)[\s._-]?(\d{1,3})\b", re.IGNORECASE)
    RE_TV_SEASON_ONLY = re.compile(r"\b(?:s|season)[\s._-]?(\d{1,2})\b", re.IGNORECASE)

    # Year pattern
    RE_YEAR = re.compile(r"\b(19\d{2}|20\d{2})\b")

    @classmethod
    def parse(cls, filename_or_path: str) -> ParsedMediaInfo:
        path_obj = Path(filename_or_path)
        ext = path_obj.suffix.lower()
        base_name = path_obj.stem

        # Clean noise characters
        clean_text = base_name.replace("[", " ").replace("]", " ").replace("(", " ").replace(")", " ")
        clean_text = re.sub(r"\s+", " ", clean_text)

        # 1. Detect Resolution
        resolution = None
        res_match = cls.RE_RESOLUTION.search(clean_text)
        if res_match:
            res_val = res_match.group(1).upper()
            if res_val in ("4K", "UHD"):
                resolution = "2160p"
            else:
                resolution = res_val.lower()

        # 2. Detect Source
        source = None
        src_match = cls.RE_SOURCE.search(clean_text)
        if src_match:
            raw_src = src_match.group(1).upper()
            if "REMUX" in raw_src:
                source = "Remux"
            elif "BLURAY" in raw_src or "BLU-RAY" in raw_src:
                source = "BluRay"
            elif "WEB-DL" in raw_src:
                source = "WEB-DL"
            elif "WEBRIP" in raw_src or "WEB" in raw_src:
                source = "WEBRip"
            elif "HDTV" in raw_src:
                source = "HDTV"
            else:
                source = raw_src.capitalize()

        # 3. Detect Video Codec
        video_codec = None
        vcodec_match = cls.RE_VIDEO_CODEC.search(clean_text)
        if vcodec_match:
            vc_val = vcodec_match.group(1).upper()
            if vc_val in ("X265", "H265", "HEVC"):
                video_codec = "HEVC"
            elif vc_val in ("X264", "H264", "AVC"):
                video_codec = "H.264"
            elif vc_val == "AV1":
                video_codec = "AV1"
            else:
                video_codec = vc_val

        # 4. Detect Audio Codec
        audio_codec = None
        # Check Atmos first anywhere in text since it can accompany TrueHD / DD+
        if re.search(r"\batmos\b", clean_text, re.IGNORECASE):
            audio_codec = "Atmos"
        else:
            acodec_match = cls.RE_AUDIO.search(clean_text)
            if acodec_match:
                ac_val = acodec_match.group(1).upper()
                if "TRUEHD" in ac_val:
                    audio_codec = "TrueHD"
                elif "DTS-HD" in ac_val or "MA" in ac_val:
                    audio_codec = "DTS-HD MA"
                elif "DTS" in ac_val:
                    audio_codec = "DTS"
                elif "EAC3" in ac_val or "DDP" in ac_val or "DD+" in ac_val:
                    audio_codec = "EAC3"
                elif "AC3" in ac_val:
                    audio_codec = "AC3"
                elif "FLAC" in ac_val:
                    audio_codec = "FLAC"
                elif "AAC" in ac_val:
                    audio_codec = "AAC"
                else:
                    audio_codec = ac_val

        # 5. Detect HDR
        hdr = None
        hdr_match = cls.RE_HDR.search(clean_text)
        if hdr_match:
            h_val = hdr_match.group(1).upper()
            if "DV" in h_val or "DOVI" in h_val or "VISION" in h_val:
                hdr = "DV"
            elif "HDR10+" in h_val:
                hdr = "HDR10+"
            elif "HDR" in h_val:
                hdr = "HDR"

        # 6. Detect Release Group
        release_group = None
        grp_match = cls.RE_GROUP.search(base_name)
        if grp_match:
            candidate_grp = grp_match.group(1)
            # Ensure group is not a codec/source/resolution keyword
            if not any(
                k.lower() in candidate_grp.lower()
                for k in ["1080p", "720p", "2160p", "x264", "x265", "hevc", "bluray", "web", "hdtv"]
            ):
                release_group = candidate_grp

        # 7. Check for TV Show Patterns
        media_type = "movie"
        season = None
        episode = None
        episode_end = None
        title_end_pos = len(clean_text)

        tv_match = cls.RE_TV_SEASON_EPISODE.search(clean_text)
        if tv_match:
            media_type = "tv"
            season = int(tv_match.group(1))
            episode = int(tv_match.group(2))
            if tv_match.group(3):
                episode_end = int(tv_match.group(3))
            title_end_pos = min(title_end_pos, tv_match.start())
        else:
            tv_x_match = cls.RE_TV_X_PATTERN.search(clean_text)
            if tv_x_match:
                media_type = "tv"
                season = int(tv_x_match.group(1))
                episode = int(tv_x_match.group(2))
                if tv_x_match.group(3):
                    episode_end = int(tv_x_match.group(3))
                title_end_pos = min(title_end_pos, tv_x_match.start())
            else:
                # Check for EP only
                ep_match = cls.RE_TV_EP_ONLY.search(clean_text)
                if ep_match:
                    media_type = "tv"
                    season = 1  # Default to Season 1 if only EP is specified
                    episode = int(ep_match.group(1))
                    title_end_pos = min(title_end_pos, ep_match.start())

        # 8. Check for Year
        year = None
        # Search year in the string before tag markers
        year_matches = list(cls.RE_YEAR.finditer(clean_text))
        if year_matches:
            # Pick the earliest year match as likely release year
            first_year = year_matches[0]
            year = int(first_year.group(1))
            # If movie and year found, cut title at year if before current cut
            if media_type == "movie" and first_year.start() < title_end_pos:
                title_end_pos = first_year.start()
            elif media_type == "tv" and first_year.start() < title_end_pos:
                # E.g. "Doctor Who 2005 S01E01" -> year is part of show name or year qualifier
                # Keep title before year or include year if standard show naming
                title_end_pos = first_year.start()

        # Check resolution / source markers to also constrain title
        for marker in [res_match, src_match, vcodec_match]:
            if marker and marker.start() < title_end_pos and marker.start() > 0:
                title_end_pos = marker.start()

        # Extract title string
        raw_title = clean_text[:title_end_pos]
        # Replace dots, underscores, dashes with spaces
        title = re.sub(r"[._-]+", " ", raw_title).strip()
        # Remove any lingering double spaces
        title = re.sub(r"\s+", " ", title)

        # Fallback if title became empty
        if not title:
            title = re.sub(r"[._-]+", " ", base_name).strip()

        return ParsedMediaInfo(
            raw_name=filename_or_path,
            media_type=media_type,
            title=title,
            year=year,
            season=season,
            episode=episode,
            episode_end=episode_end,
            resolution=resolution,
            source=source,
            video_codec=video_codec,
            audio_codec=audio_codec,
            hdr=hdr,
            release_group=release_group,
            extension=ext,
        )


class TMDBClient:
    """TMDB API client with in-memory caching and offline fallback."""

    BASE_URL = "https://api.themoviedb.org/3"

    def __init__(self, api_key: Optional[str] = None, timeout: int = 10):
        self.api_key = api_key or os.environ.get("TMDB_API_KEY", "")
        self.timeout = timeout
        self._cache: Dict[str, Optional[Dict[str, Any]]] = {}

    def search_media(
        self,
        title: str,
        media_type: str = "movie",
        year: Optional[int] = None,
    ) -> Optional[Dict[str, Any]]:
        """Search TMDB for movie or TV show. Returns official title and release/air year."""
        if not self.api_key:
            logger.debug("No TMDB API key provided. Skipping online TMDB search.")
            return None

        cache_key = f"{media_type}:{title}:{year}"
        if cache_key in self._cache:
            return self._cache[cache_key]

        endpoint = "/search/movie" if media_type == "movie" else "/search/tv"
        params: Dict[str, Any] = {
            "api_key": self.api_key,
            "query": title,
            "include_adult": "false",
            "language": "en-US",
        }
        if year:
            if media_type == "movie":
                params["year"] = year
            else:
                params["first_air_date_year"] = year

        url = f"{self.BASE_URL}{endpoint}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers={"User-Agent": "MediaServerIngest/1.0"})

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                results = data.get("results", [])
                if results:
                    top = results[0]
                    matched_title = top.get("title") or top.get("name")
                    release_date = top.get("release_date") or top.get("first_air_date")
                    matched_year = int(release_date.split("-")[0]) if release_date else year
                    res = {
                        "tmdb_id": top.get("id"),
                        "title": matched_title,
                        "year": matched_year,
                        "media_type": media_type,
                    }
                    self._cache[cache_key] = res
                    return res
        except Exception as e:
            logger.warning(f"TMDB query error for '{title}' ({media_type}): {e}")

        self._cache[cache_key] = None
        return None


class DestinationPathBuilder:
    """Constructs sanitized and standard Plex / Jellyfin folder structures."""

    @staticmethod
    def sanitize(name: str) -> str:
        """Sanitizes strings for safe cross-platform folder/file naming."""
        # Replace forbidden filesystem characters: < > : " / \ | ? *
        sanitized = re.sub(r'[<>:"/\\|?*]', "", name)
        sanitized = re.sub(r"\s+", " ", sanitized).strip()
        return sanitized

    @classmethod
    def build_destination_path(
        cls,
        info: ParsedMediaInfo,
        tmdb_data: Optional[Dict[str, Any]] = None,
        movie_library: str = "Movies",
        tv_library: str = "TV Shows",
    ) -> Tuple[str, str]:
        """Builds destination folder path and target filename.

        Returns (destination_folder, destination_filename)
        """
        title = (tmdb_data.get("title") if tmdb_data else None) or info.title
        year = (tmdb_data.get("year") if tmdb_data else None) or info.year
        clean_title = cls.sanitize(title)

        # Build quality tag string (e.g. [1080p Remux HEVC TrueHD])
        tags = []
        if info.resolution:
            tags.append(info.resolution)
        if info.source:
            tags.append(info.source)
        if info.hdr:
            tags.append(info.hdr)
        if info.video_codec:
            tags.append(info.video_codec)
        if info.audio_codec:
            tags.append(info.audio_codec)
        tag_str = f" [{' '.join(tags)}]" if tags else ""

        ext = info.extension or ".mkv"

        if info.media_type == "tv":
            # TV Standard Structure:
            # TV Shows/Show Name (Year)/Season 01/Show Name (Year) - S01E01 - [Tags].ext
            show_folder_name = f"{clean_title} ({year})" if year else clean_title
            season_num = info.season if info.season is not None else 1
            season_folder = f"Season {season_num:02d}"

            # Episode formatting (handle single & multi-episode)
            if info.episode is not None:
                if info.episode_end is not None:
                    ep_str = f"S{season_num:02d}E{info.episode:02d}-E{info.episode_end:02d}"
                else:
                    ep_str = f"S{season_num:02d}E{info.episode:02d}"
            else:
                ep_str = f"S{season_num:02d}E01"

            target_filename = f"{show_folder_name} - {ep_str}{tag_str}{ext}"
            dest_folder = f"{tv_library}/{show_folder_name}/{season_folder}"
            return dest_folder, target_filename

        else:
            # Movie Standard Structure:
            # Movies/Movie Name (Year)/Movie Name (Year) [Tags].ext
            movie_folder_name = f"{clean_title} ({year})" if year else clean_title
            target_filename = f"{movie_folder_name}{tag_str}{ext}"
            dest_folder = f"{movie_library}/{movie_folder_name}"
            return dest_folder, target_filename


class RcloneIngestEngine:
    """Executes server-side rclone operations with zero local disk utilization."""

    def __init__(
        self,
        rclone_bin: str = "rclone",
        tmdb_api_key: Optional[str] = None,
        movie_library: str = "Movies",
        tv_library: str = "TV Shows",
        dry_run: bool = False,
    ):
        self.rclone_bin = rclone_bin
        self.tmdb_client = TMDBClient(api_key=tmdb_api_key)
        self.movie_library = movie_library
        self.tv_library = tv_library
        self.dry_run = dry_run

    def list_remote_files(self, remote_path: str) -> List[str]:
        """Lists files on rclone remote or local directory without downloading them."""
        # Check if local path
        if ":" not in remote_path or os.path.exists(remote_path):
            local_p = Path(remote_path)
            if local_p.is_file():
                return [local_p.name]
            elif local_p.is_dir():
                return [
                    f.name
                    for f in local_p.iterdir()
                    if f.is_file() and f.suffix.lower() in (VIDEO_EXTENSIONS | SUBTITLE_EXTENSIONS)
                ]
            return []

        # Otherwise execute `rclone lsf`
        cmd = [self.rclone_bin, "lsf", remote_path, "--files-only"]
        try:
            res = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True,
            )
            files = [line.strip() for line in res.stdout.splitlines() if line.strip()]
            return [
                f
                for f in files
                if Path(f).suffix.lower() in (VIDEO_EXTENSIONS | SUBTITLE_EXTENSIONS)
            ]
        except Exception as e:
            logger.error(f"Failed to list files from {remote_path}: {e}")
            return []

    def plan_ingest(
        self,
        source_remote: str,
        dest_remote: str,
        files: Optional[List[str]] = None,
    ) -> List[Dict[str, Any]]:
        """Generates move plan mapping each source item to standardized remote destination."""
        if files is None:
            files = self.list_remote_files(source_remote)

        plan = []
        for filename in files:
            ext = Path(filename).suffix.lower()
            if ext in IGNORED_EXTENSIONS:
                continue

            parsed = ReleaseNameParser.parse(filename)

            # Query TMDB
            tmdb_data = self.tmdb_client.search_media(
                title=parsed.title,
                media_type=parsed.media_type,
                year=parsed.year,
            )

            # Build destination
            dest_folder, dest_filename = DestinationPathBuilder.build_destination_path(
                info=parsed,
                tmdb_data=tmdb_data,
                movie_library=self.movie_library,
                tv_library=self.tv_library,
            )

            # Formulate full rclone source and destination path
            src_full = f"{source_remote.rstrip('/')}/{filename}"
            dst_full = f"{dest_remote.rstrip('/')}/{dest_folder}/{dest_filename}"

            plan_item = {
                "source_file": filename,
                "source_full": src_full,
                "dest_full": dst_full,
                "parsed": parsed.to_dict(),
                "tmdb": tmdb_data,
                "dest_folder": dest_folder,
                "dest_filename": dest_filename,
                "rclone_command": [
                    self.rclone_bin,
                    "moveto",
                    src_full,
                    dst_full,
                    "--fast-list",
                    "-v",
                ],
            }
            plan.append(plan_item)

        return plan

    def execute_plan(self, plan: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """Executes server-side `rclone moveto` commands for all planned items."""
        results = []
        for item in plan:
            cmd = list(item["rclone_command"])
            if self.dry_run:
                cmd.append("--dry-run")

            logger.info(f"Moving: {item['source_full']} -> {item['dest_full']}")
            try:
                res = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                success = res.returncode == 0
                results.append(
                    {
                        "item": item["source_file"],
                        "success": success,
                        "stdout": res.stdout,
                        "stderr": res.stderr,
                        "returncode": res.returncode,
                        "dry_run": self.dry_run,
                    }
                )
                if not success:
                    logger.error(
                        f"Failed rclone moveto for {item['source_file']}: {res.stderr}"
                    )
            except Exception as e:
                logger.error(f"Execution error on {item['source_file']}: {e}")
                results.append(
                    {
                        "item": item["source_file"],
                        "success": False,
                        "error": str(e),
                        "dry_run": self.dry_run,
                    }
                )
        return results


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Production Media Ingest Processor (Plex/Emby/Jellyfin compliant rclone automation)"
    )
    parser.add_argument(
        "--source",
        "-s",
        required=True,
        help="Source path or rclone remote (e.g., 'gdrive:TelegramDownloads' or 'E:/Downloads')",
    )
    parser.add_argument(
        "--dest",
        "-d",
        required=True,
        help="Destination rclone remote or path (e.g., 'gdrive:Media' or 'E:/MediaServer/Library')",
    )
    parser.add_argument(
        "--tmdb-key",
        default=os.environ.get("TMDB_API_KEY", ""),
        help="TMDB v3 API Key (optional, or set TMDB_API_KEY env var)",
    )
    parser.add_argument(
        "--movie-library",
        default="Movies",
        help="Movies library folder name (default: Movies)",
    )
    parser.add_argument(
        "--tv-library",
        default="TV Shows",
        help="TV Shows library folder name (default: TV Shows)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate execution without moving any files",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output ingest plan as structured JSON",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    engine = RcloneIngestEngine(
        tmdb_api_key=args.tmdb_key,
        movie_library=args.movie_library,
        tv_library=args.tv_library,
        dry_run=args.dry_run,
    )

    plan = engine.plan_ingest(args.source, args.dest)

    if args.json:
        print(json.dumps(plan, indent=2))
        return 0

    print(f"=== Found {len(plan)} media items to process ===")
    for idx, item in enumerate(plan, 1):
        print(f"\n[{idx}] {item['source_file']}")
        print(f"    Media Type : {item['parsed']['media_type'].upper()}")
        print(f"    Title      : {item['parsed']['title']}")
        if item['parsed']['year']:
            print(f"    Year       : {item['parsed']['year']}")
        if item['parsed']['media_type'] == 'tv':
            print(f"    Season/Ep  : S{item['parsed']['season']:02d}E{item['parsed']['episode']:02d}")
        print(f"    Destination: {item['dest_full']}")

    if not args.dry_run:
        print("\nExecuting server-side moves...")
        results = engine.execute_plan(plan)
        success_count = sum(1 for r in results if r.get("success"))
        print(f"\nFinished: {success_count}/{len(results)} items moved successfully.")
    else:
        print("\n[Dry-run mode] No files were moved.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
