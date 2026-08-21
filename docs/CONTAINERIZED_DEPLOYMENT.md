# Hybrid Container Deployment Architecture Guide

This document specifies the hybrid container deployment strategy for the MediaServer ecosystem on Windows (via Docker Desktop / WSL2 Engine) and Linux environments. It covers NVIDIA GPU passthrough for hardware acceleration, Rclone VFS cache auto-mounting, automated container updates via Watchtower, multi-container log aggregation, and zero-configuration SSL termination via Caddy.

---

## 1. Architecture Overview

```
                          ┌────────────────────────┐
                          │ Internet Client / User │
                          └───────────┬────────────┘
                                      │ HTTPS (443 / QUIC)
                                      ▼
                        ┌───────────────────────────┐
                        │   Caddy Reverse Proxy     │
                        │ (Auto Let's Encrypt TLS)  │
                        └─────────────┬─────────────┘
                                      │ HTTP / WebSocket
                                      ▼
    ┌───────────────────────────────────────────────────────────────────┐
    │                      Docker Bridge Network                        │
    │                                                                   │
    │  ┌───────────────────────┐             ┌───────────────────────┐  │
    │  │  Jellyfin Server      │             │  FlareSolverr Proxy   │  │
    │  │  (NVENC / NVDEC GPU)  │             │  (Cloudflare Bypass)  │  │
    │  └──────────┬────────────┘             └───────────────────────┘  │
    │             │                                                     │
    │  ┌──────────┴────────────┐                                        │
    │  │  Watchtower           │                                        │
    │  │  (Auto-Update Engine) │                                        │
    │  └───────────────────────┘                                        │
    └───────────────────────────────────────────────────────────────────┘
                  │                                   │
      ┌───────────┴───────────┐           ┌───────────┴───────────┐
      │ Windows Host Rclone   │           │ NVIDIA Container      │
      │ VFS Cache Direct Mount│           │ Toolkit GPU Passthrough│
      └───────────────────────┘           └───────────────────────┘
```

---

## 2. NVIDIA Container Toolkit Passthrough

To enable 4K HDR hardware transcoding (NVENC / NVDEC) inside Docker containers on Windows and Linux, the NVIDIA Container Toolkit and modern Docker Compose specification must be utilized.

### 2.1 Prerequisites
1. **Windows Host**:
   - NVIDIA Driver $\ge$ 525.xx installed on host Windows OS.
   - Docker Desktop with WSL2 backend enabled.
   - NVIDIA GPU support in WSL2 is built into modern NVIDIA Windows drivers automatically.
2. **Linux Host**:
   - `nvidia-container-toolkit` installed (`apt-get install -y nvidia-container-toolkit` or distribution equivalent).
   - NVIDIA Container Runtime configured as default in `/etc/docker/daemon.json`.

### 2.2 Docker Compose GPU Resource Reservation

In `deployments/docker-compose.yml`, GPU devices are mapped using Compose Specification `deploy.resources.reservations`:

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, video, compute, utility]
```

### 2.3 Validating Transcoding Inside Container

Execute an interactive check inside the running Jellyfin container:

```bash
docker compose -f deployments/docker-compose.yml exec jellyfin nvidia-smi
docker compose -f deployments/docker-compose.yml exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -encoders | grep nvenc
```

Expected output:
- Active GPU listed in `nvidia-smi` table.
- `h264_nvenc`, `hevc_nvenc`, `av1_nvenc` codecs available.

---

## 3. Auto-Mounting Windows Host Rclone VFS Cache

When running Rclone on the Windows host (mounting remote storage such as Google Drive to `G:` drive with `--vfs-cache-mode full`), sharing the VFS cache with the Jellyfin container eliminates duplicate downloads, optimizes metadata extraction, and ensures sub-second seek latency.

### 3.1 Host Cache Directory Structure

On Windows, Rclone stores chunks and metadata in:
```
C:\Users\Administrator\.cache\rclone\vfs\
```

### 3.2 Volume Mapping Strategy

In `deployments/docker-compose.yml`:

```yaml
services:
  jellyfin:
    volumes:
      # Media mount points (Rclone virtual drive G:\)
      - G:/:/media:ro
      # Direct Rclone VFS Cache read-only mount
      - C:/Users/Administrator/.cache/rclone/vfs:/rclone-vfs-cache:ro
      # Named persistent volumes for container internal state
      - jellyfin_config:/config
      - jellyfin_cache:/cache
