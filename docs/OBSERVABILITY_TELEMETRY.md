# MediaServer Observability & Prometheus Telemetry Architecture

## Overview

The **NexusMedia Observability & Telemetry Subsystem** provides unified, real-time metric collection across all critical components of the streaming ecosystem:
- **Cloud Storage I/O & Caching:** Rclone VFS full mode cache occupancy, disk usage, read/write I/O operations, and dynamic byte throughput.
- **Media Engine & Playback Server:** Jellyfin server health, active playback sessions (DirectPlay, DirectStream, Transcode), transcode bitrates, and process CPU/RAM consumption.
- **Hardware Acceleration:** NVIDIA Blackwell (RTX 5070) GPU core utilization, VRAM allocation, NVENC hardware encoding engine load, NVDEC decoding engine load, die temperature, power draw, and fan speed.
- **Host Infrastructure:** System CPU load, physical RAM allocation, and client player processes (PotPlayer).

All metrics are gathered and formatted strictly in compliance with the **Prometheus Exposition Format (v0.0.4)** and served over HTTP at `http://localhost:9100/metrics`.

---

## Architecture Diagram

```
 +--------------------------------------------------------------------------------+
 |                           MediaServer Host (Windows 11)                        |
 |                                                                                |
 |  +-----------------------+   +-----------------------+   +------------------+  |
 |  |    Rclone VFS Mount   |   |    Jellyfin Server    |   | NVIDIA RTX 5070  |  |
 |  | (F:\rclone-cache, X:) |   |   (Port 8096, FFmpeg) |   |  (NVENC / NVDEC) |  |
 |  +-----------+-----------+   +-----------+-----------+   +--------+---------+  |
 |              |                           |                        |            |
 |       Win32 I/O, Cache            REST API, FFmpeg            nvidia-smi       |
 |              |                           |                        |            |
 |              +---------------------------+------------------------+            |
 |                                          |                                     |
 |                                          v                                     |
 |                       +--------------------------------------+                 |
 |                       |   scripts/export-metrics.ps1 Daemon  |                 |
 |                       |       (HttpListener / Port 9100)     |                 |
 |                       +------------------+-------------------+                 |
 +------------------------------------------|-------------------------------------+
                                            | Scrape (HTTP GET /metrics)
                                            v
                         +--------------------------------------+
                         |    Prometheus / VictoriaMetrics /    |
                         |          Grafana Dashboard           |
                         +--------------------------------------+
```

---

## Telemetry Metric Catalog

### 1. Rclone VFS Cache & Throughput Metrics

| Metric Name | Type | Labels | Description |
| :--- | :---: | :--- | :--- |
| `rclone_vfs_cache_exists` | `gauge` | `path` | `1` if VFS cache directory exists on disk, `0` otherwise. |
| `rclone_vfs_cache_size_bytes` | `gauge` | `path` | Current disk space consumed by cached chunks/files in bytes. |
| `rclone_vfs_cache_max_size_bytes` | `gauge` | `path` | Configured VFS cache maximum size boundary (e.g. 80 GB). |
| `rclone_vfs_cache_occupancy_ratio` | `gauge` | `path` | Current cache usage ratio relative to maximum limit (`0.0` to `1.0`). |
| `rclone_vfs_cache_file_count` | `gauge` | `path` | Total count of chunk files and object files in the cache. |
| `rclone_process_instances_total` | `gauge` | - | Number of running Rclone process instances. |
| `rclone_process_memory_working_set_bytes` | `gauge` | `pid` | Resident memory (Working Set) in bytes for Rclone process. |
| `rclone_process_cpu_time_seconds_total` | `counter` | `pid` | Cumulative CPU execution time in seconds. |
| `rclone_io_read_bytes_total` | `counter` | `pid` | Cumulative read transfer byte counter. |
| `rclone_io_write_bytes_total` | `counter` | `pid` | Cumulative write transfer byte counter. |
| `rclone_io_read_operations_total` | `counter` | `pid` | Cumulative read I/O operations count. |
| `rclone_io_write_operations_total` | `counter` | `pid` | Cumulative write I/O operations count. |
| `rclone_throughput_read_bytes_per_second` | `gauge` | - | Real-time aggregate read throughput in bytes/second. |
| `rclone_throughput_write_bytes_per_second` | `gauge` | - | Real-time aggregate write throughput in bytes/second. |

### 2. Jellyfin Server & Transcoding Metrics

