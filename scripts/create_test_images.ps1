$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $root 'tests\images'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

function New-Canvas {
    param([int]$Width = 1024, [int]$Height = 768)

    $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.Clear([System.Drawing.Color]::White)
    return @($bitmap, $graphics)
}

function ConvertFrom-Utf8Base64 {
    param([Parameter(Mandatory)][string]$Value)

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

# Spatial-reasoning test: four large shapes in a fixed 2x2 arrangement.
$canvas = New-Canvas
$bitmap = $canvas[0]
$graphics = $canvas[1]

$graphics.FillEllipse([System.Drawing.Brushes]::Red, 125, 95, 230, 230)
$graphics.FillRectangle([System.Drawing.Brushes]::RoyalBlue, 660, 95, 230, 230)
$graphics.FillEllipse([System.Drawing.Brushes]::Black, 750, 185, 50, 50)

$triangle = [System.Drawing.Point[]]@(
    [System.Drawing.Point]::new(240, 430),
    [System.Drawing.Point]::new(110, 680),
    [System.Drawing.Point]::new(370, 680)
)
$graphics.FillPolygon([System.Drawing.Brushes]::ForestGreen, $triangle)

$star = [System.Drawing.Point[]]::new(10)
$centerX = 775.0
$centerY = 555.0
for ($i = 0; $i -lt 10; $i++) {
    $angle = (-90 + ($i * 36)) * [Math]::PI / 180
    $radius = if (($i % 2) -eq 0) { 140.0 } else { 62.0 }
    $star[$i] = [System.Drawing.Point]::new(
        [int]($centerX + $radius * [Math]::Cos($angle)),
        [int]($centerY + $radius * [Math]::Sin($angle))
    )
}
$graphics.FillPolygon([System.Drawing.Brushes]::Gold, $star)

$shapePath = Join-Path $outputDir 'shapes_spatial.png'
$bitmap.Save($shapePath, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()

# High-contrast Korean OCR test with machine-checkable fields.
$canvas = New-Canvas
$bitmap = $canvas[0]
$graphics = $canvas[1]
$titleFont = [System.Drawing.Font]::new('Malgun Gothic', 46, [System.Drawing.FontStyle]::Bold)
$bodyFont = [System.Drawing.Font]::new('Malgun Gothic', 38, [System.Drawing.FontStyle]::Regular)
$dark = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(25, 25, 25))
$linePen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(50, 90, 150), 4)

$graphics.DrawString((ConvertFrom-Utf8Base64 '66+47JWE67mE7KCEIOyepeu5hCDsoJDqsoDtkZw='), $titleFont, $dark, 70, 55)
$graphics.DrawLine($linePen, 70, 135, 950, 135)
$lines = @(
    (ConvertFrom-Utf8Base64 '7J6l67mE66qFOiBSVFggMjA4MCBTVVBFUg=='),
    (ConvertFrom-Utf8Base64 '7KCQ6rKA7J28OiAyMDI2LTA3LTE0'),
    (ConvertFrom-Utf8Base64 '7Jio64+EOiA2M8KwQw=='),
    (ConvertFrom-Utf8Base64 '7IOB7YOcOiDsoJXsg4E='),
    (ConvertFrom-Utf8Base64 '6rSA66as67KI7Zi4OiBNVi0yMDgwUy0wNzE0')
)
$y = 175
foreach ($line in $lines) {
    $graphics.DrawString($line, $bodyFont, $dark, 80, $y)
    $y += 100
}

$ocrPath = Join-Path $outputDir 'korean_ocr.png'
$bitmap.Save($ocrPath, [System.Drawing.Imaging.ImageFormat]::Png)

$titleFont.Dispose()
$bodyFont.Dispose()
$dark.Dispose()
$linePen.Dispose()
$graphics.Dispose()
$bitmap.Dispose()

Get-Item $shapePath, $ocrPath | Select-Object Name, Length, FullName
