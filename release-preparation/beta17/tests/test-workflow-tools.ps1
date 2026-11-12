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

# Revit rules come first: the Revit model tools are refused until get_revit_rules has been called.
$blocked=Call 'document_info' @{}
if(-not $blocked.result.isError -or $blocked.result.content[0].text -notmatch '^Call get_revit_rules first'){throw 'A Revit tool ran before get_revit_rules was called'}
$r=Call 'get_revit_rules' @{}
$d=$r.result.content[0].text|ConvertFrom-Json
if($r.result.isError -or -not $d.must_follow -or $null -eq $d.rules -or $d.count -ne @($d.rules).Count){throw "get_revit_rules failed: $($r.result.content[0].text)"}
$ruleTool=@((Invoke-AutodeskMcpRequest ([pscustomobject]@{id=1;method='tools/list'})).result.tools|Where-Object {$_['name'] -eq 'get_revit_rules'})
if($ruleTool.Count -ne 1 -or -not $ruleTool[0]['annotations']['readOnlyHint']){throw 'get_revit_rules is not listed as a read-only tool'}
if((Invoke-AutodeskMcpRequest ([pscustomobject]@{id=1;method='initialize';params=[pscustomobject]@{protocolVersion='2025-06-18'}})).result.instructions -notmatch 'get_revit_rules'){throw 'The server instructions do not tell clients to call get_revit_rules first'}
$r=Call 'document_info' @{}
if($r.result.content[0].text -match '^Call get_revit_rules first'){throw 'The Revit tools are still refused after get_revit_rules'}
# A rules file added to the approved cache is returned, grouped by category, and a broken file is reported.
$ruleCache=Join-Path $testLocalAppData 'AutodeskMcpSkillCollection\approved-skills\revit-rules'
New-Item -ItemType Directory $ruleCache -Force|Out-Null
"---`nname: revit-rules`ndescription: test`n---`nx"|Set-Content (Join-Path $ruleCache 'SKILL.md')
'{"schema":1,"updated":"2026-01-01","rules":[{"id":"RVT-002","title":"B","category":"areas","decided_on":"2026-01-02","instruction":"Second"},{"id":"RVT-001","title":"A","category":"annotation","decided_on":"2026-01-01","instruction":"First"}]}'|Set-Content (Join-Path $ruleCache 'rules.json')
$d=(Call 'get_revit_rules' @{}).result.content[0].text|ConvertFrom-Json
if($d.count -ne 2 -or $d.rules[0].category -ne 'annotation' -or $d.rules[1].instruction -ne 'Second'){throw 'Revit rules were not returned from the approved cache in category order'}
'not json'|Set-Content (Join-Path $ruleCache 'rules.json')
$r=Call 'get_revit_rules' @{}
if(-not $r.result.isError -or $r.result.content[0].text -notmatch 'not valid JSON'){throw 'A broken rules file must be reported'}
"PASS: get_revit_rules gates the Revit tools, lists in the server instructions, reads the approved cache and reports a broken file"

# connection_status covers AutoCAD and Revit and succeeds when either one is reachable.
$statusTools=@((Invoke-AutodeskMcpRequest ([pscustomobject]@{id=1;method='tools/list'})).result.tools|Where-Object {$_['name'] -eq 'connection_status'})
if($statusTools.Count -ne 1 -or $statusTools[0]['description'] -notmatch 'AutoCAD' -or $statusTools[0]['description'] -notmatch 'Revit'){throw 'connection_status is not described for both products'}
$cadUp=@{available=$true;version='25.0s';drawing_open=$true;active_drawing='A.dwg';summary='AutoCAD 25.0s is connected; active drawing: A.dwg.'}
$cadDown=@{available=$false;running=$false;summary='AutoCAD is not running.'}
$revitUp=@{available=$true;running=$true;sessions=@();summary='Revit 2024 is connected (session s1).'}
$revitDown=@{available=$false;running=$false;sessions=@();summary='Revit is not running.'}
$script:revitArgs=$null
function Get-RevitMcpConnectionStatus($Arguments){$script:revitArgs=$Arguments;$script:revitState}
function Get-AutoCadMcpConnectionStatus($Arguments){$script:cadState}
foreach($case in @(@($cadUp,$revitDown,'AutoCAD 25.0s is connected'),@($cadDown,$revitUp,'Revit 2024 is connected'),@($cadUp,$revitUp,'A.dwg'))){
 $script:cadState=$case[0];$script:revitState=$case[1]
 $r=Call 'connection_status' ([pscustomobject]@{})
 $d=$r.result.content[0].text|ConvertFrom-Json
 if($r.result.isError -or -not $d.connected -or $d.summary -notmatch [regex]::Escape($case[2]) -or $null -eq $d.autocad -or $null -eq $d.revit){throw "connection_status failed with one product reachable: $($r.result.content[0].text)"}
}
$script:cadState=$cadDown;$script:revitState=$revitDown
$r=Call 'connection_status' ([pscustomobject]@{})
if(-not $r.result.isError -or $r.result.content[0].text -notmatch 'AutoCAD is not running' -or $r.result.content[0].text -notmatch 'Revit is not running'){throw 'connection_status must fail with both product summaries when neither is reachable'}
$script:cadState=$cadUp;$script:revitState=$revitDown
$null=Call 'connection_status' ([pscustomobject]@{session_id='s1'})
if($script:revitArgs.session_id -ne 's1'){throw 'session_id was not passed to the Revit status'}
# Product probes report a closed product instead of throwing, without a live AutoCAD or Revit.
& {
 . (Join-Path $PSScriptRoot '../source/runtime/src/revit/revit-bridge.ps1') -LibraryOnly -SessionDirectory (Join-Path $testLocalAppData 'no-sessions')
 function Get-Process { @() }
 function Invoke-RevitPipeName { throw 'The operation has timed out.' }
 $s=Get-RevitConnectionStatus ([pscustomobject]@{})
 if($s.available -or $s.summary -ne 'Revit is not running.'){throw "Closed Revit was not reported: $($s.summary)"}
 $s=Get-RevitConnectionStatus ([pscustomobject]@{session_id='missing'})
 if($s.available -or $s.summary -notmatch 'not available'){throw 'Unknown Revit session was not reported'}
 . (Join-Path $PSScriptRoot '../source/runtime/src/autocad/autocad-bridge.ps1') -LibraryOnly
 function Get-AutoCadProgIds { @('BimCadMcp.Test.NoSuchApplication') }
 $s=Get-AutoCadConnectionStatus
 if($s.available -or $s.summary -notmatch '^AutoCAD is (not running|running but not reachable)'){throw "Unreachable AutoCAD was not reported: $($s.summary)"}
}
'PASS: connection_status reports AutoCAD and Revit separately, succeeds when either is reachable, fails clearly when neither is, and probes report closed products'

} finally {
 $env:LOCALAPPDATA = $previousLocalAppData
 Remove-Item $testLocalAppData -Recurse -Force
}
