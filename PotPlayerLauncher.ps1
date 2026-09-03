# Bridge script for potplayer:// URL handler
param(
    [string]$RawUrl
)

$potPlayerExe = 'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe'

if (-not $RawUrl) {
    Start-Process $potPlayerExe
    exit 0
}

# Remove protocol prefix
$target = $RawUrl -replace '^potplayer://', ''
# URL decode
$target = [System.Uri]::UnescapeDataString($target)

Write-Host "Opening PotPlayer with target: $target"
Start-Process -FilePath $potPlayerExe -ArgumentList "`"$target`""
