# Smart Connector app: one window for the connector's status and everything it can do.
# Sections: Overview, Autodesk apps, AI connections, Workflow skills, Components, Updates, Settings,
# Diagnostics, Help. Opened from the Revit and AutoCAD buttons, the Start menu and the end of setup. Every
# action runs the existing setup, Skills Sync or update scripts. When it opens it checks for updates (at most
# once a day) and shows the weekly Skills Sync reminder; nothing of Smart Connector runs after it closes.
#   powershell -STA -File SmartConnectorApp.ps1 [-Section Skills]     (-SmokeTest builds every section and exits)
param(
    [ValidateSet('Overview', 'Autodesk', 'AI', 'Skills', 'Components', 'Updates', 'Settings', 'Diagnostics', 'Help')]
    [string]$Section = 'Overview',
    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot),
    [switch]$SmokeTest
)
$ErrorActionPreference = 'Stop'
# The setup .exe only installs files, so setup itself never starts PowerShell. On the first open the setup window
# runs instead (choose apps, team details); it opens this app again when it finishes.
$setupPending = Join-Path $RepositoryPath 'setup\setup-pending.txt'
$firstRunSetup = Join-Path $RepositoryPath 'setup\Install-Autodesk-MCP-Connector.ps1'
# The compiled Smart Connector program has the same setup window; it is used when it is installed.
$firstRunProgram = Join-Path $RepositoryPath 'bin\SmartConnector.exe'
if (-not $SmokeTest -and (Test-Path -LiteralPath $setupPending -PathType Leaf) -and (Test-Path -LiteralPath $firstRunProgram -PathType Leaf)) {
    Start-Process $firstRunProgram -WorkingDirectory $env:LOCALAPPDATA -ArgumentList 'setup'
    exit 0
}
if (-not $SmokeTest -and (Test-Path -LiteralPath $setupPending -PathType Leaf) -and (Test-Path -LiteralPath $firstRunSetup -PathType Leaf)) {
    Start-Process powershell.exe -WindowStyle Hidden -WorkingDirectory $env:LOCALAPPDATA -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File "{0}" -Install -PayloadFolder "{1}"' -f $firstRunSetup, $RepositoryPath)
    exit 0
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot 'Brand.ps1')
. (Join-Path $PSScriptRoot 'ConnectorStatus.ps1') -RepositoryPath $RepositoryPath
. (Join-Path $PSScriptRoot 'ConnectorActions.ps1') -RepositoryPath $RepositoryPath -LibraryOnly

$script:App = @{
    Section = $Section; Snapshot = $null; Repair = $null; RepairLines = New-Object System.Collections.Generic.List[string]
    Logs    = [ordered]@{
        'Setup log'            = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\setup.log'
        'Skills Sync log'      = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\weekly.log'
        'Usage upload log'     = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\usage-upload.log'
    }
    RequestPath = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\app-section.txt'
    Check = $null
}
$script:Sections = [ordered]@{
    Overview    = @('Overview', 'overview')
    Autodesk    = @('Autodesk apps', 'revit')
    AI          = @('AI connections', 'assistant')
    Skills      = @('Workflow skills', 'skills')
    Components  = @('Components', 'components')
    Updates     = @('Updates', 'updates')
    Settings    = @('Settings', 'settings')
    Diagnostics = @('Diagnostics and logs', 'diagnostics')
    Help        = @('Help', 'help')
}
$C = $script:BrandColors

# One window per user: a second start asks the running window to show the requested section.
$script:AppMutex = New-Object Threading.Mutex($false, 'Local\SmartConnector.App')
if (-not $SmokeTest -and -not $script:AppMutex.WaitOne(0)) {
    New-Item -ItemType Directory -Path (Split-Path $script:App.RequestPath) -Force | Out-Null
    Set-Content -LiteralPath $script:App.RequestPath -Value $Section -Encoding ASCII
    exit 0
}

# ---------- actions (each runs an existing script) ----------

# 1.2.0 > 1.2.0-beta.3 > 1.1.9; an unreadable version compares as equal.
function Compare-AppVersion {
    param([string]$Left, [string]$Right)
    $parse = { param($v) $m = [regex]::Match(([string]$v).Trim().TrimStart('v'), '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$'); if ($m.Success) { $m } else { $null } }
    $a = & $parse $Left; $b = & $parse $Right
    if (-not $a -or -not $b) { return 0 }
    foreach ($i in 1..3) { $d = [int]$a.Groups[$i].Value - [int]$b.Groups[$i].Value; if ($d) { return [Math]::Sign($d) } }
    $pa = $a.Groups[4].Value; $pb = $b.Groups[4].Value
    if ($pa -eq $pb) { return 0 }
    if (-not $pa) { return 1 }
    if (-not $pb) { return -1 }
    [Math]::Sign([string]::CompareOrdinal($pa, $pb))
}

function Start-AppScript {
    param([string]$Script, [string]$Arguments = '', [switch]$Wait)
    $path = Join-Path $RepositoryPath "installer\$Script"
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" {1}' -f $path, $Arguments
    if ($Wait) { (Start-Process powershell.exe -ArgumentList $argumentLine -WindowStyle Hidden -Wait -PassThru).ExitCode }
    else { $null = Start-Process powershell.exe -ArgumentList $argumentLine -WindowStyle Hidden }
}

