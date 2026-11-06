# Shared look for every Smart Connector window. Dot-source after loading WinForms.
$script:BrandName = 'Smart Connector'
$script:BrandColors = @{
    Header     = [Drawing.Color]::FromArgb(22, 36, 61)     # deep navy, matches the logo tile
    HeaderText = [Drawing.Color]::White
    HeaderSub  = [Drawing.Color]::FromArgb(160, 180, 210)
    Accent     = [Drawing.Color]::FromArgb(47, 128, 237)   # blue end of the logo gradient
    AccentDark = [Drawing.Color]::FromArgb(30, 100, 200)
    Teal       = [Drawing.Color]::FromArgb(32, 201, 171)
    Body       = [Drawing.Color]::White
    Text       = [Drawing.Color]::FromArgb(29, 35, 41)
    Muted      = [Drawing.Color]::FromArgb(95, 107, 119)
    Line       = [Drawing.Color]::FromArgb(227, 231, 236)
    Good       = [Drawing.Color]::FromArgb(31, 122, 61)
    Bad        = [Drawing.Color]::FromArgb(180, 35, 24)
}

# Captured when this file is dot-sourced; inside functions $PSScriptRoot would be the caller's folder.
$script:BrandRoot = Split-Path -Parent $PSScriptRoot

function Get-BrandAssetPath {
    param([string]$Name)
    # Layout: <root>\installer\Brand.ps1 and <root>\assets\<name>.
    $path = Join-Path $script:BrandRoot "assets\$Name"
    if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
}

function Get-BrandImage {
    param([int]$Size = 64)
    $path = Get-BrandAssetPath "logo-$Size.png"
    if (-not $path) { return $null }
    # Load through memory so the file is never kept open (updates replace the install folder).
    $bytes = [IO.File]::ReadAllBytes($path)
    [Drawing.Image]::FromStream((New-Object IO.MemoryStream(,$bytes)))
}

function Get-BrandIcon {
    $path = Get-BrandAssetPath 'logo.ico'
    if (-not $path) { return [Drawing.SystemIcons]::Application }
    New-Object Drawing.Icon((New-Object IO.MemoryStream(,[IO.File]::ReadAllBytes($path))))
}

function New-BrandFont {
    param([float]$Size = 10, [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular, [string]$Family = 'Segoe UI')
    New-Object Drawing.Font($Family, $Size, $Style)
}

function New-BrandForm {
    param([string]$Title = $script:BrandName, [int]$Width = 640, [int]$Height = 460)
    $form = New-Object Windows.Forms.Form
    $form.Text = $Title
    $form.ClientSize = New-Object Drawing.Size($Width, $Height)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.BackColor = $script:BrandColors.Body
    $form.ForeColor = $script:BrandColors.Text
    $form.Font = New-BrandFont 10
    $form.Icon = Get-BrandIcon
    $form.AutoScaleMode = 'Dpi'
    $form
}

function Add-BrandHeader {
    param([Windows.Forms.Control]$Parent, [string]$Title = $script:BrandName, [string]$Subtitle = '', [int]$Height = 88)
    $header = New-Object Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = $Height
    $header.BackColor = $script:BrandColors.Header
    $logo = New-Object Windows.Forms.PictureBox
    $logo.Image = Get-BrandImage 64
    $logo.SizeMode = 'Zoom'
    $logo.Size = New-Object Drawing.Size(52, 52)
    $logo.Location = New-Object Drawing.Point(22, [int](($Height - 52) / 2))
    $header.Controls.Add($logo)
    $titleLabel = New-Object Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = New-BrandFont 15 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'
    $titleLabel.ForeColor = $script:BrandColors.HeaderText
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object Drawing.Point(88, $(if ($Subtitle) { 18 } else { [int](($Height - 28) / 2) }))
    $header.Controls.Add($titleLabel)
    if ($Subtitle) {
        $sub = New-Object Windows.Forms.Label
        $sub.Text = $Subtitle
        $sub.ForeColor = $script:BrandColors.HeaderSub
        $sub.AutoSize = $true
        $sub.Location = New-Object Drawing.Point(90, 50)
        $header.Controls.Add($sub)
    }
    $Parent.Controls.Add($header)
    # Thin teal line under the header, echoing the logo gradient.
    $rule = New-Object Windows.Forms.Panel
    $rule.Dock = 'Top'; $rule.Height = 3; $rule.BackColor = $script:BrandColors.Teal
    $Parent.Controls.Add($rule)
    $rule.BringToFront(); $header.SendToBack()
    $header
}

function New-BrandButton {
    param([string]$Text, [switch]$Primary, [int]$Width = 120)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object Drawing.Size($Width, 36)
    $button.FlatStyle = 'Flat'
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $button.BackColor = $script:BrandColors.Accent
        $button.ForeColor = [Drawing.Color]::White
        $button.FlatAppearance.BorderColor = $script:BrandColors.Accent
        $button.FlatAppearance.MouseOverBackColor = $script:BrandColors.AccentDark
        $button.Font = New-BrandFont 10 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'
    }
    else {
        $button.BackColor = [Drawing.Color]::White
        $button.ForeColor = $script:BrandColors.Text
        $button.FlatAppearance.BorderColor = $script:BrandColors.Line
        $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(243, 246, 250)
    }
    $button
}

