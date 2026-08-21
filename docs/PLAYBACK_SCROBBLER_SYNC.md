# Playback Scrobbler Sync Architecture & Reference

## Overview

The `potplayer-sync-tracker.ps1` daemon is a real-time playback synchronization engine designed to bridge local media players (specifically Daum PotPlayer) on Windows hosts directly to a central Jellyfin Media Server instance.

Because local media players decode video directly via native DirectShow / EVR / Direct3D pipelines on the host GPU without communicating through the Jellyfin Web client, playback sessions, progress ticks, and watch state updates must be tracked out-of-band and scrobbled to Jellyfin's REST API.

```
+-------------------------------------------------------------------------+
|                              Windows Host                               |
|                                                                         |
|  +--------------------+        WindowTitle / Duration Metadata          |
|  |  PotPlayer64.exe   | ------------------------------------------+     |
|  | (Local HW Playback)|                                           |     |
|  +--------------------+                                           v     |
|                                                     +-----------------+ |
|                                                     | potplayer-sync- | |
|                                                     | tracker.ps1     | |
|                                                     | (Scrobbler loop)| |
|                                                     +-----------------+ |
|                                                              |          |
+--------------------------------------------------------------|----------+
                                                               | HTTP / JSON
                                                               v
                                                    +---------------------+
                                                    |   Jellyfin Server   |
                                                    |    REST API v1      |
                                                    +---------------------+
```

---

## 1. Scrobbler Lifecycle Architecture (`potplayer-sync-tracker.ps1`)

The tracker operates as an asynchronous polling service maintaining a robust state machine across player lifecycle events:

```
                  +-----------------------+
                  | Idle Polling (No Proc)|
                  +-----------------------+
                              |
                              | Process detected & media title matched
                              v
                  +-----------------------+
                  |  Initialize Session   |
                  | POST /Sessions/Playing|
                  +-----------------------+
                              |
                  +-----------+-----------+
                  |                       |
                  v                       v
      +------------------------+  +-----------------------+
      | Heartbeat Loop (5s)    |  | Title Change Detected |
      | POST /Playing/Progress |  | (Cross-episode sync)  |
      +------------------------+  +-----------------------+
                  |                           |
                  | Progress >= 80%           | Exit prior episode
                  v                           v
      +------------------------+  +-----------------------+
      | Auto-Mark Watched      |  | Graceful Teardown     |
      | POST /Users/../Played  |  | POST /Playing/Stopped |
      +------------------------+  +-----------------------+
                  |                           |
                  +-----------+---------------+
                              |
                              | Process exit / Stop signal
                              v
                  +-----------------------+
                  | Final Session Stop    |
                  | POST /Playing/Stopped |
                  +-----------------------+
```

### Lifecycle Phases

1. **Detection & Session Inception:**
   - Detects running `PotPlayer64.exe` or `PotPlayer.exe` processes.
   - Extracts current media file metadata and maps it to a Jellyfin library `ItemId`.
   - Transmits `POST /Sessions/Playing` with `PlayMethod=DirectPlay`.

2. **Continuous Heartbeat Monitoring:**
   - Executes a 5-second polling interval.
   - Verifies whether playback is paused, active, or seeking.
   - Calculates current `PositionTicks` ($1 \text{ tick} = 100 \text{ nanoseconds} = 10^{-7} \text{ seconds}$).
   - Dispatches `POST /Sessions/Playing/Progress` payloads to update server-side session dashboards and client activity logs.

3. **Watched State Evaluation & Auto-Completion:**
   - Evaluates progress percentage against configured threshold (default: $\ge 80\%$).
   - Triggers `POST /Users/{userId}/PlayedItems/{itemId}` once threshold is reached or upon natural completion.

4. **Cross-Episode Transition & Queue Advancement:**
   - Detects when the player advances to the next episode in a playlist without restarting the process.
   - Closes current episode session via `POST /Sessions/Playing/Stopped`.
   - Automatically initializes the new episode session to maintain accurate Next Up queue ordering.

5. **Graceful Session Termination:**
   - Intercepts process termination or user stop events.
   - Sends `POST /Sessions/Playing/Stopped` with final position coordinates.

---

