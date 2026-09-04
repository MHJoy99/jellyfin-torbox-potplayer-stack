# PotPlayer Playback Scrobbler & Live Progress Sync for Jellyfin (10x)
# Launcher: hidden per play, args: -MediaPath -ItemId -UserId -Token -ServerUrl [-DryRun]
# MediaPath is often http://127.0.0.1:8888/torbox/<tid>/<fid>/ proxy URL or a local path.
# Stdlib PowerShell only. No Shell COM. All Jellyfin calls TimeoutSec 5 + SilentlyContinue, never throw.
# Features:
#   (F1) Batches Jellyfin progress updates in a 2s window (Queue-Progress / Flush-Progress).
#   (F2) Exponential backoff when Jellyfin is down (2s,4s,8s... capped at 60s).
#   (F3) Per-user ItemId map (multi-profile): path->Id isolated per UserId.
#   (F4) Pushes position immediately on seek events (title clock vs computed pos).
#   (F5) Auto-marks watched at 95 percent.
#   (F6) -DryRun log-only mode (no HTTP, stdout log lines only).
# Pause-aware: wall-clock minus detected pauses. Secrets: params only, never hardcoded.
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

# --- Singleton per ItemId: Global\PotPlayerTracker_<8charItemPrefix>, second instance exits ---
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

# ============ (F1) Progress batching state: 2s window ============
$script:progressBatchWindowSec = 2.0
$script:lastProgressPushUtc = [DateTime]::MinValue
$script:pendingProgressTicks = $null
$script:pendingProgressItemId = $null

# ============ (F2) Exponential backoff state ============
$script:consecutiveFailures = 0
$script:backoffSec = 0
$script:nextRetryUtc = [DateTime]::MinValue

function Write-TrackerLog {
    param([string]$Message)
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Write-Output "[$ts] $Message"
    } catch {}
}

function Get-BackoffSeconds {
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
        if ([DateTime]::UtcNow -lt $script:nextRetryUtc) { return $false }
    } catch {}
    return $true
}

function Register-JellyfinSuccess {
    try {
        $script:consecutiveFailures = 0
        $script:backoffSec = 0
        $script:nextRetryUtc = [DateTime]::MinValue
    } catch {}
}

function Register-JellyfinFailure {
    try {
        $script:consecutiveFailures++
        $script:backoffSec = Get-BackoffSeconds -Failures $script:consecutiveFailures
        $script:nextRetryUtc = [DateTime]::UtcNow.AddSeconds($script:backoffSec)
        Write-TrackerLog "Jellyfin down (failures=$($script:consecutiveFailures)), backing off ${script:backoffSec}s."
    } catch {}
}

function Send-JellyfinRequest {
    param(
        [string]$Path,
        [string]$Method = "POST",
        [hashtable]$Body = $null,
        [switch]$Force
    )
    # (F6) DryRun: log-only, never HTTP.
    if ($DryRun) {
        try {
            $summary = "$Method $Path"
            if ($Body -and $Body.ContainsKey('PositionTicks')) { $summary += " PositionTicks=$($Body['PositionTicks'])" }
            if ($Body -and $Body.ContainsKey('ItemId')) { $summary += " ItemId=$($Body['ItemId'])" }
            Write-TrackerLog "[DryRun] $summary"
        } catch {}
        return $true
    }
    # (F2) Backoff gate (Force bypasses for Stopped/Played critical posts).
    if (-not $Force) {
        if (-not (Test-JellyfinBackoff)) { return $false }
    }
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
        Register-JellyfinSuccess
        return $true
    } catch {
        Register-JellyfinFailure
        return $false
    }
}

