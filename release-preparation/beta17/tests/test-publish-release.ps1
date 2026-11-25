# publish-release.ps1 against a stand-in gh: the check mode passes on a correct build and writes the release notes,
# and refuses a ZIP whose SHA-256 does not match its manifest, a TEAM file, and a version that is already published.
# Nothing is published and no network or GitHub account is needed (the script's update-check read fails quietly).
$ErrorActionPreference = 'Stop'
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$beta17 = Split-Path -Parent $PSScriptRoot
$script = Join-Path $beta17 'publish-release.ps1'
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
Assert (-not $errors) ('publish-release.ps1 does not parse: ' + ($errors | Out-String))

$work = Join-Path $env:TEMP ('publish-test-' + [guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $work 'bin'; $fixture = Join-Path $work 'artifact'
$null = New-Item -ItemType Directory -Path $fakeBin, $fixture -Force
$version = '9.8.7'
$repo = 'EhabHassan007/Autodesk-MCP-Releases'

# The stand-in gh: answers the calls publish-release.ps1 makes; 'run download' copies the fixture; 'release create' fails
# the test, because check mode must never publish. GH_TEST_EXISTING=1 makes 'release view' find the tag.
Set-Content -LiteralPath (Join-Path $fakeBin 'gh.cmd') -Value '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh.ps1" %*' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $fakeBin 'gh.ps1') -Encoding UTF8 -Value @'
$a = @($args)
$joined = $a -join ' '
switch -Wildcard ($joined) {
    'auth status*' { [Console]::Error.WriteLine('Logged in (stand-in)'); exit 0 }
    'api repos/*/commits/main*' { 'abcdef1234567890'; exit 0 }
    'run list*' { '[{"databaseId":11,"name":"Build setup exe","status":"completed","conclusion":"success","event":"push","workflowName":"Build setup exe"},{"databaseId":12,"name":"Connector tests (Windows)","status":"completed","conclusion":"success","event":"push","workflowName":"Connector tests (Windows)"}]'; exit 0 }
    'run download*' {
        $dir = $a[[array]::IndexOf($a, '-D') + 1]
        Copy-Item -Path (Join-Path $env:GH_TEST_FIXTURE '*') -Destination $dir -Recurse -Force
        exit 0
    }
    'repo view*' { 'PUBLIC'; exit 0 }
    'release view*' { if ($env:GH_TEST_EXISTING -eq '1') { '{"tagName":"v9.8.7"}'; exit 0 } else { [Console]::Error.WriteLine('release not found'); exit 1 } }
    'release create*' { Set-Content -LiteralPath $env:GH_TEST_PUBLISHED -Value $joined; exit 0 }
    default { [Console]::Error.WriteLine("stand-in gh: unexpected call: $joined"); exit 2 }
}
'@

function New-Zip([string]$Path, [hashtable]$Entries) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries.Keys) {
            $writer = New-Object IO.StreamWriter(($archive.CreateEntry($name)).Open())
            try { $writer.Write($Entries[$name]) } finally { $writer.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}
function Write-Manifest([string]$Name, [string]$Zip) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $fixture $Zip) -Algorithm SHA256).Hash
    $json = '{"schema_version":1,"version":"' + $version + '","download_url":"https://github.com/' + $repo + '/releases/download/v' + $version + '/' + $Zip + '","sha256":"' + $hash + '"}'
    [IO.File]::WriteAllText((Join-Path $fixture $Name), $json)
}
function New-Fixture {
    Get-ChildItem -LiteralPath $fixture | Remove-Item -Recurse -Force
    New-Zip (Join-Path $fixture "Autodesk-MCP-Connector-$version.zip") @{ 'Autodesk-MCP-Connector/README.txt' = 'connector' }
    New-Zip (Join-Path $fixture "Smart-Connector-$version.zip") @{ 'Smart-Connector/VERSION' = $version }
    [IO.File]::WriteAllText((Join-Path $fixture "Smart-Connector-Setup-$version.exe"), 'MZ stand-in setup')
    Write-Manifest 'latest.json' "Autodesk-MCP-Connector-$version.zip"
    Write-Manifest 'smart-connector.json' "Smart-Connector-$version.zip"
    [IO.File]::WriteAllText((Join-Path $fixture 'RELEASE-NOTES.md'), "Smart Connector for Autodesk Revit and AutoCAD $version`n`nNew in ${version}:`n- the change`n`nSmart Connector for Autodesk Revit and AutoCAD 9.8.6`n`n- older`n`nSHA-256: OLD`n")
}
function Invoke-Publish {
    $out = Join-Path $work ('out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $process = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Version', $version, '-WorkDirectory', (Join-Path $work 'publish'))
    [pscustomobject]@{ Code = $process.ExitCode; Text = [string](Get-Content -LiteralPath $out -Raw) }
}

