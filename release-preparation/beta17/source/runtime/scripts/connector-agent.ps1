[CmdletBinding()]
param(
    [ValidateSet('Run', 'Register', 'Unregister')][string]$Action = 'Run',
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'),
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),
    [switch]$LibraryOnly
)
# Smart Autodesk Connector agent: a notification-area icon that starts at sign-in.
#  - Checks for approved updates at start and every 6 hours.
#  - When Revit or AutoCAD starts and an update is ready, shows a Windows notification.
#  - Installs updates by itself once Revit and AutoCAD are closed (unless switched off in Settings),
#    or straight after they close when the person chose "Update now".
#  - Menu: Check for updates, Skills Sync, Settings, Open log, Quit.
# It runs from the state folder copy, so updates can replace the install folder underneath it.
$ErrorActionPreference = 'Stop'
$connectorState = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
$updateStatePath = Join-Path $connectorState 'update-state.json'
$requestPath = Join-Path $connectorState 'update-requested.flag'
$agentLog = Join-Path $connectorState 'agent.log'
$taskName = 'Smart Autodesk Connector Agent - ' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

# ---------- decisions (no UI; covered by tests) ----------

function Compare-AgentVersion {
    param([string]$Left, [string]$Right)
    $parse = { param($v) $m = [regex]::Match(([string]$v).Trim().TrimStart('v'), '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$'); if (-not $m.Success) { return $null }; $m }
    $a = & $parse $Left; $b = & $parse $Right
    if (-not $a -or -not $b) { return 0 }
    foreach ($i in 1..3) { $d = [int]$a.Groups[$i].Value - [int]$b.Groups[$i].Value; if ($d) { return [Math]::Sign($d) } }
    $pa = $a.Groups[4].Value; $pb = $b.Groups[4].Value
    if ($pa -eq $pb) { return 0 }
    if (-not $pa) { return 1 }; if (-not $pb) { return -1 }
    # Pre-release parts such as beta.17 vs beta.18: compare numerically where both are numbers.
    $xa = $pa -split '\.'; $xb = $pb -split '\.'
    for ($i = 0; $i -lt [Math]::Max($xa.Count, $xb.Count); $i++) {
        if ($i -ge $xa.Count) { return -1 }; if ($i -ge $xb.Count) { return 1 }
        $na = 0; $nb = 0
        if ([int]::TryParse($xa[$i], [ref]$na) -and [int]::TryParse($xb[$i], [ref]$nb)) { if ($na -ne $nb) { return [Math]::Sign($na - $nb) } }
        elseif ($xa[$i] -ne $xb[$i]) { return [Math]::Sign([string]::CompareOrdinal($xa[$i], $xb[$i])) }
    }
    0
}

function Get-AgentDecision {
    param([string]$Installed, [string]$Available, [bool]$AutoUpdate, [bool]$Requested, [string[]]$AppsRunning = @())
    if (-not $Available -or -not $Installed -or (Compare-AgentVersion $Available $Installed) -le 0) { return 'none' }
    if ($AppsRunning.Count) { return 'wait' }          # never replace files under an open Revit/AutoCAD
    if ($AutoUpdate -or $Requested) { return 'install' }
    'none'
}

function Get-StartedApps {
    param([string[]]$Previous = @(), [string[]]$Current = @())
    @($Current | Where-Object { $Previous -notcontains $_ })
}

function ConvertFrom-UpdateOutput {
    param([string]$Text)
    if ($Text -match '\[UPDATE_INSTALLED\]') { return 'installed' }
    if ($Text -match '\[UPDATE_DEFERRED\]') { return 'deferred' }
    if ($Text -match '\[UPDATE_AVAILABLE\]') { return 'available' }
    if ($Text -match '\[UP_TO_DATE\]') { return 'current' }
    'unknown'
}

function Read-UpdateStateFile {
    if (-not (Test-Path -LiteralPath $updateStatePath)) { return $null }
    try { Get-Content -LiteralPath $updateStatePath -Raw | ConvertFrom-Json } catch { $null }
}

function Get-RunningApps {
    @(Get-Process -Name 'Revit', 'acad' -ErrorAction SilentlyContinue | ForEach-Object { if ($_.ProcessName -eq 'acad') { 'AutoCAD' } else { 'Revit' } } | Sort-Object -Unique)
}

