<#
.SYNOPSIS
    Check Jellyfin user views with Nagios-style exit codes and optional JSON output.
.DESCRIPTION
    Authenticates with env-provided credentials, lists user views and triggers a
    library refresh. Never hardcodes secrets.
.PARAMETER AsJson
    Emit JSON instead of human-readable text.
.PARAMETER ServerUrl
    Jellyfin base URL. Defaults to $env:JELLYFIN_URL or http://localhost:8096.
.PARAMETER Username
    Defaults to $env:JELLYFIN_USER.
.PARAMETER Password
    Defaults to $env:JELLYFIN_PASSWORD.
.EXIT CODES
    0 = OK (views found), 1 = WARNING (zero views), 2 = CRITICAL (auth/query failure)
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
$userId = ''
$userName = ''

if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
    $status = 'CRITICAL'
    $exitCode = 2
    $messages.Add('Missing credentials: set JELLYFIN_USER and JELLYFIN_PASSWORD env vars.')
} else {
    try {
        $authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json
        $authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="check-user-views", Version="1.0.0"' }
        $authRes = Invoke-RestMethod -Uri "$ServerUrl/Users/AuthenticateByName" -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders -TimeoutSec 10
        $headers = @{ 'X-Emby-Token' = $authRes.AccessToken }
        $userId = [string]$authRes.User.Id
        $userName = [string]$authRes.User.Name
        $userViews = Invoke-RestMethod -Uri "$ServerUrl/Users/$userId/Views" -Headers $headers -TimeoutSec 10
        $views = @($userViews.Items | ForEach-Object {
            [PSCustomObject]@{
                Name           = [string]$_.Name
                Id             = [string]$_.Id
                CollectionType = [string]$_.CollectionType
            }
        })
        $messages.Add("User '$userName' views: $($views.Count)")
        if ($views.Count -eq 0) {
            $status = 'WARNING'
            $exitCode = 1
            $messages.Add('WARNING: user has zero views.')
        } else {
            try {
                Invoke-RestMethod -Uri "$ServerUrl/Library/Refresh" -Method Post -Headers $headers -TimeoutSec 10 | Out-Null
                $messages.Add('Library refresh triggered.')
            } catch {
                if ($exitCode -eq 0) { $exitCode = 1; $status = 'WARNING' }
                $messages.Add("Refresh trigger warning: $($_.Exception.Message)")
            }
        }
    } catch {
        $status = 'CRITICAL'
        $exitCode = 2
        $messages.Add("User views query error: $($_.Exception.Message)")
    }
}

$result = [ordered]@{
    status     = $status
    exitCode   = $exitCode
    serverUrl  = $ServerUrl
    userName   = $userName
    userId     = $userId
    viewCount  = $views.Count
    views      = $views
    messages   = @($messages)
    checkedAt  = (Get-Date).ToString('o')
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
