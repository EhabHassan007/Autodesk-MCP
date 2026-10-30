$ErrorActionPreference='Stop'
$t=Join-Path ([IO.Path]::GetTempPath()) ('skill-exclusion-'+[guid]::NewGuid().ToString('N'))
$saved=@{local=$env:LOCALAPPDATA;user=$env:USERPROFILE;codex=$env:CODEX_HOME}
$env:LOCALAPPDATA=Join-Path $t 'local';$env:USERPROFILE=Join-Path $t 'user';$env:CODEX_HOME=Join-Path $t 'codex'
$repo=Join-Path $t 'repo';$state=Join-Path $t 'state';$extra=Join-Path $t 'extra';$out=Join-Path $t 'review'
function Skill([string]$Folder,[string]$Name){New-Item -ItemType Directory (Join-Path $extra $Folder) -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $extra "$Folder/SKILL.md"),"---`nname: $Name`ndescription: $Name workflow`n---`nInspect a blank test document.")}
New-Item -ItemType Directory (Join-Path $repo '.agents/skills'),$state -Force|Out-Null
Skill 'revit-demo' 'revit-demo'
Skill 'linkedin-profile-optimizer' 'linkedin-profile-optimizer'
Skill 'renamed-folder' 'personal-notes'
[IO.File]::WriteAllText((Join-Path $state 'excluded-skills.txt'),"# personal skills`nLinkedIn-Profile-Optimizer`n`npersonal-notes`n")
try{
 # Collector: listed folders are neither copied nor named in REVIEW.md.
 $lines=@(& (Join-Path $PSScriptRoot '../source/runtime/scripts/collect-skills-for-review.ps1') -RepositoryRoot $repo -OutputRoot $out -AdditionalSkillRoots @($extra) -OnlyAdditionalSkillRoots -ExclusionListPath (Join-Path $state 'excluded-skills.txt'))
 $review=Get-ChildItem $out -Directory|Select-Object -First 1
 $copied=@(Get-ChildItem (Join-Path $review.FullName 'candidates') -Directory|ForEach-Object {$_.Name -replace '-[0-9a-f]{8}$',''})
 if($copied -contains 'linkedin-profile-optimizer' -or $copied -notcontains 'revit-demo'){throw ('Collector exclusion failed: '+($copied -join ','))}
 if((Get-Content (Join-Path $review.FullName 'REVIEW.md') -Raw) -match 'linkedin'){throw 'Excluded skill named in REVIEW.md'}
 if(-not ($lines -match 'exclusion list: 1')){throw 'Excluded count not reported'}
 # -ExcludeSkills works without a list file.
 $out2=Join-Path $t 'review2'
 $null=& (Join-Path $PSScriptRoot '../source/runtime/scripts/collect-skills-for-review.ps1') -RepositoryRoot $repo -OutputRoot $out2 -AdditionalSkillRoots @($extra) -OnlyAdditionalSkillRoots -ExclusionListPath (Join-Path $t 'none.txt') -ExcludeSkills 'revit-demo'
 if(@(Get-ChildItem (Join-Path (Get-ChildItem $out2 -Directory|Select-Object -First 1).FullName 'candidates') -Directory|Where-Object Name -like 'revit-demo-*').Count){throw '-ExcludeSkills ignored'}

 # Central sync: the state-root list applies, including a SKILL.md name that differs from its folder.
 $preview=(& (Join-Path $PSScriptRoot '../source/runtime/scripts/central-skill-sync.ps1') -RepositoryRoot $repo -StateRoot $state -AdditionalSkillRoots @($extra) -Preview)|ConvertFrom-Json
 $names=@($preview.skills)
 if($names -contains 'linkedin-profile-optimizer' -or $names -contains 'personal-notes' -or $names -notcontains 'revit-demo'){throw ('Central exclusion failed: '+($names -join ','))}
 if(Test-Path (Join-Path $state 'service.json')){throw 'Preview created a device credential'}
 'PASS: excluded skills are not collected, listed or submitted; folder and SKILL.md names both match'
}
finally{$env:LOCALAPPDATA=$saved.local;$env:USERPROFILE=$saved.user;$env:CODEX_HOME=$saved.codex;Remove-Item $t -Recurse -Force}
