"""
Jellyfin 10.11 REST API Python SDK (Async & Sync).
Type-safe, fully typed with Pydantic models for authentication, items, playback reporting, and stream URLs.
"""

from __future__ import annotations

import asyncio
from enum import Enum
from typing import Any, Dict, List, Optional, Union
from urllib.parse import urlencode, urljoin

import httpx
from pydantic import BaseModel, ConfigDict, Field


class PlayMethod(str, Enum):
    DIRECT_STREAM = "DirectStream"
    DIRECT_PLAY = "DirectPlay"
    TRANSCODE = "Transcode"


class RepeatMode(str, Enum):
    REPEAT_NONE = "RepeatNone"
    REPEAT_ALL = "RepeatAll"
    REPEAT_ONE = "RepeatOne"


class ItemType(str, Enum):
    MOVIE = "Movie"
    SERIES = "Series"
    SEASON = "Season"
    EPISODE = "Episode"
    AUDIO = "Audio"
    MUSIC_ALBUM = "MusicAlbum"
    MUSIC_ARTIST = "MusicArtist"
    FOLDER = "Folder"
    BOX_SET = "BoxSet"
    VIDEO = "Video"


class SortOrder(str, Enum):
    ASCENDING = "Ascending"
    DESCENDING = "Descending"


class UserDto(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: str = Field(alias="Id")
    name: str = Field(alias="Name")
    has_password: bool = Field(default=False, alias="HasPassword")
    has_configured_password: bool = Field(default=False, alias="HasConfiguredPassword")
    is_administrator: bool = Field(default=False, alias="IsAdministrator")


class AuthenticationResult(BaseModel):
    model_config = ConfigDict(extra="ignore")

    user: UserDto = Field(alias="User")
    access_token: str = Field(alias="AccessToken")
    server_id: Optional[str] = Field(default=None, alias="ServerId")
    session_info: Optional[Dict[str, Any]] = Field(default=None, alias="SessionInfo")


class UserItemDataDto(BaseModel):
    model_config = ConfigDict(extra="ignore")

    playback_position_ticks: int = Field(default=0, alias="PlaybackPositionTicks")
    play_count: int = Field(default=0, alias="PlayCount")
    is_favorite: bool = Field(default=False, alias="IsFavorite")
    played: bool = Field(default=False, alias="Played")
    key: Optional[str] = Field(default=None, alias="Key")


class MediaSourceInfo(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: str = Field(alias="Id")
    name: Optional[str] = Field(default=None, alias="Name")
    path: Optional[str] = Field(default=None, alias="Path")
    container: Optional[str] = Field(default=None, alias="Container")
    size: Optional[int] = Field(default=None, alias="Size")
    bitrate: Optional[int] = Field(default=None, alias="Bitrate")
    supports_direct_play: bool = Field(default=True, alias="SupportsDirectPlay")
    supports_direct_stream: bool = Field(default=True, alias="SupportsDirectStream")
    supports_transcoding: bool = Field(default=True, alias="SupportsTranscoding")


class BaseItemDto(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: str = Field(alias="Id")
    name: str = Field(alias="Name")
    type: str = Field(alias="Type")
    run_time_ticks: Optional[int] = Field(default=None, alias="RunTimeTicks")
    overview: Optional[str] = Field(default=None, alias="Overview")
    series_name: Optional[str] = Field(default=None, alias="SeriesName")
    series_id: Optional[str] = Field(default=None, alias="SeriesId")
    season_name: Optional[str] = Field(default=None, alias="SeasonName")
    season_id: Optional[str] = Field(default=None, alias="SeasonId")
    index_number: Optional[int] = Field(default=None, alias="IndexNumber")  # Episode number
    parent_index_number: Optional[int] = Field(default=None, alias="ParentIndexNumber")  # Season number
    production_year: Optional[int] = Field(default=None, alias="ProductionYear")
    premiere_date: Optional[str] = Field(default=None, alias="PremiereDate")
    community_rating: Optional[float] = Field(default=None, alias="CommunityRating")
    user_data: Optional[UserItemDataDto] = Field(default=None, alias="UserData")
    media_sources: Optional[List[MediaSourceInfo]] = Field(default=None, alias="MediaSources")
    container: Optional[str] = Field(default=None, alias="Container")


class QueryResult(BaseModel):
    model_config = ConfigDict(extra="ignore")

    items: List[BaseItemDto] = Field(alias="Items")
    total_record_count: int = Field(alias="TotalRecordCount")
    start_index: Optional[int] = Field(default=0, alias="StartIndex")


class SessionInfoDto(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: str = Field(alias="Id")
    user_id: Optional[str] = Field(default=None, alias="UserId")
    user_name: Optional[str] = Field(default=None, alias="UserName")
    client: Optional[str] = Field(default=None, alias="Client")
    device_name: Optional[str] = Field(default=None, alias="DeviceName")
    device_id: Optional[str] = Field(default=None, alias="DeviceId")
    application_version: Optional[str] = Field(default=None, alias="ApplicationVersion")
    now_playing_item: Optional[BaseItemDto] = Field(default=None, alias="NowPlayingItem")


class JellyfinClientConfig:
    """Client configuration for Jellyfin SDK."""

    def __init__(
        self,
        base_url: str,
        client_name: str = "ZCode-MediaServer-SDK",
        device_name: str = "Python-Agent",
        device_id: str = "zcode-agent-001",
        version: str = "10.11.0",
        api_key: Optional[str] = None,
        timeout: float = 30.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.client_name = client_name
        self.device_name = device_name
        self.device_id = device_id
        self.version = version
        self.api_key = api_key
        self.timeout = timeout

    @property
    def auth_header(self) -> str:
        parts = [
            f'Client="{self.client_name}"',
            f'Device="{self.device_name}"',
            f'DeviceId="{self.device_id}"',
            f'Version="{self.version}"',
        ]
        if self.api_key:
            parts.append(f'Token="{self.api_key}"')
        return "MediaBrowser " + ", ".join(parts)


class AsyncJellyfinClient:
    """Type-safe Async Jellyfin 10.11 REST API Client."""

    def __init__(self, config: JellyfinClientConfig, http_client: Optional[httpx.AsyncClient] = None):
        self.config = config
        self._user_id: Optional[str] = None
        self._external_client = http_client is not None
        self._http = http_client or httpx.AsyncClient(timeout=config.timeout)

    @property
    def user_id(self) -> Optional[str]:
        return self._user_id

    @user_id.setter
    def user_id(self, value: Optional[str]):
        self._user_id = value

    @property
    def token(self) -> Optional[str]:
        return self.config.api_key

    @token.setter
    def token(self, value: Optional[str]):
        self.config.api_key = value

    async def close(self):
        if not self._external_client:
            await self._http.aclose()

    async def __aenter__(self) -> AsyncJellyfinClient:
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.close()

    def _headers(self) -> Dict[str, str]:
        headers = {
            "Authorization": self.config.auth_header,
            "Accept": "application/json",
            "Content-Type": "application/json",
        }
        if self.config.api_key:
            headers["X-Emby-Token"] = self.config.api_key
        return headers

    def _url(self, path: str) -> str:
        return f"{self.config.base_url}/{path.lstrip('/')}"

    # -------------------------------------------------------------
    # 1. Authentication & Session Management
    # -------------------------------------------------------------
    async def authenticate_by_name(self, username: str, password: str = "") -> AuthenticationResult:
        """Authenticate user with username and password."""
        url = self._url("/Users/AuthenticateByName")
        payload = {"Username": username, "Pw": password}
        response = await self._http.post(url, json=payload, headers=self._headers())
        response.raise_for_status()
        data = response.json()
        result = AuthenticationResult.model_validate(data)
        self.config.api_key = result.access_token
        self._user_id = result.user.id
        return result

    async def get_current_user(self) -> UserDto:
        """Get currently authenticated user details."""
        if not self._user_id:
            raise ValueError("Client user_id is not set. Authenticate first.")
        url = self._url(f"/Users/{self._user_id}")
        response = await self._http.get(url, headers=self._headers())
        response.raise_for_status()
        return UserDto.model_validate(response.json())

    async def get_sessions(self) -> List[SessionInfoDto]:
        """Get active Jellyfin sessions."""
        url = self._url("/Sessions")
        response = await self._http.get(url, headers=self._headers())
        response.raise_for_status()
        return [SessionInfoDto.model_validate(s) for s in response.json()]

    # -------------------------------------------------------------
    # 2. Items Search, Filter, and Pagination
    # -------------------------------------------------------------
    async def get_items(
        self,
        user_id: Optional[str] = None,
        parent_id: Optional[str] = None,
        search_term: Optional[str] = None,
        include_item_types: Optional[Union[List[Union[str, ItemType]], str]] = None,
        is_played: Optional[bool] = None,
        is_favorite: Optional[bool] = None,
        genres: Optional[List[str]] = None,
        tags: Optional[List[str]] = None,
        sort_by: Optional[str] = "SortName",
        sort_order: SortOrder = SortOrder.ASCENDING,
        start_index: int = 0,
        limit: Optional[int] = None,
        recursive: bool = True,
        fields: Optional[List[str]] = None,
    ) -> QueryResult:
        """Query library items with robust filtering, search, and pagination."""
        uid = user_id or self._user_id
        path = f"/Users/{uid}/Items" if uid else "/Items"
        url = self._url(path)

        params: Dict[str, Any] = {
            "recursive": str(recursive).lower(),
            "startIndex": start_index,
            "sortBy": sort_by,
            "sortOrder": sort_order.value if isinstance(sort_order, SortOrder) else sort_order,
        }

        if limit is not None:
            params["limit"] = limit
        if parent_id:
            params["parentId"] = parent_id
        if search_term:
            params["searchTerm"] = search_term
        if is_played is not None:
            params["isPlayed"] = str(is_played).lower()
        if is_favorite is not None:
            params["isFavorite"] = str(is_favorite).lower()
        if genres:
            params["genres"] = "|".join(genres)
        if tags:
            params["tags"] = "|".join(tags)
        if include_item_types:
            if isinstance(include_item_types, list):
                types = [t.value if isinstance(t, ItemType) else str(t) for t in include_item_types]
                params["includeItemTypes"] = ",".join(types)
            else:
                params["includeItemTypes"] = str(include_item_types)

        default_fields = ["Overview", "Path", "RunTimeTicks", "UserData", "MediaSources"]
        if fields:
            merged_fields = list(set(default_fields + fields))
        else:
            merged_fields = default_fields
        params["fields"] = ",".join(merged_fields)

        response = await self._http.get(url, params=params, headers=self._headers())
        response.raise_for_status()
        return QueryResult.model_validate(response.json())

    async def get_item(self, item_id: str, user_id: Optional[str] = None) -> BaseItemDto:
        """Get specific item by ID."""
        uid = user_id or self._user_id
        path = f"/Users/{uid}/Items/{item_id}" if uid else f"/Items/{item_id}"
        url = self._url(path)
        response = await self._http.get(url, headers=self._headers())
        response.raise_for_status()
        return BaseItemDto.model_validate(response.json())

    # -------------------------------------------------------------
    # 3. Next Up & Continue Watching Extraction
    # -------------------------------------------------------------
    async def get_resume_items(
        self,
        user_id: Optional[str] = None,
        limit: int = 12,
        start_index: int = 0,
        media_types: Optional[List[str]] = None,
    ) -> QueryResult:
        """Extract Continue Watching / Resume items for the user."""
        uid = user_id or self._user_id
        if not uid:
            raise ValueError("user_id required for continue watching items.")
        url = self._url(f"/UserItems/Resume")
        params: Dict[str, Any] = {
            "userId": uid,
            "limit": limit,
            "startIndex": start_index,
            "fields": "Overview,PrimaryImageAspectRatio,RunTimeTicks,UserData,MediaSources",
        }
        if media_types:
            params["mediaTypes"] = ",".join(media_types)
        response = await self._http.get(url, params=params, headers=self._headers())
        response.raise_for_status()
        return QueryResult.model_validate(response.json())

    async def get_next_up(
        self,
        user_id: Optional[str] = None,
        parent_id: Optional[str] = None,
        series_id: Optional[str] = None,
        limit: int = 12,
        start_index: int = 0,
    ) -> QueryResult:
        """Extract Next Up TV episodes for the user."""
        uid = user_id or self._user_id
        if not uid:
            raise ValueError("user_id required for next up items.")
        url = self._url("/Shows/NextUp")
        params: Dict[str, Any] = {
            "userId": uid,
            "limit": limit,
            "startIndex": start_index,
            "fields": "Overview,PrimaryImageAspectRatio,RunTimeTicks,UserData,MediaSources",
        }
        if parent_id:
            params["parentId"] = parent_id
        if series_id:
            params["seriesId"] = series_id
        response = await self._http.get(url, params=params, headers=self._headers())
        response.raise_for_status()
        return QueryResult.model_validate(response.json())

    # -------------------------------------------------------------
    # 4. DirectPlay Video Stream URL Generator
    # -------------------------------------------------------------
    def get_direct_play_url(
        self,
        item_id: str,
        media_source_id: Optional[str] = None,
        container: Optional[str] = None,
        api_key: Optional[str] = None,
        static: bool = True,
    ) -> str:
        """
        Generate DirectPlay streaming URL with query parameter authentication.
        Safe for VLC, mpv, ExoPlayer, or browser video players.
        """
        token = api_key or self.config.api_key
        source_id = media_source_id or item_id
        ext = f".{container.lstrip('.')}" if container else ""

        query_params: Dict[str, Any] = {
            "static": str(static).lower(),
            "mediaSourceId": source_id,
            "deviceId": self.config.device_id,
        }
        if token:
            query_params["api_key"] = token

        query_str = urlencode(query_params)
        return f"{self.config.base_url}/Videos/{item_id}/stream{ext}?{query_str}"

    def get_hls_master_playlist_url(
        self,
        item_id: str,
        media_source_id: Optional[str] = None,
        api_key: Optional[str] = None,
    ) -> str:
        """Generate HLS master playlist URL for streaming."""
        token = api_key or self.config.api_key
        source_id = media_source_id or item_id
        query_params: Dict[str, Any] = {
            "mediaSourceId": source_id,
            "deviceId": self.config.device_id,
        }
        if token:
            query_params["api_key"] = token
        query_str = urlencode(query_params)
        return f"{self.config.base_url}/Videos/{item_id}/master.m3u8?{query_str}"

    # -------------------------------------------------------------
    # 5. Playback Scrobbler Reporting
    # -------------------------------------------------------------
    async def report_playing(
        self,
        item_id: str,
        media_source_id: Optional[str] = None,
        play_method: PlayMethod = PlayMethod.DIRECT_PLAY,
        position_ticks: int = 0,
        can_seek: bool = True,
        is_paused: bool = False,
        is_muted: bool = False,
        repeat_mode: RepeatMode = RepeatMode.REPEAT_NONE,
        session_id: Optional[str] = None,
    ) -> bool:
        """Report playback start / now playing state."""
        url = self._url("/Sessions/Playing")
        payload = {
            "ItemId": item_id,
            "MediaSourceId": media_source_id or item_id,
            "PlayMethod": play_method.value if isinstance(play_method, PlayMethod) else play_method,
            "PositionTicks": position_ticks,
            "CanSeek": can_seek,
            "IsPaused": is_paused,
            "IsMuted": is_muted,
            "RepeatMode": repeat_mode.value if isinstance(repeat_mode, RepeatMode) else repeat_mode,
        }
        if session_id:
            payload["SessionId"] = session_id

        response = await self._http.post(url, json=payload, headers=self._headers())
        return response.status_code in (200, 204)

    async def report_progress(
        self,
        item_id: str,
        position_ticks: int,
        media_source_id: Optional[str] = None,
        play_method: PlayMethod = PlayMethod.DIRECT_PLAY,
        is_paused: bool = False,
        is_muted: bool = False,
        repeat_mode: RepeatMode = RepeatMode.REPEAT_NONE,
        event_name: str = "timeupdate",
        session_id: Optional[str] = None,
    ) -> bool:
        """Report periodic playback progress."""
        url = self._url("/Sessions/Playing/Progress")
        payload = {
            "ItemId": item_id,
            "MediaSourceId": media_source_id or item_id,
            "PlayMethod": play_method.value if isinstance(play_method, PlayMethod) else play_method,
            "PositionTicks": position_ticks,
            "IsPaused": is_paused,
            "IsMuted": is_muted,
            "RepeatMode": repeat_mode.value if isinstance(repeat_mode, RepeatMode) else repeat_mode,
            "EventName": event_name,
        }
        if session_id:
            payload["SessionId"] = session_id

        response = await self._http.post(url, json=payload, headers=self._headers())
        return response.status_code in (200, 204)

    async def report_stopped(
        self,
        item_id: str,
        position_ticks: int,
        media_source_id: Optional[str] = None,
        session_id: Optional[str] = None,
    ) -> bool:
        """Report playback stopped."""
        url = self._url("/Sessions/Playing/Stopped")
        payload = {
            "ItemId": item_id,
            "MediaSourceId": media_source_id or item_id,
            "PositionTicks": position_ticks,
        }
        if session_id:
            payload["SessionId"] = session_id

        response = await self._http.post(url, json=payload, headers=self._headers())
        return response.status_code in (200, 204)

    async def mark_played(self, item_id: str, user_id: Optional[str] = None, date_played: Optional[str] = None) -> UserItemDataDto:
        """Mark an item as played for a user."""
        uid = user_id or self._user_id
        if not uid:
            raise ValueError("user_id required to mark item as played.")
        url = self._url(f"/Users/{uid}/PlayedItems/{item_id}")
        params = {}
        if date_played:
            params["datePlayed"] = date_played
        response = await self._http.post(url, params=params, headers=self._headers())
        response.raise_for_status()
        return UserItemDataDto.model_validate(response.json())

    async def mark_unplayed(self, item_id: str, user_id: Optional[str] = None) -> UserItemDataDto:
        """Mark an item as unplayed for a user."""
        uid = user_id or self._user_id
        if not uid:
            raise ValueError("user_id required to mark item as unplayed.")
        url = self._url(f"/Users/{uid}/PlayedItems/{item_id}")
        response = await self._http.delete(url, headers=self._headers())
        response.raise_for_status()
        return UserItemDataDto.model_validate(response.json())


class JellyfinClient:
    """Type-safe Synchronous Jellyfin 10.11 REST API Client (Wrapper over AsyncClient)."""

    def __init__(self, config: JellyfinClientConfig):
        self.config = config
        self._async_client = AsyncJellyfinClient(config)
        self._loop: Optional[asyncio.AbstractEventLoop] = None

    def _get_loop(self) -> asyncio.AbstractEventLoop:
        try:
            return asyncio.get_event_loop()
        except RuntimeError:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            return loop

    def _run(self, coro):
        loop = self._get_loop()
        if loop.is_running():
            import concurrent.futures
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                return executor.submit(lambda: asyncio.run(coro)).result()
        return loop.run_until_complete(coro)

    @property
    def user_id(self) -> Optional[str]:
        return self._async_client.user_id

    @user_id.setter
    def user_id(self, value: Optional[str]):
        self._async_client.user_id = value

    @property
    def token(self) -> Optional[str]:
        return self.config.api_key

    @token.setter
    def token(self, value: Optional[str]):
        self.config.api_key = value
        self._async_client.token = value

    def authenticate_by_name(self, username: str, password: str = "") -> AuthenticationResult:
        return self._run(self._async_client.authenticate_by_name(username, password))

    def get_current_user(self) -> UserDto:
        return self._run(self._async_client.get_current_user())

    def get_sessions(self) -> List[SessionInfoDto]:
        return self._run(self._async_client.get_sessions())

    def get_items(self, **kwargs) -> QueryResult:
        return self._run(self._async_client.get_items(**kwargs))

    def get_item(self, item_id: str, user_id: Optional[str] = None) -> BaseItemDto:
        return self._run(self._async_client.get_item(item_id, user_id))

    def get_resume_items(self, **kwargs) -> QueryResult:
        return self._run(self._async_client.get_resume_items(**kwargs))

    def get_next_up(self, **kwargs) -> QueryResult:
        return self._run(self._async_client.get_next_up(**kwargs))

    def get_direct_play_url(self, item_id: str, **kwargs) -> str:
        return self._async_client.get_direct_play_url(item_id, **kwargs)

    def get_hls_master_playlist_url(self, item_id: str, **kwargs) -> str:
        return self._async_client.get_hls_master_playlist_url(item_id, **kwargs)

    def report_playing(self, item_id: str, **kwargs) -> bool:
        return self._run(self._async_client.report_playing(item_id, **kwargs))

    def report_progress(self, item_id: str, position_ticks: int, **kwargs) -> bool:
        return self._run(self._async_client.report_progress(item_id, position_ticks, **kwargs))

    def report_stopped(self, item_id: str, position_ticks: int, **kwargs) -> bool:
        return self._run(self._async_client.report_stopped(item_id, position_ticks, **kwargs))

    def mark_played(self, item_id: str, **kwargs) -> UserItemDataDto:
        return self._run(self._async_client.mark_played(item_id, **kwargs))

    def mark_unplayed(self, item_id: str, **kwargs) -> UserItemDataDto:
        return self._run(self._async_client.mark_unplayed(item_id, **kwargs))

    def close(self):
        self._run(self._async_client.close())

    def __enter__(self) -> JellyfinClient:
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
