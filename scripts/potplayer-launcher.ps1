#requires -Version 7.0
<#
.SYNOPSIS
    PowerShell 7 PotPlayer launcher - full-season playlist default, resume via /seek= seconds.
.DESCRIPTION
    TorBox key via $env:TORBOX_API_KEY only (never hardcode secrets).
    Single 127.0.0.1:8888/health probe per launch (cached, stale recheck >60s).
    10 features:
      1) -WhatIf dry-run (print playlist + actions, launch nothing)
      2) Missing-file skip with warning (continue playlist)
      3) Natural-sort fallback when IndexNumber absent
      4) Playlist dedupe (same path once)
      5) Concurrent-launch mutex guard (second launch takes over cleanly)
      6) Exit-code propagation + log line
      7) Single launch-telemetry log line (ms timings per stage)
      8) Argument-quoting hardening (spaces/unicode/brackets)
      9) Stale-health recheck (re-probe if cached probe older than 60s)
     10) -Episodes range selector (e.g. 3-7, single N)
#>
param(
    [switch]$WhatIf,
    [string]$Episodes = "",
    [int]$Seek = -1,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$rawArgs
)

# Manual fallback scan: bind -WhatIf / -Episodes even when they arrive inside rawArgs
# (e.g. protocol-handler quoting edge cases). Exact-token match only so URIs are untouched.
try {
    $cleanRaw = @()
    for ($ri = 0; $ri -lt $rawArgs.Count; $ri++) {
        $tok = $rawArgs[$ri]
        if ($tok -eq '-WhatIf' -or $tok -eq '/WhatIf' -or $tok -eq '--WhatIf' -or $tok -eq '-DryRun') {
            $WhatIf = $true
            continue
        }
        elseif ($tok -eq '-Episodes' -or $tok -eq '--Episodes' -or $tok -eq '/Episodes' -or $tok -eq '-EpisodeRange') {
            if (($ri + 1) -lt $rawArgs.Count) { $Episodes = $rawArgs[$ri + 1]; $ri++ }
            continue
        }
        elseif ($tok -match '^-Episodes=(.+)$') {
            $Episodes = $Matches[1]
            continue
        }
        elseif ($tok -match '^--Episodes=(.+)$') {
            $Episodes = $Matches[1]
            continue
        }
        else { $cleanRaw += $tok }
    }
    $rawArgs = $cleanRaw
}
catch { }

# Effective dry-run flag (custom switch + automatic preference when ShouldProcess is used by caller)
$script:IsDryRun = $false
try {
    if ($WhatIf) { $script:IsDryRun = $true }
    elseif ((Get-Variable -Name WhatIfPreference -ErrorAction SilentlyContinue) -and ($WhatIfPreference -eq $true)) { $script:IsDryRun = $true }
}
catch { $script:IsDryRun = [bool]$WhatIf }

# FEATURE 7: telemetry clocks (single log line at end with ms per stage)
$script:TelemetryTotal = [System.Diagnostics.Stopwatch]::StartNew()
$script:TelemetryParseMs = 0
$script:TelemetryHealthMs = 0
$script:TelemetryPlaylistMs = 0
$script:TelemetryLaunchMs = 0
$script:TelemetryStage = [System.Diagnostics.Stopwatch]::StartNew()

function Write-LauncherLog([string]$Message) {
    try {
        $logDir = 'F:\Jellyfin\logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $logFile = Join-Path $logDir 'potplayer-launcher.log'
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
        Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue
    }
    catch { }
}

# FEATURE 8: argument-quoting hardening (spaces/unicode/brackets).
# Uses -LiteralPath everywhere for filesystem access (brackets safe) and explicit
# double-quote wrapping with embedded-quote doubling for PotPlayer / Start-Process args.
function Quote-PotArg([string]$Value) {
    if ($null -eq $Value) { return '""' }
    $escaped = $Value -replace '"', '""'
    return '"' + $escaped + '"'
}