function New-BrandLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 0, [float]$Size = 10, [switch]$Muted, [switch]$Bold)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object Drawing.Point($X, $Y)
    $label.Font = if ($Bold) { New-BrandFont $Size ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold' } else { New-BrandFont $Size }
    $label.ForeColor = if ($Muted) { $script:BrandColors.Muted } else { $script:BrandColors.Text }
    if ($Width -gt 0) { $label.MaximumSize = New-Object Drawing.Size($Width, 0) }
    $label.AutoSize = $true
    $label
}

# ---------------------------------------------------------------------------------------------------
# Design system 1.0 (see the Smart Connector design canvas): colour tokens, the icon family and the
# shared building blocks of the setup wizard and the Smart Connector app. ASCII only: Windows
# PowerShell 5.1 reads this file without a byte-order mark.
# ---------------------------------------------------------------------------------------------------
$script:BrandColors.Canvas    = [Drawing.Color]::FromArgb(245, 247, 250)
$script:BrandColors.Navy950   = [Drawing.Color]::FromArgb(11, 20, 38)
$script:BrandColors.RailText  = [Drawing.Color]::FromArgb(184, 198, 219)
$script:BrandColors.RailMuted = [Drawing.Color]::FromArgb(142, 162, 192)
$script:BrandColors.RailLine  = [Drawing.Color]::FromArgb(74, 93, 125)
$script:BrandColors.Border    = [Drawing.Color]::FromArgb(201, 209, 219)
$script:BrandColors.Warn      = [Drawing.Color]::FromArgb(154, 78, 5)
$script:BrandColors.Link      = [Drawing.Color]::FromArgb(30, 100, 200)

# Status badge colours: background and text. Every status also carries a word, never colour alone.
$script:BrandStatus = @{
    Good = @([Drawing.Color]::FromArgb(230, 244, 234), [Drawing.Color]::FromArgb(31, 122, 61))
    Info = @([Drawing.Color]::FromArgb(232, 241, 253), [Drawing.Color]::FromArgb(30, 100, 200))
    Warn = @([Drawing.Color]::FromArgb(253, 241, 227), [Drawing.Color]::FromArgb(154, 78, 5))
    Bad  = @([Drawing.Color]::FromArgb(252, 232, 230), [Drawing.Color]::FromArgb(180, 35, 24))
    Off  = @([Drawing.Color]::FromArgb(238, 241, 244), [Drawing.Color]::FromArgb(74, 85, 97))
}

