<#
One-command zone tool for the active AutoCAD drawing.

  zone.ps1 check                                   # report every ZONE-* polyline: area, arcs, % on plan lines, overlaps, gaps
  zone.ps1 remainder -Layer ZONE-CIRCULATION       # rebuild that zone as the space left between all other zones
  zone.ps1 snap -Layer ZONE-BOH [-Color 4]         # rough polyline on layer SKETCH -> corners snapped to real plan corners
  add -Save to save the drawing afterwards (only when the user asked to save)

Space outline (check, remainder) = the room-facing wall route (-RouteLayer, a polyline in the xref) closed through
-Close points, e.g. "49707,-22194;22522,-22194". Remainder/snap replace an existing single polyline on -Layer.
#>
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('check', 'remainder', 'snap')][string]$Mode,
    [string]$Layer, [int]$Color = 4, [string]$Xref,
    [string]$RouteLayer = 'AO-WALL-UNFOLD-REF', [string]$Close = '', [string]$Near = '',
    [string]$SketchLayer = 'SKETCH', [double]$SnapTol = 400, [switch]$Save
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tmp = Join-Path $env:TEMP 'zone-tool'; New-Item -ItemType Directory -Force $tmp | Out-Null
$py = (Get-Command py -ErrorAction SilentlyContinue).Source
$pyArgs = @('-3')
if (-not $py) { $py = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName; $pyArgs = @() }
if (-not $py) { throw 'Python 3 with shapely is required' }
if ($Mode -ne 'check' -and -not $Layer) { throw "-Layer is required for $Mode" }

# --- active drawing, xref and zone/sketch polylines ------------------------------------------------------------
$acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application.25')
try {
    $doc = $acad.ActiveDocument; $drawing = $doc.FullName
    if (-not $Xref) { foreach ($b in $doc.Blocks) { if ($b.IsXRef) { $Xref = $b.Name; break } } }
    $handles = @(); $existing = @()
    foreach ($e in $doc.ModelSpace) {
        if ($e.ObjectName -ne 'AcDbPolyline') { continue }
        if ($e.Layer -like 'ZONE-*' -or $e.Layer -eq $SketchLayer) { $handles += $e.Handle }
        if ($Layer -and $e.Layer -eq $Layer) { $existing += $e.Handle }
    }
}
finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) }
if (-not $Xref) { throw 'no xref found in the drawing' }
"drawing: $(Split-Path $drawing -Leaf) | xref: $Xref | zone/sketch polylines: $($handles.Count)"

& "$here\export-geometry.ps1" -Expected $drawing -Block $Xref -HostHandles $handles -OutFile "$tmp\export.json" | Out-Null

$closePts = @(); if ($Close) { $closePts = @($Close -split ';' | ForEach-Object { , @([double[]]($_ -split ',')) }) }
$cfg = [ordered]@{ route_layer = "$Xref|$RouteLayer"; close_with = $closePts; target = $Layer; sketch_layer = $SketchLayer; snap_tol = $SnapTol }
if ($Near) { $cfg.near = [double[]]($Near -split ',') }
ConvertTo-Json -InputObject $cfg -Depth 5 | Set-Content -Encoding utf8 "$tmp\cfg.json"

if ($Mode -eq 'check') {
    & $py @pyArgs "$here\zone_tool.py" check "$tmp\export.json" "$tmp\cfg.json"
}
else {
    & $py @pyArgs "$here\zone_tool.py" $Mode "$tmp\export.json" "$tmp\cfg.json" "$tmp\result.json"
    if ($LASTEXITCODE -ne 0) { throw "zone_tool $Mode failed" }
    if ($existing.Count -gt 1) { throw "$($existing.Count) polylines already on $Layer - remove extras first" }
    $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application.25')
    try { $doc = $acad.ActiveDocument; try { [void]$doc.Layers.Item($Layer) } catch { $l = $doc.Layers.Add($Layer); $l.color = $Color; $l.Lineweight = 50 } }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) }
    $replace = if ($existing.Count -eq 1) { $existing[0] } else { '' }
    & "$here\draw-rings.ps1" -Expected $drawing -Rings "$tmp\result.json" -Layer $Layer -Replace $replace -LogFile "$tmp\drawn.json"
}

if ($Save) {
    $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application.25')
    try { $doc = $acad.ActiveDocument; if ($doc.FullName -ne $drawing) { throw 'active drawing changed; not saving' }; $doc.Save(); "saved $(Split-Path $drawing -Leaf)" }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) }
}
