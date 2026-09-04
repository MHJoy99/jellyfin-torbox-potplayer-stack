<#
.SYNOPSIS
    Remove extra stub libraries and report library items.
.DESCRIPTION
    Deletes Movies2/Series stubs, lists libraries and samples items. Items older
    than -OlderThanDays are highlighted. -WhatIf performs a dry-run.
.PARAMETER WhatIf
    Dry-run switch: no DELETE calls are made.
.PARAMETER OlderThanDays
    Stale threshold in days. Default 30.
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
Write-Host "Stale cutoff: $($cutoff.ToString('o')) (OlderThanDays=$OlderThanDays)"
if ($WhatIf) { Write-Host '[WhatIf] Dry-run: mutating calls will be skipped.' }

if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
    Write-Error 'Missing credentials: set JELLYFIN_USER and JELLYFIN_PASSWORD env vars.'
}

$authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="cleaner", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri "$ServerUrl/Users/AuthenticateByName" -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders -TimeoutSec 10
$headers = @{ 'X-Emby-Token' = $authRes.AccessToken }

$stubs = @('Movies2', 'Series')
foreach ($stub in $stubs) {
    if ($WhatIf) {
        Write-Host "[WhatIf] Would DELETE virtual folder '$stub' (OlderThanDays=$OlderThanDays)"
    } else {
        try {
            Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders?name=$stub" -Method Delete -Headers $headers -TimeoutSec 10 | Out-Null
            Write-Host "Deleted '$stub'."
        } catch {
            Write-Host "Delete '$stub' skipped: $($_.Exception.Message)"
        }
    }
}

$libs = Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders" -Headers $headers -TimeoutSec 10
$libs | Format-Table Name, CollectionType, Locations -AutoSize

Write-Host 'Items found in library:'
$items = Invoke-RestMethod -Uri "$ServerUrl/Items?Recursive=true&IncludeItemTypes=Movie,Episode,Series&Fields=DateCreated,Path" -Headers $headers -TimeoutSec 15
$sample = @($items.Items | Select-Object -First 10)
$sample | Format-Table Name, Type, Path -AutoSize

try {
    $stale = @($items.Items | Where-Object {
        $dc = $_.DateCreated
        if ($null -eq $dc) { return $false }
        try { ([datetime]$dc) -lt $cutoff } catch { $false }
    })
    Write-Host "Stale items older than $OlderThanDays days: $($stale.Count) (cutoff $($cutoff.ToString('yyyy-MM-dd')))"
    if ($stale.Count -gt 0) {
        $stale | Select-Object -First 10 | Format-Table Name, Type, DateCreated -AutoSize | Out-String | Write-Host
    }
} catch {
    Write-Host "Stale evaluation skipped: $($_.Exception.Message)"
}
