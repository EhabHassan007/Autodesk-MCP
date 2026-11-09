<#
Draw zone rings ({"rings": [[x, y, bulge], ...]}) as closed bulged LWPOLYLINEs on a layer, ByLayer colour and
lineweight, optionally replacing a previous polyline by handle. One Undo mark; reads back. Does not save.
#>
param([string]$Expected, [string]$Rings, [string]$Layer, [string]$Replace, [string]$LogFile)
$ErrorActionPreference = 'Stop'
$data = Get-Content -Raw $Rings | ConvertFrom-Json
$acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application.25')
$log = New-Object System.Collections.Generic.List[object]
try {
    $doc = $acad.ActiveDocument
    if ($doc.FullName -ne $Expected) { throw "Active drawing is $($doc.FullName)" }
    $doc.StartUndoMark()
    try {
        if ($Replace) { $old = $doc.HandleToObject($Replace); if ($old.Layer -ne $Layer) { throw "$Replace is on $($old.Layer), not $Layer" }; $old.Delete(); "deleted $Replace" }
        foreach ($ring in @($data.rings | ForEach-Object { , $_ })) {
            $v = @($ring | ForEach-Object { , $_ }); $flat = New-Object 'double[]' ($v.Count * 2)
            for ($i = 0; $i -lt $v.Count; $i++) { $flat[2 * $i] = [double]$v[$i][0]; $flat[2 * $i + 1] = [double]$v[$i][1] }
            $pl = $doc.ModelSpace.AddLightWeightPolyline($flat)
            for ($i = 0; $i -lt $v.Count; $i++) { if ([double]$v[$i][2] -ne 0) { $pl.SetBulge($i, [double]$v[$i][2]) } }
            $pl.Closed = $true; $pl.Layer = $Layer; $pl.color = 256; $pl.Lineweight = -1   # ByLayer, not CECOLOR
            $log.Add([pscustomobject]@{ layer = $Layer; h = $pl.Handle; vertices = $v.Count; area_m2 = [math]::Round($pl.Area / 1e6, 1) })
        }
    }
    finally { $doc.EndUndoMark(); if ($log.Count) { ConvertTo-Json -InputObject ([object[]]$log.ToArray()) | Set-Content -Encoding utf8 $LogFile } }
    foreach ($r in $log) { $e = $doc.HandleToObject($r.h); "{0} {1} closed={2} vertices={3} area={4} m2 color={5}" -f $r.h, $e.Layer, $e.Closed, $r.vertices, $r.area_m2, $e.color }
    $doc.Regen(1)
}
finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) }
