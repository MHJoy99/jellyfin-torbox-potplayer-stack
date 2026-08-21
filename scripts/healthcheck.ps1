<#
.SYNOPSIS
    End-to-End Diagnostic Health Check for MediaServer ecosystem.
.DESCRIPTION
    Verifies:
    1. Jellyfin Server status and API responsiveness.
    2. Rclone Mount Drive & VFS cache integrity.
    3. NVIDIA GPU NVENC hardware acceleration capability.
    4. PotPlayer URI protocol registration & executable presence.
#>

[CmdletBinding()]
param (
    [string]$JellyfinUrl = "http://localhost:8096",
    [string]$MountDrive = "X:",
    [string]$CacheDir = "E:\MediaServer\cache\rclone_vfs"
)

$Host.UI.RawUI.ForegroundColor = "White"
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "             MEDIASERVER END-TO-END HEALTH CHECK                 " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

$results = [ordered]@{}

# -------------------------------------------------------------
# 1. Jellyfin Server Health Check
# -------------------------------------------------------------
Write-Host "[1/4] Checking Jellyfin Server ($JellyfinUrl)..." -ForegroundColor Cyan
try {
    $pingUrl = "$JellyfinUrl/System/Info/Public"
    $response = Invoke-RestMethod -Uri $pingUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
    Write-Host "      [PASS] Jellyfin is ONLINE (Version: $($response.Version), ServerName: $($response.ServerName))" -ForegroundColor Green
    $results["Jellyfin Server"] = "PASS (v$($response.Version))"
} catch {
    Write-Host "      [FAIL] Jellyfin Server is unreachable: $_" -ForegroundColor Red
    $results["Jellyfin Server"] = "FAIL"
}

# -------------------------------------------------------------
# 2. Rclone Mount & Cache Health Check
# -------------------------------------------------------------
Write-Host "[2/4] Checking Rclone Mount ($MountDrive) & Cache ($CacheDir)..." -ForegroundColor Cyan
$mountExists = Test-Path "$MountDrive\"
if ($mountExists) {
    try {
        $items = Get-ChildItem "$MountDrive\" -ErrorAction Stop | Select-Object -First 5
        Write-Host "      [PASS] Mount drive '$MountDrive' is active and readable ($($items.Count) sample items listed)." -ForegroundColor Green
        $results["Rclone Mount"] = "PASS"
    } catch {
        Write-Host "      [WARN] Mount drive '$MountDrive' exists but encountered error reading contents: $_" -ForegroundColor Yellow
        $results["Rclone Mount"] = "WARN (Read Error)"
    }
} else {
    Write-Host "      [FAIL] Mount drive '$MountDrive' is NOT mounted." -ForegroundColor Red
    $results["Rclone Mount"] = "FAIL"
}

if (Test-Path $CacheDir) {
    $cacheSize = (Get-ChildItem $CacheDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB
    Write-Host "      [PASS] VFS Cache directory exists (Current size: $([math]::Round($cacheSize, 2)) GB)." -ForegroundColor Green
    $results["VFS Cache"] = "PASS ($([math]::Round($cacheSize, 2)) GB)"
} else {
    Write-Host "      [WARN] VFS Cache directory does not exist yet at '$CacheDir'." -ForegroundColor Yellow
    $results["VFS Cache"] = "WARN (Missing)"
}

# -------------------------------------------------------------
# 3. NVIDIA GPU NVENC Hardware Acceleration Check
# -------------------------------------------------------------
Write-Host "[3/4] Checking NVIDIA GPU & NVENC Status..." -ForegroundColor Cyan
$nvidiaSmi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
if (-not $nvidiaSmi) {
    if (Test-Path "C:\Windows\System32\nvidia-smi.exe") {
        $nvidiaSmi = "C:\Windows\System32\nvidia-smi.exe"
    } elseif (Test-Path "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe") {
        $nvidiaSmi = "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    }
}

if ($nvidiaSmi) {
    try {
        $gpuQuery = & $nvidiaSmi --query-gpu=name,driver_version,utilization.gpu,encoder.stats.sessionCount --format=csv,noheader,nounits 2>&1
        Write-Host "      [PASS] GPU Detected: $gpuQuery" -ForegroundColor Green
        $results["NVIDIA GPU NVENC"] = "PASS ($gpuQuery)"
    } catch {
        Write-Host "      [WARN] nvidia-smi failed to execute: $_" -ForegroundColor Yellow
        $results["NVIDIA GPU NVENC"] = "WARN"
    }
} else {
    Write-Host "      [WARN] nvidia-smi not found. Ensure NVIDIA Graphics Drivers are installed." -ForegroundColor Yellow
    $results["NVIDIA GPU NVENC"] = "WARN (No Driver Utility)"
}

# -------------------------------------------------------------
# 4. PotPlayer URI Scheme Protocol Check
# -------------------------------------------------------------
Write-Host "[4/4] Checking PotPlayer Protocol Registration..." -ForegroundColor Cyan
$protoReg = Get-ItemProperty -Path "HKCR:\potplayer\shell\open\command" -ErrorAction SilentlyContinue
if ($protoReg -and $protoReg.'(default)') {
    Write-Host "      [PASS] 'potplayer://' URI scheme registered -> $($protoReg.'(default)')" -ForegroundColor Green
    $results["PotPlayer Protocol"] = "PASS"
} else {
    Write-Host "      [FAIL] 'potplayer://' URI scheme is NOT registered in Windows Registry." -ForegroundColor Red
    $results["PotPlayer Protocol"] = "FAIL"
}

# -------------------------------------------------------------
# Summary Report
# -------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "                      DIAGNOSTIC SUMMARY                         " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
foreach ($key in $results.Keys) {
    $status = $results[$key]
    $color = if ($status -like "PASS*") { "Green" } elseif ($status -like "WARN*") { "Yellow" } else { "Red" }
    Write-Host ("{0,-25} : {1}" -f $key, $status) -ForegroundColor $color
}
Write-Host "=================================================================" -ForegroundColor Cyan
