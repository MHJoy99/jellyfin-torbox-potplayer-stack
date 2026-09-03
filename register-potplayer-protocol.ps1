$launcher = 'F:\Jellyfin\potplayer-launcher.ps1'
$cmdValue = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '" "%1"'

New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Force | Out-Null
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Name '(Default)' -Value 'URL:PotPlayer Protocol'
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer' -Name 'URL Protocol' -Value ''

New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Force | Out-Null
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command' -Name '(Default)' -Value $cmdValue

# Also register potplayer64
New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer64' -Force | Out-Null
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer64' -Name '(Default)' -Value 'URL:PotPlayer64 Protocol'
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer64' -Name 'URL Protocol' -Value ''
New-Item -Path 'Registry::HKEY_CLASSES_ROOT\potplayer64\shell\open\command' -Force | Out-Null
Set-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\potplayer64\shell\open\command' -Name '(Default)' -Value $cmdValue

Write-Host "PotPlayer protocol handler updated: $cmdValue (launcher $launcher)"
