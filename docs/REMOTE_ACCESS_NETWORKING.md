# Secure Zero-Trust Remote Access & High-Performance Media Networking Architecture

## 1. Executive Summary & Zero-Trust Architecture Overview

Exposing home media servers (such as Jellyfin and local VFS storage) directly to the public internet via traditional UPnP or port-forwarding (ports 80/443/8096) creates severe attack surfaces:
- Port scanning and automated brute-force attacks against Jellyfin authentication.
- Zero-day vulnerabilities in web application layers or transcoding endpoints.
- Residential IP exposure, ISP throttling, and Distributed Denial of Service (DDoS) susceptibility.

This guide outlines a hardened, enterprise-grade **Zero-Trust Remote Access Architecture** separating media consumption into two optimized transmission channels:
1. **Cloudflare Zero-Trust Tunnel (HTTP/3 & QUIC):** Seamless, browser-based Jellyfin Web access on custom domains with edge security, zero open inbound firewall ports, and Cloudflare caching bypass rules for video streams.
2. **Tailscale / WireGuard Mesh VPN:** Direct, end-to-end encrypted, kernel-accelerated overlay network for native desktop media players (PotPlayer, MPV) delivering unthrottled 4K HDR bitstreams, full audio passthrough (Dolby Atmos / DTS:X), and sub-millisecond scrobbler sync across WAN.

```
                      +-------------------------------------------------------------+
                      |                      PUBLIC WAN / CLIENTS                   |
                      +-------------------------------------------------------------+
                                     /                               \
               (Web Browsers / Mobile Apps)                  (Native PotPlayer Clients)
                                   /                                   \
                                  v                                     v
                  +-------------------------------+             +-------------------------------+
                  |  Cloudflare Edge (Zero Trust) |             |     Tailscale / WireGuard     |
                  |  - Anycast CDN / WAF          |             |     Peer-to-Peer Mesh VPN     |
                  |  - HTTP/3 + QUIC Gateway      |             |  - DERP Relay / Direct P2P    |
                  |  - Bypass Cache Rules         |             |  - ChaCha20-Poly1305 Crypto   |
                  +-------------------------------+             +-------------------------------+
                                  | (Outbound UDP/QUIC)                         | (Direct UDP Tunnel)
                                  v                                             v
                      +-------------------------------------------------------------+
                      |               LOCAL MEDIA SERVER (WINDOWS 11 HOST)          |
                      |                                                             |
                      |   +-----------------------+     +-----------------------+   |
                      |   |  cloudflared Daemon   |     | Tailscale WinTun Node |   |
                      |   |  (No Inbound Ports)   |     | (100.x.y.z Overlay)   |   |
                      |   +-----------------------+     +-----------------------+   |
                      |               \                             /               |
                      |                v                           v                |
                      |      +-----------------------------------------------+      |
                      |      |           Jellyfin Media Server               |      |
                      |      |           (127.0.0.1:8096 / WinTun)           |      |
                      |      +-----------------------------------------------+      |
                      |                              |                              |
                      |                              v                              |
                      |      +-----------------------------------------------+      |
                      |      |     Rclone VFS / NVMe Transcode Cache         |      |
                      |      +-----------------------------------------------+      |
                      +-------------------------------------------------------------+
```

---

## 2. Cloudflare Zero-Trust Tunnel Setup (Jellyfin Web)

Cloudflare Tunnels (`cloudflared`) establish outbound-only encrypted connections between the local Media Server and Cloudflare's Anycast edge network. No router NAT port forwarding or dynamic DNS (DDNS) is required.

### 2.1 Installation & Daemon Deployment (Windows)

1. **Install cloudflared via Winget or Chocolatey:**
   ```powershell
   winget install --id Cloudflare.cloudflared -e
   ```
2. **Authenticate with your Cloudflare Account:**
   ```powershell
   cloudflared tunnel login
   ```
   *A browser window opens allowing authorization for your custom domain (e.g., `yourdomain.com`). The certificate is saved to `C:\Users\Administrator\.cloudflared\cert.pem`.*

3. **Create the Named Tunnel:**
   ```powershell
   cloudflared tunnel create jellyfin-media-tunnel
   ```
   *Note the generated Tunnel UUID (e.g., `a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d`).*

4. **Associate Custom Subdomain DNS Record:**
   ```powershell
   cloudflared tunnel route dns jellyfin-media-tunnel jellyfin.yourdomain.com
   ```

