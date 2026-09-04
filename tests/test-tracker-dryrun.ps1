# Tracker DryRun contract: first stdout line must be RESUME=<seconds> (launcher parses it).
$root = Split-Path $PSScriptRoot -Parent
$tracker = Join-Path $root 'potplayer-sync-tracker.ps1'
if (-not (Test-Path -LiteralPath $tracker)) { Write-Output 'SKIP: no potplayer-sync-tracker.ps1'; exit 0 }
if (Get-Command pwsh -ErrorAction SilentlyContinue) { $exe = 'pwsh' } else { $exe = 'powershell' }
$job = Start-Job -ScriptBlock {
    param($exe, $tracker)
    & $exe -NoProfile -File $tracker -MediaPath 'x' -ItemId 'citest0001' -UserId 'u' -Token 't' -ServerUrl 'http://127.0.0.1:9' -DryRun 2>&1 | Out-String
} -ArgumentList $exe, $tracker
$done = Wait-Job -Job $job -Timeout 30
$out = Receive-Job -Job $job 2>&1 | Out-String
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
$first = ($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
if ($first -notmatch '^RESUME=\d+') { Write-Output ("FAIL first line not RESUME=: '{0}'" -f $first); exit 1 }
Write-Output ("tracker-dryrun: first line '{0}'" -f $first.Trim())
exit 0
