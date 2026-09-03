$python = 'C:\Users\Administrator\AppData\Local\ZeCode\windows-mcp-venv\Scripts\python.exe'
$script = 'F:\Jellyfin\mcp-servers\rclone-storage\server.py'

$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = $python
$pinfo.Arguments = "`"$script`""
$pinfo.RedirectStandardInput = $true
$pinfo.RedirectStandardOutput = $true
$pinfo.UseShellExecute = $false

$p = [System.Diagnostics.Process]::Start($pinfo)
$p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize"}')
$initRes = $p.StandardOutput.ReadLine()
Write-Host "Init Response: $initRes"

$p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
$toolsRes = $p.StandardOutput.ReadLine()
Write-Host "Tools Response: $toolsRes"

$p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rclone_command","arguments":{"subcommand":"lsf","args":["gdrive-media:"]}}}')
$callRes = $p.StandardOutput.ReadLine()
Write-Host "Call Response: $callRes"

$p.Kill()