function Write-AgentLog {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Path $connectorState -Force | Out-Null
        [IO.File]::AppendAllText($agentLog, "[$(Get-Date -Format o)] $Message`r`n")
        $lines = @(Get-Content -LiteralPath $agentLog)
        if ($lines.Count -gt 300) { $lines[-300..-1] | Set-Content -LiteralPath $agentLog -Encoding UTF8 }
    }
    catch { }
}

# ---------- scheduled task ----------

function Register-AgentTask {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runner = Join-Path $StateRoot 'scripts\connector-agent.ps1'
    foreach ($path in @($runner, $StateRoot, $InstallRoot)) { if ($path.Contains('"')) { throw 'Unsupported quote in installation path.' } }
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Action Run -StateRoot "{1}" -InstallRoot "{2}"' -f $runner, $StateRoot, $InstallRoot
    $taskAction = New-ScheduledTaskAction -Execute $engine -Argument $arguments -WorkingDirectory $env:LOCALAPPDATA
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Smart Autodesk Connector: update notifications, automatic updates when Revit and AutoCAD are closed, and Skills Sync.' -Force | Out-Null
    # Start it now as well, so notifications work without signing out first.
    try { Start-ScheduledTask -TaskName $taskName } catch { }
    "Connector agent registered and started: $taskName"
}

if ($LibraryOnly) { return }
if ($Action -eq 'Register') { Register-AgentTask; exit 0 }
if ($Action -eq 'Unregister') {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    'Connector agent removed.'; exit 0
}

# ---------- notification-area app ----------

$mutex = New-Object Threading.Mutex($false, 'Local\SmartAutodeskConnector.Agent')
if (-not $mutex.WaitOne(0)) { exit 0 }   # one agent per signed-in user
Set-Location -LiteralPath $env:LOCALAPPDATA   # never hold the install folder open
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $InstallRoot 'installer\Brand.ps1')

$script:agent = @{ Job = $null; JobKind = ''; LastApps = @(Get-RunningApps); NotifiedVersion = ''; LastCheck = [DateTime]::MinValue; FailedVersion = ''; LastResultStamp = '' }
# Remember the last finished run so only syncs that finish from now on are announced.
try { $script:agent.LastResultStamp = [string](Get-Content -LiteralPath (Join-Path $StateRoot 'last-result.json') -Raw | ConvertFrom-Json).completed_at } catch { }

$icon = New-Object Windows.Forms.NotifyIcon
$icon.Icon = Get-BrandIcon
$icon.Text = 'Smart Autodesk Connector'
$icon.Visible = $true

function Show-Notice {
    param([string]$Title, [string]$Text, [string]$Kind = 'Info', [switch]$OffersUpdate)
    # Clicking an update notice opens the Update now / Later prompt; other notices just close.
    $script:agent.LastNoticeIsUpdate = [bool]$OffersUpdate
    $icon.BalloonTipTitle = $Title
    $icon.BalloonTipText = $Text
    $icon.BalloonTipIcon = $Kind
    $icon.ShowBalloonTip(15000)
    Write-AgentLog "$Title - $Text"
}

