# Nexus Media Master Control - Desktop Automation Suite (AHK v2)

## Overview
`NexusMediaMasterControl.ahk` is an enterprise-grade AutoHotkey v2 automation script engineered for high-performance home theater PC (HTPC) and multi-monitor desktop media environments. It unifies global media hotkeys, multi-monitor 4K / Ultrawide window snapping, real-time Jellyfin REST API scrobbling, and hardware-accelerated kiosk launching.

---

## 1. Hotkey Reference Matrix

| Shortcut | Action | Target / Behavior |
| :--- | :--- | :--- |
| `Ctrl + Alt + Space` | **Global Smart Play / Pause** | Automatically routes play/pause to PotPlayer, MPC-HC/BE, or system media bus without taking window focus. |
| `Ctrl + Alt + Right` | **Next Episode / Playlist Track** | Advances to next episode in season playlist (PotPlayer `{PgDn}` / System `Media_Next`). |
| `Ctrl + Alt + Left` | **Previous Episode** | Returns to previous episode in season playlist (PotPlayer `{PgUp}` / System `Media_Prev`). |
| `Ctrl + Alt + W` | **Mark as Watched (Scrobble)** | Resolves currently active video title and executes an asynchronous Jellyfin REST API POST to mark the item as played. |
| `Ctrl + Alt + J` | **Launch Jellyfin Kiosk** | Spawns Jellyfin Web in edge/chrome standalone application mode (`--app`, `--start-fullscreen`). |
| `Win + Alt + C` | **Ultrawide Center Theater** | Snaps the active window into a centered 70% width 21:9 theater box on the active monitor. |
| `Win + Alt + Up` | **Theater Center (16:9 60%)** | Centers active window in 60% viewport width with 80% height. |
| `Win + Alt + Left` | **Snap 1/3 Left Column** | Snaps window into left 33% column (ideal for media sidecars/trackers). |
| `Win + Alt + Down` | **Snap 1/3 Center Column** | Snaps window into center 33% column. |
| `Win + Alt + Right` | **Snap 1/3 Right Column** | Snaps window into right 33% column. |
| `Win + Alt + M` | **Toggle Borderless Fullscreen** | Strips window borders and caption bar for clean fullscreen presentation. |
---

## 2. Key Architecture & Features

### A. Non-Intrusive Direct Window Messaging
- Unlike standard hotkey scripts that force window activation (`WinActivate`), `NexusMediaMasterControl.ahk` utilizes `ControlSend` directly to the window handles (`ahk_exe PotPlayerMini64.exe`).
- This allows seamless media control while gaming, coding, or browsing on secondary monitors without losing focus.

### B. Intelligent Jellyfin REST API Scrobbling
- When `Ctrl + Alt + W` is triggered:
  1. The script extracts the current playback title from the media player window title.
  2. Queries the Jellyfin `/Items?searchTerm=...` REST API via high-speed native COM `WinHttp.WinHttpRequest.5.1`.
  3. If no title is matched, queries active server sessions via `/Sessions`.
  4. Dispatches an authenticated POST request to `/Users/{UserId}/PlayedItems/{ItemId}`.
  5. Renders a hardware-accelerated dark OSD notification indicating success or failure.

### C. 4K & Ultrawide Multi-Monitor Math Engine
- Uses Windows Win32 API `MonitorFromWindow` and `GetMonitorInfo` with `MONITOR_DEFAULTTONEAREST` flag.
- Accurately computes exact work area coordinates excluding taskbars and system docks across 1080p, 1440p, 4K, 21:9 Ultrawide, and 32:9 Super Ultrawide setups.

### D. Modern Dark OSD Notification HUD
- Custom lightweight AHK GUI overlay (`+AlwaysOnTop -Caption +ToolWindow +E0x00000020`).
- Netflix red (`#E50914`) and state-coded accent indicator bars with automatic fade-out timers and non-stealing focus (`NoActivate`).

---

## 3. Installation & Usage

### Prerequisites
- **AutoHotkey v2.0+** installed on the Windows host.

### Running on Startup
1. Press `Win + R`, type `shell:startup` and hit Enter.
2. Create a shortcut pointing to `E:\MediaServer\scripts\NexusMediaMasterControl.ahk`.
3. Alternatively, launch directly via PowerShell:
```powershell
Start-Process "AutoHotkey64.exe" -ArgumentList "E:\MediaServer\scripts\NexusMediaMasterControl.ahk"
```

### Configuration
By default, the script automatically parses `E:\MediaServer\config\system-specs.json` for server parameters, or falls back to standard local defaults:
- `ServerUrl`: `http://localhost:8096`
- `ApiKey`: `e6cf9cf4a71c4c1d810842db131e5f30`
- `UserId`: `1ad3c14a2e5d4cbdb67a216fe0ea4457`
