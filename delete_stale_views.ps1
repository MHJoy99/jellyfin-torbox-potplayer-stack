$authBody = @{ Username = 'mhjoy99'; Pw = 'Mhjoy1234*' } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="cleaner4", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri 'http://localhost:8096/Users/AuthenticateByName' -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders
$headers = @{ 'X-Emby-Token' = $authRes.AccessToken }

Write-Host "Deleting item 7f09ac8d4f2f9f306712c0d21acd9863 (Movies2)..."
try {
    Invoke-RestMethod -Uri 'http://localhost:8096/Items/7f09ac8d4f2f9f306712c0d21acd9863' -Method Delete -Headers $headers
} catch {
    Write-Host "Movies2 delete error: $_"
}

Write-Host "Deleting item 5ddaa59a73205234890fdcfc683e14ed (Series)..."
try {
    Invoke-RestMethod -Uri 'http://localhost:8096/Items/5ddaa59a73205234890fdcfc683e14ed' -Method Delete -Headers $headers
} catch {
    Write-Host "Series delete error: $_"
}

# Check user views again
$userViews = Invoke-RestMethod -Uri "http://localhost:8096/Users/$($authRes.User.Id)/Views" -Headers $headers
Write-Host "Active User Views:"
$userViews.Items | Format-Table Name, Id, CollectionType -AutoSize