## 2. Jellyfin API Endpoints Specification

All API calls require authentication via the `X-Emby-Token` header or `Authorization: MediaBrowser Token="..."` scheme.

### 2.1. Start Session / DirectPlay Reporting
- **Endpoint:** `POST /Sessions/Playing`
- **Purpose:** Registers an active playback session in Jellyfin, appearing on dashboard activity monitors and remote control endpoints.
- **Headers:**
  ```http
  X-Emby-Token: <JELLYFIN_API_KEY>
  Content-Type: application/json
  ```
- **Payload Schema:**
  ```json
  {
    "ItemId": "8a5d3f21-72bb-40f2-b883-cf228833ef14",
    "Item": {
      "Id": "8a5d3f21-72bb-40f2-b883-cf228833ef14",
      "Name": "Episode Title / Media Name"
    },
    "PlayMethod": "DirectPlay",
    "PositionTicks": 0,
    "CanSeek": true,
    "IsPaused": false,
    "IsMuted": false,
    "RepeatMode": "RepeatNone",
    "MediaSourceId": "8a5d3f2172bb40f2b883cf228833ef14",
    "AudioStreamIndex": 1,
    "SubtitleStreamIndex": -1,
    "PlaybackRate": 1.0
  }
  ```

### 2.2. Periodic Heartbeat & Progress Reporting
- **Endpoint:** `POST /Sessions/Playing/Progress`
- **Purpose:** Updates playback position every 5 seconds. Enables server-side resume point saving, user activity tracking, and live transcoding/session monitoring.
- **Payload Schema:**
  ```json
  {
    "ItemId": "8a5d3f21-72bb-40f2-b883-cf228833ef14",
    "PlayMethod": "DirectPlay",
    "PositionTicks": 14500000000,
    "IsPaused": false,
    "IsMuted": false,
    "VolumeLevel": 100,
    "EventName": "TimeUpdate"
  }
  ```
- **Tick Calculation:**
  ```powershell
  # Convert seconds to 100-nanosecond ticks
  $positionSeconds = 1450.0
  $positionTicks = [int64]($positionSeconds * 10000000)
  ```

### 2.3. Graceful Exit Reporting
- **Endpoint:** `POST /Sessions/Playing/Stopped`
- **Purpose:** Notifies Jellyfin that playback ended. Saves final resume point or clears active playback status from server session lists.
- **Payload Schema:**
  ```json
  {
    "ItemId": "8a5d3f21-72bb-40f2-b883-cf228833ef14",
    "PositionTicks": 14500000000,
    "PlayMethod": "DirectPlay"
  }
  ```

### 2.4. Mark Played Item
- **Endpoint:** `POST /Users/{userId}/PlayedItems/{itemId}`
- **Purpose:** Marks the media item as 100% watched, updates user watch counts, clears resume points, and shifts series to the Next Up queue.
- **URL Parameters:**
  - `userId`: Target Jellyfin user GUID.
  - `itemId`: Media library item GUID.
- **Trigger Rule:** Dispatched when calculated progress ratio reaches or exceeds $80\%$ ($\frac{\text{PositionTicks}}{\text{TotalDurationTicks}} \ge 0.80$).

---

## 3. Metadata Extraction via Shell.Application COM Object

Because raw file headers can be slow or locked by active players, the scrobbler uses Windows Shell COM integration (`Shell.Application`) to extract exact media duration and file attributes directly from the Windows Shell Namespace metadata cache.

### Implementation Pattern

