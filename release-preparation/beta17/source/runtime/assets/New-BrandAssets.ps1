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

# AutoCAD Add-ins buttons: the same glyphs as the Revit ribbon icons (src\revit\addin\ConnectorUi.cs Icons),
# drawn in a 32-unit space on the navy tile. Install-AutoCadBundle packs them into the .cuix.
function Add-ArcPoints($Path, [float]$X1, [float]$Y1, [float]$X2, [float]$Y2, [float]$Rx, [float]$Ry, [bool]$Large, [bool]$Clockwise) {
    # WPF ArcTo / SVG endpoint arc (no rotation) converted to its centre form, then added as a polyline.
    $xp = ($X1 - $X2) / 2; $yp = ($Y1 - $Y2) / 2
    $l = ($xp * $xp) / ($Rx * $Rx) + ($yp * $yp) / ($Ry * $Ry)
    if ($l -gt 1) { $Rx *= [Math]::Sqrt($l); $Ry *= [Math]::Sqrt($l) }
    $num = $Rx * $Rx * $Ry * $Ry - $Rx * $Rx * $yp * $yp - $Ry * $Ry * $xp * $xp
    $den = $Rx * $Rx * $yp * $yp + $Ry * $Ry * $xp * $xp
    $coef = [Math]::Sqrt([Math]::Max(0, $num / $den)) * $(if ($Large -ne $Clockwise) { 1 } else { -1 })
    $cxp = $coef * $Rx * $yp / $Ry; $cyp = -$coef * $Ry * $xp / $Rx
    $cx = $cxp + ($X1 + $X2) / 2; $cy = $cyp + ($Y1 + $Y2) / 2
    $t1 = [Math]::Atan2(($yp - $cyp) / $Ry, ($xp - $cxp) / $Rx)
    $dt = [Math]::Atan2((-$yp - $cyp) / $Ry, (-$xp - $cxp) / $Rx) - $t1
    if ($Clockwise -and $dt -lt 0) { $dt += 2 * [Math]::PI }
    if (-not $Clockwise -and $dt -gt 0) { $dt -= 2 * [Math]::PI }
    $points = foreach ($i in 0..32) { $t = $t1 + $dt * $i / 32; [Drawing.PointF]::new($cx + $Rx * [Math]::Cos($t), $cy + $Ry * [Math]::Sin($t)) }
    $Path.AddLines([Drawing.PointF[]]$points)
}

function New-ButtonIcon([int]$Size, [scriptblock]$Glyph) {
    $bmp = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
        $g.ScaleTransform($Size / 32.0, $Size / 32.0)
        $tile = New-RoundedRect 0 0 32 32 7
        $g.FillPath((New-Object Drawing.SolidBrush $tileTop), $tile)
        # 45-degree teal-to-blue gradient; a thicker stroke keeps the 16 px icons readable.
        $gradient = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(0, 0)), ([Drawing.PointF]::new(32, 32)), $accentA, $accentB
        $pen = New-Object Drawing.Pen $gradient, ([float]$(if ($Size -le 16) { 3.6 } else { 2.8 }))
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        & $Glyph $g $pen
        $pen.Dispose(); $gradient.Dispose(); $tile.Dispose()
    }
    finally { $g.Dispose() }
    $bmp
}

$buttonGlyphs = [ordered]@{
    'sac-connection-status' = {
        param($g, $pen)
        # The logo's "S" connector with its two nodes.
        $s = New-Object Drawing.Drawing2D.GraphicsPath
        Add-ArcPoints $s 21.5 9 16 16 6 4.5 $true $false
        Add-ArcPoints $s 16 16 10.5 23 6 4.5 $true $true
        $g.DrawPath($pen, $s); $s.Dispose()
        $g.FillEllipse((New-Object Drawing.SolidBrush $accentA), 19.5, 6, 6, 6)
        $g.FillEllipse((New-Object Drawing.SolidBrush $accentB), 6.5, 20, 6, 6)
    }
    'sac-check-updates' = {
        param($g, $pen)
        $g.DrawLine($pen, 16, 7.5, 16, 19)
        $g.DrawLine($pen, 11, 14.5, 16, 19.5)
        $g.DrawLine($pen, 21, 14.5, 16, 19.5)
        $g.DrawLine($pen, 9.5, 24.5, 22.5, 24.5)
    }
    'sac-skills-sync' = {
        param($g, $pen)
        # Two arcs with arrow heads: upload saved skills, download approved ones.
        $s = New-Object Drawing.Drawing2D.GraphicsPath
        Add-ArcPoints $s 8.5 14 22.5 11 7.5 7.5 $false $true
        $s.StartFigure()
        Add-ArcPoints $s 23.5 18 9.5 21 7.5 7.5 $false $true
        $g.DrawPath($pen, $s); $s.Dispose()
        $g.DrawLine($pen, 22.5, 11, 23, 6.5); $g.DrawLine($pen, 22.5, 11, 18, 10.5)
        $g.DrawLine($pen, 9.5, 21, 9, 25.5); $g.DrawLine($pen, 9.5, 21, 14, 21.5)
    }
    'sac-ai-markup' = {
        param($g, $pen)
        # A freehand stroke ending at a white pen tip: sketch the task on the drawing.
        $g.DrawBezier($pen, 7, 22, 12, 8, 18, 26, 25, 10)
        $g.FillEllipse([Drawing.Brushes]::White, 22.4, 7.4, 5.2, 5.2)
    }
    'sac-ai-clear' = {
        param($g, $pen)
        # A short sketch stroke and a white cross: remove the markup.
        $g.DrawBezier($pen, 6, 14, 10, 6, 14, 20, 18, 11)
        $white = New-Object Drawing.Pen ([Drawing.Color]::White), $pen.Width
        $white.StartCap = 'Round'; $white.EndCap = 'Round'
        $g.DrawLine($white, 19, 19, 25, 25); $g.DrawLine($white, 25, 19, 19, 25)
        $white.Dispose()
    }
    'sac-settings' = {
        param($g, $pen)
        # Slider-style settings mark: three lines with knobs.
        foreach ($y in 10, 16, 22) { $g.DrawLine($pen, 8, $y, 24, $y) }
        foreach ($knob in @(@(19, 10), @(12, 16), @(17, 22))) { $g.FillEllipse([Drawing.Brushes]::White, [float]($knob[0] - 2.6), [float]($knob[1] - 2.6), 5.2, 5.2) }
    }
}
foreach ($name in $buttonGlyphs.Keys) {
    foreach ($size in 16, 32) {
        $bmp = New-ButtonIcon $size $buttonGlyphs[$name]
        $bmp.Save((Join-Path $OutputDirectory "$name-$size.png"), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    }
}
"Wrote the AutoCAD button icons ($($buttonGlyphs.Keys -join ', '); 16 and 32 px) to $OutputDirectory"
