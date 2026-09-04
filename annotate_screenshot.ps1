<#
.SYNOPSIS
    Annotate a Jellyfin screenshot with numbered callouts.
.DESCRIPTION
    Draws fixed demo rectangles/labels over an input PNG and saves the result.
    Paths are parameterized (no hardcoded secrets; defaults preserve baseline demo).
.PARAMETER InputPath
    Source PNG. Defaults to $env:ANNOTATE_INPUT or E:\MediaServer\jellyfin_season_view.png.
.PARAMETER OutputPath
    Destination PNG. Defaults to $env:ANNOTATE_OUTPUT or E:\MediaServer\jellyfin_season_marked.png.
.EXAMPLE
    pwsh -File annotate_screenshot.ps1
    pwsh -File annotate_screenshot.ps1 -InputPath ./in.png -OutputPath ./out.png
#>
[CmdletBinding()]
param(
    [string]$InputPath = $(if ($env:ANNOTATE_INPUT) { $env:ANNOTATE_INPUT } else { 'E:\MediaServer\jellyfin_season_view.png' }),
    [string]$OutputPath = $(if ($env:ANNOTATE_OUTPUT) { $env:ANNOTATE_OUTPUT } else { 'E:\MediaServer\jellyfin_season_marked.png' })
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $InputPath)) {
    Write-Error "Input image not found: $InputPath"
}

$img = [System.Drawing.Image]::FromFile($InputPath)
try {
    $bmp = New-Object System.Drawing.Bitmap($img.Width, $img.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $graphics.DrawImage($img, 0, 0, $img.Width, $img.Height)

        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 0, 255, 0), 4)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0, 255, 0))
        $font = New-Object System.Drawing.Font('Arial', 14, [System.Drawing.FontStyle]::Bold)
        try {
            # 1. Main Header Button
            $graphics.DrawRectangle($pen, 320, 130, 200, 50)
            $graphics.DrawString('1. Main Play in PotPlayer Button', $font, $brush, 320, 100)

            # 2. Episode rows
            $graphics.DrawRectangle($pen, 1140, 290, 55, 55)
            $graphics.DrawString('2. Ep 4 Direct PotPlayer Play', $font, $brush, 820, 305)

            $graphics.DrawRectangle($pen, 1140, 440, 55, 55)
            $graphics.DrawString('3. Ep 5 Direct PotPlayer Play', $font, $brush, 820, 455)

            $graphics.DrawRectangle($pen, 1140, 590, 55, 55)
            $graphics.DrawString('4. Ep 6 Direct PotPlayer Play', $font, $brush, 820, 605)
        } finally {
            $pen.Dispose()
            $brush.Dispose()
            $font.Dispose()
        }
    } finally {
        $graphics.Dispose()
    }
    $img.Dispose()

    $bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Annotated image saved successfully to $OutputPath"
} catch {
    try { $img.Dispose() } catch {}
    throw
}
