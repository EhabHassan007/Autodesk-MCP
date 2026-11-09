<#
Export curve geometry of an xref block definition (and selected host polylines) to JSON for analysis.
Lines, arcs, circles and lightweight polylines (with bulges). Read-only.
#>
param([string]$Expected, [string]$Block, [string[]]$HostHandles, [string]$OutFile)
$ErrorActionPreference = 'Stop'
function Pl($e) {
    $c = $e.Coordinates; $n = $c.Count / 2
    [pscustomobject]@{ t = 'pline'; layer = $e.Layer; h = $e.Handle; closed = [bool]$e.Closed
        pts = @(for ($i = 0; $i -lt $n; $i++) { , @([double]$c[2 * $i], [double]$c[2 * $i + 1], [double]$e.GetBulge($i)) }) }
}
$acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application.25')
try {
    $doc = $acad.ActiveDocument
    if ($doc.FullName -ne $Expected) { throw "Active drawing is $($doc.FullName)" }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $doc.Blocks.Item($Block)) {
        switch ($e.ObjectName) {
            'AcDbLine' { $out.Add([pscustomobject]@{ t = 'line'; layer = $e.Layer; h = $e.Handle; a = @($e.StartPoint[0], $e.StartPoint[1]); b = @($e.EndPoint[0], $e.EndPoint[1]) }) }
            'AcDbArc' { $out.Add([pscustomobject]@{ t = 'arc'; layer = $e.Layer; h = $e.Handle; c = @($e.Center[0], $e.Center[1]); r = $e.Radius; sa = $e.StartAngle; ea = $e.EndAngle }) }
            'AcDbCircle' { $out.Add([pscustomobject]@{ t = 'circle'; layer = $e.Layer; h = $e.Handle; c = @($e.Center[0], $e.Center[1]); r = $e.Radius }) }
            'AcDbPolyline' { $out.Add((Pl $e)) }
            'AcDbBlockReference' {
                # columns are blocks: export their outline rectangle so column faces can bound a zone
                if ($e.Layer -match 'column') {
                    $mn = $null; $mx = $null; $e.GetBoundingBox([ref]$mn, [ref]$mx)
                    $out.Add([pscustomobject]@{ t = 'pline'; layer = $e.Layer; h = $e.Handle; closed = $true
                            pts = @(@($mn[0], $mn[1], 0.0), @($mx[0], $mn[1], 0.0), @($mx[0], $mx[1], 0.0), @($mn[0], $mx[1], 0.0)) })
                }
            }
        }
    }
    $hostItems = @(foreach ($h in $HostHandles) { Pl ($doc.HandleToObject($h)) })
    ConvertTo-Json -Depth 6 -Compress -InputObject @{ xref = [object[]]$out.ToArray(); host = [object[]]$hostItems } | Set-Content -Encoding utf8 $OutFile
    "exported $($out.Count) xref curves + $($hostItems.Count) host polylines"
}
finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) }