# The icon family: SVG path data on a 24-unit grid, 1.75 stroke, round caps and joins. The same strings are
# used by the Revit add-in (src\revit\addin\ConnectorUi.cs) and assets\icon-family.json for the AutoCAD PNGs.
$script:BrandIconPaths = [ordered]@{
    connector   = 'M17 7c-1.2-1.6-3-2.5-5-2.5-2.6 0-4.5 1.5-4.5 3.5 0 4.6 9 2.4 9 7.3 0 2-1.9 3.7-4.5 3.7-2 0-3.8-.9-5-2.5'
    assistant   = 'M12 3.5l1.9 4.6 4.6 1.9-4.6 1.9L12 16.5l-1.9-4.6L5.5 10l4.6-1.9zM18.5 15.5v4M16.5 17.5h4'
    claude      = 'M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8.5L6 19.5V16H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zM12 8v5M9.9 9.3l4.2 2.4M14.1 9.3l-4.2 2.4'
    codex       = 'M4.5 5h15a1.5 1.5 0 0 1 1.5 1.5v11a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5v-11A1.5 1.5 0 0 1 4.5 5zM7 10l3 2.5L7 15M12.5 15H17'
    skills      = 'M4.5 6.5l1.5 1.5 2.5-3M4.5 12.5l1.5 1.5 2.5-3M4.5 18.5l1.5 1.5 2.5-3M11 7h9M11 13h9M11 19h9'
    sync        = 'M4.5 10a7.5 7.5 0 0 1 13.4-3.6L19.5 8M19.5 4v4h-4M19.5 14a7.5 7.5 0 0 1-13.4 3.6L4.5 16M4.5 20v-4h4'
    revit       = 'M12 3l8 4.5v9L12 21l-8-4.5v-9zM4 7.5l8 4.5 8-4.5M12 12v9'
    autocad     = 'M4 20V5l15 15zM8 16h3.5L8 12.5z'
    markup      = 'M4 17c2.5-6 5.5 2 8.5-3.5S16.5 7 19.5 6'
    clear       = 'M4 11c2-4.5 4.5 1.5 7-2.5S14 5 16 4.5M14 14l6 6M20 14l-6 6'
    status      = 'M9 3v4M15 3v4M7 7h10v3.5a5 5 0 0 1-10 0zM12 15.5V21'
    updates     = 'M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14'
    settings    = 'M4 7h9M17 7h3M4 12h3M11 12h9M4 17h11M19 17h1M15 5v4M9 10v4M17 15v4'
    diagnostics = 'M3 12h4l2-5 4 10 2-5h6'
    help        = 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.6 9.4a2.5 2.5 0 1 1 3.4 2.4c-.6.3-1 .8-1 1.5v.6M12 17v.01'
    overview    = 'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z'
    components  = 'M4 7l8-4 8 4-8 4zM4 12l8 4 8-4M4 17l8 4 8-4'
    monitor     = 'M4 5h16v11H4zM9 20h6M12 16v4'
    globe       = 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.5 3.5 5.5 3.5 9s-1 6.5-3.5 9c-2.5-2.5-3.5-5.5-3.5-9s1-6.5 3.5-9z'
    check       = 'M5 12.5l4.5 4.5L19 7.5'
    warning     = 'M12 4l9 16H3zM12 10v4M12 17.5v.5'
    error       = 'M6 6l12 12M18 6L6 18'
    info        = 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v6M12 7.5v.5'
    minus       = 'M6 12h12'
    team        = 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20c.8-3.5 3.3-5.5 6.5-5.5s5.7 2 6.5 5.5M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.8c1.8.6 3 2.4 3.5 5.2'
    folder      = 'M3 6.5A1.5 1.5 0 0 1 4.5 5h4l2 2.5h9A1.5 1.5 0 0 1 21 9v9.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z'
}

$script:BrandIconCache = @{}
$script:BrandWpfLoaded = $false

# Display scale of the primary screen (1.0 at 100 %); bitmaps are drawn at device pixels so they stay sharp.
function Get-BrandScale {
    try { $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); try { [double]$g.DpiX / 96.0 } finally { $g.Dispose() } } catch { 1.0 }
}

# Renders one icon from the family with WPF (vector, any size) and returns a System.Drawing bitmap.
#   -Tile draws the navy tile with the teal-to-blue stroke used by the ribbons and the app's section headers.
function Get-BrandIconImage {
    param([Parameter(Mandatory = $true)][string]$Name, [int]$Size = 20, [Drawing.Color]$Color = [Drawing.Color]::FromArgb(22, 36, 61),
        [double]$Stroke = 0, [switch]$Tile, [double]$Scale = 0)
    if (-not $script:BrandIconPaths.Contains($Name)) { throw "Unknown icon: $Name" }
    if ($Scale -le 0) { $Scale = Get-BrandScale }
    $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f $Name, $Size, $Color.ToArgb(), $Stroke, [bool]$Tile, $Scale
    if ($script:BrandIconCache.ContainsKey($key)) { return $script:BrandIconCache[$key] }
    if (-not $script:BrandWpfLoaded) { Add-Type -AssemblyName PresentationCore, WindowsBase; $script:BrandWpfLoaded = $true }
    $px = [int][Math]::Round($Size * $Scale)
    $visual = New-Object Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    try {
        if ($Tile) {
            # 32-unit tile, glyph inset by 4 units, as in the ribbons.
            $dc.PushTransform((New-Object Windows.Media.ScaleTransform ($px / 32.0), ($px / 32.0)))
            $navy = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(22, 36, 61))
            $dc.DrawRoundedRectangle($navy, $null, (New-Object Windows.Rect 0, 0, 32, 32), 7, 7)
            $brush = New-Object Windows.Media.LinearGradientBrush ([Windows.Media.Color]::FromRgb(32, 201, 171)), ([Windows.Media.Color]::FromRgb(47, 128, 237)), 45
            $width = $(if ($Stroke -gt 0) { $Stroke } elseif ($Size -le 16) { 3.0 } else { 2.3 })
            $dc.PushTransform((New-Object Windows.Media.TranslateTransform 4, 4))
        }
        else {
            $dc.PushTransform((New-Object Windows.Media.ScaleTransform ($px / 24.0), ($px / 24.0)))
            $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb($Color.A, $Color.R, $Color.G, $Color.B))
            $width = $(if ($Stroke -gt 0) { $Stroke } elseif ($Size -le 16) { 2.2 } else { 1.75 })
            $dc.PushTransform((New-Object Windows.Media.TranslateTransform 0, 0))
        }
        $pen = New-Object Windows.Media.Pen $brush, $width
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
        $dc.DrawGeometry($null, $pen, [Windows.Media.Geometry]::Parse($script:BrandIconPaths[$Name]))
    }
    finally { $dc.Close() }
    $target = New-Object Windows.Media.Imaging.RenderTargetBitmap $px, $px, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $target.Render($visual)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($target))
    $stream = New-Object IO.MemoryStream
    $encoder.Save($stream); $stream.Position = 0
    $image = New-Object Drawing.Bitmap $stream
    $script:BrandIconCache[$key] = $image
    $image
}

