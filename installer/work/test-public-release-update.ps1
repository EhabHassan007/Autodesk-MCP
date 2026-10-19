[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$core = Join-Path $repositoryRoot 'installer\Setup-BimCad.ps1'
$testRoot = Join-Path $PSScriptRoot (".public-update-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$installationRoot = Join-Path $testRoot 'installed'
$testLocalAppData = Join-Path $testRoot 'localappdata'
$testTemporaryRoot = Join-Path $testRoot 'temp'
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
$expectedVersion = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()

function Get-Sha256Hex {
    param([string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

$expectedHash = Get-Sha256Hex -Path $PackagePath

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    New-Item -ItemType Directory -Path (Join-Path $installationRoot '.agents\skills\old'), (Join-Path $installationRoot 'skill-review'), (Join-Path $installationRoot 'team-candidates'), (Join-Path $installationRoot 'backups'), $testLocalAppData, $testTemporaryRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installationRoot 'VERSION') -Value '1.0.0-beta.0' -Encoding ASCII
    foreach ($name in @('skill-review', 'team-candidates', 'backups')) {
        Set-Content -LiteralPath (Join-Path $installationRoot "$name\preserve.txt") -Value $name -Encoding ASCII
    }

    $env:LOCALAPPDATA = $testLocalAppData
    $env:TEMP = $testTemporaryRoot
    $env:TMP = $testTemporaryRoot
    . $core -Action Status -RepositoryPath $installationRoot -ReleaseManifestUrl 'https://example.invalid/latest.json' -LibraryOnly
    $script:MockDownloadSource = (Resolve-Path -LiteralPath $PackagePath).Path
    function global:Invoke-WebRequest {
        param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
        Copy-Item -LiteralPath $script:MockDownloadSource -Destination $OutFile -Force
        [pscustomobject]@{ StatusCode = 200; Content = '' }
    }

    $release = [pscustomobject]@{
        Version = $expectedVersion
        DownloadUrl = 'https://example.invalid/release.zip'
        Sha256 = $expectedHash
    }
    $installed = Install-PublicRelease -Release $release
    Assert-True ((Get-Content -LiteralPath (Join-Path $installed 'VERSION') -Raw).Trim() -eq $expectedVersion) 'Installed VERSION does not match the release.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installed '.agents\skills') -PathType Container) 'Approved skills were not installed.'
    foreach ($name in @('skill-review', 'team-candidates', 'backups')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $installed "$name\preserve.txt") -PathType Leaf) "$name was not preserved."
    }
    $state = Get-Content -LiteralPath (Join-Path $testLocalAppData 'AutodeskMcpConnector\update-state.json') -Raw | ConvertFrom-Json
    Assert-True ($state.installed_version -eq $expectedVersion) 'Update state does not contain the installed release version.'
    Assert-True ($state.installed_sha256 -eq $expectedHash) 'Update state does not contain the verified SHA-256.'

    $badRelease = [pscustomobject]@{
        Version = $expectedVersion
        DownloadUrl = 'https://example.invalid/release.zip'
        Sha256 = ('0' * 64)
    }
    $rejected = $false
    try { $null = Install-PublicRelease -Release $badRelease }
    catch { $rejected = $_.Exception.Message -match 'checksum verification failed' }
    Assert-True $rejected 'A release with a wrong SHA-256 was not rejected.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installed 'VERSION') -Raw).Trim() -eq $expectedVersion) 'Checksum rejection changed the installed runtime.'

    Write-Output 'Public release update test passed: verified install, preserved local folders, and rejected a bad checksum.'
}
finally {
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
