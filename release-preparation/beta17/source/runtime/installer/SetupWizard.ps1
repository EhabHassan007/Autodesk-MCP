# Smart Connector setup wizard: Welcome (with the terms), System check, Choose apps, AI connections,
# Install (live steps) and Finish, with a step rail on the left. Dot-source after WinForms is loaded, then call
# Show-SetupWizard. The page logic below the UI section is plain functions so it can be tested.

. (Join-Path $PSScriptRoot 'Brand.ps1')
. (Join-Path $PSScriptRoot 'TeamJoinDialog.ps1')

$script:WizardSteps = @(
    @{ Id = 'files';          Label = 'Install connector files' },
    @{ Id = 'skills';         Label = 'Install workflow skills for Codex and Claude' },
    @{ Id = 'revit';          Label = 'Revit 2024 add-in' },
    @{ Id = 'autocad';        Label = 'AutoCAD Add-ins panel' },
    @{ Id = 'codex';          Label = 'Connect Codex' },
    @{ Id = 'claude_desktop'; Label = 'Connect Claude Desktop' },
    @{ Id = 'claude_code';    Label = 'Connect Claude Code' },
    @{ Id = 'team';           Label = 'Join the team skill service' },
    @{ Id = 'updates';        Label = 'Automatic updates' }
)

function Get-TermsVersion {
    param([string]$Path)
    $line = Get-Content -LiteralPath $Path -TotalCount 5 | Where-Object { $_ -match '^Version\s+(\S+)' } | Select-Object -First 1
    if ($line -match '^Version\s+(\S+)') { return $Matches[1] }
    'unversioned'
}

function Save-TermsAcceptance {
    param([string]$Version, [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'))
    New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    @{ terms_version = $Version; accepted_utc = [DateTime]::UtcNow.ToString('o'); windows_user = $env:USERNAME } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $StateDirectory 'terms-accepted.json') -Encoding UTF8
}

# Reads one line of Setup-BimCad output. Explicit markers drive the step list:
#   [PHASE] <step>              the step is now running
#   [RESULT] <step>=<status> …  ok | skipped | failed
#   [ENROLLMENT_*] tags         map onto the team step
function ConvertFrom-SetupOutputLine {
    param([string]$Line)
    if ($Line -match '\[PHASE\]\s+([a-z_]+)') { return [pscustomobject]@{ Step = $Matches[1]; Status = 'running'; Detail = '' } }
    if ($Line -match '\[RESULT\]\s+([a-z_]+)=(ok|skipped|failed)\s*(.*)$') {
        return [pscustomobject]@{ Step = $Matches[1]; Status = $Matches[2]; Detail = $Matches[3].Trim() }
    }
    if ($Line -match '\[ENROLLMENT_(OK|UNCHANGED)\]') { return [pscustomobject]@{ Step = 'team'; Status = 'ok'; Detail = '' } }
    if ($Line -match '\[ENROLLMENT_FAILED\]\s*(.*)$') { return [pscustomobject]@{ Step = 'team'; Status = 'failed'; Detail = $Matches[1].Trim() } }
    if ($Line -match '\[ENROLLMENT_(PENDING|MISSING)\]') { return [pscustomobject]@{ Step = 'team'; Status = 'skipped'; Detail = 'Not joined' } }
    $null
}

# Windows command-line quoting for ProcessStartInfo.Arguments.
function ConvertTo-CommandLine {
    param([string[]]$Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -eq '') { '""' }
        elseif ($_ -notmatch '[\s"]') { $_ }
        else { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
}

# What this computer has, for the System check and the defaults of Choose apps. Files, registry and
# process list only, so the page opens at once.
function Get-SetupSystemCheck {
    $programFiles = $env:ProgramFiles
    $revitYears = @(Get-ChildItem -Path (Join-Path $programFiles 'Autodesk\Revit 20*\RevitAPI.dll') -File -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.DirectoryName -match 'Revit (20\d\d)$') { [int]$Matches[1] } } | Sort-Object -Unique)
    $acadNames = @{ 'R23.0' = '2019'; 'R23.1' = '2020'; 'R24.0' = '2021'; 'R24.1' = '2022'; 'R24.2' = '2023'; 'R24.3' = '2024'; 'R25.0' = '2025'; 'R25.1' = '2026'; 'R26.0' = '2027' }
    $acad = @(Get-AutoCadReleasesInstalled | ForEach-Object { if ($acadNames.ContainsKey($_)) { $acadNames[$_] } else { $_ } })
    $netRelease = 0
    try { $netRelease = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release } catch { }
    [pscustomobject]@{
        Windows64      = [Environment]::Is64BitOperatingSystem
        NetOk          = $netRelease -ge 528040
        Revit2024      = $revitYears -contains 2024
        RevitOther     = @($revitYears | Where-Object { $_ -ne 2024 })
        RevitRunning   = [bool](Get-Process -Name Revit -ErrorAction SilentlyContinue)
        AutoCad        = $acad
        ClaudeDesktop  = Test-ClaudeDesktopInstalled
        ClaudeCode     = Test-CommandOnPath 'claude'
        Codex          = Test-CommandOnPath 'codex'
    }
}

