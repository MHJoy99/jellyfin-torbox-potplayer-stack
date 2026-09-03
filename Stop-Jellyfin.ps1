Get-Process -Name jellyfin -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host "Jellyfin Server stopped."
