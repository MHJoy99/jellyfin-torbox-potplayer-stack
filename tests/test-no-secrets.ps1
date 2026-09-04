# Fails if any committed code file contains a hardcoded secret pattern.
# Scans code only (*.ps1 *.py *.js *.json *.yml *.xml *.ini *.conf *.template);
# docs (*.md) are covered by test-no-absolute-paths and may show redacted examples.
$root = Split-Path $PSScriptRoot -Parent
$excludeDirs = @('.git', '.kilo', 'worktrees', '__pycache__', 'node_modules')
$codeExts = @('.ps1', '.py', '.js', '.json', '.yml', '.yaml', '.xml', '.ini', '.conf', '.template')
$torboxFrag = 'c6b5' + '9c64'  # assembled so this file does not match its own pattern
$patterns = @(
    $torboxFrag,
    'ghp_[A-Za-z0-9]{20,}',
    'gho_[A-Za-z0-9]{20,}',
    'BEGIN (RSA )?PRIVATE KEY',
    'xox[bap]-[A-Za-z0-9-]{10,}'
)
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    if ($codeExts -notcontains $_.Extension.ToLowerInvariant()) { return $false }
    $p = $_.FullName
    if ($p -like '*\.git\*' -or $p -like '*\.kilo\*' -or $p -like '*worktrees*' -or $p -like '*__pycache__*' -or $p -like '*node_modules*') { return $false }
    return $true
})
$bad = 0
foreach ($f in $files) {
    try { $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { continue }
    if ($null -eq $text) { continue }
    foreach ($p in $patterns) {
        if ($text -match $p) { $bad++; Write-Output ("FAIL {0}: matches {1}" -f $f.FullName, $p); break }
    }
}
Write-Output ("no-secrets: {0} code files checked, {1} violations" -f $files.Count, $bad)
if ($bad -gt 0) { exit 1 }
exit 0
