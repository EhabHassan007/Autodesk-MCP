$ErrorActionPreference='Stop'
# Smart Autodesk Connector: setup wizard parsing, terms record, update defaults and gate, agent decisions,
# add-in build cleanup, Skills Sync counts, legacy MCP entries and the Revit add-in build.
$t=Join-Path ([IO.Path]::GetTempPath()) ('smart-connector-'+[guid]::NewGuid().ToString('N'))
$savedLocal=$env:LOCALAPPDATA
$runtime=Join-Path $PSScriptRoot '../source/runtime'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
New-Item -ItemType Directory $t|Out-Null
$env:LOCALAPPDATA=Join-Path $t 'local'; New-Item -ItemType Directory $env:LOCALAPPDATA|Out-Null
try{
 # 1. Setup wizard: progress markers, quoting and the terms record.
 Add-Type -AssemblyName System.Windows.Forms, System.Drawing
 . (Join-Path $runtime 'installer/SetupWizard.ps1')
 $p=ConvertFrom-SetupOutputLine '[PHASE] revit'; Assert ($p.Step -eq 'revit' -and $p.Status -eq 'running') 'PHASE not parsed'
 $p=ConvertFrom-SetupOutputLine '[RESULT] codex=skipped Codex is not installed'; Assert ($p.Step -eq 'codex' -and $p.Status -eq 'skipped' -and $p.Detail -eq 'Codex is not installed') 'RESULT not parsed'
 $p=ConvertFrom-SetupOutputLine '[12:00:00] [ENROLLMENT_FAILED] The team join code was not accepted.'; Assert ($p.Step -eq 'team' -and $p.Status -eq 'failed' -and $p.Detail -like '*not accepted*') 'Enrollment failure not mapped'
 Assert ((ConvertFrom-SetupOutputLine '[12:00:00] [ENROLLMENT_OK] done').Status -eq 'ok') 'Enrollment OK not mapped'
 Assert ((ConvertFrom-SetupOutputLine '[12:00:00] [ENROLLMENT_PENDING] none').Status -eq 'skipped') 'Enrollment pending not mapped'
 Assert ($null -eq (ConvertFrom-SetupOutputLine '[12:00:00] Installing all saved skills for Codex...')) 'Ordinary line parsed as a marker'
 Assert ((ConvertTo-CommandLine @('-File','C:\Program Files\x\Setup.ps1','-JoinName','Ahmed Ali','')) -eq '-File "C:\Program Files\x\Setup.ps1" -JoinName "Ahmed Ali" ""') 'Command line quoting wrong'
 $terms=Get-TermsVersion (Join-Path $runtime 'installer/TERMS.txt'); Assert ($terms -match '^\d{4}-\d{2}-\d{2}$') "Terms version not read: $terms"
 Save-TermsAcceptance $terms
 $record=Get-Content (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector/terms-accepted.json') -Raw|ConvertFrom-Json
 Assert ($record.terms_version -eq $terms -and $record.accepted_utc) 'Terms acceptance not recorded'
 # Every marker the installer prints is one the wizard understands.
 $setupText=Get-Content (Join-Path $runtime 'installer/Setup-BimCad.ps1') -Raw
 foreach($step in $script:WizardSteps.Id){ if($step -ne 'team'){Assert ($setupText.Contains("Write-InstallPhase '$step'") -or $setupText.Contains("Invoke-InstallStep '$step'")) "Installer never starts step $step"} }
 Assert ((Get-Content (Join-Path $runtime 'installer/SetupWizard.ps1') -Encoding Byte -TotalCount 3) -join ',' -eq '239,187,191') 'SetupWizard.ps1 needs a UTF-8 BOM for Windows PowerShell 5.1'

 # 2. Installer core: auto-update default, user choice, update gate, old add-in builds, legacy entries.
 . (Join-Path $runtime 'installer/Setup-BimCad.ps1') -LibraryOnly
 function Write-Step {param($Message)}
 $state=Read-UpdateState; Assert ($state.notifications_enabled -eq $true -and $state.notifications_user_disabled -eq $false) 'Fresh install does not default to automatic updates'
 Set-InstalledRelease -Version '1.0.0-beta.18'
 Assert ((Read-UpdateState).notifications_enabled -eq $true) 'Recording the installed version turned automatic updates off'
 Disable-UpdateNotifications; $s=Read-UpdateState; Assert (-not $s.notifications_enabled -and $s.notifications_user_disabled) 'Turning updates off was not recorded as the user''s choice'
 Enable-UpdateNotifications; $s=Read-UpdateState; Assert ($s.notifications_enabled -and -not $s.notifications_user_disabled) 'Turning updates back on failed'
 Assert ((@(Get-RunningAutodeskApps)).Count -ge 0) 'Running-app check failed'
 Assert ($setupText -match "\[UPDATE_DEFERRED\]" -and $setupText.IndexOf('Get-RunningAutodeskApps', $setupText.IndexOf("'Update' {")) -gt 0) 'Update does not wait for Revit and AutoCAD'
 $bin=Join-Path $t 'bin'; New-Item -ItemType Directory $bin|Out-Null
 foreach($n in 'aaa','bbb','ccc'){ 'x'|Set-Content (Join-Path $bin "BimCadMcp.Revit.$n.dll") }
 'keep'|Set-Content (Join-Path $bin 'other.dll')
 Remove-OldRevitAddinBuilds -Directory $bin -Keep (Join-Path $bin 'BimCadMcp.Revit.bbb.dll')
 Assert ((@(Get-ChildItem $bin -Name) -join ',') -eq 'BimCadMcp.Revit.bbb.dll,other.dll') 'Old add-in builds not cleaned up correctly'
 Assert (Test-OwnConnectorEntry 'powershell.exe -File C:\Users\x\AppData\Local\BIM-CAD-MCP\src\autodesk\autodesk-bridge.ps1') 'Own connector entry not recognised'
 Assert (-not (Test-OwnConnectorEntry 'npx -y @someone/revit-mcp-server')) 'Another tool''s Revit MCP server would be removed'

 # 3. Agent decisions.
 . (Join-Path $runtime 'scripts/connector-agent.ps1') -LibraryOnly
 Assert ((Compare-AgentVersion '1.0.0-beta.18' '1.0.0-beta.17') -eq 1 -and (Compare-AgentVersion '1.0.0-beta.9' '1.0.0-beta.10') -eq -1) 'Numeric pre-release compare wrong'
 Assert ((Compare-AgentVersion '1.0.0' '1.0.0-beta.20') -eq 1 -and (Compare-AgentVersion 'v1.0.0-beta.18' '1.0.0-beta.18') -eq 0) 'Release/pre-release compare wrong'
 Assert ((Get-AgentDecision '1.0.0-beta.18' '1.0.0-beta.19' $true $false @()) -eq 'install') 'Ready update not installed when apps are closed'
 Assert ((Get-AgentDecision '1.0.0-beta.18' '1.0.0-beta.19' $true $false @('Revit')) -eq 'wait') 'Update would install under an open Revit'
 Assert ((Get-AgentDecision '1.0.0-beta.18' '1.0.0-beta.19' $false $false @()) -eq 'none') 'Update installed although automatic updates are off'
 Assert ((Get-AgentDecision '1.0.0-beta.18' '1.0.0-beta.19' $false $true @()) -eq 'install') '"Update now" ignored when automatic updates are off'
 Assert ((Get-AgentDecision '1.0.0-beta.18' '1.0.0-beta.18' $true $true @()) -eq 'none') 'Same version reinstalled'
 Assert ((Get-AgentDecision '1.0.0-beta.19' '1.0.0-beta.18' $true $false @()) -eq 'none') 'Downgrade attempted'
 Assert ((Get-AgentDecision '1.0.0-beta.18' '' $true $false @()) -eq 'none') 'Install attempted with no update known'
 $now=Get-Date
 Assert ((Test-CheckOnAppStart @('AutoCAD') $now.AddMinutes(-31) $now) -and -not (Test-CheckOnAppStart @('AutoCAD') $now.AddMinutes(-5) $now) -and -not (Test-CheckOnAppStart @() $now.AddHours(-5) $now)) 'Update check on app start wrong'
 Assert ((Get-AgentDecision '1.0.0-beta.21' '1.0.0' $true $false @()) -eq 'install' -and (Compare-AgentVersion '1.0.1' '1.0.0') -eq 1) 'Beta PCs would not move to 1.0.0'
 Assert ((@(Get-StartedApps @('Revit') @('Revit','AutoCAD')) -join ',') -eq 'AutoCAD' -and @(Get-StartedApps @('Revit') @()).Count -eq 0) 'App start detection wrong'
 foreach($pair in @(@('[UPDATE_INSTALLED] x','installed'),@('[UPDATE_DEFERRED] Revit is open','deferred'),@('[UPDATE_AVAILABLE] Version','available'),@('[UP_TO_DATE] ok','current'),@('error','unknown'))){
  Assert ((ConvertFrom-UpdateOutput $pair[0]) -eq $pair[1]) "Update output '$($pair[0])' misread"
 }

 # 4. Skills Sync counts from the approved-library install.
 . (Join-Path $runtime 'scripts/central-skill-sync.ps1') -RepositoryRoot (Join-Path $t 'repo') -StateRoot (Join-Path $t 'state') -LibraryOnly
 New-Item -ItemType Directory (Join-Path $t 'repo/.agents/skills'),(Join-Path $t 'state') -Force|Out-Null
 $lib={param($a,$b) ('{"commit":"c","skills":[{"name":"alpha","files":{"SKILL.md":"'+$a+'"}},{"name":"beta","files":{"SKILL.md":"'+$b+'"}}]}')|ConvertFrom-Json}
 $client=Join-Path $t 'client'
 $first=Install-ApprovedLibrary -Library (& $lib 'one' 'one') -State (Join-Path $t 'state') -Repository (Join-Path $t 'repo') -ClientRoots @($client)
 Assert ($first.total -eq 2 -and $first.added -eq 2) "First sync counts wrong: $($first|ConvertTo-Json -Compress)"
 Set-Content (Join-Path $client 'beta/SKILL.md') 'my own edit'
 $second=Install-ApprovedLibrary -Library (& $lib 'two' 'two') -State (Join-Path $t 'state') -Repository (Join-Path $t 'repo') -ClientRoots @($client) 3>$null
 Assert ($second.updated -eq 1 -and $second.preserved -eq 1 -and $second.added -eq 0) "Second sync counts wrong: $($second|ConvertTo-Json -Compress)"
 $third=Install-ApprovedLibrary -Library (& $lib 'two' 'two') -State (Join-Path $t 'state') -Repository (Join-Path $t 'repo') -ClientRoots @($client) 3>$null
 Assert ($third.current -eq 1 -and $third.preserved -eq 1) "Unchanged sync counts wrong: $($third|ConvertTo-Json -Compress)"

 # 4b. Uploads read skill files as plain text. Get-Content strings carry PSPath/PSDrive properties that
 #     Windows PowerShell 5.1 serialises recursively: one small skill became gigabytes and hung Skills Sync.
 $syncText=Get-Content (Join-Path $runtime 'scripts/central-skill-sync.ps1') -Raw
 $libraryText=Get-Content (Join-Path $runtime 'scripts/SkillLibrary.ps1') -Raw
 Assert ($syncText -match '\$files=Read-SkillText' -and $libraryText -match '\$files\[\$relative\] = Repair-Mojibake \(\[IO\.File\]::ReadAllText' -and $libraryText -notmatch '\$files\[\$relative\] = Get-Content') 'Skill files are not read as plain text for upload'
 $probe=Join-Path $t 'probe-skill'; New-Item -ItemType Directory $probe|Out-Null
 "---`nname: probe`n---`nhello"|Set-Content (Join-Path $probe 'SKILL.md')
 $files=@{}; foreach($file in Get-ChildItem $probe -File){ $files[$file.Name]=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8) }
 $body=@{skills=@(@{name='probe';files=$files})}|ConvertTo-Json -Depth 20 -Compress
 Assert ($body.Length -lt 500) "Upload body for a 30-byte skill is $($body.Length) characters"

 # 5. The Revit add-in compiles with the Windows compiler (skipped when Revit 2024 is not installed).
 if(Test-Path 'C:\Program Files\Autodesk\Revit 2024\RevitAPI.dll'){
  $out=Join-Path $t 'addin'
  $null=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $runtime 'src/revit/build-revit-addin.ps1') -RevitVersion 2024 -OutputPath $out
  Assert ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $out 'BimCadMcp.Revit.dll'))) 'Revit add-in did not compile'
  $addin='addin built'
 } else { $addin='add-in build skipped (no Revit 2024)' }
 $ui=Get-Content (Join-Path $runtime 'src/revit/addin/ConnectorUi.cs') -Raw
 foreach($c in 'CheckUpdatesCommand','SkillsSyncCommand','SettingsCommand','ConnectionStatusCommand'){Assert ($ui.Contains("typeof($c)")) "Ribbon lacks $c"}
 Assert ($ui.Contains('internal const string TabName = Brand.Name;') -and $ui.Contains('"Smart Autodesk Connector"')) 'Ribbon tab is not named Smart Autodesk Connector'
 "PASS: wizard markers, quoting and terms record; automatic updates on by default and only the user turns them off; updates wait for Revit/AutoCAD; old add-in builds removed; other tools' MCP servers kept; agent decisions; Skills Sync counts; $addin"
}
finally{$env:LOCALAPPDATA=$savedLocal;Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue}
