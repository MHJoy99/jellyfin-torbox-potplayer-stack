$ErrorActionPreference = 'Stop'

$baseDir = 'F:\Jellyfin'
$serverExe = Join-Path $baseDir 'server\jellyfin.exe'
$dataDir = Join-Path $baseDir 'data'
$configDir = Join-Path $baseDir 'config'
$cacheDir = Join-Path $baseDir 'cache'
$logDir = Join-Path $baseDir 'logs'
$webDir = Join-Path $baseDir 'server\jellyfin-web'
$ffmpegExe = Join-Path $baseDir 'server\ffmpeg.exe'

New-Item -ItemType Directory -Force -Path $dataDir, $configDir, $cacheDir, $logDir, (Join-Path $baseDir 'transcodes') | Out-Null

$running = Get-Process -Name jellyfin -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Jellyfin is already running (PID: $($running.Id -join ', '))"
    exit 0
}

$arguments = @(
    '--datadir', $dataDir,
    '--configdir', $configDir,
    '--cachedir', $cacheDir,
    '--logdir', $logDir,
    '--webdir', $webDir,
    '--ffmpeg', $ffmpegExe
)

Start-Process -FilePath $serverExe -ArgumentList $arguments -WorkingDirectory (Join-Path $baseDir 'server') -WindowStyle Hidden
Write-Host "Started Jellyfin Server on F:\ drive."