function Start-AgentJob {
    param([string]$Kind, [string]$Script, [string[]]$Arguments)
    if ($script:agent.Job) { return $false }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $quoted = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $env:LOCALAPPDATA
    $process = [Diagnostics.Process]::Start($psi)
    $script:agent.Job = @{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
    $script:agent.JobKind = $Kind
    Write-AgentLog "Started $Kind"
    $true
}

$setupScript = Join-Path $InstallRoot 'installer\Setup-BimCad.ps1'
function Start-UpdateCheck { $null = Start-AgentJob 'check' $setupScript @('-Action', 'CheckUpdate', '-RepositoryPath', $InstallRoot); $script:agent.LastCheck = Get-Date }
function Start-UpdateInstall { $null = Start-AgentJob 'install' $setupScript @('-Action', 'Update', '-RepositoryPath', $InstallRoot) }
function Start-SkillsSync {
    if (-not (Start-AgentJob 'sync' (Join-Path $StateRoot 'scripts\weekly-skill-collection.ps1') @('-Action', 'Sync', '-StateRoot', $StateRoot))) {
        Show-Notice 'Smart Autodesk Connector' 'Another task is running. Try Skills Sync again in a minute.'
    }
}

function Complete-Job {
    $job = $script:agent.Job
    if (-not $job -or -not $job.Process.HasExited -or -not $job.Out.IsCompleted -or -not $job.Err.IsCompleted) { return }
    $kind = $script:agent.JobKind; $script:agent.Job = $null; $script:agent.JobKind = ''
    $text = $job.Out.Result + "`n" + $job.Err.Result
    Write-AgentLog "Finished $kind (exit $($job.Process.ExitCode))"
    $state = Read-UpdateStateFile
    switch ($kind) {
        'check' {
            if ($script:agent.ManualCheck) {
                $script:agent.ManualCheck = $false
                switch (ConvertFrom-UpdateOutput $text) {
                    'available' { Show-Notice 'Update ready' ("Version {0} is ready. It installs when Revit and AutoCAD are closed. Click here to update now." -f $state.available_version) -OffersUpdate }
                    'current'   { Show-Notice 'Smart Autodesk Connector' ("You have the latest version ({0})." -f $state.installed_version) }
                    default     { Show-Notice 'Smart Autodesk Connector' 'Could not check for updates. Check the internet connection and try again.' 'Warning' }
                }
            }
        }
        'install' {
            switch (ConvertFrom-UpdateOutput $text) {
                'installed' {
                    if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
                    Show-Notice 'Smart Autodesk Connector updated' ("Version {0} is installed. Restart Codex and Claude to use it." -f (Read-UpdateStateFile).installed_version)
                    # Restart on the new agent code that the update copied into the state folder.
                    # Release the single-instance lock first, or the new copy would exit at once.
                    $mutex.ReleaseMutex(); $script:agent.MutexReleased = $true
                    Start-Process powershell.exe -WindowStyle Hidden -WorkingDirectory $env:LOCALAPPDATA -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Action Run -StateRoot "{1}" -InstallRoot "{2}"' -f (Join-Path $StateRoot 'scripts\connector-agent.ps1'), $StateRoot, $InstallRoot)
                    $icon.Visible = $false; [Windows.Forms.Application]::Exit()
                }
                'deferred' { }
                default {
                    if ($script:agent.FailedVersion -ne $state.available_version) {
                        $script:agent.FailedVersion = $state.available_version
                        Show-Notice 'Update not installed' 'The update could not be installed. It will be retried later. Details are in the agent log.' 'Warning'
                    }
                }
            }
        }
        'sync' {
            $result = Get-LastSyncResult
            if ($result) { $script:agent.LastResultStamp = [string]$result.completed_at }
            Show-SyncNotice $result
        }
    }
}

function Get-LastSyncResult {
    try { Get-Content -LiteralPath (Join-Path $StateRoot 'last-result.json') -Raw | ConvertFrom-Json } catch { $null }
}

function Show-SyncNotice {
    param($Result)
    if ($Result -and $Result.sync_status -eq 'ok') {
        Show-Notice 'Skills Sync complete' ("{0} saved skill(s) sent for review. {1} new and {2} updated approved skill(s) downloaded." -f [int]$Result.sync_submitted, [int]$Result.sync_added, [int]$Result.sync_updated)
    }
    elseif ($Result -and $Result.sync_reason) { Show-Notice 'Skills Sync' ([string]$Result.sync_reason) 'Warning' }
    else { Show-Notice 'Skills Sync' 'Skills Sync did not finish. Check the internet connection and try again.' 'Warning' }
}

function Show-UpdatePrompt {
    $state = Read-UpdateStateFile
    if (-not $state -or -not $state.available_version) { return }
    $apps = Get-RunningApps
    $form = New-BrandForm -Width 460 -Height 230
    $form.Text = 'Smart Autodesk Connector update'
    $form.TopMost = $true
    $null = Add-BrandHeader $form -Title 'Update ready' -Subtitle ("Version {0}" -f $state.available_version) -Height 72
    $message = if ($apps.Count) { "Save your work and close {0}. The update then installs by itself; it takes about a minute." -f ($apps -join ' and ') } else { 'Install the update now? It takes about a minute.' }
    $form.Controls.Add((New-BrandLabel $message 24 96 -Width 410))
    $now = New-BrandButton 'Update now' -Primary -Width 130; $now.Location = New-Object Drawing.Point(184, 170); $now.DialogResult = 'OK'
    $later = New-BrandButton 'Later' -Width 110; $later.Location = New-Object Drawing.Point(324, 170); $later.DialogResult = 'Cancel'
    $form.Controls.AddRange(@($now, $later)); $form.AcceptButton = $now; $form.CancelButton = $later
    if ($form.ShowDialog() -eq 'OK') {
        New-Item -ItemType File -Path $requestPath -Force | Out-Null
        Write-AgentLog 'Update requested by the user.'
    }
    $form.Dispose()
}

$menu = New-Object Windows.Forms.ContextMenuStrip
$title = $menu.Items.Add('Smart Autodesk Connector'); $title.Enabled = $false; $title.Font = New-BrandFont 9 ([Drawing.FontStyle]::Bold)
$null = $menu.Items.Add('-')
$null = $menu.Items.Add('Check for updates', $null, { $script:agent.ManualCheck = $true; if (-not $script:agent.Job) { Start-UpdateCheck } })
$null = $menu.Items.Add('Skills Sync', $null, { Start-SkillsSync })
$null = $menu.Items.Add('Settings', $null, { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f (Join-Path $InstallRoot 'installer\Settings.ps1')) })
$null = $menu.Items.Add('Open log', $null, { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $agentLog) })
$null = $menu.Items.Add('-')
$null = $menu.Items.Add('Quit', $null, { $icon.Visible = $false; [Windows.Forms.Application]::Exit() })
$icon.ContextMenuStrip = $menu
$icon.Add_BalloonTipClicked({ if ($script:agent.LastNoticeIsUpdate) { Show-UpdatePrompt } })