# Text in pixel units, for drawing under a DPI ScaleTransform in Paint handlers.
function New-BrandPixelFont {
    param([float]$Size = 13, [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular, [string]$Family = 'Segoe UI')
    New-Object Drawing.Font($Family, $Size, $Style, [Drawing.GraphicsUnit]::Pixel)
}

function New-BrandRoundPath {
    param([float]$X, [float]$Y, [float]$Width, [float]$Height, [float]$Radius)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min(2 * $Radius, [Math]::Min($Width, $Height))
    if ($d -le 0) { $path.AddRectangle((New-Object Drawing.RectangleF $X, $Y, $Width, $Height)); return $path }
    $path.AddArc($X, $Y, $d, $d, 180, 90); $path.AddArc($X + $Width - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $Width - $d, $Y + $Height - $d, $d, $d, 0, 90); $path.AddArc($X, $Y + $Height - $d, $d, $d, 90, 90)
    $path.CloseFigure(); $path
}

# Prepares a Paint handler's Graphics: anti-aliased, scaled so drawing uses 96-DPI logical units.
function Enter-BrandPaint {
    param([Windows.Forms.PaintEventArgs]$Event)
    $g = $Event.Graphics
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'; $g.PixelOffsetMode = 'HighQuality'
    $k = [float]($g.DpiX / 96.0)
    $g.ScaleTransform($k, $k)
    $k
}

# Navy step rail on the left of the setup wizard: logo, name, the steps with done/current/next markers.
function New-BrandStepRail {
    param([string[]]$Steps, [string]$Footer = '', [int]$Width = 208)
    $rail = New-Object Windows.Forms.Panel
    $rail.Dock = 'Left'; $rail.Width = $Width; $rail.BackColor = $script:BrandColors.Header
    $rail.Tag = @{ Steps = $Steps; Current = 0; Footer = $Footer; Logo = (Get-BrandImage 64) }
    $rail.Add_Paint({
        param($sender, $e)
        $k = Enter-BrandPaint $e
        $g = $e.Graphics; $state = $sender.Tag; $C = $script:BrandColors
        if ($state.Logo) { $g.DrawImage($state.Logo, 20, 24, 36, 36) }
        $nameFont = New-BrandPixelFont 13 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'
        $g.DrawString("Smart`nConnector", $nameFont, [Drawing.Brushes]::White, 64, 26)
        $font = New-BrandPixelFont 13; $bold = New-BrandPixelFont 13 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'
        $small = New-BrandPixelFont 11 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'
        $y = 92
        for ($i = 0; $i -lt $state.Steps.Count; $i++) {
            $done = $i -lt $state.Current; $now = $i -eq $state.Current
            $circle = New-Object Drawing.RectangleF 20, $y, 22, 22
            if ($done) {
                $g.FillEllipse((New-Object Drawing.SolidBrush $C.Teal), $circle)
                $pen = New-Object Drawing.Pen $C.Navy950, 2.2; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
                $g.DrawLines($pen, [Drawing.PointF[]]@((New-Object Drawing.PointF 26, ($y + 11.5)), (New-Object Drawing.PointF 29.5, ($y + 15)), (New-Object Drawing.PointF 36, ($y + 7.5))))
                $pen.Dispose()
            }
            elseif ($now) { $g.FillEllipse((New-Object Drawing.SolidBrush $C.Accent), $circle) }
            else { $g.DrawEllipse((New-Object Drawing.Pen $C.RailLine, 2), 21, ($y + 1), 20, 20) }
            if (-not $done) {
                $format = New-Object Drawing.StringFormat; $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
                $g.DrawString([string]($i + 1), $small, [Drawing.Brushes]::White, $circle, $format)
            }
            $color = if ($now) { [Drawing.Color]::White } elseif ($done) { [Drawing.Color]::FromArgb(200, 212, 230) } else { $C.RailMuted }
            $g.DrawString($state.Steps[$i], $(if ($now) { $bold } else { $font }), (New-Object Drawing.SolidBrush $color), 52, ($y + 2))
            $y += 36
        }
        if ($state.Footer) {
            $g.DrawString($state.Footer, (New-BrandPixelFont 11), (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(169, 188, 216))), 20, ($sender.Height / $k - 30))
        }
    })
    $rail
}

