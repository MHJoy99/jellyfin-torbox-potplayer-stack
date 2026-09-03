$authBody = @{ Username = 'mhjoy99'; Pw = 'Mhjoy1234*' } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="cleaner2", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri 'http://localhost:8096/Users/AuthenticateByName' -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders
$headers = @{ 'X-Emby-Token' = $authRes.AccessToken }

$libs = Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders' -Headers $headers
Write-Host "Current Libraries:"
$libs | Format-Table Name, CollectionType, Locations, ItemId -AutoSize

# Remove Movies2 and Series (the empty stubs)
Write-Host "Removing Movies2 and Series..."
try {
    Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders?name=Movies2' -Method Delete -Headers $headers
} catch {
    Write-Host "Movies2 delete error: $_"
}

try {
    Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders?name=Series' -Method Delete -Headers $headers
} catch {
    Write-Host "Series delete error: $_"
}

$updatedLibs = Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders' -Headers $headers
Write-Host "Updated Libraries:"
$updatedLibs | Format-Table Name, CollectionType, Locations, ItemId -AutoSize
