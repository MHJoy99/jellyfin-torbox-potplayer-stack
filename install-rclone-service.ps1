$ErrorActionPreference = 'Stop'

$nssm = 'F:\Jellyfin\server\nssm.exe'
$rcloneExe = 'F:\Jellyfin\server\rclone.exe'
$configFile = 'F:\Jellyfin\config\rclone.conf'
$serviceName = 'RcloneGdriveMount'
$cacheDir = 'F:\rclone-cache\gdrive-media'
$logDir = 'F:\Jellyfin\logs'
$logFile = Join-Path $logDir 'rclone-gdrive.log'
$mountTarget = 'F:\Media'

foreach ($requiredPath in @($nssm, $rcloneExe, $configFile)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file is missing: $requiredPath"
    }
}
New-Item -ItemType Directory -Force -Path $cacheDir, $logDir | Out-Null

# Stop only the Google Drive mount; the separate TorBox mount must remain up.
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -ieq 'rclone.exe' -and [string]$_.CommandLine -match 'mount\s+gdrive-media|gdrive-shared'
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing $serviceName..."
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & $nssm stop $serviceName 2>$null | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service -or $service.Status -eq 'Stopped') { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        throw "Windows has not released the old $serviceName service."
    }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ieq 'rclone.exe' -and [string]$_.CommandLine -match 'mount\s+gdrive-media|gdrive-shared'
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    & $nssm remove $serviceName confirm 2>$null | Out-Null
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        & sc.exe delete $serviceName | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Get-Service -Name $serviceName -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
    }
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        throw "Windows has not released the old $serviceName service after deletion."
    }
}

# Remove the old mountpoint so WinFsp can attach cleanly.
Remove-Item -LiteralPath $mountTarget -Force -Recurse -ErrorAction SilentlyContinue

$rcloneArgs = "mount gdrive-media: `"$mountTarget`" --config `"$configFile`" --cache-dir `"$cacheDir`" --vfs-cache-mode full --vfs-cache-max-size 80G --vfs-cache-max-age 4h --vfs-cache-poll-interval 30s --vfs-read-ahead 128M --vfs-read-chunk-size 16M --vfs-read-chunk-size-limit 2G --buffer-size 64M --dir-cache-time 30s --poll-interval 10s --attr-timeout 30s --rc --rc-addr 127.0.0.1:5573 --rc-no-auth --drive-pacer-min-sleep 0ms --drive-pacer-burst 200 --drive-chunk-size 64M --vfs-fast-fingerprint --no-checksum --no-modtime --async-read=true --transfers 8 --checkers 16 --vfs-disk-space-total-size 5T --log-level INFO --log-file `"$logFile`""

Write-Host "Installing $serviceName..."
& $nssm install $serviceName $rcloneExe $rcloneArgs
if ($LASTEXITCODE -ne 0) { throw "NSSM install failed with exit code $LASTEXITCODE." }
& $nssm set $serviceName AppDirectory 'F:\Jellyfin\server'
& $nssm set $serviceName Description 'High Performance Rclone Mount for Google Drive Media'
& $nssm set $serviceName AppExit Default Restart
& $nssm set $serviceName AppRestartDelay 5000
Set-Service -Name $serviceName -StartupType Automatic

$configuredArgs = (& $nssm get $serviceName AppParameters | Out-String).Trim()
if ($configuredArgs -notmatch '--dir-cache-time 30s' -or $configuredArgs -notmatch '--attr-timeout 30s' -or $configuredArgs -notmatch '--rc-addr 127\.0\.0\.1:5573') {
    throw 'The installed rclone service does not contain the expected cache and RC settings.'
}

Write-Host "Starting $serviceName..."
Start-Service -Name $serviceName
$deadline = [DateTime]::UtcNow.AddSeconds(60)
do {
    $service = Get-Service -Name $serviceName
    if ($service.Status -eq 'Running') { break }
    Start-Sleep -Seconds 1
} while ([DateTime]::UtcNow -lt $deadline)
if ((Get-Service -Name $serviceName).Status -ne 'Running') {
    throw "$serviceName did not reach Running state."
}

Get-Service -Name $serviceName | Select-Object Name, Status, StartType