function Set-BrandStepRail {
    param([Windows.Forms.Panel]$Rail, [int]$Current)
    $Rail.Tag.Current = $Current; $Rail.Invalidate()
}

# Status pill: an icon and a word on a tinted background. Kind is Good, Info, Warn, Bad or Off.
function New-BrandBadge {
    param([string]$Text, [ValidateSet('Good', 'Info', 'Warn', 'Bad', 'Off')][string]$Kind = 'Off')
    $badge = New-Object Windows.Forms.Label
    $badge.AutoSize = $false; $badge.Height = 24
    $badge.Tag = @{ Text = $Text; Kind = $Kind }
    Set-BrandBadge $badge $Text $Kind
    $badge.Add_Paint({
        param($sender, $e)
        $null = Enter-BrandPaint $e
        $g = $e.Graphics; $state = $sender.Tag; $colors = $script:BrandStatus[$state.Kind]
        $g.Clear($sender.Parent.BackColor)
        $w = [float]($sender.Width * 96.0 / $g.DpiX)
        $path = New-BrandRoundPath 0 0 ($w - 1) 23 11.5
        $g.FillPath((New-Object Drawing.SolidBrush $colors[0]), $path); $path.Dispose()
        $icon = switch ($state.Kind) { 'Good' { 'check' } 'Info' { 'updates' } 'Warn' { 'warning' } 'Bad' { 'error' } default { 'minus' } }
        $g.DrawImage((Get-BrandIconImage $icon 12 $colors[1] -Stroke 2.8), 9, 6, 12, 12)
        $g.DrawString($state.Text, (New-BrandPixelFont 12 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'), (New-Object Drawing.SolidBrush $colors[1]), 25, 4)
    })
    $badge
}

function Set-BrandBadge {
    param([Windows.Forms.Label]$Badge, [string]$Text, [string]$Kind)
    $Badge.Tag.Text = $Text; $Badge.Tag.Kind = $Kind
    $font = New-BrandPixelFont 12 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'
    $width = [Windows.Forms.TextRenderer]::MeasureText($Text, $font).Width + 38
    $Badge.Width = [int]($width * (Get-BrandScale)); $Badge.AccessibleName = $Text
    $Badge.Invalidate()
}

# White panel with a 1 px border and 8 px corners.
function New-BrandCard {
    param([int]$X = 0, [int]$Y = 0, [int]$Width = 300, [int]$Height = 120)
    $card = New-Object Windows.Forms.Panel
    $card.Location = New-Object Drawing.Point($X, $Y); $card.Size = New-Object Drawing.Size($Width, $Height)
    $card.BackColor = [Drawing.Color]::White
    $card.Add_Paint({
        param($sender, $e)
        $k = Enter-BrandPaint $e
        $path = New-BrandRoundPath 0.5 0.5 ($sender.Width / $k - 1.5) ($sender.Height / $k - 1.5) 8
        $e.Graphics.DrawPath((New-Object Drawing.Pen $script:BrandColors.Line, 1), $path); $path.Dispose()
    })
    $card
}

# An icon as a PictureBox, sized in logical pixels.
function New-BrandIconBox {
    param([string]$Name, [int]$Size = 20, [int]$X = 0, [int]$Y = 0, [Drawing.Color]$Color = [Drawing.Color]::FromArgb(22, 36, 61), [switch]$Tile)
    $box = New-Object Windows.Forms.PictureBox
    $box.Size = New-Object Drawing.Size($Size, $Size); $box.Location = New-Object Drawing.Point($X, $Y)
    $box.SizeMode = 'Zoom'; $box.BackColor = [Drawing.Color]::Transparent
    $box.Image = Get-BrandIconImage $Name $Size $Color -Tile:$Tile
    $box
}