# TorBox key via $env:TORBOX_API_KEY only (never hardcode secrets).
function Get-TorboxApiKey {
    try {
        if ($env:TORBOX_API_KEY) { return [string]$env:TORBOX_API_KEY }
    }
    catch { }
    return ""
}

# Single 127.0.0.1:8888/health probe per launch + FEATURE 9 stale-health recheck.
# In-memory cache reused for every caller in this launch; file cache shares across
# launches; re-probe only when cached result is older than 60s.
$script:ProxyHealthCached = $null
$script:ProxyHealthTimestamp = [System.DateTime]::MinValue
$script:HealthProbeCount = 0
function Test-ProxyHealthCached {
    param([switch]$Force)
    $now = Get-Date
    try {
        if (-not $Force -and ($null -ne $script:ProxyHealthCached)) {
            $ageSec = ($now - $script:ProxyHealthTimestamp).TotalSeconds
            if ($ageSec -lt 60) { return [bool]$script:ProxyHealthCached }
        }
    }
    catch { }
    $cacheFile = Join-Path ([System.IO.Path]::GetTempPath()) 'potplayer-proxy-health.json'
    try {
        if (-not $Force -and (Test-Path -LiteralPath $cacheFile)) {
            $raw = Get-Content -LiteralPath $cacheFile -Raw -ErrorAction Stop
            $cached = $raw | ConvertFrom-Json -ErrorAction Stop
            $cachedTime = [System.DateTime]$cached.timestamp
            $ageSec = ($now - $cachedTime).TotalSeconds
            if ($ageSec -lt 60) {
                $script:ProxyHealthCached = [bool]$cached.healthy
                $script:ProxyHealthTimestamp = $cachedTime
                return [bool]$script:ProxyHealthCached
            }
        }
    }
    catch { }
    # Exactly one live probe for this launch (or one re-probe when stale).
    $healthy = $false
    try {
        $script:HealthProbeCount++
        Invoke-RestMethod -Uri 'http://127.0.0.1:8888/health' -TimeoutSec 2 -ErrorAction Stop | Out-Null
        $healthy = $true
    }
    catch { $healthy = $false }
    $script:ProxyHealthCached = $healthy
    $script:ProxyHealthTimestamp = $now
    try {
        $payload = @{ healthy = $healthy; timestamp = $now.ToString('o') } | ConvertTo-Json -Compress
        Set-Content -LiteralPath $cacheFile -Value $payload -Encoding utf8 -ErrorAction SilentlyContinue
    }
    catch { }
    return [bool]$healthy
}

# FEATURE 5: concurrent-launch mutex guard (second launch takes over cleanly).
$script:LauncherMutex = $null
$script:MutexAcquired = $false
function Enter-LauncherMutex {
    try {
        $script:LauncherMutex = New-Object System.Threading.Mutex($false, 'Global\PotPlayerLauncherSingleInstance')
        $script:MutexAcquired = $script:LauncherMutex.WaitOne(0)
        if (-not $script:MutexAcquired) {
            Write-Warning 'Concurrent launch detected - taking over previous PotPlayer session.'
            Write-LauncherLog 'MUTEX contention - second launch takes over, stopping prior PotPlayer.'
            Get-Process -Name @('PotPlayerMini64', 'PotPlayer64', 'PotPlayer') -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 350
            $script:MutexAcquired = $script:LauncherMutex.WaitOne(5000)
        }
    }
    catch { }
}
function Exit-LauncherMutex {
    try {
        if ($script:MutexAcquired -and $null -ne $script:LauncherMutex) {
            $script:LauncherMutex.ReleaseMutex() | Out-Null
        }
    }
    catch { }
    try {
        if ($null -ne $script:LauncherMutex) { $script:LauncherMutex.Dispose() }
    }
    catch { }
    $script:LauncherMutex = $null
    $script:MutexAcquired = $false
}

