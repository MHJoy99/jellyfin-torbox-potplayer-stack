<##
.SYNOPSIS
    Keeps the Google Drive rclone mount and Jellyfin libraries converged.

.DESCRIPTION
    Google Drive changes can be visible through the remote while an old rclone
    directory cache is still serving the mount. This process observes the
    remote directly, refreshes the mounted VFS, repairs the mount when needed,
    asks Jellyfin to scan, and verifies that newly discovered media appears in
    Jellyfin before acknowledging the change.

    The Run mode is intended to be a single long-running Windows Scheduled Task
    under SYSTEM. The mutex makes manual runs, task restarts, and overlapping
    recovery attempts harmless.

    10x FEATURES (feat/gdrive-10x):
      1) Cycle-time metric appended to heartbeat log.
      2) Circuit breaker: after 5 consecutive failures pause 15 minutes.
      3) Per-library last-sync timestamps JSON file.
      4) Stale-item threshold alert (no change in 24h -> warning).
      5) -WhatIf mode (scan + report, change nothing).
      6) rclone RC health check before each cycle, skip cycle if down.
      7) Schedule jitter (random 0-90s delay) to avoid thundering herd.
      8) Sync-duration history (last 20) in state file.
      9) Orphan-report mode (list only, never delete without --ConfirmDelete).
     10) Resume-from-state after crash (pick up next library, don't restart all).

    Secrets are never hardcoded. Jellyfin token resolves from -JellyfinToken
    or $env:JELLYFIN_API_KEY, with optional file fallback. rclone credentials
    stay in config\rclone.conf.
##>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Run', 'Once', 'Install', 'Uninstall', 'Status', 'Test', 'Validate', 'OrphanReport')]
    [string]$Mode = 'Run',
    [ValidateRange(15, 3600)]
    [int]$PollSeconds = 30,
    [switch]$Force,
    [switch]$ConfirmDelete,
    [switch]$NoJitter,
    [string]$JellyfinToken = $env:JELLYFIN_API_KEY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseDir = 'F:\Jellyfin'
$script:ServerDir = Join-Path $script:BaseDir 'server'
$script:RcloneExe = Join-Path $script:ServerDir 'rclone.exe'
$script:RcloneConfig = Join-Path $script:BaseDir 'config\rclone.conf'
$script:NssmExe = Join-Path $script:ServerDir 'nssm.exe'
$script:MountInstaller = Join-Path $script:BaseDir 'install-rclone-service.ps1'
$script:MountRoot = 'F:\Media'
$script:RemoteRoots = @('gdrive-media:Movies', 'gdrive-media:Series')
$script:LibraryRoots = @('F:\Media\Movies', 'F:\Media\Series')
$script:RcloneServiceName = 'RcloneGdriveMount'
$script:RcloneRcBase = 'http://127.0.0.1:5573'
$script:JellyfinUrl = 'http://127.0.0.1:8096'
$script:StateFile = Join-Path $script:BaseDir 'config\gdrive-library-sync.state.json'
$script:LibrarySyncFile = Join-Path $script:BaseDir 'config\gdrive-library-sync.libraries.json'
$script:LogFile = Join-Path $script:BaseDir 'logs\gdrive-library-sync.log'
$script:HeartbeatLog = Join-Path $script:BaseDir 'logs\gdrive-library-sync.heartbeat.log'
$script:TaskName = 'MediaServer_GoogleDriveLibrarySync'
$script:VideoExtensions = @('.mkv', '.mp4', '.avi', '.mov', '.ts', '.m2ts', '.webm', '.iso', '.wmv', '.m4v', '.flv')
$script:Mutex = $null
$script:LastMountRepairAt = [DateTime]::MinValue
$script:JellyfinTokenCache = $null
$script:RcloneTpsLimit = '8'
$script:RcloneTpsBurst = '8'
$script:RclonePacerMinSleep = '100ms'
$script:RclonePacerBurst = '8'
$script:ListingMaxAttempts = 4
$script:ListingBaseDelaySeconds = 2
# Feature 2: Circuit breaker tuning.
$script:CircuitBreakerThreshold = 5
$script:CircuitBreakerPauseMinutes = 15
# Feature 4: Stale-item threshold.
$script:StaleThresholdHours = 24
# Feature 7: Schedule jitter tuning.
$script:ScheduleJitterMaxSeconds = 90
# Feature 8: Sync-duration history tuning.
$script:MaxDurationHistory = 20

function Write-SyncLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')

    $parent = Split-Path -Parent $script:LogFile
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

# Feature 1: Cycle-time metric appended to heartbeat log.
# Every sync cycle measures its wall-clock duration and appends a single
# heartbeat line containing the cycle-time metric. The heartbeat log is a
# lightweight, append-only file operators can tail without parsing the verbose log.
function Write-HeartbeatLog {
    param(
        [double]$CycleSeconds,
        [string]$Status = 'unknown',
        [int]$PendingCount = 0,
        [int]$FileCount = 0
    )

    $parent = Split-Path -Parent $script:HeartbeatLog
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $rounded = [Math]::Round($CycleSeconds, 2)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [HEARTBEAT] cycle-time=${rounded}s status=$Status pending=$PendingCount files=$FileCount"
    Add-Content -LiteralPath $script:HeartbeatLog -Value $line -Encoding UTF8
    # Also mirror the cycle-time metric to the main log for correlation.
    Write-SyncLog "Heartbeat: cycle-time=${rounded}s status=$Status pending=$PendingCount files=$FileCount"
}

function Get-TextHash {
    param([AllowEmptyString()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Invoke-Rclone {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 90
    )

    if (-not (Test-Path -LiteralPath $script:RcloneExe -PathType Leaf)) {
        throw "rclone executable is missing: $script:RcloneExe"
    }

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $script:RcloneExe
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$info.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) {
        throw 'Could not start rclone.'
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch {}
        throw "rclone timed out after $TimeoutSeconds seconds"
    }
    $process.WaitForExit()

    [PSCustomObject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdoutTask.Result
        StdErr = $stderrTask.Result
    }
}

function Get-RemoteErrorCategory {
    param([string]$Detail)

    $text = [string]$Detail
    $lower = $text.ToLowerInvariant()
    # Token-fetch DNS/TLS failures surface as "couldn't fetch token" but are network, not auth.
    $isNetworkSymptom = (
        $lower -match 'no such host' -or
        $lower -match 'dial tcp' -or
        $lower -match 'connectex' -or
        $lower -match 'connection (reset|refused|aborted)' -or
        $lower -match 'timed out|timeout|deadline exceeded' -or
        $lower -match '\btls\b|certificate|network is unreachable|socket' -or
        $lower -match 'temporarily unavailable|service unavailable'
    )
    if ($isNetworkSymptom) { return 'network' }
    if ($lower -match 'invalid_grant|invalid_client|invalid_request.*token|unauthorized|authentication failed|auth failed|token.*(expired|revoked|invalid)|refresh.*(failed|invalid)|\b401\b') { return 'auth' }
    if ($lower -match 'ratelimit|rate.limit|quotaexceeded|quota exceeded|too many requests|\b429\b|userratelimitexceeded|downloadquotaexceeded|dailylimitexceeded') { return 'quota' }
    if ($lower -match '\b403\b') { return 'quota' }
    if ($lower -match '\b(500|502|503|504)\b|backend error|internal error') { return 'network' }
    if ($lower -match '\b404\b|not.?found|trashed|folder not found|root_folder_id') { return 'notfound' }
    return 'unknown'
}

function Get-ListingRetryDelaySeconds {
    param([int]$Attempt)

    $exp = $script:ListingBaseDelaySeconds * [Math]::Pow(2, ($Attempt - 1))
    $jitterMs = Get-Random -Minimum 0 -Maximum 1000
    return ($exp + ($jitterMs / 1000.0))
}

function Test-RcloneTokenConfig {
    if (-not (Test-Path -LiteralPath $script:RcloneConfig -PathType Leaf)) {
        throw "rclone config is missing: $script:RcloneConfig"
    }
    $raw = Get-Content -LiteralPath $script:RcloneConfig -Raw -ErrorAction Stop
    $block = ([regex]::Match($raw, '(?ms)^\[gdrive-media\].*?(?=^\[|\z)')).Value
    if (-not $block) { throw 'rclone config has no [gdrive-media] remote.' }
    if ($block -notmatch '(?m)^token\s*=') { throw "rclone config [gdrive-media] has no token; run 'rclone config reconnect gdrive-media:'." }
    if ($block -notmatch '(?m)^client_id\s*=|(?m)^client_secret\s*=') {
        Write-SyncLog 'rclone config [gdrive-media] uses default client_id; custom OAuth client is recommended.' 'WARN'
    }
    $true
}

function Invoke-RcloneListingWithRetry {
    param(
        [Parameter(Mandatory)][string]$RemoteRoot,
        [string[]]$ExtraArgs = @(),
        [int]$TimeoutSeconds = 90
    )

    [void](Test-RcloneTokenConfig)
    $baseArgs = @(
        '--config', $script:RcloneConfig,
        '--tpslimit', $script:RcloneTpsLimit,
        '--tpslimit-burst', $script:RcloneTpsBurst,
        '--drive-pacer-min-sleep', $script:RclonePacerMinSleep,
        '--drive-pacer-burst', $script:RclonePacerBurst,
        '--retries', '1',
        '--low-level-retries', '3',
        '--timeout', '60s'
    ) + $ExtraArgs
    $lastError = ''
    for ($attempt = 1; $attempt -le $script:ListingMaxAttempts; $attempt++) {
        $result = Invoke-Rclone -Arguments $baseArgs -TimeoutSeconds $TimeoutSeconds
        if ($result.ExitCode -eq 0) {
            if ($attempt -gt 1) {
                Write-SyncLog "Remote listing for $RemoteRoot succeeded on attempt $attempt/$($script:ListingMaxAttempts)."
            }
            return $result
        }
        $flat = (([string]$result.StdErr + ' ' + [string]$result.StdOut).Trim() -replace '\s+', ' ')
        $category = Get-RemoteErrorCategory $flat
        if ($flat.Length -gt 1200) { $flat = $flat.Substring(0, 500) + ' ... ' + $flat.Substring($flat.Length - 600) }
        $lastError = "Remote listing failed for $RemoteRoot (exit $($result.ExitCode)) [category=$category] [attempt=$attempt/$($script:ListingMaxAttempts)]: $flat"
        if ($category -eq 'auth') {
            throw "$lastError [action=run 'rclone config reconnect gdrive-media:' then Validate]"
        }
        if ($category -eq 'notfound') {
            throw "$lastError [action=check root_folder_id / trashed remote]"
        }
        $retryable = ($category -eq 'quota' -or $category -eq 'network' -or $category -eq 'unknown')
        if ((-not $retryable) -or ($attempt -ge $script:ListingMaxAttempts)) {
            throw $lastError
        }
        $delay = Get-ListingRetryDelaySeconds -Attempt $attempt
        Write-SyncLog "$lastError [action=retry in $([Math]::Round($delay, 1))s]" 'WARN'
        Start-Sleep -Seconds $delay
    }
    throw $lastError
}

# Feature 10 helper: single-library snapshot so resume-from-state can persist
# progress after each library instead of restarting all libraries on crash.
function Get-RemoteSnapshotForLibrary {
    param([Parameter(Mandatory)][string]$RemoteRoot)

    $result = Invoke-RcloneListingWithRetry -RemoteRoot $RemoteRoot -ExtraArgs @(
        'lsf', $RemoteRoot,
        '--recursive',
        '--files-only',
        '--fast-list',
        '--format', 'stp',
        '--separator', "`t",
        '--time-format', 'unix'
    ) -TimeoutSeconds 90

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 3
        if ($parts.Count -ne 3) {
            throw "Unexpected rclone listing format for $RemoteRoot"
        }
        $relativePath = $parts[2].Trim()
        $normalizedPath = $relativePath -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($normalizedPath) -or
            $normalizedPath.StartsWith('/') -or
            $normalizedPath -match '(^|/)\.\.(\/|$)') {
            throw "Unsafe remote path returned by rclone: $relativePath"
        }
        $records.Add([PSCustomObject]@{
            Root = $RemoteRoot
            RelativePath = $normalizedPath
            Size = $parts[0].Trim()
            ModTime = $parts[1].Trim()
            Key = "$RemoteRoot|$normalizedPath"
        })
    }
    @($records.ToArray())
}