5. **Deploy the Configuration File:**
   Copy `E:\MediaServer\config\cloudflared\config.yml.template` to `E:\MediaServer\config\cloudflared\config.yml` and replace `YOUR_TUNNEL_UUID_HERE` with your tunnel ID.

6. **Install and Start as a Windows Service:**
   ```powershell
   cloudflared service install
   # Ensure service points to E:\MediaServer\config\cloudflared\config.yml or %USERPROFILE%\.cloudflared\config.yml
   Start-Service cloudflared
   Set-Service -Name cloudflared -StartupType Automatic
   ```

---

## 3. Caching & Edge Optimization: Bypassing the 100MB Chunk Limit

### 3.1 The Cloudflare Caching Problem for Media Streaming
Cloudflare CDN free/standard proxy plans enforce strict file upload/chunk size limitations and caching policies:
- Streaming video files or large progressive MP4/MKV chunks through default caching rules causes `413 Request Entity Too Large` or `524 Gateway Timeout` errors.
- Continuous high-bandwidth video caching can violate Cloudflare Terms of Service (Section 2.8) if static caching is forced on non-HTML media assets without Enterprise plans.

### 3.2 Solution: Cache Rules Configuration in Cloudflare Dashboard
To prevent chunk buffering issues while optimizing web UI asset loading, implement targeted **Cache Rules** in the Cloudflare Dashboard (**Caching > Cache Rules**):

#### Rule 1: Bypass Cache for Streaming & Dynamic API Endpoints
- **Rule Name:** `Jellyfin Media Streaming Bypass`
- **Matching Expression (Field / Operator / Value):**
  ```text
  (http.host eq "jellyfin.yourdomain.com" and (
    http.request.uri.path contains "/videos/" or
    http.request.uri.path contains "/Items/" or
    http.request.uri.path contains "/LiveTv/" or
    http.request.uri.path contains "/Sync/" or
    http.request.uri.path contains "/Audio/" or
    http.request.uri.path contains "/hls/" or
    http.request.uri.path contains "/Sessions/Playing" or
    http.request.uri.path contains "/socket"
  ))
  ```
- **Cache Eligibility:** `Bypass Cache`
- **Response Buffering:** `Off` (Ensures zero-latency chunk passthrough)

#### Rule 2: Aggressive Cache for Static Web Client Assets
- **Rule Name:** `Jellyfin Static Assets Cache`
- **Matching Expression:**
  ```text
  (http.host eq "jellyfin.yourdomain.com" and (
    http.request.uri.path contains "/web/" or
    http.request.uri.path.extension in {"js" "css" "png" "jpg" "jpeg" "webp" "woff2" "ico" "svg"}
  ))
  ```
- **Cache Eligibility:** `Eligible for cache`
- **Edge TTL:** `Override origin -> 7 days`
- **Browser TTL:** `Override origin -> 1 day`

#### Rule 3: WebSocket & Range Header Validation
Ensure in Cloudflare Network Settings that:
- **WebSockets:** `Enabled` (Crucial for Jellyfin live playback session reporting and Playback Scrobbler sync).
- **gRPC:** `Enabled`
- **Maximum Upload Size:** Set to `100MB` (or highest available tier).

---

## 4. HTTP/3 & QUIC Transport Optimization

HTTP/3 replaces TCP with QUIC (built on UDP), offering major advantages for streaming media over cellular and lossy WAN connections:
- **0-RTT Connection Establishment:** Instant playback startup without TLS/TCP multi-step handshake latency.
- **Head-of-Line Blocking Elimination:** Packet drop on one media track (e.g., subtitle stream) does not stall audio/video chunks.
- **Connection Migration:** Mobile clients transitioning between Wi-Fi and 5G retain streaming sessions without rebuffering.

### 4.1 Cloudflare Dashboard Optimization
In Cloudflare Dashboard (**Speed > Optimization > Protocol Optimization**):
1. **HTTP/3 (with QUIC):** Switch to `Enabled`.
2. **0-RTT Connection Resumption:** Switch to `Enabled`.
3. **Early Hints:** Switch to `Enabled`.

### 4.2 Local `cloudflared` Daemon QUIC Enforcement
In `E:\MediaServer\config\cloudflared\config.yml`, ensure the protocol parameter is explicitly configured:
```yaml
protocol: quic
```
*Verification:*
Check running logs to verify QUIC transport is negotiated:
```powershell
Get-EventLog -LogName Application -Source cloudflared -Newest 10 | Format-List
# Look for: "Connection established with protocol: quic"
```

