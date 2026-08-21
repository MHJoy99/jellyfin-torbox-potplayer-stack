<#
.SYNOPSIS
    Installs and configures Rclone Mount as a persistent Windows Service via NSSM.
.DESCRIPTION
    Sets up high-performance VFS cache parameters, ensures WinFsp integration,
    creates the service with auto-restart, and performs an immediate mount health check.
#>

param (
    [string]$ServiceName = "RcloneMount",
    [string]$RemoteName = "gdrive:",
    [string]$MountDrive = "X:",
    [string]$RcloneExePath = "C:\rclone\rclone.exe",
    [string]$ConfigPath = "E:\MediaServer\config\rclone.conf",
    [string]$CacheDir = "E:\MediaServer\cache\rclone_vfs",
    [string]$LogFile = "E:\MediaServer\logs\rclone-mount.log",
    [string]$NssmExePath = "C:\nssm\nssm.exe"
)

# 1. Administrator Elevation Check
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsPrincipalRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Administrator permissions required. Elevating..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit 0
    } catch {
        Write-Error "Failed to elevate permissions: $_"
        exit 1
    }
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "       Rclone Windows Service Installation (NSSM)           " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 2. Prerequisites Validation
# A. Ensure directory structures exist
@((Split-Path $ConfigPath), $CacheDir, (Split-Path $LogFile)) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-Host "[+] Created directory: $_" -ForegroundColor Gray
    }
}

# B. Locate rclone.exe
if (-not (Test-Path $RcloneExePath)) {
    $found = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($found) {
        $RcloneExePath = $found.Source
    } elseif (Test-Path "E:\MediaServer\apps\rclone\rclone.exe") {
        $RcloneExePath = "E:\MediaServer\apps\rclone\rclone.exe"
    } else {
        Write-Error "Could not find rclone.exe at '$RcloneExePath' or in system PATH."
        exit 1
    }
}
Write-Host "[+] Using Rclone executable: $RcloneExePath" -ForegroundColor Green

# C. Locate nssm.exe
if (-not (Test-Path $NssmExePath)) {
    $foundNssm = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($foundNssm) {
        $NssmExePath = $foundNssm.Source
    } elseif (Test-Path "E:\MediaServer\apps\nssm\nssm.exe") {
        $NssmExePath = "E:\MediaServer\apps\nssm\nssm.exe"
    } else {
        Write-Error "Could not find nssm.exe. Please install NSSM or specify -NssmExePath."
        exit 1
    }
}
Write-Host "[+] Using NSSM executable: $NssmExePath" -ForegroundColor Green

# D. Verify WinFsp
$winfspService = Get-Service -Name "WinFsp.Launcher" -ErrorAction SilentlyContinue
if (-not $winfspService) {
    Write-Host "[!] WinFsp does not appear to be installed or registered as a service." -ForegroundColor Yellow
    Write-Host "    Rclone mount on Windows requires WinFsp (https://winfsp.dev/)." -ForegroundColor Yellow
} else {
    Write-Host "[+] WinFsp is detected and ready." -ForegroundColor Green
}

# 3. Build Rclone Mount Arguments
$rcloneArgs = @(
    "mount",
    $RemoteName,
    $MountDrive,
    "--config", "`"$ConfigPath`"",
    "--vfs-cache-mode", "full",
    "--vfs-cache-max-size", "200G",
    "--vfs-cache-max-age", "24h",
    "--vfs-read-chunk-size", "64M",
    "--vfs-read-chunk-size-limit", "2G",
    "--buffer-size", "128M",
    "--dir-cache-time", "72h",
    "--cache-dir", "`"$CacheDir`"",
    "--log-file", "`"$LogFile`"",
    "--log-level", "INFO",
    "--network-mode",
    "--rc",
    "--rc-no-auth",
    "--rc-addr", "127.0.0.1:5572"
) -join " "

Write-Host "[*] Service Arguments: $rcloneArgs" -ForegroundColor Gray

# 4. Stop and Remove Existing Service if present
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "[*] Existing service '$ServiceName' found. Stopping and removing..." -ForegroundColor Yellow
    & $NssmExePath stop $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    & $NssmExePath remove $ServiceName confirm | Out-Null
}

# 5. Install Service via NSSM
Write-Host "[*] Creating service '$ServiceName'..." -ForegroundColor Cyan
& $NssmExePath install $ServiceName $RcloneExePath $rcloneArgs
& $NssmExePath set $ServiceName DisplayName "MediaServer Rclone Cloud Mount ($RemoteName -> $MountDrive)"
& $NssmExePath set $ServiceName Description "High-performance VFS cached cloud mount for Jellyfin Media Server."
& $NssmExePath set $ServiceName Start SERVICE_AUTO_START
& $NssmExePath set $ServiceName AppStdout "$LogFile"
& $NssmExePath set $ServiceName AppStderr "$LogFile"
& $NssmExePath set $ServiceName AppRotateFiles 1
& $NssmExePath set $ServiceName AppRotateOnline 1
& $NssmExePath set $ServiceName AppRotateBytes 10485760

# 6. Start Service & Perform Health Check
Write-Host "[*] Starting service '$ServiceName'..." -ForegroundColor Cyan
& $NssmExePath start $ServiceName

Write-Host "[*] Waiting for mount initialization on $MountDrive..." -ForegroundColor Cyan
$mounted = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Path "$MountDrive\") {
        $mounted = $true
        break
    }
}

if ($mounted) {
    Write-Host "[SUCCESS] Rclone mount service is ACTIVE and drive '$MountDrive' is accessible!" -ForegroundColor Green
} else {
    Write-Host "[WARNING] Mount drive '$MountDrive' is not yet mounted. Checking log file..." -ForegroundColor Yellow
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail 10 | Write-Host -ForegroundColor Gray
    }
}
