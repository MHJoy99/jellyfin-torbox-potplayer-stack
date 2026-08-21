# PotPlayer Optimal Configuration Guide (4K HDR & Ultra-Low Latency Playback)

## 1. Overview
This guide documents the production-grade, optimal configuration for Daum PotPlayer (64-bit) tailored for high-bitrate 4K HDR playback, seamless zero-lag timeline scrubbing, 128MB I/O stream pre-buffering over network/cloud mounts (e.g., rclone / WebDAV / Google Drive), advanced pixel shader tone-mapping for non-HDR displays, custom minimal dark skinning, and global keyboard shortcuts for scrobbling and playback synchronization.

---

## 2. Video Rendering Engines: Built-in Direct3D 11 vs. MadVR

| Feature / Metric | Built-in Direct3D 11 Native (Recommended Default) | MadVR (Madshi Video Renderer) |
| :--- | :--- | :--- |
| **GPU Overhead** | Minimal (Low power, high efficiency) | High to Extreme (Scalers, D3D9/D3D11 hooks) |
| **HDR10 Passthrough** | Native Windows 10/11 HDR Display API integration | Direct OS D3D11 Fullscreen Exclusive / OS HDR API |
| **HDR to SDR Tone Mapping** | Built-in Pixel Shader / SMPTE ST 2084 curve | Advanced 3DLUT / Dynamic Target Nits tone mapping |
| **Hardware Decoding** | DXVA2 / D3D11 Native Copy-Back & Native | D3D11 Native / DXVA2 Native |
| **Frame Dropping / Jitter** | Near-zero with FreeSync/G-Sync | Sensitive to scaling algorithms (NGU, Chroma) |
| **Best Used For** | Everyday 4K HDR playback, cloud mounts, low latency | Dedicated Home Theater PCs (HTPC) with RTX 3080/4080+ |

### Configuration Steps:
1. **Direct3D 11 Renderer (Native)**:
   - Go to `Preferences (F5)` -> `Video` -> `Video Renderer` -> Select **Direct3D 11 Video Renderer**.
   - Under D3D11 settings: Set Presentation Mode to **FlipEx / DirectFlip** to bypass Desktop Window Manager (DWM) composition latency.
2. **MadVR Setup**:
   - Install MadVR and select `Madshi Video Renderer` in `Video Renderer`.
   - In MadVR settings: Navigate to `devices` -> `<Display Device>` -> `hdr` -> Select `tone map HDR using pixel shaders` (for SDR displays) or `pass through HDR content to the display` (for native HDR displays).

---

## 3. Zero-Lag Seeking & 128MB I/O Stream Buffers

When playing 4K remuxes (50Mbps - 120Mbps bitrates) from rclone virtual drives, NAS mounts, or local NVMe storage, keyframe seeking and stream buffer allocation prevent stutter and audio de-sync.

### 1. Zero-Lag Keyframe Seeking
- Navigate to `Preferences (F5)` -> `Playback` -> `Time`:
  - Enable **Jump to keyframe (Fast Seeking)**.
  - Set Default Jump Times:
    - Short Jump (Left/Right arrow): `5 seconds`
    - Medium Jump (Ctrl + Left/Right): `30 seconds`
    - Long Jump (Shift + Left/Right): `60 seconds`
  - Uncheck `Show time indicator on seek` if minimal OSD is preferred.

### 2. 128MB I/O Stream Buffering (Filter & Source Cache)
- Navigate to `Preferences (F5)` -> `Filter Control` -> `Source/Splitter`:
  - Under `Built-in Source/Splitter Settings` (or LAV Splitter if external):
    - Set `Read Buffer Size`: `134217728 bytes` (**128 MB**).
    - Enable `Asynchronous file I/O reading`.
    - Buffer-ahead playback queue: `5000 ms` (5 seconds).

---

## 4. HDR-to-SDR Tone-Mapping Pixel Shaders

For monitors that lack native HDR peak brightness (>600 nits) or when running on standard SDR displays:

1. **SMPTE 2084 / BT.2020 Matrix Conversion**:
   - Go to `Preferences (F5)` -> `Video` -> `Color Spaces`:
     - Color Space: **Auto / BT.2020**
     - YCbCr to RGB Matrix: **ITU-R BT.2020**
2. **Pixel Shader Tone Mapping**:
   - Go to `Preferences (F5)` -> `Video` -> `Pixel Shaders`:
     - Enable **HDR Correction / HDR Tone Mapping (SMPTE ST 2084 to BT.709)**.
     - Target Display Peak: `100 - 250 nits` (tune according to SDR display luminance).
     - Color Saturation compensation: `1.05 - 1.10`.

---

## 5. Custom Netflix-Style Dark Minimal UI Skin

To achieve a clean, cinematic borderless playback interface without visual distractions:

1. **Window Frame & Title Bar**:
   - `Preferences (F5)` -> `General` -> `Skin`:
     - Select **Default Skin** or **Modern Minimal Dark (Direct3D 11 OSD)**.
     - Title Bar: Set to **Do not display (Borderless Window)** or **Auto-hide on mouse leave**.
     - Enable `Hide mouse cursor after 1.5 seconds of inactivity`.
2. **OSD (On-Screen Display)**:
   - `Preferences (F5)` -> `General` -> `OSD`:
     - Background: Semi-transparent dark `#111111` with `80% opacity`.
     - Font: `Segoe UI Variable` / `Inter`, Size `14pt`.
     - Disable playback status icon overlays (keep timeline bar slim and auto-hiding at screen bottom).

---

## 6. Global Keyboard Hotkeys for Playback Scrobbling & Control

Global hotkeys allow controlling playback and triggering webhook/scrobble sync even when PotPlayer is running in the background.

| Action | Local Key | Global Hotkey | INI Key Mapping / Command |
| :--- | :--- | :--- | :--- |
| **Play / Pause (Scrobble Ping)** | `Space` | `Ctrl + Alt + Space` | `CMD_PLAY_PAUSE` |
| **Step 5s Backward** | `Left` | `Ctrl + Alt + Left` | `CMD_JUMP_BACKWARD_5` |
| **Step 5s Forward** | `Right` | `Ctrl + Alt + Right` | `CMD_JUMP_FORWARD_5` |
| **Mark Scrobble Watched / Sync** | `Ctrl + W` | `Ctrl + Shift + Alt + W` | Custom Script / Webhook trigger |
| **Toggle Subtitle Track** | `S` | `Alt + S` | `CMD_CYCLE_SUBTITLES` |
| **Cycle Audio Stream** | `A` | `Alt + A` | `CMD_CYCLE_AUDIO_TRACKS` |
| **Toggle Fullscreen Exclusive** | `Enter` | `Alt + Enter` | `CMD_TOGGLE_FULLSCREEN` |
| **Audio Sync Adjust (+/- 50ms)** | `>` / `<` | `Ctrl + >` / `Ctrl + <` | `CMD_AUDIO_SYNC_STEP` |

---

## 7. Applying the Template Configuration
To apply the pre-tuned configuration directly:
1. Close all running instances of PotPlayer.
2. Copy `E:\MediaServer\config\potplayer\PotPlayerMini64.ini.template` to:
   - `C:\Users\%USERNAME%\AppData\Roaming\PotPlayerMini64\PotPlayerMini64.ini`
   - (or directly in the portable PotPlayer directory if running portable mode).
3. Re-launch PotPlayer.
