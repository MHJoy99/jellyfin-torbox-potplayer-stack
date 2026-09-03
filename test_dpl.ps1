$targetFolder = 'F:\Media\Series\The Traitor (2025)\Season 2'
$files = Get-ChildItem -LiteralPath $targetFolder -File | Sort-Object Name

$dplLines = @(
    "DAUMPLAYLIST"
    "playname=$($files[0].FullName)"
    "playindex=0"
    "topindex=0"
    "1*file*$($files[0].FullName)"
    "1*title*Episode 04"
    "2*file*$($files[1].FullName)"
    "2*title*Episode 05"
    "3*file*$($files[2].FullName)"
    "3*title*Episode 06"
)

$testDpl = 'F:\Jellyfin\test_playlist.dpl'
[System.IO.File]::WriteAllLines($testDpl, $dplLines, [System.Text.Encoding]::Unicode)
Write-Host "Created test DPL with Unicode encoding"

Stop-Process -Name PotPlayerMini64 -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$potExe = 'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe'
Start-Process -FilePath $potExe -ArgumentList "`"$testDpl`""
Start-Sleep -Seconds 2
