<#
Annotate a paper-space layout from a JSON spec (see references/annotation-spec.md).
Creates leader labels, level markers, rotated/radial dimensions and section callouts in the open drawing,
inside one Undo mark, and appends every new handle to -LogFile. Does not save or plot.

  .\annotate-sheet.ps1 -Spec spec.json -Expected <exact drawing path> -LogFile run.json [-Kinds leader,level,dim,radial,callout] [-Test]

Run stages separately (e.g. level,dim,radial,callout, then leader) and keep each call short.
Never stop this script while it is running: interrupting a COM call can deadlock AutoCAD.
#>
param(
    [Parameter(Mandatory)][string]$Spec,
    [Parameter(Mandatory)][string]$Expected,
    [Parameter(Mandatory)][string]$LogFile,
    [string[]]$Kinds = @('leader', 'level', 'dim', 'radial', 'callout'),
    [switch]$Test,
    [string]$ProgId = 'AutoCAD.Application.25'
)
$ErrorActionPreference = 'Stop'
$S = Get-Content -Raw $Spec | ConvertFrom-Json
function A($v) { @($v | ForEach-Object { $_ }) }   # unroll JSON arrays (PowerShell 5.1)

function P([string]$view, [double]$x, [double]$y) {
    $v = $S.views.$view
    [double[]]@(($v.paperCentre[0] + ($x + $v.offset[0] - $v.modelCentre[0]) * $v.scale),
        ($v.paperCentre[1] + ($y + $v.offset[1] - $v.modelCentre[1]) * $v.scale), 0)
}
function Wrap([string]$t, [int]$n) {
    $lines = @(); $cur = ''
    foreach ($w in ($t -split ' ')) { if ($cur.Length -and ($cur.Length + 1 + $w.Length) -gt $n) { $lines += $cur; $cur = $w } else { $cur = ($cur + ' ' + $w).Trim() } }
    if ($cur) { $lines += $cur }; , $lines
}
function SetDyn($br, $vals) {
    # setting a property (especially visibility) invalidates the property wrappers: re-fetch the block per key
    foreach ($k in $vals.Keys) {
        $obj = $doc.HandleToObject($br.Handle)
        foreach ($p in $obj.GetDynamicBlockProperties()) {
            if ($p.PropertyName -eq $k -and -not $p.ReadOnly) { if ("$($p.Value)" -ne "$($vals[$k])") { $p.Value = $vals[$k] }; break }
        }
    }
}
function SetAtt($br, [hashtable]$vals) { foreach ($a in $br.GetAttributes()) { if ($vals.ContainsKey($a.TagString)) { $a.TextString = $vals[$a.TagString] } } }

$st = $S.style
$labels = A $S.labels; $levels = A $S.levels; $dims = A $S.dims; $radials = A $S.radials; $callouts = A $S.callouts
if ($Test) { $labels = A $labels[0]; $levels = A $levels[0]; $dims = A $dims[0]; $radials = @(); $callouts = A $callouts[0] }
if ('leader' -notin $Kinds) { $labels = @() }; if ('level' -notin $Kinds) { $levels = @() }; if ('dim' -notin $Kinds) { $dims = @() }
if ('radial' -notin $Kinds) { $radials = @() }; if ('callout' -notin $Kinds) { $callouts = @() }

