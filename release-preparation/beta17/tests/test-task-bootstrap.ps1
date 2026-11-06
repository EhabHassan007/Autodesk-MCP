$ErrorActionPreference='Stop'
# configure-connector-tasks.ps1 runs at Install / Repair and when an earlier version installs this one. It
# registers nothing: it removes earlier background tasks (without stopping the agent that may be running the
# update), refreshes the Skills Sync helpers, keeps the weekly reminder choice and folders, and turns update
# checks on unless the person turned them off.
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('tasks-test-'+[guid]::NewGuid().ToString('N'))
$savedLocal=$env:LOCALAPPDATA
$env:LOCALAPPDATA=Join-Path $testRoot 'local'
$RepositoryRoot=Join-Path $testRoot 'connector'
$fixtureScripts=Join-Path $RepositoryRoot 'scripts'
New-Item -ItemType Directory $fixtureScripts -Force|Out-Null
@'
param($Action,$RepositoryRoot,$StateRoot,$Reminder='',$AdditionalSkillRoots=@())
New-Item -ItemType Directory -Path $StateRoot -Force|Out-Null
@{action=$Action;reminder=$Reminder;roots=$AdditionalSkillRoots}|ConvertTo-Json|Set-Content (Join-Path $StateRoot 'test-call.json')
$global:LASTEXITCODE=0
'@|Set-Content (Join-Path $fixtureScripts 'weekly-skill-collection.ps1')
@'
param([switch]$StopAgent,$StateRoot)
New-Item -ItemType Directory -Path $StateRoot -Force|Out-Null
@{stop_agent=[bool]$StopAgent}|ConvertTo-Json|Set-Content (Join-Path $StateRoot 'retire-call.json')
'Nothing runs in the background.'
'@|Set-Content (Join-Path $fixtureScripts 'retire-background-tasks.ps1')
foreach($n in @('collect-skills-for-review.ps1','submit-team-knowledge.ps1','central-skill-sync.ps1','Initialize-SkillService.ps1','send-usage.ps1','SkillLibrary.ps1')){'# test placeholder'|Set-Content (Join-Path $fixtureScripts $n)}
$script:updates=0
function Invoke-TaskSetup {param($Script,$ScriptArguments) $script:updates++}
$source=Get-Content (Join-Path $PSScriptRoot '../source/runtime/scripts/configure-connector-tasks.ps1') -Raw
Assert ($source -notmatch 'Register-ScheduledTask|-Action Register|connector-agent') 'configure-connector-tasks still registers background tasks'
$body=[scriptblock]::Create($source.Substring($source.IndexOf('$stateRoot=Join-Path')).Replace('$PSScriptRoot','$fixtureScripts'))
try {
 $state=Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
 & $body
 $call=Get-Content (Join-Path $state 'test-call.json') -Raw|ConvertFrom-Json
 Assert ($call.action -eq 'Configure' -and -not $call.reminder -and $script:updates -eq 1) 'Fresh install: Skills Sync settings or update checks not set up'
 $retire=Get-Content (Join-Path $state 'retire-call.json') -Raw|ConvertFrom-Json
 Assert (-not $retire.stop_agent) 'The agent that may be installing this update must not be stopped'
 Assert ((Test-Path (Join-Path $state 'scripts/send-usage.ps1')) -and -not (Test-Path (Join-Path $state 'scripts/connector-agent.ps1'))) 'Helpers not copied, or the agent copied again'
 'PASS: fresh setup registers nothing, removes earlier tasks and turns update checks on'

 @{enabled=$false;day='Monday';time='10:00';additional_skill_roots=@('custom')}|ConvertTo-Json|Set-Content (Join-Path $state 'settings.json')
 $u=Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector';New-Item -ItemType Directory $u -Force|Out-Null
 # Older versions saved "off" by mistake on fresh installs; only the person's own choice keeps it off.
 '{"notifications_enabled":false}'|Set-Content (Join-Path $u 'update-state.json')
 & $body
 $call=Get-Content (Join-Path $state 'test-call.json') -Raw|ConvertFrom-Json
 Assert ($call.reminder -eq 'Off' -and @($call.roots)[0] -eq 'custom') 'Reminder choice or skill folders lost'
 Assert ($script:updates -eq 2) 'Accidental "off" from an older version was not repaired'
 '{"notifications_enabled":false,"notifications_user_disabled":true}'|Set-Content (Join-Path $u 'update-state.json')
 & $body
 Assert ($script:updates -eq 2) 'Update checks turned back on against the person''s choice'
 'PASS: reminder choice, skill folders and the update-check choice are kept'
}
finally {$env:LOCALAPPDATA=$savedLocal;Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
