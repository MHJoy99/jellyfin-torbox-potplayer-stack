$launcherScript = 'F:\Jellyfin\potplayer-launcher.ps1'
$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherScript + '" "%1"'

New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Force | Out-Null
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Name '(Default)' -Value 'URL:PotPlayer Protocol'
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Name 'URL Protocol' -Value ''

New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Force | Out-Null
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Name '(Default)' -Value $cmd

Write-Host "Permanent registry handler locked in."
