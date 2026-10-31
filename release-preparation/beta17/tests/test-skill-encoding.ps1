$ErrorActionPreference='Stop'
# Skills Sync must send dashes, quotation marks and Arabic exactly as saved, and repair local copies that an
# earlier wrong decoding (UTF-8 read as Latin-1 or Windows-1252) turned into mojibake.
$t=Join-Path ([IO.Path]::GetTempPath()) ('skill-encoding-'+[guid]::NewGuid().ToString('N'))
$saved=@{local=$env:LOCALAPPDATA;user=$env:USERPROFILE;codex=$env:CODEX_HOME}
$env:LOCALAPPDATA=Join-Path $t 'local';$env:USERPROFILE=Join-Path $t 'user';$env:CODEX_HOME=Join-Path $t 'codex'
$repo=Join-Path $t 'repo';$state=Join-Path $t 'state';$extra=Join-Path $t 'extra'
$utf8=New-Object Text.UTF8Encoding($false,$true)
$latin1=[Text.Encoding]::GetEncoding(28591);$windows1252=[Text.Encoding]::GetEncoding(1252)
# Built from code points so this file reads the same in any editor encoding.
$dash=[string][char]0x2014;$open=[string][char]0x201C;$close=[string][char]0x201D
$arabic=-join ([char[]]@(0x0627,0x0644,0x0646,0x0635,0x0020,0x0627,0x0644,0x0639,0x0631,0x0628,0x064A))
$cafe='Caf'+[char]0x00E9+' at 50 '+[char]0x00B0+'C; a lone '+[char]0x00C3+' stays'
function Body([string]$Name){"---`nname: $Name`ndescription: Encoding round trip`n---`nUse a blank model $dash keep ${open}quoted${close} text.`n$arabic`n$cafe`n"}
function Once([string]$Text,$Encoding){$Encoding.GetString($utf8.GetBytes($Text))}
function Skill([string]$Root,[string]$Name,[string]$Text){
 $folder=Join-Path $Root $Name
 New-Item -ItemType Directory (Join-Path $folder 'references') -Force|Out-Null
 [IO.File]::WriteAllBytes((Join-Path $folder 'SKILL.md'),$utf8.GetBytes($Text))
 [IO.File]::WriteAllBytes((Join-Path $folder 'references/notes.md'),$utf8.GetBytes($Text.Replace('name:','topic:')))
}
New-Item -ItemType Directory (Join-Path $repo '.agents/skills/revit'),$state -Force|Out-Null
Skill $extra 'clean-skill' (Body 'clean-skill')
Skill $extra 'twice-latin1-skill' (Once (Once (Body 'twice-latin1-skill') $latin1) $latin1)
Skill $extra 'once-windows1252-skill' (Once (Body 'once-windows1252-skill') $windows1252)
# An approved skill whose local copy was corrupted by a download is not proposed again.
Skill (Join-Path $repo '.agents/skills/revit') 'approved-skill' (Body 'approved-skill')
Skill $extra 'approved-skill' (Once (Once (Body 'approved-skill') $latin1) $latin1)
$secure=New-Object Security.SecureString;'test-placeholder'.ToCharArray()|ForEach-Object {$secure.AppendChar($_)}
@{service_url='https://skills.example.test';protected_token=(ConvertFrom-SecureString $secure)}|ConvertTo-Json|Set-Content (Join-Path $state 'service.json') -Encoding ASCII
# A hashtable, because the mock runs from inside the sync script's scope.
$captured=@{}
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 if($Uri -like '*/v1/submissions'){
  if($ContentType -ne 'application/json; charset=utf-8' -or $Body -isnot [byte[]]){throw 'Submission must be UTF-8 bytes labelled charset=utf-8'}
  $captured.body=$Body;return [pscustomobject]@{status='submitted_for_approval';pull_request='https://example.test/pull/1'}
 }
 [pscustomobject]@{commit='test';skills=@()}
}
try{
 $null=& (Join-Path $PSScriptRoot '../source/runtime/scripts/central-skill-sync.ps1') -RepositoryRoot $repo -StateRoot $state -AdditionalSkillRoots @($extra)
 if(-not $captured.body){throw 'Nothing was submitted'}
 # The collector copies files byte for byte.
 $candidate=Get-ChildItem $state -Recurse -Directory|Where-Object {$_.Name -like "clean-skill-*" -and $_.Parent.Name -eq "candidates"}
 if([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $candidate.FullName 'SKILL.md'))) -cne [Convert]::ToBase64String($utf8.GetBytes((Body 'clean-skill')))){throw 'Collector changed the bytes'}
 # The service decodes with fatal UTF-8, so the body must be valid UTF-8 and every file must round-trip.
 $payload=$utf8.GetString($captured.body)|ConvertFrom-Json
 $byName=@{};foreach($s in $payload.skills){$byName[$s.name]=$s.files}
 if($byName.ContainsKey('approved-skill')){throw 'Corrupted copy of an approved skill was submitted'}
 foreach($name in @('clean-skill','twice-latin1-skill','once-windows1252-skill')){
  if(-not $byName.ContainsKey($name)){throw "Missing $name"}
  $expected=Body $name
  foreach($pair in @(@('SKILL.md',$expected),@('references/notes.md',$expected.Replace('name:','topic:')))){
   $actual=[string]$byName[$name].($pair[0])
   if([Convert]::ToBase64String($utf8.GetBytes($actual)) -cne [Convert]::ToBase64String($utf8.GetBytes($pair[1]))){throw "$name/$($pair[0]) is not byte-exact: $actual"}
  }
 }
 if(@($payload.skills).Count -ne 3){throw ('Unexpected submissions: '+(@($payload.skills.name) -join ','))}
 'PASS: dashes, quotation marks and Arabic reach the service byte-exact; Latin-1 and Windows-1252 mojibake is repaired; repaired copies of approved skills are not resubmitted'
}
finally{$env:LOCALAPPDATA=$saved.local;$env:USERPROFILE=$saved.user;$env:CODEX_HOME=$saved.codex;Remove-Item $t -Recurse -Force}
