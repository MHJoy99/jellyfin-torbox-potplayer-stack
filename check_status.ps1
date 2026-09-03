$ErrorActionPreference = 'Stop'
try {
    $res = Invoke-RestMethod -Uri 'http://localhost:8096/System/Info' -Method Get -TimeoutSec 5
    Write-Host "Jellyfin Server: $($res.ServerName) (v$($res.Version))"
} catch {
    Write-Host "Jellyfin API error: $_"
}

try {
    $authBody = @{ Username = 'mhjoy99'; Pw = 'Mhjoy1234*' } | ConvertTo-Json
    $authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="test1", Version="1.0.0"' }
    $authRes = Invoke-RestMethod -Uri 'http://localhost:8096/Users/AuthenticateByName' -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders
    Write-Host "Auth success! User: $($authRes.User.Name)"
    $token = $authRes.AccessToken
    $headers = @{ 'X-Emby-Token' = $token }
    $libs = Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders' -Headers $headers
    Write-Host "Configured Libraries:"
    $libs | Format-Table Name, CollectionType, Locations -AutoSize
} catch {
    Write-Host "Auth/Library query error: $_"
}