function Invoke-AppAction {
    param([string]$Name)
    switch ($Name) {
        'SkillsSync'   { Start-AppScript 'ConnectorActions.ps1' '-Action SkillsSync' }
        'CheckUpdates' { Start-AppScript 'ConnectorActions.ps1' '-Action CheckUpdates' }
        'TestConnection' { Start-AppScript 'ConnectorActions.ps1' '-Action Status' }
        # The update window waits for Revit and AutoCAD to close, installs, and shows the result.
        'UpdateNow' { Start-UpdateWindow $RepositoryPath }
        'OpenSkillsFolder' {
            $folder = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\approved-skills'
            if (-not (Test-Path -LiteralPath $folder)) { $folder = Join-Path $RepositoryPath '.agents\skills' }
            Start-Process explorer.exe -ArgumentList ('"{0}"' -f $folder)
        }
        'PrivateSkills' {
            $list = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\excluded-skills.txt'
            if (-not (Test-Path -LiteralPath $list)) {
                New-Item -ItemType Directory -Path (Split-Path $list) -Force | Out-Null
                Set-Content -LiteralPath $list -Encoding UTF8 -Value @('# Skills listed here stay on this PC: Skills Sync never sends them for review.', '# One skill folder name per line.')
            }
            Start-Process notepad.exe -ArgumentList ('"{0}"' -f $list)
        }
        'OpenLogFolder' { Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector')) }
        'CopyDiagnostics' {
            [Windows.Forms.Clipboard]::SetText((Get-DiagnosticsText))
            [Windows.Forms.MessageBox]::Show($script:Form, 'The diagnostics summary is copied. Paste it into an email or chat to your administrator. It contains no passwords or tokens.', 'Smart Connector', 'OK', 'Information') | Out-Null
        }
        'Repair' { Start-Repair }
    }
}

function Set-SyncReminder {
    param([bool]$On)
    $runner = Get-ConnectorScript 'weekly-skill-collection.ps1' $RepositoryPath
    $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $runner, $(if ($On) { 'Enable' } else { 'Disable' })
    $code = (Start-Process powershell.exe -ArgumentList $line -WindowStyle Hidden -Wait -PassThru).ExitCode
    if ($code -ne 0) { [Windows.Forms.MessageBox]::Show($script:Form, 'The setting could not be saved. Try again, or open Diagnostics.', 'Smart Connector', 'OK', 'Warning') | Out-Null }
}

# When the app opens: look for an update in the background (at most once a day, unless switched off).
function Start-OpenCheck {
    $s = Get-ConnectorSnapshot
    if (-not (Test-UpdateCheckDue $s)) { return }
    Write-StatusDay (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\open-check.txt')
    $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action CheckUpdate -RepositoryPath "{1}"' -f (Join-Path $RepositoryPath 'installer\Setup-BimCad.ps1'), $RepositoryPath
    try { $script:App.Check = Start-Process powershell.exe -ArgumentList $line -WindowStyle Hidden -PassThru } catch { }
}

function Set-AutoUpdates {
    param([bool]$On)
    $action = if ($On) { 'EnableNotifications' } else { 'DisableNotifications' }
    $code = Start-AppScript 'Setup-BimCad.ps1' ('-Action {0} -RepositoryPath "{1}"' -f $action, $RepositoryPath) -Wait
    if ($code -ne 0) { [Windows.Forms.MessageBox]::Show($script:Form, 'The setting could not be saved. Try again, or open Diagnostics.', 'Smart Connector', 'OK', 'Warning') | Out-Null }
}

function Get-DiagnosticsText {
    $s = Get-ConnectorSnapshot
    $yesNo = { param($v) if ($v) { 'yes' } else { 'no' } }
    @(
        "Smart Connector $($s.Version) diagnostics, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        "Computer: $env:COMPUTERNAME   Windows user: $env:USERNAME"
        "Revit 2024 installed: $(& $yesNo $s.RevitInstalled)   add-in: $(& $yesNo $s.RevitAddin)   running: $(& $yesNo $s.RevitRunning)"
        "AutoCAD releases: $(if ($s.AutoCadReleases.Count) { $s.AutoCadReleases -join ', ' } else { 'none' })   panel: $(& $yesNo $s.AutoCadPanel)   running: $(& $yesNo $s.AutoCadRunning)"
        "Claude Desktop installed: $(& $yesNo $s.ClaudeDesktop.Installed)   connected: $(& $yesNo $s.ClaudeDesktop.Connected)"
        "Claude Code installed: $(& $yesNo $s.ClaudeCode.Installed)   connected: $(& $yesNo $s.ClaudeCode.Connected)"
        "Codex installed: $(& $yesNo $s.Codex.Installed)   connected: $(& $yesNo $s.Codex.Connected)"
        "Team skill service joined: $(& $yesNo $s.TeamJoined)   update checks: $(& $yesNo $s.AutoUpdates)   weekly sync reminder: $(& $yesNo $s.SyncReminder)"
        "Update ready: $(if ($s.AvailableVersion) { $s.AvailableVersion } else { 'none' })   last checked: $($s.LastChecked)"
        "Last Skills Sync: $($s.LastSync)   result: $($s.LastSyncStatus)   $($s.LastSyncReason)"
    ) -join "`r`n"
}

# Repair: setup again with the same choices, its output shown in the Components section.
function Start-Repair {
    if ($script:App.Repair) { return }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Install -RepositoryPath "{1}"' -f (Join-Path $RepositoryPath 'installer\Setup-BimCad.ps1'), $RepositoryPath
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($psi)
    $script:App.Repair = @{ Process = $process; Out = $process.StandardOutput.ReadLineAsync(); Err = $process.StandardError.ReadLineAsync() }
    $script:App.RepairLines.Clear(); $script:App.RepairLines.Add('Repair started...')
    Request-Section 'Components'
}

function Update-Repair {
    $repair = $script:App.Repair
    if (-not $repair) { return }
    foreach ($key in 'Out', 'Err') {
        while ($repair[$key] -and $repair[$key].IsCompleted) {
            $line = $repair[$key].Result
            if ($null -eq $line) { $repair[$key] = $null; break }
            if ($line -notmatch '^\[(PHASE|RESULT)\]') { $script:App.RepairLines.Add($line) }
            $reader = if ($key -eq 'Out') { $repair.Process.StandardOutput } else { $repair.Process.StandardError }
            $repair[$key] = $reader.ReadLineAsync()
        }
    }
    if ($repair.Process.HasExited -and -not $repair.Out -and -not $repair.Err) {
        $script:App.RepairLines.Add($(if ($repair.Process.ExitCode -eq 0) { 'Repair finished. Restart Revit, AutoCAD, Claude and Codex.' } else { 'Repair finished with problems. Open the setup log in Diagnostics.' }))
        $script:App.Repair = $null
    }
    if ($script:App.Section -eq 'Components' -and $script:RepairBox) {
        $script:RepairBox.Lines = $script:App.RepairLines.ToArray()
        $script:RepairBox.SelectionStart = $script:RepairBox.TextLength; $script:RepairBox.ScrollToCaret()
    }
}

# Section changes requested from inside the content run after the click finishes: rebuilding the section
# disposes the very control whose click handler is still running.
function Request-Section {
    param([string]$Name)
    $script:App.Pending = $Name
    $null = $script:Form.BeginInvoke([Windows.Forms.MethodInvoker]{ if ($script:App.Pending) { $next = $script:App.Pending; $script:App.Pending = $null; Show-Section $next } })
}

function Format-When {
    param([string]$Value, [switch]$Utc)
    try { $when = [DateTime]::Parse($Value); if ($Utc) { $when = $when.ToLocalTime() }; $when.ToString('g') } catch { $Value }
}

# ---------- layout helpers (positions in 96-DPI units; the form scales them) ----------

function Add-Text {
    param([Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 0, [float]$Size = 10, [switch]$Bold, [switch]$Muted, [Drawing.Color]$Color = [Drawing.Color]::Empty)
    $label = New-BrandLabel $Text $X $Y -Width $Width -Size $Size -Bold:$Bold -Muted:$Muted
    if (-not $Color.IsEmpty) { $label.ForeColor = $Color }
    $label.BackColor = [Drawing.Color]::Transparent
    $Parent.Controls.Add($label); $label
}

function Add-ActionButton {
    param([Windows.Forms.Control]$Parent, [string]$Text, [string]$Action, [int]$X, [int]$Y, [switch]$Primary, [int]$Width = 0)
    if ($Width -le 0) { $Width = [Math]::Max(96, [Windows.Forms.TextRenderer]::MeasureText($Text, (New-BrandFont 10)).Width + 32) }
    $button = New-BrandButton $Text -Primary:$Primary -Width $Width
    $button.Height = 32; $button.Location = New-Object Drawing.Point($X, $Y); $button.Tag = $Action
    $button.Add_Click({ Invoke-AppAction $this.Tag })
    $Parent.Controls.Add($button); $button
}

function Add-SectionLink {
    param([Windows.Forms.Control]$Parent, [string]$Text, [string]$Target, [int]$X, [int]$Y)
    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = $Text; $link.AutoSize = $true; $link.Location = New-Object Drawing.Point($X, $Y)
    $link.LinkColor = $C.Link; $link.ActiveLinkColor = $C.Header; $link.BackColor = [Drawing.Color]::Transparent; $link.Tag = $Target
    $link.Add_LinkClicked({ Request-Section $this.Tag })
    $Parent.Controls.Add($link); $link
}

function Add-Badge {
    param([Windows.Forms.Control]$Parent, [string]$Text, [string]$Kind, [int]$X, [int]$Y, [switch]$AlignRight)
    $badge = New-BrandBadge $Text $Kind
    $x = if ($AlignRight) { $X - [int]($badge.Width / (Get-BrandScale)) } else { $X }
    $badge.Location = New-Object Drawing.Point($x, $Y)
    $Parent.Controls.Add($badge); $badge
}

# A row inside a card: icon, title and detail, a status badge on the right, optionally a button.
function Add-StatusRow {
    param([Windows.Forms.Control]$Card, [int]$Y, [string]$Icon, [string]$Title, [string]$Detail, [string]$Status, [string]$Kind, [string]$ButtonText = '', [string]$Action = '')
    $Card.Controls.Add((New-BrandIconBox $Icon 22 18 ($Y + 14)))
    $null = Add-Text $Card $Title 54 ($Y + 8) -Bold
    $null = Add-Text $Card $Detail 54 ($Y + 30) -Width 470 -Size 9 -Muted
    $right = 812
    if ($ButtonText) { $null = Add-ActionButton $Card $ButtonText $Action 704 ($Y + 12) -Width 92; $right = 692 }
    $null = Add-Badge $Card $Status $Kind $right ($Y + 16) -AlignRight
    if ($Y -gt 0) {
        $line = New-Object Windows.Forms.Panel; $line.BackColor = $C.Line; $line.Height = 1; $line.Width = 800
        $line.Location = New-Object Drawing.Point(16, $Y); $Card.Controls.Add($line)
    }
}

function Add-Heading {
    param([string]$Title, [string]$Text)
    $null = Add-Text $script:Content $Title 32 24 -Size 16 -Bold
    if ($Text) { $null = Add-Text $script:Content $Text 33 58 -Width 780 -Muted }
}

function Get-ClientStatus {
    param($Client)
    if ($Client.Connected) { return @('Connected', 'Good') }
    if ($Client.Installed) { return @('Not connected', 'Warn') }
    @('Not installed', 'Off')
}

# ---------- sections ----------

function Show-Overview {
    param($s)
    $headline = Get-ConnectorHeadline $s
    $hero = New-BrandCard 32 24 832 92; $script:Content.Controls.Add($hero)
    $icon = switch ($headline.Kind) { 'Good' { 'check' } 'Bad' { 'error' } default { 'warning' } }
    $hero.Controls.Add((New-BrandIconBox $icon 28 22 30 -Color $script:BrandStatus[$headline.Kind][1]))
    $null = Add-Text $hero $headline.Title 66 20 -Size 13 -Bold
    $null = Add-Text $hero $headline.Text 67 50 -Width 480 -Muted
    $null = Add-ActionButton $hero 'Check for updates' 'CheckUpdates' 548 30 -Width 140
    $null = Add-ActionButton $hero 'Skills Sync' 'SkillsSync' 698 30 -Primary -Width 116
    # Reminders: a new version is ready, or the weekly Skills Sync is due.
    $reminder = $null
    if ($s.AvailableVersion -and (Compare-AppVersion $s.AvailableVersion $s.Version) -gt 0) {
        $reminder = @('updates', ("Smart Connector {0} is ready to install." -f $s.AvailableVersion), 'Update now', 'UpdateNow')
    }
    elseif (Test-SyncReminderDue $s) {
        $days = if ($s.LastSyncDay -lt 0) { 'Skills have not been synced on this computer yet.' } else { 'Your last Skills Sync was {0} days ago.' -f [int][Math]::Floor((Get-StatusToday) - $s.LastSyncDay) }
        $reminder = @('sync', "$days Sync to send your saved skills for review and get newly approved ones.", 'Sync now', 'SkillsSync')
    }
    $top = 136
    if ($reminder) {
        $strip = New-BrandCard 32 128 832 52; $script:Content.Controls.Add($strip)
        $strip.Controls.Add((New-BrandIconBox $reminder[0] 18 16 17))
        $null = Add-Text $strip $reminder[1] 48 16 -Width 620
        $null = Add-ActionButton $strip $reminder[2] $reminder[3] 698 9 -Primary -Width 116
        $top = 196
    }

    $cards = @(
        @('Revit 2024', 'revit', $(if ($s.RevitAddin) { @('Ready', 'Good') } elseif ($s.RevitInstalled) { @('Add-in missing', 'Warn') } else { @('Not installed', 'Off') }),
            $(if ($s.RevitRunning) { 'Revit is open.' } else { 'Revit is closed.' }) + "`n" + $(if ($s.RevitAddin) { 'Smart Connector tab installed.' } else { 'No add-in for this user.' }), 'Autodesk'),
        @('AutoCAD', 'autocad', $(if ($s.AutoCadPanel) { @('Ready', 'Good') } elseif ($s.AutoCadInstalled) { @('Panel missing', 'Warn') } else { @('Not installed', 'Off') }),
            $(if ($s.AutoCadRunning) { 'AutoCAD is open.' } else { 'AutoCAD is closed.' }) + "`nAdd-ins panel with AI Markup.", 'Autodesk'),
        @('Claude', 'claude', $(if ($s.ClaudeDesktop.Connected -or $s.ClaudeCode.Connected) { @('Connected', 'Good') } elseif ($s.ClaudeDesktop.Installed -or $s.ClaudeCode.Installed) { @('Not connected', 'Warn') } else { @('Not installed', 'Off') }),
            "Claude Desktop: $((Get-ClientStatus $s.ClaudeDesktop)[0].ToLower())`nClaude Code: $((Get-ClientStatus $s.ClaudeCode)[0].ToLower())", 'AI'),
        @('Codex', 'codex', (Get-ClientStatus $s.Codex), $(if ($s.Codex.Installed) { 'Codex uses the connector tools.' } else { 'Install Codex, then choose Repair.' }) + "`n ", 'AI'),
        @('Workflow skills', 'skills', @("$(@(Get-InstalledWorkflowSkills).Count) installed", 'Good'),
            $(if ($s.LastSync) { 'Last sync ' + (Format-When $s.LastSync) } else { 'Not synced yet.' }) + "`n" + $(if ($s.TeamJoined) { 'Joined to the team skill service.' } else { 'Not joined to the team.' }), 'Skills'),
        @('Updates', 'updates', $(if ($s.AvailableVersion -and $s.AvailableVersion -ne $s.Version) { @("$($s.AvailableVersion) ready", 'Info') } else { @('Up to date', 'Good') }),
            "Version $($s.Version)`n" + $(if ($s.AutoUpdates) { 'Checked when Revit, AutoCAD or this app opens.' } else { 'Update checks are off.' }), 'Updates')
    )
    for ($i = 0; $i -lt $cards.Count; $i++) {
        $spec = $cards[$i]
        $card = New-BrandCard (32 + ($i % 3) * 284) ($top + [Math]::Floor($i / 3) * 168) 264 152
        $script:Content.Controls.Add($card)
        $card.Controls.Add((New-BrandIconBox $spec[1] 22 16 18))
        $null = Add-Text $card $spec[0] 48 18 -Bold
        $null = Add-Badge $card $spec[2][0] $spec[2][1] 16 52
        $null = Add-Text $card $spec[3] 16 86 -Width 236 -Size 9 -Muted
        $null = Add-SectionLink $card 'Details' $spec[4] 16 124
    }
}

function Show-Autodesk {
    param($s)
    Add-Heading 'Autodesk apps' 'Smart Connector adds a tab to Revit and a panel to AutoCAD. Claude and Codex then work with the open model or drawing.'
    $card = New-BrandCard 32 96 832 152; $script:Content.Controls.Add($card)
    Add-StatusRow $card 0 'revit' 'Revit 2024' $(if (-not $s.RevitInstalled) { 'Not installed on this computer.' } elseif ($s.RevitAddin) { 'Smart Connector tab installed' + $(if ($s.RevitRunning) { '; Revit is open.' } else { '.' }) } else { 'Installed, but the add-in is missing. Choose Repair in Components.' }) `
        $(if ($s.RevitAddin) { 'Ready' } elseif ($s.RevitInstalled) { 'Add-in missing' } else { 'Not installed' }) $(if ($s.RevitAddin) { 'Good' } elseif ($s.RevitInstalled) { 'Warn' } else { 'Off' })
    Add-StatusRow $card 76 'autocad' $(if ($s.AutoCadReleases.Count) { 'AutoCAD (' + ($s.AutoCadReleases -join ', ') + ')' } else { 'AutoCAD' }) $(if (-not $s.AutoCadInstalled) { 'Not installed on this computer.' } elseif ($s.AutoCadPanel) { 'Add-ins panel with AI Markup, Skills Sync and settings' + $(if ($s.AutoCadRunning) { '; AutoCAD is open.' } else { '.' }) } else { 'Installed, but the panel is missing. Choose Repair in Components.' }) `
        $(if ($s.AutoCadPanel) { 'Ready' } elseif ($s.AutoCadInstalled) { 'Panel missing' } else { 'Not installed' }) $(if ($s.AutoCadPanel) { 'Good' } elseif ($s.AutoCadInstalled) { 'Warn' } else { 'Off' })
    $null = Add-Text $script:Content 'Revit 2025 and later are not supported yet. A program opened after setup needs a restart to show the connector.' 33 264 -Width 780 -Size 9 -Muted
    $null = Add-ActionButton $script:Content 'Test connection' 'TestConnection' 32 296 -Primary -Width 140
}

function Show-AI {
    param($s)
    Add-Heading 'AI connections' 'Setup adds Smart Connector to each AI app''s own settings for this Windows user. Your other connectors are kept.'
    $card = New-BrandCard 32 96 832 228; $script:Content.Controls.Add($card)
    $rows = @(
        @('claude', 'Claude Desktop', $s.ClaudeDesktop, 'Listed as "Smart Connector" in its connectors.'),
        @('claude', 'Claude Code', $s.ClaudeCode, 'User-level MCP server named autodesk.'),
        @('codex', 'Codex', $s.Codex, 'MCP server named autodesk in config.toml.')
    )
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $status = Get-ClientStatus $rows[$i][2]
        $detail = if ($rows[$i][2].Connected) { $rows[$i][3] } elseif ($rows[$i][2].Installed) { 'Installed but not connected. Choose Repair.' } else { 'Not installed. It connects when you install it and choose Repair.' }
        Add-StatusRow $card ($i * 76) $rows[$i][0] $rows[$i][1] $detail $status[0] $status[1]
    }
    $null = Add-Text $script:Content 'After connecting, restart Claude and Codex so they load the connector.' 33 340 -Width 780 -Size 9 -Muted
    $null = Add-ActionButton $script:Content 'Test connection' 'TestConnection' 32 372 -Primary -Width 140
    $null = Add-ActionButton $script:Content 'Repair connections' 'Repair' 182 372 -Width 160
}

function Show-Skills {
    param($s)
    $skills = @(Get-InstalledWorkflowSkills)
    Add-Heading 'Workflow skills' ("{0} approved skills are installed for Claude and Codex. Skills Sync sends your saved skills for review and downloads newly approved ones." -f $skills.Count)
    $null = Add-ActionButton $script:Content 'Skills Sync' 'SkillsSync' 32 96 -Primary -Width 116
    $null = Add-ActionButton $script:Content 'Open skills folder' 'OpenSkillsFolder' 158 96 -Width 150
    $null = Add-ActionButton $script:Content 'Private skills' 'PrivateSkills' 318 96 -Width 120
    $last = if ($s.LastSync) { 'Last sync ' + (Format-When $s.LastSync) + $(if ($s.LastSyncStatus -in 'ok', 'completed') { ": $($s.SyncSubmitted) sent for review, $($s.SyncUpdated) downloaded." } elseif ($s.LastSyncReason) { ': ' + $s.LastSyncReason } else { '.' }) } else { 'Skills have not been synced on this computer yet.' }
    $null = Add-Text $script:Content $last 33 138 -Width 780 -Size 9 -Muted
    $list = New-Object Windows.Forms.ListView
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.HeaderStyle = 'Nonclickable'; $list.BorderStyle = 'FixedSingle'
    $list.Location = New-Object Drawing.Point(32, 166); $list.Size = New-Object Drawing.Size(832, 400)
    $null = $list.Columns.Add('Skill', 520); $null = $list.Columns.Add('Category', 280)
    $groups = @{}
    foreach ($skill in $skills) {
        if (-not $groups.ContainsKey($skill.Category)) { $groups[$skill.Category] = $list.Groups.Add($skill.Category, $skill.CategoryTitle) }
        $item = New-Object Windows.Forms.ListViewItem($skill.Name, $groups[$skill.Category])
        $null = $item.SubItems.Add($skill.CategoryTitle); $null = $list.Items.Add($item)
    }
    $script:Content.Controls.Add($list)
}

function Show-Components {
    param($s)
    Add-Heading 'Components' 'Everything Smart Connector installed for this Windows user. Repair runs setup again with your choices.'
    $card = New-BrandCard 32 96 832 380; $script:Content.Controls.Add($card)
    $rows = @(
        @('connector', 'Smart Connector', "Version $($s.Version)", $(if ($s.Installed) { @('Installed', 'Good') } else { @('Missing', 'Bad') })),
        @('revit', 'Revit 2024 add-in', 'Smart Connector tab in Revit', $(if ($s.RevitAddin) { @('Installed', 'Good') } elseif ($s.RevitInstalled) { @('Missing', 'Warn') } else { @('Not needed', 'Off') })),
        @('autocad', 'AutoCAD panel', 'Add-ins tab buttons and AI Markup', $(if ($s.AutoCadPanel) { @('Installed', 'Good') } elseif ($s.AutoCadInstalled) { @('Missing', 'Warn') } else { @('Not needed', 'Off') })),
        @('team', 'Team skill service', 'Shares your saved skills for review', $(if ($s.TeamJoined) { @('Joined', 'Good') } else { @('Not joined', 'Off') })),
        @('updates', 'Update checks', 'When Revit, AutoCAD or this app opens. Nothing runs in the background.', $(if ($s.AutoUpdates) { @('On', 'Good') } else { @('Off', 'Off') }))
    )
    for ($i = 0; $i -lt $rows.Count; $i++) { Add-StatusRow $card ($i * 76) $rows[$i][0] $rows[$i][1] $rows[$i][2] $rows[$i][3][0] $rows[$i][3][1] }
    $null = Add-ActionButton $script:Content $(if ($script:App.Repair) { 'Repairing...' } else { 'Repair' }) 'Repair' 32 492 -Primary -Width 116
    $script:RepairBox = New-Object Windows.Forms.TextBox
    $script:RepairBox.Multiline = $true; $script:RepairBox.ReadOnly = $true; $script:RepairBox.ScrollBars = 'Vertical'
    $script:RepairBox.Font = New-BrandFont 8.5 -Family 'Consolas'; $script:RepairBox.BackColor = $C.Canvas
    $script:RepairBox.Location = New-Object Drawing.Point(32, 534); $script:RepairBox.Size = New-Object Drawing.Size(832, 110)
    $script:RepairBox.Visible = $script:App.RepairLines.Count -gt 0
    $script:RepairBox.Lines = $script:App.RepairLines.ToArray()
    $script:Content.Controls.Add($script:RepairBox)
}

function Show-Updates {
    param($s)
    Add-Heading 'Updates' 'Smart Connector looks for a new version once a day, when you open Revit, AutoCAD or this app, and asks before installing. Updates install when Revit and AutoCAD are closed.'
    $card = New-BrandCard 32 96 832 152; $script:Content.Controls.Add($card)
    $ready = $s.AvailableVersion -and (Compare-AppVersion $s.AvailableVersion $s.Version) -gt 0
    Add-StatusRow $card 0 'connector' "Installed version $($s.Version)" $(if ($s.LastChecked) { 'Last checked ' + (Format-When $s.LastChecked -Utc) } else { 'Not checked yet.' }) $(if ($ready) { "$($s.AvailableVersion) ready" } else { 'Up to date' }) $(if ($ready) { 'Info' } else { 'Good' })
    Add-StatusRow $card 76 'updates' 'Update checks' $(if ($s.AutoUpdates) { 'On: you are asked when a new version is ready.' } else { 'Off: use Check for updates.' }) $(if ($s.AutoUpdates) { 'On' } else { 'Off' }) $(if ($s.AutoUpdates) { 'Good' } else { 'Off' })
    $null = Add-ActionButton $script:Content 'Check for updates' 'CheckUpdates' 32 264 -Width 140
    if ($ready) { $null = Add-ActionButton $script:Content 'Update now' 'UpdateNow' 182 264 -Primary -Width 116 }
}

function Show-Settings {
    param($s)
    Add-Heading 'Settings' 'Changes apply to this Windows user.'
    $auto = New-Object Windows.Forms.CheckBox
    $auto.Text = 'Check for updates when Revit, AutoCAD or Smart Connector opens (recommended)'; $auto.AutoSize = $true; $auto.Checked = $s.AutoUpdates
    $auto.Font = New-BrandFont 10.5 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'; $auto.Location = New-Object Drawing.Point(32, 100)
    $auto.Add_Click({ $this.Enabled = $false; Set-AutoUpdates $this.Checked; Request-Section 'Settings' })
    $script:Content.Controls.Add($auto)
    $null = Add-Text $script:Content 'At most once a day. You are asked before anything is installed, and it installs when Revit and AutoCAD are closed. When this is off, use Check for updates.' 52 130 -Width 760 -Size 9 -Muted
    $remind = New-Object Windows.Forms.CheckBox
    $remind.Text = 'Remind me weekly to sync my skills'; $remind.AutoSize = $true; $remind.Checked = $s.SyncReminder; $remind.Enabled = $s.TeamJoined
    $remind.Font = New-BrandFont 10.5 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'; $remind.Location = New-Object Drawing.Point(32, 166)
    $remind.Add_Click({ $this.Enabled = $false; Set-SyncReminder $this.Checked; Request-Section 'Settings' })
    $script:Content.Controls.Add($remind)
    $null = Add-Text $script:Content $(if ($s.TeamJoined) { 'When your last Skills Sync is more than a week old, Revit, AutoCAD and this app remind you once a day.' } else { 'Available once this computer has joined the team skill service.' }) 52 196 -Width 760 -Size 9 -Muted
    $null = Add-Text $script:Content 'Private skills' 32 242 -Bold
    $null = Add-Text $script:Content 'Skills on this list stay on your computer: Skills Sync never sends them for review.' 32 266 -Width 760 -Size 9 -Muted
    $null = Add-ActionButton $script:Content 'Edit private skills' 'PrivateSkills' 32 294 -Width 150
    $null = Add-Text $script:Content 'Team skill service' 32 350 -Bold
    $null = Add-Text $script:Content $(if ($s.TeamJoined) { 'This computer has joined. Your administrator sees its name, your name and email, and which skills and tools are used (names and counts only). Usage counts are sent only when you run Skills Sync.' } else { 'Not joined. Ask your administrator for the team setup file to join.' }) 32 374 -Width 760 -Size 9 -Muted
}

function Show-Diagnostics {
    param($s)
    Add-Heading 'Diagnostics and logs' 'When something does not work, copy the summary and send it to your administrator with the log they ask for.'
    $null = Add-ActionButton $script:Content 'Copy diagnostics summary' 'CopyDiagnostics' 32 96 -Primary -Width 200
    $null = Add-ActionButton $script:Content 'Open log folder' 'OpenLogFolder' 242 96 -Width 140
    $summary = New-Object Windows.Forms.TextBox
    $summary.Multiline = $true; $summary.ReadOnly = $true; $summary.ScrollBars = 'Vertical'; $summary.BackColor = $C.Canvas
    $summary.Font = New-BrandFont 9 -Family 'Consolas'; $summary.Location = New-Object Drawing.Point(32, 142); $summary.Size = New-Object Drawing.Size(832, 200)
    $summary.Text = Get-DiagnosticsText
    $script:Content.Controls.Add($summary)
    $y = 362
    foreach ($name in $script:App.Logs.Keys) {
        $path = $script:App.Logs[$name]
        if (Test-Path -LiteralPath $path) {
            $link = New-Object Windows.Forms.LinkLabel
            $link.Text = $name; $link.AutoSize = $true; $link.Location = New-Object Drawing.Point(32, $y); $link.LinkColor = $C.Link; $link.Tag = $path
            $link.Add_LinkClicked({ Start-Process notepad.exe -ArgumentList ('"{0}"' -f $this.Tag) })
            $script:Content.Controls.Add($link)
        }
        else { $null = Add-Text $script:Content "$name (not created yet)" 32 $y -Muted }
        $y += 28
    }
}

function Show-Help {
    param($s)
    Add-Heading 'Help' "Smart Connector $($s.Version) connects Claude and Codex to Revit and AutoCAD on this computer."
    $topics = @(
        @('In Revit', 'Open a model, then ask Claude or Codex to work with it. The Smart Connector tab has Skills Sync, Connection Status, updates and settings.'),
        @('In AutoCAD', 'Open a drawing and use the Add-ins tab. AI Markup lets you sketch on the drawing and type a task; paste the copied request into Claude. Clear Markup removes it.'),
        @('Workflow skills', 'Approved team workflows are installed for Claude and Codex. Save your own skills as usual; Skills Sync sends them to your administrator for review.'),
        @('Updates', 'Once a day, opening Revit, AutoCAD or this app looks for a new version and asks you. Choose Update now, save your work and close Revit and AutoCAD; the update window installs it.'),
        @('Something is wrong', 'Open Diagnostics, copy the summary and send it to your administrator. Repair in Components fixes most connection problems.')
    )
    $y = 100
    foreach ($topic in $topics) {
        $null = Add-Text $script:Content $topic[0] 32 $y -Bold
        $text = Add-Text $script:Content $topic[1] 32 ($y + 24) -Width 800 -Muted
        $y += 34 + [int]($text.PreferredHeight / (Get-BrandScale)) + 14
    }
}

# ---------- window ----------

function Show-Section {
    param([string]$Name)
    if (-not $script:Sections.Contains($Name)) { $Name = 'Overview' }
    $script:App.Section = $Name
    $script:App.Snapshot = Get-ConnectorSnapshot
    foreach ($button in $script:NavButtons) {
        $on = $button.Tag -eq $Name
        $button.BackColor = if ($on) { [Drawing.Color]::FromArgb(36, 55, 90) } else { $C.Header }
        $button.ForeColor = if ($on) { [Drawing.Color]::White } else { $C.RailText }
        $button.Font = if ($on) { New-BrandFont 10 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold' } else { New-BrandFont 10 }
    }
    $script:Content.SuspendLayout()
    $old = @($script:Content.Controls); $script:Content.Controls.Clear(); foreach ($control in $old) { $control.Dispose() }
    $script:RepairBox = $null
    & (Get-Command "Show-$Name") $script:App.Snapshot
    $script:Content.ResumeLayout()
    $script:Form.Text = 'Smart Connector - ' + $script:Sections[$Name][0]
}

$script:Form = New-BrandForm -Width 1120 -Height 720
$script:Form.Text = 'Smart Connector'
$script:Form.FormBorderStyle = 'Sizable'; $script:Form.MaximizeBox = $true
$script:Form.MinimumSize = New-Object Drawing.Size(980, 640)
$script:Form.BackColor = $C.Canvas

$script:Content = New-Object Windows.Forms.Panel
$script:Content.Dock = 'Fill'; $script:Content.AutoScroll = $true; $script:Content.BackColor = $C.Canvas
$script:Form.Controls.Add($script:Content)

$nav = New-Object Windows.Forms.Panel
$nav.Dock = 'Left'; $nav.Width = 224; $nav.BackColor = $C.Header
$script:Form.Controls.Add($nav)
$brand = New-Object Windows.Forms.PictureBox
$brand.Image = Get-BrandImage 64; $brand.SizeMode = 'Zoom'; $brand.Size = New-Object Drawing.Size(36, 36); $brand.Location = New-Object Drawing.Point(18, 18)
$nav.Controls.Add($brand)
$title = New-BrandLabel 'Smart Connector' 62 26 -Size 11 -Bold; $title.ForeColor = [Drawing.Color]::White; $nav.Controls.Add($title)
$script:NavButtons = @()
$y = 76
foreach ($key in $script:Sections.Keys) {
    $button = New-Object Windows.Forms.Button
    $button.Text = '   ' + $script:Sections[$key][0]; $button.Tag = $key
    $button.FlatStyle = 'Flat'; $button.FlatAppearance.BorderSize = 0
    $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(30, 46, 76)
    $button.TextAlign = 'MiddleLeft'; $button.ImageAlign = 'MiddleLeft'; $button.TextImageRelation = 'ImageBeforeText'
    $button.Image = Get-BrandIconImage $script:Sections[$key][1] 18 ([Drawing.Color]::FromArgb(200, 212, 230))
    $button.Padding = New-Object Windows.Forms.Padding(12, 0, 0, 0)
    $button.Size = New-Object Drawing.Size(208, 40); $button.Location = New-Object Drawing.Point(8, $y)
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.Add_Click({ Show-Section $this.Tag })
    $nav.Controls.Add($button); $script:NavButtons += $button
    $y += 42
}
$footer = New-BrandLabel ("Version {0}`n{1}" -f $(if (Test-Path (Join-Path $RepositoryPath 'VERSION')) { (Get-Content (Join-Path $RepositoryPath 'VERSION') -Raw).Trim() } else { '' }), $env:COMPUTERNAME) 18 612 -Size 8.5
$footer.ForeColor = $C.RailMuted; $footer.Anchor = 'Bottom, Left'; $nav.Controls.Add($footer)

if ($SmokeTest) {
    foreach ($key in $script:Sections.Keys) { Show-Section $key }
    $script:Form.Dispose()
    'SMOKE_OK'
    exit 0
}

# Timer: Repair output, requests from a second start, and a light refresh of the Overview.
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$script:App.Ticks = 0
$timer.Add_Tick({
    try {
        Update-Repair
        # The update check started on opening has finished: show its result.
        if ($script:App.Check -and $script:App.Check.HasExited) {
            $script:App.Check = $null
            if ($script:App.Section -in 'Overview', 'Updates') { Show-Section $script:App.Section }
        }
        if (Test-Path -LiteralPath $script:App.RequestPath) {
            $requested = (Get-Content -LiteralPath $script:App.RequestPath -Raw).Trim()
            Remove-Item -LiteralPath $script:App.RequestPath -Force
            if ($script:Form.WindowState -eq 'Minimized') { $script:Form.WindowState = 'Normal' }
            $script:Form.Activate(); Show-Section $requested
        }
        $script:App.Ticks++
        if ($script:App.Section -eq 'Overview' -and $script:App.Ticks % 60 -eq 0) { Show-Section 'Overview' }
    }
    catch { }
})
$script:Form.Add_Shown({ $script:Form.Activate(); $timer.Start(); try { Start-OpenCheck } catch { } })
Show-Section $Section
[void]$script:Form.ShowDialog()
$timer.Stop(); $script:Form.Dispose()
$script:AppMutex.ReleaseMutex()
