$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
# Builds a throwaway copy so the committed archives are never touched.
$t=Join-Path ([IO.Path]::GetTempPath()) ('team-build-'+[guid]::NewGuid().ToString('N'))
$copy=Join-Path $t 'beta17'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Entries([string]$Zip){$z=[IO.Compression.ZipFile]::OpenRead($Zip);try{@($z.Entries|ForEach-Object FullName)}finally{$z.Dispose()}}
function Read-Entry([string]$Zip,[string]$Name,[string]$Out){$z=[IO.Compression.ZipFile]::OpenRead($Zip);try{[IO.Compression.ZipFileExtensions]::ExtractToFile($z.GetEntry($Name),$Out)}finally{$z.Dispose()}}
try{
 New-Item -ItemType Directory $copy|Out-Null
 foreach($item in @('source','tests','build.py','build.ps1','RELEASE-NOTES.md')){Copy-Item (Join-Path $PSScriptRoot "../$item") $copy -Recurse}
 Assert ((Entries (Join-Path $PSScriptRoot '../source/Support/Autodesk-MCP-Payload.zip')) -notcontains 'Autodesk-MCP-Payload/installer/team-join.json') 'Committed payload contains a join code'
 $code='team-build-test-code-'+[guid]::NewGuid().ToString('N')
 $secure=ConvertTo-SecureString $code -AsPlainText -Force
 $out=@(& (Join-Path $copy 'build.ps1') -TeamJoinCode $secure)
 $v=(Get-Content (Join-Path $copy 'source/runtime/VERSION') -Raw).Trim()
 $public=Join-Path $copy "Autodesk-MCP-Connector-$v.zip";$team=Join-Path $copy "Autodesk-MCP-Connector-$v-TEAM.zip"
 Assert ((Test-Path $public) -and (Test-Path $team)) 'Both installers were not built'
 Assert (-not (($out -join "`n").Contains($code))) 'Build output printed the join code'
 # Public: neither the payload nor any release file holds the code.
 Assert ((Entries (Join-Path $copy 'source/Support/Autodesk-MCP-Payload.zip')) -notcontains 'Autodesk-MCP-Payload/installer/team-join.json') 'Public payload contains team-join.json'
 foreach($zip in @($public,(Join-Path $copy 'beta17-github-upload.zip'),(Join-Path $copy 'beta17-source-and-tests.zip'))){
  Assert (-not ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($zip)).Contains('team-join.json'))) "Public archive mentions team-join.json: $zip"
 }
 # Team: the payload inside carries the code and service address, and nothing else differs in its file list.
 Assert ((Entries $team) -join ',' -eq ((Entries $public) -join ',')) 'Team installer has a different file list'
 $teamPayload=Join-Path $t 'team-payload.zip';Read-Entry $team "Autodesk-MCP-Connector-$v/Support/Autodesk-MCP-Payload.zip" $teamPayload
 $publicEntries=Entries (Join-Path $copy 'source/Support/Autodesk-MCP-Payload.zip');$teamEntries=Entries $teamPayload
 Assert (@(Compare-Object $publicEntries $teamEntries).Count -eq 1 -and $teamEntries -contains 'Autodesk-MCP-Payload/installer/team-join.json') 'Team payload should differ only by team-join.json'
 $joinFile=Join-Path $t 'team-join.json';Read-Entry $teamPayload 'Autodesk-MCP-Payload/installer/team-join.json' $joinFile
 $join=Get-Content $joinFile -Raw|ConvertFrom-Json
 Assert ($join.join_code -eq $code -and $join.service_url -eq 'https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev') 'Team join file is wrong'
 # A stray join file in the source tree stops the build instead of leaking into the public payload.
 Copy-Item $joinFile (Join-Path $copy 'source/runtime/installer/team-join.json')
 $stopped=$false;try{$null=& (Join-Path $copy 'build.ps1')}catch{$stopped=$_.Exception.Message -like '*team-join.json*'}
 Assert $stopped 'A join file in source/runtime was not refused'
 Assert ((Get-Content (Join-Path $PSScriptRoot '../../.gitignore') -Raw).Contains('**/team-join.json')) 'team-join.json is not git-ignored'
 'PASS: public installer never holds a join code; TEAM installer differs only by its payload''s team-join.json; stray join files stop the build'
}
finally{Remove-Item $t -Recurse -Force}
