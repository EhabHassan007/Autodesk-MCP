$ErrorActionPreference = 'Stop'
# Design system (installer\Brand.ps1): every icon renders through WPF, plain and as a tile; the step rail,
# badges and cards paint without errors at 100 % and 150 % scale. Windows only (WinForms and WPF).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
. (Join-Path $PSScriptRoot '../source/runtime/installer/Brand.ps1')
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-InkCount([Drawing.Bitmap]$Bitmap) {
    $count = 0
    for ($x = 0; $x -lt $Bitmap.Width; $x++) { for ($y = 0; $y -lt $Bitmap.Height; $y++) { if ($Bitmap.GetPixel($x, $y).A -gt 40) { $count++ } } }
    $count
}

foreach ($name in $script:BrandIconPaths.Keys) {
    foreach ($scale in 1.0, 1.5) {
        $plain = Get-BrandIconImage $name 24 -Scale $scale
        Assert ($plain.Width -eq [int][Math]::Round(24 * $scale)) "Icon $name has the wrong size at $scale"
        Assert ((Get-InkCount $plain) -gt 8) "Icon $name drew nothing at $scale"
        $tile = Get-BrandIconImage $name 32 -Tile -Scale $scale
        Assert ((Get-InkCount $tile) -gt ($tile.Width * $tile.Height * 0.6)) "Tile $name is not filled at $scale"
    }
}
'PASS: {0} icons render plain and as tiles at 100 % and 150 %' -f $script:BrandIconPaths.Count

# The Revit add-in draws the same family; its copy of the path data must not drift.
$cs = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../source/runtime/src/revit/addin/ConnectorUi.cs') -Raw
foreach ($name in 'connector', 'sync', 'skills', 'status', 'updates', 'settings', 'diagnostics', 'help') {
    Assert ($cs.Contains('"' + $script:BrandIconPaths[$name] + '"')) "Revit add-in path for $name differs from Brand.ps1"
}
'PASS: Revit add-in uses the same icon paths'

$form = New-Object Windows.Forms.Form
$form.ClientSize = New-Object Drawing.Size(760, 520)
$rail = New-BrandStepRail -Steps @('Welcome', 'System check', 'Choose apps', 'AI connections', 'Install', 'Finish') -Footer 'Version 1.0.0'
$form.Controls.Add($rail)
$card = New-BrandCard 240 20 300 120
$form.Controls.Add($card)
$badges = foreach ($kind in 'Good', 'Info', 'Warn', 'Bad', 'Off') { $b = New-BrandBadge "$kind status" $kind; $b.Location = New-Object Drawing.Point(250, 160); $form.Controls.Add($b); $b }
$icon = New-BrandIconBox 'revit' 20 250 200
$form.Controls.Add($icon)
foreach ($current in 0, 3, 5) {
    Set-BrandStepRail $rail $current
    $bitmap = New-Object Drawing.Bitmap $rail.Width, $rail.Height
    $rail.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle 0, 0, $rail.Width, $rail.Height))
    # Left margin of the rail, beside the step markers: plain navy.
    Assert ($bitmap.GetPixel(6, [int]($rail.Height / 2)).ToArgb() -eq $script:BrandColors.Header.ToArgb()) 'Step rail is not navy'
    $ink = 0; for ($y = 90; $y -lt 300; $y += 2) { for ($x = 20; $x -lt 180; $x += 2) { if ($bitmap.GetPixel($x, $y).ToArgb() -ne $script:BrandColors.Header.ToArgb()) { $ink++ } } }
    Assert ($ink -gt 200) 'Step rail drew no steps'
    $bitmap.Dispose()
}
Set-BrandBadge $badges[0] 'Connected' 'Good'
Assert ($badges[0].Width -gt 60 -and $badges[0].AccessibleName -eq 'Connected') 'Badge did not resize to its text'
$form.Dispose()
'PASS: step rail, cards, badges and icon boxes paint'
