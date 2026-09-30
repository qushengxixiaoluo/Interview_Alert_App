# Generate Android launcher icons from a user-provided PNG.
# Uses System.Drawing (no external dependency).
# Outputs:
#   mipmap-*/ic_launcher.png              legacy icon (Android < 8), full image
#   mipmap-*/ic_launcher_foreground.png   adaptive foreground (Android 8+), scaled into safe zone
#   mipmap-*/ic_launcher_background.png   adaptive background, average corner color

Add-Type -AssemblyName System.Drawing

$srcPath = "F:\OneDrive\桌面\icron.png"
$resDir  = "D:\PythonCode\Interview_Alert_App\interview_calendar\android\app\src\main\res"

if (-not (Test-Path $srcPath)) { Write-Error "source image not found: $srcPath"; exit 1 }
if (-not (Test-Path $resDir))  { Write-Error "res dir not found: $resDir"; exit 1 }

$src = [System.Drawing.Image]::FromFile($srcPath)
$bmpSrc = New-Object System.Drawing.Bitmap $src
$w = $bmpSrc.Width
$h = $bmpSrc.Height

$r = 0; $g = 0; $b = 0
foreach ($p in @(
    $bmpSrc.GetPixel(0, 0),
    $bmpSrc.GetPixel($w - 1, 0),
    $bmpSrc.GetPixel(0, $h - 1),
    $bmpSrc.GetPixel($w - 1, $h - 1))) {
    $r += $p.R; $g += $p.G; $b += $p.B
}
$bg = [System.Drawing.Color]::FromArgb(255, [int]($r / 4), [int]($g / 4), [int]($b / 4))
Write-Output ("source {0}x{1}, bg RGB({2},{3},{4})" -f $w, $h, $bg.R, $bg.G, $bg.B)

function New-Graphics([System.Drawing.Bitmap]$bmp) {
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gr.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $gr.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gr.CompositingMode   = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    return $gr
}

function Save-Png([System.Drawing.Bitmap]$bmp, [string]$path) {
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
}

function Make-Legacy([int]$size, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $gr = New-Graphics $bmp
    $gr.DrawImage($src, 0, 0, $size, $size)
    Save-Png $bmp $path
    $gr.Dispose(); $bmp.Dispose()
}

function Make-Foreground([int]$size, [string]$path, [double]$scale) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = New-Graphics $bmp
    $gr.Clear([System.Drawing.Color]::Transparent)
    $inner = [int]($size * $scale)
    $off   = [int](($size - $inner) / 2)
    $gr.DrawImage($src, $off, $off, $inner, $inner)
    Save-Png $bmp $path
    $gr.Dispose(); $bmp.Dispose()
}

function Make-Background([int]$size, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.Clear($bg)
    Save-Png $bmp $path
    $gr.Dispose(); $bmp.Dispose()
}

$legacy = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
$adaptive = @{ mdpi = 108; hdpi = 162; xhdpi = 216; xxhdpi = 324; xxxhdpi = 432 }

foreach ($d in $legacy.Keys) {
    $dir = Join-Path $resDir "mipmap-$d"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Make-Legacy $legacy[$d] (Join-Path $dir "ic_launcher.png")
    Write-Output ("  mipmap-$d/ic_launcher.png  {0}x{0}" -f $legacy[$d])
}

foreach ($d in $adaptive.Keys) {
    $dir = Join-Path $resDir "mipmap-$d"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Make-Foreground $adaptive[$d] (Join-Path $dir "ic_launcher_foreground.png") 0.72
    Make-Background  $adaptive[$d] (Join-Path $dir "ic_launcher_background.png")
    Write-Output ("  mipmap-$d/ic_launcher_foreground+background.png  {0}x{0}" -f $adaptive[$d])
}

$preview = "D:\PythonCode\Interview_Alert_App\icon_preview.png"
Make-Legacy 512 $preview
Write-Output "preview: $preview"

$bmpSrc.Dispose(); $src.Dispose()
Write-Output "done."
