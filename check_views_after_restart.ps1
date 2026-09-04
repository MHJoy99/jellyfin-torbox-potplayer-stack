<#
.SYNOPSIS
    Verify user views are present after a Jellyfin restart (Nagios-style).
.DESCRIPTION
    Lightweight post-restart probe: auth + GET /Users/{id}/Views. No refresh trigger
    (use check_user_views.ps1 for that). Never hardcodes secrets.
.PARAMETER AsJson
    Emit JSON instead of human-readable text.
.PARAMETER ServerUrl
    Jellyfin base URL. Defaults to $env:JELLYFIN_URL or http://localhost:8096.
.PARAMETER Username
    Defaults to $env:JELLYFIN_USER.
.PARAMETER Password
    Defaults to $env:JELLYFIN_PASSWORD.
.EXIT CODES
    0 = OK (views present), 1 = WARNING (zero views), 2 = CRITICAL (failure)
#>
[CmdletBinding()]
param(
    [switch]$AsJson,
    [string]$ServerUrl = $(if ($env:JELLYFIN_URL) { $env:JELLYFIN_URL } else { 'http://localhost:8096' }),
    [string]$Username = $(if ($env:JELLYFIN_USER) { $env:JELLYFIN_USER } else { '' }),
    [string]$Password = $(if ($env:JELLYFIN_PASSWORD) { $env:JELLYFIN_PASSWORD } else { '' })
)

$ErrorActionPreference = 'Stop'
$ServerUrl = $ServerUrl.TrimEnd('/')
$exitCode = 0
$status = 'OK'
$messages = [System.Collections.Generic.List[string]]::new()
$views = @()

if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
    $status = 'CRITICAL'
    $exitCode = 2
    $messages.Add('Missing credentials: set JELLYFIN_USER and JELLYFIN_PASSWORD env vars.')
} else {
    try {
        $authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json
        $authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="check-views-restart", Version="1.0.0"' }
        $authRes = Invoke-RestMethod -Uri "$ServerUrl/Users/AuthenticateByName" -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders -TimeoutSec 10
        $headers = @{ 'X-Emby-Token' = $authRes.AccessToken }
        $userViews = Invoke-RestMethod -Uri "$ServerUrl/Users/$($authRes.User.Id)/Views" -Headers $headers -TimeoutSec 10
        $views = @($userViews.Items | ForEach-Object {
            [PSCustomObject]@{
                Name           = [string]$_.Name
                Id             = [string]$_.Id
                CollectionType = [string]$_.CollectionType
            }
        })
        $messages.Add("Active User Views: $($views.Count)")
        if ($views.Count -eq 0) {
            $status = 'WARNING'
            $exitCode = 1
            $messages.Add('WARNING: no views after restart — libraries may not have reloaded yet.')
        }
    } catch {
        $status = 'CRITICAL'
        $exitCode = 2
        $messages.Add("Views-after-restart query error: $($_.Exception.Message)")
    }
}

$result = [ordered]@{
    status    = $status
    exitCode  = $exitCode
    serverUrl = $ServerUrl
    viewCount = $views.Count
    views     = $views
    messages  = @($messages)
    checkedAt = (Get-Date).ToString('o')
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} else {
    foreach ($m in $messages) { Write-Host $m }
    if ($views.Count -gt 0) {
        $views | Format-Table Name, Id, CollectionType -AutoSize | Out-String | Write-Host
    }
    Write-Host "$status (exit $exitCode)"
}

exit $exitCode
