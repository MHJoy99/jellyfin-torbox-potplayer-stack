# ==============================================================================
# NexusMedia: Prometheus / Grafana Telemetry Exporter
# ==============================================================================

param(
    [int]$Port = 9100,
    [string]$ServerUrl = "http://localhost:8096"
)

Write-Host "Starting NexusMedia Prometheus Exporter on port $Port..." -ForegroundColor Cyan

function Get-NvidiaGpuMetrics {
    $metrics = [System.Collections.Generic.List[string]]::new()
    try {
        $smiOut = & "nvidia-smi" --query-gpu=temperature.gpu,utilization.gpu,utilization.memory,utilization.encoder,utilization.decoder,memory.used,memory.total --format=csv,noheader,nounits 2>$null
        if ($smiOut) {
            $parts = $smiOut.Split(',') | ForEach-Object { [double]($_.Trim()) }
            if ($parts.Length -ge 7) {
                $metrics.Add("# HELP media_gpu_temperature_celsius Current GPU temperature in Celsius")
                $metrics.Add("# TYPE media_gpu_temperature_celsius gauge")
                $metrics.Add("media_gpu_temperature_celsius $($parts[0])")

                $metrics.Add("# HELP media_gpu_utilization_percent GPU core utilization percentage")
                $metrics.Add("# TYPE media_gpu_utilization_percent gauge")
                $metrics.Add("media_gpu_utilization_percent $($parts[1])")

                $metrics.Add("# HELP media_gpu_encoder_utilization_percent NVENC hardware encoder utilization")
                $metrics.Add("# TYPE media_gpu_encoder_utilization_percent gauge")
                $metrics.Add("media_gpu_encoder_utilization_percent $($parts[3])")

                $metrics.Add("# HELP media_gpu_decoder_utilization_percent NVDEC hardware decoder utilization")
                $metrics.Add("# TYPE media_gpu_decoder_utilization_percent gauge")
                $metrics.Add("media_gpu_decoder_utilization_percent $($parts[4])")

                $metrics.Add("# HELP media_gpu_memory_used_bytes GPU VRAM currently occupied")
                $metrics.Add("# TYPE media_gpu_memory_used_bytes gauge")
                $metrics.Add("media_gpu_memory_used_bytes $($parts[5] * 1024 * 1024)")
            }
        }
    } catch {}
    return $metrics
}

function Get-RcloneCacheMetrics {
    $metrics = [System.Collections.Generic.List[string]]::new()
    try {
        $cacheDir = "F:\rclone-cache\gdrive-media"
        if (Test-Path $cacheDir) {
            $files = Get-ChildItem -Path $cacheDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            $bytes = if ($files.Sum) { $files.Sum } else { 0 }
            $count = if ($files.Count) { $files.Count } else { 0 }

            $metrics.Add("# HELP media_rclone_cache_bytes Current VFS cache size on NVMe SSD")
            $metrics.Add("# TYPE media_rclone_cache_bytes gauge")
            $metrics.Add("media_rclone_cache_bytes $bytes")

            $metrics.Add("# HELP media_rclone_cached_objects Total cached chunks & objects")
            $metrics.Add("# TYPE media_rclone_cached_objects gauge")
            $metrics.Add("media_rclone_cached_objects $count")
        }
    } catch {}
    return $metrics
}

function Get-JellyfinMetrics {
    $metrics = [System.Collections.Generic.List[string]]::new()
    try {
        $jellyProc = Get-Process -Name "jellyfin" -ErrorAction SilentlyContinue
        if ($jellyProc) {
            $metrics.Add("# HELP media_jellyfin_process_active Jellyfin server running status (1 = active)")
            $metrics.Add("# TYPE media_jellyfin_process_active gauge")
            $metrics.Add("media_jellyfin_process_active 1")

            $metrics.Add("# HELP media_jellyfin_memory_bytes Jellyfin working set RAM usage")
            $metrics.Add("# TYPE media_jellyfin_memory_bytes gauge")
            $metrics.Add("media_jellyfin_memory_bytes $($jellyProc.WorkingSet64)")
        } else {
            $metrics.Add("media_jellyfin_process_active 0")
        }
    } catch {}
    return $metrics
}

# Start HTTP Listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://*:$Port/metrics/")
try {
    $listener.Start()
    Write-Host "Exporter actively listening on http://localhost:$Port/metrics" -ForegroundColor Green
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $response = $context.Response
        
        $output = [System.Collections.Generic.List[string]]::new()
        $output.AddRange((Get-NvidiaGpuMetrics))
        $output.AddRange((Get-RcloneCacheMetrics))
        $output.AddRange((Get-JellyfinMetrics))
        
        $payload = ($output -join "`n") + "`n"
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($payload)
        
        $response.ContentType = "text/plain; version=0.0.4; charset=utf-8"
        $response.ContentLength64 = $buffer.Length
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.OutputStream.Close()
    }
} finally {
    $listener.Stop()
}
