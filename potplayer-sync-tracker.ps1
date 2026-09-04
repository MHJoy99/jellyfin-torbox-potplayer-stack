# PotPlayer Playback Scrobbler & Live Progress Sync for Jellyfin (rewritten)
# Launcher: hidden per play, args: -MediaPath -ItemId -UserId -Token -ServerUrl
# MediaPath is often http://127.0.0.1:8888/torbox/<tid>/<fid>/ proxy URL or a T:\ local path.
# Stdlib PowerShell only. No Shell COM. All Jellyfin calls TimeoutSec 5 + SilentlyContinue, never throw.
param(
    [string]$MediaPath,
    [string]$ItemId,
    [string]$UserId,
    [string]$Token,
    [string]$ServerUrl = "http://localhost:8096",
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
if (-not $ServerUrl) { $ServerUrl = "http://localhost:8096" }
$ServerUrl = $ServerUrl.TrimEnd('/')

# --- (5) Singleton per ItemId: Global\PotPlayerTracker_<8charItemPrefix>, second instance exits ---
$mutex = $null
$mutexCreated = $false
$mutexHeld = $false
if ($ItemId) {
    $prefix = $ItemId
    if ($prefix.Length -gt 8) { $prefix = $prefix.Substring(0, 8) }
    $mutexName = "Global\PotPlayerTracker_$prefix"
    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName, ([ref]$mutexCreated))
        if ($mutexCreated) {
            $mutexHeld = $true
        } else {
            return
        }
    } catch {
        if ($_.Exception -is [System.Threading.AbandonedMutexException]) {
            $mutexHeld = $true
            $mutexCreated = $true
        } else {
            $mutex = $null
            $mutexHeld = $false
        }
    }
}

# --- Tracker resilience: backoff + DryRun (additive; event-free loop so $script: state is safe) ---
$script:trkConsecutiveFailures = 0
$script:trkBackoffSec = 0
$script:trkNextRetryUtc = [DateTime]::MinValue

function Write-TrackerLog {
    param([string]$Message)
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Write-Output "[$ts] $Message"
    } catch {}
}

function Get-TrkBackoffSeconds {
    param([int]$Failures)
    try {
        if ($Failures -le 0) { return 0 }
        $s = [math]::Pow(2, $Failures)
        if ($s -gt 60) { $s = 60 }
        return [int]$s
    } catch { return 5 }
}

function Test-JellyfinBackoff {
    try {
        if ([DateTime]::UtcNow -lt $script:trkNextRetryUtc) { return $false }
    } catch {}
    return $true
}

function Register-JellyfinSuccess {
    try {
        $script:trkConsecutiveFailures = 0
        $script:trkBackoffSec = 0
        $script:trkNextRetryUtc = [DateTime]::MinValue
    } catch {}
}

function Register-JellyfinFailure {
    try {
        $script:trkConsecutiveFailures++
        $script:trkBackoffSec = Get-TrkBackoffSeconds -Failures $script:trkConsecutiveFailures
        $script:trkNextRetryUtc = [DateTime]::UtcNow.AddSeconds($script:trkBackoffSec)
        Write-TrackerLog "Jellyfin down (failures=$($script:trkConsecutiveFailures)), backing off $($script:trkBackoffSec)s."
    } catch {}
}

function Send-JellyfinRequest {
    param(
        [string]$Path,
        [string]$Method = "POST",
        [hashtable]$Body = $null,
        [switch]$Force
    )
    # DryRun: log-only, never HTTP (manual testing; launcher never passes -DryRun).
    if ($DryRun) {
        try {
            $summary = "$Method $Path"
            if ($Body -and $Body.ContainsKey('PositionTicks')) { $summary += " PositionTicks=$($Body['PositionTicks'])" }
            if ($Body -and $Body.ContainsKey('ItemId')) { $summary += " ItemId=$($Body['ItemId'])" }
            Write-TrackerLog "[DryRun] $summary"
        } catch {}
        return
    }
    # Backoff gate: skip non-critical traffic while Jellyfin is down (Force bypasses for Played/Stopped).
    if (-not $Force) {
        if (-not (Test-JellyfinBackoff)) { return }
    }
    try {
        $headers = @{
            "Authorization" = "MediaBrowser Client=`"PotPlayer`", Device=`"Windows`", DeviceId=`"PotPlayer-Win32`", Version=`"1.0.0`", Token=`"$Token`""
            "Content-Type" = "application/json"
        }
        $url = "$ServerUrl$Path"
        if ($Body) {
            $jsonBody = $Body | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -Body $jsonBody -TimeoutSec 5 -ErrorAction Stop | Out-Null
        } else {
            Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -TimeoutSec 5 -ErrorAction Stop | Out-Null
        }
        Register-JellyfinSuccess
    } catch {
        Register-JellyfinFailure
    }
}

