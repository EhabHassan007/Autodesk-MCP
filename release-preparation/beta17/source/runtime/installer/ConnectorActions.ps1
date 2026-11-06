# Smart Connector actions behind the AutoCAD Add-ins buttons (SmartAutodeskConnector.lsp).
# A PowerShell port of the Revit add-in's TaskWindow (src\revit\addin\ConnectorUi.cs): one hidden step runs
# while a branded window shows progress, then the window shows the result.
# Run directly (powershell -STA -File ConnectorActions.ps1 -Action X) or dot-source with -LibraryOnly.
param(
    [ValidateSet('SkillsSync', 'CheckUpdates', 'Status')]
    [string]$Action = 'Status',
    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot),
    [switch]$LibraryOnly
)

$script:ActionPaths = @{
    StateRoot      = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
    ConnectorState = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
    UpdateState    = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\update-state.json'
    UpdateRequest  = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\update-requested.flag'
    PowerShell     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Read-ActionJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $null }
}

function Get-ActionValue {
    param($Object, [string]$Name)
    if ($Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null }
}

# Scripts copied to the state folder keep working while an update replaces the install folder.
function Get-ConnectorScript {
    param([string]$Name, [string]$Root = $RepositoryPath)
    $stateCopy = Join-Path $script:ActionPaths.StateRoot "scripts\$Name"
    if (Test-Path -LiteralPath $stateCopy -PathType Leaf) { return $stateCopy }
    Join-Path $Root "scripts\$Name"
}

function Start-HiddenScript {
    param([string]$Script, [string]$Arguments)
    Start-Process $script:ActionPaths.PowerShell -WindowStyle Hidden -WorkingDirectory $env:LOCALAPPDATA `
        -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" {1}' -f $Script, $Arguments)
}

# The agent is single-instance; starting it when it already runs is harmless.
function Start-ConnectorAgent {
    param([string]$Root = $RepositoryPath)
    $agent = Get-ConnectorScript 'connector-agent.ps1' $Root
    if (Test-Path -LiteralPath $agent -PathType Leaf) {
        try { Start-HiddenScript $agent ('-Action Run -StateRoot "{0}" -InstallRoot "{1}"' -f $script:ActionPaths.StateRoot, $Root) } catch { }
    }
}

function Test-ConnectorAgentRunning {
    try { $mutex = [Threading.Mutex]::OpenExisting('Local\SmartAutodeskConnector.Agent'); $mutex.Dispose(); $true } catch { $false }
}

# Result shown after Skills Sync; Kind is Good, Bad or Accent (the brand colour names).
function Get-SkillsSyncOutcome {
    param([string]$Output, [string]$ResultPath = (Join-Path $script:ActionPaths.StateRoot 'last-result.json'))
    if ($Output -like '*A collection run is already active.*') {
        return [pscustomobject]@{ Title = 'Skills Sync is already running'; Kind = 'Accent'
            Body = 'A sync started earlier is still working in the background. You will get a Windows notification when it is done.' }
    }
    $result = Read-ActionJson $ResultPath
    $status = [string](Get-ActionValue $result 'sync_status')
    $reason = [string](Get-ActionValue $result 'sync_reason')
    if ($status -in 'ok', 'partial') {
        $n = @{}
        foreach ($key in 'sync_submitted', 'sync_added', 'sync_updated', 'sync_preserved', 'sync_approved_total') { $n[$key] = [int](Get-ActionValue $result $key) }
        $plural = { param($count) if ($count -eq 1) { '' } else { 's' } }
        $body = "Sent for review:  $($n.sync_submitted) saved skill$(& $plural $n.sync_submitted)`n" +
            "Downloaded:  $($n.sync_added) new and $($n.sync_updated) updated approved AutoCAD skill$(& $plural ($n.sync_added + $n.sync_updated))`n" +
            $(if ($n.sync_preserved -gt 0) { "Kept your local edits:  $($n.sync_preserved) skill$(& $plural $n.sync_preserved)`n" } else { '' }) +
            "Approved AutoCAD skills available:  $($n.sync_approved_total)" +
            $(if ($status -eq 'partial') { "`n`n$reason" } else { "`n`nRestart Codex or Claude to see new skills." })
        return [pscustomobject]@{ Title = $(if ($status -eq 'ok') { 'Skills are in sync' } else { 'Skills downloaded, but not sent' })
            Body = $body; Kind = $(if ($status -eq 'ok') { 'Good' } else { 'Bad' }) }
    }
    [pscustomobject]@{ Title = "Skills Sync didn't finish"; Kind = 'Bad'
        Body = $(if ([string]::IsNullOrWhiteSpace($reason)) { 'Check the internet connection and try again. Details are in the weekly skill log.' } else { $reason }) }
}

