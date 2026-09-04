<#
.SYNOPSIS
    Cuts a versioned release for this stack (VERSION bump, CHANGELOG scaffold, git tag, zip artifact).

.DESCRIPTION
    Reads the VERSION file at the repository root, computes the next semantic
    version, scaffolds a Keep-a-Changelog entry in CHANGELOG.md, commits the
    bump, creates an annotated git tag, pushes the commit and tag (unless
    -SkipPush is used), and builds a zip artifact of tracked files with
    git archive.

    Secrets are never read or written by this script. Only VERSION,
    CHANGELOG.md, git metadata, and the zip artifact are touched.

.PARAMETER Bump
    Which part to increment when -Version is not given: major, minor, or patch.
    Default is patch.

.PARAMETER Version
    Explicit version to release (for example 1.2.0). Must be strict semver
    major.minor.patch. When given, -Bump is ignored.

.PARAMETER ChangelogDate
    Date string inserted into the CHANGELOG entry. Defaults to today (yyyy-MM-dd).

.PARAMETER SkipPush
    Create the commit, tag, and zip locally but skip git push.

.EXAMPLE
    pwsh -File release.ps1 -Bump patch
    Bumps 1.0.0 to 1.0.1, scaffolds CHANGELOG, tags v1.0.1, pushes, and zips.

.EXAMPLE
    pwsh -File release.ps1 -Bump minor -SkipPush
    Bumps minor locally without pushing.

.EXAMPLE
    pwsh -File release.ps1 -Version 2.0.0 -WhatIf
    Shows what a 2.0.0 release would do without changing anything.

.NOTES
    Versioning follows semver (major.minor.patch). See CHANGELOG.md for the
    versioning and deprecation policies.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('major', 'minor', 'patch')]
    [string]$Bump = 'patch',

    [string]$Version = '',

    [string]$ChangelogDate = (Get-Date -Format 'yyyy-MM-dd'),

    [switch]$SkipPush,

    [string]$ArtifactDir = 'dist'
)

$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    return $PSScriptRoot
}

function Test-SemVer {
    param([string]$Text)
    return ($Text -match '^(\d+)\.(\d+)\.(\d+)$')
}

function Get-NextVersion {
    param(
        [string]$Current,
        [string]$BumpKind
    )
    $m = [regex]::Match($Current, '^(\d+)\.(\d+)\.(\d+)$')
    $major = [int]$m.Groups[1].Value
    $minor = [int]$m.Groups[2].Value
    $patch = [int]$m.Groups[3].Value
    switch ($BumpKind) {
        'major' { $major++; $minor = 0; $patch = 0 }
        'minor' { $minor++; $patch = 0 }
        default { $patch++ }
    }
    return ('{0}.{1}.{2}' -f $major, $minor, $patch)
}

function Invoke-Step {
    param(
        [string]$Label,
        [string]$CommandText,
        [scriptblock]$Action
    )
    if ($PSCmdlet.ShouldProcess($Label, $CommandText)) {
        & $Action
    }
}

$root = Get-RepoRoot
$versionFile = Join-Path $root 'VERSION'
$changelogFile = Join-Path $root 'CHANGELOG.md'

if (-not (Test-Path -LiteralPath $versionFile)) {
    throw 'VERSION file not found at repository root.'
}
if (-not (Test-Path -LiteralPath $changelogFile)) {
    throw 'CHANGELOG.md file not found at repository root.'
}

$current = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if (-not (Test-SemVer -Text $current)) {
    throw ("Current VERSION '{0}' is not strict semver major.minor.patch." -f $current)
}

if ($Version.Trim() -ne '') {
    $next = $Version.Trim()
    if (-not (Test-SemVer -Text $next)) {
        throw ("-Version '{0}' is not strict semver major.minor.patch." -f $next)
    }
}
else {
    $next = Get-NextVersion -Current $current -BumpKind $Bump
}

