[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$setupPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'installer\Setup-BimCad.ps1'
$source = Get-Content -LiteralPath $setupPath -Raw
$match = [regex]::Match(
    $source,
    '(?ms)^function Get-ClaudeDesktopConfigPath \{.*?^\}'
)
if (-not $match.Success) {
    throw 'Get-ClaudeDesktopConfigPath was not found.'
}

Invoke-Expression $match.Value
$expected = Join-Path (Join-Path $env:APPDATA 'Claude') 'claude_desktop_config.json'
$actual = Get-ClaudeDesktopConfigPath
if ($actual -ne $expected) {
    throw "Claude Desktop config path mismatch. Expected '$expected'; got '$actual'."
}
if ($match.Value -match 'Packages\\Claude_') {
    throw 'Claude Desktop config path must not use a hard-coded MSIX package LocalCache.'
}

Write-Output "Claude Desktop config path test passed: $actual"

$testBase = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$temporaryRoot = Join-Path $testBase ('tc-' + [Guid]::NewGuid().ToString('N'))
$previousAppData = $env:APPDATA
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $env:APPDATA = $temporaryRoot
    $env:LOCALAPPDATA = Join-Path $temporaryRoot 'Local'
    . $setupPath -LibraryOnly
    $configPath = Get-ClaudeDesktopConfigPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
    $packageRoot = Join-Path $env:LOCALAPPDATA 'Packages\Claude_test'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $packageConfigPath = Join-Path $packageRoot 'LocalCache\Roaming\Claude\claude_desktop_config.json'
    @{
        mcpServers = @{
            'keep-me' = @{ command = 'keep.exe'; args = @() }
            'Revit Connector' = @{ command = 'legacy.exe'; args = @() }
            'autodesk' = @{ command = 'old-combined.exe'; args = @() }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8

    $bridge = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\autodesk\autodesk-bridge.ps1'
    Register-ClaudeDesktopMcpServer -Name 'Autodesk MCP Connector' -Bridge $bridge -BridgeArguments @('-RevitVersion','2024') -LegacyNames @('Revit Connector','autodesk')
    $configBytes = [IO.File]::ReadAllBytes($configPath)
    if ($configBytes.Length -ge 3 -and $configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB -and $configBytes[2] -eq 0xBF) {
        throw 'Claude Desktop config must be UTF-8 without a BOM.'
    }
    $registered = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if (-not $registered.mcpServers.PSObject.Properties['Autodesk MCP Connector']) {
        throw 'The combined Autodesk registration was not written.'
    }
    if (-not $registered.mcpServers.PSObject.Properties['keep-me']) {
        throw 'An unrelated Claude Desktop registration was not preserved.'
    }
    if ($registered.mcpServers.PSObject.Properties['Revit Connector']) {
        throw 'The legacy Revit registration was not removed.'
    }
    if ($registered.mcpServers.PSObject.Properties['autodesk']) {
        throw 'The old short Claude Desktop connector name was not removed.'
    }
    if (-not (Test-Path -LiteralPath $packageConfigPath -PathType Leaf)) {
        throw 'The Microsoft Store/MSIX Claude config was not written.'
    }
    $packageBytes = [IO.File]::ReadAllBytes($packageConfigPath)
    if ($packageBytes.Length -ge 3 -and $packageBytes[0] -eq 0xEF -and $packageBytes[1] -eq 0xBB -and $packageBytes[2] -eq 0xBF) {
        throw 'The Microsoft Store/MSIX Claude config must be UTF-8 without a BOM.'
    }
    $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
    if (-not $packageConfig.mcpServers.PSObject.Properties['Autodesk MCP Connector']) {
        throw 'The combined Autodesk registration was not written to the Microsoft Store/MSIX config.'
    }
    Write-Output 'Claude Desktop registration test passed without relying on AppX detection.'
}
finally {
    $env:APPDATA = $previousAppData
    $env:LOCALAPPDATA = $previousLocalAppData
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedTestBase = [IO.Path]::GetFullPath($testBase)
        if (-not $resolvedTemporary.StartsWith($resolvedTestBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected test path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
    }
}
