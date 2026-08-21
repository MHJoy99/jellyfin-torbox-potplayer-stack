<#
.SYNOPSIS
    High-Performance Prometheus Exporter for MediaServer Ecosystem.
.DESCRIPTION
    Collects real-time telemetry from:
    1. Rclone VFS Cache occupancy, throughput (Read/Write bytes & IOPS), process CPU/RAM.
    2. Jellyfin Media Server metrics:
       - Active playback sessions & transcode state (via REST API and/or log monitoring)
       - Transcode bitrates, active transcode workers (FFmpeg / NVENC processes)
       - Server process CPU, WorkingSet RAM, Private Bytes RAM, and Host System RAM/CPU.
    3. NVIDIA GPU Telemetry (via nvidia-smi):
       - GPU Temperature, Power Draw, Fan Speed
       - VRAM Total, Used, Free, Memory Utilization %
       - GPU Core Engine Utilization %, NVENC Encoder %, NVDEC Decoder %
    4. PotPlayer client process status & resource consumption.

    Exposes all metrics in standard Prometheus text format on http://localhost:9100/metrics (or specified port/host).
    Supports standalone one-shot collection (-Once / -OutputFile) or daemon HTTP server mode.
.PARAMETER Port
    HTTP Port to listen on (Default: 9100).
.PARAMETER ListenAddress
    IP or hostname prefix to bind to (Default: "http://*:9100/" or "http://localhost:9100/").
.PARAMETER JellyfinUrl
    Jellyfin base URL (Default: "http://localhost:8096").
.PARAMETER JellyfinApiKey
    Optional Jellyfin API Key or User Token for authenticated /Sessions endpoint metrics.
.PARAMETER VfsCachePath
    Path to Rclone VFS cache directory (Default: auto-detected or "F:\rclone-cache\gdrive-media", "E:\MediaServer\cache\rclone_vfs").
.PARAMETER VfsCacheLimitBytes
    Configured maximum cache size in bytes (Default: 80GB = 85899345920).
.PARAMETER IntervalSeconds
    Interval between background metric refreshes when running in server mode (Default: 5).
.PARAMETER Once
    If specified, gathers metrics once, writes them to stdout or file, and exits immediately.
.PARAMETER OutputFile
    Optional file path to write Prometheus metrics output.
.EXAMPLE
    .\export-metrics.ps1
    Starts the HTTP Prometheus exporter daemon on port 9100.
.EXAMPLE
    .\export-metrics.ps1 -Once
    Outputs current metrics once to console.
#>

[CmdletBinding()]
param (
    [int]$Port = 9100,
    [string]$ListenAddress = "",
    [string]$JellyfinUrl = "http://localhost:8096",
    [string]$JellyfinApiKey = "",
    [string]$VfsCachePath = "",
    [int64]$VfsCacheLimitBytes = 85899345920, # 80GB
    [int]$IntervalSeconds = 5,
    [switch]$Once,
    [string]$OutputFile = ""
)

$ErrorActionPreference = "Continue"

# Auto-detect Rclone cache path if not provided
if (-not $VfsCachePath) {
    $candidatePaths = @(
        "F:\rclone-cache\gdrive-media",
        "E:\MediaServer\cache\rclone_vfs",
        "$env:LOCALAPPDATA\rclone\cache"
    )
    foreach ($cand in $candidatePaths) {
        if (Test-Path $cand) {
            $VfsCachePath = $cand
            break
        }
    }
    if (-not $VfsCachePath) {
        $VfsCachePath = "F:\rclone-cache\gdrive-media"
    }
}

# Locate nvidia-smi executable
$script:NvidiaSmiPath = $null
$smiCmd = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
if ($smiCmd) {
    $script:NvidiaSmiPath = $smiCmd.Source
} elseif (Test-Path "C:\Windows\System32\nvidia-smi.exe") {
    $script:NvidiaSmiPath = "C:\Windows\System32\nvidia-smi.exe"
} elseif (Test-Path "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe") {
    $script:NvidiaSmiPath = "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
}

# State tracking for rate calculation
$script:PreviousState = @{
    Timestamp = [DateTime]::UtcNow
    RcloneProcesses = @{}   # PID -> @{ ReadBytes, WriteBytes, Timestamp }
    JellyfinProcesses = @{} # PID -> @{ ReadBytes, WriteBytes, Timestamp }
}

