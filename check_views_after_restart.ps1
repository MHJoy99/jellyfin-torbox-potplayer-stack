$authBody = @{ Username = 'mhjoy99'; Pw = 'Mhjoy1234*' } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="cleaner5", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri 'http://localhost:8096/Users/AuthenticateByName' -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders
$headers = @{ 'X-Emby-Token' = $authRes.AccessToken }

$userViews = Invoke-RestMethod -Uri "http://localhost:8096/Users/$($authRes.User.Id)/Views" -Headers $headers
Write-Host "Active User Views:"
$userViews.Items | Format-Table Name, Id, CollectionType -AutoSize