function Get-JellyfinJson {
    param([string]$Path)
    if ($DryRun) {
        try { Write-TrackerLog "[DryRun] GET $Path" } catch {}
        return $null
    }
    if (-not (Test-JellyfinBackoff)) { return $null }
    try {
        $headers = @{
            "Authorization" = "MediaBrowser Client=`"PotPlayer`", Device=`"Windows`", DeviceId=`"PotPlayer-Win32`", Version=`"1.0.0`", Token=`"$Token`""
        }
        $url = "$ServerUrl$Path"
        $r = Invoke-RestMethod -Uri $url -Method GET -Headers $headers -TimeoutSec 5 -ErrorAction SilentlyContinue
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
                if ($ln -match '(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})') {
                    $ts = $null
                    try { $ts = [DateTime]::Parse($Matches[1]) } catch { $ts = $null }
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

# ============ (F3) Per-user ItemId map (multi-profile) ============
# Top-level key = UserId, value = hashtable(pathLower|nameLower -> ItemId).
$script:userItemMaps = @{}

function Get-UserItemMap {
    param([string]$ForUserId)
    try {
        if ([string]::IsNullOrEmpty($ForUserId)) { $ForUserId = "__anonymous__" }
        if (-not $script:userItemMaps.ContainsKey($ForUserId)) {
            $script:userItemMaps[$ForUserId] = @{}
        }
        return $script:userItemMaps[$ForUserId]
    } catch { return @{} }
}

function Update-UserItemMapFromLibrary {
    try {
        if (-not $UserId) { return }
        $map = Get-UserItemMap -ForUserId $UserId
        $itemsResp = $null
        if ($DryRun) {
            Write-TrackerLog "[DryRun] Skipping library ItemId map refresh for user $UserId."
            return
        }
        try {
            $headers = @{ "Authorization" = "MediaBrowser Token=`"$Token`"" }
            $itemsResp = Invoke-RestMethod -Uri "$ServerUrl/Items?userId=$UserId&recursive=true&includeItemTypes=Episode,Movie" -Headers $headers -TimeoutSec 5 -ErrorAction SilentlyContinue
            Register-JellyfinSuccess
        } catch {
            Register-JellyfinFailure
            return
        }
        if ($itemsResp -and $itemsResp.Items) {
            foreach ($it in $itemsResp.Items) {
                try {
                    if ($it.Path) {
                        $normalized = ([string]$it.Path) -replace '^R:\\', 'F:\Media\' -replace '^r:\\', 'F:\Media\'
                        $map[$normalized.ToLower()] = $it.Id
                    }
                    if ($it.Name) { $map[([string]$it.Name).ToLower()] = $it.Id }
                } catch {}
            }
        }
    } catch {}
}

function Get-MappedItemIdForUser {
    param([string]$ForUserId, [string]$LookupKey)
    try {
        if ([string]::IsNullOrEmpty($LookupKey)) { return $null }
        $map = Get-UserItemMap -ForUserId $ForUserId
        $k = $LookupKey.ToLower()
        if ($map.ContainsKey($k)) { return $map[$k] }
    } catch {}
    return $null
}

# ============ (F1) Batched progress helpers ============
function Queue-Progress {
    param([string]$ProgressItemId, [int64]$PositionTicks)
    try {
        $script:pendingProgressTicks = $PositionTicks
        $script:pendingProgressItemId = $ProgressItemId
        $elapsedSincePush = ([DateTime]::UtcNow - $script:lastProgressPushUtc).TotalSeconds
        if ($elapsedSincePush -ge $script:progressBatchWindowSec) {
            Flush-Progress
        }
    } catch {}
}

function Flush-Progress {
    try {
        if ($null -eq $script:pendingProgressTicks -or [string]::IsNullOrEmpty($script:pendingProgressItemId)) { return }
        $ok = Send-JellyfinRequest -Path "/Sessions/Playing/Progress" -Method "POST" -Body @{
            ItemId        = $script:pendingProgressItemId
            PositionTicks = $script:pendingProgressTicks
            PlayMethod    = "DirectPlay"
        }
        # Only advance the window + clear pending on success or DryRun (which returns true).
        # On backoff/failure keep pending so the next window retries the latest position.
        if ($ok) {
            $script:lastProgressPushUtc = [DateTime]::UtcNow
            $script:pendingProgressTicks = $null
        }
    } catch {}
}

function Push-ProgressImmediate {
    param([string]$ProgressItemId, [int64]$PositionTicks)
    try {
        $script:pendingProgressTicks = $PositionTicks
        $script:pendingProgressItemId = $ProgressItemId
        Flush-Progress -ErrorAction SilentlyContinue
        # Seek pushes bypass the batch window: force one direct send if flush was gated.
        $elapsedSincePush = ([DateTime]::UtcNow - $script:lastProgressPushUtc).TotalSeconds
        if ($null -ne $script:pendingProgressTicks -and $elapsedSincePush -ge 0) {
            $sent = Send-JellyfinRequest -Path "/Sessions/Playing/Progress" -Method "POST" -Body @{
                ItemId        = $ProgressItemId
                PositionTicks = $PositionTicks
                PlayMethod    = "DirectPlay"
            } -Force
            if ($sent) {
                $script:lastProgressPushUtc = [DateTime]::UtcNow
                $script:pendingProgressTicks = $null
            }
        }
    } catch {}
}

# ============ (F4) Seek detection helpers ============
$script:lastReportedPosSec = -1.0
$script:seekThresholdSec = 10.0

function Get-TitlePositionSec {
    param([string]$Title)
    try {
        if ([string]::IsNullOrEmpty($Title)) { return $null }
        # Matches "12:34 / 45:00", "01:12:34 / 01:45:00", "12:34/45:00".
        if ($Title -match '(\d{1,2}:\d{2}(?::\d{2})?)\s*/\s*(\d{1,2}:\d{2}(?::\d{2})?)') {
            $posStr = $Matches[1]
            $parts = $posStr.Split(':')
            $sec = 0.0
            try {
                if ($parts.Count -eq 2) { $sec = ([double]$parts[0] * 60.0) + [double]$parts[1] }
                elseif ($parts.Count -eq 3) { $sec = ([double]$parts[0] * 3600.0) + ([double]$parts[1] * 60.0) + [double]$parts[2] }
                else { return $null }
            } catch { return $null }
            return $sec
        }
    } catch {}
    return $null
}

function Test-IsSeekEvent {
    param([double]$ComputedPosSec, [string]$ActiveTitle, [double]$ExpectedDeltaSec)
    try {
        # (a) Title-clock jump: PotPlayer title carries the real clock after a seek.
        $titlePos = Get-TitlePositionSec -Title $ActiveTitle
        if ($null -ne $titlePos) {
            $gap = [math]::Abs($titlePos - $ComputedPosSec)
            if ($gap -ge $script:seekThresholdSec) { return $true }
        }
        # (b) Computed-position discontinuity vs last report (covers playlist jumps).
        if ($script:lastReportedPosSec -ge 0 -and $ExpectedDeltaSec -ge 0) {
            $expected = $script:lastReportedPosSec + $ExpectedDeltaSec
            $jump = [math]::Abs($ComputedPosSec - $expected)
            # Only flag large backward jumps or forward jumps far beyond one poll interval.
            if (($ComputedPosSec + 1.0) -lt $script:lastReportedPosSec -and $jump -ge $script:seekThresholdSec) { return $true }
            if ($jump -ge 30.0) { return $true }
        }
    } catch {}
    return $false
}

# ============ (F5) Watched threshold (95 percent) ============
$script:watchedThreshold = 0.95

function Test-ShouldMarkWatched {
    param([double]$PosSec, [double]$DurationSec)
    try {
        if ($DurationSec -le 0) { return $false }
        if ($PosSec -ge ($DurationSec * $script:watchedThreshold)) { return $true }
    } catch {}
    return $false
}

# --- Duration AND resume from Jellyfin ---
$totalDurationSec = 2700.0
$resumeSec = 0
$seasonId = $null
$seriesId = $null
try {
    if ($ItemId -and $UserId) {
        $detail = Get-JellyfinJson -Path "/Users/$UserId/Items/$ItemId"
        if ($detail) {
            $totalDurationSec = Get-DurationFromItem -Item $detail
            try { if ($detail.SeasonId) { $seasonId = [string]$detail.SeasonId } } catch {}
            try { if ($detail.SeriesId) { $seriesId = [string]$detail.SeriesId } } catch {}
        }
    }
} catch {}
try {
    if ($ItemId -and $UserId) {
        $ud = Get-JellyfinJson -Path "/Users/$UserId/Items/$ItemId/UserData"
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
$initialResumeSec = $resumeSec
if ($DryRun) { Write-TrackerLog "[DryRun] Tracker start ItemId=$ItemId UserId=$UserId Resume=${resumeSec}s Duration=${totalDurationSec}s." }

# 1. Report Playback Started
Send-JellyfinRequest -Path "/Sessions/Playing" -Method "POST" -Body @{
    ItemId     = $ItemId
    PlayMethod = "DirectPlay"
    CanSeek    = $true
} | Out-Null

$startTime = [DateTime]::UtcNow
$lastLoopUtc = [DateTime]::UtcNow
$pausedSeconds = 0.0
$currentResumeSec = [double]$resumeSec
$isMarkedPlayed = $false
$currentEpisodePath = $MediaPath
$currentItemId = $ItemId
$currentLabel = $MediaPath
$pollSec = 2

# Season episode cache for proxy-name -> episode mapping
$seasonEpisodes = @()
try {
    if ($seriesId) { $seasonEpisodes = @(Get-SeasonEpisodes -SeriesId $seriesId -SeasonId $seasonId) }
} catch { $seasonEpisodes = @() }

# (F3) Build per-user ItemId map at startup.
try { Update-UserItemMapFromLibrary } catch {}

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

# Monitor loop while PotPlayer is running (2s poll to match 2s batch window)
while ($true) {
    Start-Sleep -Seconds $pollSec

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

    # --- Pause-aware position: wall-clock minus detected pauses ---
    try {
        if (Test-IsPausedTitle -Title $activeTitle) { $pausedSeconds += [double]$pollSec }
    } catch {}

    $now = [DateTime]::UtcNow
    $loopDelta = ($now - $lastLoopUtc).TotalSeconds
    if ($loopDelta -lt 0) { $loopDelta = [double]$pollSec }
    $lastLoopUtc = $now
    $elapsed = ($now - $startTime).TotalSeconds
    if ($elapsed -lt 0) { $elapsed = 0 }
    $segmentWatched = $elapsed - $pausedSeconds
    if ($segmentWatched -lt 0) { $segmentWatched = 0 }
    $posSec = $currentResumeSec + $segmentWatched
    if ($posSec -lt 0) { $posSec = 0 }
    if ($totalDurationSec -gt 0 -and $posSec -gt $totalDurationSec) { $posSec = $totalDurationSec }
    $ticks = [int64]($posSec * 10000000)

    $switched = $false

    # --- Primary episode-switch: torbox-proxy.log ---
    try {
        $proxy = Get-LatestProxyEntry
        if ($proxy -and $proxy.Key -and ($proxy.Key -ne $lastProxyKey)) {
            $lastProxyKey = $proxy.Key
            $mapped = Find-EpisodeByName -Episodes $seasonEpisodes -ProxyName $proxy.Name
            if (-not $mapped) {
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
                    Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST" -Force | Out-Null
                }
                # Flush pending progress for the old episode before switching.
                try { Flush-Progress } catch {}
                $currentItemId = [string]$mapped.Id
                $currentEpisodePath = $proxy.Name
                $currentLabel = $proxy.Name
                $startTime = [DateTime]::UtcNow
                $lastLoopUtc = [DateTime]::UtcNow
                $pausedSeconds = 0.0
                $currentResumeSec = 0.0
                $isMarkedPlayed = $false
                $script:lastReportedPosSec = -1.0
                $script:pendingProgressTicks = $null
                $totalDurationSec = Get-DurationFromItem -Item $mapped
                if ($totalDurationSec -le 0) {
                    try {
                        $nd = Get-JellyfinJson -Path "/Users/$UserId/Items/$currentItemId"
                        $totalDurationSec = Get-DurationFromItem -Item $nd
                    } catch { $totalDurationSec = 2700.0 }
                }
                if ($totalDurationSec -le 0) { $totalDurationSec = 2700.0 }
                Send-JellyfinRequest -Path "/Sessions/Playing" -Method "POST" -Body @{
                    ItemId     = $currentItemId
                    PlayMethod = "DirectPlay"
                    CanSeek    = $true
                } | Out-Null
                $switched = $true
                $posSec = 0.0
                $ticks = [int64]0
            }
        }
    } catch {}

    # --- Fallback episode-switch: title substring vs local siblings ---
    if ((-not $switched) -and $activeTitle -and ($siblingFiles.Count -gt 0)) {
        try {
            $atLower = $activeTitle.ToLower()
            $curLower = ""
            try { $curLower = ([string]$currentEpisodePath).ToLower() } catch {}
            foreach ($baseName in $siblingFiles.Keys) {
                if ($atLower.Contains($baseName) -and (-not $curLower.Contains($baseName))) {
                    if ((-not $isMarkedPlayed) -and ($segmentWatched -ge 60)) {
                        Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST" -Force | Out-Null
                    }
                    try { Flush-Progress } catch {}
                    $currentEpisodePath = $siblingFiles[$baseName]
                    $currentLabel = $siblingFiles[$baseName]
                    $found = Find-EpisodeByName -Episodes $seasonEpisodes -ProxyName $baseName
                    if ($found -and $found.Id) {
                        $currentItemId = [string]$found.Id
                        $totalDurationSec = Get-DurationFromItem -Item $found
                    }
                    # (F3) Per-user lookup fallback when season cache misses.
                    if ([string]::IsNullOrEmpty($currentItemId) -or ($found -eq $null)) {
                        try {
                            $perUser = Get-MappedItemIdForUser -ForUserId $UserId -LookupKey $currentEpisodePath
                            if ($perUser) { $currentItemId = [string]$perUser }
                        } catch {}
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
                    $lastLoopUtc = [DateTime]::UtcNow
                    $pausedSeconds = 0.0
                    $currentResumeSec = 0.0
                    $isMarkedPlayed = $false
                    $script:lastReportedPosSec = -1.0
                    $script:pendingProgressTicks = $null
                    Send-JellyfinRequest -Path "/Sessions/Playing" -Method "POST" -Body @{
                        ItemId     = $currentItemId
                        PlayMethod = "DirectPlay"
                        CanSeek    = $true
                    } | Out-Null
                    $posSec = 0.0
                    $ticks = [int64]0
                    break
                }
            }
        } catch {}
    }

    # --- (F5) Played threshold at 95 percent on pause-adjusted position ---
    if (-not $isMarkedPlayed) {
        try {
            if (Test-ShouldMarkWatched -PosSec $posSec -DurationSec $totalDurationSec) {
                Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST" -Force | Out-Null
                $isMarkedPlayed = $true
            }
        } catch {}
    }

    # --- (F4) Seek: push position immediately, bypassing the 2s batch window ---
    $isSeek = $false
    try {
        if (-not $switched) {
            $isSeek = Test-IsSeekEvent -ComputedPosSec $posSec -ActiveTitle $activeTitle -ExpectedDeltaSec $loopDelta
        }
    } catch { $isSeek = $false }
    if ($isSeek) {
        try {
            if ($DryRun) { Write-TrackerLog "[DryRun] Seek detected at ${posSec}s, pushing immediately." }
            Push-ProgressImmediate -ProgressItemId $currentItemId -PositionTicks $ticks
            $script:lastReportedPosSec = $posSec
        } catch {}
    } else {
        # --- (F1) Normal path: batch progress in 2s window ---
        try { Queue-Progress -ProgressItemId $currentItemId -PositionTicks $ticks } catch {}
        try {
            if ($null -eq $script:pendingProgressTicks) { $script:lastReportedPosSec = $posSec }
        } catch {}
    }
}

# Flush any batched progress before exit.
try { Flush-Progress } catch {}

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
    # (F5) Final mark at 95 percent.
    if ((-not $isMarkedPlayed) -and (Test-ShouldMarkWatched -PosSec $finalPosSec -DurationSec $totalDurationSec)) {
        Send-JellyfinRequest -Path "/Users/$UserId/PlayedItems/$currentItemId" -Method "POST" -Force | Out-Null
    }
} catch {}

# Always POST Stopped with final ticks (Force bypasses backoff so the session closes).
Send-JellyfinRequest -Path "/Sessions/Playing/Stopped" -Method "POST" -Body @{
    ItemId        = $currentItemId
    PositionTicks = $finalTicks
} -Force | Out-Null

try {
    if ($mutexHeld -and $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        try { $mutex.Dispose() } catch {}
    }
} catch {}

return $initialResumeSec
