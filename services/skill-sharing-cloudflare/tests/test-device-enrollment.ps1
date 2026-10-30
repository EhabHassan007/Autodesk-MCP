$ErrorActionPreference='Stop'
$t=Join-Path ([IO.Path]::GetTempPath()) ('device-enrollment-'+[guid]::NewGuid().ToString('N'))
$tool=Join-Path $PSScriptRoot '../tools/New-DeviceEnrollment.ps1'
$initializer=Join-Path $PSScriptRoot '../../../release-preparation/beta17/source/runtime/scripts/Initialize-SkillService.ps1'
$savedLocal=$env:LOCALAPPDATA
$admin=('a'*40)
$secure=ConvertTo-SecureString $admin -AsPlainText -Force
$global:DeviceEnrollmentCalls=New-Object System.Collections.Generic.List[object]
$global:DeviceEnrollmentRefuse=''
# Stands in for the Worker's POST /admin/devices; the tool resolves this before the cmdlet.
# Globals because $script: inside the mock would resolve to the tool's scope.
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 $label=($Body|ConvertFrom-Json).label
 $global:DeviceEnrollmentCalls.Add([pscustomobject]@{Uri=$Uri;Method=$Method;Auth=$Headers.Authorization;Agent=$Headers['User-Agent'];Label=$label})
 if($label -eq $global:DeviceEnrollmentRefuse){throw 'simulated refusal'}
 [pscustomobject]@{device_id=[guid]::NewGuid().ToString('N');device_token=('T'+[guid]::NewGuid().ToString('N')*2)}
}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
 # Two PCs in one run: one folder each, a token-free register, and files setup can import.
 $out=Join-Path $t 'out'
 & $tool -Label 'Office-PC-01','Office-PC-02' -OutputDirectory $out -AdminToken $secure 6>$null
 Assert ($global:DeviceEnrollmentCalls.Count -eq 2) 'Expected one service call per PC'
 Assert (@($global:DeviceEnrollmentCalls|Where-Object {$_.Uri -eq 'https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev/admin/devices' -and $_.Method -eq 'Post' -and $_.Auth -eq ('Bearer '+$admin) -and $_.Agent -like 'Autodesk-MCP-Connector/*'}).Count -eq 2) 'Service call was not authenticated correctly'
 $files=@(Get-ChildItem $out -Recurse -Filter enrollment.json)
 Assert ($files.Count -eq 2) 'Expected two enrollment files'
 $register=Get-Content (Join-Path $out 'devices.csv') -Raw
 foreach($f in $files){
  $data=Get-Content $f.FullName -Raw|ConvertFrom-Json
  Assert ($register.Contains($data.device_id) -and -not $register.Contains($data.device_token)) 'Register missing a device or holding a token'
 }
 Assert (-not $register.Contains($admin)) 'Register holds the admin token'
 $acl=Get-Acl -LiteralPath $out
 Assert ($acl.AreAccessRulesProtected -and @($acl.Access).Count -eq 1 -and $acl.Access[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 'Output folder is readable by others'
 $env:LOCALAPPDATA=Join-Path $t 'local'
 $null=& $initializer -ConfigPath $files[0].FullName
 Assert (Test-Path (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection/service.json')) 'Setup initializer rejected the generated file'

 # Existing files are never overwritten, and nothing is requested.
 $global:DeviceEnrollmentCalls.Clear()
 $failed=$false;try{& $tool -Label 'Office-PC-01' -OutputDirectory $out -AdminToken $secure 6>$null}catch{$failed=$_.Exception.Message -like '*already exists*'}
 Assert ($failed -and $global:DeviceEnrollmentCalls.Count -eq 0) 'Existing enrollment file was not protected'

 # Unsafe and duplicate labels are rejected before any request.
 foreach($bad in @(@('..\escape'),@('PC 01'),@('Same','same'))){
  $failed=$false;try{& $tool -Label $bad -OutputDirectory (Join-Path $t 'bad') -AdminToken $secure 6>$null}catch{$failed=$true}
  Assert ($failed -and $global:DeviceEnrollmentCalls.Count -eq 0) ("Label accepted: "+($bad -join ','))
 }

 # A refusal stops the batch, names the PC, and keeps enrollments already created.
 $global:DeviceEnrollmentRefuse='Office-PC-04'
 $out2=Join-Path $t 'out2'
 $message='';try{& $tool -Label 'Office-PC-03','Office-PC-04','Office-PC-05' -OutputDirectory $out2 -AdminToken $secure 6>$null}catch{$message=$_.Exception.Message}
 Assert ($message -like "*'Office-PC-04'*" -and -not $message.Contains($admin)) 'Refusal not reported clearly'
 Assert ((Test-Path (Join-Path $out2 'Office-PC-03/enrollment.json')) -and -not (Test-Path (Join-Path $out2 'Office-PC-05'))) 'Batch did not stop at the refused PC'
 Assert ((Get-Content (Join-Path $out2 'devices.csv') -Raw).Contains('Office-PC-03')) 'Created device missing from register after refusal'
 'PASS: per-PC enrollment files created for setup, restricted to this user; register has no tokens; bad labels, reuse and refusals handled'
}
finally{$env:LOCALAPPDATA=$savedLocal;Remove-Variable DeviceEnrollmentCalls,DeviceEnrollmentRefuse -Scope Global -ErrorAction SilentlyContinue;Remove-Item $t -Recurse -Force}
