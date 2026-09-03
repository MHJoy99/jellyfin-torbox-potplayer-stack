Add-Type -AssemblyName System.Drawing

$imgPath = "E:\MediaServer\jellyfin_season_view.png"
$outPath = "E:\MediaServer\jellyfin_season_marked.png"

$img = [System.Drawing.Image]::FromFile($imgPath)
$bmp = New-Object System.Drawing.Bitmap($img.Width, $img.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bmp)
$graphics.DrawImage($img, 0, 0, $img.Width, $img.Height)

$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 0, 255, 0), 4)
$brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0, 255, 0))
$font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Bold)

# 1. Main Header Button
$graphics.DrawRectangle($pen, 320, 130, 200, 50)
$graphics.DrawString("1. Main Play in PotPlayer Button", $font, $brush, 320, 100)

# 2. Episode rows
$graphics.DrawRectangle($pen, 1140, 290, 55, 55)
$graphics.DrawString("2. Ep 4 Direct PotPlayer Play", $font, $brush, 820, 305)

$graphics.DrawRectangle($pen, 1140, 440, 55, 55)
$graphics.DrawString("3. Ep 5 Direct PotPlayer Play", $font, $brush, 820, 455)

$graphics.DrawRectangle($pen, 1140, 590, 55, 55)
$graphics.DrawString("4. Ep 6 Direct PotPlayer Play", $font, $brush, 820, 605)

$graphics.Dispose()
$pen.Dispose()
$brush.Dispose()
$font.Dispose()
$img.Dispose()

$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "Annotated image saved successfully to $outPath"
