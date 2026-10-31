$ErrorActionPreference='Stop'
# Skill categories: nested and legacy flat discovery, flat installs, unique names, collector hashes and the
# intake check for category folders.
$t=Join-Path ([IO.Path]::GetTempPath()) ('skill-categories-'+[guid]::NewGuid().ToString('N'))
$runtime=Join-Path $PSScriptRoot '../source/runtime'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$saved=@{local=$env:LOCALAPPDATA;user=$env:USERPROFILE;codex=$env:CODEX_HOME}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
# Runs a child PowerShell script whose failure is expected; 5.1 would otherwise turn its stderr into an exception.
function Invoke-Child([string[]]$Arguments){
 $previous=$ErrorActionPreference; $ErrorActionPreference='Continue'
 try{ $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass @Arguments 2>&1 | ForEach-Object { $_.ToString() } }
 finally{ $ErrorActionPreference=$previous }
 [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=($output -join ' ')}
}
function New-Skill([string]$Root,[string]$Folder,[string]$Name,[string]$Category=''){
 $dir=Join-Path $Root $Folder; New-Item -ItemType Directory $dir -Force|Out-Null
 $lines=@('---',"name: $Name"); if($Category){$lines+="category: $Category"}; $lines+=@("description: $Name workflow",'---','Guidance.')
 [IO.File]::WriteAllText((Join-Path $dir 'SKILL.md'),($lines -join "`n"))
}
try{
 . (Join-Path $runtime 'scripts/SkillLibrary.ps1')
 # 1. Discovery: category folders, legacy flat skills, category READMEs ignored, unknown folders ignored.
 $lib=Join-Path $t 'lib'
 New-Skill $lib 'revit/revit-a' 'revit-a' 'revit'
 New-Skill $lib 'linkedin-marketing/linkedin-b' 'linkedin-b' 'linkedin-marketing'
 New-Skill $lib 'legacy-c' 'legacy-c'
 New-Item -ItemType Directory (Join-Path $lib '3ds-max') -Force|Out-Null; '# 3ds Max'|Set-Content (Join-Path $lib '3ds-max/README.md')
 New-Item -ItemType Directory (Join-Path $lib 'not-a-category/x') -Force|Out-Null
 $found=@(Get-SkillFolders $lib)
 Assert ((($found|ForEach-Object {"$($_.Category):$($_.Name)"}|Sort-Object) -join ',') -eq ':legacy-c,linkedin-marketing:linkedin-b,revit:revit-a') "Discovery wrong: $(($found|ForEach-Object {"$($_.Category):$($_.Name)"}) -join ',')"
 Assert ((Get-SkillCategory (Join-Path $lib 'revit/revit-a')) -eq 'revit' -and (Get-SkillCategory (Join-Path $lib 'legacy-c')) -eq '') 'Frontmatter category not read'
 Assert ((Test-SkillCategory 'branding-ci') -and -not (Test-SkillCategory 'games')) 'Category list wrong'

 # 2. Install: the categorised library lands flat for Codex and Claude, so they find every skill.
 $fakeRepo=Join-Path $t 'repo'; New-Item -ItemType Directory (Join-Path $fakeRepo 'scripts') -Force|Out-Null
 Copy-Item (Join-Path $runtime 'scripts/sync-codex-skills.ps1'),(Join-Path $runtime 'scripts/SkillLibrary.ps1') (Join-Path $fakeRepo 'scripts')
 Copy-Item $lib (Join-Path $fakeRepo '.agents/skills') -Recurse
 Remove-Item (Join-Path $fakeRepo '.agents/skills/not-a-category') -Recurse
 $dest=Join-Path $t 'claude-skills'
 $null=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fakeRepo 'scripts/sync-codex-skills.ps1') -Action Install -Destination $dest
 Assert ($LASTEXITCODE -eq 0) 'Install from a categorised library failed'
 Assert (((Get-ChildItem $dest -Directory).Name|Sort-Object) -join ',' -eq 'legacy-c,linkedin-b,revit-a') 'Skills not installed flat'
 New-Skill (Join-Path $fakeRepo '.agents/skills') 'general/revit-a' 'revit-a' 'general'
 $run=Invoke-Child @('-File',(Join-Path $fakeRepo 'scripts/sync-codex-skills.ps1'),'-Action','Install','-Destination',(Join-Path $t 'dup'))
 Assert ($run.ExitCode -ne 0 -and $run.Output -match 'unique across categories') 'Duplicate skill names across categories were accepted'

 # 3. Collector: a local copy identical to a categorised library skill is IDENTICAL, not NEW.
 $env:LOCALAPPDATA=Join-Path $t 'local';$env:USERPROFILE=Join-Path $t 'user';$env:CODEX_HOME=Join-Path $t 'codex'
 $local=Join-Path $t 'local-skills'; Copy-Item (Join-Path $lib 'revit/revit-a') (Join-Path $local 'revit-a') -Recurse -Force
 $collectRepo=Join-Path $t 'collect-repo'; Copy-Item $lib (Join-Path $collectRepo '.agents/skills') -Recurse
 $lines=@(& (Join-Path $runtime 'scripts/collect-skills-for-review.ps1') -RepositoryRoot $collectRepo -OutputRoot (Join-Path $t 'review') -AdditionalSkillRoots @($local) -OnlyAdditionalSkillRoots -ExclusionListPath (Join-Path $t 'none.txt'))
 Assert (($lines -join "`n") -match 'Candidates requiring a decision: 0') 'Categorised library skill reported as new'

 # 4. Intake check: a skill in a category folder passes; a mismatched category or duplicate name fails.
 $git='git'; if(-not (Get-Command git -ErrorAction SilentlyContinue)){$git='C:\Program Files\Git\cmd\git.exe'}
 $intake=Join-Path $t 'intake'; New-Item -ItemType Directory (Join-Path $intake 'scripts') -Force|Out-Null
 Copy-Item (Join-Path $repoRoot 'scripts/validate-team-skill-intake.ps1'),(Join-Path $repoRoot 'scripts/SkillLibrary.ps1') (Join-Path $intake 'scripts')
 New-Skill (Join-Path $intake '.agents/skills') 'revit/revit-a' 'revit-a' 'revit'
 & $git -C $intake init -q -b main; & $git -C $intake -c user.name=t -c user.email=t@example.test add -A; & $git -C $intake -c user.name=t -c user.email=t@example.test commit -qm base
 & $git -C $intake checkout -qb skill-intake/test
 $validate={ param($expectPass,$label) $run=Invoke-Child @('-File',(Join-Path $intake 'scripts/validate-team-skill-intake.ps1'),'-RepositoryRoot',$intake,'-BaseRef','main','-HeadRef','skill-intake/test'); Assert (($run.ExitCode -eq 0) -eq $expectPass) "$label`: $($run.Output)" }
 New-Skill (Join-Path $intake '.agents/skills') 'autocad/acad-new' 'acad-new' 'autocad'
 & $git -C $intake add -A; & $git -C $intake -c user.name=t -c user.email=t@example.test commit -qm add
 & $validate $true 'A correct categorised submission was rejected'
 New-Skill (Join-Path $intake '.agents/skills') 'autocad/acad-wrong' 'acad-wrong' 'revit'
 & $git -C $intake add -A; & $git -C $intake -c user.name=t -c user.email=t@example.test commit -qm wrong
 & $validate $false 'A skill whose category does not match its folder was accepted'
 & $git -C $intake reset -q --hard HEAD~1
 New-Skill (Join-Path $intake '.agents/skills') 'general/revit-a' 'revit-a' 'general'
 & $git -C $intake add -A; & $git -C $intake -c user.name=t -c user.email=t@example.test commit -qm dup
 & $validate $false 'A duplicate skill name in another category was accepted'

 # 5. The approved library itself: every skill in a category folder, names unique, categories declared.
 $approved=@(Get-SkillFolders (Join-Path $repoRoot '.agents/skills'))
 Assert ($approved.Count -ge 30 -and -not @($approved|Where-Object {-not $_.Category}).Count) 'Approved library has skills outside category folders'
 Assert (-not @($approved|Group-Object Name|Where-Object Count -gt 1).Count) 'Approved library repeats a skill name'
 Assert (-not @($approved|Where-Object {(Get-SkillCategory $_.Path) -ne $_.Category}).Count) 'An approved SKILL.md category does not match its folder'
 "PASS: category folders and legacy flat skills discovered; installs stay flat; duplicate names refused; collector recognises categorised skills; intake check validates categories; approved library ($($approved.Count) skills) fully categorised"
}
finally{$env:LOCALAPPDATA=$saved.local;$env:USERPROFILE=$saved.user;$env:CODEX_HOME=$saved.codex;Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue}