```

### 3.3 Benefits of Shared VFS Cache Mount
- **Zero Double-Buffering**: Jellyfin reads directly from hot SSD chunks buffered by the host Rclone process.
- **Read-Only Protection (`:ro`)**: Protects cache state from container permission collisions or improper cleanup.
- **Fast Startup & Scanning**: Media analysis and FFprobe calls retrieve chunks cached during prior playback sessions.

---

## 4. Multi-Container Services & Orchestration

The deployment stack includes four interconnected services:

| Service | Image | Role | Port (Host / Internal) |
| :--- | :--- | :--- | :--- |
| **Jellyfin** | `jellyfin/jellyfin:latest` | Primary media streaming & transcoding server | `8096:8096`, `8920:8920` |
| **FlareSolverr** | `ghcr.io/flaresolverr/flaresolverr:latest` | Cloudflare clearance proxy for scrapers / indexers | `8191:8191` |
| **Caddy** | `caddy:2-alpine` | Edge reverse proxy, HTTP/3, and automatic TLS | `80:80`, `443:443 (TCP/UDP)` |
| **Watchtower** | `containrrr/watchtower:latest` | Automated container updates and image garbage collection | Background daemon (`docker.sock`) |

### 4.1 Caddy Reverse Proxy & Automatic SSL

Caddy automatically negotiates and renews Let's Encrypt / ZeroSSL TLS certificates with HTTP/3 (QUIC) support:

```caddyfile
{$DOMAIN_NAME:localhost} {
    tls {$ACME_EMAIL:admin@example.com}
    encode gzip zstd

    handle {
        reverse_proxy jellyfin:8096 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}

            transport http {
                response_header_timeout 600s
                read_timeout 600s
                write_timeout 600s
            }
        }
    }
}
```

### 4.2 Automated Updates via Watchtower

Watchtower polls the container registry daily (`86400s`), pulls updated images, gracefully recreates containers with identical runtime flags, and removes orphaned images (`WATCHTOWER_CLEANUP=true`):

```yaml
watchtower:
  image: containrrr/watchtower:latest
  environment:
    - WATCHTOWER_CLEANUP=true
    - WATCHTOWER_POLL_INTERVAL=86400
    - WATCHTOWER_INCLUDE_STOPPED=false
    - WATCHTOWER_REVIVE_STOPPED=false
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
```

---

## 5. Multi-Container Logging & Log Rotation

To prevent container logs from saturating disk storage over time, production `json-file` log limits are enforced across all services:

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "20m"
    max-file: "5"
```

### Viewing Logs
- View live aggregated logs:
  ```bash
  docker compose -f deployments/docker-compose.yml logs -f
  ```
- View specific service logs:
  ```bash
  docker compose -f deployments/docker-compose.yml logs -f jellyfin
  docker compose -f deployments/docker-compose.yml logs -f caddy
  ```

---

## 6. Quick Start & Deployment Lifecycle

### 6.1 Setup Environment File
Copy the example environment file and customize your domain name and credentials:

```bash
cd E:/MediaServer/deployments
cp .env.example .env
```

### 6.2 Launch Stack

```bash
docker compose -f E:/MediaServer/deployments/docker-compose.yml up -d
```

### 6.3 Verify Health & Status

```bash
docker compose -f E:/MediaServer/deployments/docker-compose.yml ps
```

### 6.4 Stop Stack

```bash
docker compose -f E:/MediaServer/deployments/docker-compose.yml down
```
