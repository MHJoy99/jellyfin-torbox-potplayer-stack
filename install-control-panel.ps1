$ErrorActionPreference = 'Stop'

$baseDir = 'F:\Jellyfin'
$controlDir = Join-Path $baseDir 'control-panel'
$startScript = Join-Path $controlDir 'start-control-panel.vbs'
$openScript = Join-Path $controlDir 'open-control-panel.vbs'
$jellyfinExe = Join-Path $baseDir 'server\jellyfin.exe'
$taskName = 'Jellyfin Control Panel'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'

foreach($path in @($startScript, $openScript)){ if(-not (Test-Path -LiteralPath $path)){ throw "Missing panel file: $path" } }

$userId = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $wscript -Argument ('"{0}"' -f $startScript) -WorkingDirectory $controlDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Quiet local Jellyfin control panel; no console window.' -Force | Out-Null

$startMenuPrograms = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
New-Item -ItemType Directory -Force -Path $startMenuPrograms | Out-Null
$shortcutPath = Join-Path $startMenuPrograms 'Jellyfin Control Panel.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $wscript
$shortcut.Arguments = ('"{0}"' -f $openScript)
$shortcut.WorkingDirectory = $controlDir
$shortcut.IconLocation = "$jellyfinExe,0"
$shortcut.Description = 'Open the local Jellyfin Control Panel'
$shortcut.Save()

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Milliseconds 1000
$health = Invoke-RestMethod -Uri 'http://127.0.0.1:18080/health' -TimeoutSec 5
$task = Get-ScheduledTask -TaskName $taskName

[PSCustomObject]@{
    TaskName = $task.TaskName
    TaskState = $task.State
    Shortcut = $shortcutPath
    PanelHealth = ($health | ConvertTo-Json -Compress)
}