function Show-SetupWizard {
    param(
        [Parameter(Mandatory = $true)][string]$CoreSetup,
        [Parameter(Mandatory = $true)][string[]]$CoreArguments,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string]$Version = '',
        [bool]$AskDetails = $false,
        [bool]$HasEnrollmentFile = $false,
        [switch]$SmokeTest
    )
    . (Join-Path $PSScriptRoot 'ConnectorStatus.ps1') -RepositoryPath (Split-Path -Parent $PSScriptRoot)
    $termsPath = Join-Path $PSScriptRoot 'TERMS.txt'
    $termsVersion = Get-TermsVersion $termsPath
    $C = $script:BrandColors
    $script:wizard = @{ Page = 0; Result = 'cancelled'; Process = $null; Reads = @{}; Status = @{}; Details = @{}; Join = $null; ExitCode = $null; OpenApp = $false }
    $check = Get-SetupSystemCheck
    $script:wizard.Check = $check
    $installRoot = Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'
    for ($i = 0; $i -lt $CoreArguments.Count - 1; $i++) { if ($CoreArguments[$i] -eq '-RepositoryPath') { $installRoot = $CoreArguments[$i + 1] } }

    $form = New-BrandForm -Width 760 -Height 520
    $form.Text = 'Smart Connector Setup'
    $rail = New-BrandStepRail -Steps @('Welcome', 'System check', 'Choose apps', 'AI connections', 'Install', 'Finish') -Footer $(if ($Version) { "Version $Version" } else { '' })
    $footer = New-Object Windows.Forms.Panel
    $footer.Dock = 'Bottom'; $footer.Height = 64; $footer.BackColor = [Drawing.Color]::FromArgb(248, 250, 252)
    $back = New-BrandButton 'Back' -Width 96; $back.Location = New-Object Drawing.Point(198, 14)
    $next = New-BrandButton 'Next' -Primary -Width 112; $next.Location = New-Object Drawing.Point(302, 14)
    $cancel = New-BrandButton 'Cancel' -Width 96; $cancel.Location = New-Object Drawing.Point(422, 14)
    $hint = New-BrandLabel '' 24 24 -Width 170 -Size 9 -Muted
    $footer.Controls.AddRange(@($hint, $back, $next, $cancel))
    $body = New-Object Windows.Forms.Panel
    $body.Dock = 'Fill'; $body.BackColor = [Drawing.Color]::White
    $form.Controls.Add($body); $form.Controls.Add($footer); $form.Controls.Add($rail)
    $body.BringToFront()

    $newPage = { $p = New-Object Windows.Forms.Panel; $p.Dock = 'Fill'; $p.BackColor = [Drawing.Color]::White; $p.Visible = $false; $body.Controls.Add($p); $p }
    $addText = {
        param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 0, [float]$Size = 10, [bool]$Bold = $false, [bool]$Muted = $false)
        $label = New-BrandLabel $Text $X $Y -Width $Width -Size $Size -Bold:$Bold -Muted:$Muted; $Parent.Controls.Add($label); $label
    }
    $addRow = {
        param($Parent, [int]$Y, [string]$Icon, [string]$Title, [string]$Detail, [string]$Status, [string]$Kind)
        $Parent.Controls.Add((New-BrandIconBox $Icon 20 30 ($Y + 6)))
        $null = & $addText $Parent $Title 62 $Y 0 10 $true
        $null = & $addText $Parent $Detail 62 ($Y + 20) 330 9 $false $true
        $badge = New-BrandBadge $Status $Kind
        $badge.Location = New-Object Drawing.Point((520 - [int]($badge.Width / (Get-BrandScale))), ($Y + 6)); $Parent.Controls.Add($badge)
    }

    # --- 0 Welcome
    $welcome = & $newPage
    $null = & $addText $welcome 'Welcome to Smart Connector' 28 24 0 16 $true
    $null = & $addText $welcome 'Connect Claude and Codex to Revit and AutoCAD on this computer, and keep your team''s workflow skills up to date.' 29 62 490 10 $false $true
    $features = @(
        @('revit', 'Revit and AutoCAD', 'Claude and Codex work with your open model or drawing.'),
        @('assistant', 'Claude and Codex', 'Connected for you. No settings files to edit.'),
        @('skills', 'Team workflow skills', 'Approved skills installed and kept in sync.'),
        @('updates', 'Automatic updates', 'New versions install when Revit and AutoCAD are closed.')
    )
    for ($i = 0; $i -lt 4; $i++) {
        $card = New-BrandCard (28 + ($i % 2) * 254) (112 + [Math]::Floor($i / 2) * 80) 242 70; $welcome.Controls.Add($card)
        $card.Controls.Add((New-BrandIconBox $features[$i][0] 20 12 12 -Color $C.Link))
        $null = & $addText $card $features[$i][1] 42 10 0 9.5 $true
        $null = & $addText $card $features[$i][2] 42 30 190 8.5 $false $true
    }
    $revitNote = & $addText $welcome 'Revit is open. Save your work and close it before installing, so the Revit add-in can be updated. AutoCAD can stay open.' 29 280 490 9
    $revitNote.ForeColor = $C.Warn
    $accept = New-Object Windows.Forms.CheckBox
    $accept.Text = 'I have read and accept the terms of use'; $accept.AutoSize = $true; $accept.Location = New-Object Drawing.Point(28, 330)
    $welcome.Controls.Add($accept)
    $readTerms = New-Object Windows.Forms.LinkLabel
    $readTerms.Text = 'Read the terms of use'; $readTerms.AutoSize = $true; $readTerms.Location = New-Object Drawing.Point(46, 356); $readTerms.LinkColor = $C.Link
    $welcome.Controls.Add($readTerms)

    # --- 1 System check
    $system = & $newPage
    $null = & $addText $system 'System check' 28 22 0 15 $true
    $null = & $addText $system 'Setup looked at this computer. Programs that are not installed are simply skipped.' 29 56 490 9.5 $false $true
    $rows = @(
        @('monitor', 'Windows', $(if ($check.Windows64 -and $check.NetOk) { '64-bit with .NET Framework 4.8' } elseif ($check.Windows64) { '64-bit; .NET Framework 4.8 not found' } else { 'Smart Connector needs 64-bit Windows' }), $(if ($check.Windows64 -and $check.NetOk) { 'Ready' } else { 'Check' }), $(if ($check.Windows64 -and $check.NetOk) { 'Good' } else { 'Warn' })),
        @('revit', 'Revit 2024', $(if ($check.Revit2024) { 'The Smart Connector tab will be added' } else { 'Not installed' }), $(if ($check.Revit2024) { 'Found' } else { 'Not found' }), $(if ($check.Revit2024) { 'Good' } else { 'Off' })),
        @('autocad', 'AutoCAD', $(if ($check.AutoCad.Count) { 'AutoCAD ' + ($check.AutoCad -join ', ') + ': buttons on the Add-ins tab' } else { 'Not installed' }), $(if ($check.AutoCad.Count) { 'Found' } else { 'Not found' }), $(if ($check.AutoCad.Count) { 'Good' } else { 'Off' })),
        @('claude', 'Claude Desktop', $(if ($check.ClaudeDesktop) { 'Installed for this Windows user' } else { 'Not installed; setup can install it' }), $(if ($check.ClaudeDesktop) { 'Found' } else { 'Not found' }), $(if ($check.ClaudeDesktop) { 'Good' } else { 'Off' })),
        @('claude', 'Claude Code', $(if ($check.ClaudeCode) { 'Command-line tool found' } else { 'Not installed' }), $(if ($check.ClaudeCode) { 'Found' } else { 'Not found' }), $(if ($check.ClaudeCode) { 'Good' } else { 'Off' })),
        @('codex', 'Codex', $(if ($check.Codex) { 'Command-line tool found' } else { 'Not installed; connect it later with Repair' }), $(if ($check.Codex) { 'Found' } else { 'Not found' }), $(if ($check.Codex) { 'Good' } else { 'Off' }))
    )
    for ($i = 0; $i -lt $rows.Count; $i++) { & $addRow $system (92 + $i * 44) $rows[$i][0] $rows[$i][1] $rows[$i][2] $rows[$i][3] $rows[$i][4] }
    if ($check.RevitOther.Count) {
        $other = & $addText $system ('Revit ' + ($check.RevitOther -join ', ') + ' found: not supported yet, so it is skipped.') 29 362 490 9
        $other.ForeColor = $C.Warn
    }

    # --- 2 Choose apps
    $choose = & $newPage
    $null = & $addText $choose 'Choose what to connect' 28 18 0 15 $true
    $makeGroup = {
        param([string]$Title, [int]$X, $Items)
        $box = New-BrandCard $X 54 248 150; $choose.Controls.Add($box)
        $all = New-Object Windows.Forms.CheckBox; $all.Text = $Title; $all.Font = New-BrandFont 9.5 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'
        $all.AutoSize = $true; $all.Location = New-Object Drawing.Point(12, 10); $box.Controls.Add($all)
        $boxes = @()
        $y = 40
        foreach ($item in $Items) {
            $cb = New-Object Windows.Forms.CheckBox; $cb.Text = $item.Name; $cb.AutoSize = $true; $cb.Location = New-Object Drawing.Point(12, $y)
            $cb.Enabled = $item.Enabled; $cb.Checked = $item.Checked -and $item.Enabled; $cb.Tag = $item.Key; $box.Controls.Add($cb)
            $note = New-BrandLabel $item.Note 30 ($y + 20) -Width 210 -Size 8 -Muted; $box.Controls.Add($note)
            $boxes += $cb; $y += 36
        }
        [pscustomobject]@{ All = $all; Boxes = $boxes }
    }
    $aiGroup = & $makeGroup 'AI apps' 28 @(
        [pscustomobject]@{ Key = 'ClaudeDesktop'; Name = 'Claude Desktop'; Enabled = $true; Checked = $true; Note = $(if ($check.ClaudeDesktop) { 'Installed' } else { 'Installed for you during setup' }) },
        [pscustomobject]@{ Key = 'ClaudeCode'; Name = 'Claude Code'; Enabled = $check.ClaudeCode; Checked = $true; Note = $(if ($check.ClaudeCode) { 'Installed' } else { 'Not installed' }) },
        [pscustomobject]@{ Key = 'Codex'; Name = 'Codex'; Enabled = $check.Codex; Checked = $true; Note = $(if ($check.Codex) { 'Installed' } else { 'Not installed' }) })
    $cadGroup = & $makeGroup 'Autodesk software' 284 @(
        [pscustomobject]@{ Key = 'Revit'; Name = 'Revit 2024'; Enabled = $check.Revit2024; Checked = $true; Note = $(if ($check.Revit2024) { 'Smart Connector tab' } else { 'Not installed' }) },
        [pscustomobject]@{ Key = 'AutoCAD'; Name = $(if ($check.AutoCad.Count) { 'AutoCAD ' + ($check.AutoCad[-1]) } else { 'AutoCAD' }); Enabled = [bool]$check.AutoCad.Count; Checked = $true; Note = $(if ($check.AutoCad.Count) { 'Add-ins panel and AI Markup' } else { 'Not installed' }) })
    $null = & $addText $choose 'Also install' 28 218 0 9.5 $true
    $skillsBox = New-Object Windows.Forms.CheckBox; $skillsBox.Text = 'Team workflow skills'; $skillsBox.Checked = $true; $skillsBox.AutoSize = $true; $skillsBox.Location = New-Object Drawing.Point(28, 242)
    $updatesBox = New-Object Windows.Forms.CheckBox; $updatesBox.Text = 'Automatic updates (recommended)'; $updatesBox.Checked = $true; $updatesBox.AutoSize = $true; $updatesBox.Location = New-Object Drawing.Point(200, 242)
    $choose.Controls.AddRange(@($skillsBox, $updatesBox))
    $joinBox = New-Object Windows.Forms.CheckBox; $joinBox.Text = 'Join the team skill service'; $joinBox.Checked = $true; $joinBox.AutoSize = $true; $joinBox.Location = New-Object Drawing.Point(28, 268)
    $joinBox.Visible = $AskDetails; $choose.Controls.Add($joinBox)
    $nameLabel = & $addText $choose 'Your name' 28 296 0 9 $true
    $nameBox = New-Object Windows.Forms.TextBox; $nameBox.Location = New-Object Drawing.Point(28, 316); $nameBox.Size = New-Object Drawing.Size(240, 26); $nameBox.MaxLength = 80
    $emailLabel = & $addText $choose 'Work email' 284 296 0 9 $true
    $emailBox = New-Object Windows.Forms.TextBox; $emailBox.Location = New-Object Drawing.Point(284, 316); $emailBox.Size = New-Object Drawing.Size(248, 26); $emailBox.MaxLength = 254
    $choose.Controls.AddRange(@($nameBox, $emailBox))
    $joinNote = & $addText $choose $script:TeamJoinNotice 28 346 500 8 $false $true
    $problem = & $addText $choose '' 28 374 500 9; $problem.ForeColor = $C.Bad

    $selectedAi = { @($aiGroup.Boxes | Where-Object Checked | ForEach-Object Tag) }
    $selectedCad = { @($cadGroup.Boxes | Where-Object Checked | ForEach-Object Tag) }
    $validateChoices = {
        foreach ($group in $aiGroup, $cadGroup) {
            $live = @($group.Boxes | Where-Object Enabled)
            $group.All.Enabled = $live.Count -gt 0
            $group.All.Checked = $live.Count -gt 0 -and @($live | Where-Object { -not $_.Checked }).Count -eq 0
        }
        $joining = $AskDetails -and $joinBox.Checked
        foreach ($c in $nameLabel, $nameBox, $emailLabel, $emailBox, $joinNote) { $c.Visible = $joining }
        $message = ''
        if (-not (& $selectedAi).Count) { $message = 'Choose at least one AI app.' }
        elseif (@($cadGroup.Boxes | Where-Object Enabled).Count -and -not (& $selectedCad).Count) { $message = 'Choose at least one Autodesk program.' }
        elseif ($joining -and -not ((Test-TeamJoinName $nameBox.Text) -and (Test-TeamJoinEmail $emailBox.Text))) { $message = 'Enter your name and work email to join the team, or untick Join the team skill service.' }
        $problem.Text = $message
        if ($script:wizard.Page -eq 2) { $next.Enabled = -not $message }
        $hint.Text = '{0} AI app{1} - {2} Autodesk program{3}' -f (& $selectedAi).Count, $(if ((& $selectedAi).Count -eq 1) { '' } else { 's' }), (& $selectedCad).Count, $(if ((& $selectedCad).Count -eq 1) { '' } else { 's' })
    }
    foreach ($group in $aiGroup, $cadGroup) {
        $group.All.Tag = $group
        $group.All.Add_Click({ $g = $this.Tag; foreach ($b in $g.Boxes) { if ($b.Enabled) { $b.Checked = $this.Checked } }; & $validateChoices })
        foreach ($b in $group.Boxes) { $b.Add_CheckedChanged({ & $validateChoices }) }
    }
    $joinBox.Add_CheckedChanged({ & $validateChoices }); $nameBox.Add_TextChanged({ & $validateChoices }); $emailBox.Add_TextChanged({ & $validateChoices })

    # --- 3 AI connections (review before installing)
    $review = & $newPage
    $null = & $addText $review 'Connect your AI apps' 28 22 0 15 $true
    $null = & $addText $review 'Setup adds Smart Connector to each app''s own settings for this Windows user. Your other connectors and settings are kept, and a backup is made first.' 29 56 490 9.5 $false $true
    $reviewRows = New-Object Windows.Forms.Panel; $reviewRows.Location = New-Object Drawing.Point(0, 100); $reviewRows.Size = New-Object Drawing.Size(552, 170); $review.Controls.Add($reviewRows)
    $restartNote = & $addText $review 'Restart Claude and Codex after setup so they load the connector. Claude may ask you once to allow its tools.' 29 290 490 9
    $restartNote.ForeColor = $C.Link
    $fillReview = {
        $reviewRows.Controls.Clear()
        $chosen = & $selectedAi
        $specs = @(
            @('ClaudeDesktop', 'claude', 'Claude Desktop', $(if ($check.ClaudeDesktop) { 'Adds "Smart Connector" to its connectors; Claude restarts' } else { 'Installs Claude Desktop, then adds Smart Connector' })),
            @('ClaudeCode', 'claude', 'Claude Code', 'Adds a user-level MCP server named autodesk'),
            @('Codex', 'codex', 'Codex', 'Adds an MCP server named autodesk to config.toml'))
        for ($i = 0; $i -lt 3; $i++) {
            $on = $chosen -contains $specs[$i][0]
            & $addRow $reviewRows ($i * 52) $specs[$i][1] $specs[$i][2] $(if ($on) { $specs[$i][3] } else { 'Not selected; left unchanged' }) $(if ($on) { 'Will connect' } else { 'Skipped' }) $(if ($on) { 'Info' } else { 'Off' })
        }
    }

    # --- 4 Installing
    $installing = & $newPage
    $installTitle = & $addText $installing 'Installing' 28 22 0 15 $true
    $currentTask = & $addText $installing 'Starting...' 29 56 400 9 $false $true
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Location = New-Object Drawing.Point(28, 80); $progress.Size = New-Object Drawing.Size(500, 8); $progress.Style = 'Continuous'
    $installing.Controls.Add($progress)
    $stepLabels = @{}
    $detailsLink = New-Object Windows.Forms.LinkLabel
    $detailsLink.Text = 'Show details'; $detailsLink.AutoSize = $true; $detailsLink.LinkColor = $C.Link
    $installing.Controls.Add($detailsLink)
    $logBox = New-Object Windows.Forms.TextBox
    $logBox.Multiline = $true; $logBox.ScrollBars = 'Vertical'; $logBox.ReadOnly = $true; $logBox.Visible = $false
    $logBox.Font = New-BrandFont 8.5 -Family 'Consolas'
    $logBox.Location = New-Object Drawing.Point(28, 100); $logBox.Size = New-Object Drawing.Size(500, 250)
    $installing.Controls.Add($logBox); $logBox.BringToFront()
    $buildSteps = {
        param([string[]]$Hidden)
        foreach ($label in @($stepLabels.Values)) { $installing.Controls.Remove($label); $label.Dispose() }
        $stepLabels.Clear(); $script:wizard.Status = @{}
        $y = 100
        foreach ($step in $script:WizardSteps) {
            if ($Hidden -contains $step.Id) { continue }
            $row = New-BrandLabel ([string][char]0x25CB + '   ' + $step.Label) 30 $y -Width 500
            $row.ForeColor = $C.Muted
            $installing.Controls.Add($row); $stepLabels[$step.Id] = $row; $script:wizard.Status[$step.Id] = 'pending'
            $y += 26
        }
        $detailsLink.Location = New-Object Drawing.Point(30, ($y + 6))
    }

    # --- 5 Finish
    $finished = & $newPage
    $doneTitle = & $addText $finished '' 28 22 0 15 $true
    $doneSummary = & $addText $finished '' 29 58 500 9.5 $false $true
    $doneRows = New-Object Windows.Forms.Panel; $doneRows.Location = New-Object Drawing.Point(0, 92); $doneRows.Size = New-Object Drawing.Size(552, 230); $finished.Controls.Add($doneRows)
    $openApp = New-Object Windows.Forms.CheckBox
    $openApp.Text = 'Open Smart Connector when I click Finish'; $openApp.Checked = $true; $openApp.AutoSize = $true; $openApp.Location = New-Object Drawing.Point(28, 330)
    $finished.Controls.Add($openApp)
    $openLog = New-Object Windows.Forms.LinkLabel
    $openLog.Text = 'Open the setup log'; $openLog.AutoSize = $true; $openLog.LinkColor = $C.Link; $openLog.Location = New-Object Drawing.Point(28, 358)
    $finished.Controls.Add($openLog)

    $pages = @($welcome, $system, $choose, $review, $installing, $finished)

    $updateStep = {
        param([string]$Id, [string]$Status, [string]$Detail)
        if (-not $stepLabels.ContainsKey($Id)) { return }
        $script:wizard.Status[$Id] = $Status
        if ($Detail) { $script:wizard.Details[$Id] = $Detail }
        $label = $stepLabels[$Id]; $text = ($script:WizardSteps | Where-Object { $_.Id -eq $Id }).Label
        switch ($Status) {
            'running' { $label.Text = [string][char]0x25D0 + "   $text..."; $label.ForeColor = $C.Accent; $currentTask.Text = "$text..." }
            'ok'      { $label.Text = [string][char]0x2713 + "   $text"; $label.ForeColor = $C.Good }
            'skipped' { $label.Text = [string][char]0x2013 + "   $text" + $(if ($Detail) { "  ($Detail)" } else { '' }); $label.ForeColor = $C.Muted }
            'failed'  { $label.Text = [string][char]0x2717 + "   $text" + $(if ($Detail) { "  ($Detail)" } else { '' }); $label.ForeColor = $C.Bad }
        }
        $done = @($script:wizard.Status.Values | Where-Object { $_ -in 'ok', 'skipped', 'failed' }).Count
        $progress.Value = [Math]::Min(100, [int](100 * $done / [Math]::Max(1, $stepLabels.Count)))
    }

    $showPage = {
        param([int]$Index)
        $script:wizard.Page = $Index
        for ($i = 0; $i -lt $pages.Count; $i++) { $pages[$i].Visible = ($i -eq $Index) }
        Set-BrandStepRail $rail $Index
        $revitNote.Visible = [bool](Get-Process -Name Revit -ErrorAction SilentlyContinue)
        $back.Visible = $Index -in 1, 2, 3
        $cancel.Visible = $Index -lt 4
        $next.Visible = $Index -ne 4
        $hint.Text = ''
        switch ($Index) {
            0 { $next.Text = 'Next'; $next.Enabled = $accept.Checked }
            1 { $next.Text = 'Next'; $next.Enabled = $check.Windows64 }
            2 { $next.Text = 'Next'; & $validateChoices }
            3 { $next.Text = 'Install'; $next.Enabled = $true; & $fillReview }
            5 { $next.Text = 'Finish'; $next.Enabled = $true }
        }
    }

    $startInstall = {
        Save-TermsAcceptance $termsVersion
        $ai = & $selectedAi; $cad = & $selectedCad
        $product = if ($cad.Count -eq 1) { $cad[0] } else { 'All' }
        $arguments = @($CoreArguments) + @('-TermsVersion', $termsVersion, '-AiClients', ($ai -join ','), '-Product', $product,
            '-Skills', $(if ($skillsBox.Checked) { 'On' } else { 'Off' }), '-AutoUpdates', $(if ($updatesBox.Checked) { 'On' } else { 'Off' }))
        $script:wizard.Join = if ($AskDetails -and $joinBox.Checked) { [pscustomobject]@{ Name = $nameBox.Text.Trim(); Email = $emailBox.Text.Trim() } } else { $null }
        if ($script:wizard.Join) { $arguments += @('-JoinName', $script:wizard.Join.Name, '-JoinEmail', $script:wizard.Join.Email) }
        $hidden = @()
        if (-not ($HasEnrollmentFile -or $script:wizard.Join)) { $hidden += 'team' }
        if ($product -eq 'Revit') { $hidden += 'autocad' }
        if ($product -eq 'AutoCAD') { $hidden += 'revit' }
        & $buildSteps $hidden
        & $showPage 4
        & $updateStep 'files' 'running' ''
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = ConvertTo-CommandLine (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $CoreSetup) + $arguments)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $script:wizard.Process = [Diagnostics.Process]::Start($psi)
        # Async line reads polled from the UI timer: no PowerShell code ever runs on another thread.
        $script:wizard.Reads.Out = $script:wizard.Process.StandardOutput.ReadLineAsync()
        $script:wizard.Reads.Err = $script:wizard.Process.StandardError.ReadLineAsync()
        $timer.Start()
    }

    $handleLine = {
        param([string]$Line)
        if ($null -eq $Line) { return }
        Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
        $logBox.AppendText($Line + "`r`n")
        $parsed = ConvertFrom-SetupOutputLine $Line
        if ($parsed) {
            if ($parsed.Status -eq 'running') {
                # Starting a phase means the previous running steps finished without a failure.
                foreach ($id in @($script:wizard.Status.Keys)) { if ($script:wizard.Status[$id] -eq 'running' -and $id -ne $parsed.Step) { & $updateStep $id 'ok' '' } }
            }
            & $updateStep $parsed.Step $parsed.Status $parsed.Detail
        }
    }

    $finish = {
        $code = $script:wizard.Process.ExitCode
        foreach ($id in @($script:wizard.Status.Keys)) {
            $s = $script:wizard.Status[$id]
            if ($s -eq 'running') { & $updateStep $id $(if ($code -eq 0) { 'ok' } else { 'failed' }) '' }
            elseif ($s -eq 'pending') { & $updateStep $id 'skipped' '' }
        }
        $failed = @($script:wizard.Status.GetEnumerator() | Where-Object { $_.Value -eq 'failed' })
        $script:wizard.ExitCode = $code
        $script:wizard.Result = if ($code -eq 0 -and -not $failed) { 'ok' } else { 'problems' }
        $doneRows.Controls.Clear()
        $icons = @{ files = 'connector'; skills = 'skills'; revit = 'revit'; autocad = 'autocad'; codex = 'codex'; claude_desktop = 'claude'; claude_code = 'claude'; team = 'team'; updates = 'updates' }
        $i = 0
        foreach ($step in $script:WizardSteps) {
            if (-not $stepLabels.ContainsKey($step.Id)) { continue }
            $s = $script:wizard.Status[$step.Id]
            $row = New-BrandCard (28 + ($i % 2) * 254) ([Math]::Floor($i / 2) * 44) 242 38; $doneRows.Controls.Add($row)
            $row.Controls.Add((New-BrandIconBox $icons[$step.Id] 16 10 11))
            $title = $step.Label -replace '^(Install|Connect) ', '' -replace 'workflow skills for Codex and Claude', 'Workflow skills'
            $row.Controls.Add((New-BrandLabel ($title.Substring(0, 1).ToUpper() + $title.Substring(1)) 32 10 -Size 9))
            $word = switch ($s) { 'ok' { 'Done' } 'failed' { 'Failed' } default { 'Skipped' } }
            $color = switch ($s) { 'ok' { $C.Good } 'failed' { $C.Bad } default { $C.Muted } }
            $status = New-BrandLabel $word 180 10 -Size 9 -Bold; $status.ForeColor = $color; $row.Controls.Add($status)
            $i++
        }
        if ($script:wizard.Result -eq 'ok') {
            $doneTitle.Text = 'Smart Connector is ready'; $doneTitle.ForeColor = $C.Good
            $doneSummary.Text = 'Restart Revit, AutoCAD, Claude and Codex so they load the connector.'
        }
        else {
            $doneTitle.Text = 'Setup finished with problems'; $doneTitle.ForeColor = $C.Bad
            $doneSummary.Text = 'Everything that could be installed was installed. Open the setup log, fix the failed item and run setup again, or contact your administrator.'
        }
        & $showPage 5
    }

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({
        foreach ($key in @('Out', 'Err')) {
            $task = $script:wizard.Reads[$key]
            while ($task -and $task.IsCompleted) {
                $line = $task.Result
                if ($null -eq $line) { $script:wizard.Reads[$key] = $null; break }
                & $handleLine $line
                $reader = if ($key -eq 'Out') { $script:wizard.Process.StandardOutput } else { $script:wizard.Process.StandardError }
                $task = $reader.ReadLineAsync(); $script:wizard.Reads[$key] = $task
            }
        }
        if ($script:wizard.Process.HasExited -and -not $script:wizard.Reads.Out -and -not $script:wizard.Reads.Err) {
            $timer.Stop(); & $finish
        }
    })

    $accept.Add_CheckedChanged({ if ($script:wizard.Page -eq 0) { $next.Enabled = $accept.Checked } })
    $readTerms.Add_LinkClicked({
        $dialog = New-BrandForm -Width 620 -Height 460; $dialog.Text = 'Smart Connector terms of use'
        $box = New-Object Windows.Forms.TextBox; $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.Dock = 'Fill'
        $box.Font = New-BrandFont 9.5; $box.BackColor = [Drawing.Color]::White
        $box.Text = if (Test-Path -LiteralPath $termsPath) { (Get-Content -LiteralPath $termsPath -Raw) -replace "(?<!`r)`n", "`r`n" } else { 'The terms of use file is missing from this installer.' }
        $dialog.Controls.Add($box); $box.SelectionStart = 0
        [void]$dialog.ShowDialog($form); $dialog.Dispose()
    })
    $detailsLink.Add_LinkClicked({ $logBox.Visible = -not $logBox.Visible; $detailsLink.Text = if ($logBox.Visible) { 'Hide details' } else { 'Show details' }; $logBox.BringToFront(); $detailsLink.BringToFront() })
    $openLog.Add_LinkClicked({ Start-Process notepad.exe -ArgumentList ('"{0}"' -f $LogPath) })
    $back.Add_Click({ & $showPage ([Math]::Max(0, $script:wizard.Page - 1)) })
    $cancel.Add_Click({ $form.Close() })
    $next.Add_Click({
        switch ($script:wizard.Page) {
            0 { & $showPage 1 }
            1 { & $showPage 2 }
            2 { & $showPage 3 }
            3 { & $startInstall }
            5 { $script:wizard.OpenApp = $openApp.Checked -and $script:wizard.Result -eq 'ok'; $form.Close() }
        }
    })
    $form.Add_FormClosing({
        param($sender, $e)
        if ($script:wizard.Page -eq 4) { $e.Cancel = $true; return }   # never stop half way through an install
        if ($script:wizard.Page -lt 4 -and -not $script:wizard.Smoke) {
            $answer = [Windows.Forms.MessageBox]::Show($form, 'Cancel setup? Nothing has been installed yet.', 'Smart Connector Setup', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { $e.Cancel = $true }
        }
    })

    if ($SmokeTest) {
        # Build and step through every page without installing anything.
        $script:wizard.Smoke = $true
        $accept.Checked = $true
        foreach ($index in 0, 1, 2, 3) { & $showPage $index }
        & $buildSteps @('team'); & $showPage 4
        foreach ($id in @($stepLabels.Keys)) { & $updateStep $id 'ok' '' }
        $script:wizard.Process = [pscustomobject]@{ ExitCode = 0 }
        & $finish
        $form.Dispose()
        return [pscustomobject]@{ Result = $script:wizard.Result; Pages = $pages.Count; Steps = $stepLabels.Count }
    }

    # Windows may refuse focus to a window started from Explorer, leaving setup hidden behind it.
    # Stay on top until the person first switches to the window, then behave normally.
    $form.TopMost = $true
    $form.Add_Shown({ $form.Activate() })
    $form.Add_Activated({ if (-not $script:wizard.Activated) { $script:wizard.Activated = $true; $form.TopMost = $false } })

    & $showPage 0
    [void]$form.ShowDialog()
    $form.Dispose()
    if ($script:wizard.OpenApp) {
        $app = Join-Path $installRoot 'installer\SmartConnectorApp.ps1'
        if (Test-Path -LiteralPath $app) {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -RepositoryPath "{1}"' -f $app, $installRoot)
        }
    }
    [pscustomobject]@{ Result = $script:wizard.Result; ExitCode = $script:wizard.ExitCode; Joined = [bool]$script:wizard.Join; Status = $script:wizard.Status }
}