| Metric Name | Type | Labels | Description |
| :--- | :---: | :--- | :--- |
| `jellyfin_server_up` | `gauge` | `version`, `server_id` | `1` if server responds to public API, `0` if offline. |
| `jellyfin_process_memory_working_set_bytes` | `gauge` | `pid` | Jellyfin resident physical RAM in bytes. |
| `jellyfin_process_memory_private_bytes` | `gauge` | `pid` | Jellyfin committed private memory in bytes. |
| `jellyfin_process_cpu_time_seconds_total` | `counter` | `pid` | Jellyfin cumulative CPU seconds spent. |
| `jellyfin_process_io_read_bytes_total` | `counter` | `pid` | Total bytes read by Jellyfin server process. |
| `jellyfin_process_io_write_bytes_total` | `counter` | `pid` | Total bytes written by Jellyfin server process. |
| `jellyfin_sessions_active_total` | `gauge` | - | Total count of active playback sessions. |
| `jellyfin_sessions_direct_play_total` | `gauge` | - | Count of sessions utilizing DirectPlay (zero transcode). |
| `jellyfin_sessions_direct_stream_total` | `gauge` | - | Count of sessions with direct stream (container remux). |
| `jellyfin_sessions_transcoding_total` | `gauge` | - | Count of sessions performing audio/video transcoding. |
| `jellyfin_transcode_bitrate_bps_total` | `gauge` | - | Aggregate target transcoding bitrate in bits per second. |
| `jellyfin_ffmpeg_processes_active` | `gauge` | - | Number of active FFmpeg transcode/extract worker processes. |
| `jellyfin_ffmpeg_nvenc_processes_active` | `gauge` | - | Active FFmpeg processes utilizing NVIDIA NVENC acceleration. |
| `jellyfin_ffmpeg_cpu_time_seconds_total` | `counter` | - | Total CPU seconds consumed across active FFmpeg workers. |
| `jellyfin_ffmpeg_memory_working_set_bytes` | `gauge` | - | Total resident RAM consumed across active FFmpeg workers. |
| `jellyfin_transcode_process_info` | `gauge` | `pid`, `hwaccel` | Metadata flag (`1`) for each running FFmpeg process. |
| `jellyfin_session_stream_bitrate_bps` | `gauge` | `session_id`, `client`, `device`, `user`, `item`, `play_method` | Per-session stream bitrate in bps. |

### 3. NVIDIA GPU & Hardware Acceleration Metrics

| Metric Name | Type | Labels | Description |
| :--- | :---: | :--- | :--- |
| `nvidia_gpu_available` | `gauge` | - | `1` if NVIDIA GPU is detected via `nvidia-smi`, `0` otherwise. |
| `nvidia_gpu_temperature_celsius` | `gauge` | `gpu`, `model`, `driver` | GPU core die temperature in °C. |
| `nvidia_gpu_vram_total_bytes` | `gauge` | `gpu`, `model`, `driver` | Total installed Video RAM (VRAM) in bytes (12 GB on RTX 5070). |
| `nvidia_gpu_vram_used_bytes` | `gauge` | `gpu`, `model`, `driver` | Currently allocated Video RAM in bytes. |
| `nvidia_gpu_vram_free_bytes` | `gauge` | `gpu`, `model`, `driver` | Currently available Video RAM in bytes. |
| `nvidia_gpu_vram_occupancy_ratio` | `gauge` | `gpu`, `model`, `driver` | VRAM occupancy percentage (`0.0` to `1.0`). |
| `nvidia_gpu_utilization_gpu_percent` | `gauge` | `gpu`, `model`, `driver` | Core graphics/compute pipeline utilization percentage (`0` - `100`). |
| `nvidia_gpu_utilization_memory_percent` | `gauge` | `gpu`, `model`, `driver` | VRAM memory controller bandwidth utilization percentage. |
| `nvidia_gpu_nvenc_utilization_percent` | `gauge` | `gpu`, `model`, `driver` | NVENC hardware video encoding engine utilization percentage. |
| `nvidia_gpu_nvdec_utilization_percent` | `gauge` | `gpu`, `model`, `driver` | NVDEC hardware video decoding engine utilization percentage. |
| `nvidia_gpu_power_draw_watts` | `gauge` | `gpu`, `model`, `driver` | Current GPU electrical power draw in Watts. |
| `nvidia_gpu_fan_speed_percent` | `gauge` | `gpu`, `model`, `driver` | Fan speed percentage (`0` - `100`). |

### 4. Host & Client Application Metrics

| Metric Name | Type | Labels | Description |
| :--- | :---: | :--- | :--- |
| `mediaserver_host_memory_total_bytes` | `gauge` | - | Total host physical RAM in bytes. |
| `mediaserver_host_memory_used_bytes` | `gauge` | - | Currently used host physical RAM in bytes. |
| `mediaserver_host_memory_free_bytes` | `gauge` | - | Available host physical RAM in bytes. |
| `mediaserver_host_memory_usage_ratio` | `gauge` | - | Host memory utilization ratio (`0.0` to `1.0`). |
| `mediaserver_host_cpu_utilization_percent` | `gauge` | - | Total host CPU load percentage (`0` - `100`). |
| `potplayer_client_running` | `gauge` | - | `1` if PotPlayer player client is executing, `0` otherwise. |
| `potplayer_client_memory_working_set_bytes` | `gauge` | - | PotPlayer resident memory in bytes. |
| `potplayer_client_cpu_time_seconds_total` | `counter` | - | Cumulative CPU seconds consumed by PotPlayer client. |

