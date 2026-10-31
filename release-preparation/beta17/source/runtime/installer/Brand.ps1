# Shared look for every Smart Autodesk Connector window. Dot-source after loading WinForms.
$script:BrandName = 'Smart Autodesk Connector'
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