# FEATURE 3: natural-sort fallback when IndexNumber absent.
# Pads every digit run so lexical compare equals numeric compare (E2 < E10).
function Get-NaturalSortKey([string]$Name) {
    if ([string]::IsNullOrEmpty($Name)) { return $Name }
    try {
        return [regex]::Replace($Name, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
    }
    catch { return $Name }
}
function Sort-PlaylistNatural([array]$Files) {
    if ($null -eq $Files -or $Files.Count -eq 0) { return @() }
    # Primary: embedded SxxEyy episode number when present; secondary: natural key; tertiary: name.
    $sorted = $Files | Sort-Object -Property `
        @{ Expression = {
            $n = 999999
            try {
                $nm = ''
                try { $nm = [string]$_.Name } catch { $nm = [string]$_ }
                if ($nm -match '(?i)(?:s\d{1,3})?e(\d{1,4})') { $n = [int]$Matches[1] }
            } catch { }
            $n
        } }, `
        @{ Expression = {
            $k = ''
            try {
                $nm2 = ''
                try { $nm2 = [string]$_.Name } catch { $nm2 = [string]$_ }
                $k = Get-NaturalSortKey $nm2
            } catch { }
            $k
        } }, `
        @{ Expression = {
            try { [string]$_.Name } catch { [string]$_ }
        } }
    return @($sorted)
}
function Sort-PlaylistByIndexOrNatural([array]$Files, [hashtable]$IndexMap) {
    if ($null -eq $Files -or $Files.Count -eq 0) { return @() }
    $known = 0
    try {
        if ($null -ne $IndexMap -and $IndexMap.Count -gt 0) {
            foreach ($f in $Files) {
                try {
                    $key = ''
                    try { $key = ([string]$f.FullName).ToLowerInvariant() } catch { $key = ([string]$f).ToLowerInvariant() }
                    if ($IndexMap.ContainsKey($key)) { $known++ }
                }
                catch { }
            }
        }
    }
    catch { $known = 0 }
    if ($known -gt 0) {
        try { Write-LauncherLog "PLAYLIST order=indexnumber ($known/$($Files.Count))" } catch { }
        $sorted = $Files | Sort-Object -Property `
            @{ Expression = {
                $idx = 999999
                try {
                    $k2 = ([string]$_.FullName).ToLowerInvariant()
                    if ($IndexMap.ContainsKey($k2)) { $idx = [int]$IndexMap[$k2] }
                } catch { }
                $idx
            } }, `
            @{ Expression = {
                $kk = ''
                try { $kk = Get-NaturalSortKey ([string]$_.Name) } catch { }
                $kk
            } }
        return @($sorted)
    }
    try { Write-LauncherLog "PLAYLIST order=natural (indexnumber 0/$($Files.Count))" } catch { }
    return @(Sort-PlaylistNatural $Files)
}

# FEATURE 10: -Episodes range selector (e.g. 3-7, single N, comma list).
function Select-EpisodeRange([array]$Ordered, [string]$RangeSpec) {
    if ([string]::IsNullOrWhiteSpace($RangeSpec)) { return @($Ordered) }
    $spec = $RangeSpec.Trim()
    try {
        $count = $Ordered.Count
        if ($count -eq 0) { return @() }
        # Single N
        if ($spec -match '^\s*(\d+)\s*$') {
            $n = [int]$Matches[1]
            if ($n -ge 1 -and $n -le $count) { return @($Ordered[$n - 1]) }
            Write-Warning "Episodes selector '$spec' out of range 1-$count."
            return @($Ordered)
        }
        # Range N-M (e.g. 3-7, inclusive, 1-based, order-normalized)
        if ($spec -match '^\s*(\d+)\s*-\s*(\d+)\s*$') {
            $a = [int]$Matches[1]
            $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            if ($a -lt 1) { $a = 1 }
            if ($b -gt $count) { $b = $count }
            if ($a -gt $count -or $b -lt 1) { return @($Ordered) }
            return @($Ordered[($a - 1)..($b - 1)])
        }
        # Comma list with optional ranges: "1,3-5,8"
        if ($spec -match ',') {
            $picked = [System.Collections.Generic.List[object]]::new()
            $seenIdx = @{}
            $chunks = $spec.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
            foreach ($c in $chunks) {
                $t2 = $c.Trim()
                if ($t2 -match '^\s*(\d+)\s*-\s*(\d+)\s*$') {
                    $x = [int]$Matches[1]; $y = [int]$Matches[2]
                    if ($x -gt $y) { $tmp = $x; $x = $y; $y = $tmp }
                    for ($k = $x; $k -le $y; $k++) {
                        if ($k -ge 1 -and $k -le $count -and -not $seenIdx.ContainsKey($k)) {
                            $seenIdx[$k] = $true
                            $picked.Add($Ordered[$k - 1]) | Out-Null
                        }
                    }
                }
                elseif ($t2 -match '^\s*(\d+)\s*$') {
                    $k3 = [int]$Matches[1]
                    if ($k3 -ge 1 -and $k3 -le $count -and -not $seenIdx.ContainsKey($k3)) {
                        $seenIdx[$k3] = $true
                        $picked.Add($Ordered[$k3 - 1]) | Out-Null
                    }
                }
            }
            if ($picked.Count -gt 0) { return @($picked.ToArray()) }
            return @($Ordered)
        }
        Write-Warning "Unrecognized -Episodes '$spec' (use N or N-M). Using full season."
        return @($Ordered)
    }
    catch {
        Write-Warning "Episodes selector parse failed for '$spec': $_"
        return @($Ordered)
    }
}

# Resume via /seek= seconds: explicit -Seek wins, else Jellyfin PlaybackPositionTicks.
function Get-ResumeSeconds([string]$ItemId, [string]$UserId, [string]$Token, [string]$ServerUrl) {
    try {
        if ($Seek -ge 0) { return [int]$Seek }
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($ItemId) -or [string]::IsNullOrWhiteSpace($UserId) -or [string]::IsNullOrWhiteSpace($Token)) {
        return 0
    }
    try {
        $headers = @{ 'X-Emby-Token' = $Token }
        $url = $ServerUrl.TrimEnd('/') + '/Users/' + $UserId + '/Items/' + $ItemId + '?Fields=UserData'
        $item = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 5 -ErrorAction Stop
        $ticks = 0
        try { $ticks = [long]$item.UserData.PlaybackPositionTicks } catch { $ticks = 0 }
        if ($ticks -gt 0) {
            $sec = [int]([long]$ticks / 10000000)
            if ($sec -lt 0) { $sec = 0 }
            return $sec
        }
    }
    catch { }
    return 0
}

function Get-JellyfinIndexMap([string]$ItemId, [string]$UserId, [string]$Token, [string]$ServerUrl, [string]$MediaPath) {
    $map = @{}
    try {
        if ([string]::IsNullOrWhiteSpace($ItemId) -or [string]::IsNullOrWhiteSpace($UserId) -or [string]::IsNullOrWhiteSpace($Token)) {
            return $map
        }
        $headers = @{ 'X-Emby-Token' = $Token }
        $seriesId = ''
        try {
            $selfUrl = $ServerUrl.TrimEnd('/') + '/Users/' + $UserId + '/Items/' + $ItemId + '?Fields=SeriesId,SeasonId,IndexNumber,ParentIndexNumber,Path'
            $self = Invoke-RestMethod -Uri $selfUrl -Headers $headers -TimeoutSec 5 -ErrorAction Stop
            if ($null -ne $self.SeriesId -and -not [string]::IsNullOrWhiteSpace([string]$self.SeriesId)) { $seriesId = [string]$self.SeriesId }
        }
        catch { }
        if ([string]::IsNullOrWhiteSpace($seriesId)) { return $map }
        $epUrl = $ServerUrl.TrimEnd('/') + '/Shows/' + $seriesId + '/Episodes?UserId=' + $UserId + '&Fields=Path,IndexNumber,ParentIndexNumber&Limit=400'
        $eps = Invoke-RestMethod -Uri $epUrl -Headers $headers -TimeoutSec 8 -ErrorAction Stop
        if ($null -ne $eps.Items) {
            foreach ($ep in $eps.Items) {
                try {
                    if ($null -ne $ep.IndexNumber -and $null -ne $ep.Path -and -not [string]::IsNullOrWhiteSpace([string]$ep.Path)) {
                        $k = ([string]$ep.Path).ToLowerInvariant()
                        if (-not $map.ContainsKey($k)) { $map[$k] = [int]$ep.IndexNumber }
                    }
                }
                catch { }
            }
        }
    }
    catch { }
    return $map
}

# ---- main ----
Enter-LauncherMutex
$script:ExitCode = 0
try {
    # Combine any split arguments if Windows passes unquoted spaces
    $inputUri = ($rawArgs -join ' ').Trim()
    if (-not $inputUri) {
        if ($script:IsDryRun) {
            Write-Host 'DRY-RUN: no input URI (nothing to launch).'
            Write-LauncherLog 'DRYRUN no-input'
        }
        $script:TelemetryTotal.Stop()
        try {
            $totalMs = [int]$script:TelemetryTotal.Elapsed.TotalMilliseconds
            Write-LauncherLog "TELEMETRY total=${totalMs}ms parse=0ms health=0ms playlist=0ms launch=0ms episodes='' dryrun=$($script:IsDryRun) probes=$($script:HealthProbeCount)"
        }
        catch { }
        Exit-LauncherMutex
        exit 0
    }

    # Parse stage timing
    $script:TelemetryStage.Restart()

    # 1. Clean protocol prefix
    $target = $inputUri -replace '^potplayer://', '' -replace '^"potplayer://', '' -replace "^'potplayer://", ''

    # 2. URL decode
    $target = [System.Uri]::UnescapeDataString($target)
    $target = $target.Trim().Trim('"').Trim("'").TrimEnd('\').TrimEnd('/')

    # 3. Parse optional metadata query parameters (target|itemId|userId|token|serverUrl)
    $mediaPath = $target
    $itemId = ""
    $userId = ""
    $token = ""
    $serverUrl = "http://localhost:8096"

    if ($target.Contains('|')) {
        $parts = $target.Split('|')
        $mediaPath = $parts[0]
        if ($parts.Length -gt 1) { $itemId = $parts[1] }
        if ($parts.Length -gt 2) { $userId = $parts[2] }
        if ($parts.Length -gt 3) { $token = $parts[3] }
        if ($parts.Length -gt 4) { $serverUrl = $parts[4] }
    }

    # 4. Handle Drive letter mappings (R:\ -> F:\Media\)
    if ($mediaPath.StartsWith('R:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $mediaPath = 'F:\Media\' + $mediaPath.Substring(3)
    }
    elseif ($mediaPath.StartsWith('R:/', [System.StringComparison]::OrdinalIgnoreCase)) {
        $mediaPath = 'F:/Media/' + $mediaPath.Substring(3)
    }

    # 5. Normalize path slashes for Windows
    if ($mediaPath -match '^[a-zA-Z]:') {
        $mediaPath = $mediaPath -replace '/', '\'
    }

    $script:TelemetryStage.Stop()
    $script:TelemetryParseMs = [int]$script:TelemetryStage.Elapsed.TotalMilliseconds

    # Health stage: single probe per launch (stale recheck inside).
    $script:TelemetryStage.Restart()
    $proxyHealthy = $false
    try { $proxyHealthy = Test-ProxyHealthCached }
    catch { $proxyHealthy = $false }
    # Touch TorBox key accessor (env only) so telemetry notes availability without logging the secret.
    $torboxKeyPresent = $false
    try { $torboxKeyPresent = (-not [string]::IsNullOrEmpty((Get-TorboxApiKey))) } catch { $torboxKeyPresent = $false }
    $script:TelemetryStage.Stop()
    $script:TelemetryHealthMs = [int]$script:TelemetryStage.Elapsed.TotalMilliseconds

    # Resume seconds for /seek=
    $resumeSec = 0
    try { $resumeSec = Get-ResumeSeconds $itemId $userId $token $serverUrl } catch { $resumeSec = 0 }
    if ($resumeSec -lt 0) { $resumeSec = 0 }
    $seekArgs = @()
    if ($resumeSec -gt 0) { $seekArgs += '/seek=' + $resumeSec }

    $potExe = 'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe'
    if (-not (Test-Path -LiteralPath $potExe)) {
        $altPot = 'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini64.exe'
        if (Test-Path -LiteralPath $altPot) { $potExe = $altPot }
    }

    # Playlist stage timing starts here
    $script:TelemetryStage.Restart()
    $playlistBuilt = $false
    $dplPath = ''
    $finalPlaylist = @()
    $targetIndex = 0
    $playlistAction = 'direct'

    Write-LauncherLog "LAUNCH start path=$mediaPath episodes='$Episodes' seek=$resumeSec dryrun=$($script:IsDryRun) proxyHealthy=$proxyHealthy torboxKeyPresent=$torboxKeyPresent"

    # FEATURE 1: -WhatIf dry-run helper prints playlist + actions and launches nothing.
    # Built playlist is still computed so dry-run shows exactly what would launch.

    # 6. Launch background playback sync tracker if credentials/itemId provided (skipped in dry-run)
    if ($itemId -and $userId -and $token) {
        if ($script:IsDryRun) {
            Write-Host "DRY-RUN would start sync tracker for item=$itemId user=$userId server=$serverUrl"
        }
        else {
            $trackerScript = 'F:\Jellyfin\potplayer-sync-tracker.ps1'
            if (Test-Path -LiteralPath $trackerScript) {
                try {
                    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', (Quote-PotArg $trackerScript), '-MediaPath', (Quote-PotArg $mediaPath), '-ItemId', (Quote-PotArg $itemId), '-UserId', (Quote-PotArg $userId), '-Token', (Quote-PotArg $token), '-ServerUrl', (Quote-PotArg $serverUrl) | Out-Null
                }
                catch {
                    Write-Warning "Tracker launch failed: $_"
                }
            }
        }
    }

    # 7. If local media file exists, generate complete season playlist (full-season default)
    if (Test-Path -LiteralPath $mediaPath) {
        try {
            $item = Get-Item -LiteralPath $mediaPath -ErrorAction Stop
            if ($item -is [System.IO.FileInfo]) {
                $parentFolder = $item.DirectoryName
                $extensions = @('.mkv', '.mp4', '.avi', '.ts', '.m4v', '.mov', '.webm', '.flv', '.wmv', '.m2ts')

                $rawFiles = @(Get-ChildItem -LiteralPath $parentFolder -File -ErrorAction SilentlyContinue |
                    Where-Object { $extensions -contains $_.Extension.ToLower() })

                # FEATURE 4: playlist dedupe (same path once, case-insensitive).
                $seenPaths = @{}
                $deduped = [System.Collections.Generic.List[object]]::new()
                foreach ($f in $rawFiles) {
                    try {
                        $k = ([string]$f.FullName).ToLowerInvariant()
                    }
                    catch { $k = ([string]$f).ToLowerInvariant() }
                    if ([string]::IsNullOrWhiteSpace($k)) { continue }
                    if (-not $seenPaths.ContainsKey($k)) {
                        $seenPaths[$k] = $true
                        $deduped.Add($f) | Out-Null
                    }
                }

                # FEATURE 2: missing-file skip with warning (continue playlist).
                $existing = [System.Collections.Generic.List[object]]::new()
                foreach ($f in $deduped) {
                    try {
                        $p = [string]$f.FullName
                        if (Test-Path -LiteralPath $p) { $existing.Add($f) | Out-Null }
                        else {
                            Write-Warning "Skipping missing file: $p"
                            Write-LauncherLog "SKIP missing file: $p"
                        }
                    }
                    catch {
                        Write-Warning "Skipping unreadable entry: $_"
                    }
                }

                # IndexNumber map when Jellyfin credentials present; else empty -> natural-sort fallback.
                $indexMap = @{}
                try { $indexMap = Get-JellyfinIndexMap $itemId $userId $token $serverUrl $mediaPath } catch { $indexMap = @{} }

                # FEATURE 3: natural-sort fallback when IndexNumber absent.
                $ordered = @(Sort-PlaylistByIndexOrNatural @($existing.ToArray()) $indexMap)

                # FEATURE 10: -Episodes range selector.
                $filtered = @(Select-EpisodeRange $ordered $Episodes)

                if ($filtered -and $filtered.Count -gt 0) {
                    # Recompute target index inside filtered list; default 0 when selection excludes it.
                    $targetIndex = 0
                    for ($i = 0; $i -lt $filtered.Count; $i++) {
                        try {
                            if (([string]$filtered[$i].FullName).Equals($mediaPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                                $targetIndex = $i
                                break
                            }
                        }
                        catch { }
                    }
                    # Full-season default: use playlist when >1 entry, or single entry when -Episodes picked one.
                    $usePlaylist = ($filtered.Count -gt 1) -or (-not [string]::IsNullOrWhiteSpace($Episodes))
                    if ($usePlaylist) {
                        $dplFolder = 'F:\Jellyfin\cache\playlists'
                        if (-not (Test-Path -LiteralPath $dplFolder)) {
                            New-Item -ItemType Directory -Path $dplFolder -Force | Out-Null
                        }
                        $dplPath = Join-Path $dplFolder 'season_playlist.dpl'

                        $dplLines = [System.Collections.Generic.List[string]]::new()
                        $dplLines.Add('DAUMPLAYLIST')
                        $dplLines.Add('playname=' + $mediaPath)
                        $dplLines.Add('playindex=' + $targetIndex)
                        $dplLines.Add('topindex=0')

                        $count = 1
                        foreach ($file in $filtered) {
                            $dplLines.Add("$count`*file`*" + [string]$file.FullName)
                            $cleanTitle = [System.IO.Path]::GetFileNameWithoutExtension([string]$file.Name)
                            $dplLines.Add("$count`*title`*" + $cleanTitle)
                            $count++
                        }

                        [System.IO.File]::WriteAllLines($dplPath, $dplLines, [System.Text.Encoding]::Unicode)
                        $finalPlaylist = @($filtered)
                        $playlistBuilt = $true
                        $playlistAction = "playlist:$dplPath"
                    }
                }
            }
        }
        catch {
            Write-LauncherLog "PLAYLIST build failed, falling through to direct: $_"
        }
    }
    $script:TelemetryStage.Stop()
    $script:TelemetryPlaylistMs = [int]$script:TelemetryStage.Elapsed.TotalMilliseconds

    # Launch stage
    $script:TelemetryStage.Restart()
    $launchTargetDesc = ''
    $launchArgsDesc = ''
    if ($playlistBuilt) {
        $launchTargetDesc = $dplPath
        $launchArgsDesc = (Quote-PotArg $dplPath)
        if ($seekArgs.Count -gt 0) { $launchArgsDesc += ' ' + ($seekArgs -join ' ') }
        if ($script:IsDryRun) {
            Write-Host 'DRY-RUN playlist would launch (no process started):'
            Write-Host "  PotPlayer : $potExe"
            Write-Host "  DPL       : $dplPath"
            Write-Host "  Episodes  : '$Episodes' -> $($finalPlaylist.Count) entries, playindex=$targetIndex"
            Write-Host "  Seek      : $resumeSec sec ($($seekArgs -join ' '))"
            $pi = 1
            foreach ($f in $finalPlaylist) {
                try { Write-Host ("  [{0}] {1}" -f $pi, [string]$f.FullName) } catch { }
                $pi++
            }
            Write-Host "  Actions   : Start-Process $potExe $launchArgsDesc (SKIPPED in dry-run)"
            Write-LauncherLog "DRYRUN playlist entries=$($finalPlaylist.Count) playindex=$targetIndex dpl=$dplPath seek=$resumeSec"
        }
        else {
            # FEATURE 8: quoting hardened via Quote-PotArg + array ArgumentList.
            $argList = @((Quote-PotArg $dplPath)) + $seekArgs
            Write-LauncherLog "PLAYLIST launching $dplPath seek=${resumeSec}s entries=$($finalPlaylist.Count)"
            $proc = $null
            try {
                $proc = Start-Process -FilePath $potExe -ArgumentList $argList -WindowStyle Normal -PassThru -ErrorAction Stop
            }
            catch {
                Write-LauncherLog "EXIT code=1 error=playlist-launch-failed detail=$_"
                $script:ExitCode = 1
                throw
            }
            try {
                $proc.WaitForExit()
                $code = 0
                try { $code = [int]$proc.ExitCode } catch { $code = 0 }
                # FEATURE 6: exit-code propagation + log line.
                Write-LauncherLog "EXIT code=$code action=playlist file=$dplPath"
                $script:ExitCode = $code
            }
            catch {
                Write-LauncherLog "EXIT code=0 action=playlist (no-wait fallback)"
                $script:ExitCode = 0
            }
        }
    }
    else {
        $launchTargetDesc = $mediaPath
        $argList2 = @((Quote-PotArg $mediaPath), '/current', '/play') + $seekArgs
        $launchArgsDesc = $argList2 -join ' '
        if ($script:IsDryRun) {
            Write-Host 'DRY-RUN direct would launch (no process started):'
            Write-Host "  PotPlayer : $potExe"
            Write-Host "  Media     : $mediaPath"
            Write-Host "  Seek      : $resumeSec sec ($($seekArgs -join ' '))"
            Write-Host "  Actions   : Start-Process $potExe $launchArgsDesc (SKIPPED in dry-run)"
            Write-LauncherLog "DRYRUN direct media=$mediaPath seek=$resumeSec"
        }
        else {
            Write-LauncherLog "DIRECT launching $mediaPath seek=${resumeSec}s"
            $proc2 = $null
            try {
                $proc2 = Start-Process -FilePath $potExe -ArgumentList $argList2 -WindowStyle Normal -PassThru -ErrorAction Stop
            }
            catch {
                Write-LauncherLog "EXIT code=1 error=direct-launch-failed detail=$_"
                $script:ExitCode = 1
                throw
            }
            try {
                $proc2.WaitForExit()
                $code2 = 0
                try { $code2 = [int]$proc2.ExitCode } catch { $code2 = 0 }
                Write-LauncherLog "EXIT code=$code2 action=direct file=$mediaPath"
                $script:ExitCode = $code2
            }
            catch {
                Write-LauncherLog 'EXIT code=0 action=direct (no-wait fallback)'
                $script:ExitCode = 0
            }
        }
    }
    $script:TelemetryStage.Stop()
    $script:TelemetryLaunchMs = [int]$script:TelemetryStage.Elapsed.TotalMilliseconds
    $script:TelemetryTotal.Stop()
    $totalMs = [int]$script:TelemetryTotal.Elapsed.TotalMilliseconds
    # FEATURE 7: single launch-telemetry log line (ms timings per stage).
    try {
        Write-LauncherLog "TELEMETRY total=${totalMs}ms parse=$($script:TelemetryParseMs)ms health=$($script:TelemetryHealthMs)ms playlist=$($script:TelemetryPlaylistMs)ms launch=$($script:TelemetryLaunchMs)ms episodes='$Episodes' dryrun=$($script:IsDryRun) probes=$($script:HealthProbeCount) exit=$($script:ExitCode)"
    }
    catch { }
}
catch {
    try {
        $script:TelemetryTotal.Stop()
        $tMs = [int]$script:TelemetryTotal.Elapsed.TotalMilliseconds
        Write-LauncherLog "TELEMETRY total=${tMs}ms parse=$($script:TelemetryParseMs)ms health=$($script:TelemetryHealthMs)ms playlist=$($script:TelemetryPlaylistMs)ms launch=$($script:TelemetryLaunchMs)ms episodes='$Episodes' dryrun=$($script:IsDryRun) probes=$($script:HealthProbeCount) exit=$($script:ExitCode) error=$_"
    }
    catch { }
    try { Write-LauncherLog "EXIT code=$($script:ExitCode) error=$_ " } catch { }
}
finally {
    Exit-LauncherMutex
}

exit $script:ExitCode
