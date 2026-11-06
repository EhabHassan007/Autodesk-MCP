[CmdletBinding()]
param(
    # Also stop a running connector agent from an earlier version. Left off when an earlier version's agent is
    # the process installing this update: it would be cut off mid-update. It exits by itself afterwards,
    # because its restart copy is removed here and nothing starts it again.
    [switch]$StopAgent,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'),
    [string]$ConnectorState = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'),
    [string]$StartupFolder = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
    # The installed connector; setup copies new files over it, so files that were removed are deleted here.
    [string]$InstallRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$LibraryOnly
)
# Smart Connector runs nothing in the background. Earlier versions set up, per Windows user:
#   - scheduled tasks: the connector agent (sign-in), usage reporting (sign-in and daily), weekly Skills Sync,
#     and update alerts (daily);
#   - the connector agent itself, a hidden notification-area PowerShell process;
#   - the optional Claude remote gateway: a hidden local HTTP gateway plus a Cloudflare tunnel, started from the
#     Startup folder, with its credentials stored under AutodeskMcpConnector\remote.
# This removes all of them. Safe to run any number of times; each part fails on its own.
$ErrorActionPreference = 'Stop'

# Our scripts, as they appear in the actions of tasks created by earlier versions.
$script:RetiredScripts = @('connector-agent.ps1', 'send-usage.ps1', 'weekly-skill-collection.ps1', 'autodesk-mcp-update-notifier.ps1')
$script:RetiredTaskPrefixes = @('Smart Autodesk Connector Agent - ', 'Autodesk MCP Usage Report - ', 'Autodesk MCP Weekly Skills - ', 'Autodesk MCP Connector Update Alerts')

# A task is ours when its name is one we used, or when it runs one of our scripts from our folders.
function Test-RetiredTask {
    param([string]$TaskName, [string[]]$ActionArguments = @())
    foreach ($prefix in $script:RetiredTaskPrefixes) { if ($TaskName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    foreach ($arguments in $ActionArguments) {
        if ([string]::IsNullOrEmpty($arguments)) { continue }
        if ($arguments -notmatch 'AutodeskMcpSkillCollection|BIM-CAD-MCP') { continue }
        foreach ($name in $script:RetiredScripts) { if ($arguments.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    }
    $false
}

function Remove-RetiredTasks {
    $removed = @()
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $removed }
    foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $arguments = @($task.Actions | ForEach-Object { [string]$_.Arguments })
        if (-not (Test-RetiredTask -TaskName $task.TaskName -ActionArguments $arguments)) { continue }
        try {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
            $removed += $task.TaskName
        }
        catch { Write-Warning ("Scheduled task '{0}' could not be removed: {1}" -f $task.TaskName, $_.Exception.Message) }
    }
    $removed
}

function Stop-RetiredAgent {
    $stopped = 0
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)) {
        if ($process.ProcessId -eq $PID -or [string]$process.CommandLine -notmatch 'connector-agent\.ps1') { continue }
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
    }
    $stopped
}

# Stops the remote gateway and tunnel this user started (matched by recorded process id and start time,
# so an unrelated process that reused the id is left alone) and deletes the stored remote credentials.
function Remove-RemoteGateway {
    $remoteRoot = Join-Path $ConnectorState 'remote'
    $found = $false
    $runtime = Join-Path $remoteRoot 'runtime.json'
    if (Test-Path -LiteralPath $runtime -PathType Leaf) {
        $found = $true
        try {
            $state = Get-Content -LiteralPath $runtime -Raw | ConvertFrom-Json
            foreach ($entry in @($state.gateway, $state.tunnel)) {
                if ($null -eq $entry -or $null -eq $entry.pid) { continue }
                try {
                    $process = Get-Process -Id ([int]$entry.pid) -ErrorAction Stop
                    $recorded = [DateTime]::Parse([string]$entry.started_at).ToUniversalTime()
                    if ($process.ProcessName -match '^(powershell|cloudflared)' -and [Math]::Abs(($process.StartTime.ToUniversalTime() - $recorded).TotalSeconds) -le 2) {
                        Stop-Process -Id $process.Id -Force -ErrorAction Stop
                    }
                }
                catch { }
            }
        }
        catch { }
    }
    $startup = Join-Path $StartupFolder 'Autodesk MCP Remote Connector.cmd'
    if (Test-Path -LiteralPath $startup -PathType Leaf) { $found = $true; Remove-Item -LiteralPath $startup -Force }
    if (Test-Path -LiteralPath $remoteRoot) { $found = $true; Remove-Item -LiteralPath $remoteRoot -Recurse -Force }
    $found
}

# Files of the agent and the remote gateway left in the install folder by earlier versions.
$script:RetiredFiles = @('scripts\connector-agent.ps1', 'scripts\autodesk-mcp-update-notifier.ps1', 'REMOTE-CLAUDE.md',
    'src\autodesk\autodesk-http-gateway.ps1', 'src\autodesk\Initialize-AutodeskMcpRemote.ps1', 'src\autodesk\Start-AutodeskMcpRemote.ps1',
    'src\autodesk\Stop-AutodeskMcpRemote.ps1', 'src\autodesk\Get-AutodeskMcpRemoteConnection.ps1')

function Remove-RetiredFiles {
    $removed = 0
    if (-not $InstallRoot -or -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'installer\Setup-BimCad.ps1') -PathType Leaf)) { return $removed }
    foreach ($relative in $script:RetiredFiles) {
        $path = Join-Path $InstallRoot $relative
        try { if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force; $removed++ } } catch { }
    }
    $removed
}

function Invoke-RetireBackgroundTasks {
    $report = @()
    try {
        $tasks = @(Remove-RetiredTasks)
        if ($tasks.Count) { $report += ('Removed scheduled tasks from an earlier version: ' + ($tasks -join ', ')) }
    }
    catch { Write-Warning ('Scheduled tasks could not be checked: ' + $_.Exception.Message) }
    # The agent restarts itself from this copy after an update; without it, it simply exits.
    foreach ($name in 'connector-agent.ps1', 'autodesk-mcp-update-notifier.ps1') {
        $copy = Join-Path $StateRoot "scripts\$name"
        try { if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Force; $report += "Removed $name from the skills folder." } } catch { }
    }
    foreach ($flag in 'update-requested.flag') {
        try { $path = Join-Path $ConnectorState $flag; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } } catch { }
    }
    if ($StopAgent) {
        try { $count = Stop-RetiredAgent; if ($count) { $report += 'Stopped the connector agent from an earlier version.' } } catch { }
    }
    try { if (Remove-RemoteGateway) { $report += 'Removed Claude remote access (local gateway, tunnel start-up and stored credentials).' } }
    catch { Write-Warning ('Claude remote access could not be fully removed: ' + $_.Exception.Message) }
    try { $count = Remove-RetiredFiles; if ($count) { $report += "Removed $count file(s) of the agent and remote access from the install folder." } } catch { }
    if (-not $report.Count) { $report += 'Nothing runs in the background.' }
    $report
}

if ($LibraryOnly) { return }
Invoke-RetireBackgroundTasks | ForEach-Object { Write-Output $_ }