function Get-JellyfinJson {
    param([string]$Path, [switch]$Force)
    if ($DryRun) {
        try { Write-TrackerLog "[DryRun] GET $Path" } catch {}
        return $null
    }
    if (-not $Force -and -not (Test-JellyfinBackoff)) { return $null }
    try {
        $headers = @{
            "Authorization" = "MediaBrowser Client=`"PotPlayer`", Device=`"Windows`", DeviceId=`"PotPlayer-Win32`", Version=`"1.0.0`", Token=`"$Token`""
        }
        $url = "$ServerUrl$Path"
        $r = Invoke-RestMethod -Uri $url -Method GET -Headers $headers -TimeoutSec 5 -ErrorAction Stop
        Register-JellyfinSuccess
        return $r
    } catch {
        Register-JellyfinFailure
    }
    return $null
}

function Test-IsPausedTitle {
    param([string]$Title)
    try {
        if ([string]::IsNullOrEmpty($Title)) { return $false }
        if ($Title.Contains("||")) { return $true }
        $t = $Title.ToLower()
        if ($t.Contains("paused")) { return $true }
        if ($t.Contains("[pause]")) { return $true }
    } catch {}
    return $false
}

$proxyLogPath = "F:\Jellyfin\logs\torbox-proxy.log"

function Get-LatestProxyEntry {
    try {
        if (-not (Test-Path -LiteralPath $proxyLogPath)) { return $null }
        $fi = Get-Item -LiteralPath $proxyLogPath -ErrorAction SilentlyContinue
        if (-not $fi) { return $null }
        if ($fi.LastWriteTimeUtc -and (([DateTime]::UtcNow - $fi.LastWriteTimeUtc).TotalSeconds -gt 60)) { return $null }
        $lines = Get-Content -LiteralPath $proxyLogPath -Tail 40 -ErrorAction SilentlyContinue
        if (-not $lines) { return $null }
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $ln = $lines[$i]
            if ([string]::IsNullOrEmpty($ln)) { continue }
            if ($ln -match 'Proxy torbox\s+(\S+)/(\S+)\s+(.+)') {
                $tid = $Matches[1].Trim()
                $fid = $Matches[2].Trim()
                $nm = $Matches[3].Trim().Trim('"').Trim("'").Trim()
                if (-not $nm) { continue }
                # If line carries an embedded timestamp, require it within last 60s.
                $m2 = [regex]::Match($ln, '(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})')
                if ($m2.Success) {
                    $ts = $null
                    try { $ts = [DateTime]::Parse($m2.Groups[1].Value) } catch { $ts = $null }
                    if ($ts -ne $null) {
                        try { $ts = $ts.ToUniversalTime() } catch {}
                        if (([DateTime]::UtcNow - $ts).TotalSeconds -gt 60) { return $null }
                    }
                }
                $key = "$tid/$fid/$nm"
                return @{ Tid = $tid; Fid = $fid; Name = $nm; Key = $key }
            }
        }
    } catch {}
    return $null
}

function Get-SeasonEpisodes {
    param([string]$SeriesId, [string]$SeasonId)
    try {
        if (-not $SeriesId -or -not $UserId) { return @() }
        $q = "/Shows/$SeriesId/Episodes?UserId=$UserId&Fields=Path"
        if ($SeasonId) { $q += "&SeasonId=$SeasonId" }
        $r = Get-JellyfinJson -Path $q
        if ($r -and $r.Items) { return @($r.Items) }
    } catch {}
    return @()
}

