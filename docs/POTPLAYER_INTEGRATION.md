# Daum PotPlayer Deep Integration & Protocol Architecture

This document provides technical documentation for the native Daum PotPlayer integration with Jellyfin Media Server. It covers the Windows Custom URI scheme protocol, pipe-delimited payload serialization, the dynamic UTF-16 Unicode season playlist (`.dpl`) format, client-side DOM injection, and an end-to-end troubleshooting guide.

---

## Architecture Overview

```
 ┌────────────────────────────────────────────────────────────┐
 │                  Jellyfin Web Client                       │
 │  (potplayer-integration.js: DOM Buttons & Event Listeners) │
 └─────────────────────────────┬──────────────────────────────┘
                               │ Click: custom URI invocation
                               ▼
 ┌────────────────────────────────────────────────────────────┐
 │  Windows OS Protocol Handler (HKEY_CLASSES_ROOT\potplayer) │
 │  potplayer://<encoded(target|itemId|userId|token|server)>  │
 └─────────────────────────────┬──────────────────────────────┘
                               │ Execution via powershell.exe
                               ▼
 ┌────────────────────────────────────────────────────────────┐
 │         Launcher Wrapper (potplayer-launcher.ps1)          │
 ├─────────────────────────────┬──────────────────────────────┤
 │  - Unescapes & parses URI   │  - Resolves path mappings    │
 │  - Spawns background sync   │  - Generates UTF-16 .dpl     │
 └──────────────┬──────────────┴──────────────┬───────────────┘
                │                             │
    Starts sync tracker            Launches PotPlayerMini64.exe
                │                             │
                ▼                             ▼
 ┌───────────────────────────┐   ┌───────────────────────────┐
 │ potplayer-sync-tracker.ps1│   │   Daum PotPlayer Engine   │
 │ - Live progress scrobble  │   │  (DirectPlay native GPU   │
 │ - Sibling episode scrobble│   │   decoding & playback)    │
 │ - Jellyfin API updates    │   └───────────────────────────┘
 └───────────────────────────┘
```

---

## 1. Custom URI Scheme (`potplayer://`) & Windows Registry Configuration

Windows uses protocol handler entries registered under `HKEY_CLASSES_ROOT` to route custom URI scheme calls from web browsers directly to local executable binaries or scripts.

### Registry Hive Structure

```
HKEY_CLASSES_ROOT\potplayer
 ├── (Default) = "URL:PotPlayer Protocol"
 ├── URL Protocol = ""
 └── shell
      └── open
           └── command
                └── (Default) = powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "F:\Jellyfin\potplayer-launcher.ps1" "%1"
```

### Registration Script (`register-potplayer-protocol.ps1` / `update_registry.ps1`)

To configure or repair the registry entry, run the following PowerShell command in an elevated prompt:

```powershell
$launcherScript = 'F:\Jellyfin\potplayer-launcher.ps1'
$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherScript + '" "%1"'

New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Force | Out-Null
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Name '(Default)' -Value 'URL:PotPlayer Protocol'
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Name 'URL Protocol' -Value ''

New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Force | Out-Null
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Name '(Default)' -Value $cmd
```

---

## 2. Pipe-Delimited Payload Serialization

When launching PotPlayer from the browser, metadata is packed into a single pipe-delimited (`|`) payload, URL-encoded, and passed through the `potplayer://` protocol.

### Payload Structure

```text
potplayer://<URL_ENCODED_PAYLOAD>

Unencoded format:
target|itemId|userId|token|serverUrl
```

### Field Definitions

| Field | Description | Example |
| :--- | :--- | :--- |
| `target` | Local physical media path (or fallback HTTP stream URL) | `F:\Media\TV Shows\Severance (2022)\Season 01\Severance - S01E01 - Good News About Hell.mkv` |
| `itemId` | Jellyfin item GUID | `e3b0c44298fc1c149afbf4c8996fb924` |
| `userId` | Current logged-in Jellyfin user ID | `a1b2c3d4e5f67890123456789abcdef0` |
| `token` | Jellyfin API access token for authentication | `7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d` |
| `serverUrl`| Base URL of the Jellyfin server instance | `http://localhost:8096` |