---

## Exporter Usage Guide

The exporter is implemented in `E:\MediaServer\scripts\export-metrics.ps1`.

### 1. One-Shot Inspection Mode
To capture and print all metrics once directly to standard output:
```powershell
powershell.exe -ExecutionPolicy Bypass -File E:\MediaServer\scripts\export-metrics.ps1 -Once
```

To write current metrics to a static file:
```powershell
powershell.exe -ExecutionPolicy Bypass -File E:\MediaServer\scripts\export-metrics.ps1 -OutputFile "E:\MediaServer\metrics.prom"
```

### 2. HTTP Daemon Mode (Default)
Starts a persistent HTTP daemon listening for Prometheus scrapes:
```powershell
powershell.exe -ExecutionPolicy Bypass -File E:\MediaServer\scripts\export-metrics.ps1 -Port 9100
```

#### Parameters:
- `-Port <int>`: HTTP listening port (Default: `9100`).
- `-JellyfinUrl <string>`: Base URL of the Jellyfin server (Default: `http://localhost:8096`).
- `-JellyfinApiKey <string>`: Optional API key or user authentication token for detailed `/Sessions` query.
- `-VfsCachePath <string>`: Custom Rclone cache directory (Default: auto-detects `F:\rclone-cache\gdrive-media` or `E:\MediaServer\cache\rclone_vfs`).
- `-VfsCacheLimitBytes <int64>`: Configured maximum VFS cache size (Default: `85899345920` = 80 GB).

---

## Prometheus Scrape Configuration

Add the following scrape configuration to your `prometheus.yml` configuration:

```yaml
scrape_configs:
  - job_name: 'mediaserver_telemetry'
    scrape_interval: 5s
    scrape_timeout: 4s
    metrics_path: '/metrics'
    static_configs:
      - targets: ['localhost:9100']
        labels:
          environment: 'production'
          server: 'MHJOYGAMERSHUB'
          gpu_arch: 'Blackwell_RTX5070'
```

---

## Grafana Dashboard & PromQL Queries

### 1. Rclone VFS Cache Gauge & Throughput
- **Cache Occupancy Percentage:**
  ```promql
  rclone_vfs_cache_occupancy_ratio * 100
  ```
- **Cache Disk Usage (GB):**
  ```promql
  rclone_vfs_cache_size_bytes / 1024 / 1024 / 1024
  ```
- **Rclone Disk Read Throughput (MB/s):**
  ```promql
  rate(rclone_io_read_bytes_total[30s]) / 1024 / 1024
  ```

### 2. Jellyfin Playback & Transcoding Load
- **Active Playback Breakdown:**
  ```promql
  jellyfin_sessions_direct_play_total
  jellyfin_sessions_direct_stream_total
  jellyfin_sessions_transcoding_total
  ```
- **Active Transcode Workers (NVENC vs Software):**
  ```promql
  jellyfin_ffmpeg_nvenc_processes_active
  jellyfin_ffmpeg_processes_active - jellyfin_ffmpeg_nvenc_processes_active
  ```
- **Jellyfin Memory Consumption (MB):**
  ```promql
  jellyfin_process_memory_working_set_bytes / 1024 / 1024
  ```

### 3. NVIDIA RTX 5070 GPU Real-Time Metrics
- **GPU Core & NVENC Engine Utilization (%):**
  ```promql
  nvidia_gpu_utilization_gpu_percent
  nvidia_gpu_nvenc_utilization_percent
  nvidia_gpu_nvdec_utilization_percent
  ```
- **GPU VRAM Utilization (%):**
  ```promql
  nvidia_gpu_vram_occupancy_ratio * 100
  ```
- **GPU Temperature (°C):**
  ```promql
  nvidia_gpu_temperature_celsius
  ```
- **GPU Power Consumption (Watts):**
  ```promql
  nvidia_gpu_power_draw_watts
  ```

---

## Windows Service / Scheduled Task Deployment

To run the telemetry exporter automatically on system boot in the background:

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File E:\MediaServer\scripts\export-metrics.ps1 -Port 9100"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "MediaServer-Prometheus-Exporter" -Action $action -Trigger $trigger -Settings $settings -User "NT AUTHORITY\SYSTEM" -RunLevel Highest
```

To start the task immediately:
```powershell
Start-ScheduledTask -TaskName "MediaServer-Prometheus-Exporter"
```
