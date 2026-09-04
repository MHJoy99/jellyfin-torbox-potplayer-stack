# Asserts every PowerShell file in the repo parses with zero syntax errors.
$root = Split-Path $PSScriptRoot -Parent
$exclude = @('.git', '.kilo', 'worktrees', '__pycache__', 'node_modules')
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue | Where-Object {
    $full = $_.FullName
    $skip = $false
    foreach ($e in $exclude) { if ($full -like "*\$e\*") { $skip = $true; break } }
    -not $skip
})
$bad = 0
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $bad++
        Write-Output ("FAIL {0}: {1}" -f $f.FullName, $errors[0].Message)
    }
}
Write-Output ("ps-parse: {0} files checked, {1} with errors" -f $files.Count, $bad)
if ($bad -gt 0) { exit 1 }
exit 0