### Launcher Deserialization Routine (`potplayer-launcher.ps1`)

```powershell
# Clean protocol prefixes
$target = $inputUri -replace '^potplayer://', '' -replace '^"potplayer://', '' -replace '^''potplayer://', ''

# Decode URL encoding
$target = [System.Uri]::UnescapeDataString($target)
$target = $target.Trim().Trim('"').Trim("'").TrimEnd('\').TrimEnd('/')

# Split pipe-delimited payload
$mediaPath = $target
$itemId = ""
$userId = ""
$token = ""
$serverUrl = "http://localhost:8096"

if ($target.Contains('|')) {
    $parts = $target.Split('|')
    $mediaPath = $parts[0]
    if ($parts.Length -gt 1) { $itemId = $parts[1] }
    if ($parts.Length -gt 2) { $userId = $parts[2] }
    if ($parts.Length -gt 3) { $token = $parts[3] }
    if ($parts.Length -gt 4) { $serverUrl = $parts[4] }
}

# Normalize drive letter mappings and path separators
if ($mediaPath.StartsWith('R:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    $mediaPath = 'F:\Media\' + $mediaPath.Substring(3)
}
if ($mediaPath -match '^[a-zA-Z]:') {
    $mediaPath = $mediaPath -replace '/', '\'
}
```

---

## 3. Daum PotPlayer Dynamic Season Playlist (`.dpl`) Format

When an episode from a series is opened, `potplayer-launcher.ps1` scans the directory for all sibling video files and creates a temporary Daum PotPlayer Playlist (`.dpl`). This enables seamless binge-watching, auto-advancing to subsequent episodes, and retaining playlist navigation within PotPlayer.

### Technical Specification

- **File Encoding:** UTF-16 LE (Unicode with BOM). UTF-8 is not reliably parsed by PotPlayer for multi-byte Unicode titles and paths.
- **Header:** First line must be `DAUMPLAYLIST`.
- **Top-Level Metadata Keys:**
  - `playname=<full_path_of_selected_item>`: The file that should begin playing immediately.
  - `playindex=<0_based_index>`: Zero-based index indicating the initial active playlist entry.
  - `topindex=0`: Zero-based index of the item at the top of the GUI playlist view.
- **Sequential Item Attributes (1-indexed counter `N`):**
  - `N*file*<absolute_file_path>`: Full path to the media file.
  - `N*title*<display_title>`: Clean display name (usually filename without extension).

### Sample `.dpl` Output

```text
DAUMPLAYLIST
playname=F:\Media\TV Shows\Severance (2022)\Season 01\Severance - S01E02 - Half Loop.mkv
playindex=1
topindex=0
1*file*F:\Media\TV Shows\Severance (2022)\Season 01\Severance - S01E01 - Good News About Hell.mkv
1*title*Severance - S01E01 - Good News About Hell
2*file*F:\Media\TV Shows\Severance (2022)\Season 01\Severance - S01E02 - Half Loop.mkv
2*title*Severance - S01E02 - Half Loop
3*file*F:\Media\TV Shows\Severance (2022)\Season 01\Severance - S01E03 - In Perpetuity.mkv
3*title*Severance - S01E03 - In Perpetuity
```

### Playlist Generation Code (`potplayer-launcher.ps1`)

```powershell
$allFiles = Get-ChildItem -LiteralPath $parentFolder -File | 
            Where-Object { $extensions -contains $_.Extension.ToLower() } | 
            Sort-Object Name

$dplLines = [System.Collections.Generic.List[string]]::new()
$dplLines.Add("DAUMPLAYLIST")
$dplLines.Add("playname=" + $mediaPath)
$dplLines.Add("playindex=" + $targetIndex)
$dplLines.Add("topindex=0")

$count = 1
foreach ($file in $allFiles) {
    $dplLines.Add("$count`*file`*" + $file.FullName)
    $cleanTitle = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $dplLines.Add("$count`*title`*" + $cleanTitle)
    $count++
}

[System.IO.File]::WriteAllLines($dplPath, $dplLines, [System.Text.Encoding]::Unicode)
```

---

## 4. Client-Side DOM Injection (`potplayer-integration.js`)

