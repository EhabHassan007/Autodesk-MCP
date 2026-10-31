# Generates the Smart Autodesk Connector logo files from one vector drawing:
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
        $fill = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(0, 8)), ([Drawing.PointF]::new(0, 248)), $tileTop, $tileBottom
        $g.FillPath($fill, $tile)
        # "S" connector: two opposite arcs joining a node at top-right (Revit) and bottom-left (AutoCAD).
        $stroke = [float]$(if ($Size -le 32) { 30 } else { 24 })
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $path.AddArc(76, 52, 104, 76, 330, -240)     # upper bowl, from the top-right node round to the centre
        $path.AddArc(76, 128, 104, 76, 270, 240)     # lower bowl, from the centre round to the bottom-left node
        $gradient = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(70, 60)), ([Drawing.PointF]::new(186, 200)), $accentA, $accentB
        $pen = New-Object Drawing.Pen $gradient, $stroke
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        $g.DrawPath($pen, $path)
        # Nodes: a ring with a white core, so they read as connection points.
        $ends = @(@(173, 71, $accentA), @(83, 185, $accentB))
        foreach ($n in $ends) {
            $r = [float]$(if ($Size -le 32) { 26 } else { 22 })
            $g.FillEllipse((New-Object Drawing.SolidBrush $n[2]), [float]($n[0] - $r), [float]($n[1] - $r), 2 * $r, 2 * $r)
            if ($Size -gt 32) { $c = 10; $g.FillEllipse([Drawing.Brushes]::White, [float]($n[0] - $c), [float]($n[1] - $c), 2 * $c, 2 * $c) }
        }
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
