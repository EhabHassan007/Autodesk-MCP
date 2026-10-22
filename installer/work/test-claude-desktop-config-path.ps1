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
