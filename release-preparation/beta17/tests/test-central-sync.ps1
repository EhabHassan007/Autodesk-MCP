$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('central-sync-'+[guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA=Join-Path $testRoot 'local'
$repo=Join-Path $testRoot 'repo';$state=Join-Path $testRoot 'state';$client=Join-Path $testRoot 'client'
New-Item -ItemType Directory $state,(Join-Path $repo '.agents/skills') -Force|Out-Null
. (Join-Path $PSScriptRoot '../source/runtime/scripts/central-skill-sync.ps1') -RepositoryRoot $repo -StateRoot $state -LibraryOnly
function Library($content){('{"commit":"abc","skills":[{"name":"revit-test","files":{"SKILL.md":'+($content|ConvertTo-Json -Compress)+'}}]}')|ConvertFrom-Json}
try{
 Install-ApprovedLibrary -Library (Library 'version one') -State $state -Repository $repo -ClientRoots @($client)
 $file=Join-Path $client 'revit-test/SKILL.md'
 if((Get-Content $file -Raw) -ne 'version one'){throw 'Approved skill missing'}
 Install-ApprovedLibrary -Library (Library 'version two') -State $state -Repository $repo -ClientRoots @($client)
 if((Get-Content $file -Raw) -ne 'version two'){throw 'Unmodified skill not updated'}
 Set-Content $file 'personal edits'
 Install-ApprovedLibrary -Library (Library 'version three') -State $state -Repository $repo -ClientRoots @($client)
 if((Get-Content $file -Raw).Trim() -ne 'personal edits'){throw 'Personal edits lost'}
 if((Get-Content (Join-Path $state 'approved-skills/revit-test/SKILL.md') -Raw) -ne 'version three'){throw 'MCP approved cache not updated'}
 $bad='{"name":"revit-test","files":{"SKILL.md":"ok","../escape.md":"bad"}}'|ConvertFrom-Json
 $failed=$false;try{Test-RemoteSkillFiles $bad}catch{$failed=$true}
 if(-not $failed){throw 'Approved path traversal accepted'}
 'PASS: approved skills installed and updated; local edits preserved; MCP cache refreshed; invalid path rejected'

 # Skills Sync by software: a button downloads only its category; skills of other categories are left alone.
 $mixed=('{"commit":"def","skills":['+
  '{"name":"revit-one","category":"revit","files":{"SKILL.md":"revit one"}},'+
  '{"name":"autocad-one","category":"autocad","files":{"SKILL.md":"autocad one"}},'+
  '{"name":"office-one","category":"general","files":{"SKILL.md":"office one"}},'+
  '{"name":"shipped-revit","category":null,"files":{"SKILL.md":"shipped revit v2"}}]}')|ConvertFrom-Json
 # A skill the service sends without a category takes the category of the shipped library copy.
 New-Item -ItemType Directory (Join-Path $repo '.agents/skills/revit/shipped-revit') -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $repo '.agents/skills/revit/shipped-revit/SKILL.md'),"---`nname: shipped-revit`n---`nshipped")
 $byProduct=Join-Path $testRoot 'by-product'
 New-Item -ItemType Directory (Join-Path $byProduct 'autocad-one') -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $byProduct 'autocad-one/SKILL.md'),'older autocad copy already installed')
 $r=Install-ApprovedLibrary -Library $mixed -State (Join-Path $testRoot 'state2') -Repository $repo -ClientRoots @($byProduct) -Categories @('revit')
 $names=@(Get-ChildItem $byProduct -Directory|ForEach-Object Name|Sort-Object)
 if(($names -join ',') -ne 'autocad-one,revit-one,shipped-revit'){throw "Revit sync installed the wrong skills: $($names -join ',')"}
 if((Get-Content (Join-Path $byProduct 'autocad-one/SKILL.md') -Raw) -ne 'older autocad copy already installed'){throw 'Revit sync changed an installed AutoCAD skill'}
 if($r.total -ne 2 -or $r.added -ne 2){throw "Revit sync summary wrong: total=$($r.total) added=$($r.added)"}
 $all=Install-ApprovedLibrary -Library $mixed -State (Join-Path $testRoot 'state3') -Repository $repo -ClientRoots @(Join-Path $testRoot 'all')
 if($all.total -ne 4){throw 'Without categories every approved skill should be downloaded'}

 # Which categories a sync downloads: a button takes only its product; otherwise installed products plus General.
 if((Get-SyncCategories -Product 'Revit' -InstalledProducts @('AutoCAD')) -join ',' -ne 'revit'){throw 'Revit button categories wrong'}
 if((Get-SyncCategories -Product 'AutoCAD') -join ',' -ne 'autocad'){throw 'AutoCAD button categories wrong'}
 if((Get-SyncCategories -InstalledProducts @('Revit','AutoCAD')) -join ',' -ne 'revit,autocad,general'){throw 'Weekly categories wrong'}
 if((Get-SyncCategories -InstalledProducts @()) -join ',' -ne 'general'){throw 'With no Autodesk product only General should be downloaded'}
 $unknown=$false;try{$null=Get-SyncCategories -Product 'Photoshop'}catch{$unknown=$true}
 if(-not $unknown){throw 'Unknown product accepted'}
 $programs=Join-Path $testRoot 'programs'; New-Item -ItemType Directory (Join-Path $programs 'Autodesk/Revit 2024') -Force|Out-Null
 'x'|Set-Content (Join-Path $programs 'Autodesk/Revit 2024/RevitAPI.dll')
 $machine='HKCU:\Software\SmartAutodeskConnectorTest-'+[guid]::NewGuid().ToString('N')
 try{
  New-Item -Path "$machine\AutoCAD\R25.0" -Force|Out-Null; New-Item -Path "$machine\3dsMax" -Force|Out-Null
  $found=@(Get-InstalledAutodeskProducts -ProgramFiles $programs -MachineRoot $machine)
  if(($found -join ',') -ne 'Revit,AutoCAD'){throw "Installed products wrong: $($found -join ',')"}
 }
 finally{Remove-Item -LiteralPath $machine -Recurse -Force -ErrorAction SilentlyContinue}
 'PASS: Skills Sync downloads only the chosen categories, keeps other installed skills, and picks categories by product'
}
finally{Remove-Item $testRoot -Recurse -Force}
