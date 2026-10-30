$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('usage-test-'+[guid]::NewGuid().ToString('N'))
$savedLocal=$env:LOCALAPPDATA
$runtime=Join-Path $PSScriptRoot '../source/runtime'
$env:LOCALAPPDATA=$testRoot
$state=Join-Path $testRoot 'AutodeskMcpSkillCollection'
$usage=Join-Path $state 'usage.jsonl';$pending=Join-Path $state 'usage-pending.jsonl'
New-Item -ItemType Directory $state -Force|Out-Null
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Lines($path){if(Test-Path $path){@(Get-Content $path|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json})}else{@()}}
try{
 # 1. The bridge records names only, and only on an enrolled PC.
 . (Join-Path $runtime 'src/autodesk/autodesk-bridge.ps1') -LibraryOnly
 function Call($name,$arguments){Invoke-AutodeskMcpRequest ([pscustomobject]@{id=1;method='tools/call';params=[pscustomobject]@{name=$name;arguments=$arguments}})}
 $null=Call 'read_skill_workflow' @{name='revit-read-write'}
 Assert (-not (Test-Path $usage)) 'Usage recorded before enrollment'
 $token=([guid]::NewGuid().ToString('N'))*2
 $enroll=Join-Path $testRoot 'enroll.json'
 @{service_url='https://skills.example.test';device_id='0123456789abcdef0123456789abcdef';device_token=$token}|ConvertTo-Json|Set-Content $enroll
 $null=& (Join-Path $runtime 'scripts/Initialize-SkillService.ps1') -ConfigPath $enroll
 Remove-Item $enroll
 $r=Call 'read_skill_workflow' @{name='revit-read-write'}
 Assert (-not $r.result.isError) 'Workflow read failed'
 $null=Call 'read_skill_workflow' @{name='revit-read-write';file='SKILL.md'}
 $null=Call 'list_skill_workflows' @{}
 $null=Call 'read_skill_workflow' @{name='revit-read-write';file='../VERSION'}
 $null=Call 'no_such_tool' @{secret='do-not-record'}
 $text=Get-Content $usage -Raw
 $recorded=Lines $usage
 Assert ($recorded.Count -eq 2 -and @($recorded|Where-Object {$_.kind -eq 'skill' -and $_.name -eq 'revit-read-write' -and $_.day -eq (Get-Date).ToString('yyyy-MM-dd')}).Count -eq 2) "Wrong usage lines: $text"
 Assert (@($recorded[0].PSObject.Properties.Name|Sort-Object) -join ',' -eq 'day,kind,name') "Usage line holds more than names: $text"
 Assert (-not $text.Contains('SKILL.md') -and -not $text.Contains('do-not-record') -and -not $text.Contains('no_such_tool')) 'Arguments or failed calls recorded'
 Write-UsageEvent 'tool' 'drawing_info'
 Write-UsageEvent 'tool' 'C:\drawings\secret.dwg'
 Assert ((Lines $usage).Count -eq 3) 'Tool name not recorded or a path accepted as a name'
 'PASS: bridge records skill/tool names and day only, only after enrollment, never arguments or failed calls'

 # 2. send-usage aggregates, sends with the device token and connector headers, and truncates on success.
 . (Join-Path $runtime 'scripts/send-usage.ps1') -StateRoot $state -LibraryOnly
 $global:UsageCalls=New-Object System.Collections.Generic.List[object]
 $global:UsageFail=@()
 function global:Invoke-RestMethod {
  param($Uri,$Method,$Headers,$UserAgent,$ContentType,$Body,$TimeoutSec)
  $global:UsageCalls.Add([pscustomobject]@{Uri=$Uri;Auth=$Headers.Authorization;Version=$Headers['X-Connector-Version'];Agent=$UserAgent;Body=([Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json)})
  if($global:UsageFail -contains $global:UsageCalls.Count){
   $ex=New-Object Exception 'HTTP error';$ex|Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=503});throw $ex
  }
  [pscustomobject]@{accepted=@($Body).Count}
 }
 $today=(Get-Date).ToString('yyyy-MM-dd');$old=(Get-Date).AddDays(-90).ToString('yyyy-MM-dd')
 Add-Content $usage -Value @('not json',('{"kind":"skill","name":"old-skill","day":"'+$old+'"}'),('{"kind":"bad","name":"x","day":"'+$today+'"}'))
 $result=Send-Usage
 Assert ($global:UsageCalls.Count -eq 1 -and $result -eq 'Reported 2 usage record(s).') "Unexpected send result: $result"
 $call=$global:UsageCalls[0]
 Assert ($call.Uri -eq 'https://skills.example.test/v1/usage' -and $call.Auth -eq ('Bearer '+$token) -and $call.Version -and $call.Agent -like 'Autodesk-MCP-Connector/*') 'Wrong usage request'
 $sent=@($call.Body.events)
 $skill=$sent|Where-Object {$_.kind -eq 'skill'};$tool=$sent|Where-Object {$_.kind -eq 'tool'}
 Assert ($sent.Count -eq 2 -and $skill.name -eq 'revit-read-write' -and $skill.count -eq 2 -and $skill.day -eq $today -and $tool.name -eq 'drawing_info' -and $tool.count -eq 1) "Wrong aggregation: $($sent|ConvertTo-Json -Compress)"
 Assert (-not (Test-Path $usage) -and -not (Test-Path $pending) -and @(Get-ChildItem $state -Filter 'usage-taking-*').Count -eq 0) 'Sent lines were not removed'
 Assert ((Send-Usage) -eq 'No new usage to report.' -and $global:UsageCalls.Count -eq 1) 'Empty run sent a request'

 # 3. A failed upload keeps the counts and merges them with new uses on the next run.
 Write-UsageEvent 'tool' 'list_layers'
 $global:UsageFail=@(2)
 $failed=$false;try{$null=Send-Usage}catch{$failed=$true}
 Assert ($failed -and (Lines $pending).Count -eq 1) 'Failed upload lost the counts'
 Write-UsageEvent 'tool' 'list_layers'
 $null=Send-Usage
 $last=@($global:UsageCalls[-1].Body.events)
 Assert ($last.Count -eq 1 -and $last[0].count -eq 2 -and -not (Test-Path $pending)) 'Retried counts not merged and cleared'

 # 4. More than 500 events go in batches; a failed later batch keeps only the unsent part.
 $global:UsageCalls.Clear();$global:UsageFail=@(2)
 [IO.File]::WriteAllLines($usage,[string[]](1..600|ForEach-Object {'{"kind":"tool","name":"tool-'+$_+'","day":"'+$today+'"}'}))
 $failed=$false;try{$null=Send-Usage}catch{$failed=$true}
 Assert ($failed -and @($global:UsageCalls[0].Body.events).Count -eq 500 -and (Lines $pending).Count -eq 100) 'Batching or partial truncation wrong'
 $global:UsageFail=@()
 $null=Send-Usage
 Assert (@($global:UsageCalls[-1].Body.events).Count -eq 100 -and -not (Test-Path $pending)) 'Remaining batch not sent'
 'PASS: send-usage aggregates by kind/name/day, drops malformed and expired lines, batches 500, removes only sent counts, retries the rest'
}
finally{
 $env:LOCALAPPDATA=$savedLocal
 Remove-Item function:global:Invoke-RestMethod -ErrorAction SilentlyContinue
 Remove-Variable UsageCalls,UsageFail -Scope Global -ErrorAction SilentlyContinue
 Remove-Item $testRoot -Recurse -Force
}
