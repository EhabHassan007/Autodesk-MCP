$ErrorActionPreference = 'Stop'
# Lean core: Smart Connector runs nothing in the background. No scheduled tasks, no notification-area agent,
# no local web gateway or tunnel. Update checks and the weekly Skills Sync reminder happen when Revit, AutoCAD
# or the Smart Connector app opens, and PCs updated from an earlier version are cleaned up.
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$t = Join-Path ([IO.Path]::GetTempPath()) ('lean-core-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $t | Out-Null
$saved = @{ local = $env:LOCALAPPDATA; roaming = $env:APPDATA }
try {
    # 1. Nothing in the shipped connector schedules, hides a long-running process or serves the network.
    $retire = Join-Path $runtime 'scripts/retire-background-tasks.ps1'
    $code = Get-ChildItem -LiteralPath $runtime -Recurse -File -Include *.ps1, *.cs, *.lsp, *.cmd | Where-Object { $_.FullName -ne (Resolve-Path $retire).Path }
    foreach ($pattern in '(?<!Un)Register-ScheduledTask', 'New-ScheduledTaskTrigger', 'schtasks', 'HttpListener', 'TcpListener', 'cloudflared', 'connector-agent\.ps1', 'Start-ScheduledTask', 'CurrentVersion\\Run') {
        $hits = @($code | Select-String -Pattern $pattern | ForEach-Object { '{0}:{1}' -f $_.Path.Substring($runtime.Length), $_.LineNumber })
        Assert ($hits.Count -eq 0) ("Found '$pattern' in: " + ($hits -join ', '))
    }
    foreach ($gone in 'scripts/connector-agent.ps1', 'scripts/autodesk-mcp-update-notifier.ps1', 'src/autodesk/autodesk-http-gateway.ps1', 'src/autodesk/Start-AutodeskMcpRemote.ps1', 'REMOTE-CLAUDE.md') {
        Assert (-not (Test-Path -LiteralPath (Join-Path $runtime $gone))) "$gone is still shipped"
    }
    $outer = Get-Content (Join-Path $runtime '../Support/Install-Autodesk-MCP-Connector.ps1') -Raw
    Assert ($outer -notmatch '-Action Sync') 'Setup still starts a hidden Skills Sync after installing'
    'PASS: no scheduled tasks, no agent, no web gateway or tunnel, no hidden work after setup'

    # 2. Revit, AutoCAD and the app share one set of day stamps and the same reminder rules.
    $cs = Get-Content (Join-Path $runtime 'src/revit/addin/ConnectorUi.cs') -Raw
    $app = Get-Content (Join-Path $runtime 'src/revit/addin/RevitMcpApplication.cs') -Raw
    $lisp = Get-Content (Join-Path $runtime 'src/autocad/SmartAutodeskConnector.bundle/Contents/SmartAutodeskConnector.lsp') -Raw
    $status = Get-Content (Join-Path $runtime 'installer/ConnectorStatus.ps1') -Raw
    foreach ($stamp in 'open-check.txt', 'last-sync.txt', 'sync-reminder.txt') {
        foreach ($pair in @(@('Revit add-in', $cs), @('AutoCAD panel', $lisp), @('Smart Connector app', $status))) { Assert ($pair[1].Contains('"' + $stamp + '"') -or $pair[1].Contains("'" + $stamp + "'") -or $pair[1].Contains('\' + $stamp)) "$($pair[0]) does not use $stamp" }
    }
    Assert ($app.Contains('OpenCheck.Start(application);') -and $cs -notmatch 'EnsureAgentRunning') 'Revit still starts the agent instead of the open check'
    Assert ($cs.Contains('-Action InstallUpdate') -and $lisp.Contains('-Action InstallUpdate')) 'Update now does not open the update window'
    'PASS: Revit, AutoCAD and the app use the same day stamps and open the update window'

    $env:LOCALAPPDATA = Join-Path $t 'local'; $env:APPDATA = Join-Path $t 'roaming'
    New-Item -ItemType Directory -Force $env:LOCALAPPDATA, $env:APPDATA | Out-Null
    . (Join-Path $runtime 'installer/ConnectorStatus.ps1') -RepositoryPath $runtime
    $skillState = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
    $connectorState = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
    New-Item -ItemType Directory -Force $skillState, $connectorState | Out-Null
    $s = Get-ConnectorSnapshot
    Assert (-not (Test-SyncReminderDue $s)) 'Reminder shown on a PC that has not joined the team'
    Assert (Test-UpdateCheckDue $s) 'First open must check for updates'
    Write-StatusDay (Join-Path $connectorState 'open-check.txt')
    Assert (-not (Test-UpdateCheckDue (Get-ConnectorSnapshot))) 'Checked twice on the same day'
    Assert (Test-UpdateCheckDue (Get-ConnectorSnapshot) -Now ((Get-StatusToday) + 1)) 'Not checked again the next day'
    '{"notifications_user_disabled":  true}' | Set-Content (Join-Path $connectorState 'update-state.json')
    Assert (-not (Test-UpdateCheckDue (Get-ConnectorSnapshot) -Now ((Get-StatusToday) + 5))) 'Checked although update checks are off'
    '{}' | Set-Content (Join-Path $skillState 'service.json')
    Assert (Test-SyncReminderDue (Get-ConnectorSnapshot)) 'A team PC that never synced is not reminded'
    Write-StatusDay (Join-Path $skillState 'last-sync.txt')
    Assert (-not (Test-SyncReminderDue (Get-ConnectorSnapshot) -Now ((Get-StatusToday) + 6))) 'Reminded before a week had passed'
    Assert (Test-SyncReminderDue (Get-ConnectorSnapshot) -Now ((Get-StatusToday) + 7.5)) 'Not reminded after a week'
    '{"enabled":  false}' | Set-Content (Join-Path $skillState 'settings.json')
    Assert (-not (Test-SyncReminderDue (Get-ConnectorSnapshot) -Now ((Get-StatusToday) + 30))) 'Reminded although the reminder is off'
    'PASS: once-a-day update check and weekly reminder rules'

    # 3. Skills Sync settings: the reminder switch, and a PC updated from an earlier version keeps its last sync.
    $repo = Join-Path $t 'repo'; New-Item -ItemType Directory -Force (Join-Path $repo '.agents/skills') | Out-Null
    $state = Join-Path $t 'skill-state'; New-Item -ItemType Directory -Force $state | Out-Null
    $yesterday = (Get-Date).AddDays(-1).ToString('o')
    @{ completed_at = $yesterday; action = 'Sync'; sync_status = 'ok' } | ConvertTo-Json | Set-Content (Join-Path $state 'last-result.json')
    $weekly = Join-Path $runtime 'scripts/weekly-skill-collection.ps1'
    $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $weekly -Action Configure -RepositoryRoot $repo -StateRoot $state
    Assert ($LASTEXITCODE -eq 0) 'Configure failed'
    $settings = Get-Content (Join-Path $state 'settings.json') -Raw | ConvertFrom-Json
    Assert ($settings.enabled -eq $true -and -not $settings.PSObject.Properties['task_name']) 'Reminder not on by default, or a task name was saved'
    $day = [double]::Parse((Get-Content (Join-Path $state 'last-sync.txt') -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture)
    $expected = ([DateTime]::Parse($yesterday).ToUniversalTime() - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalDays
    Assert ([Math]::Abs($day - $expected) -lt 0.01) "Last sync day not carried over: $day vs $expected"
    $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $weekly -Action Disable -StateRoot $state
    $settings = Get-Content (Join-Path $state 'settings.json') -Raw | ConvertFrom-Json
    Assert ($settings.enabled -eq $false -and $settings.repository_root -eq $repo) 'Disable lost the reminder choice or the connector folder'
    $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $weekly -Action Configure -RepositoryRoot $repo -StateRoot $state
    Assert ((Get-Content (Join-Path $state 'settings.json') -Raw | ConvertFrom-Json).enabled -eq $false) 'Repair switched the reminder back on'
    'PASS: Skills Sync reminder settings and last sync day'

    # 4. Cleanup of what earlier versions set up.
    . $retire -LibraryOnly -StateRoot (Join-Path $t 'old-state') -ConnectorState (Join-Path $t 'old-connector') -StartupFolder (Join-Path $t 'startup') -InstallRoot (Join-Path $t 'install')
    Assert (Test-RetiredTask 'Smart Autodesk Connector Agent - S-1-5-21-1') 'Agent task not recognised'
    Assert (Test-RetiredTask 'Autodesk MCP Usage Report - S-1-5-21-1') 'Usage task not recognised'
    Assert (Test-RetiredTask 'Autodesk MCP Weekly Skills - S-1-5-21-1') 'Weekly task not recognised'
    Assert (Test-RetiredTask 'Autodesk MCP Connector Update Alerts') 'Update alert task not recognised'
    Assert (Test-RetiredTask 'Renamed' @('-File "C:\Users\a\AppData\Local\AutodeskMcpSkillCollection\scripts\connector-agent.ps1" -Action Run')) 'Agent task found by its action not recognised'
    Assert (-not (Test-RetiredTask 'OneDrive Standalone Update Task' @('/reporting'))) 'Another program''s task would be removed'
    Assert (-not (Test-RetiredTask 'Other' @('-File C:\Tools\connector-agent.ps1'))) 'A task outside our folders would be removed'

    New-Item -ItemType Directory -Force (Join-Path $t 'old-state/scripts'), (Join-Path $t 'old-connector/remote'), (Join-Path $t 'startup'), (Join-Path $t 'install/installer'), (Join-Path $t 'install/scripts'), (Join-Path $t 'install/src/autodesk') | Out-Null
    'x' | Set-Content (Join-Path $t 'old-state/scripts/connector-agent.ps1')
    'x' | Set-Content (Join-Path $t 'old-state/scripts/send-usage.ps1')
    'token' | Set-Content (Join-Path $t 'old-connector/remote/cloudflare-token.dpapi')
    '{"gateway":{"pid":999999,"started_at":"2026-01-01T00:00:00Z"}}' | Set-Content (Join-Path $t 'old-connector/remote/runtime.json')
    'x' | Set-Content (Join-Path $t 'old-connector/update-requested.flag')
    '@echo off' | Set-Content (Join-Path $t 'startup/Autodesk MCP Remote Connector.cmd')
    'x' | Set-Content (Join-Path $t 'startup/Other.cmd')
    'x' | Set-Content (Join-Path $t 'install/installer/Setup-BimCad.ps1')
    foreach ($old in 'scripts/connector-agent.ps1', 'src/autodesk/autodesk-http-gateway.ps1', 'src/autodesk/Start-AutodeskMcpRemote.ps1', 'REMOTE-CLAUDE.md') { 'x' | Set-Content (Join-Path $t "install/$old") }
    'x' | Set-Content (Join-Path $t 'install/src/autodesk/autodesk-bridge.ps1')
    function Remove-RetiredTasks { @('Smart Autodesk Connector Agent - test') }
    $report = @(Invoke-RetireBackgroundTasks)
    Assert (-not (Test-Path (Join-Path $t 'old-state/scripts/connector-agent.ps1')) -and (Test-Path (Join-Path $t 'old-state/scripts/send-usage.ps1'))) 'Agent restart copy not removed, or a Skills Sync helper removed'
    Assert (-not (Test-Path (Join-Path $t 'old-connector/remote')) -and -not (Test-Path (Join-Path $t 'old-connector/update-requested.flag'))) 'Remote credentials or the update request flag were left'
    Assert (-not (Test-Path (Join-Path $t 'startup/Autodesk MCP Remote Connector.cmd')) -and (Test-Path (Join-Path $t 'startup/Other.cmd'))) 'Remote start-up entry left, or another start-up entry removed'
    Assert (-not (Test-Path (Join-Path $t 'install/src/autodesk/autodesk-http-gateway.ps1')) -and -not (Test-Path (Join-Path $t 'install/REMOTE-CLAUDE.md')) -and (Test-Path (Join-Path $t 'install/src/autodesk/autodesk-bridge.ps1'))) 'Old gateway files left, or the MCP bridge removed'
    Assert (($report -join ' ') -match 'Removed scheduled tasks' -and ($report -join ' ') -match 'Claude remote access') ("Cleanup report incomplete: " + ($report -join ' | '))
    'PASS: earlier tasks, agent copy, remote gateway and its files are removed; nothing else is touched'

    # 5. On Windows, a real task of an earlier version is unregistered.
    if ([Environment]::OSVersion.Platform -eq 'Win32NT' -and (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        Remove-Item Function:\Remove-RetiredTasks
        . $retire -LibraryOnly
        $name = 'Autodesk MCP Usage Report - lean-core-test'
        $registered = $false
        try {
            $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
            $null = Register-ScheduledTask -TaskName $name -Action $action -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)) -Force
            $registered = $true
        }
        catch { "SKIP: scheduled tasks cannot be created here: $($_.Exception.Message)" }
        if ($registered) {
            try {
                $removed = @(Remove-RetiredTasks)
                Assert ($removed -contains $name -and -not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) 'The earlier usage task was not unregistered'
                'PASS: a scheduled task from an earlier version is unregistered'
            }
            finally { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
        }
    }
}
finally { $env:LOCALAPPDATA = $saved.local; $env:APPDATA = $saved.roaming; Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
