"""
Unit tests for Jellyfin 10.11 REST API Python SDK.
Tests asynchronous and synchronous client functionality with mock transport and live interfaces.
"""

import pytest
import httpx
from unittest.mock import MagicMock

from sdk.jellyfin_sdk import (
    AsyncJellyfinClient,
    JellyfinClient,
    JellyfinClientConfig,
    ItemType,
    PlayMethod,
    RepeatMode,
    SortOrder,
    AuthenticationResult,
    QueryResult,
    BaseItemDto,
    UserItemDataDto,
)


def mock_transport_handler(request: httpx.Request) -> httpx.Response:
    url_path = request.url.path
    method = request.method

    # 1. AuthenticateByName
    if url_path.endswith("/Users/AuthenticateByName") and method == "POST":
        return httpx.Response(
            200,
            json={
                "User": {
                    "Id": "user-12345",
                    "Name": "admin",
                    "HasPassword": True,
                    "HasConfiguredPassword": True,
                    "IsAdministrator": True,
                },
                "AccessToken": "token-abc-xyz-789",
                "ServerId": "server-001",
            },
        )

    # 2. Get User
    if url_path.endswith("/Users/user-12345") and method == "GET":
        return httpx.Response(
            200,
            json={
                "Id": "user-12345",
                "Name": "admin",
                "HasPassword": True,
                "HasConfiguredPassword": True,
                "IsAdministrator": True,
            },
        )

    # 3. Query Items
    if "/Items" in url_path and method == "GET" and not url_path.endswith("/Items/item-001"):
        return httpx.Response(
            200,
            json={
                "Items": [
                    {
                        "Id": "item-001",
                        "Name": "Breaking Bad S01E01",
                        "Type": "Episode",
                        "SeriesName": "Breaking Bad",
                        "SeriesId": "series-001",
                        "SeasonId": "season-001",
                        "IndexNumber": 1,
                        "ParentIndexNumber": 1,
                        "RunTimeTicks": 36000000000,
                        "UserData": {
                            "PlaybackPositionTicks": 10000000,
                            "PlayCount": 1,
                            "IsFavorite": True,
                            "Played": False,
                        },
                        "MediaSources": [
                            {
                                "Id": "ms-001",
                                "Container": "mkv",
                                "SupportsDirectPlay": True,
                                "SupportsDirectStream": True,
                                "SupportsTranscoding": True,
                            }
                        ],
                    }
                ],
                "TotalRecordCount": 1,
                "StartIndex": 0,
            },
        )

    # 4. Single Item
    if url_path.endswith("/item-001") and method == "GET":
        return httpx.Response(
            200,
            json={
                "Id": "item-001",
                "Name": "Breaking Bad S01E01",
                "Type": "Episode",
                "SeriesName": "Breaking Bad",
                "IndexNumber": 1,
                "ParentIndexNumber": 1,
            },
        )

    # 5. Resume / Continue Watching
    if url_path.endswith("/UserItems/Resume") and method == "GET":
        return httpx.Response(
            200,
            json={
                "Items": [
                    {
                        "Id": "item-001",
                        "Name": "Breaking Bad S01E01",
                        "Type": "Episode",
                        "UserData": {"PlaybackPositionTicks": 12000000, "Played": False},
                    }
                ],
                "TotalRecordCount": 1,
                "StartIndex": 0,
            },
        )

    # 6. Next Up
    if url_path.endswith("/Shows/NextUp") and method == "GET":
        return httpx.Response(
            200,
            json={
                "Items": [
                    {
                        "Id": "item-002",
                        "Name": "Breaking Bad S01E02",
                        "Type": "Episode",
                        "IndexNumber": 2,
                        "ParentIndexNumber": 1,
                    }
                ],
                "TotalRecordCount": 1,
                "StartIndex": 0,
            },
        )

    # 7. Scrobbler endpoints
    if url_path.endswith("/Sessions/Playing") and method == "POST":
        return httpx.Response(204)

    if url_path.endswith("/Sessions/Playing/Progress") and method == "POST":
        return httpx.Response(204)

    if url_path.endswith("/Sessions/Playing/Stopped") and method == "POST":
        return httpx.Response(204)

    # 8. Mark Played / Unplayed
    if "/PlayedItems/item-001" in url_path:
        if method == "POST":
            return httpx.Response(200, json={"Played": True, "PlayCount": 2, "PlaybackPositionTicks": 0})
        elif method == "DELETE":
            return httpx.Response(200, json={"Played": False, "PlayCount": 0, "PlaybackPositionTicks": 0})

    return httpx.Response(404, json={"error": "Not Found"})


