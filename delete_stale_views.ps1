<#
.SYNOPSIS
    Delete stale user-view items with age gating and dry-run support.
.DESCRIPTION
    Deletes known stale item IDs (Movies2, Series stubs) and prunes user views
    whose DateCreated is older than -OlderThanDays. Use -WhatIf for safe preview.
.PARAMETER WhatIf
    Dry-run switch.
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
if ($WhatIf) { Write-Host '[WhatIf] Dry-run: no items will be deleted.' }

if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
    Write-Error 'Missing credentials: set JELLYFIN_USER and JELLYFIN_PASSWORD env vars.'
}

$authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="cleaner4", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri "$ServerUrl/Users/AuthenticateByName" -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders -TimeoutSec 10
$headers = @{ 'X-Emby-Token' = $authRes.AccessToken }

function Remove-StaleItem {
    param([string]$ItemId, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($ItemId)) { return }
    if ($WhatIf) {
        Write-Host "[WhatIf] Would DELETE item $ItemId ($Label) older than $OlderThanDays days"
    } else {
        Write-Host "Deleting item $ItemId ($Label)..."
        try {
            Invoke-RestMethod -Uri "$ServerUrl/Items/$ItemId" -Method Delete -Headers $headers -TimeoutSec 10 | Out-Null
            Write-Host "Deleted $Label."
        } catch {
            Write-Host "$Label delete error: $($_.Exception.Message)"
        }
    }
}

# Known stale stub IDs from baseline (empty Movies2 / Series views).
Remove-StaleItem -ItemId '7f09ac8d4f2f9f306712c0d21acd9863' -Label 'Movies2'
Remove-StaleItem -ItemId '5ddaa59a73205234890fdcfc683e14ed' -Label 'Series'

# Generic stale-view sweep: delete views older than cutoff when DateCreated is available.
try {
    $userViews = Invoke-RestMethod -Uri "$ServerUrl/Users/$($authRes.User.Id)/Views" -Headers $headers -TimeoutSec 10
    $staleViews = @($userViews.Items | Where-Object {
        try {
            $dc = $_.DateCreated
            if ($null -eq $dc) { return $false }
            ([datetime]$dc) -lt $cutoff
        } catch { $false }
    })
    Write-Host "Views older than $OlderThanDays days: $($staleViews.Count)"
    foreach ($v in $staleViews) {
        Remove-StaleItem -ItemId ([string]$v.Id) -Label ("stale view '{0}'" -f $v.Name)
    }
    Write-Host 'Active User Views:'
    $userViews.Items | Format-Table Name, Id, CollectionType -AutoSize
} catch {
    Write-Host "User views sweep error: $($_.Exception.Message)"
}
