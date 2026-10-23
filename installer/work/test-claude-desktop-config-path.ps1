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

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('AutodeskMcpClaudeConfigTest-' + [Guid]::NewGuid().ToString('N'))
$previousAppData = $env:APPDATA
try {
    $env:APPDATA = $temporaryRoot
    . $setupPath -LibraryOnly
    $configPath = Get-ClaudeDesktopConfigPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
    @{
        mcpServers = @{
            'keep-me' = @{ command = 'keep.exe'; args = @() }
            'Revit Connector' = @{ command = 'legacy.exe'; args = @() }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8

    $bridge = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\autodesk\autodesk-bridge.ps1'
    Register-ClaudeDesktopMcpServer -Name 'autodesk' -Bridge $bridge -BridgeArguments @('-RevitVersion','2024') -LegacyNames @('Revit Connector')
    $registered = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if (-not $registered.mcpServers.PSObject.Properties['autodesk']) {
        throw 'The combined Autodesk registration was not written.'
    }
    if (-not $registered.mcpServers.PSObject.Properties['keep-me']) {
        throw 'An unrelated Claude Desktop registration was not preserved.'
    }
    if ($registered.mcpServers.PSObject.Properties['Revit Connector']) {
        throw 'The legacy Revit registration was not removed.'
    }
    Write-Output 'Claude Desktop registration test passed without relying on AppX detection.'
}
finally {
    $env:APPDATA = $previousAppData
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedSystemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemporary.StartsWith($resolvedSystemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected test path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
    }
}
