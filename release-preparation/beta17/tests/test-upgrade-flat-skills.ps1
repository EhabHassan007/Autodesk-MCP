$ErrorActionPreference='Stop'
# Upgrading a PC whose earlier install kept skills flat: setup replaces the shipped library instead of merging it,
# and the skill install ignores flat leftovers that are now in category folders.
$runtime=(Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$t=Join-Path ([IO.Path]::GetTempPath()) ('upgrade-flat-'+[guid]::NewGuid().ToString('N'))
$saved=@{local=$env:LOCALAPPDATA;user=$env:USERPROFILE;codex=$env:CODEX_HOME}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
 $env:LOCALAPPDATA=Join-Path $t 'local'; $env:USERPROFILE=Join-Path $t 'user'; $env:CODEX_HOME=Join-Path $t 'codex'
 New-Item -ItemType Directory $env:LOCALAPPDATA,$env:USERPROFILE,$env:CODEX_HOME -Force|Out-Null
 . (Join-Path $runtime 'installer/Setup-BimCad.ps1') -LibraryOnly
 . (Join-Path $runtime 'scripts/SkillLibrary.ps1')
 $shipped=@(Get-SkillFolders (Join-Path $runtime '.agents/skills'))

 # An earlier version installed here: every shipped skill flat, plus a file only that version had.
 $RepositoryPath=Join-Path $t 'installed'; $Action='Install'; $SkipRepositoryUpdate=$false
 foreach($skill in $shipped){ Copy-Item -LiteralPath $skill.Path -Destination (Join-Path $RepositoryPath ".agents/skills/$($skill.Name)") -Recurse -Force }
 Set-Content (Join-Path $RepositoryPath '.agents/skills/old-only.txt') 'left by an earlier version'
 $root=Get-Repository
 $after=@(Get-SkillFolders (Join-Path $root '.agents/skills'))
 Assert ($after.Count -eq $shipped.Count) "Upgrade left $($after.Count) skills for $($shipped.Count) shipped"
 Assert (-not @($after|Where-Object {-not $_.Category}).Count) 'Flat skills from the earlier version survived the upgrade'
 Assert (-not (Test-Path (Join-Path $root '.agents/skills/old-only.txt'))) 'The shipped library was merged, not replaced'

 # A library that still has flat leftovers next to category folders installs once per skill.
 $lib=Join-Path $t 'leftover'
 New-Item -ItemType Directory (Join-Path $lib 'scripts') -Force|Out-Null
 Copy-Item (Join-Path $runtime 'scripts/sync-codex-skills.ps1'),(Join-Path $runtime 'scripts/SkillLibrary.ps1') (Join-Path $lib 'scripts')
 Copy-Item (Join-Path $runtime '.agents') (Join-Path $lib '.agents') -Recurse
 foreach($skill in $shipped | Select-Object -First 5){ Copy-Item -LiteralPath $skill.Path -Destination (Join-Path $lib ".agents/skills/$($skill.Name)") -Recurse -Force }
 $dest=Join-Path $t 'claude'
 $previous=$ErrorActionPreference; $ErrorActionPreference='Continue'
 $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $lib 'scripts/sync-codex-skills.ps1') -Action Install -Destination $dest 2>&1 | ForEach-Object { "$_" }
 $code=$LASTEXITCODE; $ErrorActionPreference=$previous
 Assert ($code -eq 0) "Install failed with flat leftovers: $($output -join ' ')"
 Assert (@(Get-ChildItem $dest -Directory).Count -eq $shipped.Count) 'Skills not installed exactly once each'
 Assert (($output -join ' ') -match 'Ignoring 5 older flat skill copies') 'Flat leftovers were not reported'
 "PASS: upgrading over a flat install replaces the shipped library ($($shipped.Count) skills, no leftovers); flat leftovers beside category folders are ignored and each skill installs once"
}
finally{$env:LOCALAPPDATA=$saved.local;$env:USERPROFILE=$saved.user;$env:CODEX_HOME=$saved.codex;Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue}