```powershell
function Get-MediaDurationMetadata {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )

    $resolvedPath = Resolve-Path $FilePath
    $folderPath = [System.IO.Path]::GetDirectoryName($resolvedPath)
    $fileName = [System.IO.Path]::GetFileName($resolvedPath)

    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.Namespace($folderPath)
    $fileItem = $folder.ParseName($fileName)

    # Property 27 is the standard Windows Shell Extended Detail index for Media Duration (HH:mm:ss)
    $rawDuration = $folder.GetDetailsOf($fileItem, 27)

    if (-not [string]::IsNullOrWhiteSpace($rawDuration)) {
        # Clean unicode direction marks (e.g. \u200E / \u200F)
        $cleanDuration = $rawDuration -replace '[^\d:]', ''
        
        $parts = $cleanDuration -split ':'
        if ($parts.Count -eq 3) {
            $ts = New-TimeSpan -Hours $parts[0] -Minutes $parts[1] -Seconds $parts[2]
            $totalSeconds = $ts.TotalSeconds
            $durationTicks = [int64]($totalSeconds * 10000000)
            
            return @{
                DurationString = $cleanDuration
                TotalSeconds   = $totalSeconds
                DurationTicks  = $durationTicks
            }
        }
    }

    # Fallback to secondary extended properties if property index 27 differs across OS locales
    for ($i = 0; $i -le 320; $i++) {
        $headerName = $folder.GetDetailsOf($null, $i)
        if ($headerName -eq 'Duration' -or $headerName -eq 'Length') {
            $val = $folder.GetDetailsOf($fileItem, $i) -replace '[^\d:]', ''
            if ($val -match '\d+:\d+:\d+') {
                $p = $val -split ':'
                $ts = New-TimeSpan -Hours $p[0] -Minutes $p[1] -Seconds $p[2]
                return @{
                    DurationString = $val
                    TotalSeconds   = $ts.TotalSeconds
                    DurationTicks  = [int64]($ts.TotalSeconds * 10000000)
                }
            }
        }
    }

    return $null
}
```

---

## 4. Cross-Episode Detection & Next Up Queue Progression

PotPlayer commonly auto-plays subsequent files in a folder or playlist without reopening the process window. The tracker handles dynamic episode transitions seamlessly.

### Mechanism

1. **Window Title Parsing & Polling:**
   - The process window title is sampled every cycle:
     ```powershell
     $proc = Get-Process -Name "PotPlayer64" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle }
     $windowTitle = $proc.MainWindowTitle
     ```
   - Standard PotPlayer title format: `[Episode Name / File Path] - PotPlayer` or `[Filename.mkv]`.

2. **Episode Transition Logic:**
   - If `$newTitle -ne $activeSession.Title`:
     1. Mark the prior active session as stopped (`POST /Sessions/Playing/Stopped`).
     2. If prior episode reached watch threshold ($\ge 80\%$), confirm watched status (`POST /Users/{userId}/PlayedItems/{itemId}`).
     3. Resolve the new file path from the updated title.
     4. Query Jellyfin API (`GET /Items?searchTerm=...&userId=...`) to retrieve the new item GUID.
     5. Extract exact duration via Shell COM metadata.
     6. Initiate new active session (`POST /Sessions/Playing`).
     7. Advance Jellyfin's server-side Next Up queue automatically.

```powershell
# Pseudocode loop for continuous monitoring
while ($true) {
    $proc = Get-Process -Name "PotPlayer64" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle }
    if ($proc) {
        $currentTitle = $proc.MainWindowTitle
        if ($session -and $session.Title -ne $currentTitle) {
            # Episode boundary crossed
            Stop-JellyfinSession -Session $session
            $session = Start-JellyfinSession -Title $currentTitle -Process $proc
        } elseif (-not $session) {
            $session = Start-JellyfinSession -Title $currentTitle -Process $proc
        } else {
            # Send periodic 5s progress heartbeat
            Send-JellyfinProgress -Session $session
        }
    } elseif ($session) {
        # Player closed
        Stop-JellyfinSession -Session $session
        $session = $null
    }
    Start-Sleep -Seconds 5
}
```

---

## 5. Error Handling & Edge Cases

| Scenario | Behavior / Mitigation |
| :--- | :--- |
| **Network Timeout / Jellyfin Restart** | Exponential backoff for HTTP requests; drops unacked heartbeats without crashing local tracker loop. |
| **Short Media / Skips** | If player is closed before $80\%$ progress, resume point is saved via `POST /Sessions/Playing/Stopped`, preserving exact playback position. |
| **Non-Standard Window Titles** | Regex sanitization strips player status tags (e.g. `[Paused]`, `[1080p]`, `[Direct3D]`) before querying Jellyfin item database. |
| **File Locking** | Shell COM namespace metadata extraction avoids opening binary stream handles, preventing file-access collisions with player renderers. |
