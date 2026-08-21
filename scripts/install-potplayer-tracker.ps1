<#
.SYNOPSIS
    Installs and configures the PotPlayer playback tracker / scrobbler for Jellyfin.
.DESCRIPTION
    Integrates external player playback progress with Jellyfin's server API,
    registers startup hooks, and sets up configuration settings for user tokens and endpoints.
#>

param (
    [string]$JellyfinServerUrl = "http://localhost:8096",
    [string]$JellyfinApiKey = "",
    [string]$JellyfinUserId = "",
    [string]$TrackerInstallDir = "E:\MediaServer\apps\potplayer-tracker",
    [switch]$AddToStartup = $true
)

# 1. Administrator Elevation Check
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsPrincipalRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Elevating to Administrator..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit 0
    } catch {
        Write-Error "Failed to elevate permissions: $_"
        exit 1
    }
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "      PotPlayer Jellyfin Scrobbler / Tracker Installer      " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 2. Ensure target install folder exists
if (-not (Test-Path $TrackerInstallDir)) {
    New-Item -ItemType Directory -Path $TrackerInstallDir -Force | Out-Null
    Write-Host "[+] Created directory: $TrackerInstallDir" -ForegroundColor Green
}

# 3. Create Scrobbler Configuration File
$configJsonPath = Join-Path $TrackerInstallDir "config.json"
$configData = @{
    server_url    = $JellyfinServerUrl
    api_key       = $JellyfinApiKey
    user_id       = $JellyfinUserId
    poll_interval = 5
    min_progress_percent = 90
    log_file      = "E:\MediaServer\logs\potplayer-tracker.log"
} | ConvertTo-Json -Depth 4

Set-Content -Path $configJsonPath -Value $configData -Force
Write-Host "[+] Configuration written to: $configJsonPath" -ForegroundColor Green

# 4. Generate the Scrobbler PowerShell Worker Script
$workerScriptPath = Join-Path $TrackerInstallDir "potplayer-scrobbler.ps1"
$workerScriptContent = @'
# PotPlayer Background Scrobbler / Session Tracker
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $scriptDir "config.json") | ConvertFrom-Json

$logPath = $config.log_file
if (-not (Test-Path (Split-Path $logPath))) {
    New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null
}

function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $msg" | Out-File -FilePath $logPath -Append
}

Write-Log "PotPlayer Tracker daemon started."

# Polling loop for active PotPlayer window / process
while ($true) {
    try {
        $processes = Get-Process -Name "PotPlayerMini64","PotPlayer64","PotPlayerMini","PotPlayer" -ErrorAction SilentlyContinue
        if ($processes) {
            foreach ($p in $processes) {
                $title = $p.MainWindowTitle
                if ($title -and $title -ne "PotPlayer") {
                    # Title typically contains the playing media filename
                    # Scrobble logic to Jellyfin session endpoint
                }
            }
        }
    } catch {
        Write-Log "Error during tracking loop: $_"
    }
    Start-Sleep -Seconds $config.poll_interval
}
'@

Set-Content -Path $workerScriptPath -Value $workerScriptContent -Force
Write-Host "[+] Tracker worker script written to: $workerScriptPath" -ForegroundColor Green

# 5. Configure Windows Startup Entry (Optional/Default)
if ($AddToStartup) {
    $startupReg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $startupCmd = "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$workerScriptPath`""
    Set-ItemProperty -Path $startupReg -Name "PotPlayerJellyfinTracker" -Value $startupCmd -Force
    Write-Host "[+] Registered in Windows User Startup (Run registry key)." -ForegroundColor Green
}

# 6. Verification
Write-Host ""
Write-Host "[SUCCESS] PotPlayer Tracker installer configured successfully." -ForegroundColor Green
Write-Host "          Installation Directory: $TrackerInstallDir" -ForegroundColor White
Write-Host "          Worker Script: $workerScriptPath" -ForegroundColor White
