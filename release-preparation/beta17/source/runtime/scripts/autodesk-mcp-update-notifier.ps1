[CmdletBinding()]
param(
    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/Autodesk-MCP.git',
    [string]$ReleaseManifestUrl = 'https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json',
    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),
    [switch]$TestNotification
)
# Kept for scheduled tasks created by earlier versions. Updates and notices are now handled by the
# connector agent (scripts\connector-agent.ps1), so this only makes sure the agent is running.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
$agent = Join-Path $stateRoot 'scripts\connector-agent.ps1'
if (-not (Test-Path -LiteralPath $agent)) { $agent = Join-Path $RepositoryPath 'scripts\connector-agent.ps1' }
if (Test-Path -LiteralPath $agent) {
    Start-Process powershell.exe -WindowStyle Hidden -WorkingDirectory $env:LOCALAPPDATA -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Action Run -StateRoot "{1}" -InstallRoot "{2}"' -f $agent, $stateRoot, $RepositoryPath)
}
