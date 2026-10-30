$ErrorActionPreference='Stop'
$scripts=(Join-Path $PSScriptRoot '../source/runtime/scripts')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('weekly-pr-test-'+[guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA=Join-Path $testRoot 'local';$env:USERPROFILE=Join-Path $testRoot 'user'
$repo=Join-Path $testRoot 'repo';$state=Join-Path $testRoot 'state';$candidates=Join-Path $repo 'team-candidates'
New-Item -ItemType Directory (Join-Path $repo '.agents/skills'),(Join-Path $candidates 'new-skill') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $candidates 'new-skill/SKILL.md'),"---`nname: new-skill`ndescription: a safe test`n---`nUse a blank test model.")
$submit=Join-Path $scripts 'submit-team-knowledge.ps1'
. $submit -RepositoryRoot $repo -StateRoot $state -CandidateRoot $candidates -LibraryOnly
$script:remoteExists=$false;$script:failPR=$true;$script:pushes=@();$script:requests=@();$script:identities=@()
function Get-RequiredCommand { 'Mock-Git' }
function Mock-Git {
 $a=@($args)
 if($a[0] -eq 'credential'){'username=test';'password=test-placeholder';$global:LASTEXITCODE=0;return}
 if($a -contains 'config'){if($a -contains '--global'){throw 'Do not require global identity'};if($a -contains '--local'){$script:identities+=($a -join ' ')}}
 elseif($a -contains 'clone'){New-Item -ItemType Directory $a[-1] -Force|Out-Null}
 elseif($a -contains 'ls-remote'){if($script:remoteExists){'fakehash refs/heads/existing'}}
 elseif($a -contains 'diff'){$global:LASTEXITCODE=1;return}
 elseif($a -contains 'push'){$script:remoteExists=$true;$script:pushes+=$a[-1]}
 elseif($a -contains 'merge'){throw 'Never merge automatically'}
 $global:LASTEXITCODE=0
}
function Invoke-RestMethod {
 param($Method,$Uri,$Headers,$ContentType,$Body)
 $script:requests+="$Method $Uri"
 if($Uri -eq 'https://api.github.com/user'){return [pscustomobject]@{login='test-user';id=12345}}
 if($Method -eq 'Get'){return @()}
 if($Uri -match '/requested_reviewers$'){return @{}}
 if($script:failPR){throw 'Simulated GitHub outage after push'}
 $p=$Body|ConvertFrom-Json
 if(-not $p.draft -or $p.base -ne 'main'){throw 'PR must be draft against main'}
 if($p.head -notlike 'skill-intake/*'){throw 'Unexpected head branch'}
 [pscustomobject]@{html_url='https://github.com/example/test/pull/1';number=1}
}
$source=Get-Content $submit -Raw
$main=[scriptblock]::Create($source.Substring($source.IndexOf('$collector =')).Replace('$PSScriptRoot','$scripts'))
try {
 $failed=$false
 try{& $main|Out-Null}catch{if($_.Exception.Message -notmatch 'Simulated GitHub outage'){throw};$failed=$true}
 if(-not $failed -or (Test-Path (Join-Path $state 'submitted-hashes.json'))){throw 'Failed submission advanced ledger'}
 $script:failPR=$false
 $result=((& $main) -join "`n")|ConvertFrom-Json
 if($result.status -ne 'submitted_for_approval'){throw 'No PR result'}
 if($script:pushes.Count -ne 2 -or $script:pushes[0] -ne $script:pushes[1]){throw 'Retry created a different branch'}
 $ledger=Get-Content (Join-Path $state 'submitted-hashes.json') -Raw|ConvertFrom-Json
 if(@($ledger.PSObject.Properties).Count -ne 1){throw 'Wrong ledger count'}
 if(-not ($script:identities -match 'config --local user.email 12345\+test-user@users.noreply.github.com')){throw 'No automatic account identity'}
 'PASS: automatic private GitHub author identity without global configuration; failed PR leaves ledger unchanged; retry reuses branch; creates draft PR and requests owner review; successful PR records hash'
}
finally {Remove-Item $testRoot -Recurse -Force}