$acad = [Runtime.InteropServices.Marshal]::GetActiveObject($ProgId)
$log = New-Object System.Collections.Generic.List[object]
try {
    $doc = $null; for ($i = 0; $i -lt 20 -and -not $doc; $i++) { try { $doc = $acad.ActiveDocument } catch {}; if (-not $doc) { Start-Sleep -Milliseconds 500 } }
    if ($doc.FullName -ne $Expected) { throw "Active drawing is '$($doc.FullName)', expected '$Expected'" }
    $doc.StartUndoMark()
    try {
        # leader labels: one column per label group; each label sits level with its target (horizontal leader).
        # Colliding labels merge into a group placed at the least-squares position of their targets.
        $ps = $doc.Layouts.Item($S.layout).Block
        foreach ($colName in @($labels | ForEach-Object { if ($_.column) { $_.column } else { $_.view } } | Select-Object -Unique)) {
            $c = $S.columns.$colName
            $items = @($labels | Where-Object { $(if ($_.column) { $_.column } else { $_.view }) -eq $colName } | ForEach-Object {
                    $br = $ps.InsertBlock([double[]]@($c.x, 0, 0), $st.leaderBlock, 1.0, 1.0, 1.0, 0.0); $br.Layer = $st.leaderLayer
                    # attribute bounding boxes ignore MText wrapping: estimate lines (~2.3 mm/char, 5.6 mm/line at 3.5 high)
                    $h = (Wrap $_.text ([int][math]::Floor($c.width / 2.3))).Count * 5.6
                    foreach ($a in $br.GetAttributes()) { if ($a.TagString -eq $st.leaderTag) { $a.TextString = $_.text; $a.MTextBoundaryWidth = [double]$c.width } }
                    [pscustomobject]@{ t = (P $_.view $_.x $_.y); h = $h; handle = $br.Handle; text = $_.text; view = $_.view } } | Sort-Object { $_.t[1] } -Descending)
            $gap = 2.5; $groups = New-Object System.Collections.Generic.List[object]
            foreach ($it in $items) {
                $groups.Add([pscustomobject]@{ items = @($it); span = $it.h; top = ($it.t[1] + $it.h / 2) })
                while ($groups.Count -gt 1) {
                    $a = $groups[$groups.Count - 2]; $b = $groups[$groups.Count - 1]
                    if (($a.top - $a.span - $gap) -ge $b.top) { break }
                    $m = [pscustomobject]@{ items = @($a.items + $b.items); span = ($a.span + $gap + $b.span); top = 0.0 }
                    $off = 0.0; $sum = 0.0; foreach ($x in $m.items) { $sum += $x.t[1] + $off + $x.h / 2; $off += $x.h + $gap }
                    $m.top = $sum / $m.items.Count
                    $groups.RemoveAt($groups.Count - 1); $groups[$groups.Count - 1] = $m
                }
            }
            foreach ($g in $groups) { $g.top = [math]::Min($g.top, [double]$c.maxY) }
            for ($i = $groups.Count - 1; $i -ge 0; $i--) {
                $floor = if ($i -eq $groups.Count - 1) { [double]$c.minY } else { $groups[$i + 1].top + $gap }
                if ($groups[$i].top - $groups[$i].span -lt $floor) { $groups[$i].top = $floor + $groups[$i].span }
            }
            foreach ($g in $groups) { $y = $g.top; foreach ($x in $g.items) { $x | Add-Member y ($y - $x.h / 2) -Force; $y -= $x.h + $gap } }
            foreach ($it in $items) {
                $br = $doc.HandleToObject($it.handle); $br.InsertionPoint = [double[]]@($c.x, $it.y, 0)
                $land = 4.0; $dx = $it.t[0] - ($c.x - $land); $dy = $it.t[1] - $it.y
                # the block draws its leader at Angle1 + 180 deg from the end of the Distance1 landing
                SetDyn $br ([ordered]@{ 'Visibility1' = '1 arrow'; 'Distance1' = $land; 'Distance2' = [math]::Sqrt($dx * $dx + $dy * $dy); 'Angle1' = [math]::Atan2($dy, $dx) - [math]::PI })
                $log.Add([pscustomobject]@{ kind = 'leader'; view = $it.view; h = $it.handle; text = $it.text })
            }
        }
        $ps = $doc.Layouts.Item($S.layout).Block
        $refDyn = [ordered]@{}
        if ($st.levelReferenceHandle) { foreach ($p in $doc.HandleToObject($st.levelReferenceHandle).GetDynamicBlockProperties()) { if (-not $p.ReadOnly -and $p.PropertyName -ne 'Origin') { $refDyn[$p.PropertyName] = $p.Value } } }
        foreach ($l in $levels) {
            $pt = P $l.view 0 $l.y; $lx = if ($null -ne $l.x) { $l.x } else { $S.levelX.($l.view) }
            $sc = [double]$st.levelScale
            $br = $ps.InsertBlock([double[]]@($lx, $pt[1], 0), $st.levelBlock, $sc, $sc, $sc, 0.0); $br.Layer = $st.levelLayer
            if ($refDyn.Count) { SetDyn $br $refDyn }
            SetAtt $br @{ ($st.levelTopTag) = $l.elevation.Replace('*', ''); ($st.levelBottomTag) = $l.description }
            $log.Add([pscustomobject]@{ kind = 'level'; view = $l.view; h = $br.Handle; text = "$($l.elevation) $($l.description)" })
        }
        $ps = $doc.Layouts.Item($S.layout).Block
        foreach ($d in $dims) {
            $dim = $ps.AddDimRotated([double[]](P $d.view $d.p1[0] $d.p1[1]), [double[]](P $d.view $d.p2[0] $d.p2[1]), [double[]](P $d.view $d.line[0] $d.line[1]), ([double]$d.angle * [math]::PI / 180))
            $dim.Layer = $st.dimLayer; $dim.StyleName = $st.dimStyle; $dim.LinearScaleFactor = -1 / [double]$S.views.($d.view).scale
            if ($d.textAt) { $dim.TextPosition = [double[]](P $d.view $d.textAt[0] $d.textAt[1]) }   # plain measured number, no override
            $log.Add([pscustomobject]@{ kind = 'dim'; view = $d.view; h = $dim.Handle; text = "meas=$([math]::Round($dim.Measurement, 1))" })
        }
        foreach ($r in $radials) {
            $cp = P $r.view $r.centre[0] $r.centre[1]; $ch = P $r.view $r.chord[0] $r.chord[1]; $tp = P $r.view $r.textAt[0] $r.textAt[1]
            $len = [math]::Sqrt([math]::Pow($tp[0] - $ch[0], 2) + [math]::Pow($tp[1] - $ch[1], 2))
            $dim = $ps.AddDimRadial([double[]]$cp, [double[]]$ch, [double]$len)
            $dim.Layer = $st.radialLayer; $dim.StyleName = $st.dimStyle; $dim.LinearScaleFactor = -1 / [double]$S.views.($r.view).scale
            $log.Add([pscustomobject]@{ kind = 'radial'; view = $r.view; h = $dim.Handle; text = "meas=$([math]::Round($dim.Measurement, 1))" })
        }
        $ps = $doc.Layouts.Item($S.layout).Block
        foreach ($co in $callouts) {
            $sc = [double]$st.calloutScale
            $br = $ps.InsertBlock([double[]]@($co.at[0], $co.at[1], 0), $st.calloutBlock, $sc, $sc, $sc, [double]$co.rotation); $br.Layer = $st.calloutLayer
            SetAtt $br @{ VIEWNUMBER = $co.name; SHEETNUMBER = $st.sheetNumber }; SetDyn $br @{ 'Ref Line Length' = 0.0 }
            $log.Add([pscustomobject]@{ kind = 'callout'; view = $co.name; h = $br.Handle; text = $co.name })
        }
    }
    finally {
        $doc.EndUndoMark()
        if ($log.Count) { @($log) | ConvertTo-Json | Set-Content -Encoding utf8 $LogFile }
    }
    "created $($log.Count): " + (($log | Group-Object kind | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
}
finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) }
