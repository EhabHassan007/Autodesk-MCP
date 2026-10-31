$ErrorActionPreference='Stop'
$previousLocalAppData = $env:LOCALAPPDATA
$testLocalAppData = Join-Path ([IO.Path]::GetTempPath()) ('workflow-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testLocalAppData -Force | Out-Null
$env:LOCALAPPDATA = $testLocalAppData
try {
. (Join-Path $PSScriptRoot '../source/runtime/src/autodesk/autodesk-bridge.ps1') -LibraryOnly
function Call($name,$arguments) {
 Invoke-AutodeskMcpRequest ([pscustomobject]@{id=1;method='tools/call';params=[pscustomobject]@{name=$name;arguments=$arguments}})
}
# Every shipped skill (in category folders) is listed once, with its category.
$shipped=@(Get-SkillFolders (Join-Path $PSScriptRoot '../source/runtime/.agents/skills'))
$r=Call 'list_skill_workflows' @{}
$d=$r.result.content[0].text|ConvertFrom-Json
if($r.result.isError -or $d.skills.Count -ne $shipped.Count -or $shipped.Count -lt 1){throw "Skill inventory mismatch: listed $($d.skills.Count), shipped $($shipped.Count)"}
$revit=$d.skills|Where-Object name -eq 'revit-read-write'
if($revit.category -ne 'revit'){throw 'Skill category not reported'}
if(@($d.skills|Where-Object {-not $_.category}).Count){throw 'A listed skill has no category'}
$r=Call 'read_skill_workflow' @{name='revit-read-write'}
$d=$r.result.content[0].text|ConvertFrom-Json
if($r.result.isError -or $d.content -isnot [string] -or $d.content -notmatch 'document_info'){throw 'Cannot read workflow'}
foreach($file in @('../VERSION','/etc/passwd','C:\Windows\win.ini','references/../../VERSION','../../../VERSION')){
 $r=Call 'read_skill_workflow' @{name='revit-read-write';file=$file}
 if(-not $r.result.isError){throw "Path escape accepted: $file"}
}
# The approved cache from Skills Sync is flat and wins over the shipped copy, keeping the shipped category.
$cache=Join-Path $testLocalAppData 'AutodeskMcpSkillCollection\approved-skills\revit-read-write'
New-Item -ItemType Directory $cache -Force|Out-Null
"---`nname: revit-read-write`ndescription: newer approved copy`n---`nfrom-cache"|Set-Content (Join-Path $cache 'SKILL.md')
$d=(Call 'read_skill_workflow' @{name='revit-read-write'}).result.content[0].text|ConvertFrom-Json
if($d.content -notmatch 'from-cache'){throw 'Approved cache was not preferred'}
$listed=((Call 'list_skill_workflows' @{}).result.content[0].text|ConvertFrom-Json).skills|Where-Object name -eq 'revit-read-write'
if($listed.category -ne 'revit'){throw 'Category lost for a skill served from the approved cache'}
"PASS: $($shipped.Count) workflow entries available over MCP with categories; approved cache preferred; workflow content readable; path traversal rejected"

} finally {
 $env:LOCALAPPDATA = $previousLocalAppData
 Remove-Item $testLocalAppData -Recurse -Force
}