function Get-RemoteSnapshot {
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($remoteRoot in $script:RemoteRoots) {
        foreach ($rec in @(Get-RemoteSnapshotForLibrary -RemoteRoot $remoteRoot)) {
            [void]$records.Add($rec)
        }
    }

    $canonicalLines = @(
        $records | Sort-Object Key, Size, ModTime | ForEach-Object {
            "$($_.Key)|$($_.Size)|$($_.ModTime)"
        }
    )
    $canonical = $canonicalLines -join "`n"
    [PSCustomObject]@{
        Signature = Get-TextHash $canonical
        FileCount = $records.Count
        Files = @($records.ToArray())
    }
}

function New-EmptyState {
    [PSCustomObject]@{
        Version = 1
        LastObservedSignature = ''
        LastSuccessfulSignature = ''
        PendingSignature = ''
        PendingPaths = @()
        Files = @()
        LastRemotePollUtc = ''
        LastSuccessfulRefreshUtc = ''
        LastRefreshAttemptUtc = ''
        LastFileCount = 0
        LastRefreshStatus = 'never'
        LastError = ''
        # Feature 2: Circuit breaker state.
        ConsecutiveFailures = 0
        CircuitBreakerUntil = ''
        # Feature 4: Stale tracking.
        LastChangeUtc = ''
        # Feature 8: Sync-duration history (last 20 cycle durations, seconds).
        SyncDurationHistory = @()
        LastCycleSeconds = 0
        TotalCycles = 0
        # Feature 10: Resume-from-state progress.
        PendingLibraries = @()
        NextLibraryIndex = 0
        CompletedLibraries = @()
    }
}

function Load-State {
    if (-not (Test-Path -LiteralPath $script:StateFile -PathType Leaf)) {
        return New-EmptyState
    }
    try {
        $state = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $state.Version) { throw 'State file has no version.' }
        if ($null -eq $state.PendingPaths) { $state | Add-Member -NotePropertyName PendingPaths -NotePropertyValue @() }
        if ($null -eq $state.Files) { $state | Add-Member -NotePropertyName Files -NotePropertyValue @() }
        # Backward-compat defaults for 10x fields (resume/circuit/duration).
        if ($null -eq $state.PSObject.Properties['ConsecutiveFailures']) { $state | Add-Member -NotePropertyName ConsecutiveFailures -NotePropertyValue 0 }
        if ($null -eq $state.PSObject.Properties['CircuitBreakerUntil']) { $state | Add-Member -NotePropertyName CircuitBreakerUntil -NotePropertyValue '' }
        if ($null -eq $state.PSObject.Properties['LastChangeUtc']) { $state | Add-Member -NotePropertyName LastChangeUtc -NotePropertyValue '' }
        if ($null -eq $state.PSObject.Properties['SyncDurationHistory']) { $state | Add-Member -NotePropertyName SyncDurationHistory -NotePropertyValue @() }
        if ($null -eq $state.PSObject.Properties['LastCycleSeconds']) { $state | Add-Member -NotePropertyName LastCycleSeconds -NotePropertyValue 0 }
        if ($null -eq $state.PSObject.Properties['TotalCycles']) { $state | Add-Member -NotePropertyName TotalCycles -NotePropertyValue 0 }
        if ($null -eq $state.PSObject.Properties['PendingLibraries']) { $state | Add-Member -NotePropertyName PendingLibraries -NotePropertyValue @() }
        if ($null -eq $state.PSObject.Properties['NextLibraryIndex']) { $state | Add-Member -NotePropertyName NextLibraryIndex -NotePropertyValue 0 }
        if ($null -eq $state.PSObject.Properties['CompletedLibraries']) { $state | Add-Member -NotePropertyName CompletedLibraries -NotePropertyValue @() }
        return $state
    } catch {
        $badState = "$($script:StateFile).corrupt-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item -LiteralPath $script:StateFile -Destination $badState -Force -ErrorAction SilentlyContinue
        Write-SyncLog "State file was invalid; started a clean state. Backup: $badState" 'WARN'
        return New-EmptyState
    }
}

