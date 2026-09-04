<#
.SYNOPSIS
    Assert-based test for Daum (.dpl) playlist generation.
.DESCRIPTION
    Creates a Unicode .dpl from a sample folder (or temp fixtures when the media
    folder is absent), asserts structure/encoding, and optionally launches
    PotPlayer. Exits nonzero on any assertion failure.
.PARAMETER MediaFolder
    Folder to build the playlist from. Defaults to $env:TEST_MEDIA_FOLDER or the
    baseline sample path.
.PARAMETER SkipLaunch
    Skip launching PotPlayer (useful for CI).
.EXAMPLE
    pwsh -File test_dpl.ps1 -SkipLaunch
#>
[CmdletBinding()]
param(
    [string]$MediaFolder = $(if ($env:TEST_MEDIA_FOLDER) { $env:TEST_MEDIA_FOLDER } else { 'F:\Media\Series\The Traitor (2025)\Season 2' }),
    [switch]$SkipLaunch
)

$ErrorActionPreference = 'Continue'
$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
    } else {
        $script:failed++
        Write-Host "FAIL: $Name"
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ("$Actual" -eq "$Expected") {
        $script:passed++
        Write-Host "PASS: $Name"
    } else {
        $script:failed++
        Write-Host "FAIL: $Name (expected='$Expected', actual='$Actual')"
    }
}

# Arrange: ensure we have at least 3 files (use temp fixtures if media folder missing).
$targetFolder = $MediaFolder
$tempFixture = $false
if (-not (Test-Path -LiteralPath $targetFolder)) {
    $tempFixture = $true
    $targetFolder = Join-Path ([System.IO.Path]::GetTempPath()) 'dpl_test_fixtures'
    if (-not (Test-Path -LiteralPath $targetFolder)) { New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null }
    4..6 | ForEach-Object {
        $p = Join-Path $targetFolder ("Episode 0$_.mkv")
        if (-not (Test-Path -LiteralPath $p)) { [System.IO.File]::WriteAllText($p, "fixture $_") }
    }
    Write-Host "Media folder missing; using temp fixtures at $targetFolder"
}

$files = @(Get-ChildItem -LiteralPath $targetFolder -File | Sort-Object Name)
Assert-True ($files.Count -ge 3) "Fixture has >=3 files (found $($files.Count))"

$dplLines = @(
    'DAUMPLAYLIST'
    "playname=$($files[0].FullName)"
    'playindex=0'
    'topindex=0'
    "1*file*$($files[0].FullName)"
    '1*title*Episode 04'
    "2*file*$($files[1].FullName)"
    '2*title*Episode 05'
    "3*file*$($files[2].FullName)"
    '3*title*Episode 06'
)

$testDpl = Join-Path ([System.IO.Path]::GetTempPath()) 'test_playlist.dpl'
[System.IO.File]::WriteAllLines($testDpl, $dplLines, [System.Text.Encoding]::Unicode)
Write-Host 'Created test DPL with Unicode encoding'

# Assert: file exists, header, unicode BOM, entry count.
Assert-True (Test-Path -LiteralPath $testDpl) 'DPL file was created'
if (Test-Path -LiteralPath $testDpl) {
    $raw = [System.IO.File]::ReadAllBytes($testDpl)
    $hasBom = ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE)
    Assert-True $hasBom 'DPL is UTF-16 LE (Unicode BOM present)'
    $content = [System.IO.File]::ReadAllText($testDpl, [System.Text.Encoding]::Unicode)
    Assert-True ($content.Contains('DAUMPLAYLIST')) 'DPL header DAUMPLAYLIST present'
    Assert-True ($content.Contains('1*file*') -and $content.Contains('2*file*') -and $content.Contains('3*file*')) 'DPL has 3 file entries'
    $lines = @($content -split "`r?`n" | Where-Object { $_ -ne '' })
    Assert-Equal $lines[0] 'DAUMPLAYLIST' 'DPL first line is DAUMPLAYLIST'
}

if (-not $SkipLaunch) {
    try {
        Stop-Process -Name PotPlayerMini64 -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        $potExe = 'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe'
        if (Test-Path -LiteralPath $potExe) {
            Start-Process -FilePath $potExe -ArgumentList "`"$testDpl`""
            Start-Sleep -Seconds 2
            $running = @(Get-Process -Name PotPlayerMini64 -ErrorAction SilentlyContinue)
            Assert-True ($running.Count -gt 0) 'PotPlayer launched with test DPL'
        } else {
            Write-Host 'SKIP: PotPlayer exe not found; launch assertion skipped.'
        }
    } catch {
        $script:failed++
        Write-Host "FAIL: PotPlayer launch threw: $($_.Exception.Message)"
    }
} else {
    Write-Host 'SKIP: launch skipped via -SkipLaunch.'
}

Write-Host "---- SUMMARY: passed=$script:passed failed=$script:failed ----"
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
