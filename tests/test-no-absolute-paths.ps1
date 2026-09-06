# Keeps public docs portable: fails on machine-specific absolute paths
# in *.md outside fenced code blocks.
# Allowed (documented install roots): F:\Jellyfin*, F:\Media*, F:\TorboxMedia*,
# T:\*, G:\*, R:\*. Everything else (C:\Users\..., E:\..., other drives) must live
# inside ``` fences or be removed. Forensic incident logs are frozen history.
# Usage: pwsh -File tests/test-no-absolute-paths.ps1
# Exit 0 = no violations, 1 = violations found (prints FAIL <file>:<line>: <path>).
# Skips .git / .kilo / worktrees / node_modules; see tests/README.md "Portable-path rule".
$root = Split-Path $PSScriptRoot -Parent
$frozen = @('GLOBAL_FIX_', 'CONTROL_PANEL.md')
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object {
    $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
    if ($rel -match '^((\.git|\.kilo|node_modules|worktrees)([\\/]|$))') { return $false }
    foreach ($fr in $frozen) { if ($_.Name -like "*$fr*") { return $false } }
    return $true
})
$allowedRoots = '^(F:\\(Jellyfin|Media|TorboxMedia)?|T:\\|G:\\|R:\\)(\\|$)'
$bad = 0
foreach ($f in $files) {
    try { $lines = Get-Content -LiteralPath $f.FullName -ErrorAction Stop } catch { continue }
    $inFence = $false
    $ln = 0
    foreach ($line in $lines) {
        $ln++
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        foreach ($m in ([regex]::Matches($line, '[A-Za-z]:\\[^\s`]*'))) {
            $v = $m.Value.TrimEnd('.', ',', ')', ':', ';', '"', "'")
            if ($v -match $allowedRoots) { continue }
            $bad++
            Write-Output ("FAIL {0}:{1}: {2}" -f $f.Name, $ln, $v)
        }
    }
}
Write-Output ("no-absolute-paths: {0} md files checked, {1} violations" -f $files.Count, $bad)
if ($bad -gt 0) { exit 1 }
exit 0