function Find-EpisodeByName {
    param($Episodes, [string]$ProxyName)
    try {
        if (-not $Episodes -or -not $ProxyName) { return $null }
        $leaf = $ProxyName.Trim()
        try { $leaf = [System.IO.Path]::GetFileName($ProxyName.Trim()) } catch {}
        if (-not $leaf) { $leaf = $ProxyName.Trim() }
        $leafLower = $leaf.ToLower()
        $stemLower = $leafLower
        try { $stemLower = [System.IO.Path]::GetFileNameWithoutExtension($leaf).ToLower() } catch {}
        foreach ($ep in $Episodes) {
            $epLeaf = $null
            if ($ep.Path) { try { $epLeaf = [System.IO.Path]::GetFileName($ep.Path) } catch {} }
            if ($epLeaf -and ($epLeaf.ToLower() -eq $leafLower)) { return $ep }
            if ($epLeaf) {
                try {
                    if ([System.IO.Path]::GetFileNameWithoutExtension($epLeaf).ToLower() -eq $stemLower) { return $ep }
                } catch {}
            }
            if ($ep.Name -and ($ep.Name.ToLower() -eq $leafLower -or $ep.Name.ToLower() -eq $stemLower)) { return $ep }
        }
        foreach ($ep in $Episodes) {
            if ($ep.Name -and $ep.Name.Length -ge 4) {
                $n = $ep.Name.ToLower()
                if ($leafLower.Contains($n) -or $stemLower.Contains($n)) { return $ep }
            }
        }
    } catch {}
    return $null
}

function Get-DurationFromItem {
    param($Item)
    try {
        if ($Item -and $Item.RunTimeTicks) {
            $s = [double]$Item.RunTimeTicks / 10000000.0
            if ($s -gt 0) { return $s }
        }
    } catch {}
    return 2700.0
}

# --- (1) Duration AND resume from Jellyfin ---
$totalDurationSec = 2700.0
$resumeSec = 0
$seasonId = $null
$seriesId = $null
try {
    if ($ItemId -and $UserId) {
        $detail = Get-JellyfinJson -Path "/Users/$UserId/Items/$ItemId" -Force
        if ($detail) {
            $totalDurationSec = Get-DurationFromItem -Item $detail
            try { if ($detail.SeasonId) { $seasonId = [string]$detail.SeasonId } } catch {}
            try { if ($detail.SeriesId) { $seriesId = [string]$detail.SeriesId } } catch {}
        }
    }
} catch {}
try {
    if ($ItemId -and $UserId) {
        $ud = Get-JellyfinJson -Path "/Users/$UserId/Items/$ItemId/UserData" -Force
        $ppt = $null
        try { if ($ud -and $ud.PlaybackPositionTicks) { $ppt = $ud.PlaybackPositionTicks } } catch {}
        try { if ((-not $ppt) -and $ud -and $ud.UserData -and $ud.UserData.PlaybackPositionTicks) { $ppt = $ud.UserData.PlaybackPositionTicks } } catch {}
        if ($ppt -and ([double]$ppt -gt 0)) {
            $resumeSec = [int]([double]$ppt / 10000000.0)
            if ($resumeSec -lt 0) { $resumeSec = 0 }
        }
    }
} catch {}
if ($totalDurationSec -le 0) { $totalDurationSec = 2700.0 }
if ($resumeSec -lt 0) { $resumeSec = 0 }

# Very first stdout line for launcher resume-seek wiring. Also returned at script end.
Write-Output "RESUME=$resumeSec"
if ($DryRun) { Write-TrackerLog "[DryRun] Tracker start ItemId=$ItemId UserId=$UserId Resume=${resumeSec}s Duration=${totalDurationSec}s." }
$initialResumeSec = $resumeSec

# 1. Report Playback Started
Send-JellyfinRequest -Path "/Sessions/Playing" -Method "POST" -Body @{
    ItemId = $ItemId
    PlayMethod = "DirectPlay"
    CanSeek = $true
}

$startTime = [DateTime]::UtcNow
$pausedSeconds = 0.0
$currentResumeSec = [double]$resumeSec
$isMarkedPlayed = $false
$currentEpisodePath = $MediaPath
$currentItemId = $ItemId
$currentLabel = $MediaPath

# Season episode cache for proxy-name -> episode mapping
$seasonEpisodes = @()
try {
    if ($seriesId) { $seasonEpisodes = @(Get-SeasonEpisodes -SeriesId $seriesId -SeasonId $seasonId) }
} catch { $seasonEpisodes = @() }

