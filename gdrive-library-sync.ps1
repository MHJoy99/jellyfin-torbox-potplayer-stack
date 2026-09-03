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
##>

[CmdletBinding()]
param(
    [ValidateSet('Run', 'Once', 'Install', 'Uninstall', 'Status', 'Test', 'Validate')]
    [string]$Mode = 'Run',
    [ValidateRange(15, 3600)]
    [int]$PollSeconds = 30,
    [switch]$Force,
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
$script:LogFile = Join-Path $script:BaseDir 'logs\gdrive-library-sync.log'
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

function Write-SyncLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')

    $parent = Split-Path -Parent $script:LogFile
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
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

function Get-RemoteSnapshot {
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($remoteRoot in $script:RemoteRoots) {
        $result = Invoke-RcloneListingWithRetry -RemoteRoot $remoteRoot -ExtraArgs @(
            'lsf', $remoteRoot,
            '--recursive',
            '--files-only',
            '--fast-list',
            '--format', 'stp',
            '--separator', "`t",
            '--time-format', 'unix'
        ) -TimeoutSeconds 90

        foreach ($line in ($result.StdOut -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t", 3
            if ($parts.Count -ne 3) {
                throw "Unexpected rclone listing format for $remoteRoot"
            }
            $relativePath = $parts[2].Trim()
            $normalizedPath = $relativePath -replace '\\', '/'
            if ([string]::IsNullOrWhiteSpace($normalizedPath) -or
                $normalizedPath.StartsWith('/') -or
                $normalizedPath -match '(^|/)\.\.(\/|$)') {
                throw "Unsafe remote path returned by rclone: $relativePath"
            }
            $records.Add([PSCustomObject]@{
                Root = $remoteRoot
                RelativePath = $normalizedPath
                Size = $parts[0].Trim()
                ModTime = $parts[1].Trim()
                Key = "$remoteRoot|$normalizedPath"
            })
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

function Invoke-SyncCycle {
    param([switch]$ForceScan)

    $state = Load-State
    try {
        $snapshot = Get-RemoteSnapshot
        $state.LastRemotePollUtc = [DateTime]::UtcNow.ToString('o')
        $state.LastFileCount = $snapshot.FileCount
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
            Save-State $state
            Write-SyncLog "Remote snapshot changed: $($snapshot.FileCount) files; $($state.PendingPaths.Count) media path(s) require verification."
        }

        if ([string]::IsNullOrWhiteSpace([string]$state.PendingSignature)) {
            Save-State $state
            return $true
        }

        if ($state.LastRefreshAttemptUtc) {
            try {
                $elapsed = ([DateTime]::UtcNow - [DateTime]::Parse([string]$state.LastRefreshAttemptUtc)).TotalSeconds
                if (-not $ForceScan -and $elapsed -lt 30) { return $true }
            } catch {}
        }
        $state.LastRefreshAttemptUtc = [DateTime]::UtcNow.ToString('o')
        Save-State $state

        if (-not (Ensure-Mount)) {
            $state.LastRefreshStatus = 'waiting-for-mount'
            $state.LastError = 'Google Drive mount is not healthy.'
            Save-State $state
            return $false
        }
        [void](Invoke-RcloneCacheRefresh $state.PendingPaths)
        if (-not (Wait-ForMountedPaths $state.PendingPaths)) {
            $state.LastRefreshStatus = 'waiting-for-mounted-files'
            $state.LastError = 'One or more changed media paths are not visible through the mount yet.'
            Save-State $state
            return $false
        }
        if (-not (Invoke-JellyfinRefresh)) {
            $state.LastRefreshStatus = 'waiting-for-jellyfin'
            $state.LastError = 'Jellyfin did not accept the library refresh.'
            Save-State $state
            return $false
        }
        if (-not (Wait-ForJellyfinPaths $state.PendingPaths)) {
            $state.LastRefreshStatus = 'waiting-for-index'
            $state.LastError = 'Jellyfin accepted the scan but has not indexed all changed media yet.'
            Save-State $state
            return $false
        }

        $state.LastSuccessfulSignature = $state.PendingSignature
        $state.PendingSignature = ''
        $state.PendingPaths = @()
        $state.LastSuccessfulRefreshUtc = [DateTime]::UtcNow.ToString('o')
        $state.LastRefreshStatus = 'healthy'
        $state.LastError = ''
        Save-State $state
        Write-SyncLog 'Google Drive media and Jellyfin library are synchronized.'
        $true
        } catch {
            $errorPosition = (($_.InvocationInfo.PositionMessage -replace '\s+', ' ').Trim())
            $state.LastError = $_.Exception.Message
            $state.LastRefreshStatus = 'waiting-for-remote'
            Save-State $state
            Write-SyncLog "Sync cycle failed; will retry without advancing state: $($_.Exception.Message) [$errorPosition]" 'ERROR'
            $false
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
    Write-Output 'gdrive-library-sync self-test: PASS'
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
    [PSCustomObject]@{
        Task = $script:TaskName
        MountHealthy = $health.Healthy
        MountService = $health.ServiceStatus
        MountProcesses = $health.ProcessCount
        MountPathsVisible = $health.PathsVisible
        RemoteFiles = $state.LastFileCount
        LastRemotePollUtc = $state.LastRemotePollUtc
        LastSuccessfulRefreshUtc = $state.LastSuccessfulRefreshUtc
        RefreshStatus = $state.LastRefreshStatus
        PendingFiles = @($state.PendingPaths).Count
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
    default { Invoke-RunMode -ForceScan:$Force; break }
}
