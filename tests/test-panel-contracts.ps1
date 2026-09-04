# Panel contract: every DOM id referenced by control-panel/app.js must exist in control-panel/index.html.
$root = Split-Path $PSScriptRoot -Parent
$htmlPath = Join-Path $root 'control-panel\index.html'
$jsPath = Join-Path $root 'control-panel\app.js'
if (-not (Test-Path -LiteralPath $htmlPath)) { Write-Output 'SKIP: no control-panel/index.html'; exit 0 }
if (-not (Test-Path -LiteralPath $jsPath)) { Write-Output 'SKIP: no control-panel/app.js'; exit 0 }
$html = Get-Content -LiteralPath $htmlPath -Raw
$js = Get-Content -LiteralPath $jsPath -Raw
$defined = @{}
foreach ($m in [regex]::Matches($html, 'id\s*=\s*["'']([^"'']+)["'']')) { $defined[$m.Groups[1].Value] = $true }
$referenced = @()
foreach ($m in [regex]::Matches($js, 'getElementById\(\s*["'']([^"'']+)["'']\s*\)')) { $referenced += $m.Groups[1].Value }
foreach ($m in [regex]::Matches($js, 'querySelector(All)?\(\s*["'']#([^"'']+)["'']')) { $referenced += $m.Groups[2].Value }
$missing = @($referenced | Sort-Object -Unique | Where-Object { -not $defined.ContainsKey($_) })
if ($missing.Count -gt 0) {
    Write-Output ("FAIL missing ids: " + ($missing -join ', '))
    exit 1
}
Write-Output ("panel-contracts: {0} ids referenced, all defined" -f @($referenced | Sort-Object -Unique).Count)
exit 0
