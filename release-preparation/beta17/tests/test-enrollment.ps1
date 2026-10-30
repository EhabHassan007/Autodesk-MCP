$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('enrollment-'+[guid]::NewGuid().ToString('N'))
$savedLocal=$env:LOCALAPPDATA
$runtime=Join-Path $PSScriptRoot '../source/runtime'
. (Join-Path $runtime 'installer/Setup-BimCad.ps1') -LibraryOnly
# Capture setup log lines instead of writing them to the console.
$script:log=New-Object System.Collections.Generic.List[string]
function Write-Step {param([string]$Message) $script:log.Add($Message)}
$root=Join-Path $testRoot 'install';$deploy=Join-Path $testRoot 'deploy'
New-Item -ItemType Directory (Join-Path $root 'scripts'),$deploy -Force|Out-Null
Copy-Item (Join-Path $runtime 'scripts/Initialize-SkillService.ps1') (Join-Path $root 'scripts')
$token=([guid]::NewGuid().ToString('N'))*2
function Reset-State([string]$Name){$env:LOCALAPPDATA=Join-Path $testRoot $Name;New-Item -ItemType Directory $env:LOCALAPPDATA -Force|Out-Null;$script:log.Clear()}
function Write-Enrollment([string]$Name,[string]$Text){$path=Join-Path $deploy $Name;[IO.File]::WriteAllText($path,$Text);$path}
function Valid([string]$Secret){@{service_url='https://skills.example.test';device_id='0123456789abcdef0123456789abcdef';device_token=$Secret}|ConvertTo-Json}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw ($Message+"`n"+($script:log -join "`n"))}}
# Literal match: the [TAG] brackets would be a character class under -like.
function Logged([string]$Text){@($script:log|Where-Object {$_.Contains($Text)}).Count}
$service={Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection/service.json'}
try{
 # Present: enrollment.json beside the installer is imported, encrypted and securely removed.
 Reset-State 'present'
 $file=Write-Enrollment 'enrollment.json' (Valid $token)
 $status=Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)
 Assert ($status -eq 'Enrolled') 'Valid enrollment was not imported'
 Assert (-not (Test-Path $file)) 'Plaintext enrollment file was left on disk'
 $config=Get-Content (& $service) -Raw|ConvertFrom-Json
 Assert ($config.service_url -eq 'https://skills.example.test' -and -not ((Get-Content (& $service) -Raw).Contains($token))) 'service.json is wrong or holds the plaintext token'
 $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $config.protected_token))
 try{Assert ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -eq $token) 'Protected token does not decrypt for this user'}
 finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
 Assert ((Logged '[ENROLLMENT_OK]') -eq 1 -and (Logged '[ENROLLMENT_FILE_REMOVED]') -eq 1) 'Success was not logged'
 Assert (-not (($script:log -join "`n").Contains($token))) 'Token written to the setup log'

 # Present via the documented legacy name and an explicit -EnrollmentPath.
 Reset-State 'legacy'
 $null=Write-Enrollment 'skill-service-device.json' (Valid $token)
 Assert ((Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)) -eq 'Enrolled') 'Legacy file name not imported'
 Reset-State 'explicit'
 $file=Write-Enrollment 'pc-07.json' (Valid $token)
 Assert ((Import-SkillServiceEnrollment -Root $root -Path $file -SearchDirectories @()) -eq 'Enrolled') 'Explicit -EnrollmentPath not imported'
 Assert (-not (Test-Path $file)) 'Explicit enrollment file was left on disk'

 # Missing: setup reports pending and creates nothing.
 Reset-State 'missing'
 Assert ((Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)) -eq 'Missing') 'Missing file not reported'
 Assert ((Logged '[ENROLLMENT_PENDING]') -eq 1 -and -not (Test-Path (& $service))) 'Pending state not logged'
 $script:log.Clear()
 Assert ((Import-SkillServiceEnrollment -Root $root -Path (Join-Path $deploy 'absent.json') -SearchDirectories @()) -eq 'Missing') 'Missing explicit file not reported'
 Assert ((Logged '[ENROLLMENT_MISSING]') -eq 1) 'Missing explicit path not logged'
 Reset-State 'kept'
 $null=Write-Enrollment 'enrollment.json' (Valid $token)
 $null=Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)
 Assert ((Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)) -eq 'AlreadyEnrolled') 'Existing enrollment not reported'

 # Invalid token: failure is logged, setup continues, and the plaintext file is still removed.
 Reset-State 'invalid-token'
 $file=Write-Enrollment 'enrollment.json' (Valid 'short')
 Assert ((Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)) -eq 'Failed') 'Invalid token accepted'
 Assert (@($script:log|Where-Object {$_.Contains('[ENROLLMENT_FAILED]') -and $_.Contains('Invalid device enrollment token')}).Count -eq 1) 'Invalid token failure not logged'
 Assert (-not (Test-Path $file) -and -not (Test-Path (& $service))) 'Invalid token left a file or created service.json'

 # Invalid JSON: the parser error must not copy the secret into setup.log.
 Reset-State 'invalid-json'
 $file=Write-Enrollment 'enrollment.json' ('{"device_token":"'+$token+'" broken')
 Assert ((Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)) -eq 'Failed') 'Malformed JSON accepted'
 Assert (-not (($script:log -join "`n").Contains($token))) 'Malformed file leaked its token into the log'
 Assert (-not (Test-Path $file)) 'Malformed enrollment file was left on disk'

 # Invalid replacement does not overwrite a working enrollment.
 Reset-State 'invalid-replacement'
 $null=Write-Enrollment 'enrollment.json' (Valid $token)
 $null=Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)
 $before=Get-Content (& $service) -Raw
 $null=Write-Enrollment 'enrollment.json' (Valid 'short')
 Assert ((Import-SkillServiceEnrollment -Root $root -Path '' -SearchDirectories @($deploy)) -eq 'Failed') 'Invalid replacement accepted'
 Assert ((Get-Content (& $service) -Raw) -eq $before) 'Invalid replacement changed service.json'

 # The outer installer hands deployed files to Setup-BimCad.ps1 instead of importing them itself.
 $wrapper=Get-Content (Join-Path $PSScriptRoot '../source/Support/Install-Autodesk-MCP-Connector.ps1') -Raw
 Assert ($wrapper.Contains("'-EnrollmentPath'") -and $wrapper.Contains("'enrollment.json'") -and -not $wrapper.Contains('Initialize-SkillService')) 'Outer installer does not pass enrollment to setup'
 'PASS: enrollment imported, encrypted and securely removed; missing and invalid files reported in setup.log without leaking the token'
}
finally{$env:LOCALAPPDATA=$savedLocal;Remove-Item $testRoot -Recurse -Force}
