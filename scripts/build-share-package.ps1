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
$supportRoot = Join-Path $shareRoot 'Support'
$payloadArchive = Join-Path $supportRoot 'Autodesk-MCP-Payload.zip'
$outputArchive = Join-Path $OutputDirectory ("Autodesk-MCP-Connector-{0}.zip" -f $Version)
$manifestPath = Join-Path $OutputDirectory 'latest.json'

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

function Copy-RequiredItem {
    param([string]$RelativePath)

    $source = Join-Path $repositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source)) { throw "Required package item is missing: $source" }
    $destination = Join-Path $payloadRoot $RelativePath
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

New-Item -ItemType Directory -Path $payloadRoot, $shareRoot, $supportRoot, $OutputDirectory -Force | Out-Null
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
    $claudeSkillArchive = Join-Path $shareRoot 'Autodesk MCP Skills for Claude.zip'
    $claudeSkillBuilder = Join-Path $repositoryRoot 'scripts\build-claude-skill-package.ps1'
    $null = & $claudeSkillBuilder -RepositoryRoot $repositoryRoot -OutputPath $claudeSkillArchive

    @'
@echo off
setlocal
title Autodesk MCP Connector Setup
echo Starting Autodesk MCP Connector setup...
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Support\Install-Autodesk-MCP-Connector.ps1" -Install %*
if errorlevel 1 (
    echo.
    echo Setup stopped. See %%LOCALAPPDATA%%\AutodeskMcpConnector\setup.log
    pause
)
endlocal
'@ | Set-Content -LiteralPath (Join-Path $shareRoot 'INSTALL Autodesk MCP Connector.cmd') -Encoding ASCII

    @'
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$payload = Join-Path $PSScriptRoot 'Autodesk-MCP-Payload.zip'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("autodesk-mcp-install-{0}" -f [Guid]::NewGuid().ToString('N'))
$logDirectory = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
$logPath = Join-Path $logDirectory 'setup.log'

function Show-SetupMessage {
    param(
        [string]$Message,
        [System.Windows.Forms.MessageBoxIcon]$Icon
    )

    $owner = New-Object System.Windows.Forms.Form
    $owner.ShowInTaskbar = $false
    $owner.TopMost = $true
    $owner.StartPosition = 'CenterScreen'
    $owner.Size = New-Object System.Drawing.Size(1, 1)
    $owner.Opacity = 0
    try {
        $owner.Show()
        $owner.Activate()
        [System.Windows.Forms.MessageBox]::Show(
            $owner, $Message, 'Autodesk MCP Connector',
            [System.Windows.Forms.MessageBoxButtons]::OK, $Icon
        ) | Out-Null
    }
    finally {
        $owner.Close()
        $owner.Dispose()
    }
}

try {
    if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) {
        throw "The installation payload is missing: $payload"
    }
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Expand-Archive -LiteralPath $payload -DestinationPath $temporaryRoot -Force
    $packageRoot = Join-Path $temporaryRoot 'Autodesk-MCP-Payload'
    $setup = Join-Path $packageRoot 'installer\BIM-CAD-Setup.ps1'
    $coreSetup = Join-Path $packageRoot 'installer\Setup-BimCad.ps1'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf) -or
        -not (Test-Path -LiteralPath $coreSetup -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $packageRoot '.agents\skills') -PathType Container)) {
        throw 'The Autodesk MCP installation payload is invalid.'
    }

    if ($SmokeTest) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $setup -SmokeTest
        if ($LASTEXITCODE -ne 0) { throw "Autodesk MCP Connector smoke test stopped with exit code $LASTEXITCODE." }
    }
    elseif ($Install) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        "[{0}] Starting Autodesk MCP Connector installation." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
            Set-Content -LiteralPath $logPath -Encoding UTF8
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $coreSetup `
            -Action Install -RepositoryPath (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP') 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = @($output | ForEach-Object { $_.ToString() })
        $outputText | Add-Content -LiteralPath $logPath -Encoding UTF8
        $outputText | ForEach-Object { Write-Host $_ }
        if ($exitCode -ne 0) { throw "Installation stopped with exit code $exitCode. See $logPath" }
        Show-SetupMessage -Message 'Installation completed. Restart Revit, Codex, and Claude to load Autodesk MCP Connector.' `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Information)
    }
    else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $setup
        if ($LASTEXITCODE -ne 0) { throw "Autodesk MCP Connector setup stopped with exit code $LASTEXITCODE." }
    }
}
catch {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    "[{0}] ERROR: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message |
        Add-Content -LiteralPath $logPath -Encoding UTF8
    Show-SetupMessage -Message ("Setup could not finish.`r`n`r`n{0}`r`n`r`nLog: {1}" -f $_.Exception.Message, $logPath) `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Error)
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
'@ | Set-Content -LiteralPath (Join-Path $supportRoot 'Install-Autodesk-MCP-Connector.ps1') -Encoding UTF8

    @"
Autodesk MCP Connector $Version

1. Extract this ZIP completely.
2. Double-click INSTALL Autodesk MCP Connector.cmd.
3. Wait for the installation-completed message.
4. Restart Revit, Codex, and Claude.

Claude Free users: in Claude, open Customize > Skills, choose Upload a skill, and select Autodesk MCP Skills for Claude.zip once.

The Support folder contains the internal runtime package. Keep it beside the launcher; you do not need to open it.
"@ | Set-Content -LiteralPath (Join-Path $shareRoot 'README-FIRST.txt') -Encoding UTF8

    if (Test-Path -LiteralPath $outputArchive -PathType Leaf) {
        Remove-Item -LiteralPath $outputArchive -Force
    }
    Compress-Archive -LiteralPath $shareRoot -DestinationPath $outputArchive -CompressionLevel Optimal
    $hash = Get-Sha256Hex -Path $outputArchive
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
        RootFiles = 3
        TotalFiles = 5
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
