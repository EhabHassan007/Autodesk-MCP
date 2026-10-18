[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$Version,
    [string]$PublicReleaseRepository = 'EhabHassan007/Autodesk-MCP-Releases'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Split-Path -Parent $repositoryRoot
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
}
if ($Version -cnotmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') {
    throw "Invalid package version: $Version"
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("autodesk-mcp-share-{0}" -f [Guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $temporaryRoot 'payload\Autodesk-MCP-Payload'
$shareRoot = Join-Path $temporaryRoot ("share\Autodesk-MCP-Connector-{0}" -f $Version)
$payloadArchive = Join-Path $shareRoot 'Autodesk-MCP-Payload.zip'
$outputArchive = Join-Path $OutputDirectory ("Autodesk-MCP-Connector-{0}.zip" -f $Version)
$manifestPath = Join-Path $OutputDirectory 'latest.json'

function Copy-RequiredItem {
    param([string]$RelativePath)

    $source = Join-Path $repositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source)) { throw "Required package item is missing: $source" }
    $destination = Join-Path $payloadRoot $RelativePath
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

New-Item -ItemType Directory -Path $payloadRoot, $shareRoot, $OutputDirectory -Force | Out-Null
try {
    foreach ($item in @(
        '.agents\skills',
        'installer',
        'src\autocad\autocad-bridge.ps1',
        'src\autodesk\autodesk-bridge.ps1',
        'src\revit\addin',
        'src\revit\build-revit-addin.ps1',
        'src\revit\revit-bridge.ps1',
        'scripts\autodesk-mcp-update-notifier.ps1',
        'scripts\collect-skills-for-review.ps1',
        'scripts\submit-team-knowledge.ps1',
        'scripts\sync-codex-skills.ps1',
        'scripts\validate-team-skill-intake.ps1',
        'README.md',
        'TESTING.md',
        'VERSION'
    )) {
        Copy-RequiredItem $item
    }

    Compress-Archive -LiteralPath $payloadRoot -DestinationPath $payloadArchive -CompressionLevel Optimal

    @'
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Autodesk-MCP-Connector.ps1" %*
if errorlevel 1 pause
endlocal
'@ | Set-Content -LiteralPath (Join-Path $shareRoot 'Start-Autodesk-MCP-Connector.cmd') -Encoding ASCII

    @'
[CmdletBinding()]
param([switch]$SmokeTest)

$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'Autodesk-MCP-Payload.zip'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("autodesk-mcp-install-{0}" -f [Guid]::NewGuid().ToString('N'))

try {
    if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) {
        throw "The installation payload is missing: $payload"
    }
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Expand-Archive -LiteralPath $payload -DestinationPath $temporaryRoot -Force
    $packageRoot = Join-Path $temporaryRoot 'Autodesk-MCP-Payload'
    $setup = Join-Path $packageRoot 'installer\BIM-CAD-Setup.ps1'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $packageRoot '.agents\skills') -PathType Container)) {
        throw 'The Autodesk MCP installation payload is invalid.'
    }

    $setupArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $setup)
    if ($SmokeTest) { $setupArguments += '-SmokeTest' }
    & powershell.exe @setupArguments
    if ($LASTEXITCODE -ne 0) { throw "Autodesk MCP Connector setup stopped with exit code $LASTEXITCODE." }
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Autodesk MCP Connector') | Out-Null
    exit 1
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedSystemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemporary.StartsWith($resolvedSystemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected temporary path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
'@ | Set-Content -LiteralPath (Join-Path $shareRoot 'Install-Autodesk-MCP-Connector.ps1') -Encoding UTF8

    @"
Autodesk MCP Connector $Version

1. Extract this ZIP completely.
2. Double-click Start-Autodesk-MCP-Connector.cmd.
3. Select Install / Repair.
4. Restart Revit, Codex, and Claude after installation.

Autodesk-MCP-Payload.zip is the internal runtime package. Keep it beside the two launcher files; you do not need to open it.
"@ | Set-Content -LiteralPath (Join-Path $shareRoot 'README-FIRST.txt') -Encoding UTF8

    if (Test-Path -LiteralPath $outputArchive -PathType Leaf) {
        Remove-Item -LiteralPath $outputArchive -Force
    }
    Compress-Archive -LiteralPath $shareRoot -DestinationPath $outputArchive -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $outputArchive -Algorithm SHA256).Hash
    $assetName = Split-Path -Leaf $outputArchive
    [ordered]@{
        schema_version = 1
        version = $Version
        download_url = "https://github.com/$PublicReleaseRepository/releases/download/v$Version/$assetName"
        sha256 = $hash
        published_at = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Output ([pscustomobject]@{
        Path = $outputArchive
        ManifestPath = $manifestPath
        Version = $Version
        VisibleFiles = 4
        Sha256 = $hash
    })
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedSystemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemporary.StartsWith($resolvedSystemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected temporary path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
