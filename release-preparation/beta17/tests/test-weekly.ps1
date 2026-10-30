$ErrorActionPreference='Stop'
$scripts=(Join-Path $PSScriptRoot '../source/runtime/scripts')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('weekly-test-'+[guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA=Join-Path $testRoot 'local';$env:USERPROFILE=Join-Path $testRoot 'user'
# Only this subprocess's test fixture variables are changed; the real user's skill folders are not scanned.
$repo=Join-Path $testRoot 'repo';$extra=Join-Path $testRoot 'extra';$state=Join-Path $testRoot 'state'
function Skill($path,$name,$body){New-Item -ItemType Directory $path -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $path 'SKILL.md'),"---`nname: $name`ndescription: test skill`n---`n$body")}
try {
 Skill (Join-Path $repo '.agents/skills/approved') 'approved' 'already shared'
 Skill (Join-Path $env:USERPROFILE '.claude/skills/approved') 'approved' 'already shared'
 Skill (Join-Path $env:USERPROFILE '.claude/skills/new-claude') 'new-claude' 'safe workflow'
 Skill (Join-Path $env:USERPROFILE '.agents/skills/new-agent') 'new-agent' 'safe workflow'
 Skill (Join-Path $extra 'extra-skill') 'extra-skill' 'safe workflow'
 Skill (Join-Path $extra 'secret-skill') 'secret-skill' 'password=do-not-upload'
 Skill (Join-Path $extra 'new-claude') 'new-claude' 'safe workflow'
 $submit=Join-Path $scripts 'submit-team-knowledge.ps1'
 $argsMap=@{RepositoryRoot=$repo;StateRoot=$state;CandidateRoot=(Join-Path $repo 'team-candidates');IncludeSavedSkills=$true;AdditionalSkillRoots=@($extra);DryRun=$true}
 # Exclude the real HOME Codex skills by supplying an empty CODEX_HOME from the shell launching this test.
 $out=(& $submit @argsMap) -join "`n"
 $data=$out|ConvertFrom-Json
 $names=@($data.candidates.name|Sort-Object)
 if(($names -join ',') -ne 'extra-skill,new-agent,new-claude'){throw "Incorrect candidates: $($names -join ',')"}
 if(Test-Path (Join-Path $state 'submitted-hashes.json')){throw 'Preview marked skills submitted'}
 'PASS: Claude/agent/custom roots; skip identical and sensitive; duplicate elimination; preview does not upload or advance ledger'
 # A nested symlink must be skipped before any contents can be copied.
 $linked=Join-Path $extra 'linked-skill';Skill $linked 'linked-skill' 'safe'
 New-Item -ItemType SymbolicLink -Path (Join-Path $linked 'outside') -Target $env:USERPROFILE|Out-Null
 $out=(& $submit @argsMap) -join "`n";$data=$out|ConvertFrom-Json
 if($data.candidates.name -contains 'linked-skill'){throw 'Symlink accepted'}
 'PASS: skill containing a link is excluded'
 # A conflicting same-name revision is refused instead of selecting a source arbitrarily.
 Skill (Join-Path $extra 'new-claude') 'new-claude' 'conflicting variant'
 $failed=$false
 try{& $submit @argsMap|Out-Null}catch{$failed=$_.Exception.Message -match 'Conflicting candidates'}
 if(-not $failed){throw 'Conflicting skill not rejected'}
 'PASS: conflicting skill revisions stop submission for review'
}
finally {Remove-Item $testRoot -Recurse -Force}