function Format-PrometheusMetric {
    param (
        [string]$Name,
        [string]$Help,
        [string]$Type,
        [hashtable[]]$Samples
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# HELP $Name $Help")
    [void]$sb.AppendLine("# TYPE $Name $Type")

    foreach ($sample in $Samples) {
        $labels = ""
        if ($sample.Labels -and $sample.Labels.Count -gt 0) {
            $labelPairs = @()
            foreach ($k in $sample.Labels.Keys) {
                $val = ($sample.Labels[$k] -replace '\\', '\\') -replace '"', '\"'
                $labelPairs += "$k=`"$val`""
            }
            $labels = "{" + ($labelPairs -join ",") + "}"
        }
        $valStr = [string]$sample.Value
        if ($sample.Value -is [double] -or $sample.Value -is [float]) {
            $valStr = $sample.Value.ToString("0.####", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        [void]$sb.AppendLine("${Name}${labels} $valStr")
    }
    return $sb.ToString()
}

function Collect-AllMetrics {
    $metricsOutput = [System.Text.StringBuilder]::new()
    $nowUtc = [DateTime]::UtcNow

    # =========================================================================
    # 1. System Host Metrics (CPU & Physical RAM)
    # =========================================================================
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $totalRamBytes = [double]($os.TotalVisibleMemorySize * 1024)
            $freeRamBytes = [double]($os.FreePhysicalMemory * 1024)
            $usedRamBytes = $totalRamBytes - $freeRamBytes
            $ramUsageRatio = if ($totalRamBytes -gt 0) { $usedRamBytes / $totalRamBytes } else { 0 }

            [void]$metricsOutput.Append((Format-PrometheusMetric `
                -Name "mediaserver_host_memory_total_bytes" `
                -Help "Total physical memory in bytes on host." `
                -Type "gauge" `
                -Samples @(@{ Value = $totalRamBytes })))

            [void]$metricsOutput.Append((Format-PrometheusMetric `
                -Name "mediaserver_host_memory_used_bytes" `
                -Help "Used physical memory in bytes on host." `
                -Type "gauge" `
                -Samples @(@{ Value = $usedRamBytes })))

            [void]$metricsOutput.Append((Format-PrometheusMetric `
                -Name "mediaserver_host_memory_free_bytes" `
                -Help "Free physical memory in bytes on host." `
                -Type "gauge" `
                -Samples @(@{ Value = $freeRamBytes })))

            [void]$metricsOutput.Append((Format-PrometheusMetric `
                -Name "mediaserver_host_memory_usage_ratio" `
                -Help "Host physical memory utilization percentage (0.0 to 1.0)." `
                -Type "gauge" `
                -Samples @(@{ Value = $ramUsageRatio })))
        }

        $cpuMeasure = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average
        if ($cpuMeasure -and $null -ne $cpuMeasure.Average) {
            [void]$metricsOutput.Append((Format-PrometheusMetric `
                -Name "mediaserver_host_cpu_utilization_percent" `
                -Help "Total host CPU load percentage." `
                -Type "gauge" `
                -Samples @(@{ Value = [double]$cpuMeasure.Average })))
        }
    } catch {
        # Host metrics collection fallback
    }

    # =========================================================================
    # 2. Rclone VFS Cache & Process Metrics
    # =========================================================================
    try {
        $vfsSizeBytes = 0
        $vfsFileCount = 0
        $vfsDirCount = 0
        $vfsExists = 0

        if (Test-Path -LiteralPath $VfsCachePath) {
            $vfsExists = 1
            $files = Get-ChildItem -LiteralPath $VfsCachePath -Recurse -File -ErrorAction SilentlyContinue
            if ($files) {
                $vfsFileCount = $files.Count
                $measure = $files | Measure-Object -Property Length -Sum
                if ($measure -and $null -ne $measure.Sum) {
                    $vfsSizeBytes = [double]$measure.Sum
                }
            }
            $dirs = Get-ChildItem -LiteralPath $VfsCachePath -Recurse -Directory -ErrorAction SilentlyContinue
            if ($dirs) {
                $vfsDirCount = $dirs.Count
            }
        }

        $cacheOccupancyRatio = if ($VfsCacheLimitBytes -gt 0) { [math]::Min(1.0, $vfsSizeBytes / $VfsCacheLimitBytes) } else { 0 }

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "rclone_vfs_cache_exists" `
            -Help "Whether the configured Rclone VFS cache directory exists (1=yes, 0=no)." `
            -Type "gauge" `
            -Samples @(@{ Labels = @{ path = $VfsCachePath }; Value = $vfsExists })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "rclone_vfs_cache_size_bytes" `
            -Help "Current total size in bytes occupied by Rclone VFS cache on disk." `
            -Type "gauge" `
            -Samples @(@{ Labels = @{ path = $VfsCachePath }; Value = $vfsSizeBytes })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "rclone_vfs_cache_max_size_bytes" `
            -Help "Configured maximum size limit for Rclone VFS cache." `
            -Type "gauge" `
            -Samples @(@{ Labels = @{ path = $VfsCachePath }; Value = $VfsCacheLimitBytes })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "rclone_vfs_cache_occupancy_ratio" `
            -Help "Ratio of current VFS cache occupancy relative to max configured limit (0.0 to 1.0)." `
            -Type "gauge" `
            -Samples @(@{ Labels = @{ path = $VfsCachePath }; Value = $cacheOccupancyRatio })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "rclone_vfs_cache_file_count" `
            -Help "Total number of cached file chunks/objects in VFS directory." `
            -Type "gauge" `
            -Samples @(@{ Labels = @{ path = $VfsCachePath }; Value = $vfsFileCount })))

        # Rclone Process Telemetry (Throughput, I/O counters, CPU, RAM)
        $rcloneProcs = Get-Process -Name rclone -ErrorAction SilentlyContinue
        $rcloneActiveCount = if ($rcloneProcs) { $rcloneProcs.Count } else { 0 }

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "rclone_process_instances_total" `
            -Help "Number of running Rclone mount/sync process instances." `
            -Type "gauge" `
            -Samples @(@{ Value = $rcloneActiveCount })))

        $totalRcloneReadBytesRate = 0.0
        $totalRcloneWriteBytesRate = 0.0
        $totalRcloneWorkingSet = 0.0
        $totalRcloneCpuSeconds = 0.0

        if ($rcloneProcs) {
            $rcloneCim = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'rclone.exe' }
            foreach ($p in $rcloneProcs) {
                $pidStr = [string]$p.Id
                $cim = $rcloneCim | Where-Object { $_.ProcessId -eq $p.Id } | Select-Object -First 1
                $readTransfer = if ($cim -and $cim.ReadTransferCount) { [int64]$cim.ReadTransferCount } else { 0 }
                $writeTransfer = if ($cim -and $cim.WriteTransferCount) { [int64]$cim.WriteTransferCount } else { 0 }
                $readOps = if ($cim -and $cim.ReadOperationCount) { [int64]$cim.ReadOperationCount } else { 0 }
                $writeOps = if ($cim -and $cim.WriteOperationCount) { [int64]$cim.WriteOperationCount } else { 0 }

                $totalRcloneWorkingSet += $p.WorkingSet64
                $totalRcloneCpuSeconds += $p.CPU

                # Calculate read/write byte rates if previous sample exists
                $readRate = 0.0
                $writeRate = 0.0
                if ($script:PreviousState.RcloneProcesses.ContainsKey($pidStr)) {
                    $prev = $script:PreviousState.RcloneProcesses[$pidStr]
                    $deltaSec = ($nowUtc - $prev.Timestamp).TotalSeconds
                    if ($deltaSec -gt 0.2) {
                        if ($readTransfer -ge $prev.ReadBytes) {
                            $readRate = [double]($readTransfer - $prev.ReadBytes) / $deltaSec
                        }
                        if ($writeTransfer -ge $prev.WriteBytes) {
                            $writeRate = [double]($writeTransfer - $prev.WriteBytes) / $deltaSec
                        }
                    }
                }
                $script:PreviousState.RcloneProcesses[$pidStr] = @{
                    ReadBytes = $readTransfer
                    WriteBytes = $writeTransfer
                    Timestamp = $nowUtc
                }

                $totalRcloneReadBytesRate += $readRate
                $totalRcloneWriteBytesRate += $writeRate

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "rclone_process_memory_working_set_bytes" `
                    -Help "Rclone process resident working set memory in bytes." `
                    -Type "gauge" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$p.WorkingSet64 })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "rclone_process_cpu_time_seconds_total" `
                    -Help "Total CPU time consumed by Rclone process in seconds." `
                    -Type "counter" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$p.CPU })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "rclone_io_read_bytes_total" `
                    -Help "Total cumulative bytes read by Rclone process from disk/cache/network." `
                    -Type "counter" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$readTransfer })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "rclone_io_write_bytes_total" `
                    -Help "Total cumulative bytes written by Rclone process to disk/cache." `
                    -Type "counter" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$writeTransfer })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "rclone_io_read_operations_total" `
                    -Help "Total cumulative read operations performed by Rclone process." `
                    -Type "counter" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$readOps })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "rclone_io_write_operations_total" `
                    -Help "Total cumulative write operations performed by Rclone process." `
                    -Type "counter" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$writeOps })))
            }
        }

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "rclone_throughput_read_bytes_per_second" `
            -Help "Calculated aggregate read throughput across all active Rclone instances in bytes/sec." `
            -Type "gauge" `
            -Samples @(@{ Value = $totalRcloneReadBytesRate })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "rclone_throughput_write_bytes_per_second" `
            -Help "Calculated aggregate write throughput across all active Rclone instances in bytes/sec." `
            -Type "gauge" `
            -Samples @(@{ Value = $totalRcloneWriteBytesRate })))
    } catch {
        # Error handling for Rclone metrics
    }

    # =========================================================================
    # 3. Jellyfin Server & Transcoding Metrics
    # =========================================================================
    try {
        $jellyfinProcs = Get-Process -Name jellyfin -ErrorAction SilentlyContinue
        $jellyfinOnline = 0
        $jellyfinVersion = "unknown"
        $jellyfinServerId = "unknown"

        # Check Jellyfin Public Endpoint
        try {
            $infoUrl = "$($JellyfinUrl.TrimEnd('/'))/System/Info/Public"
            $pubInfo = Invoke-RestMethod -Uri $infoUrl -Method Get -TimeoutSec 3 -ErrorAction Stop
            if ($pubInfo) {
                $jellyfinOnline = 1
                if ($pubInfo.Version) { $jellyfinVersion = $pubInfo.Version }
                if ($pubInfo.Id) { $jellyfinServerId = $pubInfo.Id }
            }
        } catch {
            $jellyfinOnline = if ($jellyfinProcs) { 1 } else { 0 }
        }

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_server_up" `
            -Help "Jellyfin media server operational status (1=up, 0=down)." `
            -Type "gauge" `
            -Samples @(@{ Labels = @{ version = $jellyfinVersion; server_id = $jellyfinServerId }; Value = $jellyfinOnline })))

        # Process-level Jellyfin CPU/RAM
        if ($jellyfinProcs) {
            $jfCim = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'jellyfin.exe' }
            foreach ($jp in $jellyfinProcs) {
                $pidStr = [string]$jp.Id
                $cim = $jfCim | Where-Object { $_.ProcessId -eq $jp.Id } | Select-Object -First 1
                $readTransfer = if ($cim -and $cim.ReadTransferCount) { [int64]$cim.ReadTransferCount } else { 0 }
                $writeTransfer = if ($cim -and $cim.WriteTransferCount) { [int64]$cim.WriteTransferCount } else { 0 }

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "jellyfin_process_memory_working_set_bytes" `
                    -Help "Jellyfin server process working set memory in bytes." `
                    -Type "gauge" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$jp.WorkingSet64 })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "jellyfin_process_memory_private_bytes" `
                    -Help "Jellyfin server process private committed memory in bytes." `
                    -Type "gauge" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$jp.PM })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "jellyfin_process_cpu_time_seconds_total" `
                    -Help "Cumulative CPU time consumed by Jellyfin server process in seconds." `
                    -Type "counter" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$jp.CPU })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "jellyfin_process_io_read_bytes_total" `
                    -Help "Cumulative bytes read by Jellyfin server process." `
                    -Type "counter" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$readTransfer })))

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "jellyfin_process_io_write_bytes_total" `
                    -Help "Cumulative bytes written by Jellyfin server process." `
                    -Type "counter" `
                    -Samples @(@{ Labels = @{ pid = $pidStr }; Value = [double]$writeTransfer })))
            }
        }

        # Active Playback Sessions & Bitrates
        $activeSessionsCount = 0
        $directPlayCount = 0
        $directStreamCount = 0
        $transcodeCount = 0
        $totalTranscodeBitrateBps = 0.0
        $sessionSamples = @()

        # Query authenticated /Sessions endpoint if API key/token provided
        if ($JellyfinApiKey -and $jellyfinOnline -eq 1) {
            try {
                $sessUrl = "$($JellyfinUrl.TrimEnd('/'))/Sessions"
                $headers = @{
                    "X-Emby-Token" = $JellyfinApiKey
                    "Authorization" = "MediaBrowser Token=`"$JellyfinApiKey`""
                }
                $sessions = Invoke-RestMethod -Uri $sessUrl -Method Get -Headers $headers -TimeoutSec 3 -ErrorAction Stop
                if ($sessions) {
                    $activeSessionsCount = $sessions.Count
                    foreach ($s in $sessions) {
                        $playMethod = "DirectPlay"
                        $bitrate = 0.0
                        if ($s.NowPlayingItem) {
                            if ($s.PlayState -and $s.PlayState.PlayMethod) {
                                $playMethod = [string]$s.PlayState.PlayMethod
                            }
                            if ($s.TranscodingInfo) {
                                $playMethod = "Transcode"
                                $transcodeCount++
                                if ($s.TranscodingInfo.Bitrate) {
                                    $bitrate = [double]$s.TranscodingInfo.Bitrate
                                    $totalTranscodeBitrateBps += $bitrate
                                }
                            } elseif ($playMethod -eq "DirectStream") {
                                $directStreamCount++
                            } else {
                                $directPlayCount++
                            }

                            $clientName = if ($s.Client) { $s.Client } else { "Unknown" }
                            $deviceName = if ($s.DeviceName) { $s.DeviceName } else { "Unknown" }
                            $userName = if ($s.UserName) { $s.UserName } else { "Anonymous" }
                            $mediaName = if ($s.NowPlayingItem.Name) { $s.NowPlayingItem.Name } else { "Item" }

                            $sessionSamples += @{
                                Labels = @{
                                    session_id = [string]$s.Id
                                    client = $clientName
                                    device = $deviceName
                                    user = $userName
                                    item = $mediaName
                                    play_method = $playMethod
                                }
                                Value = $bitrate
                            }
                        }
                    }
                }
            } catch {
                # Fallback to process inspection
            }
        }

        # Inspect Active FFmpeg Transcoder / Subtitle / Remux Processes
        $ffmpegProcs = Get-Process -Name ffmpeg -ErrorAction SilentlyContinue
        $activeFfmpegCount = if ($ffmpegProcs) { $ffmpegProcs.Count } else { 0 }
        $activeNvencFfmpegCount = 0
        $ffmpegCpuTotal = 0.0
        $ffmpegRamTotal = 0.0

        if ($ffmpegProcs) {
            $ffmpegCim = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'ffmpeg.exe' }
            foreach ($fp in $ffmpegProcs) {
                $ffmpegCpuTotal += $fp.CPU
                $ffmpegRamTotal += $fp.WorkingSet64
                $cim = $ffmpegCim | Where-Object { $_.ProcessId -eq $fp.Id } | Select-Object -First 1
                $cmdLine = if ($cim -and $cim.CommandLine) { $cim.CommandLine } else { "" }

                $isNvenc = if ($cmdLine -match "nvenc|cuvid|cuda|scale_cuda|tonemap_cuda") { 1 } else { 0 }
                if ($isNvenc -eq 1) { $activeNvencFfmpegCount++ }

                # Extract target bitrate from FFmpeg command line if present (e.g., -b:v 22M or -maxrate 12M)
                $parsedBitrateBps = 0.0
                if ($cmdLine -match "-b:v\s+([0-9\.]+)([kKmMgG]?)") {
                    $num = [double]$Matches[1]
                    $unit = $Matches[2].ToUpper()
                    $mult = switch ($unit) {
                        "K" { 1000 }
                        "M" { 1000000 }
                        "G" { 1000000000 }
                        Default { 1 }
                    }
                    $parsedBitrateBps = $num * $mult
                } elseif ($cmdLine -match "-maxrate\s+([0-9\.]+)([kKmMgG]?)") {
                    $num = [double]$Matches[1]
                    $unit = $Matches[2].ToUpper()
                    $mult = switch ($unit) {
                        "K" { 1000 }
                        "M" { 1000000 }
                        "G" { 1000000000 }
                        Default { 1 }
                    }
                    $parsedBitrateBps = $num * $mult
                }

                if ($parsedBitrateBps -gt 0 -and $totalTranscodeBitrateBps -eq 0) {
                    $totalTranscodeBitrateBps += $parsedBitrateBps
                }

                [void]$metricsOutput.Append((Format-PrometheusMetric `
                    -Name "jellyfin_transcode_process_info" `
                    -Help "Individual active FFmpeg transcode worker instance metadata." `
                    -Type "gauge" `
                    -Samples @(@{
                        Labels = @{
                            pid = [string]$fp.Id
                            hwaccel = if ($isNvenc -eq 1) { "nvenc_cuda" } else { "software" }
                        }
                        Value = 1
                    })))
            }
        }

        # If transcodeCount wasn't populated from API, infer from running FFmpeg workers
        if ($transcodeCount -eq 0 -and $activeFfmpegCount -gt 0) {
            $transcodeCount = $activeFfmpegCount
        }

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_sessions_active_total" `
            -Help "Total number of currently active Jellyfin playback sessions." `
            -Type "gauge" `
            -Samples @(@{ Value = $activeSessionsCount })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_sessions_direct_play_total" `
            -Help "Active direct play playback streams." `
            -Type "gauge" `
            -Samples @(@{ Value = $directPlayCount })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_sessions_direct_stream_total" `
            -Help "Active direct stream container remux playback streams." `
            -Type "gauge" `
            -Samples @(@{ Value = $directStreamCount })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_sessions_transcoding_total" `
            -Help "Active transcode streams requiring real-time audio/video transcoding." `
            -Type "gauge" `
            -Samples @(@{ Value = $transcodeCount })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_transcode_bitrate_bps_total" `
            -Help "Aggregate active video/audio transcoding bitrate in bits per second." `
            -Type "gauge" `
            -Samples @(@{ Value = $totalTranscodeBitrateBps })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_ffmpeg_processes_active" `
            -Help "Number of currently active FFmpeg transcode/subtitle extraction worker processes." `
            -Type "gauge" `
            -Samples @(@{ Value = $activeFfmpegCount })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_ffmpeg_nvenc_processes_active" `
            -Help "Number of FFmpeg worker processes utilizing NVIDIA NVENC / CUDA acceleration." `
            -Type "gauge" `
            -Samples @(@{ Value = $activeNvencFfmpegCount })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_ffmpeg_cpu_time_seconds_total" `
            -Help "Total cumulative CPU time consumed by active FFmpeg transcoding processes." `
            -Type "counter" `
            -Samples @(@{ Value = $ffmpegCpuTotal })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "jellyfin_ffmpeg_memory_working_set_bytes" `
            -Help "Total resident memory consumed by active FFmpeg transcoding processes in bytes." `
            -Type "gauge" `
            -Samples @(@{ Value = $ffmpegRamTotal })))

        if ($sessionSamples.Count -gt 0) {
            [void]$metricsOutput.Append((Format-PrometheusMetric `
                -Name "jellyfin_session_stream_bitrate_bps" `
                -Help "Per-session stream bitrate in bits per second." `
                -Type "gauge" `
                -Samples $sessionSamples))
        }
    } catch {
        # Error handling for Jellyfin metrics
    }

    # =========================================================================
    # 4. NVIDIA GPU Hardware Telemetry (via nvidia-smi)
    # =========================================================================
    try {
        $gpuDetected = 0
        if ($script:NvidiaSmiPath) {
            # Query comprehensive GPU metrics in CSV format
            # Fields: name, temperature.gpu, memory.used, memory.total, memory.free, utilization.gpu, utilization.memory, utilization.encoder, utilization.decoder, power.draw, fan.speed
            $smiOut = & $script:NvidiaSmiPath --query-gpu=index,name,driver_version,temperature.gpu,memory.used,memory.total,memory.free,utilization.gpu,utilization.memory,utilization.encoder,utilization.decoder,power.draw,fan.speed --format=csv,noheader,nounits 2>$null
            if ($smiOut) {
                $gpuDetected = 1
                $lines = $smiOut -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
                foreach ($line in $lines) {
                    $parts = ($line -split ",") | ForEach-Object { $_.Trim() }
                    if ($parts.Count -ge 12) {
                        $gpuIdx = $parts[0]
                        $gpuName = $parts[1]
                        $gpuDriver = $parts[2]
                        $gpuTemp = [double]($parts[3] -replace '[^\d\.]', '')
                        $vramUsedMB = [double]($parts[4] -replace '[^\d\.]', '')
                        $vramTotalMB = [double]($parts[5] -replace '[^\d\.]', '')
                        $vramFreeMB = [double]($parts[6] -replace '[^\d\.]', '')
                        $gpuCoreUtil = [double]($parts[7] -replace '[^\d\.]', '')
                        $vramMemUtil = [double]($parts[8] -replace '[^\d\.]', '')
                        $nvencUtil = [double]($parts[9] -replace '[^\d\.]', '')
                        $nvdecUtil = [double]($parts[10] -replace '[^\d\.]', '')
                        $powerDrawWatts = [double]($parts[11] -replace '[^\d\.]', '')
                        $fanSpeedPercent = if ($parts.Count -ge 13 -and $parts[12] -ne "[Not Supported]" -and $parts[12] -match '^\d+') { [double]$parts[12] } else { 0.0 }

                        $gpuLabels = @{
                            gpu = $gpuIdx
                            model = $gpuName
                            driver = $gpuDriver
                        }

                        $vramTotalBytes = $vramTotalMB * 1024 * 1024
                        $vramUsedBytes = $vramUsedMB * 1024 * 1024
                        $vramFreeBytes = $vramFreeMB * 1024 * 1024
                        $vramRatio = if ($vramTotalBytes -gt 0) { $vramUsedBytes / $vramTotalBytes } else { 0.0 }

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_temperature_celsius" `
                            -Help "NVIDIA GPU core die temperature in degrees Celsius." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $gpuTemp })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_vram_total_bytes" `
                            -Help "Total installed NVIDIA GPU Video RAM (VRAM) in bytes." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $vramTotalBytes })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_vram_used_bytes" `
                            -Help "Currently allocated NVIDIA GPU VRAM in bytes." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $vramUsedBytes })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_vram_free_bytes" `
                            -Help "Currently unallocated NVIDIA GPU VRAM in bytes." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $vramFreeBytes })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_vram_occupancy_ratio" `
                            -Help "NVIDIA GPU VRAM utilization ratio (0.0 to 1.0)." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $vramRatio })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_utilization_gpu_percent" `
                            -Help "NVIDIA GPU core processing engine utilization percent." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $gpuCoreUtil })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_utilization_memory_percent" `
                            -Help "NVIDIA GPU memory controller bandwidth utilization percent." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $vramMemUtil })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_nvenc_utilization_percent" `
                            -Help "NVIDIA NVENC hardware video encoding engine utilization percent." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $nvencUtil })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_nvdec_utilization_percent" `
                            -Help "NVIDIA NVDEC hardware video decoding engine utilization percent." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $nvdecUtil })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_power_draw_watts" `
                            -Help "Current NVIDIA GPU power consumption in Watts." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $powerDrawWatts })))

                        [void]$metricsOutput.Append((Format-PrometheusMetric `
                            -Name "nvidia_gpu_fan_speed_percent" `
                            -Help "NVIDIA GPU cooling fan speed percent." `
                            -Type "gauge" `
                            -Samples @(@{ Labels = $gpuLabels; Value = $fanSpeedPercent })))
                    }
                }
            }
        }

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "nvidia_gpu_available" `
            -Help "Whether an NVIDIA GPU with NVENC acceleration is detected (1=yes, 0=no)." `
            -Type "gauge" `
            -Samples @(@{ Value = $gpuDetected })))
    } catch {
        # Error handling for GPU metrics
    }

    # =========================================================================
    # 5. PotPlayer Client Status
    # =========================================================================
    try {
        $potProcs = Get-Process -Name PotPlayer64, PotPlayer -ErrorAction SilentlyContinue
        $potRunning = if ($potProcs) { 1 } else { 0 }
        $potCpu = 0.0
        $potRam = 0.0

        if ($potProcs) {
            foreach ($pp in $potProcs) {
                $potCpu += $pp.CPU
                $potRam += $pp.WorkingSet64
            }
        }

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "potplayer_client_running" `
            -Help "Whether PotPlayer playback client is currently executing (1=yes, 0=no)." `
            -Type "gauge" `
            -Samples @(@{ Value = $potRunning })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "potplayer_client_memory_working_set_bytes" `
            -Help "PotPlayer client resident working set memory in bytes." `
            -Type "gauge" `
            -Samples @(@{ Value = $potRam })))

        [void]$metricsOutput.Append((Format-PrometheusMetric `
            -Name "potplayer_client_cpu_time_seconds_total" `
            -Help "Cumulative CPU time consumed by PotPlayer client in seconds." `
            -Type "counter" `
            -Samples @(@{ Value = $potCpu })))
    } catch {
        # Error handling for PotPlayer metrics
    }

    return $metricsOutput.ToString()
}

# =============================================================================
# Execution Mode: One-shot (-Once / -OutputFile) or HTTP Server Daemon
# =============================================================================

if ($Once -or $OutputFile) {
    Write-Verbose "Executing single metric collection cycle..."
    $metrics = Collect-AllMetrics
    if ($OutputFile) {
        $dir = Split-Path -Path $OutputFile -Parent
        if ($dir -and (-not (Test-Path $dir))) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [System.IO.File]::WriteAllText($OutputFile, $metrics, [System.Text.Encoding]::UTF8)
        Write-Host "Metrics written to: $OutputFile" -ForegroundColor Green
    }
    if ($Once -or (-not $OutputFile)) {
        Write-Output $metrics
    }
    return
}

# Daemon HTTP Server Mode
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "       MEDIASERVER PROMETHEUS TELEMETRY EXPORTER DAEMON          " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Port             : $Port" -ForegroundColor Gray
Write-Host "Jellyfin URL     : $JellyfinUrl" -ForegroundColor Gray
Write-Host "VFS Cache Path   : $VfsCachePath" -ForegroundColor Gray
Write-Host "Cache Max Limit  : $([math]::Round($VfsCacheLimitBytes / 1GB, 2)) GB" -ForegroundColor Gray
Write-Host "NVIDIA-SMI       : $(if ($script:NvidiaSmiPath) { $script:NvidiaSmiPath } else { 'Not Found' })" -ForegroundColor Gray
Write-Host "Metrics Endpoint : http://localhost:$Port/metrics" -ForegroundColor Green
Write-Host "Press Ctrl+C to terminate exporter daemon." -ForegroundColor Yellow
Write-Host ""

$listener = [System.Net.HttpListener]::new()

if ($ListenAddress) {
    $listener.Prefixes.Add($ListenAddress)
} else {
    try {
        $listener.Prefixes.Add("http://*:$Port/")
        $listener.Start()
    } catch {
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add("http://localhost:$Port/")
        $listener.Start()
    }
}

if (-not $listener.IsListening) {
    $listener.Start()
}

Write-Host "HTTP Server listening on prefixes: $($listener.Prefixes -join ', ')" -ForegroundColor Green

# Cached metrics buffer to prevent disk/CPU hammering on rapid scrapes
$script:LastScrapeTime = [DateTime]::MinValue
$script:CachedMetrics = ""
$script:CacheLock = [System.Object]::new()

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $path = $request.Url.AbsolutePath
        if ($path -eq "/metrics" -or $path -eq "/" -or $path -eq "/metrics/") {
            $now = [DateTime]::UtcNow
            $needsRefresh = $false
            lock ($script:CacheLock) {
                if (($now - $script:LastScrapeTime).TotalSeconds -ge 1.0 -or [string]::IsNullOrEmpty($script:CachedMetrics)) {
                    $needsRefresh = $true
                }
            }

            if ($needsRefresh) {
                $newMetrics = Collect-AllMetrics
                lock ($script:CacheLock) {
                    $script:CachedMetrics = $newMetrics
                    $script:LastScrapeTime = [DateTime]::UtcNow
                }
            }

            $buffer = [System.Text.Encoding]::UTF8.GetBytes($script:CachedMetrics)
            $response.ContentType = "text/plain; version=0.0.4; charset=utf-8"
            $response.StatusCode = 200
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.OutputStream.Close()
        } elseif ($path -eq "/health" -or $path -eq "/ping") {
            $healthMsg = "OK`n"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($healthMsg)
            $response.ContentType = "text/plain; charset=utf-8"
            $response.StatusCode = 200
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.OutputStream.Close()
        } else {
            $response.StatusCode = 404
            $response.OutputStream.Close()
        }
    }
} catch {
    Write-Host "HTTP Listener error: $_" -ForegroundColor Red
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
        $listener.Close()
    }
    Write-Host "Prometheus Telemetry Exporter stopped." -ForegroundColor Gray
}
