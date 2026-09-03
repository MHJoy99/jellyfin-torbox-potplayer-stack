$authBody = @{ Username = 'mhjoy99'; Pw = 'Mhjoy1234*' } | ConvertTo-Json
$authHeaders = @{ 'X-Emby-Authorization' = 'MediaBrowser Client="PowerShell", Device="CLI", DeviceId="cleaner", Version="1.0.0"' }
$authRes = Invoke-RestMethod -Uri 'http://localhost:8096/Users/AuthenticateByName' -Method Post -Body $authBody -ContentType 'application/json' -Headers $authHeaders
$headers = @{ 'X-Emby-Token' = $authRes.AccessToken }

try { Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders?name=Movies2' -Method Delete -Headers $headers } catch {}
try { Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders?name=Series' -Method Delete -Headers $headers } catch {}

$libs = Invoke-RestMethod -Uri 'http://localhost:8096/Library/VirtualFolders' -Headers $headers
$libs | Format-Table Name, CollectionType, Locations -AutoSize

Write-Host "Items found in library:"
$items = Invoke-RestMethod -Uri 'http://localhost:8096/Items?Recursive=true&IncludeItemTypes=Movie,Episode,Series' -Headers $headers
$items.Items | Select-Object -First 10 | Format-Table Name, Type, Path -AutoSize
