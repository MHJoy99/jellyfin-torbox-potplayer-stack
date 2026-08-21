# PotPlayer Playback Scrobbler & Live Progress Sync for Jellyfin
param(
    [string]$MediaPath,
    [string]$ItemId,
    [string]$UserId,
    [string]$Token,
    [string]$ServerUrl = "http://localhost:8096"
)

if (-not $ServerUrl) { $ServerUrl = "http://localhost:8096" }
$ServerUrl = $ServerUrl.TrimEnd('/')

function Send-JellyfinRequest {
    param(
        [string]$Path,
        [string]$Method = "POST",
        [hashtable]$Body = $null
    )
    try {
        $headers = @{
            "Authorization" = "MediaBrowser Client=`"PotPlayer`", Device=`"Windows`", DeviceId=`"PotPlayer-Win32`", Version=`"1.0.0`", Token=`"$Token`""
            "Content-Type" = "application/json"
        }
        $url = "$ServerUrl$Path"
        if ($Body) {
            $jsonBody = $Body | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -Body $jsonBody -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        } else {
            Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
}

function Get-EpisodeDuration {
    param([string]$FilePath)
    try {
        if (Test-Path -LiteralPath $FilePath) {
            $shell = New-Object -ComObject Shell.Application
            $folder = $shell.NameSpace((Split-Path $FilePath))
            $file = $folder.ParseName((Split-Path $FilePath -Leaf))
            # 27 is Duration in Windows Shell properties
            $durStr = $folder.GetDetailsOf($file, 27)
            if ($durStr) {
                $ts = [TimeSpan]::Parse($durStr)
                return $ts.TotalSeconds
            }
        }
    } catch {}
    return 2700 # default 45 mins fallback
}

# 1. Report Playback Started
Send-JellyfinRequest -Path "/Sessions/Playing" -Method "POST" -Body @{
    ItemId = $ItemId
    PlayMethod = "DirectPlay"
    CanSeek = $true
}

$startTime = [DateTime]::UtcNow
$totalDurationSec = Get-EpisodeDuration -FilePath $MediaPath
$isMarkedPlayed = $false
$currentEpisodePath = $MediaPath
$currentItemId = $ItemId

# Map all sibling episodes in the season if available
$parentFolder = Split-Path $MediaPath -Parent
$siblingFiles = @{}
if (Test-Path -LiteralPath $parentFolder) {
    Get-ChildItem -LiteralPath $parentFolder -File | ForEach-Object {
        $cleanBase = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        $siblingFiles[$cleanBase.ToLower()] = $_.FullName
    }
}

# Query Jellyfin to get map of FilePath -> ItemId
$pathToIdMap = @{}
try {
    $headers = @{ "Authorization" = "MediaBrowser Token=`"$Token`"" }
    $itemsResp = Invoke-RestMethod -Uri "$ServerUrl/Items?userId=$UserId&recursive=true&includeItemTypes=Episode,Movie" -Headers $headers -TimeoutSec 5 -ErrorAction SilentlyContinue
    if ($itemsResp -and $itemsResp.Items) {
        foreach ($it in $itemsResp.Items) {
            if ($it.Path) {
                $normalized = $it.Path -replace '^R:\\', 'F:\Media\' -replace '^r:\\', 'F:\Media\'
                $pathToIdMap[$normalized.ToLower()] = $it.Id
                $pathToIdMap[$it.Name.ToLower()] = $it.Id
            }
        }
    }
} catch {}

# Monitor loop while PotPlayer is running
while ($true) {
    Start-Sleep -Seconds 5
    
    $potProcesses = Get-Process -Name "PotPlayerMini64", "PotPlayer64", "PotPlayer" -ErrorAction SilentlyContinue
    if (-not $potProcesses) {
        # PotPlayer was closed
        break
    }

    # Find the active playback title from PotPlayer main window title
    $activeTitle = ""
    foreach ($p in $potProcesses) {
        if ($p.MainWindowTitle) {
            $activeTitle = $p.MainWindowTitle
            break
        }
    }

    $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds
    $ticks = [int64]($elapsed * 10000000)

    # Check if user transitioned to another episode in playlist
    if ($activeTitle) {
        foreach ($baseName in $siblingFiles.Keys) {
            if ($activeTitle.ToLower().Contains($baseName) -and -not $currentEpisodePath.ToLower().Contains($baseName)) {
                # Previous episode finished/switched -> mark previous as played
                if (-not $isMarkedPlayed -and $elapsed -ge 60) {
                    Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST"
                }
                # Switch tracking to new episode
                $currentEpisodePath = $siblingFiles[$baseName]
                if ($pathToIdMap.ContainsKey($currentEpisodePath.ToLower())) {
                    $currentItemId = $pathToIdMap[$currentEpisodePath.ToLower()]
                }
                $startTime = [DateTime]::UtcNow
                $totalDurationSec = Get-EpisodeDuration -FilePath $currentEpisodePath
                $isMarkedPlayed = $false
                Send-JellyfinRequest -Path "/Sessions/Playing" -Method "POST" -Body @{
                    ItemId = $currentItemId
                    PlayMethod = "DirectPlay"
                    CanSeek = $true
                }
                break
            }
        }
    }

    # If watched more than 80% or at least 10 minutes (for short testing), mark played
    if (-not $isMarkedPlayed) {
        if ($elapsed -ge ($totalDurationSec * 0.8) -or ($totalDurationSec -gt 0 -and $elapsed -ge 300 -and $elapsed -ge ($totalDurationSec * 0.5))) {
            Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST"
            $isMarkedPlayed = $true
        }
    }

    # Send progress tick
    Send-JellyfinRequest -Path "/Sessions/Playing/Progress" -Method "POST" -Body @{
        ItemId = $currentItemId
        PositionTicks = $ticks
        PlayMethod = "DirectPlay"
    }
}

# On PotPlayer close: if watched sufficient portion, mark played
$finalElapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds
$finalTicks = [int64]($finalElapsed * 10000000)
if (-not $isMarkedPlayed -and $finalElapsed -ge 120 -and ($finalElapsed -ge ($totalDurationSec * 0.7))) {
    Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST"
}

# Stop session
Send-JellyfinRequest -Path "/Sessions/Playing/Stopped" -Method "POST" -Body @{
    ItemId = $currentItemId
    PositionTicks = $finalTicks
}
