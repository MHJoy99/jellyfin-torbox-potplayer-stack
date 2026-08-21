# Maximum Blazing-Fast Google Drive Mount Script for Media Streaming (Jellyfin / PotPlayer / Windows)
$ErrorActionPreference = 'Stop'

$driveLetter = 'R:'
$remoteName = 'gdrive-media:'
$cacheDir = 'F:\rclone-cache\gdrive-media'
$logDir = Join-Path $env:LOCALAPPDATA 'rclone\logs'
$logFile = Join-Path $logDir 'gdrive-media-mount.log'

New-Item -ItemType Directory -Force -Path $cacheDir, $logDir | Out-Null

# If already mounted, kill old mount to apply new ultra-fast flags
$existing = Get-Process -Name rclone -ErrorAction SilentlyContinue | Where-Object {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)"
    $proc.CommandLine -match 'gdrive-media|gdrive-shared'
}
if ($existing) {
    Write-Host "Stopping existing mount PID $($existing.Id)..."
    $existing | Stop-Process -Force
    Start-Sleep -Seconds 1
}

$arguments = @(
    'mount', $remoteName, $driveLetter,
    '--volname', 'MHJoy Media Server',
    '--network-mode',
    '--cache-dir', $cacheDir,
    '--vfs-cache-mode', 'full',
    '--vfs-cache-max-size', '80G',
    '--vfs-cache-max-age', '4h',
    '--vfs-cache-poll-interval', '30s',
    '--vfs-read-ahead', '256M',
    '--vfs-read-chunk-size', '64M',
    '--vfs-read-chunk-size-limit', '2G',
    '--buffer-size', '128M',
    '--dir-cache-time', '1000h',
    '--poll-interval', '10s',
    '--attr-timeout', '1000h',
    '--drive-pacer-min-sleep', '0ms',
    '--drive-pacer-burst', '200',
    '--drive-chunk-size', '128M',
    '--fast-list',
    '--vfs-fast-fingerprint',
    '--no-checksum',
    '--no-modtime',
    '--transfers', '8',
    '--checkers', '16',
    '--vfs-disk-space-total-size', '5T',
    '--log-level', 'INFO',
    '--log-file', $logFile
)

Start-Process -FilePath 'rclone.exe' -ArgumentList $arguments -WindowStyle Hidden
Write-Host "Blazing-fast Google Drive mounted to $driveLetter (NVMe Cache on $cacheDir)"
