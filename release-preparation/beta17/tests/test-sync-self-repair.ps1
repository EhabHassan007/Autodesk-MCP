$ErrorActionPreference='Stop'
# Skills Sync restores a helper missing from its own copy of the scripts, and a failed sync always records a reason
# the Skills Sync window can show instead of "check the internet connection".
$t=Join-Path ([IO.Path]::GetTempPath()) ('sync-self-repair-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $PSScriptRoot '../source/runtime/scripts'
$repo=Join-Path $t 'repo';$state=Join-Path $t 'state';$copy=Join-Path $state 'scripts'
New-Item -ItemType Directory (Join-Path $repo '.agents/skills'),(Join-Path $repo 'scripts'),$copy -Force|Out-Null
foreach($n in 'weekly-skill-collection.ps1','collect-skills-for-review.ps1','submit-team-knowledge.ps1','central-skill-sync.ps1','send-usage.ps1','SkillLibrary.ps1'){
 Copy-Item (Join-Path $source $n) (Join-Path $repo "scripts/$n")
 if($n -ne 'SkillLibrary.ps1'){Copy-Item (Join-Path $source $n) (Join-Path $copy $n)}
}
$engine=(Get-Process -Id $PID).Path
try{
 $null=& $engine -NoProfile -File (Join-Path $copy 'weekly-skill-collection.ps1') -Action Preview -Product Revit -RepositoryRoot $repo -StateRoot $state 2>&1
 if(-not (Test-Path (Join-Path $copy 'SkillLibrary.ps1'))){throw 'Missing SkillLibrary.ps1 was not restored'}
 if((Get-Content (Join-Path $state 'weekly.log') -Raw) -notmatch 'Restored missing SkillLibrary.ps1'){throw 'Restore not logged'}
 $r=Get-Content (Join-Path $state 'last-result.json') -Raw|ConvertFrom-Json
 if($r.status -eq 'failed' -and -not $r.sync_reason){throw 'Failed run has no sync_reason'}
 # Missing from both copies: the run stops with a reason that says what to do.
 Remove-Item (Join-Path $copy 'SkillLibrary.ps1'),(Join-Path $repo 'scripts/SkillLibrary.ps1')
 $null=& $engine -NoProfile -File (Join-Path $copy 'weekly-skill-collection.ps1') -Action Preview -Product Revit -RepositoryRoot $repo -StateRoot $state 2>&1
 $r=Get-Content (Join-Path $state 'last-result.json') -Raw|ConvertFrom-Json
 if($r.sync_status -ne 'failed' -or $r.sync_reason -notmatch 'SkillLibrary\.ps1' -or $r.sync_reason -notmatch 'Install / Repair'){throw ('Unexpected result: '+($r|ConvertTo-Json -Compress))}
 'PASS: a missing Skills Sync helper is restored from the installed connector; failures always carry a reason for the Skills Sync window'
}
finally{Remove-Item $t -Recurse -Force}
