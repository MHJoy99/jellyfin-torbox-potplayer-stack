<#
.SYNOPSIS
    Remove extra stub libraries (Movies2, Series) with dry-run and age gating.
.PARAMETER WhatIf
    Dry-run: log deletes without executing them.
.PARAMETER OlderThanDays
    Stale threshold in days. Default 30. Reported in output and used for stale summary.
.PARAMETER ServerUrl
    Defaults to $env:JELLYFIN_URL or http://localhost:8096.
.PARAMETER Username
    Defaults to $env:JELLYFIN_USER.
.PARAMETER Password
    Defaults to $env:JELLYFIN_PASSWORD.
#>
[CmdletBinding()]
param(
    [switch]$WhatIf,
    [int]$OlderThanDays = 30,
    [string]$ServerUrl = $(if ($env:JELLYFIN_URL) { $env:JELLYFIN_URL } else { 'http://localhost:8096' }),
    [string]$Username = $(if ($env:JELLYFIN_USER) { $env:JELLYFIN_USER } else { '' }),
    [string]$Password = $(if ($env:JELLYFIN_PASSWORD) { $env:JELLYFIN_PASSWORD } else { '' })
)

$ErrorActionPreference = 'Stop'
$ServerUrl = $ServerUrl.TrimEnd('/')
$cutoff = (Get-Date).AddDays(-$OlderThanDays)
Write-Host "Cutoff for stale review: $($cutoff.ToString('o')) (OlderThanDays=$OlderThanDays)"
if ($WhatIf) { Write-Host '[WhatIf] Dry-run mode active.' }

if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
    Write-Error 'Missing credentials: set JELLYFIN_USER and JELLYFIN_PASSWORD env vars.'
}

$authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="cleaner2", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri "$ServerUrl/Users/AuthenticateByName" -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders -TimeoutSec 10
$headers = @{ 'X-Emby-Token' = $authRes.AccessToken }

$libs = Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders" -Headers $headers -TimeoutSec 10
Write-Host 'Current Libraries:'
$libs | Format-Table Name, CollectionType, Locations, ItemId -AutoSize

Write-Host 'Removing Movies2 and Series...'
foreach ($name in @('Movies2', 'Series')) {
    if ($WhatIf) {
        Write-Host "[WhatIf] Would DELETE library '$name' (OlderThanDays=$OlderThanDays, cutoff $($cutoff.ToString('yyyy-MM-dd')))"
    } else {
        try {
            Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders?name=$name" -Method Delete -Headers $headers -TimeoutSec 10 | Out-Null
            Write-Host "Deleted '$name'."
        } catch {
            Write-Host "$name delete error: $($_.Exception.Message)"
        }
    }
}

$updatedLibs = Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders" -Headers $headers -TimeoutSec 10
Write-Host 'Updated Libraries:'
$updatedLibs | Format-Table Name, CollectionType, Locations, ItemId -AutoSize