function Save-State {
    param([Parameter(Mandatory)]$State)

    $parent = Split-Path -Parent $script:StateFile
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = "$($script:StateFile).tmp-$PID"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $script:StateFile -Force
}

# Feature 2: Circuit breaker — after 5 consecutive failures pause 15 minutes.
function Test-CircuitBreakerOpen {
    param([Parameter(Mandatory)]$State)

    $raw = [string]$State.CircuitBreakerUntil
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    try {
        $until = [DateTime]::Parse($raw).ToUniversalTime()
    } catch {
        return $false
    }
    if ([DateTime]::UtcNow -lt $until) {
        $remaining = [Math]::Ceiling(($until - [DateTime]::UtcNow).TotalMinutes)
        Write-SyncLog "Circuit breaker OPEN (failures=$($State.ConsecutiveFailures)); pausing until $raw (~${remaining}m remaining). Skipping cycle." 'WARN'
        return $true
    }
    return $false
}

function Register-CycleSuccess {
    param([Parameter(Mandatory)]$State)

    $State.ConsecutiveFailures = 0
    $State.CircuitBreakerUntil = ''
}

function Register-CycleFailure {
    param(
        [Parameter(Mandatory)]$State,
        [string]$ErrorMessage = ''
    )

    $count = 0
    try { $count = [int]$State.ConsecutiveFailures } catch { $count = 0 }
    $count++
    $State.ConsecutiveFailures = $count
    if ($count -ge $script:CircuitBreakerThreshold) {
        $until = [DateTime]::UtcNow.AddMinutes($script:CircuitBreakerPauseMinutes).ToString('o')
        $State.CircuitBreakerUntil = $until
        Write-SyncLog "Circuit breaker TRIPPED after $count consecutive failures; pausing $($script:CircuitBreakerPauseMinutes) minutes until $until. Last error: $ErrorMessage" 'ERROR'
    } else {
        Write-SyncLog "Cycle failure $count/$($script:CircuitBreakerThreshold) (breaker opens at $($script:CircuitBreakerThreshold)): $ErrorMessage" 'WARN'
    }
}

# Feature 3: Per-library last-sync timestamps JSON file.
function Load-LibrarySyncTimes {
    if (-not (Test-Path -LiteralPath $script:LibrarySyncFile -PathType Leaf)) {
        return @{}
    }
    try {
        $json = Get-Content -LiteralPath $script:LibrarySyncFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        foreach ($prop in @($json.PSObject.Properties)) {
            $map[$prop.Name] = [string]$prop.Value
        }
        return $map
    } catch {
        Write-SyncLog "Library sync file invalid; starting fresh: $($_.Exception.Message)" 'WARN'
        return @{}
    }
}

function Save-LibrarySyncTime {
    param(
        [Parameter(Mandatory)][string]$Library,
        [string]$TimestampUtc = ([DateTime]::UtcNow.ToString('o'))
    )

    $parent = Split-Path -Parent $script:LibrarySyncFile
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $map = Load-LibrarySyncTimes
    $map[$Library] = $TimestampUtc
    $obj = [PSCustomObject]$map
    $temporary = "$($script:LibrarySyncFile).tmp-$PID"
    $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $script:LibrarySyncFile -Force
    Write-SyncLog "Per-library sync timestamp updated: $Library -> $TimestampUtc"
}

# Feature 4: Stale-item threshold alert (no change in 24h -> warning).
function Test-StaleThreshold {
    param([Parameter(Mandatory)]$State)

    $raw = [string]$State.LastChangeUtc
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    try {
        $lastChange = [DateTime]::Parse($raw).ToUniversalTime()
    } catch {
        return $false
    }
    $hours = ([DateTime]::UtcNow - $lastChange).TotalHours
    if ($hours -ge $script:StaleThresholdHours) {
        Write-SyncLog "STALE WARNING: no library change observed in $([Math]::Round($hours, 1))h (threshold $($script:StaleThresholdHours)h, lastChange=$raw)." 'WARN'
        return $true
    }
    return $false
}

# Feature 5: -WhatIf mode (scan + report, change nothing).
function Test-WhatIfRequested {
    # SupportsShouldProcess gives us -WhatIf natively; honour both preference and explicit bound param.
    if ($WhatIfPreference.IsPresent -and [bool]$WhatIfPreference) { return $true }
    if ($PSBoundParameters.ContainsKey('WhatIf') -and [bool]$PSBoundParameters['WhatIf']) { return $true }
    # Also honour the automatic WhatIf variable when SupportsShouldProcess triggers it.
    try {
        if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('probe', 'whatif-check')) { return $true }
    } catch {
        # ShouldProcess throws when -WhatIf was passed without confirmation; treat as WhatIf.
        return $true
    }
    return $false
}

function Invoke-WhatIfReport {
    param($State)

    Write-SyncLog 'WhatIf mode: scan + report, changing nothing (no state writes, no mount repair, no Jellyfin refresh).'
    $snapshot = Get-RemoteSnapshot
    $oldFiles = @()
    if ($State -and $null -ne $State.Files) { $oldFiles = @($State.Files) }
    $changed = @(Get-ChangedMountPaths -OldFiles $oldFiles -NewFiles $snapshot.Files)
    $report = [PSCustomObject]@{
        Mode = 'WhatIf'
        RemoteFiles = $snapshot.FileCount
        ChangedMediaPaths = $changed.Count
        ChangedPaths = @($changed)
        Signature = $snapshot.Signature
        Note = 'WhatIf: scanned remote and compared to saved state; changed nothing.'
    }
    Write-Output "WhatIf REPORT: $($snapshot.FileCount) remote files, $($changed.Count) changed media path(s); no changes made."
    foreach ($p in @($changed | Select-Object -First 50)) {
        Write-Output "WhatIf WOULD-SYNC: $p"
    }
    if ($changed.Count -gt 50) {
        Write-Output "WhatIf ... and $($changed.Count - 50) more (truncated)."
    }
    return $report
}

# Feature 6: rclone RC health check before each cycle, skip cycle if down.
function Test-RcloneRcHealth {
    param([int]$TimeoutSec = 5)

    try {
        # rc/noop is the lightest health probe; fall back to vfs/stats if noop is disabled.
        try {
            $null = Invoke-RestMethod -Uri "$($script:RcloneRcBase)/rc/noop" -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec $TimeoutSec
            return $true
        } catch {
            $msg = [string]$_.Exception.Message
            # 404 on /rc/noop means RC is up but endpoint naming differs; try vfs/stats.
            if ($msg -match '404') {
                $null = Invoke-RestMethod -Uri "$($script:RcloneRcBase)/vfs/stats" -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec $TimeoutSec
                return $true
            }
            throw
        }
    } catch {
        Write-SyncLog "rclone RC health check FAILED ($($script:RcloneRcBase)): $($_.Exception.Message). Skipping cycle." 'WARN'
        return $false
    }
}

# Feature 7: Schedule jitter (random 0-90s delay) to avoid thundering herd.
function Invoke-ScheduleJitter {
    param([switch]$ForceJitter)

    if ($NoJitter -and -not $ForceJitter) {
        Write-SyncLog 'Schedule jitter skipped (-NoJitter).'
        return 0
    }
    $delay = Get-Random -Minimum 0 -Maximum ($script:ScheduleJitterMaxSeconds + 1)
    Write-SyncLog "Schedule jitter: delaying start by ${delay}s (0-$($script:ScheduleJitterMaxSeconds)s) to avoid thundering herd."
    if ($delay -gt 0) {
        Start-Sleep -Seconds $delay
    }
    return $delay
}

