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

# Panel TorBox contract (session-safe): process + RC healthy, path informational.
# Healthy = rclone 'mount torbox' process + POST-only RC noop on :5572 proves
# the Session-1 mount is alive even when T:\ is invisible from Session 0.
# Drive-letter visibility is informational only and never a failure criterion.
$panelPy = Join-Path $root 'control-panel\control_panel.py'
if (-not (Test-Path -LiteralPath $panelPy)) { Write-Output 'SKIP: no control-panel/control_panel.py'; exit 0 }
$py = Get-Content -LiteralPath $panelPy -Raw
$required = @(
  'torboxmount',
  'mount torbox',
  'TORBOX_RC_NOOP_URL',
  'rc/noop',
  '_torbox_rc_healthy',
  '_torbox_path_visible',
  'path_visible',
  'rc_ok',
  'informational only',
  ':5572'
)
$missingContracts = @($required | Where-Object { $py -notmatch [regex]::Escape($_) })
if ($missingContracts.Count -gt 0) {
    Write-Output ("FAIL torbox contract missing: " + ($missingContracts -join ', '))
    exit 1
}
Write-Output ("panel-torbox: all {0} process+RC/path-informational contracts present" -f $required.Count)
exit 0