# Fallback map: local sibling files (only when MediaPath is a local file)
$siblingFiles = @{}
try {
    $parentFolder = $null
    try { $parentFolder = Split-Path $MediaPath -Parent } catch {}
    if ($parentFolder -and (Test-Path -LiteralPath $parentFolder)) {
        $files = Get-ChildItem -LiteralPath $parentFolder -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            try {
                $cleanBase = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                if ($cleanBase) { $siblingFiles[$cleanBase.ToLower()] = $f.FullName }
            } catch {}
        }
    }
} catch {}

# Baseline proxy key at startup so current playback line does not trigger a false switch
$lastProxyKey = $null
try {
    $base = Get-LatestProxyEntry
    if ($base -and $base.Key) { $lastProxyKey = $base.Key }
} catch {}

# Monitor loop while PotPlayer is running
while ($true) {
    Start-Sleep -Seconds 5

    $potProcesses = Get-Process -Name "PotPlayerMini64", "PotPlayer64", "PotPlayer" -ErrorAction SilentlyContinue
    if (-not $potProcesses) {
        break
    }

    $activeTitle = ""
    foreach ($p in $potProcesses) {
        try {
            if ($p.MainWindowTitle) {
                $activeTitle = $p.MainWindowTitle
                break
            }
        } catch {}
    }

    # --- (2) Pause-aware position: wall-clock minus detected pauses ---
    try {
        if (Test-IsPausedTitle -Title $activeTitle) { $pausedSeconds += 5.0 }
    } catch {}

    $now = [DateTime]::UtcNow
    $elapsed = ($now - $startTime).TotalSeconds
    if ($elapsed -lt 0) { $elapsed = 0 }
    $segmentWatched = $elapsed - $pausedSeconds
    if ($segmentWatched -lt 0) { $segmentWatched = 0 }
    $posSec = $currentResumeSec + $segmentWatched
    if ($posSec -lt 0) { $posSec = 0 }
    if ($totalDurationSec -gt 0 -and $posSec -gt $totalDurationSec) { $posSec = $totalDurationSec }
    $ticks = [int64]($posSec * 10000000)

    $switched = $false

    # --- (3a) Primary episode-switch: torbox-proxy.log ---
    try {
        $proxy = Get-LatestProxyEntry
        if ($proxy -and $proxy.Key -and ($proxy.Key -ne $lastProxyKey)) {
            $lastProxyKey = $proxy.Key
            $mapped = Find-EpisodeByName -Episodes $seasonEpisodes -ProxyName $proxy.Name
            if (-not $mapped) {
                # Refresh parent + season once, then retry (covers stale cache)
                try {
                    if ($currentItemId -and $UserId) {
                        $cd = Get-JellyfinJson -Path "/Users/$UserId/Items/$currentItemId"
                        if ($cd) {
                            try { if ($cd.SeasonId) { $seasonId = [string]$cd.SeasonId } } catch {}
                            try { if ($cd.SeriesId) { $seriesId = [string]$cd.SeriesId } } catch {}
                            if ($seriesId) { $seasonEpisodes = @(Get-SeasonEpisodes -SeriesId $seriesId -SeasonId $seasonId) }
                        }
                    }
                } catch {}
                $mapped = Find-EpisodeByName -Episodes $seasonEpisodes -ProxyName $proxy.Name
            }
            if ($mapped -and $mapped.Id -and ([string]$mapped.Id -ne [string]$currentItemId)) {
                if ((-not $isMarkedPlayed) -and ($segmentWatched -ge 60)) {
                    Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST" -Force
                }
                $currentItemId = [string]$mapped.Id
                $currentEpisodePath = $proxy.Name
                $currentLabel = $proxy.Name
                $startTime = [DateTime]::UtcNow
                $pausedSeconds = 0.0
                $currentResumeSec = 0.0
                $isMarkedPlayed = $false
                $totalDurationSec = Get-DurationFromItem -Item $mapped
                if ($totalDurationSec -le 0) {
                    try {
                        $nd = Get-JellyfinJson -Path "/Users/$UserId/Items/$currentItemId"
                        $totalDurationSec = Get-DurationFromItem -Item $nd
                    } catch { $totalDurationSec = 2700.0 }
                }
                if ($totalDurationSec -le 0) { $totalDurationSec = 2700.0 }
                Send-JellyfinRequest -Path "/Sessions/Playing" -Method "POST" -Body @{
                    ItemId = $currentItemId
                    PlayMethod = "DirectPlay"
                    CanSeek = $true
                }
                $switched = $true
                $posSec = 0.0
                $ticks = [int64]0
            }
        }
    } catch {}

    # --- (3b) Fallback episode-switch: title substring vs local siblings ---
    if ((-not $switched) -and $activeTitle -and ($siblingFiles.Count -gt 0)) {
        try {
            $atLower = $activeTitle.ToLower()
            $curLower = ""
            try { $curLower = ([string]$currentEpisodePath).ToLower() } catch {}
            foreach ($baseName in $siblingFiles.Keys) {
                if ($atLower.Contains($baseName) -and (-not $curLower.Contains($baseName))) {
                    if ((-not $isMarkedPlayed) -and ($segmentWatched -ge 60)) {
                        Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST" -Force
                    }
                    $currentEpisodePath = $siblingFiles[$baseName]
                    $currentLabel = $siblingFiles[$baseName]
                    $found = Find-EpisodeByName -Episodes $seasonEpisodes -ProxyName $baseName
                    if ($found -and $found.Id) {
                        $currentItemId = [string]$found.Id
                        $totalDurationSec = Get-DurationFromItem -Item $found
                    }
                    if ($totalDurationSec -le 0) {
                        try {
                            if ($currentItemId -and $UserId) {
                                $nd2 = Get-JellyfinJson -Path "/Users/$UserId/Items/$currentItemId"
                                $totalDurationSec = Get-DurationFromItem -Item $nd2
                            }
                        } catch {}
                    }
                    if ($totalDurationSec -le 0) { $totalDurationSec = 2700.0 }
                    $startTime = [DateTime]::UtcNow
                    $pausedSeconds = 0.0
                    $currentResumeSec = 0.0
                    $isMarkedPlayed = $false
                    Send-JellyfinRequest -Path "/Sessions/Playing" -Method "POST" -Body @{
                        ItemId = $currentItemId
                        PlayMethod = "DirectPlay"
                        CanSeek = $true
                    }
                    $posSec = 0.0
                    $ticks = [int64]0
                    break
                }
            }
        } catch {}
    }

    # --- (4) Played thresholds on pause-adjusted position ---
    if (-not $isMarkedPlayed) {
        try {
            if (($posSec -ge ($totalDurationSec * 0.8)) -or (($totalDurationSec -gt 0) -and ($posSec -ge 300) -and ($posSec -ge ($totalDurationSec * 0.5)))) {
                Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST" -Force
                $isMarkedPlayed = $true
            }
        } catch {}
    }

    # Send progress tick (pause-adjusted)
    Send-JellyfinRequest -Path "/Sessions/Playing/Progress" -Method "POST" -Body @{
        ItemId = $currentItemId
        PositionTicks = $ticks
        PlayMethod = "DirectPlay"
    }
}

# On PotPlayer close: pause-adjusted final position
$finalPosSec = $currentResumeSec
try {
    $finalElapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds
    if ($finalElapsed -lt 0) { $finalElapsed = 0 }
    $finalSeg = $finalElapsed - $pausedSeconds
    if ($finalSeg -lt 0) { $finalSeg = 0 }
    $finalPosSec = $currentResumeSec + $finalSeg
    if ($finalPosSec -lt 0) { $finalPosSec = 0 }
    if ($totalDurationSec -gt 0 -and $finalPosSec -gt $totalDurationSec) { $finalPosSec = $totalDurationSec }
} catch {}
$finalTicks = [int64]($finalPosSec * 10000000)
try {
    if ((-not $isMarkedPlayed) -and ($finalPosSec -ge 120) -and ($finalPosSec -ge ($totalDurationSec * 0.7))) {
        Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST" -Force
    }
} catch {}

# Always POST Stopped with final ticks
Send-JellyfinRequest -Path "/Sessions/Playing/Stopped" -Method "POST" -Force -Body @{
    ItemId = $currentItemId
    PositionTicks = $finalTicks
}

try {
    if ($mutexHeld -and $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        try { $mutex.Dispose() } catch {}
    }
} catch {}

return $initialResumeSec