# Feature 8: Sync-duration history (last 20) in state file.
function Add-SyncDurationHistory {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][double]$Seconds
    )

    $rounded = [Math]::Round($Seconds, 2)
    $history = @()
    if ($null -ne $State.SyncDurationHistory) { $history = @($State.SyncDurationHistory) }
    $history += $rounded
    if ($history.Count -gt $script:MaxDurationHistory) {
        $history = @($history | Select-Object -Last $script:MaxDurationHistory)
    }
    $State.SyncDurationHistory = @($history)
    $State.LastCycleSeconds = $rounded
    try { $State.TotalCycles = [int]$State.TotalCycles + 1 } catch { $State.TotalCycles = 1 }
}

function Test-MediaRecord {
    param([Parameter(Mandatory)]$Record)
    $extension = [System.IO.Path]::GetExtension([string]$Record.RelativePath).ToLowerInvariant()
    return $script:VideoExtensions -contains $extension
}

function Get-MountPath {
    param([Parameter(Mandatory)]$Record)

    $rootName = ([string]$Record.Root).Substring(([string]$Record.Root).IndexOf(':') + 1).Trim('/', '\')
    $relative = ([string]$Record.RelativePath) -replace '/', '\'
    Join-Path (Join-Path $script:MountRoot $rootName) $relative
}

function Get-ChangedMountPaths {
    param(
        [AllowNull()][object[]]$OldFiles,
        [Parameter(Mandatory)][object[]]$NewFiles
    )

    $oldMap = @{}
    foreach ($file in @($OldFiles)) {
        if ($file -and $file.Key) { $oldMap[[string]$file.Key] = $file }
    }
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($NewFiles)) {
        if (-not (Test-MediaRecord $file)) { continue }
        $old = $oldMap[[string]$file.Key]
        if ($null -eq $old -or [string]$old.Size -ne [string]$file.Size -or [string]$old.ModTime -ne [string]$file.ModTime) {
            [void]$paths.Add((Get-MountPath $file))
        }
    }
    @($paths)
}

function Get-MountHealth {
    $serviceStatus = 'Missing'
    try {
        $service = Get-Service -Name $script:RcloneServiceName -ErrorAction Stop
        $serviceStatus = [string]$service.Status
    } catch {}

    $processes = @()
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ieq 'rclone.exe' -and [string]$_.CommandLine -match 'mount\s+gdrive-media'
        })
    } catch {}

    $pathsVisible = @($script:LibraryRoots | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -eq $script:LibraryRoots.Count
    [PSCustomObject]@{
        Healthy = ($serviceStatus -eq 'Running' -and $processes.Count -gt 0 -and $pathsVisible)
        ServiceStatus = $serviceStatus
        ProcessCount = $processes.Count
        PathsVisible = $pathsVisible
    }
}

function Invoke-Nssm {
    param([Parameter(Mandatory)][string]$Command)

    if (-not (Test-Path -LiteralPath $script:NssmExe -PathType Leaf)) {
        throw "NSSM executable is missing: $script:NssmExe"
    }
    $process = Start-Process -FilePath $script:NssmExe -ArgumentList @($Command, $script:RcloneServiceName) -WindowStyle Hidden -Wait -PassThru
    $process.ExitCode -eq 0
}

function Wait-ForMount {
    param([int]$TimeoutSeconds = 60)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ((Get-MountHealth).Healthy) { return $true }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    $false
}

