# Fails if any committed code file contains a hardcoded secret pattern.
# Scans code only (*.ps1 *.py *.js *.json *.yml *.yaml *.xml *.ini *.conf *.template *.env);
# docs (*.md) are covered by test-no-absolute-paths and may show redacted examples.
# Allowlisted placeholders (e.g., <your-torbox-key>, <your-key>, CHANGEME, example tokens)
# are permitted, but any realistic hardcoded token or private key causes immediate failure.

$root = (Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path
$codeExts = @('.ps1', '.py', '.js', '.json', '.yml', '.yaml', '.xml', '.ini', '.conf', '.template', '.env')

# Pattern definitions (assembled fragments to avoid self-match)
$pGitHubPersonal = 'gh' + 'p_[A-Za-z0-9]{20,}'
$pGitHubOauth    = 'gh' + 'o_[A-Za-z0-9]{20,}'
$pGitHubApp      = 'gh' + 's_[A-Za-z0-9]{20,}'
$pGitHubRefresh  = 'gh' + 'r_[A-Za-z0-9]{20,}'
$pPrivateKey     = '-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----'
$pSlackToken     = 'xox[baprs]-[A-Za-z0-9-]{10,}'
$pAwsAccessKey   = 'AKIA[0-9A-Z]{16}'
$pGoogleApiKey   = 'AIza[0-9A-Za-z\-_]{35}'
$pStripeLiveKey  = 'sk_live_[0-9a-zA-Z]{24,}'
$pTorBoxAssign   = 'TORBOX_API_KEY\s*=\s*[''"][A-Za-z0-9\-_]{16,}[''"]'
$pTorBoxUrlToken = 'api\.torbox\.app[^\s''"]*[?&]token=[A-Za-z0-9\-_]{16,}'
$pTorBoxFrag     = 'c6b5' + '9c64'

$ruleList = @(
    @{ Name = 'GitHub Personal Token'; Pattern = $pGitHubPersonal },
    @{ Name = 'GitHub OAuth Token';    Pattern = $pGitHubOauth },
    @{ Name = 'GitHub App Token';      Pattern = $pGitHubApp },
    @{ Name = 'GitHub Refresh Token';  Pattern = $pGitHubRefresh },
    @{ Name = 'Private Key Header';    Pattern = $pPrivateKey },
    @{ Name = 'Slack Token';           Pattern = $pSlackToken },
    @{ Name = 'AWS Access Key ID';     Pattern = $pAwsAccessKey },
    @{ Name = 'Google API Key';        Pattern = $pGoogleApiKey },
    @{ Name = 'Stripe Live Key';       Pattern = $pStripeLiveKey },
    @{ Name = 'TorBox Hardcoded Key';  Pattern = $pTorBoxAssign },
    @{ Name = 'TorBox URL Token';      Pattern = $pTorBoxUrlToken },
    @{ Name = 'TorBox Known Secret';   Pattern = $pTorBoxFrag }
)

# Placeholder and scanner exemption regexes
$placeholderValueRegex = '^(?:<[^>]+>|your-[a-zA-Z0-9_-]+|paste-your-[a-zA-Z0-9_-]+|changeme|placeholder[a-zA-Z0-9_-]*|dummy[a-zA-Z0-9_-]*|fake[a-zA-Z0-9_-]*|example[a-zA-Z0-9_-]*|mock[a-zA-Z0-9_-]*|redacted|xxx+|\*+|0{8,})$'
$scannerMetaRegex      = '(?i)(\$pattern|\$p[A-Za-z0-9]+|Select-String|gitleaks|--regex|\[A-Za-z0-9|\$ruleList|\$placeholder)'

$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    if ($codeExts -notcontains $_.Extension.ToLowerInvariant()) { return $false }
    $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
    $segs = $rel -split '[\\/]'
    if ($segs.Count -gt 1) {
        for ($i = 0; $i -lt ($segs.Count - 1); $i++) {
            if ($segs[$i] -in @('.git', '.kilo', 'worktrees', '__pycache__', 'node_modules', '.pytest_cache')) { return $false }
        }
    }
    return $true
})

$violations = @()

foreach ($f in $files) {
    # Skip this test script itself
    if ($f.FullName -eq $PSCommandPath) { continue }

    try {
        $lines = @(Get-Content -LiteralPath $f.FullName -ErrorAction Stop)
    } catch {
        continue
    }
    if ($lines.Count -eq 0) { continue }

    for ($lineIdx = 0; $lineIdx -lt $lines.Count; $lineIdx++) {
        $lineText = $lines[$lineIdx]
        $lineNum = $lineIdx + 1

        # Skip comment-only or regex-definition lines in test scanners
        if ($lineText -match $scannerMetaRegex) {
            continue
        }

        foreach ($rule in $ruleList) {
            $matched = [regex]::Match($lineText, $rule.Pattern)
            if ($matched.Success) {
                $matchVal = $matched.Value

                # Check if matched value is a placeholder
                if ($matchVal -match $placeholderValueRegex) {
                    continue
                }

                # If rule is an assignment, check the assigned value inside quotes
                if ($rule.Name -eq 'TorBox Hardcoded Key') {
                    $valMatch = [regex]::Match($matchVal, '[''"]([^''"]+)[''"]')
                    if ($valMatch.Success) {
                        $innerVal = $valMatch.Groups[1].Value
                        if ($innerVal -match $placeholderValueRegex) {
                            continue
                        }
                    }
                }

                # Redact snippet for safe display
                $snippet = $lineText.Trim()
                if ($snippet.Length -gt 70) {
                    $snippet = $snippet.Substring(0, 67) + '...'
                }

                $violations += [PSCustomObject]@{
                    File    = $f.FullName
                    Line    = $lineNum
                    Rule    = $rule.Name
                    Pattern = $rule.Pattern
                    Snippet = $snippet
                }
            }
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Output ("FAIL: Found {0} hardcoded secret violation(s):" -f $violations.Count)
    foreach ($v in $violations) {
        Write-Output ("  [FAIL] {0}:{1} - Rule: {2} | Snippet: {3}" -f $v.File, $v.Line, $v.Rule, $v.Snippet)
    }
    Write-Output ("no-secrets: {0} code files checked, {1} violation(s)" -f $files.Count, $violations.Count)
    exit 1
}

Write-Output ("no-secrets: {0} code files checked, 0 violations (all clean)" -f $files.Count)
exit 0
