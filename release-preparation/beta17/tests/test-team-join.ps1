$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('team-join-'+[guid]::NewGuid().ToString('N'))
$savedLocal=$env:LOCALAPPDATA
$runtime=Join-Path $PSScriptRoot '../source/runtime'
. (Join-Path $runtime 'installer/Setup-BimCad.ps1') -LibraryOnly
. (Join-Path $runtime 'installer/TeamJoinDialog.ps1')
$script:log=New-Object System.Collections.Generic.List[string]
function Write-Step {param([string]$Message) $script:log.Add($Message)}
function Logged([string]$Text){@($script:log|Where-Object {$_.Contains($Text)}).Count}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw ($Message+"`n"+($script:log -join "`n"))}}
# Stands in for the service's POST /v1/enroll. Globals because $script: would resolve to Setup-BimCad's scope.
$global:TeamJoinCalls=New-Object System.Collections.Generic.List[object]
$global:TeamJoinReply='ok'
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$UserAgent,$ContentType,$Body,$TimeoutSec)
 $global:TeamJoinCalls.Add([pscustomobject]@{Uri=$Uri;Auth=$Headers.Authorization;Agent=$UserAgent;Version=$Headers['X-Connector-Version'];Body=([Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json)})
 if($global:TeamJoinReply -eq 'offline'){throw (New-Object Net.WebException 'The remote name could not be resolved')}
 if($global:TeamJoinReply -match '^\d+$'){
  $ex=New-Object Exception 'HTTP error'
  $ex|Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=[int]$global:TeamJoinReply})
  throw $ex
 }
 [pscustomobject]@{device_id='0123456789abcdef0123456789abcdef';device_token=$global:TeamJoinToken}
}
$root=Join-Path $testRoot 'install';$RepositoryPath=$root
New-Item -ItemType Directory (Join-Path $root 'scripts'),(Join-Path $root 'installer') -Force|Out-Null
Copy-Item (Join-Path $runtime 'scripts/Initialize-SkillService.ps1') (Join-Path $root 'scripts')
'1.0.0-beta.17'|Set-Content (Join-Path $root 'VERSION')
$code='team-join-code-for-tests-'+[guid]::NewGuid().ToString('N')
$global:TeamJoinToken=([guid]::NewGuid().ToString('N'))*2
$joinFile=Join-Path $testRoot 'team-join.json'
@{service_url='https://skills.example.test/';join_code=$code}|ConvertTo-Json|Set-Content $joinFile
function Reset-State([string]$Name){$env:LOCALAPPDATA=Join-Path $testRoot $Name;New-Item -ItemType Directory $env:LOCALAPPDATA -Force|Out-Null;$script:log.Clear();$global:TeamJoinCalls.Clear();$global:TeamJoinReply='ok'}
$service={Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection/service.json'}
try{
 # Success: one request with the code and profile, token stored with DPAPI, nothing secret logged or left behind.
 Reset-State 'joined'
 $installedCopy=Join-Path $root 'installer/team-join.json'; Copy-Item $joinFile $installedCopy
 $status=Register-SkillServiceDevice -Root $root -Name ' Ahmed Ali ' -Email 'ahmed@example.com' -JoinConfigPath $joinFile
 Assert ($status -eq 'Enrolled') 'Join did not enroll'
 $call=$global:TeamJoinCalls[0]
 Assert ($global:TeamJoinCalls.Count -eq 1 -and $call.Uri -eq 'https://skills.example.test/v1/enroll' -and $call.Auth -eq ('Bearer '+$code)) 'Join request not sent to /v1/enroll with the code'
 Assert ($call.Agent -eq 'Autodesk-MCP-Connector/1.0.0-beta.17' -and $call.Version -eq '1.0.0-beta.17') 'Connector headers missing'
 Assert ($call.Body.name -eq 'Ahmed Ali' -and $call.Body.email -eq 'ahmed@example.com' -and $call.Body.pc_name -eq $env:COMPUTERNAME -and $call.Body.windows_user -eq $env:USERNAME) 'Profile not sent'
 $config=Get-Content (& $service) -Raw|ConvertFrom-Json
 Assert ($config.service_url -eq 'https://skills.example.test' -and $config.device_id -eq '0123456789abcdef0123456789abcdef') 'service.json not written'
 $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $config.protected_token))
 try{Assert ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -eq $global:TeamJoinToken) 'Token not protected for this user'}
 finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
 Assert ((Logged '[ENROLLMENT_OK]') -eq 1 -and (Logged '[ENROLLMENT_FILE_REMOVED]') -eq 1) 'Success not logged'
 $all=$script:log -join "`n"
 Assert (-not $all.Contains($code) -and -not $all.Contains($global:TeamJoinToken)) 'Join code or token written to the log'
 Assert (@(Get-ChildItem (Split-Path (& $service)) -Filter 'enrollment-*.json').Count -eq 0) 'Plaintext enrollment file left behind'
 Assert (-not (Test-Path $installedCopy)) 'Join code left in the permanent install'
 Assert (Test-Path $joinFile) 'The installer copy should be untouched'

 # Already enrolled: no request.
 $script:log.Clear();$global:TeamJoinCalls.Clear()
 Assert ((Register-SkillServiceDevice -Root $root -Name 'Ahmed' -Email 'a@example.com' -JoinConfigPath $joinFile) -eq 'AlreadyEnrolled' -and $global:TeamJoinCalls.Count -eq 0) 'Enrolled PC joined again'

 # Wrong code, offline, rate limit and missing join file: clear failure, install continues, nothing stored.
 foreach($case in @(@('403','not accepted'),@('offline','could not be reached'),@('429','Too many join attempts'))){
  Reset-State ('fail-'+$case[0]); $global:TeamJoinReply=$case[0]
  Assert ((Register-SkillServiceDevice -Root $root -Name 'Ahmed' -Email 'a@example.com' -JoinConfigPath $joinFile) -eq 'Failed') ('Accepted on '+$case[0])
  Assert (@($script:log|Where-Object {$_.Contains('[ENROLLMENT_FAILED]') -and $_.Contains($case[1])}).Count -eq 1) ('Failure not explained for '+$case[0])
  Assert (-not (Test-Path (& $service)) -and -not ($script:log -join "`n").Contains($code)) ('State or secret leaked for '+$case[0])
 }
 # Open joining: no join file means the built-in service address and no Authorization header at all.
 Reset-State 'no-file'
 Assert ((Register-SkillServiceDevice -Root $root -Name 'Ahmed' -Email 'a@example.com' -JoinConfigPath (Join-Path $testRoot 'absent.json')) -eq 'Enrolled') 'Join without a join file failed'
 Assert ($global:TeamJoinCalls.Count -eq 1 -and $global:TeamJoinCalls[0].Uri -eq ($script:TeamServiceUrl+'/v1/enroll') -and $null -eq $global:TeamJoinCalls[0].Auth) 'No-code join not sent to the built-in service without a code'
 Reset-State 'no-code'
 $noCodeFile=Join-Path $testRoot 'no-code.json'; @{service_url='https://skills.example.test'}|ConvertTo-Json|Set-Content $noCodeFile
 Assert ((Register-SkillServiceDevice -Root $root -Name 'Ahmed' -Email 'a@example.com' -JoinConfigPath $noCodeFile) -eq 'Enrolled' -and $null -eq $global:TeamJoinCalls[0].Auth) 'A join file without a code did not join, or sent an empty code'
 Reset-State 'bad-url'
 $badFile=Join-Path $testRoot 'bad.json'; @{service_url='http://skills.example.test';join_code=$code}|ConvertTo-Json|Set-Content $badFile
 Assert ((Register-SkillServiceDevice -Root $root -Name 'Ahmed' -Email 'a@example.com' -JoinConfigPath $badFile) -eq 'Failed' -and $global:TeamJoinCalls.Count -eq 0) 'Non-HTTPS join file used'

 # Dialog validation matches what the service accepts and what can be passed on the command line.
 foreach($ok in @('Ahmed Ali','Sara O''Neil','محمد')){Assert (Test-TeamJoinName $ok) "Valid name refused: $ok"}
 foreach($bad in @('','   ',('x'*81),'Ali "Boss"','Ali\','<b>x</b>',"a`tb")){Assert (-not (Test-TeamJoinName $bad)) "Invalid name accepted: $bad"}
 foreach($ok in @('ahmed@gmail.com','a.b+c@company.co.uk')){Assert (Test-TeamJoinEmail $ok) "Valid email refused: $ok"}
 foreach($bad in @('ahmed','ahmed@','@x.com','a b@x.com','a@x','a"b@x.com')){Assert (-not (Test-TeamJoinEmail $bad)) "Invalid email accepted: $bad"}
 $env:LOCALAPPDATA=Join-Path $testRoot 'dialog'; New-Item -ItemType Directory $env:LOCALAPPDATA -Force|Out-Null
 $payloadInstaller=Join-Path $testRoot 'payload-installer'; New-Item -ItemType Directory $payloadInstaller|Out-Null
 Assert (Test-TeamJoinRequired -PayloadInstaller $payloadInstaller) 'Dialog not offered on a PC that has not joined (no team code needed)'
 Copy-Item $joinFile (Join-Path $payloadInstaller 'team-join.json')
 Assert (Test-TeamJoinRequired -PayloadInstaller $payloadInstaller) 'Dialog not shown for an older team installer'
 New-Item -ItemType Directory (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection')|Out-Null;'{}'|Set-Content (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection/service.json')
 Assert (-not (Test-TeamJoinRequired -PayloadInstaller $payloadInstaller)) 'Dialog shown on an enrolled PC'

 # Wiring: the admin file wins in both installers, and Install only joins when the dialog was answered.
 $setup=Get-Content (Join-Path $runtime 'installer/Setup-BimCad.ps1') -Raw
 Assert ($setup.Contains('if ($JoinName -and $JoinEmail -and [string]::IsNullOrWhiteSpace($EnrollmentPath)) { $null = Register-SkillServiceDevice -Root $root }')) 'Install does not prefer the admin file'
 # The outer installer asks for details only without an admin file; the setup wizard passes them on.
 $wrapper=Get-Content (Join-Path $PSScriptRoot '../source/Support/Install-Autodesk-MCP-Connector.ps1') -Raw
 Assert ($wrapper.Contains('$askDetails = (-not $enrollmentFile) -and (Test-TeamJoinRequired -PayloadInstaller $payloadInstaller)')) 'Outer installer does not prefer the admin file'
 $wizard=Get-Content (Join-Path $runtime 'installer/SetupWizard.ps1') -Raw
 Assert ($wizard.Contains("'-JoinName', `$script:wizard.Join.Name, '-JoinEmail', `$script:wizard.Join.Email")) 'Setup wizard does not pass the join answers'
 $gui=Get-Content (Join-Path $runtime 'installer/BIM-CAD-Setup.ps1') -Raw
 Assert ($gui.Contains("Show-TeamJoinDialog -Owner `$form") -and $gui.Contains("'-JoinName', `$join.Name")) 'Setup window does not offer the join dialog'
 'PASS: team join needs no code, enrolls with DPAPI and secure cleanup, never logs an old code or the token, removes the installed join file, explains failures, and the dialog validates input'
}
finally{$env:LOCALAPPDATA=$savedLocal;Remove-Variable TeamJoinCalls,TeamJoinReply,TeamJoinToken -Scope Global -ErrorAction SilentlyContinue;Remove-Item $testRoot -Recurse -Force}