@pytest.fixture
def mock_async_client():
    config = JellyfinClientConfig(
        base_url="http://localhost:8096",
        client_name="TestClient",
        device_name="TestDevice",
        device_id="test-device-id",
        api_key="test-api-token",
    )
    transport = httpx.MockTransport(mock_transport_handler)
    http = httpx.AsyncClient(transport=transport)
    client = AsyncJellyfinClient(config, http_client=http)
    client.user_id = "user-12345"
    return client


@pytest.mark.asyncio
async def test_async_authenticate(mock_async_client):
    auth_result = await mock_async_client.authenticate_by_name("admin", "password")
    assert isinstance(auth_result, AuthenticationResult)
    assert auth_result.user.id == "user-12345"
    assert auth_result.access_token == "token-abc-xyz-789"
    assert mock_async_client.token == "token-abc-xyz-789"
    assert mock_async_client.user_id == "user-12345"


@pytest.mark.asyncio
async def test_async_get_items(mock_async_client):
    res = await mock_async_client.get_items(
        include_item_types=[ItemType.EPISODE, ItemType.MOVIE],
        sort_by="DateCreated",
        sort_order=SortOrder.DESCENDING,
        limit=10,
    )
    assert isinstance(res, QueryResult)
    assert res.total_record_count == 1
    assert len(res.items) == 1
    item = res.items[0]
    assert item.id == "item-001"
    assert item.series_name == "Breaking Bad"
    assert item.user_data is not None
    assert item.user_data.is_favorite is True


@pytest.mark.asyncio
async def test_async_continue_watching_and_next_up(mock_async_client):
    resume = await mock_async_client.get_resume_items()
    assert resume.total_record_count == 1
    assert resume.items[0].id == "item-001"

    next_up = await mock_async_client.get_next_up()
    assert next_up.total_record_count == 1
    assert next_up.items[0].id == "item-002"
    assert next_up.items[0].index_number == 2


def test_direct_play_url_generation():
    config = JellyfinClientConfig(
        base_url="http://192.168.1.100:8096",
        device_id="my-player-device",
        api_key="secret-token-123",
    )
    client = JellyfinClient(config)
    url = client.get_direct_play_url(
        item_id="item-abc-123",
        media_source_id="ms-def-456",
        container="mkv",
    )

    assert url.startswith("http://192.168.1.100:8096/Videos/item-abc-123/stream.mkv?")
    assert "api_key=secret-token-123" in url
    assert "mediaSourceId=ms-def-456" in url
    assert "deviceId=my-player-device" in url
    assert "static=true" in url

    # Test HLS Master Playlist URL
    hls_url = client.get_hls_master_playlist_url("item-abc-123")
    assert hls_url.startswith("http://192.168.1.100:8096/Videos/item-abc-123/master.m3u8?")
    assert "api_key=secret-token-123" in hls_url


@pytest.mark.asyncio
async def test_async_playback_scrobbler(mock_async_client):
    # Report playing
    res_playing = await mock_async_client.report_playing(
        item_id="item-001",
        play_method=PlayMethod.DIRECT_PLAY,
        position_ticks=0,
    )
    assert res_playing is True

    # Report progress
    res_progress = await mock_async_client.report_progress(
        item_id="item-001",
        position_ticks=50000000,
        play_method=PlayMethod.DIRECT_PLAY,
        event_name="timeupdate",
    )
    assert res_progress is True

    # Report stopped
    res_stopped = await mock_async_client.report_stopped(
        item_id="item-001",
        position_ticks=50000000,
    )
    assert res_stopped is True

    # Mark played & unplayed
    played_data = await mock_async_client.mark_played("item-001")
    assert isinstance(played_data, UserItemDataDto)
    assert played_data.played is True
    assert played_data.play_count == 2

    unplayed_data = await mock_async_client.mark_unplayed("item-001")
    assert isinstance(unplayed_data, UserItemDataDto)
    assert unplayed_data.played is False
