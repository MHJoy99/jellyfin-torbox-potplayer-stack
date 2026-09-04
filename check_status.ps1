<#
.SYNOPSIS
    Jellyfin stack status check with Nagios-style exit codes and optional JSON output.
.DESCRIPTION
    Probes Jellyfin System/Info (unauthenticated), then authenticates via env-provided
    credentials and lists virtual libraries. Never hardcodes secrets.
.PARAMETER AsJson
    Emit a single JSON object instead of human-readable text.
.PARAMETER ServerUrl
    Jellyfin base URL. Defaults to $env:JELLYFIN_URL or http://localhost:8096.
.PARAMETER Username
    Jellyfin username. Defaults to $env:JELLYFIN_USER (no hardcoded fallback).
.PARAMETER Password
    Jellyfin password. Defaults to $env:JELLYFIN_PASSWORD (no hardcoded fallback).
.EXAMPLE
    pwsh -File check_status.ps1
    pwsh -File check_status.ps1 -AsJson
.EXIT CODES
    0 = OK (server reachable, auth OK, libraries present)
    1 = WARNING (reachable but degraded: e.g. no libraries, partial failure)
    2 = CRITICAL (API down or auth/library query failed)
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
$serverName = ''
$serverVersion = ''
$libraries = @()

try {
    $res = Invoke-RestMethod -Uri "$ServerUrl/System/Info" -Method Get -TimeoutSec 5
    $serverName = [string]$res.ServerName
    $serverVersion = [string]$res.Version
    $messages.Add("Jellyfin Server: $serverName (v$serverVersion)")
} catch {
    $status = 'CRITICAL'
    $exitCode = 2
    $messages.Add("Jellyfin API error: $($_.Exception.Message)")
}

if ($exitCode -ne 2) {
    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
        $status = 'CRITICAL'
        $exitCode = 2
        $messages.Add('Missing credentials: set JELLYFIN_USER and JELLYFIN_PASSWORD env vars (never hardcode secrets).')
    } else {
        try {
            $authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json
            $authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="check-status", Version="1.0.0"' }
            $authRes = Invoke-RestMethod -Uri "$ServerUrl/Users/AuthenticateByName" -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders -TimeoutSec 10
            $messages.Add("Auth success! User: $($authRes.User.Name)")
            $token = $authRes.AccessToken
            $headers = @{ 'X-Emby-Token' = $token }
            $libs = Invoke-RestMethod -Uri "$ServerUrl/Library/VirtualFolders" -Headers $headers -TimeoutSec 10
            $libraries = @($libs | ForEach-Object {
                [PSCustomObject]@{
                    Name           = [string]$_.Name
                    CollectionType = [string]$_.CollectionType
                    Locations      = @($_.Locations)
                }
            })
            $messages.Add("Configured Libraries: $($libraries.Count)")
            if ($libraries.Count -eq 0) {
                $status = 'WARNING'
                if ($exitCode -eq 0) { $exitCode = 1 }
                $messages.Add('WARNING: no virtual libraries configured.')
            }
        } catch {
            $status = 'CRITICAL'
            $exitCode = 2
            $messages.Add("Auth/Library query error: $($_.Exception.Message)")
        }
    }
}

$result = [ordered]@{
    status        = $status
    exitCode      = $exitCode
    serverName    = $serverName
    serverVersion = $serverVersion
    serverUrl     = $ServerUrl
    libraryCount  = $libraries.Count
    libraries     = $libraries
    messages      = @($messages)
    checkedAt     = (Get-Date).ToString('o')
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} else {
    foreach ($m in $messages) { Write-Host $m }
    if ($libraries.Count -gt 0) {
        $libraries | Format-Table Name, CollectionType -AutoSize | Out-String | Write-Host
    }
    Write-Host "$status (exit $exitCode)"
}

exit $exitCode