---

## 5. Tailscale / WireGuard Mesh VPN for Direct PotPlayer Streaming

While Cloudflare Tunnels are ideal for web browsers and mobile clients, native players like **Daum PotPlayer** perform best with raw network streams (direct HTTP/SMB/WebDAV), unconstrained bitrates, and direct scrobbler synchronization.

### 5.1 Tailscale Architecture & Key Benefits
- **Zero Port Forwarding:** Establishes direct NAT-traversed UDP tunnels via STUN/DERP.
- **Unrestricted Bitrates:** Bypasses all CDN limits for raw 100Mbps+ 4K Remux / HEVC / AV1 files.
- **High-Fidelity Audio Bitstreaming:** Direct bitstream delivery of Dolby TrueHD / Atmos and DTS-HD MA to remote PotPlayer installations.
- **MagicDNS Integration:** Allows referencing the server cleanly as `http://mediaserver:8096` or `http://100.x.y.z:8096`.

### 5.2 Server-Side Configuration (Windows Host)

1. **Install Tailscale:**
   ```powershell
   winget install --id Tailscale.Tailscale -e
   ```
2. **Authenticate & Enable MagicDNS:**
   ```powershell
   tailscale up --hostname=mediaserver --accept-routes=true
   ```
3. **Verify Tailscale Virtual IP (WinTun Adapter):**
   ```powershell
   tailscale ip -4
   # Example output: 100.85.120.45
   ```

### 5.3 Remote Client Setup (PotPlayer Direct Playback over WAN)

On the remote client machine:
1. Connect to the same Tailscale Tailnet.
2. Open **PotPlayer**:
   - Press `Ctrl + U` (Open URL).
   - Enter direct stream URL: `http://100.85.120.45:8096/Videos/ActiveStream?...` or use the Jellyfin Web Client's "Play on PotPlayer" scrobbler integration.
   - Set PotPlayer VFS buffer: `Preferences > General > Playback > Network Buffer Size: 64MB`.
3. Scrobbler Sync integration (`E:\MediaServer\docs\POTPLAYER_INTEGRATION.md`) functions transparently over the Tailscale IP range without public token exposure.

---

## 6. Remote Access Performance & Security Matrix

| Feature / Dimension | Cloudflare Zero-Trust Tunnel | Tailscale / WireGuard Mesh | Direct Port Forward (Deprecated) |
| :--- | :--- | :--- | :--- |
| **Primary Target Client** | Jellyfin Web / Mobile Browser | PotPlayer / Native Media Players | Legacy installations |
| **Inbound Ports Required** | **0 (Outbound Only)** | **0 (UDP NAT Traversal)** | Ports 80, 443, 8096 open |
| **Transport Protocol** | HTTP/3 (QUIC) / HTTP/2 | WireGuard (UDP / ChaCha20) | TCP (Standard HTTPS) |
| **Max Bitrate / File Size** | Chunk-optimized (Bypass rules) | **Unlimited (Hardware wire speed)**| Limited by ISP upload only |
| **SSL / TLS Certificate** | Cloudflare Edge Automated SSL | Tailscale Built-in Mesh Auth | Let's Encrypt / Manual renewal |
| **DDoS Protection** | Cloudflare Global Anycast WAF | Inaccessible from Public Web | None (Host vulnerable) |
| **Audio Passthrough** | Opus / AAC (Browser limited) | **Bitstream TrueHD / DTS:X / PCM** | **Bitstream TrueHD / DTS:X** |

---

## 7. Operational Health Checks & Maintenance

### 7.1 Testing Cloudflare Tunnel Connectivity
```powershell
# Verify cloudflared daemon status
Get-Service -Name cloudflared

# Test DNS and HTTP/3 Edge response
curl -I --http3 https://jellyfin.yourdomain.com
```

### 7.2 Testing Tailscale Mesh Throughput & Latency
```powershell
# Check active peer connection type (Direct P2P vs DERP relay)
tailscale status
tailscale ping 100.85.120.45
```

---
*Reference Implementation Paths:*
- Tunnel Template: `E:\MediaServer\config\cloudflared\config.yml.template`
- PotPlayer Integration Specs: `E:\MediaServer\docs\POTPLAYER_INTEGRATION.md`
- Transcoding Architecture: `E:\MediaServer\docs\GPU_TRANSCODING_NVENC.md`