$oldPath = $env:PATH
try {
    $env:PATH = $fakeBin + ';' + $env:PATH
    $env:GH_TEST_FIXTURE = $fixture
    $env:GH_TEST_PUBLISHED = Join-Path $work 'published.txt'
    $env:GH_TEST_EXISTING = '0'

    New-Fixture
    $ok = Invoke-Publish
    Assert ($ok.Code -eq 0) ("check mode must pass on a correct build (exit $($ok.Code)): $($ok.Text)")
    Assert ($ok.Text -like '*Nothing was published*') 'check mode must say that nothing was published'
    Assert (-not (Test-Path -LiteralPath $env:GH_TEST_PUBLISHED)) 'check mode must never create a release'
    $notes = [IO.File]::ReadAllText((Join-Path $work "publish\release-notes-$version.md"))
    Assert ($notes -like '*- the change*' -and $notes -notlike '*older*' -and $notes -notlike '*SHA-256: OLD*') ("the release notes must hold only this version's section: $notes")
    Assert ($notes -like "*Smart-Connector-Setup-$version.exe: *") 'the release notes must list the SHA-256 of the published files'
    'PASS: check mode verifies a correct build, writes only this version''s notes with the SHA-256 values, and publishes nothing'

    New-Fixture
    New-Zip (Join-Path $fixture "Smart-Connector-$version.zip") @{ 'Smart-Connector/VERSION' = 'changed after the manifest' }
    $bad = Invoke-Publish
    Assert ($bad.Code -ne 0 -and $bad.Text -like '*does not match smart-connector.json*') ("a ZIP that does not match its manifest must be refused: $($bad.Text)")

    New-Fixture
    [IO.File]::WriteAllText((Join-Path $fixture "Smart-Connector-Setup-$version-TEAM.exe"), 'team')
    $team = Invoke-Publish
    Assert ($team.Code -ne 0 -and $team.Text -like '*TEAM file*') ("a TEAM file must be refused: $($team.Text)")

    New-Fixture
    New-Zip (Join-Path $fixture "Smart-Connector-$version.zip") @{ 'Smart-Connector/installer/team-join.json' = '{"code":"x"}' }
    Write-Manifest 'smart-connector.json' "Smart-Connector-$version.zip"
    $join = Invoke-Publish
    Assert ($join.Code -ne 0 -and $join.Text -like '*team join code*') ("a ZIP holding team-join.json must be refused: $($join.Text)")

    New-Fixture
    $env:GH_TEST_EXISTING = '1'
    $again = Invoke-Publish
    Assert ($again.Code -ne 0 -and $again.Text -like '*already has a release*') ("a version that is already published must be refused: $($again.Text)")
    Assert (-not (Test-Path -LiteralPath $env:GH_TEST_PUBLISHED)) 'a refused check must never create a release'
    'PASS: a mismatched SHA-256, a TEAM file, a team join code and an already published version are refused'
}
finally {
    $env:PATH = $oldPath
    Remove-Item Env:GH_TEST_FIXTURE, Env:GH_TEST_PUBLISHED, Env:GH_TEST_EXISTING -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