# State is Available, Current or Unknown; drives which buttons Check Updates offers.
function Get-CheckUpdatesOutcome {
    param([string]$Output, [string]$StatePath = $script:ActionPaths.UpdateState)
    $state = Read-ActionJson $StatePath
    $installed = [string](Get-ActionValue $state 'installed_version')
    $available = [string](Get-ActionValue $state 'available_version')
    $userOff = [bool](Get-ActionValue $state 'notifications_user_disabled')
    if (([string]$Output).Contains('[UPDATE_AVAILABLE]')) {
        return [pscustomobject]@{ State = 'Available'; Kind = 'Accent'; UserOff = $userOff; Title = "Version $available is ready"
            Body = "You have version $installed. The update installs by itself as soon as AutoCAD and Revit are closed, and takes about a minute. Choose Update now to install it the next time you close them, even if automatic updates are off." }
    }
    if (([string]$Output).Contains('[UP_TO_DATE]')) {
        return [pscustomobject]@{ State = 'Current'; Kind = 'Good'; UserOff = $userOff; Title = "You're up to date"
            Body = "Smart Connector $installed is the latest approved version." }
    }
    [pscustomobject]@{ State = 'Unknown'; Kind = 'Bad'; UserOff = $userOff; Title = "Couldn't check right now"
        Body = 'The update service could not be reached. Check the internet connection and try again later. Your connector keeps working.' }
}

function Request-ConnectorUpdate {
    param([string]$Root = $RepositoryPath)
    New-Item -ItemType Directory -Path $script:ActionPaths.ConnectorState -Force | Out-Null
    [IO.File]::WriteAllText($script:ActionPaths.UpdateRequest, [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture))
    Start-ConnectorAgent $Root
}

# Turns Setup-BimCad -Action Status output into one line per check, plus the agent.
function Get-ConnectionStatusOutcome {
    param([string]$Output, [bool]$AgentRunning)
    $lines = @()
    foreach ($line in ($Output -split "`r?`n")) {
        # Only the installer's own timestamped findings; the raw `codex mcp get` output it echoes is left out.
        if ($line -notmatch '^\[\d{2}:\d{2}:\d{2}\]\s*(.+)$') { continue }
        $text = $Matches[1].Trim()
        if ($text -like 'Revit*' -or $text -like 'Smart Connector - *') { continue }   # the installer's own heading
        $good = $text -match 'passed|has the Smart Connector registration|installation detected|is running at'
        $lines += $(if ($good) { [char]0x2713 } else { [char]0x2022 }) + '  ' + $text
    }
    $lines += $(if ($AgentRunning) { [char]0x2713 + '  The connector agent is running (updates and notifications).' }
        else { [char]0x2022 + '  The connector agent is not running. It starts again when you sign in to Windows.' })
    $title, $kind = if ($Output -match 'Live AutoCAD connection passed') { 'AutoCAD is connected', 'Good' }
        elseif ($Output -match 'AutoCAD is running, but no drawing is open') { 'Open a drawing to connect', 'Accent' }
        else { 'AutoCAD is not reachable yet', 'Bad' }
    [pscustomobject]@{ Title = $title; Kind = $kind; Body = ($lines -join "`n") }
}

