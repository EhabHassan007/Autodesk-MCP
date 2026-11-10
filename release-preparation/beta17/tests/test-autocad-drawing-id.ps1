$ErrorActionPreference='Stop'
# A saved drawing is identified by its full path, an unsaved one by its name. A never-saved drawing in AutoCAD 2024 reports a
# non-empty Path but an empty FullName, which once made the id blank so that no expected_drawing could match.
# Runs without AutoCAD, against stand-in objects.
. (Join-Path $PSScriptRoot '../source/runtime/src/autocad/autocad-bridge.ps1') -LibraryOnly
function New-Doc([string]$name,[string]$full,[string]$path){ [pscustomobject]@{Name=$name;FullName=$full;Path=$path} }
$cases=@(
 @('saved drawing', (New-Doc 'a.dwg' 'C:\w\a.dwg' 'C:\w'), 'C:\w\a.dwg'),
 @('saved drawing, forward slashes', (New-Doc 'a.dwg' 'C:/w/a.dwg' 'C:/w'), 'C:/w/a.dwg'),
 @('network drawing', (New-Doc 'a.dwg' '\\srv\share\a.dwg' '\\srv\share'), '\\srv\share\a.dwg'),
 @('unsaved, empty Path and FullName', (New-Doc 'Drawing1.dwg' '' ''), 'Drawing1.dwg'),
 @('unsaved, Path set but FullName empty (AutoCAD 2024)', (New-Doc 'Drawing1.dwg' '' 'C:\Users\x\Documents'), 'Drawing1.dwg'),
 @('unsaved, FullName is only the name', (New-Doc 'Drawing1.dwg' 'Drawing1.dwg' 'C:\Users\x\Documents'), 'Drawing1.dwg')
)
foreach($case in $cases){
 $got=Drawing-Id $case[1]
 if($got -cne $case[2]){ throw "$($case[0]): expected '$($case[2])', got '$got'" }
}
'PASS: drawing id is the full path for saved drawings and the name for unsaved ones, whatever Path reports'
