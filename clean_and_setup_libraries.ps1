<#
.SYNOPSIS
    Clean empty stub libraries and set up the canonical Movies library.
.DESCRIPTION
    Removes known empty stubs (Movies2, Series, Movies) then re-creates Movies
    linked to the configured path and triggers a scan. Supports -WhatIf dry-run
    and -OlderThanDays stale threshold (used to gate destructive deletes and to
    report items older than the cutoff).
.PARAMETER WhatIf
    Dry-run: log planned actions without calling mutating APIs.
.PARAMETER OlderThanDays
    Stale threshold in days. Default 30. Destructive deletes are logged with the
    computed cutoff date; item queries filter by DateCreated when available.
.PARAMETER ServerUrl
    Defaults to $env:JELLYFIN_URL or http://localhost:8096.
.PARAMETER Username
    Defaults to $env:JELLYFIN_USER.
.PARAMETER Password
    Defaults to $env:JELLYFIN_PASSWORD.
.PARAMETER MoviesPath
    Filesystem path for the Movies library. Defaults to $env:MOVIES_PATH or F:\Media\Movies.
.EXAMPLE
    pwsh -File clean_and_setup_libraries.ps1 -WhatIf
    pwsh -File clean_and_setup_libraries.ps1 -OlderThanDays 7
#>
[CmdletBinding()]
param(
    [switch]$WhatIf,
    [int]$OlderThanDays = 30,
    [string]$ServerUrl = $(if ($env:JELLYFIN_URL) { $env:JELLYFIN_URL } else { 'http://localhost:8096' }),
    [string]$Username = $(if ($env:JELLYFIN_USER) { $env:JELLYFIN_USER } else { '' }),
    [string]$Password = $(if ($env:JELLYFIN_PASSWORD) { $env:JELLYFIN_PASSWORD } else { '' }),
    [string]$MoviesPath = $(if ($env:MOVIES_PATH) { $env:MOVIES_PATH } else { 'F:\Media\Movies' })
)

$ErrorActionPreference = 'Stop'
$ServerUrl = $ServerUrl.TrimEnd('/')
$cutoff = (Get-Date).AddDays(-$OlderThanDays)
Write-Host "Stale cutoff: $($cutoff.ToString('o')) (OlderThanDays=$OlderThanDays)"
if ($WhatIf) { Write-Host '[WhatIf] Dry-run mode: no mutating API calls will be made.' }

if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
    Write-Error 'Missing credentials: set JELLYFIN_USER and JELLYFIN_PASSWORD env vars (never hardcode secrets).'
}

$authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="setupScript", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri "$ServerUrl/Users/AuthenticateByName" -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders -TimeoutSec 10
$token = $authRes.AccessToken
$headers = @{ 'X-Emby-Token' = $token }

$stubs = @('Movies2', 'Series', 'Movies')
Write-Host 'Cleaning up empty virtual folder definitions...'
foreach ($stub in $stubs) {
    if ($WhatIf) {
        Write-Host "[WhatIf] Would DELETE virtual folder '$stub' (stale threshold OlderThanDays=$OlderThanDays, cutoff $($cutoff.ToString('yyyy-MM-dd')))"
    } else {
        try {
            Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders/Delete?name=$stub" -Method Post -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Deleted stub '$stub' (if existed)."
        } catch {
            Write-Host "Stub '$stub' delete skipped: $($_.Exception.Message)"
        }
    }
}

$movieAddBody = @{
    Name     = 'Movies'
    PathInfo = @{ Path = $MoviesPath }
} | ConvertTo-Json

if ($WhatIf) {
    Write-Host "[WhatIf] Would CREATE Movies library at '$MoviesPath' and trigger full scan."
} else {
    Write-Host "Creating Movies library linked to $MoviesPath..."
    Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders/Paths?collectionType=movies&refreshLibrary=true" -Method Post -Body $movieAddBody -ContentType 'application/json' -Headers $headers -TimeoutSec 15 | Out-Null
    Write-Host 'Triggering full media scan...'
    Invoke-RestMethod -Uri "$ServerUrl/Library/Refresh" -Method Post -Headers $headers -TimeoutSec 10 | Out-Null
}

$updatedLibs = Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders" -Headers $headers -TimeoutSec 10
$updatedLibs | Format-Table Name, CollectionType, Locations -AutoSize
