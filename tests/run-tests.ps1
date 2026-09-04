# Test runner for jellyfin-torbox-potplayer-stack.
# Discovers tests/test-*.*, runs each, prints timing + summary.
# Exit code: 0 = all passed, 1 = any failure.
param([switch]$Verbose)

$ErrorActionPreference = 'Continue'
$testDir = $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $testDir -File | Where-Object { $_.Name -like 'test-*.*' } | Sort-Object Name)
$passed = 0
$failed = 0
$skipped = 0
$rows = @()

foreach ($f in $files) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'PASS'
    $detail = ''
    try {
        switch ($f.Extension.ToLowerInvariant()) {
            '.ps1' {
                if (Get-Command pwsh -ErrorAction SilentlyContinue) { $exe = 'pwsh' } else { $exe = 'powershell' }
                $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $f.FullName 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { $status = 'FAIL'; $detail = ($out -split "`r?`n" | Where-Object { $_ -match 'FAIL|Error' } | Select-Object -First 3) -join ' | ' }
            }
            '.py' {
                $py = Get-Command python -ErrorAction SilentlyContinue
                if (-not $py) { $status = 'SKIP'; $detail = 'no python'; break }
                $out = & python $f.FullName 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { $status = 'FAIL'; $detail = ($out -split "`r?`n" | Select-Object -Last 3) -join ' | ' }
            }
            '.js' {
                $nd = Get-Command node -ErrorAction SilentlyContinue
                if (-not $nd) { $status = 'SKIP'; $detail = 'no node'; break }
                $out = & node $f.FullName 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { $status = 'FAIL'; $detail = ($out -split "`r?`n" | Select-Object -Last 3) -join ' | ' }
            }
            default { $status = 'SKIP'; $detail = 'unknown extension' }
        }
    } catch {
        $status = 'FAIL'
        $detail = $_.Exception.Message
    }
    $sw.Stop()
    if ($status -eq 'PASS') { $passed++ } elseif ($status -eq 'FAIL') { $failed++ } else { $skipped++ }
    $rows += [PSCustomObject]@{ Test = $f.Name; Status = $status; Ms = [int]$sw.Elapsed.TotalMilliseconds; Detail = $detail }
    if ($Verbose -or $status -ne 'PASS') { Write-Output ("[{0}] {1} ({2}ms) {3}" -f $status, $f.Name, [int]$sw.Elapsed.TotalMilliseconds, $detail) }
}

Write-Output ''
Write-Output ("SUMMARY: {0} passed, {1} failed, {2} skipped ({3} total)" -f $passed, $failed, $skipped, $files.Count)
if ($failed -gt 0) { exit 1 }
exit 0
