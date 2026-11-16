# Generates the Smart Connector logo files from one vector drawing:
#   logo-256.png, logo-64.png, logo-32.png, logo-16.png and logo.ico (16-256 px).
# Run again after changing the drawing; the outputs are committed next to this script.
param([string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Brand palette, shared with the setup windows and the Revit add-in.
$tileTop = [Drawing.Color]::FromArgb(255, 22, 36, 61)       # deep navy
$tileBottom = [Drawing.Color]::FromArgb(255, 11, 20, 38)
$accentA = [Drawing.Color]::FromArgb(255, 32, 201, 171)     # teal
$accentB = [Drawing.Color]::FromArgb(255, 47, 128, 237)     # blue

function New-RoundedRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}

function New-Logo([int]$Size) {
    $bmp = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
        $s = $Size / 256.0
        $g.ScaleTransform($s, $s)
        # Tile
        $tile = New-RoundedRect 8 8 240 240 52
        $fill = New-Object Drawing.SolidBrush $tileTop
        $g.FillPath($fill, $tile)
        # Grip S (logo option A): the S drawn as one flat teal line on a 64-unit grid inside the tile,
        # its two ends marked with blue CAD grip squares. Heavier strokes keep the small sizes sharp.
        $stroke = [float]$(if ($Size -le 24) { 34 } elseif ($Size -le 32) { 28 } else { 22.5 })
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $path.AddArc(90.5, 49.25, 75, 75, 0, -270)     # upper bowl: from the right end over the top to the centre
        $path.AddArc(90.5, 124.25, 75, 75, 270, 270)   # lower bowl: from the centre round to the left end
        $gradient = New-Object Drawing.SolidBrush $accentA
        $pen = New-Object Drawing.Pen $gradient, $stroke
        $pen.StartCap = 'Flat'; $pen.EndCap = 'Flat'; $pen.LineJoin = 'Round'
        $g.DrawPath($pen, $path)
        $grip = New-Object Drawing.SolidBrush $accentB
        $g.FillRectangle($grip, [float]148.5, [float]69.75, [float]34, [float]34)
        $g.FillRectangle($grip, [float]73.5, [float]144.75, [float]34, [float]34)
        $grip.Dispose()
        $pen.Dispose(); $gradient.Dispose(); $fill.Dispose(); $tile.Dispose(); $path.Dispose()
    }
    finally { $g.Dispose() }
    $bmp
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @{}
foreach ($size in $sizes) {
    $bmp = New-Logo $size
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $pngs[$size] = $ms.ToArray()
    if ($size -in 16, 32, 64, 256) { [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "logo-$size.png"), $pngs[$size]) }
}

# Multi-size .ico with PNG-compressed entries (supported since Windows Vista).
$ico = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $ico
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
foreach ($size in $sizes) {
    $dim = [byte]$(if ($size -ge 256) { 0 } else { $size })
    $w.Write($dim); $w.Write($dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$size].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$size].Length
}
foreach ($size in $sizes) { $w.Write($pngs[$size]) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'logo.ico'), $ico.ToArray())
$w.Dispose()
"Wrote logo-16/32/64/256.png and logo.ico to $OutputDirectory"

# AutoCAD Add-ins buttons: flat line icons from the icon family in installer\Brand.ps1, the same artwork and colours as
# the Revit ribbon (Icons.Line in ConnectorUi.cs): the accent blue for AI Markup, a grey for the rest, both with about 3:1
# contrast on AutoCAD's light and dark themes. Install-AutoCadBundle packs these PNGs into the .cuix. Run on Windows
# (WPF renders them). The file names stay as before so the panel definition keeps its references.
. (Join-Path (Split-Path -Parent $OutputDirectory) 'installer\Brand.ps1')
$accent = [Drawing.Color]::FromArgb(74, 144, 240); $grey = [Drawing.Color]::FromArgb(125, 141, 160)
$buttonIcons = [ordered]@{
    'sac-ai-markup' = @('markup', $accent); 'sac-ai-clear' = @('clear', $grey); 'sac-skills-sync' = @('sync', $grey)
    'sac-connection-status' = @('diagnostics', $grey); 'sac-check-updates' = @('updates', $grey); 'sac-settings' = @('settings', $grey)
    'sac-open-connector' = @('status', $grey)
}
foreach ($file in $buttonIcons.Keys) {
    foreach ($size in 16, 32) {
        $stroke = $(if ($size -le 16) { 2.0 } else { 1.6 })
        $image = Get-BrandIconImage $buttonIcons[$file][0] $size -Color $buttonIcons[$file][1] -Stroke $stroke -Scale 1
        $image.Save((Join-Path $OutputDirectory "$file-$size.png"), [Drawing.Imaging.ImageFormat]::Png)
    }
}
"Wrote the AutoCAD button icons ($($buttonIcons.Keys -join ', '); 16 and 32 px) to $OutputDirectory"
