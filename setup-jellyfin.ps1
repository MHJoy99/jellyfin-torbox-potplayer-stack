$installer = 'F:\Jellyfin\installer\Jellyfin Server_10.11.11_Machine_X64_nullsoft_en-US.exe'
$outDir = 'F:\Jellyfin\server'
$7z = 'C:\Program Files\7-Zip\7z.exe'

Write-Host "Extracting Jellyfin Server into $outDir..."
& $7z x $installer "-o$outDir" "-xr!`$PLUGINSDIR" -y

Write-Host "Verifying files in $outDir..."
Get-ChildItem $outDir -Filter 'jellyfin*.exe' | Select-Object Name, Length
