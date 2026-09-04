# GDrive self-check: Test mode must PASS and Status must exit 0 (both read-only/safe).
$root = Split-Path $PSScriptRoot -Parent
$gdrive = Join-Path $root 'gdrive-library-sync.ps1'
if (-not (Test-Path -LiteralPath $gdrive)) { Write-Output 'SKIP: no gdrive-library-sync.ps1'; exit 0 }
if (Get-Command pwsh -ErrorAction SilentlyContinue) { $exe = 'pwsh' } else { $exe = 'powershell' }
$t = & $exe -NoProfile -ExecutionPolicy Bypass -File $gdrive -Mode Test 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $t -notmatch 'PASS') { Write-Output 'FAIL gdrive -Mode Test did not PASS'; exit 1 }
& $exe -NoProfile -ExecutionPolicy Bypass -File $gdrive -Mode Status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output 'FAIL gdrive -Mode Status exit code'; exit 1 }
Write-Output 'gdrive-modes: Test PASS + Status exit 0'
exit 0