$tag = 'v' + $next
Write-Host ("Current: {0}  Next: {1}  Tag: {2}" -f $current, $next, $tag)

# 1. Update VERSION file.
Invoke-Step -Label $versionFile -CommandText ("Write VERSION {0}" -f $next) -Action {
    Set-Content -LiteralPath $versionFile -Value ($next + "`n") -Encoding utf8NoBOM
}

# 2. Scaffold CHANGELOG.md entry if it does not exist yet.
$changelog = Get-Content -LiteralPath $changelogFile -Raw -Encoding utf8
if ($changelog -notmatch [regex]::Escape('## [' + $next + ']')) {
    $entry = @(
        ''
        ('## [{0}] - {1}' -f $next, $ChangelogDate)
        ''
        '### Added'
        ''
        '- Highlights for this release.'
        ''
        '### Changed'
        ''
        '- Behavior changes and improvements.'
        ''
        '### Fixed'
        ''
        '- Bug fixes.'
        ''
    ) -join "`r`n"
    $anchor = '## [Unreleased]'
    Invoke-Step -Label $changelogFile -CommandText ("Insert CHANGELOG entry for {0}" -f $next) -Action {
        if ($changelog.Contains($anchor)) {
            $updated = $changelog.Replace($anchor, ($anchor + "`r`n" + $entry), [System.StringComparison]::Ordinal)
        }
        else {
            $updated = $entry + "`r`n" + $changelog
        }
        Set-Content -LiteralPath $changelogFile -Value $updated -Encoding utf8NoBOM
    }
}
else {
    Write-Host ("CHANGELOG already contains an entry for {0}; leaving it unchanged." -f $next)
}

# 3. Commit the bump.
Invoke-Step -Label 'git commit' -CommandText ("git add VERSION CHANGELOG.md and commit release {0}" -f $tag) -Action {
    & git add -- 'VERSION' 'CHANGELOG.md'
    if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }
    $status = & git status --porcelain -- 'VERSION' 'CHANGELOG.md'
    if ($status) {
        & git commit -m ("release: {0}" -f $tag)
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
    }
    else {
        Write-Host 'Nothing to commit; VERSION and CHANGELOG already match HEAD.'
    }
}

# 4. Create annotated tag if missing.
$existingTag = (& git tag --list $tag) | Select-Object -First 1
if (-not $existingTag) {
    Invoke-Step -Label 'git tag' -CommandText ("git tag -a {0}" -f $tag) -Action {
        & git tag -a $tag -m $tag
        if ($LASTEXITCODE -ne 0) { throw 'git tag failed.' }
    }
}
else {
    Write-Host ("Tag {0} already exists; leaving it unchanged." -f $tag)
}

# 5. Push commit and tag unless -SkipPush.
if ($SkipPush) {
    Write-Host 'Skipping git push because -SkipPush was given.'
}
else {
    Invoke-Step -Label 'git push' -CommandText ("git push origin HEAD and tag {0}" -f $tag) -Action {
        & git push origin HEAD
        if ($LASTEXITCODE -ne 0) { throw 'git push HEAD failed.' }
        & git push origin $tag
        if ($LASTEXITCODE -ne 0) { throw 'git push tag failed.' }
    }
}

# 6. Zip artifact of tracked files via git archive.
$artifactDirFull = Join-Path $root $ArtifactDir
$artifactName = ('stack-{0}.zip' -f $tag)
$artifactPath = Join-Path $artifactDirFull $artifactName
Invoke-Step -Label $artifactPath -CommandText ("git archive HEAD to {0}" -f $artifactName) -Action {
    if (-not (Test-Path -LiteralPath $artifactDirFull)) {
        New-Item -ItemType Directory -Path $artifactDirFull | Out-Null
    }
    & git archive --format=zip --output $artifactPath HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed.' }
    Write-Host ("Artifact: {0}" -f $artifactPath)
}

Write-Host ("Done: {0}" -f $tag)
