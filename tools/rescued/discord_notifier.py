#!/usr/bin/env python3
# RESCUED-FROM: archive/old-main-2026-08-21:tools/discord_notifier.py
# WHAT-CHANGED (cleaned for PUBLIC MIT repo):
#   - Added this header (origin + changes). All secrets already env-based (DISCORD_WEBHOOK_URL, TMDB_API_KEY); no hardcoded keys/tokens.
#   - Generalized branding: "Nexus Media ..." -> "Jellyfin Stack ..." (bot name, footers, server-name defaults, User-Agent).
#   - Generalized machine paths: --cache-dir/--log-path and helpers now default to $env:RCLONE_CACHE_DIR / $env:DB_BACKUP_LOG when set
#     (fallback keeps old example paths for compat; they are examples, not secrets).
#   - CLI --dry-run now also accepts --DryRun/--WhatIf aliases (safe preview: prints JSON payload, never POSTs).
#   - No new dependencies (stdlib only: argparse/datetime/json/logging/os/platform/re/shutil/socket/subprocess/sys/time/urllib/dataclasses/pathlib/typing).
#   - Send-only when webhook configured; without webhook (or with DryRun) it prints payload and exits 0 (safe by default).
# See docs/rescued.md for usage.

#!/usr/bin/env python3
"""
Discord Webhook Notifier for Jellyfin Stack
==================================================
Path: E:\\MediaServer\\tools\\discord_notifier.py

Provides production-grade Discord Webhook integration with rich, visually aesthetic
embed notifications for:
1. Media Ingest Events (New Movies & TV episodes with poster art, runtime, resolution, audio/video codecs, HDR tags)
2. Rclone VFS Cache & Low Disk Alerts (Cache capacity, mount health, free disk space thresholds)
3. Jellyfin Service Lifecycle & Crash Events (Process status, memory, uptime, crash/restart alerts)
4. Nightly SQLite VACUUM & Database Backup Summaries (Integrity check, compression ratios, cloud sync status)
5. Generic/Custom MediaServer Status Alerts & CLI trigger interface
"""

from __future__ import annotations

import argparse
import datetime
import json
import logging
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Union

# ---------------------------------------------------------------------------
# Logging Configuration
# ---------------------------------------------------------------------------
LOG_FORMAT = "%(asctime)s [%(levelname)s] [%(name)s] %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT, datefmt="%Y-%m-%d %H:%M:%S")
logger = logging.getLogger("DiscordNotifier")

# Windows console safety: prefer UTF-8 for emoji payloads; fall back gracefully on cp1252.
try:
    import sys as _sys
    if hasattr(_sys.stdout, "reconfigure"):
        _sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# ---------------------------------------------------------------------------
# Theme Colors & Discord Embed Palette
# ---------------------------------------------------------------------------
class DiscordColor:
    SUCCESS = 0x2ECC71      # Emerald Green
    INFO = 0x3498DB         # Deep Sky Blue
    WARNING = 0xF39C12      # Vibrant Orange
    ERROR = 0xE74C3C        # Crimson Red
    CRITICAL = 0x962D3E     # Dark Burgundy
    MEDIA_MOVIE = 0x9B59B6  # Amethyst Purple (Movies)
    MEDIA_TV = 0x1ABC9C     # Turquoise Teal (TV Shows)
    DATABASE = 0x34495E     # Midnight Slate (DB Maintenance)
    VFS_CACHE = 0x00BCD4    # Cyan (Storage & VFS Cache)
    JELLYFIN = 0xAA5CC8     # Jellyfin Brand Purple

# Default Assets & Fallback Icons
DEFAULT_BOT_USERNAME = "Jellyfin Stack Notifier"
DEFAULT_AVATAR_URL = "https://raw.githubusercontent.com/jellyfin/jellyfin-ux/master/branding/SVG/icon-transparent.svg"
DEFAULT_THUMBNAIL_JELLYFIN = "https://raw.githubusercontent.com/jellyfin/jellyfin-ux/master/branding/SVG/banner-dark.svg"


@dataclass
class DiscordEmbedField:
    name: str
    value: str
    inline: bool = True

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name[:256],
            "value": self.value[:1024] if self.value else "N/A",
            "inline": self.inline
        }


@dataclass
class DiscordEmbed:
    title: Optional[str] = None
    description: Optional[str] = None
    url: Optional[str] = None
    color: int = DiscordColor.INFO
    timestamp: Optional[str] = None
    footer_text: Optional[str] = None
    footer_icon_url: Optional[str] = None
    image_url: Optional[str] = None
    thumbnail_url: Optional[str] = None
    author_name: Optional[str] = None
    author_url: Optional[str] = None
    author_icon_url: Optional[str] = None
    fields: List[DiscordEmbedField] = field(default_factory=list)

    def add_field(self, name: str, value: Any, inline: bool = True) -> DiscordEmbed:
        if value is not None:
            self.fields.append(DiscordEmbedField(name=str(name), value=str(value), inline=inline))
        return self

    def to_dict(self) -> Dict[str, Any]:
        data: Dict[str, Any] = {"color": self.color}
        if self.title:
            data["title"] = self.title[:256]
        if self.description:
            data["description"] = self.description[:4096]
        if self.url:
            data["url"] = self.url
        if self.timestamp:
            data["timestamp"] = self.timestamp
        else:
            data["timestamp"] = datetime.datetime.now(datetime.timezone.utc).isoformat()

        if self.footer_text:
            footer: Dict[str, str] = {"text": self.footer_text[:2048]}
            if self.footer_icon_url:
                footer["icon_url"] = self.footer_icon_url
            data["footer"] = footer

        if self.image_url:
            data["image"] = {"url": self.image_url}

        if self.thumbnail_url:
            data["thumbnail"] = {"url": self.thumbnail_url}

        if self.author_name:
            author: Dict[str, str] = {"name": self.author_name[:256]}
            if self.author_url:
                author["url"] = self.author_url
            if self.author_icon_url:
                author["icon_url"] = self.author_icon_url
            data["author"] = author

        if self.fields:
            data["fields"] = [f.to_dict() for f in self.fields[:25]]

        return data