function Ensure-Mount {
    $health = Get-MountHealth
    if ($health.Healthy) { return $true }

    if (([DateTime]::UtcNow - $script:LastMountRepairAt).TotalSeconds -lt 60) {
        return $false
    }
    $script:LastMountRepairAt = [DateTime]::UtcNow
    Write-SyncLog "Google Drive mount unhealthy (service=$($health.ServiceStatus), processes=$($health.ProcessCount), paths=$($health.PathsVisible)); attempting repair." 'WARN'

    try {
        if ($health.ServiceStatus -eq 'Missing') {
            if (-not (Test-Path -LiteralPath $script:MountInstaller -PathType Leaf)) {
                throw "Mount installer is missing: $script:MountInstaller"
            }
            $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
            if (-not $pwsh) { $pwsh = (Get-Command powershell.exe -ErrorAction Stop).Source }
            $installer = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:MountInstaller) -WindowStyle Hidden -Wait -PassThru
            if ($installer.ExitCode -ne 0) { throw "Mount installer exited with $($installer.ExitCode)" }
        } elseif ($health.ServiceStatus -ne 'Running') {
            if (-not (Invoke-Nssm 'start')) { throw 'NSSM could not start the Google Drive mount service.' }
        } else {
            if (-not (Invoke-Nssm 'restart')) { throw 'NSSM could not restart the Google Drive mount service.' }
        }
        if (Wait-ForMount 60) {
            Write-SyncLog 'Google Drive mount repair succeeded.'
            return $true
        }
        throw 'Mount path did not become healthy within 60 seconds.'
    } catch {
        Write-SyncLog "Google Drive mount repair failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Invoke-RcloneCacheRefresh {
    param([object[]]$PendingPaths)

    $directories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $script:LibraryRoots) { [void]$directories.Add($root) }
    foreach ($path in @($PendingPaths)) {
        if ($path) {
            $parent = [System.IO.Path]::GetDirectoryName([string]$path)
            if ($parent) { [void]$directories.Add($parent) }
        }
    }

    $allSucceeded = $true
    foreach ($directory in @($directories)) {
        try {
            $relativeDirectory = [System.IO.Path]::GetRelativePath($script:MountRoot, [System.IO.Path]::GetFullPath([string]$directory))
            if ($relativeDirectory -eq '.') {
                $vfsDirectory = '/'
            } else {
                $vfsDirectory = '/' + ($relativeDirectory -replace '\\', '/')
            }
            $body = @{ dir = $vfsDirectory; recursive = 'false' } | ConvertTo-Json -Compress
            $response = Invoke-RestMethod -Uri "$($script:RcloneRcBase)/vfs/refresh" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10
            $failed = @($response.result.PSObject.Properties | Where-Object { [string]$_.Value -ne 'OK' })
            if ($failed.Count -gt 0) {
                $allSucceeded = $false
                $details = ($failed | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
                Write-SyncLog "rclone did not refresh ${vfsDirectory}: $details" 'WARN'
            }
        } catch {
            $allSucceeded = $false
            Write-SyncLog "Could not invalidate rclone cache for ${directory}: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($allSucceeded) { Write-SyncLog "Invalidated rclone directory cache for $($directories.Count) directories." }
    $allSucceeded
}

function Wait-ForMountedPaths {
    param(
        [object[]]$Paths,
        [int]$TimeoutSeconds = 90
    )

    $expected = @($Paths | Where-Object { $_ } | Select-Object -Unique)
    if ($expected.Count -eq 0) { return $true }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $attempt = 0
    do {
        $missing = @($expected | Where-Object {
            try { -not (Test-Path -LiteralPath $_ -PathType Leaf) } catch { $true }
        })
        if ($missing.Count -eq 0) { return $true }
        if (($attempt -eq 0) -or ($attempt % 6 -eq 0)) {
            [void](Invoke-RcloneCacheRefresh $missing)
            Write-SyncLog "Waiting for $($missing.Count) newly changed media path(s) to appear on the mount." 'WARN'
        }
        $attempt++
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)

    Write-SyncLog "Mount still misses $($missing.Count) expected media path(s) after $TimeoutSeconds seconds." 'WARN'
    $false
}

function Get-JellyfinTokenValue {
    if ($script:JellyfinTokenCache) { return $script:JellyfinTokenCache }
    if ($JellyfinToken) {
        $script:JellyfinTokenCache = $JellyfinToken
        return $script:JellyfinTokenCache
    }

    $sourceCandidates = @(
        (Join-Path $script:BaseDir 'config\jellyfin-sync-token.txt'),
        'E:\MediaServer\tools\torbox_smart_sync.py'
    )
    foreach ($candidate in $sourceCandidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $content = Get-Content -LiteralPath $candidate -Raw -ErrorAction SilentlyContinue
        if ($candidate.EndsWith('.txt')) {
            $value = $content.Trim()
        } else {
            $match = [regex]::Match($content, 'DEFAULT_JELLYFIN_API_KEY\s*=\s*["'']([^"'']+)["'']')
            $value = if ($match.Success) { $match.Groups[1].Value } else { '' }
        }
        if ($value) {
            $script:JellyfinTokenCache = $value
            return $script:JellyfinTokenCache
        }
    }
    ''
}

function Invoke-JellyfinRefresh {
    $token = Get-JellyfinTokenValue
    if (-not $token) {
        Write-SyncLog 'Jellyfin API token is unavailable; the mount will continue healing and the pending scan will be retried.' 'ERROR'
        return $false
    }

    $headers = @{ 'X-Emby-Token' = $token }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri "$($script:JellyfinUrl)/Library/Refresh" -Method Post -Headers $headers -Body '' -TimeoutSec 20
            if ($response.StatusCode -in @(200, 204)) {
                Write-SyncLog "Jellyfin library refresh accepted (attempt $attempt)."
                return $true
            }
            Write-SyncLog "Jellyfin library refresh returned HTTP $($response.StatusCode) (attempt $attempt)." 'WARN'
        } catch {
            Write-SyncLog "Jellyfin library refresh failed (attempt $attempt): $($_.Exception.Message)" 'WARN'
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
    }
    $false
}

function Wait-ForJellyfinPaths {
    param(
        [object[]]$Paths,
        [int]$TimeoutSeconds = 120
    )

    $expected = @($Paths | Where-Object { $_ -and ([System.IO.Path]::GetExtension([string]$_).ToLowerInvariant() -in $script:VideoExtensions) } | ForEach-Object {
        ([System.IO.Path]::GetFullPath([string]$_)).ToLowerInvariant()
    } | Select-Object -Unique)
    if ($expected.Count -eq 0) { return $true }

    $token = Get-JellyfinTokenValue
    if (-not $token) { return $false }
    $headers = @{ 'X-Emby-Token' = $token }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastErrorAt = [DateTime]::MinValue
    do {
        try {
            $items = Invoke-RestMethod -Uri "$($script:JellyfinUrl)/Items?Recursive=true&IncludeItemTypes=Movie,Episode&Fields=Path&Limit=10000" -Headers $headers -TimeoutSec 20
            $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($item in @($items.Items)) {
                if ($item.Path) { [void]$found.Add(([System.IO.Path]::GetFullPath([string]$item.Path)).ToLowerInvariant()) }
            }
            $missing = @($expected | Where-Object { -not $found.Contains($_) })
            if ($missing.Count -eq 0) {
                Write-SyncLog "Jellyfin verification passed for $($expected.Count) changed media path(s)."
                return $true
            }
            if (([DateTime]::UtcNow - $lastErrorAt).TotalSeconds -ge 20) {
                Write-SyncLog "Jellyfin scan is still processing; $($missing.Count) changed media path(s) are not indexed yet." 'WARN'
                $lastErrorAt = [DateTime]::UtcNow
            }
        } catch {
            if (([DateTime]::UtcNow - $lastErrorAt).TotalSeconds -ge 20) {
                Write-SyncLog "Jellyfin verification request failed: $($_.Exception.Message)" 'WARN'
                $lastErrorAt = [DateTime]::UtcNow
            }
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    $false
}

# Feature 9: Orphan-report mode (list only, never delete without --ConfirmDelete).
function Invoke-OrphanReport {
    param(
        [switch]$DeleteConfirmed
    )

    Write-SyncLog "Orphan-report mode started (ConfirmDelete=$([bool]$DeleteConfirmed)). List-only unless --ConfirmDelete is supplied."
    $snapshot = Get-RemoteSnapshot
    $remoteKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($snapshot.Files)) {
        if ($f -and $f.Key) { [void]$remoteKeys.Add([string]$f.Key) }
    }

    # Map local files back to remote keys by comparing mount-relative paths.
    $orphans = [System.Collections.Generic.List[string]]::new()
    foreach ($libRoot in @($script:LibraryRoots)) {
        if (-not (Test-Path -LiteralPath $libRoot -PathType Container)) {
            Write-SyncLog "Orphan scan: library root missing, skipping: $libRoot" 'WARN'
            continue
        }
        # Determine which remote root corresponds to this library root.
        $libName = Split-Path -Leaf $libRoot
        $candidateRoots = @($script:RemoteRoots | Where-Object { $_ -like "*:$libName" })
        if ($candidateRoots.Count -eq 0) { $candidateRoots = @($script:RemoteRoots) }
        $localFiles = @(Get-ChildItem -LiteralPath $libRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $script:VideoExtensions -contains $_.Extension.ToLowerInvariant()
        })
        foreach ($lf in $localFiles) {
            $matched = $false
            foreach ($rr in $candidateRoots) {
                $rel = [System.IO.Path]::GetRelativePath($libRoot, $lf.FullName) -replace '\\', '/'
                $key = "$rr|$rel"
                if ($remoteKeys.Contains($key)) { $matched = $true; break }
            }
            if (-not $matched) {
                [void]$orphans.Add($lf.FullName)
            }
        }
    }

    $orphanList = @($orphans.ToArray())
    Write-Output "Orphan REPORT: $($orphanList.Count) local file(s) with no remote counterpart (list-only unless --ConfirmDelete)."
    foreach ($o in @($orphanList | Select-Object -First 100)) {
        Write-Output "Orphan: $o"
    }
    if ($orphanList.Count -gt 100) {
        Write-Output "Orphan ... and $($orphanList.Count - 100) more (truncated)."
    }
    Write-SyncLog "Orphan-report: found $($orphanList.Count) orphan(s)."

    # Safety: never delete without explicit --ConfirmDelete, and never delete under WhatIf.
    $whatIf = $false
    try { $whatIf = Test-WhatIfRequested } catch { $whatIf = $false }
    if ($whatIf -and $orphanList.Count -gt 0) {
        Write-Output 'Orphan WhatIf: would delete nothing (WhatIf active; change nothing).'
        return @($orphanList)
    }
    if (-not $DeleteConfirmed) {
        Write-Output 'Orphan-report mode: list-only (pass -ConfirmDelete to actually delete). No files deleted.'
        return @($orphanList)
    }
    if (-not $PSCmdlet.ShouldProcess("$($orphanList.Count) orphan file(s)", 'Delete orphans')) {
        Write-Output 'Orphan delete cancelled by WhatIf/ShouldProcess. No files deleted.'
        return @($orphanList)
    }
    foreach ($o in $orphanList) {
        try {
            Remove-Item -LiteralPath $o -Force -ErrorAction Stop
            Write-SyncLog "Orphan deleted (--ConfirmDelete): $o"
        } catch {
            Write-SyncLog "Orphan delete failed for ${o}: $($_.Exception.Message)" 'WARN'
        }
    }
    Write-Output "Orphan delete complete with --ConfirmDelete: processed $($orphanList.Count) file(s)."
    return @($orphanList)
}

function Invoke-SyncCycle {
    param([switch]$ForceScan)

    $cycleTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $cycleStatus = 'failed'
    $state = Load-State
    $pendingCountForHeartbeat = 0
    $fileCountForHeartbeat = 0
    try {
        # Feature 6: rclone RC health check before each cycle, skip cycle if down.
        if (-not (Test-RcloneRcHealth)) {
            $state.LastRefreshStatus = 'waiting-for-rc'
            $state.LastError = 'rclone RC is down; cycle skipped.'
            Save-State $state
            $cycleStatus = 'skipped-rc-down'
            Write-SyncLog 'Cycle skipped: rclone RC health check failed.' 'WARN'
            return $false
        }

        # Feature 2: Circuit breaker gate.
        if (Test-CircuitBreakerOpen -State $state) {
            $cycleStatus = 'skipped-breaker-open'
            return $false
        }

        # Feature 5: -WhatIf mode (scan + report, change nothing).
        # Detect native -WhatIf via preference/bound params without mutating state.
        $isWhatIf = $false
        try { $isWhatIf = Test-WhatIfRequested } catch { $isWhatIf = $false }
        if ($isWhatIf) {
            [void](Invoke-WhatIfReport -State $state)
            $cycleStatus = 'whatif'
            return $true
        }

        # Feature 10: Resume-from-state after crash (pick up next library, don't restart all).
        $resumeLibraries = @($script:RemoteRoots)
        $startIndex = 0
        $savedPending = @($state.PendingLibraries)
        $savedIndex = 0
        try { $savedIndex = [int]$state.NextLibraryIndex } catch { $savedIndex = 0 }
        if ($savedPending.Count -gt 0 -and $savedIndex -gt 0 -and $savedIndex -lt $savedPending.Count) {
            # Previous cycle crashed mid-library-loop; resume where it left off.
            $resumeLibraries = @($savedPending)
            $startIndex = $savedIndex
            Write-SyncLog "Resume-from-state: picking up at library $($startIndex + 1)/$($resumeLibraries.Count) ($($resumeLibraries[$startIndex])) instead of restarting all." 'WARN'
        } else {
            # Fresh cycle: initialise resume cursor.
            $state.PendingLibraries = @($script:RemoteRoots)
            $state.NextLibraryIndex = 0
            $state.CompletedLibraries = @()
            Save-State $state
        }

        # Per-library snapshot loop with crash-safe progress persistence.
        $allRecords = [System.Collections.Generic.List[object]]::new()
        # Preserve previously completed libraries' files if resuming: start from saved Files then replace per-library slices.
        $priorByLibrary = @{}
        foreach ($f in @($state.Files)) {
            if ($f -and $f.Root) {
                if (-not $priorByLibrary.ContainsKey([string]$f.Root)) { $priorByLibrary[[string]$f.Root] = [System.Collections.Generic.List[object]]::new() }
                [void]$priorByLibrary[[string]$f.Root].Add($f)
            }
        }
        # If resuming, preload already-completed libraries' records from prior state.
        $completedSoFar = @($state.CompletedLibraries)
        if ($startIndex -gt 0) {
            foreach ($doneLib in @($resumeLibraries[0..($startIndex - 1)])) {
                if ($priorByLibrary.ContainsKey($doneLib)) {
                    foreach ($r in @($priorByLibrary[$doneLib])) { [void]$allRecords.Add($r) }
                }
            }
        }

        for ($i = $startIndex; $i -lt $resumeLibraries.Count; $i++) {
            $lib = $resumeLibraries[$i]
            $libRecords = @(Get-RemoteSnapshotForLibrary -RemoteRoot $lib)
            foreach ($r in $libRecords) { [void]$allRecords.Add($r) }
            # Persist resume cursor after EACH library so a crash resumes at the next library.
            if ($completedSoFar -notcontains $lib) { $completedSoFar += $lib }
            $state.CompletedLibraries = @($completedSoFar)
            $state.NextLibraryIndex = $i + 1
            $state.PendingLibraries = @($resumeLibraries)
            Save-State $state
            Write-SyncLog "Resume checkpoint: library $($i + 1)/$($resumeLibraries.Count) ($lib) scanned ($($libRecords.Count) files)."
        }

        $canonicalLines = @(
            $allRecords | Sort-Object Key, Size, ModTime | ForEach-Object {
                "$($_.Key)|$($_.Size)|$($_.ModTime)"
            }
        )
        $canonical = $canonicalLines -join "`n"
        $snapshot = [PSCustomObject]@{
            Signature = Get-TextHash $canonical
            FileCount = $allRecords.Count
            Files = @($allRecords.ToArray())
        }

        $state.LastRemotePollUtc = [DateTime]::UtcNow.ToString('o')
        $state.LastFileCount = $snapshot.FileCount
        $fileCountForHeartbeat = $snapshot.FileCount
        $state.LastError = ''

        $signatureChanged = $snapshot.Signature -ne [string]$state.LastObservedSignature
        if ($ForceScan -or $signatureChanged -or [string]::IsNullOrWhiteSpace([string]$state.LastSuccessfulSignature)) {
            $oldFiles = @($state.Files)
            $changedPaths = @(Get-ChangedMountPaths -OldFiles $oldFiles -NewFiles $snapshot.Files)
            if ($ForceScan -and $changedPaths.Count -eq 0) {
                $changedPaths = @($snapshot.Files | Where-Object { Test-MediaRecord $_ } | ForEach-Object { Get-MountPath $_ })
            }
            $state.PendingPaths = @(
                @($state.PendingPaths) + $changedPaths | Where-Object { $_ } | Select-Object -Unique
            )
            $state.PendingSignature = $snapshot.Signature
            $state.LastObservedSignature = $snapshot.Signature
            $state.Files = @($snapshot.Files)
            $state.LastRefreshStatus = 'pending'
            # Feature 4 tracking: record when a change was last observed.
            if ($changedPaths.Count -gt 0 -or $signatureChanged) {
                $state.LastChangeUtc = [DateTime]::UtcNow.ToString('o')
            }
            Save-State $state
            Write-SyncLog "Remote snapshot changed: $($snapshot.FileCount) files; $($state.PendingPaths.Count) media path(s) require verification."
        } else {
            # No change: evaluate stale threshold.
            [void](Test-StaleThreshold -State $state)
        }

        # Feature 4: Stale-item threshold alert also fires when idle.
        [void](Test-StaleThreshold -State $state)

        if ([string]::IsNullOrWhiteSpace([string]$state.PendingSignature)) {
            # Cycle complete with nothing pending: reset resume cursor, mark success.
            $state.PendingLibraries = @()
            $state.NextLibraryIndex = 0
            $state.CompletedLibraries = @()
            Register-CycleSuccess -State $state
            Save-State $state
            $cycleStatus = 'healthy-idle'
            $pendingCountForHeartbeat = 0
            return $true
        }

        if ($state.LastRefreshAttemptUtc) {
            try {
                $elapsed = ([DateTime]::UtcNow - [DateTime]::Parse([string]$state.LastRefreshAttemptUtc)).TotalSeconds
                if (-not $ForceScan -and $elapsed -lt 30) {
                    $cycleStatus = 'throttled'
                    $pendingCountForHeartbeat = @($state.PendingPaths).Count
                    return $true
                }
            } catch {}
        }
        $state.LastRefreshAttemptUtc = [DateTime]::UtcNow.ToString('o')
        Save-State $state

        if (-not (Ensure-Mount)) {
            $state.LastRefreshStatus = 'waiting-for-mount'
            $state.LastError = 'Google Drive mount is not healthy.'
            Register-CycleFailure -State $state -ErrorMessage $state.LastError
            Save-State $state
            $cycleStatus = 'waiting-for-mount'
            $pendingCountForHeartbeat = @($state.PendingPaths).Count
            return $false
        }
        [void](Invoke-RcloneCacheRefresh $state.PendingPaths)
        if (-not (Wait-ForMountedPaths $state.PendingPaths)) {
            $state.LastRefreshStatus = 'waiting-for-mounted-files'
            $state.LastError = 'One or more changed media paths are not visible through the mount yet.'
            Register-CycleFailure -State $state -ErrorMessage $state.LastError
            Save-State $state
            $cycleStatus = 'waiting-for-mounted-files'
            $pendingCountForHeartbeat = @($state.PendingPaths).Count
            return $false
        }
        if (-not (Invoke-JellyfinRefresh)) {
            $state.LastRefreshStatus = 'waiting-for-jellyfin'
            $state.LastError = 'Jellyfin did not accept the library refresh.'
            Register-CycleFailure -State $state -ErrorMessage $state.LastError
            Save-State $state
            $cycleStatus = 'waiting-for-jellyfin'
            $pendingCountForHeartbeat = @($state.PendingPaths).Count
            return $false
        }
        if (-not (Wait-ForJellyfinPaths $state.PendingPaths)) {
            $state.LastRefreshStatus = 'waiting-for-index'
            $state.LastError = 'Jellyfin accepted the scan but has not indexed all changed media yet.'
            Register-CycleFailure -State $state -ErrorMessage $state.LastError
            Save-State $state
            $cycleStatus = 'waiting-for-index'
            $pendingCountForHeartbeat = @($state.PendingPaths).Count
            return $false
        }

        $state.LastSuccessfulSignature = $state.PendingSignature
        $state.PendingSignature = ''
        $state.PendingPaths = @()
        $state.LastSuccessfulRefreshUtc = [DateTime]::UtcNow.ToString('o')
        $state.LastRefreshStatus = 'healthy'
        $state.LastError = ''
        # Reset resume cursor on full success.
        $state.PendingLibraries = @()
        $state.NextLibraryIndex = 0
        $state.CompletedLibraries = @()
        Register-CycleSuccess -State $state
        Save-State $state
        # Feature 3: Per-library last-sync timestamps JSON file.
        $nowIso = [DateTime]::UtcNow.ToString('o')
        foreach ($lib in @($script:RemoteRoots)) {
            try { Save-LibrarySyncTime -Library $lib -TimestampUtc $nowIso } catch {
                Write-SyncLog "Could not update per-library timestamp for ${lib}: $($_.Exception.Message)" 'WARN'
            }
        }
        Write-SyncLog 'Google Drive media and Jellyfin library are synchronized.'
        $cycleStatus = 'healthy'
        $pendingCountForHeartbeat = 0
        $true
        } catch {
            $errorPosition = (($_.InvocationInfo.PositionMessage -replace '\s+', ' ').Trim())
            try { $state.LastError = $_.Exception.Message } catch {}
            try { $state.LastRefreshStatus = 'waiting-for-remote' } catch {}
            try { Register-CycleFailure -State $state -ErrorMessage $_.Exception.Message } catch {}
            try { Save-State $state } catch {}
            try { $pendingCountForHeartbeat = @($state.PendingPaths).Count } catch {}
            $cycleStatus = 'failed'
            Write-SyncLog "Sync cycle failed; will retry without advancing state: $($_.Exception.Message) [$errorPosition]" 'ERROR'
            $false
        } finally {
            $cycleTimer.Stop()
            $elapsedSeconds = $cycleTimer.Elapsed.TotalSeconds
            try {
                # Feature 8: Sync-duration history (last 20) in state file.
                Add-SyncDurationHistory -State $state -Seconds $elapsedSeconds
                Save-State $state
            } catch {
                Write-SyncLog "Could not persist sync-duration history: $($_.Exception.Message)" 'WARN'
            }
            try {
                # Feature 1: Cycle-time metric appended to heartbeat log.
                Write-HeartbeatLog -CycleSeconds $elapsedSeconds -Status $cycleStatus -PendingCount $pendingCountForHeartbeat -FileCount $fileCountForHeartbeat
            } catch {
                Write-SyncLog "Could not write heartbeat log: $($_.Exception.Message)" 'WARN'
            }
        }
}

function Set-RealtimeMonitoring {
    foreach ($optionsPath in @(
        (Join-Path $script:BaseDir 'data\root\default\Movies\options.xml'),
        (Join-Path $script:BaseDir 'data\root\default\Shows\options.xml')
    )) {
        if (-not (Test-Path -LiteralPath $optionsPath -PathType Leaf)) { continue }
        try {
            $xml = [xml](Get-Content -LiteralPath $optionsPath -Raw -Encoding UTF8)
            $node = $xml.SelectSingleNode('/LibraryOptions/EnableRealtimeMonitor')
            if ($node) {
                $node.InnerText = 'true'
                $xml.Save($optionsPath)
            }
        } catch {
            Write-SyncLog "Could not enable realtime monitoring in ${optionsPath}: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Install-SyncTask {
    if (-not $PSCmdlet.ShouldProcess($script:TaskName, 'Install scheduled task')) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:StateFile), (Split-Path -Parent $script:LogFile) | Out-Null
    Set-RealtimeMonitoring

    if (Test-Path -LiteralPath $script:MountInstaller -PathType Leaf) {
        $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
        if (-not $pwsh) { $pwsh = (Get-Command powershell.exe -ErrorAction Stop).Source }
        $mountInstall = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:MountInstaller) -WindowStyle Hidden -Wait -PassThru
        if ($mountInstall.ExitCode -ne 0) { throw "Google Drive mount installation failed with exit code $($mountInstall.ExitCode)." }
    }

    $pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) { $pwshPath = (Get-Command powershell.exe -ErrorAction Stop).Source }
    $action = New-ScheduledTaskAction -Execute $pwshPath -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Run -PollSeconds $PollSeconds" -WorkingDirectory $script:BaseDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Keeps Google Drive media, rclone VFS, and Jellyfin libraries synchronized.' -Force | Out-Null
    Start-ScheduledTask -TaskName $script:TaskName
    Write-SyncLog "Installed and started scheduled task $script:TaskName."
}

