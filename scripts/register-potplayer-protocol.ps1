<#
.SYNOPSIS
    Registers custom potplayer:// and potplayer64:// protocol handlers in Windows Registry.
.DESCRIPTION
    Ensures PotPlayer is launched cleanly when custom URI schemes are invoked from Jellyfin Web,
    browsers, or external scrobblers/trackers. Requires Administrator privileges.
#>

# Requires Run as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsPrincipalRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Script must be run as Administrator to write to HKEY_CLASSES_ROOT / HKEY_LOCAL_MACHINE." -ForegroundColor Yellow
    Write-Host "[*] Attempting to elevate privileges..." -ForegroundColor Cyan
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit 0
    } catch {
        Write-Error "Failed to elevate permissions: $_"
        exit 1
    }
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   PotPlayer Custom URI Protocol Registration Utility      " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 1. Locate PotPlayer Executable
$potentialPaths = @(
    "C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe",
    "C:\Program Files\DAUM\PotPlayer\PotPlayer64.exe",
    "C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe",
    "C:\Program Files (x86)\DAUM\PotPlayer\PotPlayer.exe",
    "E:\PotPlayer\PotPlayerMini64.exe",
    "E:\MediaServer\apps\PotPlayer\PotPlayerMini64.exe"
)

$potPlayerExe = $null
foreach ($path in $potentialPaths) {
    if (Test-Path -Path $path) {
        $potPlayerExe = $path
        break
    }
}

if (-not $potPlayerExe) {
    # Check registry App Paths
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini64.exe"
    if (Test-Path $regPath) {
        $potPlayerExe = (Get-ItemProperty -Path $regPath).'(default)'
    }
}

if (-not $potPlayerExe -or -not (Test-Path $potPlayerExe)) {
    Write-Host "[!] Could not automatically detect PotPlayer executable." -ForegroundColor Yellow
    $potPlayerExe = Read-Host "Please enter the full path to PotPlayerMini64.exe (e.g. C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe)"
    if (-not (Test-Path $potPlayerExe)) {
        Write-Error "Provided path does not exist: $potPlayerExe"
        exit 1
    }
}

Write-Host "[+] Found PotPlayer executable at: $potPlayerExe" -ForegroundColor Green

# 2. Define Protocols to Register
$protocols = @("potplayer", "potplayer64")

foreach ($proto in $protocols) {
    $rootKey = "HKCR:\$proto"
    Write-Host "[*] Registering '$proto://' protocol handler..." -ForegroundColor Cyan

    try {
        # Create / Overwrite root protocol key
        if (-not (Test-Path $rootKey)) {
            New-Item -Path $rootKey -Force | Out-Null
        }
        Set-ItemProperty -Path $rootKey -Name "(Default)" -Value "URL:PotPlayer Protocol" -Force
        Set-ItemProperty -Path $rootKey -Name "URL Protocol" -Value "" -Force

        # DefaultIcon
        $iconKey = "$rootKey\DefaultIcon"
        if (-not (Test-Path $iconKey)) {
            New-Item -Path $iconKey -Force | Out-Null
        }
        Set-ItemProperty -Path $iconKey -Name "(Default)" -Value "`"$potPlayerExe`",0" -Force

        # shell\open\command
        $cmdKey = "$rootKey\shell\open\command"
        if (-not (Test-Path $cmdKey)) {
            New-Item -Path $cmdKey -Force | Out-Null
        }
        # Windows command line syntax to pass %1 as parameter
        $commandValue = "`"$potPlayerExe`" `"%1`""
        Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value $commandValue -Force

        Write-Host "[+] Successfully registered protocol '$proto://'" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to configure registry keys for '$proto': $_"
    }
}

Write-Host ""
Write-Host "[+] Verification:" -ForegroundColor Cyan
foreach ($proto in $protocols) {
    $cmd = (Get-ItemProperty -Path "HKCR:\$proto\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
    Write-Host "    $proto -> $cmd" -ForegroundColor White
}

Write-Host ""
Write-Host "[SUCCESS] Protocol registration completed successfully." -ForegroundColor Green