class DiscordWebhookClient:
    """Production client for dispatching asynchronous or synchronous Discord webhook payloads."""

    def __init__(
        self,
        webhook_url: Optional[str] = None,
        username: str = DEFAULT_BOT_USERNAME,
        avatar_url: str = DEFAULT_AVATAR_URL,
        timeout: int = 10,
        max_retries: int = 3,
        rate_limit_pause: float = 1.0,
    ):
        self.webhook_url = (webhook_url or os.environ.get("DISCORD_WEBHOOK_URL", "")).strip()
        self.username = username
        self.avatar_url = avatar_url
        self.timeout = timeout
        self.max_retries = max_retries
        self.rate_limit_pause = rate_limit_pause

    def send(
        self,
        content: Optional[str] = None,
        embeds: Optional[List[DiscordEmbed]] = None,
        dry_run: bool = False,
    ) -> bool:
        """Sends payload to Discord Webhook with automatic rate-limit backoff and retries."""
        payload: Dict[str, Any] = {
            "username": self.username,
            "avatar_url": self.avatar_url,
        }
        if content:
            payload["content"] = content[:2000]
        if embeds:
            payload["embeds"] = [e.to_dict() for e in embeds[:10]]

        if dry_run or not self.webhook_url:
            if not self.webhook_url:
                logger.warning("DISCORD_WEBHOOK_URL not configured. Outputting payload to stdout (dry-run mode).")
            else:
                logger.info("[DRY-RUN] Discord payload generated successfully.")
            try:
                print(json.dumps(payload, indent=2, ensure_ascii=False))
            except UnicodeEncodeError:
                # Windows cp1252 console cannot render emoji; fall back to ASCII-escaped JSON.
                print(json.dumps(payload, indent=2, ensure_ascii=True))
            return True

        data_bytes = json.dumps(payload).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "User-Agent": "JellyfinStack-DiscordNotifier/1.0",
        }

        for attempt in range(1, self.max_retries + 1):
            req = urllib.request.Request(self.webhook_url, data=data_bytes, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    if resp.status in (200, 204):
                        logger.info("Discord notification sent successfully.")
                        return True
                    logger.warning(f"Discord responded with HTTP {resp.status} on attempt {attempt}.")
            except urllib.error.HTTPError as e:
                # Handle Discord Rate Limiting (HTTP 429)
                if e.code == 429:
                    try:
                        err_body = json.loads(e.read().decode("utf-8", errors="ignore"))
                        retry_after = float(err_body.get("retry_after", self.rate_limit_pause))
                    except Exception:
                        retry_after = self.rate_limit_pause
                    logger.warning(f"Discord 429 Rate Limit encountered. Pausing for {retry_after:.2f}s before retry {attempt}/{self.max_retries}...")
                    time.sleep(retry_after)
                    continue
                else:
                    err_msg = e.read().decode("utf-8", errors="ignore")
                    logger.error(f"HTTP error sending Discord notification (Code {e.code}): {err_msg}")
                    return False
            except Exception as ex:
                logger.warning(f"Network error on attempt {attempt}/{self.max_retries}: {ex}")
                time.sleep(self.rate_limit_pause * attempt)

        logger.error(f"Failed to deliver Discord notification after {self.max_retries} attempts.")
        return False


# ===========================================================================
# TMDB Metadata & Media Probe Helpers
# ===========================================================================
class TMDBPosterResolver:
    """Fetches high-resolution poster art, backdrop images, overview, and runtime from TMDB."""

    BASE_URL = "https://api.themoviedb.org/3"
    IMAGE_BASE_URL = "https://image.tmdb.org/t/p/w500"
    BACKDROP_BASE_URL = "https://image.tmdb.org/t/p/original"

    def __init__(self, api_key: Optional[str] = None):
        self.api_key = api_key or os.environ.get("TMDB_API_KEY", "")

    def fetch_media_details(
        self,
        title: str,
        media_type: str = "movie",
        year: Optional[int] = None,
        season: Optional[int] = None,
        episode: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Queries TMDB for poster URL, backdrop, overview, runtime, rating, and genres."""
        if not self.api_key:
            return {}

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
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "JellyfinStack-Notifier/1.0"})
            with urllib.request.urlopen(req, timeout=8) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                results = data.get("results", [])
                if not results:
                    return {}

                top = results[0]
                tmdb_id = top.get("id")
                poster_path = top.get("poster_path")
                backdrop_path = top.get("backdrop_path")
                overview = top.get("overview", "")
                vote_avg = top.get("vote_average", 0.0)
                official_title = top.get("title") or top.get("name") or title
                release_date = top.get("release_date") or top.get("first_air_date") or ""

                poster_url = f"{self.IMAGE_BASE_URL}{poster_path}" if poster_path else None
                backdrop_url = f"{self.BACKDROP_BASE_URL}{backdrop_path}" if backdrop_path else None

                details: Dict[str, Any] = {
                    "tmdb_id": tmdb_id,
                    "title": official_title,
                    "release_date": release_date,
                    "overview": overview,
                    "vote_average": round(float(vote_avg), 1) if vote_avg else None,
                    "poster_url": poster_url,
                    "backdrop_url": backdrop_url,
                    "runtime_str": None,
                }

                # Fetch episode-specific metadata if TV show
                if media_type == "tv" and season is not None and episode is not None and tmdb_id:
                    ep_url = f"{self.BASE_URL}/tv/{tmdb_id}/season/{season}/episode/{episode}?api_key={self.api_key}&language=en-US"
                    try:
                        ep_req = urllib.request.Request(ep_url, headers={"User-Agent": "JellyfinStack-Notifier/1.0"})
                        with urllib.request.urlopen(ep_req, timeout=5) as ep_resp:
                            ep_data = json.loads(ep_resp.read().decode("utf-8"))
                            ep_still = ep_data.get("still_path")
                            if ep_still:
                                details["poster_url"] = f"{self.IMAGE_BASE_URL}{ep_still}"
                            details["episode_name"] = ep_data.get("name")
                            if ep_data.get("overview"):
                                details["overview"] = ep_data.get("overview")
                            if ep_data.get("runtime"):
                                details["runtime_str"] = f"{ep_data.get('runtime')} mins"
                    except Exception as ep_err:
                        logger.debug(f"Could not fetch episode TMDB detail: {ep_err}")

                # Fetch movie runtime if movie
                elif media_type == "movie" and tmdb_id:
                    movie_url = f"{self.BASE_URL}/movie/{tmdb_id}?api_key={self.api_key}&language=en-US"
                    try:
                        m_req = urllib.request.Request(movie_url, headers={"User-Agent": "JellyfinStack-Notifier/1.0"})
                        with urllib.request.urlopen(m_req, timeout=5) as m_resp:
                            m_data = json.loads(m_resp.read().decode("utf-8"))
                            runtime = m_data.get("runtime")
                            if runtime:
                                hours = runtime // 60
                                mins = runtime % 60
                                details["runtime_str"] = f"{hours}h {mins}m" if hours > 0 else f"{mins}m"
                    except Exception:
                        pass

                return details
        except Exception as e:
            logger.debug(f"TMDB metadata query failed for '{title}': {e}")
            return {}


class LocalMediaProbe:
    """Inspects local or mounted media files using ffprobe for exact resolution, audio, video codecs, and runtime."""

    @staticmethod
    def probe_file(file_path: Union[str, Path]) -> Dict[str, Any]:
        p = Path(file_path)
        if not p.exists() or not p.is_file():
            return {}

        cmd = [
            "ffprobe",
            "-v", "error",
            "-show_entries", "stream=codec_name,codec_type,width,height,channels,channel_layout:stream_tags=language,title:format=duration,size",
            "-of", "json",
            str(p)
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=True, encoding="utf-8", errors="replace")
            info = json.loads(res.stdout)
            streams = info.get("streams", [])
            fmt = info.get("format", {})

            video_stream = next((s for s in streams if s.get("codec_type") == "video"), {})
            audio_stream = next((s for s in streams if s.get("codec_type") == "audio"), {})

            width = video_stream.get("width")
            height = video_stream.get("height")
            res_tag = "1080p"
            if width and height:
                if width >= 3800 or height >= 2100:
                    res_tag = "4K UHD (2160p)"
                elif width >= 1900 or height >= 1000:
                    res_tag = "1080p Full HD"
                elif width >= 1200 or height >= 700:
                    res_tag = "720p HD"
                else:
                    res_tag = f"{height}p SD"

            v_codec = video_stream.get("codec_name", "").upper()
            if v_codec == "HEVC":
                v_codec = "HEVC / H.265"
            elif v_codec == "H264":
                v_codec = "AVC / H.264"
            elif v_codec == "AV1":
                v_codec = "AV1"

            a_codec = audio_stream.get("codec_name", "").upper()
            channels = audio_stream.get("channel_layout") or f"{audio_stream.get('channels', 2)}ch"
            a_tag = f"{a_codec} ({channels})" if a_codec else "AAC"

            duration_sec = float(fmt.get("duration", 0))
            runtime_str = None
            if duration_sec > 0:
                hours = int(duration_sec // 3600)
                mins = int((duration_sec % 3600) // 60)
                runtime_str = f"{hours}h {mins:02d}m" if hours > 0 else f"{mins}m"

            filesize_bytes = int(fmt.get("size", p.stat().st_size if p.exists() else 0))
            filesize_gb = round(filesize_bytes / (1024 ** 3), 2)

            return {
                "resolution": res_tag,
                "video_codec": v_codec,
                "audio_codec": a_tag,
                "runtime": runtime_str,
                "filesize_gb": filesize_gb,
            }
        except Exception as e:
            logger.debug(f"ffprobe probe failed for {p.name}: {e}")
            return {}


# ===========================================================================
# High-Level Event Notification Builders
# ===========================================================================
class DiscordNotificationBuilder:
    """Constructs tailored Discord Embeds for each core Jellyfin Stack event type."""

    @staticmethod
    def build_media_ingest_embed(
        title: str,
        media_type: str = "movie",
        year: Optional[int] = None,
        season: Optional[int] = None,
        episode: Optional[int] = None,
        episode_name: Optional[str] = None,
        resolution: Optional[str] = None,
        source: Optional[str] = None,
        video_codec: Optional[str] = None,
        audio_codec: Optional[str] = None,
        hdr: Optional[str] = None,
        runtime: Optional[str] = None,
        filesize: Optional[str] = None,
        destination_path: Optional[str] = None,
        poster_url: Optional[str] = None,
        overview: Optional[str] = None,
        vote_average: Optional[float] = None,
        jellyfin_url: Optional[str] = "http://localhost:8096",
    ) -> DiscordEmbed:
        """Builds an aesthetic Media Ingest notification embed with poster art and technical badges."""
        is_tv = media_type.lower() == "tv"
        color = DiscordColor.MEDIA_TV if is_tv else DiscordColor.MEDIA_MOVIE
        type_str = "TV Episode" if is_tv else "Movie"
        author_text = f"✨ Media Ingest Pipeline • New {type_str} Ready"

        if is_tv:
            s_num = season if season is not None else 1
            e_num = episode if episode is not None else 1
            ep_tag = f"S{s_num:02d}E{e_num:02d}"
            full_title = f"{title} ({year}) - {ep_tag}" if year else f"{title} - {ep_tag}"
            if episode_name:
                full_title += f": {episode_name}"
        else:
            full_title = f"{title} ({year})" if year else title

        embed = DiscordEmbed(
            title=f"🎬 {full_title}",
            description=overview[:300] + ("..." if overview and len(overview) > 300 else "") if overview else "New high-quality media asset ingested and indexed in Jellyfin library.",
            color=color,
            author_name=author_text,
            author_icon_url="https://raw.githubusercontent.com/jellyfin/jellyfin-ux/master/branding/SVG/icon-transparent.svg",
            thumbnail_url=poster_url,
            footer_text="Jellyfin Stack • Automated Ingestion Engine",
        )

        # Technical Badges Row 1
        embed.add_field("📺 Quality & Source", f"`{resolution or '1080p'}` • `{source or 'WEB-DL'}`", inline=True)
        
        # Audio / Video Codec Badges
        codec_str = f"`{video_codec or 'HEVC'}`"
        if hdr:
            codec_str += f" • `{hdr}`"
        embed.add_field("🎞️ Video / HDR", codec_str, inline=True)
        embed.add_field("🔊 Audio Stream", f"`{audio_codec or 'AAC'}`", inline=True)

        # Technical Badges Row 2
        if runtime:
            embed.add_field("⏱️ Runtime", f"`{runtime}`", inline=True)
        if filesize:
            embed.add_field("💾 File Size", f"`{filesize}`", inline=True)
        if vote_average:
            embed.add_field("⭐ Rating", f"**{vote_average}/10** (TMDB)", inline=True)

        if destination_path:
            embed.add_field("📂 Library Target", f"```{destination_path}```", inline=False)

        if jellyfin_url:
            embed.add_field("🚀 Quick Launch", f"[Open Jellyfin Dashboard]({jellyfin_url})", inline=False)

        return embed

    @staticmethod
    def build_rclone_vfs_embed(
        mount_drive: str = "X:",
        mount_status: str = "ONLINE",
        cache_dir: str = "E:\\MediaServer\\cache\\rclone_vfs",
        cache_used_gb: float = 0.0,
        cache_max_gb: float = 50.0,
        disk_drive: str = "E:",
        disk_free_gb: float = 0.0,
        disk_total_gb: float = 0.0,
        low_disk_threshold_gb: float = 15.0,
        active_transfers: int = 0,
        details: Optional[str] = None,
    ) -> DiscordEmbed:
        """Builds an Rclone VFS Cache status & low disk capacity alert embed."""
        is_low_disk = (disk_free_gb > 0 and disk_free_gb <= low_disk_threshold_gb)
        is_mount_down = mount_status.upper() not in ("ONLINE", "PASS", "HEALTHY", "MOUNTED")

        if is_mount_down:
            color = DiscordColor.CRITICAL
            status_title = "🚨 CRITICAL: Rclone VFS Mount Offline!"
            status_badge = "🔴 OFFLINE / DISCONNECTED"
        elif is_low_disk:
            color = DiscordColor.WARNING
            status_title = "⚠️ WARNING: Low Disk Space on Cache Volume!"
            status_badge = "🟡 LOW DISK WARNING"
        else:
            color = DiscordColor.VFS_CACHE
            status_title = "📊 Rclone VFS Storage & Cache Report"
            status_badge = "🟢 HEALTHY & OPERATIONAL"

        cache_pct = round((cache_used_gb / cache_max_gb) * 100, 1) if cache_max_gb > 0 else 0
        disk_used_gb = max(0.0, disk_total_gb - disk_free_gb)
        disk_pct = round((disk_used_gb / disk_total_gb) * 100, 1) if disk_total_gb > 0 else 0

        embed = DiscordEmbed(
            title=status_title,
            description=details or f"Real-time monitoring metrics for Rclone Cloud Mount `{mount_drive}` and NVMe VFS cache pool.",
            color=color,
            author_name="Jellyfin Stack • Rclone VFS Monitor",
            author_icon_url="https://rclone.org/img/logo_on_light__horizontal_color.svg",
            footer_text=f"Host: {socket.gethostname()} • Threshold: {low_disk_threshold_gb} GB Free",
        )

        embed.add_field("⚡ VFS Mount Status", f"**{status_badge}** (`{mount_drive}`)", inline=True)
        embed.add_field("🔄 Active Cloud IO", f"`{active_transfers} Transfers`", inline=True)
        embed.add_field("💽 Cache Dir", f"`{cache_dir}`", inline=False)

        cache_progress = f"`{cache_used_gb:.2f} GB` / `{cache_max_gb:.1f} GB` ({cache_pct}%)"
        embed.add_field("📦 VFS Cache Usage", cache_progress, inline=True)

        disk_progress = f"`{disk_free_gb:.2f} GB Free` / `{disk_total_gb:.1f} GB` ({100 - disk_pct:.1f}% free)"
        embed.add_field(f"💾 Drive `{disk_drive}` Capacity", disk_progress, inline=True)

        if is_low_disk:
            embed.add_field("⚠️ Action Needed", f"Free disk space on `{disk_drive}` dropped below safety threshold of `{low_disk_threshold_gb} GB`. VFS automatic purge triggered.", inline=False)

        return embed

    @staticmethod
    def build_jellyfin_service_embed(
        event_type: str,  # 'crash', 'restart', 'start', 'stop', 'heartbeat'
        server_name: str = "Jellyfin Server",
        jellyfin_url: str = "http://localhost:8096",
        version: str = "10.9.x",
        uptime_str: Optional[str] = None,
        memory_usage_mb: Optional[float] = None,
        cpu_pct: Optional[float] = None,
        active_streams: int = 0,
        error_message: Optional[str] = None,
    ) -> DiscordEmbed:
        """Builds a Jellyfin server service lifecycle alert (Crash, Restart, Heartbeat, Recovery)."""
        ev_lower = event_type.lower()
        if "crash" in ev_lower or "fail" in ev_lower:
            color = DiscordColor.CRITICAL
            icon = "🔥"
            title = f"{icon} ALERT: Jellyfin Service Crashed / Unresponsive!"
            desc = f"Jellyfin service failed healthcheck at `{jellyfin_url}`. Automated watchdog restart initiated."
        elif "restart" in ev_lower:
            color = DiscordColor.WARNING
            icon = "🔄"
            title = f"{icon} NOTICE: Jellyfin Service Restarted"
            desc = f"Jellyfin media server daemon has been recycled and re-initialized."
        elif "start" in ev_lower:
            color = DiscordColor.SUCCESS
            icon = "🚀"
            title = f"{icon} SUCCESS: Jellyfin Service Online"
            desc = f"Jellyfin media server is fully operational and listening on `{jellyfin_url}`."
        else:
            color = DiscordColor.JELLYFIN
            icon = "💓"
            title = f"{icon} Jellyfin Service Heartbeat"
            desc = f"Jellyfin service healthcheck status: All subsystems healthy."

        embed = DiscordEmbed(
            title=title,
            description=error_message or desc,
            color=color,
            author_name=f"{server_name} • Jellyfin Watchdog",
            author_icon_url="https://raw.githubusercontent.com/jellyfin/jellyfin-ux/master/branding/SVG/icon-transparent.svg",
            footer_text=f"Version: {version} • Host: {socket.gethostname()}",
        )

        embed.add_field("🌐 Server URL", f"[{jellyfin_url}]({jellyfin_url})", inline=True)
        embed.add_field("⚡ Event Type", f"`{event_type.upper()}`", inline=True)
        embed.add_field("👥 Active Streams", f"`{active_streams} direct/transcode`", inline=True)

        if memory_usage_mb is not None:
            embed.add_field("🧠 Memory Usage", f"`{memory_usage_mb:.1f} MB`", inline=True)
        if cpu_pct is not None:
            embed.add_field("⚙️ CPU Load", f"`{cpu_pct:.1f}%`", inline=True)
        if uptime_str:
            embed.add_field("⏱️ Service Uptime", f"`{uptime_str}`", inline=True)

        return embed

    @staticmethod
    def build_db_backup_embed(
        backup_archive_name: str,
        backup_size_mb: float,
        initial_size_mb: float,
        compacted_size_mb: float,
        compression_ratio_pct: float,
        integrity_status: str = "PASS",
        wal_checkpoint_status: str = "PASSIVE / TRUNCATED",
        retention_pruned_count: int = 0,
        cloud_sync_status: str = "SUCCESS (gdrive-backup:)",
        duration_seconds: float = 4.2,
        log_file: str = "E:\\MediaServer\\logs\\db_backup.log",
    ) -> DiscordEmbed:
        """Builds a comprehensive Nightly SQLite VACUUM & Backup Completion Summary embed."""
        is_pass = integrity_status.upper() in ("PASS", "PASSED", "OK", "SUCCESS")
        color = DiscordColor.SUCCESS if is_pass else DiscordColor.ERROR

        status_emoji = "✅" if is_pass else "❌"
        title = f"{status_emoji} Nightly SQLite VACUUM & Backup Completed" if is_pass else f"{status_emoji} CRITICAL: Database Backup / VACUUM Failed!"

        embed = DiscordEmbed(
            title=title,
            description="Automated zero-downtime SQLite WAL checkpoint, `VACUUM INTO` live snapshot, and encrypted cloud rotation summary.",
            color=color,
            author_name="Jellyfin Stack • Database Maintenance",
            author_icon_url="https://www.sqlite.org/images/sqlite370.gif",
            footer_text=f"Execution Duration: {duration_seconds:.2f}s • Retention: 7-Day Rolling",
        )

        embed.add_field("🛡️ SQLite Integrity", f"**`{integrity_status.upper()}`** (quick_check & integrity_check)", inline=True)
        embed.add_field("🧹 WAL Checkpoint", f"`{wal_checkpoint_status}`", inline=True)
        embed.add_field("📦 Archive File", f"`{backup_archive_name}`", inline=True)

        space_savings = f"`{initial_size_mb:.2f} MB` ➔ `{compacted_size_mb:.2f} MB` (**{compression_ratio_pct:.1f}% savings**)"
        embed.add_field("💾 Compaction Savings", space_savings, inline=True)
        embed.add_field("🗜️ Compressed Zip Size", f"`{backup_size_mb:.2f} MB`", inline=True)
        embed.add_field("🗑️ Pruned Expired Backups", f"`{retention_pruned_count} old archives`", inline=True)

        embed.add_field("☁️ Encrypted Cloud Sync", f"`{cloud_sync_status}`", inline=False)
        embed.add_field("📝 Task Execution Log", f"```{log_file}```", inline=False)

        return embed


# ===========================================================================
# System Metrics & Live Inspection Helpers
# ===========================================================================
def inspect_system_vfs_storage(
    cache_dir: str | None = None,
    mount_drive: str = "X:",
) -> Dict[str, Any]:
    if not cache_dir:
        cache_dir = os.environ.get("RCLONE_CACHE_DIR", r"E:\MediaServer\cache\rclone_vfs")
    """Gathers live disk stats and rclone cache footprint."""
    cache_p = Path(cache_dir)
    cache_used_bytes = 0
    if cache_p.exists() and cache_p.is_dir():
        try:
            cache_used_bytes = sum(f.stat().st_size for f in cache_p.rglob("*") if f.is_file())
        except Exception:
            pass

    cache_used_gb = round(cache_used_bytes / (1024 ** 3), 2)

    drive_letter = cache_p.anchor if cache_p.anchor else "E:\\"
    total_bytes, used_bytes, free_bytes = 0, 0, 0
    try:
        usage = shutil.disk_usage(drive_letter)
        total_bytes = usage.total
        free_bytes = usage.free
    except Exception:
        pass

    disk_free_gb = round(free_bytes / (1024 ** 3), 2)
    disk_total_gb = round(total_bytes / (1024 ** 3), 2)

    mount_status = "ONLINE" if Path(f"{mount_drive}\\").exists() else "OFFLINE"

    return {
        "mount_drive": mount_drive,
        "mount_status": mount_status,
        "cache_dir": str(cache_p),
        "cache_used_gb": cache_used_gb,
        "cache_max_gb": 50.0,
        "disk_drive": drive_letter.rstrip("\\"),
        "disk_free_gb": disk_free_gb,
        "disk_total_gb": disk_total_gb,
        "low_disk_threshold_gb": 15.0,
        "active_transfers": 0,
    }


def inspect_jellyfin_live_service(
    jellyfin_url: str = "http://localhost:8096",
) -> Dict[str, Any]:
    """Queries Jellyfin public endpoint and process details."""
    status_info: Dict[str, Any] = {
        "event_type": "heartbeat",
        "server_name": "Jellyfin Server",
        "jellyfin_url": jellyfin_url,
        "version": "10.9.x",
        "uptime_str": "Active",
        "memory_usage_mb": 0.0,
        "cpu_pct": 0.0,
        "active_streams": 0,
        "error_message": None,
    }

    try:
        ping_url = f"{jellyfin_url.rstrip('/')}/System/Info/Public"
        req = urllib.request.Request(ping_url, headers={"User-Agent": "JellyfinStack-Notifier/1.0"})
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            status_info["version"] = data.get("Version", "10.9.x")
            status_info["server_name"] = data.get("ServerName", "Jellyfin Server")
            status_info["event_type"] = "heartbeat"
    except Exception as e:
        status_info["event_type"] = "crash"
        status_info["error_message"] = f"Failed to connect to Jellyfin endpoint at {jellyfin_url}: {e}"

    return status_info


# ===========================================================================
# CLI Interface & Subcommands
# ===========================================================================
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Discord Webhook Notifier for Jellyfin Stack",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--webhook-url", "-w", default=os.environ.get("DISCORD_WEBHOOK_URL", ""), help="Discord Webhook URL (or set DISCORD_WEBHOOK_URL env)")
    parser.add_argument("--dry-run", "--DryRun", "--WhatIf", dest="dry_run", action="store_true", help="Preview Discord JSON payload without POSTing (safe preview; writes nothing)")
    parser.add_argument("--tmdb-key", default=os.environ.get("TMDB_API_KEY", ""), help="TMDB API Key for fetching poster art")

    subparsers = parser.add_subparsers(dest="command", required=True, help="Notification category")

    # 1. Media Ingest Subcommand
    p_ingest = subparsers.add_parser("media-ingest", help="Send Media Ingest (Movie / TV episode) notification")
    p_ingest.add_argument("--title", "-t", required=True, help="Media title (e.g. 'Inception' or 'Severance')")
    p_ingest.add_argument("--type", "-m", choices=["movie", "tv"], default="movie", help="Media type (movie / tv)")
    p_ingest.add_argument("--year", "-y", type=int, default=None, help="Release / Air year")
    p_ingest.add_argument("--season", "-s", type=int, default=None, help="Season number (TV)")
    p_ingest.add_argument("--episode", "-e", type=int, default=None, help="Episode number (TV)")
    p_ingest.add_argument("--episode-name", default=None, help="Episode title (TV)")
    p_ingest.add_argument("--resolution", "-r", default="1080p", help="Resolution tag (e.g. 2160p, 1080p, 720p)")
    p_ingest.add_argument("--source", default="WEB-DL", help="Release source (e.g. Remux, BluRay, WEB-DL)")
    p_ingest.add_argument("--video-codec", default="HEVC", help="Video codec (e.g. HEVC, H.264, AV1)")
    p_ingest.add_argument("--audio-codec", default="AAC", help="Audio codec (e.g. TrueHD, Atmos, DTS-HD MA, EAC3, AAC)")
    p_ingest.add_argument("--hdr", default=None, help="HDR profile (e.g. DV, HDR10+, HDR)")
    p_ingest.add_argument("--runtime", default=None, help="Runtime formatted string (e.g. '2h 15m')")
    p_ingest.add_argument("--filesize", default=None, help="Filesize string (e.g. '12.4 GB')")
    p_ingest.add_argument("--dest", "-d", default=None, help="Destination library path")
    p_ingest.add_argument("--poster", "-p", default=None, help="Direct poster image URL")
    p_ingest.add_argument("--overview", default=None, help="Plot overview / synopsis")
    p_ingest.add_argument("--rating", type=float, default=None, help="User / TMDB rating out of 10")
    p_ingest.add_argument("--file", "-f", default=None, help="Optional path to local video file to auto-probe metadata with ffprobe")

    # 2. VFS Cache & Storage Subcommand
    p_vfs = subparsers.add_parser("vfs-cache", help="Send Rclone VFS cache and low disk notification")
    p_vfs.add_argument("--mount-drive", default="X:", help="Rclone mount drive letter (default: X:)")
    p_vfs.add_argument("--mount-status", default="ONLINE", help="Mount status (ONLINE / OFFLINE)")
    p_vfs.add_argument("--cache-dir", default=os.environ.get("RCLONE_CACHE_DIR", r"E:\MediaServer\cache\rclone_vfs"), help="VFS cache directory (or set RCLONE_CACHE_DIR env)")
    p_vfs.add_argument("--cache-used-gb", type=float, default=None, help="Used cache space in GB")
    p_vfs.add_argument("--cache-max-gb", type=float, default=50.0, help="Max cache limit in GB")
    p_vfs.add_argument("--disk-drive", default="E:", help="Cache host drive letter")
    p_vfs.add_argument("--disk-free-gb", type=float, default=None, help="Available free space on host drive in GB")
    p_vfs.add_argument("--disk-total-gb", type=float, default=None, help="Total host drive size in GB")
    p_vfs.add_argument("--low-disk-threshold-gb", type=float, default=15.0, help="Low disk threshold in GB")
    p_vfs.add_argument("--auto-probe", action="store_true", help="Auto-probe live system disk & cache metrics")

    # 3. Jellyfin Service Subcommand
    p_jellyfin = subparsers.add_parser("jellyfin-service", help="Send Jellyfin service lifecycle / crash notification")
    p_jellyfin.add_argument("--event", "-e", choices=["crash", "restart", "start", "stop", "heartbeat"], default="heartbeat", help="Service event type")
    p_jellyfin.add_argument("--server-name", default="Jellyfin Server", help="Jellyfin Server Name")
    p_jellyfin.add_argument("--url", default="http://localhost:8096", help="Jellyfin Server URL")
    p_jellyfin.add_argument("--version", default="10.9.x", help="Jellyfin server version")
    p_jellyfin.add_argument("--uptime", default=None, help="Service uptime string")
    p_jellyfin.add_argument("--memory-mb", type=float, default=None, help="Process memory in MB")
    p_jellyfin.add_argument("--cpu-pct", type=float, default=None, help="CPU utilization percentage")
    p_jellyfin.add_argument("--streams", type=int, default=0, help="Active playback streams count")
    p_jellyfin.add_argument("--error", default=None, help="Error message / stack trace")
    p_jellyfin.add_argument("--auto-probe", action="store_true", help="Auto-probe live Jellyfin server endpoint")

    # 4. Database Backup Subcommand
    p_backup = subparsers.add_parser("db-backup", help="Send Nightly SQLite VACUUM & Backup completion summary")
    p_backup.add_argument("--archive-name", default="jellyfin_db_backup_latest.zip", help="Generated backup zip archive name")
    p_backup.add_argument("--backup-size-mb", type=float, default=48.5, help="Final compressed archive size in MB")
    p_backup.add_argument("--initial-size-mb", type=float, default=124.0, help="Uncompacted initial size in MB")
    p_backup.add_argument("--compacted-size-mb", type=float, default=82.0, help="Compacted snapshot size in MB")
    p_backup.add_argument("--savings-pct", type=float, default=33.8, help="Compaction / compression savings percentage")
    p_backup.add_argument("--integrity", default="PASS", help="SQLite integrity_check status (PASS / FAIL)")
    p_backup.add_argument("--wal-status", default="PASSIVE / TRUNCATED", help="SQLite WAL checkpoint status")
    p_backup.add_argument("--pruned-count", type=int, default=1, help="Number of expired backup archives pruned")
    p_backup.add_argument("--cloud-sync", default="SUCCESS (gdrive-backup:)", help="Rclone cloud sync status")
    p_backup.add_argument("--duration", type=float, default=3.4, help="Duration in seconds")
    p_backup.add_argument("--log-path", default=os.environ.get("DB_BACKUP_LOG", "E:\\MediaServer\\logs\\db_backup.log"), help="Path to backup execution log (or set DB_BACKUP_LOG env)")

    # 5. Generic Custom Notification Subcommand
    p_custom = subparsers.add_parser("custom", help="Send custom Discord embed notification")
    p_custom.add_argument("--title", required=True, help="Embed title")
    p_custom.add_argument("--desc", required=True, help="Embed description")
    p_custom.add_argument("--color", choices=["success", "info", "warning", "error", "critical", "purple", "cyan"], default="info", help="Embed color theme")
    p_custom.add_argument("--field", action="append", nargs=2, metavar=("NAME", "VALUE"), help="Add custom field (can specify multiple)")

    args = parser.parse_args()

    client = DiscordWebhookClient(webhook_url=args.webhook_url)

    # -----------------------------------------------------------------------
    # Handler: Media Ingest
    # -----------------------------------------------------------------------
    if args.command == "media-ingest":
        poster_url = args.poster
        overview = args.overview
        vote_avg = args.rating
        runtime = args.runtime
        filesize = args.filesize
        resolution = args.resolution
        video_codec = args.video_codec
        audio_codec = args.audio_codec

        # Local ffprobe inspection if file provided
        if args.file:
            probe = LocalMediaProbe.probe_file(args.file)
            if probe:
                resolution = probe.get("resolution", resolution)
                video_codec = probe.get("video_codec", video_codec)
                audio_codec = probe.get("audio_codec", audio_codec)
                if not runtime and probe.get("runtime"):
                    runtime = probe["runtime"]
                if not filesize and probe.get("filesize_gb"):
                    filesize = f"{probe['filesize_gb']} GB"

        # TMDB Resolution
        if not poster_url or not overview:
            tmdb = TMDBPosterResolver(api_key=args.tmdb_key)
            meta = tmdb.fetch_media_details(
                title=args.title,
                media_type=args.type,
                year=args.year,
                season=args.season,
                episode=args.episode,
            )
            if meta:
                if not poster_url and meta.get("poster_url"):
                    poster_url = meta["poster_url"]
                if not overview and meta.get("overview"):
                    overview = meta["overview"]
                if vote_avg is None and meta.get("vote_average"):
                    vote_avg = meta["vote_average"]
                if not runtime and meta.get("runtime_str"):
                    runtime = meta["runtime_str"]

        embed = DiscordNotificationBuilder.build_media_ingest_embed(
            title=args.title,
            media_type=args.type,
            year=args.year,
            season=args.season,
            episode=args.episode,
            episode_name=args.episode_name,
            resolution=resolution,
            source=args.source,
            video_codec=video_codec,
            audio_codec=audio_codec,
            hdr=args.hdr,
            runtime=runtime,
            filesize=filesize,
            destination_path=args.dest,
            poster_url=poster_url,
            overview=overview,
            vote_average=vote_avg,
        )
        success = client.send(embeds=[embed], dry_run=args.dry_run)
        return 0 if success else 1

    # -----------------------------------------------------------------------
    # Handler: Rclone VFS Cache
    # -----------------------------------------------------------------------
    elif args.command == "vfs-cache":
        if args.auto_probe:
            metrics = inspect_system_vfs_storage(cache_dir=args.cache_dir, mount_drive=args.mount_drive)
            mount_status = metrics["mount_status"]
            cache_used_gb = metrics["cache_used_gb"]
            cache_max_gb = metrics["cache_max_gb"]
            disk_drive = metrics["disk_drive"]
            disk_free_gb = metrics["disk_free_gb"]
            disk_total_gb = metrics["disk_total_gb"]
        else:
            mount_status = args.mount_status
            cache_used_gb = args.cache_used_gb if args.cache_used_gb is not None else 12.8
            cache_max_gb = args.cache_max_gb
            disk_drive = args.disk_drive
            disk_free_gb = args.disk_free_gb if args.disk_free_gb is not None else 142.5
            disk_total_gb = args.disk_total_gb if args.disk_total_gb is not None else 500.0

        embed = DiscordNotificationBuilder.build_rclone_vfs_embed(
            mount_drive=args.mount_drive,
            mount_status=mount_status,
            cache_dir=args.cache_dir,
            cache_used_gb=cache_used_gb,
            cache_max_gb=cache_max_gb,
            disk_drive=disk_drive,
            disk_free_gb=disk_free_gb,
            disk_total_gb=disk_total_gb,
            low_disk_threshold_gb=args.low_disk_threshold_gb,
        )
        success = client.send(embeds=[embed], dry_run=args.dry_run)
        return 0 if success else 1

    # -----------------------------------------------------------------------
    # Handler: Jellyfin Service
    # -----------------------------------------------------------------------
    elif args.command == "jellyfin-service":
        if args.auto_probe:
            info = inspect_jellyfin_live_service(jellyfin_url=args.url)
            event_type = info["event_type"] if args.event == "heartbeat" else args.event
            server_name = info["server_name"]
            version = info["version"]
            error_msg = info["error_message"] or args.error
        else:
            event_type = args.event
            server_name = args.server_name
            version = args.version
            error_msg = args.error

        embed = DiscordNotificationBuilder.build_jellyfin_service_embed(
            event_type=event_type,
            server_name=server_name,
            jellyfin_url=args.url,
            version=version,
            uptime_str=args.uptime,
            memory_usage_mb=args.memory_mb,
            cpu_pct=args.cpu_pct,
            active_streams=args.streams,
            error_message=error_msg,
        )
        success = client.send(embeds=[embed], dry_run=args.dry_run)
        return 0 if success else 1

    # -----------------------------------------------------------------------
    # Handler: Database Backup Summary
    # -----------------------------------------------------------------------
    elif args.command == "db-backup":
        embed = DiscordNotificationBuilder.build_db_backup_embed(
            backup_archive_name=args.archive_name,
            backup_size_mb=args.backup_size_mb,
            initial_size_mb=args.initial_size_mb,
            compacted_size_mb=args.compacted_size_mb,
            compression_ratio_pct=args.savings_pct,
            integrity_status=args.integrity,
            wal_checkpoint_status=args.wal_status,
            retention_pruned_count=args.pruned_count,
            cloud_sync_status=args.cloud_sync,
            duration_seconds=args.duration,
            log_file=args.log_path,
        )
        success = client.send(embeds=[embed], dry_run=args.dry_run)
        return 0 if success else 1

    # -----------------------------------------------------------------------
    # Handler: Custom Embed
    # -----------------------------------------------------------------------
    elif args.command == "custom":
        color_map = {
            "success": DiscordColor.SUCCESS,
            "info": DiscordColor.INFO,
            "warning": DiscordColor.WARNING,
            "error": DiscordColor.ERROR,
            "critical": DiscordColor.CRITICAL,
            "purple": DiscordColor.JELLYFIN,
            "cyan": DiscordColor.VFS_CACHE,
        }
        embed = DiscordEmbed(
            title=args.title,
            description=args.desc,
            color=color_map.get(args.color, DiscordColor.INFO),
            footer_text="Jellyfin Stack • Status Alert",
        )
        if args.field:
            for fname, fval in args.field:
                embed.add_field(fname, fval, inline=True)

        success = client.send(embeds=[embed], dry_run=args.dry_run)
        return 0 if success else 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