function Show-ConnectorAction {
    param([string]$Name = $Action, [string]$Root = $RepositoryPath)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    . (Join-Path $Root 'installer\Brand.ps1')
    $C = $script:BrandColors
    $caption = @{ SkillsSync = 'Skills Sync'; CheckUpdates = 'Check Updates'; Status = 'Connection Status' }[$Name]
    $height = if ($Name -eq 'Status') { 460 } else { 330 }
    $ui = @{ Process = $null; Output = $null; Started = [DateTime]::UtcNow; BackgroundAfter = 0; UserOff = $false }

    $form = New-BrandForm -Width 520 -Height $height
    $null = Add-BrandHeader $form -Title $caption -Subtitle $script:BrandName -Height 76
    $title = New-BrandLabel '' 26 100 -Width 470 -Size 12 -Bold
    $body = New-BrandLabel '' 26 134 -Width 470
    # Drawing names can contain '&' ("Location & Details.dwg"); show it rather than treat it as a shortcut key.
    $title.UseMnemonic = $false; $body.UseMnemonic = $false
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30
    $progress.Bounds = New-Object Drawing.Rectangle(26, ($height - 100), 468, 8)
    $option = New-Object Windows.Forms.CheckBox
    $option.AutoSize = $true; $option.Location = New-Object Drawing.Point(26, ($height - 92)); $option.Visible = $false
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.Bounds = New-Object Drawing.Rectangle(0, ($height - 56), 508, 50)
    # Bottom-anchored, so they follow when the window grows to fit a long result.
    foreach ($control in $progress, $option, $buttons) { $control.Anchor = 'Bottom, Left' }
    $form.Controls.AddRange(@($title, $body, $progress, $option, $buttons))
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 250

    $showResult = {
        param($Outcome)
        $title.Text = $Outcome.Title; $title.ForeColor = $C[$Outcome.Kind]; $body.Text = $Outcome.Body; $progress.Visible = $false
        # Grow (never shrink) so the result and the buttons below it stay visible; measured in scaled pixels.
        $needed = $body.Bottom + 12 + ($form.ClientSize.Height - $progress.Top)
        $limit = [int]([Windows.Forms.Screen]::FromControl($form).WorkingArea.Height * 0.9)
        if ($needed -gt $form.ClientSize.Height) { $form.ClientSize = New-Object Drawing.Size($form.ClientSize.Width, [Math]::Min($needed, $limit)) }
    }
    $addButton = {
        param([string]$Text, [bool]$Primary, [scriptblock]$OnClick)
        $button = if ($Primary) { New-BrandButton $Text -Primary } else { New-BrandButton $Text }
        $button.Margin = New-Object Windows.Forms.Padding(0, 4, 14, 4)
        $button.Add_Click($OnClick)
        $buttons.Controls.Add($button)
        if ($Primary) { $form.AcceptButton = $button }
    }
    $run = {
        param([string]$Heading, [string]$Text, [string]$Script, [string]$Arguments)
        $title.Text = $Heading; $body.Text = $Text
        $info = New-Object Diagnostics.ProcessStartInfo($script:ActionPaths.PowerShell,
            ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $Script, $Arguments))
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $info.WorkingDirectory = $env:LOCALAPPDATA
        $ui.Process = [Diagnostics.Process]::Start($info)
        $ui.Output = $ui.Process.StandardOutput.ReadToEndAsync()
        $null = $ui.Process.StandardError.ReadToEndAsync()
        $ui.Started = [DateTime]::UtcNow
        $timer.Start()
    }

    $finish = switch ($Name) {
        'SkillsSync' {
            # After 15 s the step continues in the background; the agent shows a notice when it finishes.
            $ui.BackgroundAfter = 15
            { param($Output) & $showResult (Get-SkillsSyncOutcome $Output); & $addButton 'Close' $true { $form.Close() } }
        }
        'CheckUpdates' {
            {
                param($Output)
                $outcome = Get-CheckUpdatesOutcome $Output
                & $showResult $outcome
                switch ($outcome.State) {
                    'Available' {
                        & $addButton 'Later' $false { $form.Close() }
                        & $addButton 'Update now' $true {
                            Request-ConnectorUpdate $Root
                            & $showResult ([pscustomobject]@{ Title = 'Update scheduled'; Kind = 'Good'
                                Body = 'Save your work and close AutoCAD (and Revit if it is open). The update then installs by itself and you will see a notice when it is done.' })
                            $buttons.Controls.Clear()
                            & $addButton 'Close' $true { $form.Close() }
                        }
                    }
                    'Current' {
                        $option.Text = 'Install updates automatically (recommended)'
                        $ui.UserOff = $outcome.UserOff   # read later by the Close handler, after this block has returned
                        $option.Checked = -not $ui.UserOff; $option.Visible = $true
                        & $addButton 'Close' $true {
                            if ($option.Checked -eq $ui.UserOff) {
                                Start-HiddenScript (Join-Path $Root 'installer\Setup-BimCad.ps1') ('{0} -RepositoryPath "{1}"' -f $(if ($option.Checked) { '-Action EnableNotifications' } else { '-Action DisableNotifications' }), $Root)
                            }
                            $form.Close()
                        }
                    }
                    default { & $addButton 'Close' $true { $form.Close() } }
                }
            }
        }
        'Status' {
            { param($Output) & $showResult (Get-ConnectionStatusOutcome $Output (Test-ConnectorAgentRunning)); & $addButton 'Close' $true { $form.Close() } }
        }
    }

    $timer.Add_Tick({
        if (-not $ui.Process) { return }
        if (-not $ui.Process.HasExited -or -not $ui.Output.IsCompleted) {
            if ($ui.BackgroundAfter -gt 0 -and ([DateTime]::UtcNow - $ui.Started).TotalSeconds -ge $ui.BackgroundAfter) {
                # Leave the step running; only this window stops watching it.
                $timer.Stop()
                & $showResult ([pscustomobject]@{ Title = 'Syncing in the background'; Kind = 'Accent'
                    Body = 'Skills Sync is still working. You can close this window and keep working; a Windows notification shows the result when it is done.' })
                & $addButton 'Close' $true { $form.Close() }
            }
            return
        }
        $timer.Stop()
        $progress.Visible = $false
        $output = $ui.Output.Result
        $ui.Process.Dispose(); $ui.Process = $null
        & $finish $output
    })

    $form.Add_Shown({
        try {
            switch ($Name) {
                'SkillsSync' {
                    Start-ConnectorAgent $Root   # the agent announces the result if this window is closed first
                    # From AutoCAD, only approved AutoCAD skills are downloaded; saved skills of any kind are still sent.
                    & $run 'Syncing skills...' 'Sending your saved skills for review and downloading the latest approved AutoCAD skills.' `
                        (Get-ConnectorScript 'weekly-skill-collection.ps1' $Root) ('-Action Sync -Product AutoCAD -StateRoot "{0}"' -f $script:ActionPaths.StateRoot)
                }
                'CheckUpdates' {
                    & $run 'Checking for updates...' 'Looking for a newer approved version of Smart Connector.' `
                        (Join-Path $Root 'installer\Setup-BimCad.ps1') ('-Action CheckUpdate -RepositoryPath "{0}"' -f $Root)
                }
                'Status' {
                    & $run 'Checking the connection...' 'Looking for AutoCAD, Codex, Claude and the connector agent.' `
                        (Join-Path $Root 'installer\Setup-BimCad.ps1') ('-Action Status -Product AutoCAD -RepositoryPath "{0}"' -f $Root)
                }
            }
        }
        catch {
            & $showResult ([pscustomobject]@{ Title = 'Something went wrong'; Kind = 'Bad'; Body = $_.Exception.Message })
            & $addButton 'Close' $true { $form.Close() }
        }
    })

    $form.TopMost = $true
    [void]$form.ShowDialog()
    $timer.Stop()
    # A step still running (Skills Sync in the background) keeps writing to this process's pipes; wait for it
    # here, hidden, so it is never cut off when the window closes.
    if ($ui.Process -and -not $ui.Process.HasExited) { $ui.Process.WaitForExit() }
    $form.Dispose()
}

if (-not $LibraryOnly -and $MyInvocation.InvocationName -ne '.') { Show-ConnectorAction }
