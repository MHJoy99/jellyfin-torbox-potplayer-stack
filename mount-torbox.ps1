# Maximum Blazing-Fast Torbox WebDAV Mount Script for Media Streaming (Jellyfin / PotPlayer / Windows)
$ErrorActionPreference = 'Stop'

$driveLetter = 'T:'
$remoteName = 'torbox:'
$cacheDir = 'F:\rclone-cache\torbox'
$logDir = Join-Path $env:LOCALAPPDATA 'rclone\logs'
$logFile = Join-Path $logDir 'torbox-mount.log'

New-Item -ItemType Directory -Force -Path $cacheDir, $logDir | Out-Null

# Log rotation if >100MB (prevent unbounded growth on long-lived mount)
if (Test-Path -LiteralPath $logFile) {
    if ((Get-Item -LiteralPath $logFile).Length -gt 100MB) {
        $rotated = "$logFile.old"
        Move-Item -LiteralPath $logFile -Destination $rotated -Force
    }
}

$existing = Get-Process -Name rclone -ErrorAction SilentlyContinue | Where-Object {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue
    $proc.CommandLine -match 'mount torbox:'
}

# Idempotent guard: a live mount serving T:\ must NEVER be restarted — the old
# behavior killed a healthy mount on every supervisor/panel retry, and the fresh
# cold mount never finished WinFsp init inside the 30s wait, causing a perpetual
# kill-loop (2026-09-05: torboxmount fail #700+, T:\ flapping).
if ($existing -and (Test-Path -LiteralPath "${driveLetter}\")) {
    Write-Host "Torbox mount already healthy (PID $($existing.Id), ${driveLetter}\ present); leaving it alone."
    return
}
if ($existing) {
    Write-Host "Stopping existing Torbox mount PID $($existing.Id)..."
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:5572/mount/unmount' -Method Post -TimeoutSec 10 | Out-Null
    } catch {
        Write-Host "rc unmount failed (continuing to Stop-Process): $($_.Exception.Message)"
    }
    $existing | Stop-Process -Force
    Start-Sleep -Seconds 10
}

$argString = "mount $remoteName $driveLetter " +
    '--volname "Torbox Debrid Media" ' +
    '--network-mode ' +
    "--cache-dir `"$cacheDir`" " +
    '--vfs-cache-mode full ' +
    '--vfs-cache-max-size 25G ' +
    '--vfs-cache-max-age 12h ' +
    '--vfs-cache-min-free-space 30G ' +
    '--vfs-cache-poll-interval 1m ' +
    '--vfs-write-back 10s ' +
    '--vfs-read-ahead 128M ' +
    '--vfs-read-chunk-size 32M ' +
    '--vfs-read-chunk-size-limit 256M ' +
    '--buffer-size 32M ' +
    '--async-read=true ' +
    '--dir-cache-time 15m ' +
    '--poll-interval 0 ' +
    '--attr-timeout 5m ' +
    '--tpslimit 5 ' +
    '--tpslimit-burst 10 ' +
    '--timeout 30s ' +
    '--contimeout 20s ' +
    '--retries 5 ' +
    '--low-level-retries 10 ' +
    '--retries-sleep 2s ' +
    '--rc --rc-addr 127.0.0.1:5572 --rc-no-auth ' +
    '--vfs-fast-fingerprint ' +
    '--no-checksum ' +
    '--no-modtime ' +
    '--vfs-disk-space-total-size 10T ' +
    '--exclude "DDK-*/**" ' +
    '--exclude "Meccha Chameleon/**" ' +
    '--exclude "Oni Chichi*/**" ' +
    '--exclude "*Mujin Eki*/**" ' +
    '--exclude "*[Hh]entai*/**" ' +
    '--log-level INFO ' +
    "--log-file `"$logFile`""

Start-Process -FilePath 'rclone.exe' -ArgumentList $argString -WindowStyle Hidden
Write-Host "Blazing-fast Torbox Debrid mounted to $driveLetter (NVMe Cache on $cacheDir)"
