$ErrorActionPreference = 'Stop'
$setupPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Setup-BimCad.ps1'
. $setupPath -LibraryOnly

$script:claudeDesktopRegistered = $false
$script:claudeDesktopRestarted = $false
$script:localMcpPolicyEnabled = $false
$InstallClaudeDesktopIfMissing = $true

function Get-OptionalCommand {
    param([string]$Name)
    if ($Name -eq 'codex') { return 'mock-codex.exe' }
    $null
}

function Get-ClaudeDesktopProcesses { @() }
function Get-ClaudeDesktopInstallation {
    [pscustomobject]@{ Installed=$true; Executable=''; Source='test' }
}
function Register-McpServer { throw 'simulated Codex CLI failure' }
function Register-ClaudeCodeMcpServer { throw 'Claude Code should not be called in this test.' }
function Test-ClaudeDesktopLocalMcpAllowed {
    $script:localMcpPolicyEnabled = $true
    $true
}
function Register-ClaudeDesktopMcpServer { $script:claudeDesktopRegistered = $true }
function Restart-ClaudeDesktopIfRunning { $script:claudeDesktopRestarted = $true }

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Register-DetectedAiClients -Root $repositoryRoot

if (-not $script:localMcpPolicyEnabled) {
    throw 'Claude Desktop local MCP policy was not checked.'
}
if (-not $script:claudeDesktopRegistered) {
    throw 'A Codex registration failure blocked Claude Desktop registration.'
}
if (-not $script:claudeDesktopRestarted) {
    throw 'Claude Desktop was not restarted after successful registration.'
}

Write-Output 'Client registration isolation test passed.'
