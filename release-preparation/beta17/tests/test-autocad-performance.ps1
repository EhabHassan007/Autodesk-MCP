$ErrorActionPreference='Stop'
# list_entities must not hold AutoCAD for minutes: one call examines a bounded number of objects, and each object
# is asked only for the properties its type has. Runs without AutoCAD, against stand-in objects.
. (Join-Path $PSScriptRoot '../source/runtime/src/autocad/autocad-bridge.ps1') -LibraryOnly
$script:reads=0
function New-Line([int]$n,[string]$layer){
 $o=[pscustomobject]@{Handle=('{0:X}' -f (100+$n));ObjectName='AcDbLine';Layer=$layer;Color=256;Linetype='ByLayer';Lineweight=-1;Length=1.0}
 $o|Add-Member -MemberType ScriptProperty -Name StartPoint -Value {$script:reads++;@(0,0,0)}
 $o|Add-Member -MemberType ScriptProperty -Name EndPoint -Value {$script:reads++;@(1,0,0)}
 $o
}
$objects=@(for($n=0;$n -lt 5000;$n++){New-Line $n $(if($n -eq 4900){'TARGET'}else{'0'})})
$space=[pscustomobject]@{Count=$objects.Count};$space|Add-Member -MemberType ScriptMethod -Name Item -Value {param($i)$objects[$i]}
$doc=[pscustomobject]@{Name='test.dwg';FullName='C:\t\test.dwg';Path='C:\t';ModelSpace=$space;ReadOnly=$false}
$cad=[pscustomobject]@{Documents=[pscustomobject]@{Count=1};ActiveDocument=$doc}
function Connect-Cad{$cad}
# Bounded scan with a layer filter that matches only object 4900.
$r=Invoke-CadTool 'list_entities' ([pscustomobject]@{layer='TARGET'})
if($r.scanned -ne 2000 -or $r.next_offset -ne 2000 -or $r.entities.Count -ne 0){throw ('First call not bounded: '+($r|ConvertTo-Json -Compress -Depth 3))}
$r=Invoke-CadTool 'list_entities' ([pscustomobject]@{layer='TARGET';offset=4000})
if($r.entities.Count -ne 1 -or $r.entities[0].handle -ne ('{0:X}' -f 5000) -or $null -ne $r.next_offset){throw ('Continuation failed: '+($r|ConvertTo-Json -Compress -Depth 3))}
# Same output fields as before for a line, read only once each.
$e=$r.entities[0]
foreach($k in 'StartPoint','EndPoint','Length','Color','Linetype','Lineweight'){if(-not $e.ContainsKey($k)){throw "Missing $k"}}
foreach($k in 'Radius','TextString','Area','Name'){if($e.ContainsKey($k)){throw "Unexpected $k"}}
$script:reads=0;$null=Read-Entity $objects[0];if($script:reads -ne 2){throw "Point properties read $script:reads times"}
Clear-CadReferences
'PASS: list_entities examines at most 2000 objects per call and continues from next_offset; objects are read only for their own properties'