$tick = New-Object Windows.Forms.Timer
$tick.Interval = 20000
$tick.Add_Tick({
    try {
        Complete-Job
        # A Skills Sync started from Revit (or elsewhere) finished: announce its result.
        $last = Get-LastSyncResult
        if ($last -and [string]$last.completed_at -ne $script:agent.LastResultStamp) {
            $script:agent.LastResultStamp = [string]$last.completed_at
            if ($last.action -eq 'Sync') { Show-SyncNotice $last }
        }
        if (-not $script:agent.Job -and ((Get-Date) - $script:agent.LastCheck).TotalHours -ge 6) { Start-UpdateCheck; return }
        $apps = Get-RunningApps
        $started = Get-StartedApps $script:agent.LastApps $apps
        $script:agent.LastApps = $apps
        $state = Read-UpdateStateFile
        if (-not $state) { return }
        $auto = [bool]$state.notifications_enabled
        $requested = Test-Path -LiteralPath $requestPath
        $decision = Get-AgentDecision -Installed $state.installed_version -Available $state.available_version -AutoUpdate $auto -Requested $requested -AppsRunning $apps
        if ($decision -eq 'install' -and -not $script:agent.Job) { Start-UpdateInstall }
        elseif ($decision -eq 'wait' -and $started.Count -and ($auto -or $requested)) {
            # One notice each time Revit or AutoCAD starts while an update is waiting.
            Show-Notice 'Smart Autodesk Connector update ready' ("Version {0} installs when you close Revit and AutoCAD. Click here to update now." -f $state.available_version) -OffersUpdate
        }
    }
    catch { Write-AgentLog "Agent error: $($_.Exception.Message)" }
})
$tick.Start()
Write-AgentLog 'Agent started.'
# First check shortly after sign-in, once the network is up.
$first = New-Object Windows.Forms.Timer
$first.Interval = 60000
$first.Add_Tick({ $first.Stop(); if (-not $script:agent.Job) { Start-UpdateCheck } })
$first.Start()
[Windows.Forms.Application]::Run()
$icon.Dispose()
if (-not $script:agent.MutexReleased) { try { $mutex.ReleaseMutex() } catch { } }
