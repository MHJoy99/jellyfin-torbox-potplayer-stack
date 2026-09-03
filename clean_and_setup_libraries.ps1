$authBody = @{ Username = 'mhjoy99'; Pw = 'Mhjoy1234*' } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="setupScript", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri 'http://localhost:8096/Users/AuthenticateByName' -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders
$token = $authRes.AccessToken
$headers = @{ 'X-Emby-Token' = $token }

Write-Host "Cleaning up empty virtual folder definitions..."
try {
    Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders/Delete?name=Movies2' -Method Post -Headers $headers -ErrorAction SilentlyContinue
} catch {}
try {
    Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders/Delete?name=Series' -Method Post -Headers $headers -ErrorAction SilentlyContinue
} catch {}
try {
    Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders/Delete?name=Movies' -Method Post -Headers $headers -ErrorAction SilentlyContinue
} catch {}

Write-Host "Creating Movies library linked to F:\Media\Movies..."
$movieAddBody = @{
    Name = "Movies"
    PathInfo = @{
        Path = "F:\Media\Movies"
    }
} | ConvertTo-Json

Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders/Paths?collectionType=movies&refreshLibrary=true' -Method Post -Body $movieAddBody -ContentType 'application/json' -Headers $headers

Write-Host "Triggering full media scan..."
Invoke-RestMethod -Uri 'http://localhost:8096/Library/Refresh' -Method Post -Headers $headers

$updatedLibs = Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders' -Headers $headers
$updatedLibs | Format-Table Name, CollectionType, Locations -AutoSize
