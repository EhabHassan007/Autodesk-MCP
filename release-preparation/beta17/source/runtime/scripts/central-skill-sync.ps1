[CmdletBinding()]
param(
 [string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),
 [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'),
 [string[]]$AdditionalSkillRoots=@(),
 # Approved categories to download (see Get-SyncCategories); empty downloads every category.
 [string[]]$Categories=@(),
 [switch]$Preview,
 [switch]$LibraryOnly
)
$ErrorActionPreference='Stop'
# Isolate validation helpers so their script parameters cannot overwrite this runner's options.
$validationModule=New-Module -Name CentralSkillValidation -ArgumentList (Join-Path $PSScriptRoot 'submit-team-knowledge.ps1'),$RepositoryRoot -ScriptBlock {
 param($ScriptPath,$Root)
 . $ScriptPath -RepositoryRoot $Root -LibraryOnly
 Export-ModuleMember -Function Get-DirectoryHash,Get-SkillName,Test-SafeCandidate
}
Import-Module $validationModule -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'SkillLibrary.ps1')

function Test-RemoteSkillFiles {
 param($Skill)
 if([string]$Skill.name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$'){throw 'Invalid approved skill name.'}
 if(-not $Skill.files.PSObject.Properties['SKILL.md']){throw 'Approved skill has no SKILL.md.'}
 $seen=@{}
 foreach($file in $Skill.files.PSObject.Properties){
  $parts=@($file.Name -split '/')
  if($file.Name -match '[\\:]' -or @($parts|Where-Object {$_ -in @('','.','..') -or $_.StartsWith('.')}).Count -or $seen.ContainsKey($file.Name.ToLowerInvariant())){throw 'Invalid approved file path.'}
  $seen[$file.Name.ToLowerInvariant()]=$true
  if([IO.Path]::GetExtension($file.Name).ToLowerInvariant() -notin @('.md','.txt','.json','.yaml','.yml','.toml','.py','.ps1','.js','.ts','.sh','.csv','.xml')){throw 'Unsupported approved file type.'}
  if($file.Value -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($file.Value) -gt 256KB -or $file.Value.Contains([char]0)){throw 'Invalid approved file content.'}
 }
}

function Set-ApprovedSkillDirectory {
 param([string]$Source,[string]$Destination)
 $stage=$Destination+'.download-'+[guid]::NewGuid().ToString('N')
 $backup=$Destination+'.previous-'+[guid]::NewGuid().ToString('N')
 $moved=$false
 try {
  Copy-Item -LiteralPath $Source -Destination $stage -Recurse -Force
  if(Test-Path $Destination){Move-Item -LiteralPath $Destination -Destination $backup;$moved=$true}
  try {Move-Item -LiteralPath $stage -Destination $Destination}
  catch {
   if($moved){Move-Item -LiteralPath $backup -Destination $Destination}
   throw
  }
  if($moved){Remove-Item -LiteralPath $backup -Recurse -Force}
 }
 finally {if(Test-Path $stage){Remove-Item -LiteralPath $stage -Recurse -Force}}
}

function Install-ApprovedLibrary {
 param($Library,[string]$State,[string]$Repository,[string[]]$ClientRoots,[string[]]$Categories=@())
 $cache=Join-Path $State 'approved-skills'
 $ledgerPath=Join-Path $State 'managed-skill-hashes.json'
 $managed=@{}
 if(Test-Path $ledgerPath){$obj=Get-Content $ledgerPath -Raw|ConvertFrom-Json;foreach($p in $obj.PSObject.Properties){$managed[$p.Name]=[string]$p.Value}}
 if((Test-Path $cache) -and ((Get-Item $cache -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked cache directory refused.'}
 New-Item -ItemType Directory -Path $cache -Force|Out-Null
 # Per-skill outcome for the Skills Sync summary: added, updated, preserved (local edits kept) or current.
 $outcome=@{}
 # Installed copies of the shipped library, which may be in category folders, by skill name.
 $baselines=@{};$shippedCategories=@{}
 foreach($shipped in Get-SkillFolders (Join-Path $Repository '.agents/skills')){$baselines[$shipped.Name]=$shipped.Path;$shippedCategories[$shipped.Name]=$shipped.Category}
 $selected=@($Library.skills)
 if($Categories.Count){
  # Only the requested categories are downloaded; skills of other categories are left exactly as they are.
  $selected=@($selected|Where-Object {
   $category=if($_.PSObject.Properties['category'] -and $_.category){[string]$_.category}elseif($shippedCategories[[string]$_.name]){$shippedCategories[[string]$_.name]}else{'uncategorized'}
   $Categories -contains $category
  })
 }
 foreach($skill in $selected){
  $outcome[$skill.name]='current'
  Test-RemoteSkillFiles $skill
  $temp=Join-Path $State ('download-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory $temp|Out-Null
  try{
   foreach($file in $skill.files.PSObject.Properties){
    $path=Join-Path $temp $file.Name
    New-Item -ItemType Directory (Split-Path $path) -Force|Out-Null
    [IO.File]::WriteAllText($path,[string]$file.Value,(New-Object Text.UTF8Encoding($false)))
   }
   $hash=Get-DirectoryHash $temp
   # The service-managed MCP cache always follows approved main; local authoring folders are protected below.
   $target=Join-Path $cache $skill.name
   if(Test-Path $target){
    if(((Get-Item $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked cache path refused.'}
   }
   Set-ApprovedSkillDirectory -Source $temp -Destination $target
   foreach($clientRoot in $ClientRoots){
    if((Test-Path $clientRoot) -and ((Get-Item $clientRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){Write-Warning 'Skipped linked client skill root.';continue}
    New-Item -ItemType Directory $clientRoot -Force|Out-Null
    $destination=Join-Path $clientRoot $skill.name
    $key=$destination
    $replace=$true
    $existed=Test-Path $destination
    $current=''
    if($existed){
     # Avoid replacing personal edits or following local links.
     $linked=@(Get-Item $destination -Force;Get-ChildItem $destination -Recurse -Force)|Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}
     if($linked){$replace=$false}
     else{
      $current=Get-DirectoryHash $destination
      $baselineHash=if($baselines.ContainsKey($skill.name)){Get-DirectoryHash $baselines[$skill.name]}else{''}
      $replace=($current -eq $hash -or $current -eq $baselineHash -or ($managed.ContainsKey($key) -and $managed[$key] -eq $current))
     }
    }
    if($replace){
     Set-ApprovedSkillDirectory -Source $temp -Destination $destination
     $managed[$key]=$hash
     if(-not $existed){if($outcome[$skill.name] -eq 'current'){$outcome[$skill.name]='added'}}
     elseif($current -ne $hash -and $outcome[$skill.name] -ne 'preserved'){$outcome[$skill.name]='updated'}
    }
    else{Write-Warning ('Preserved locally edited skill: '+$skill.name);$outcome[$skill.name]='preserved'}
   }
  }
  finally{if(Test-Path $temp){Remove-Item $temp -Recurse -Force}}
 }
 $tempLedger=$ledgerPath+'.tmp'
 $managed|ConvertTo-Json|Set-Content $tempLedger -Encoding UTF8
 Move-Item $tempLedger $ledgerPath -Force
 $values=@($outcome.Values)
 [pscustomobject]@{total=$values.Count;added=@($values|Where-Object {$_ -eq 'added'}).Count;updated=@($values|Where-Object {$_ -eq 'updated'}).Count
  preserved=@($values|Where-Object {$_ -eq 'preserved'}).Count;current=@($values|Where-Object {$_ -eq 'current'}).Count}
}

# One machine-readable summary line for Skills Sync in Revit and the connector agent.
function Write-SyncResult {
 param([hashtable]$Result)
 Write-Output ('[SYNC_RESULT] '+($Result|ConvertTo-Json -Compress))
}

if($LibraryOnly){return}
New-Item -ItemType Directory $StateRoot -Force|Out-Null
$reviewRoot=Join-Path $StateRoot ('central-review-'+[guid]::NewGuid().ToString('N'))
$collector=Join-Path $PSScriptRoot 'collect-skills-for-review.ps1'
$exclusionList=Join-Path $StateRoot 'excluded-skills.txt'
$null=& $collector -RepositoryRoot $RepositoryRoot -OutputRoot $reviewRoot -AdditionalSkillRoots (@((Join-Path $RepositoryRoot 'team-candidates'))+@($AdditionalSkillRoots)) -ExclusionListPath $exclusionList
# The collector matches folder names; also match the SKILL.md name in case a folder was renamed.
$excluded=@{}
if(Test-Path -LiteralPath $exclusionList){foreach($line in Get-Content -LiteralPath $exclusionList){$t=$line.Trim();if($t -and -not $t.StartsWith('#')){$excluded[$t.ToLowerInvariant()]=$true}}}
$review=Get-ChildItem $reviewRoot -Directory|Select-Object -First 1
# Approved text already on this PC: the shipped library and the downloaded cache. Local copies of approved
# skills can hold mojibake from an earlier download; once repaired they match and are not sent again.
$approvedText=@{}
foreach($root in @((Join-Path $RepositoryRoot '.agents/skills'),(Join-Path $StateRoot 'approved-skills'))){
 foreach($approvedSkill in Get-SkillFolders $root){
  if(-not $approvedText.ContainsKey($approvedSkill.Name)){$approvedText[$approvedSkill.Name]=@()}
  $approvedText[$approvedSkill.Name]+=Get-SkillTextKey (Read-SkillText $approvedSkill.Path)
 }
}
$skills=New-Object System.Collections.Generic.List[object]
$names=@{}
$submissionBlocked=$false
foreach($folder in @(Get-ChildItem (Join-Path $review.FullName 'candidates') -Directory)){
 try{$name=Get-SkillName $folder.FullName;Test-SafeCandidate $folder.FullName}
 catch{Write-Warning ('Skipped flagged skill: '+$folder.Name);continue}
 if($excluded.ContainsKey($name.ToLowerInvariant())){Remove-Item -LiteralPath $folder.FullName -Recurse -Force;continue}
 $files=Read-SkillText $folder.FullName
 $hash=Get-SkillTextKey $files
 if($approvedText.ContainsKey($name) -and $approvedText[$name] -ccontains $hash){continue}
 if($names.ContainsKey($name)){
  if($names[$name] -cne $hash){$submissionBlocked=$true;Write-Warning ('Conflicting saved skill variants; submissions paused: '+$name)}
  continue
 }
 $names[$name]=$hash
 $skills.Add(@{name=$name;files=$files})
}
if($Preview){@{status='preview';skills=@($names.Keys);review=$review.FullName}|ConvertTo-Json -Depth 5;exit 0}
$configPath=Join-Path $StateRoot 'service.json'
if(-not(Test-Path $configPath)){
 Write-SyncResult @{status='not_enrolled';candidates=$skills.Count;reason='This computer has not joined the team skill service yet. Run the team installer, or ask your administrator.'}
 throw 'Central sharing is waiting for administrator enrollment. No team GitHub sign-in is required.'
}
$config=Get-Content $configPath -Raw|ConvertFrom-Json
$uri=[Uri]$config.service_url
if($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw 'Invalid skill service URL.'}
$secure=ConvertTo-SecureString ([string]$config.protected_token)
$pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try{$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}
finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
$versionPath=Join-Path $RepositoryRoot 'VERSION'
$headers=@{Authorization='Bearer '+$token;'X-Connector-Version'=$(if(Test-Path $versionPath){(Get-Content $versionPath -Raw).Trim()}else{'unknown'})}
$token=$null
try{
 $base=$uri.AbsoluteUri.TrimEnd('/')
 $submissionFailure=$null
 $summary=@{status='ok';candidates=$skills.Count;submitted=0;submission='none';pull_request='';categories=@($Categories)}
 try {
 if($submissionBlocked){throw 'Conflicting saved skills need administrator review.'}
 if($skills.Count){
  $body=@{skills=@($skills.ToArray())}|ConvertTo-Json -Depth 20 -Compress
  if([Text.Encoding]::UTF8.GetByteCount($body) -gt 2MB){throw 'Skill batch exceeds 2 MB. An administrator must split the review batch.'}
  $result=Invoke-RestMethod -Uri ($base+'/v1/submissions') -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
  Write-Output ($result|ConvertTo-Json -Depth 5)
  $summary.submission=[string]$result.status
  $summary.pull_request=[string]$result.pull_request
  if($result.status -eq 'submitted_for_approval'){$summary.submitted=$skills.Count}
 }
 else{Write-Output 'No new local skill candidates.'}
 }
 catch {$submissionFailure=$_.Exception.Message;$summary.submission='failed';Write-Warning 'Submission was not completed; approved skill downloads will still be attempted.'}
 try{
  $approved=Invoke-RestMethod -Uri ($base+'/v1/library') -Headers $headers -TimeoutSec 120
  $codexRoot=if($env:CODEX_HOME){Join-Path $env:CODEX_HOME 'skills'}else{Join-Path $env:USERPROFILE '.codex/skills'}
  $library=Install-ApprovedLibrary -Library $approved -State $StateRoot -Repository $RepositoryRoot -ClientRoots @($codexRoot,(Join-Path $env:USERPROFILE '.claude/skills')) -Categories $Categories
 }
 catch{
  $summary.status='failed'
  $summary.reason='Approved skills could not be downloaded. Check the internet connection and try again.'
  Write-SyncResult $summary
  throw
 }
 $summary.approved_total=$library.total;$summary.added=$library.added;$summary.updated=$library.updated
 $summary.preserved=$library.preserved;$summary.commit=[string]$approved.commit
 Write-Output ('Approved skill library synchronized. Commit: '+$approved.commit)
 if($submissionFailure){
  $summary.status='partial';$summary.reason='Approved skills were downloaded, but your saved skills could not be sent for review: '+$submissionFailure
 }
 Write-SyncResult $summary
 if($submissionFailure){throw ('Approved skills downloaded, but submission needs attention: '+$submissionFailure)}
}
finally{$headers.Authorization=$null}
