# Jellyfin 10.11 REST API Python SDK

A type-safe, asynchronous and synchronous Python SDK for interfacing with Jellyfin 10.11 REST API.

---

## 📦 Features

- **Full Async & Sync Support**: Built on `httpx` and `pydantic` v2 with strict typings.
- **Authentication & Sessions**: Support for `AuthenticateByName`, token headers (`X-Emby-Token` & `Authorization: MediaBrowser ...`), and active session listing.
- **Search, Filter & Pagination**: Query items across libraries with support for genres, tags, play state, recursive traversal, and sorting.
- **Next Up & Continue Watching**: Dedicated endpoints for `/UserItems/Resume` and `/Shows/NextUp`.
- **DirectPlay & Stream URL Generation**: Generate authenticated DirectPlay video URLs with query parameter tokens compatible with VLC, mpv, browser players, and ExoPlayer.
- **Playback Scrobbler Reporting**: Scrobble events (`report_playing`, `report_progress`, `report_stopped`) and toggle watched states (`mark_played`, `mark_unplayed`).

---

## 🚀 Installation & Requirements

Ensure you have Python 3.10+ and the required dependencies:

```bash
pip install httpx pydantic
```

---

## 🛠️ Quickstart Usage

### 1. Asynchronous Client

```python
import asyncio
from sdk.jellyfin_sdk import AsyncJellyfinClient, JellyfinClientConfig, ItemType, SortOrder

async def main():
    config = JellyfinClientConfig(
        base_url="http://localhost:8096",
        client_name="MediaServer-Client",
        device_name="LivingRoom-Node",
        device_id="node-01"
    )

    async with AsyncJellyfinClient(config) as client:
        # Authenticate
        auth = await client.authenticate_by_name("admin", "your_password")
        print(f"Logged in as {auth.user.name} (User ID: {auth.user.id})")

        # Fetch Continue Watching
        resume_items = await client.get_resume_items(limit=5)
        for item in resume_items.items:
            print(f"Continue Watching: {item.name} - Position: {item.user_data.playback_position_ticks if item.user_data else 0}")

        # Fetch Next Up TV Shows
        next_up = await client.get_next_up(limit=5)
        for item in next_up.items:
            print(f"Next Up: {item.series_name} S{item.parent_index_number}E{item.index_number} - {item.name}")

        # Query Library Items
        movies = await client.get_items(
            include_item_types=[ItemType.MOVIE],
            sort_by="DateCreated",
            sort_order=SortOrder.DESCENDING,
            limit=10
        )
        print(f"Total Movies: {movies.total_record_count}")

        # DirectPlay URL
        if movies.items:
            movie_id = movies.items[0].id
            stream_url = client.get_direct_play_url(movie_id, container="mkv")
            print(f"DirectPlay URL: {stream_url}")

if __name__ == "__main__":
    asyncio.run(main())
```

---

### 2. Synchronous Client

```python
from sdk.jellyfin_sdk import JellyfinClient, JellyfinClientConfig

config = JellyfinClientConfig(
    base_url="http://localhost:8096",
    api_key="your-api-token"
)

with JellyfinClient(config) as client:
    client.user_id = "your-user-id"
    items = client.get_items(limit=10)
    print(f"Found {items.total_record_count} items")
```

---

## 🎬 Scrobbler & Playback Reporting

Report playback states to update Jellyfin's dashboard and tracking engine:

```python
import asyncio
from sdk.jellyfin_sdk import AsyncJellyfinClient, JellyfinClientConfig, PlayMethod

async def play_video(client: AsyncJellyfinClient, item_id: str):
    # 1. Start playback
    await client.report_playing(
        item_id=item_id,
        play_method=PlayMethod.DIRECT_PLAY,
        position_ticks=0
    )

    # 2. Report progress (e.g. at 30 seconds: 300,000,000 ticks)
    await client.report_progress(
        item_id=item_id,
        position_ticks=300_000_000,
        play_method=PlayMethod.DIRECT_PLAY
    )

    # 3. Stop playback
    await client.report_stopped(
        item_id=item_id,
        position_ticks=300_000_000
    )

    # 4. Mark fully watched
    await client.mark_played(item_id=item_id)
```

---

## 🧪 Testing

Run the comprehensive unit test suite:

```bash
PYTHONPATH="E:/MediaServer" pytest "E:/MediaServer/tests/test_jellyfin_sdk.py" -v
```
