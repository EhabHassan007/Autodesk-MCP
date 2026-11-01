$ErrorActionPreference='Stop'
# Two different saved copies of one skill hold back only that skill, and the result names it and where both copies are.
# A copy that exactly matches an approved version this PC installed earlier is not a personal edit and is not sent.
$t=Join-Path ([IO.Path]::GetTempPath()) ('skill-conflicts-'+[guid]::NewGuid().ToString('N'))
$saved=@{local=$env:LOCALAPPDATA;user=$env:USERPROFILE;codex=$env:CODEX_HOME}
$env:LOCALAPPDATA=Join-Path $t 'local';$env:USERPROFILE=Join-Path $t 'user';$env:CODEX_HOME=Join-Path $t 'codex'
$repo=Join-Path $t 'repo';$state=Join-Path $t 'state'
$codexSkills=Join-Path $env:CODEX_HOME 'skills';$claudeSkills=Join-Path $env:USERPROFILE '.claude/skills'
function Skill([string]$Root,[string]$Name,[string]$Text){
 New-Item -ItemType Directory (Join-Path $Root $Name) -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $Root "$Name/SKILL.md"),"---`nname: $Name`ndescription: $Name workflow`n---`n$Text`n")
}
New-Item -ItemType Directory (Join-Path $repo '.agents/skills'),$state -Force|Out-Null
Skill $codexSkills 'plain-skill' 'Only one copy.'
Skill $codexSkills 'split-skill' 'Edited in Codex.'
Skill $claudeSkills 'split-skill' 'Edited in Claude.'
# An older approved version, still recorded in the ledger as installed by Skills Sync.
Skill $claudeSkills 'old-approved' 'Approved last month.'
$validation=New-Module -ArgumentList (Join-Path $PSScriptRoot '../source/runtime/scripts/submit-team-knowledge.ps1'),$repo -ScriptBlock {param($s,$r);. $s -RepositoryRoot $r -LibraryOnly;Export-ModuleMember -Function Get-DirectoryHash}
@{(Join-Path $claudeSkills 'old-approved')=(& $validation {Get-DirectoryHash $args[0]} (Join-Path $claudeSkills 'old-approved'))}|ConvertTo-Json|Set-Content (Join-Path $state 'managed-skill-hashes.json') -Encoding UTF8
$secure=New-Object Security.SecureString;'test-placeholder'.ToCharArray()|ForEach-Object {$secure.AppendChar($_)}
@{service_url='https://skills.example.test';protected_token=(ConvertFrom-SecureString $secure)}|ConvertTo-Json|Set-Content (Join-Path $state 'service.json') -Encoding ASCII
$captured=@{}
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 if($Uri -like '*/v1/submissions'){$captured.body=$Body;return [pscustomobject]@{status='submitted_for_approval';pull_request='https://example.test/pull/1'}}
 [pscustomobject]@{commit='test';skills=@()}
}
try{
 $out=@(& (Join-Path $PSScriptRoot '../source/runtime/scripts/central-skill-sync.ps1') -RepositoryRoot $repo -StateRoot $state 3>$null)
 if(-not $captured.body){throw 'The skill without a conflict was not sent'}
 $sent=@(([Text.Encoding]::UTF8.GetString($captured.body)|ConvertFrom-Json).skills.name)
 if(($sent -join ',') -ne 'plain-skill'){throw ('Unexpected submissions: '+($sent -join ','))}
 $line=@($out|Where-Object {"$_" -like '[[]SYNC_RESULT]*'})[0]
 $result=("$line".Substring(14))|ConvertFrom-Json
 if($result.status -ne 'partial' -or $result.submitted -ne 1 -or $result.withheld -ne 1){throw ('Unexpected result: '+$line)}
 foreach($part in 'split-skill','Codex user skills','Claude Code user skills'){if($result.reason -notlike "*$part*"){throw "Reason does not mention $part : $($result.reason)"}}
 if($result.reason -like '*old-approved*'){throw 'Unedited approved copy was treated as a saved skill'}
 'PASS: a conflicting skill is held back alone and named with both locations; unedited approved copies are not sent'
}
finally{$env:LOCALAPPDATA=$saved.local;$env:USERPROFILE=$saved.user;$env:CODEX_HOME=$saved.codex;Remove-Item $t -Recurse -Force}