The web interface is augmented using a client-side JavaScript bridge injected into the Jellyfin web root (`F:\Jellyfin\server\jellyfin-web\potplayer-integration.js`).

### UI Elements Injected

1. **Netflix-Style Red Hero Buttons (`.btnPotPlayer`):**
   - Injected into `.mainDetailButtons` and `.detailButtons` on Movie, Series, and Season pages.
   - Styled with Netflix Red (`#E50914`), white text, bold typography, rounded borders, and subtle box shadows.
   - Resolves Next-Up episodes when clicked on Series detail pages.

2. **Per-Episode List Item Buttons (`.btnPotPlayerEpisode`):**
   - Injected into `.listItem` rows inside `.listViewUserDataButtons`.
   - Displays a red circular play icon (`play_circle_filled`) with subtle glowing drop shadows for direct episode playback.

3. **Silent Invocation Bridge:**
   - Appends an invisible `<iframe>` (`#potplayer-invoker`) to `document.body` to dispatch URI protocols without triggering browser navigation, page unload warnings, or disrupting the current view state.

4. **Robust Fallback Handling:**
   - If local path resolution or API retrieval encounters an error, the handler automatically falls back to clicking the default Jellyfin web player button.

---

## 5. Background Playback & Live Scrobbling Sync

When PotPlayer starts, `potplayer-launcher.ps1` asynchronously spawns `potplayer-sync-tracker.ps1` in a hidden background process:

- **Playback Start Notification:** Calls `/Sessions/Playing` via REST API.
- **Heartbeat & Position Updates:** Polls every 5 seconds and pushes `/Sessions/Playing/Progress` ticks.
- **Dynamic Sibling File Tracking:** Monitors PotPlayer window title changes. If the user skips to the next episode inside PotPlayer, the previous episode is marked as played (`/Users/{UserId}/PlayedItems/{ItemId}`), and tracking transitions seamlessly to the new episode.
- **Threshold Watch Completion:** Automatically marks media as played when playback crosses 80% duration or when the player is closed after substantial viewing.
- **Playback Stopped Notification:** Emits `/Sessions/Playing/Stopped` upon process termination.

---

## 6. Troubleshooting Guide

### Issue A: Clicking "Play in PotPlayer" Prompts for an App or Does Nothing

1. **Verify Registry Handler:**
   Run in PowerShell:
   ```powershell
   Get-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command'
   ```
   Ensure `(Default)` contains the valid command string pointing to `potplayer-launcher.ps1`.

2. **Verify Browser Protocol Security Prompts:**
   When prompted by Chrome/Edge ("Open PotPlayer?"), select **"Always allow [host] to open links of this type in the associated app"** and click **Open**.

3. **Check Script Execution Policy:**
   Ensure PowerShell execution policy allows script execution:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

### Issue B: PotPlayer Binary Path Not Found

`potplayer-launcher.ps1` checks the following default installation paths:
1. `C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe` (64-bit default)
2. `C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini64.exe` (32-bit fallback)

If PotPlayer is installed in a custom directory (e.g. `D:\Tools\PotPlayer`):
- Open `F:\Jellyfin\potplayer-launcher.ps1`.
- Update `$potExe = 'D:\Tools\PotPlayer\PotPlayerMini64.exe'`.

### Issue C: Drive Letter / Remote Storage Mapping

If Jellyfin library items use mapped mount points (such as `R:\` from rclone or network shares) while the physical cache/storage lives at `F:\Media\`:
- Verify path replacement rules in `potplayer-launcher.ps1`:
  ```powershell
  if ($mediaPath.StartsWith('R:\', [System.StringComparison]::OrdinalIgnoreCase)) {
      $mediaPath = 'F:\Media\' + $mediaPath.Substring(3)
  }
  ```
- Ensure paths use Windows backslashes (`\`) for local file operations.

### Issue D: Playlist `.dpl` Encoding Errors

If PotPlayer displays gibberish characters or fails to load sibling files in the playlist:
- Confirm `.dpl` generation uses UTF-16 Unicode:
  ```powershell
  [System.IO.File]::WriteAllLines($dplPath, $dplLines, [System.Text.Encoding]::Unicode)
  ```
- Check that the playlist directory `F:\Jellyfin\cache\playlists\` has write permissions.