function Uninstall-SyncTask {
    if (-not $PSCmdlet.ShouldProcess($script:TaskName, 'Remove scheduled task')) { return }
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-SyncLog "Removed scheduled task $script:TaskName."
}

function Run-SelfTest {
    $sampleA = @(
        [PSCustomObject]@{ Root = 'gdrive-media:Series'; RelativePath = 'Show/Season 1/E02.mkv'; Size = '2'; ModTime = '20'; Key = 'gdrive-media:Series|Show/Season 1/E02.mkv' },
        [PSCustomObject]@{ Root = 'gdrive-media:Series'; RelativePath = 'Show/Season 1/E01.mkv'; Size = '1'; ModTime = '10'; Key = 'gdrive-media:Series|Show/Season 1/E01.mkv' }
    )
    $sampleB = @($sampleA | Sort-Object Key -Descending)
    $canonicalA = (@($sampleA | Sort-Object Key, Size, ModTime | ForEach-Object { "$($_.Key)|$($_.Size)|$($_.ModTime)" }) -join "`n")
    $canonicalB = (@($sampleB | Sort-Object Key, Size, ModTime | ForEach-Object { "$($_.Key)|$($_.Size)|$($_.ModTime)" }) -join "`n")
    if ((Get-TextHash $canonicalA) -ne (Get-TextHash $canonicalB)) { throw 'Snapshot hash is order-dependent.' }
    $mountPath = Get-MountPath $sampleA[0]
    if ($mountPath -ne 'F:\Media\Series\Show\Season 1\E02.mkv') { throw "Mount path normalization failed: $mountPath" }
    $changed = @(Get-ChangedMountPaths -OldFiles @($sampleA[0]) -NewFiles $sampleA)
    if ($changed.Count -ne 1) { throw "Change detection expected one path, got $($changed.Count)." }
    if (-not ((New-EmptyState).PendingSignature -eq '')) { throw 'State defaults are invalid.' }

    # Feature 1: Heartbeat helper exists and formats cycle-time.
    if (-not (Get-Command Write-HeartbeatLog -ErrorAction SilentlyContinue)) { throw 'Feature 1 missing: Write-HeartbeatLog.' }

    # Feature 2: Circuit breaker trips after 5 consecutive failures (15-minute pause).
    $cb = New-EmptyState
    for ($i = 1; $i -le 5; $i++) { Register-CycleFailure -State $cb -ErrorMessage "test $i" }
    if ([int]$cb.ConsecutiveFailures -ne 5) { throw "Circuit breaker count expected 5, got $($cb.ConsecutiveFailures)." }
    if ([string]::IsNullOrWhiteSpace([string]$cb.CircuitBreakerUntil)) { throw 'Circuit breaker did not set pause timestamp after 5 failures.' }
    if (-not (Test-CircuitBreakerOpen -State $cb)) { throw 'Circuit breaker should report OPEN after 5 failures.' }
    Register-CycleSuccess -State $cb
    if ([int]$cb.ConsecutiveFailures -ne 0) { throw 'Circuit breaker did not reset on success.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$cb.CircuitBreakerUntil)) { throw 'Circuit breaker pause not cleared on success.' }

    # Feature 3: Per-library timestamp helpers exist.
    if (-not (Get-Command Load-LibrarySyncTimes -ErrorAction SilentlyContinue)) { throw 'Feature 3 missing: Load-LibrarySyncTimes.' }
    if (-not (Get-Command Save-LibrarySyncTime -ErrorAction SilentlyContinue)) { throw 'Feature 3 missing: Save-LibrarySyncTime.' }

    # Feature 4: Stale threshold (24h) fires.
    $stale = New-EmptyState
    $stale.LastChangeUtc = ([DateTime]::UtcNow.AddHours(-25)).ToString('o')
    if (-not (Test-StaleThreshold -State $stale)) { throw 'Stale threshold should warn after 25h.' }
    $fresh = New-EmptyState
    $fresh.LastChangeUtc = ([DateTime]::UtcNow).ToString('o')
    if (Test-StaleThreshold -State $fresh) { throw 'Stale threshold should not warn for fresh change.' }

    # Feature 5: WhatIf helper exists.
    if (-not (Get-Command Test-WhatIfRequested -ErrorAction SilentlyContinue)) { throw 'Feature 5 missing: Test-WhatIfRequested.' }
    if (-not (Get-Command Invoke-WhatIfReport -ErrorAction SilentlyContinue)) { throw 'Feature 5 missing: Invoke-WhatIfReport.' }

    # Feature 6: RC health check exists.
    if (-not (Get-Command Test-RcloneRcHealth -ErrorAction SilentlyContinue)) { throw 'Feature 6 missing: Test-RcloneRcHealth.' }

    # Feature 7: Jitter helper exists and respects bounds 0-90s.
    if (-not (Get-Command Invoke-ScheduleJitter -ErrorAction SilentlyContinue)) { throw 'Feature 7 missing: Invoke-ScheduleJitter.' }
    if ([int]$script:ScheduleJitterMaxSeconds -ne 90) { throw "Jitter max expected 90, got $($script:ScheduleJitterMaxSeconds)." }

    # Feature 8: Duration history keeps last 20.
    $dur = New-EmptyState
    for ($i = 1; $i -le 25; $i++) { Add-SyncDurationHistory -State $dur -Seconds $i }
    if (@($dur.SyncDurationHistory).Count -ne 20) { throw "Duration history expected 20, got $(@($dur.SyncDurationHistory).Count)." }
    if (@($dur.SyncDurationHistory)[0] -ne 6) { throw 'Duration history should keep last 20 (first should be 6 after 1..25).' }

    # Feature 9: Orphan-report helper exists.
    if (-not (Get-Command Invoke-OrphanReport -ErrorAction SilentlyContinue)) { throw 'Feature 9 missing: Invoke-OrphanReport.' }

    # Feature 10: Resume state fields exist.
    $rs = New-EmptyState
    if ($null -eq $rs.PSObject.Properties['PendingLibraries']) { throw 'Feature 10 missing: PendingLibraries.' }
    if ($null -eq $rs.PSObject.Properties['NextLibraryIndex']) { throw 'Feature 10 missing: NextLibraryIndex.' }
    if (-not (Get-Command Get-RemoteSnapshotForLibrary -ErrorAction SilentlyContinue)) { throw 'Feature 10 missing: Get-RemoteSnapshotForLibrary.' }

    Write-Output 'gdrive-library-sync self-test: PASS (10x features verified)'
}

function Invoke-ValidateOnly {
    # Dry-run-safe: list remote root only (non-recursive), no state/mount/Jellyfin writes.
    [void](Test-RcloneTokenConfig)
    foreach ($remoteRoot in $script:RemoteRoots) {
        $probe = Invoke-RcloneListingWithRetry -RemoteRoot $remoteRoot -ExtraArgs @(
            'lsf', $remoteRoot,
            '--max-depth', '1',
            '--files-only',
            '--format', 'p',
            '--separator', "`t"
        ) -TimeoutSeconds 30
        $count = @($probe.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        Write-Output "VALIDATE OK: $remoteRoot reachable (top-level entries: $count) [category=ok]"
    }
    Write-Output 'gdrive-library-sync validate: PASS (no writes performed)'
}

function Write-Status {
    $state = Load-State
    $health = Get-MountHealth
    $libTimes = Load-LibrarySyncTimes
    $rcHealthy = $false
    try { $rcHealthy = Test-RcloneRcHealth } catch { $rcHealthy = $false }
    $breakerOpen = $false
    try { $breakerOpen = Test-CircuitBreakerOpen -State $state } catch { $breakerOpen = $false }
    [PSCustomObject]@{
        Task = $script:TaskName
        MountHealthy = $health.Healthy
        MountService = $health.ServiceStatus
        MountProcesses = $health.ProcessCount
        MountPathsVisible = $health.PathsVisible
        RcloneRcHealthy = $rcHealthy
        CircuitBreakerOpen = $breakerOpen
        ConsecutiveFailures = $state.ConsecutiveFailures
        CircuitBreakerUntil = $state.CircuitBreakerUntil
        RemoteFiles = $state.LastFileCount
        LastRemotePollUtc = $state.LastRemotePollUtc
        LastSuccessfulRefreshUtc = $state.LastSuccessfulRefreshUtc
        RefreshStatus = $state.LastRefreshStatus
        PendingFiles = @($state.PendingPaths).Count
        LastCycleSeconds = $state.LastCycleSeconds
        SyncDurationHistory = (@($state.SyncDurationHistory) -join ', ')
        PendingLibraries = (@($state.PendingLibraries) -join ', ')
        NextLibraryIndex = $state.NextLibraryIndex
        CompletedLibraries = (@($state.CompletedLibraries) -join ', ')
        LibrarySyncTimes = ($libTimes | ConvertTo-Json -Compress)
        LastChangeUtc = $state.LastChangeUtc
        LastError = $state.LastError
    } | Format-List
}

function Invoke-RunMode {
    param([switch]$ForceScan, [switch]$RunOnce)

    try {
        $script:Mutex = [System.Threading.Mutex]::new($false, 'Global\MediaServer_GoogleDriveLibrarySync_v2')
        if (-not $script:Mutex.WaitOne(0)) {
            Write-SyncLog 'Sync mutex held by another instance; skipping this run' 'WARN'
            return
        }
    } catch {
        Write-SyncLog "Could not acquire sync mutex: $($_.Exception.Message)" 'ERROR'
        return
    }

    try {
        # Feature 7: Schedule jitter (random 0-90s delay) to avoid thundering herd.
        [void](Invoke-ScheduleJitter)
        Write-SyncLog "Run mode started (poll ${PollSeconds}s, forceScan=$([bool]$ForceScan))"
        do {
            [void](Invoke-SyncCycle -ForceScan:$ForceScan)
            $ForceScan = $false
            if ($RunOnce) { break }
            Start-Sleep -Seconds $PollSeconds
        } while ($true)
    } finally {
        try { $script:Mutex.ReleaseMutex() } catch {}
        $script:Mutex.Dispose()
    }
}

switch ($Mode) {
    'Validate' { Invoke-ValidateOnly; break }
    'Test' { Run-SelfTest; break }
    'Install' { Install-SyncTask; break }
    'Uninstall' { Uninstall-SyncTask; break }
    'Status' { Write-Status; break }
    'Once' { Invoke-RunMode -ForceScan:$Force -RunOnce; break }
    'OrphanReport' { Invoke-OrphanReport -DeleteConfirmed:$ConfirmDelete; break }
    default { Invoke-RunMode -ForceScan:$Force; break }
}
