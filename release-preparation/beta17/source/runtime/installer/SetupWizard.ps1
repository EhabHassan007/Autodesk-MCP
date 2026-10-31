# Smart Autodesk Connector setup wizard: Welcome, Terms, Your details (team installer only),
# Installing (live steps) and Finished. Dot-source after WinForms is loaded, then call
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

function Show-SetupWizard {
    param(
        [Parameter(Mandatory = $true)][string]$CoreSetup,
        [Parameter(Mandatory = $true)][string[]]$CoreArguments,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string]$Version = '',
        [bool]$AskDetails = $false,
        [bool]$HasEnrollmentFile = $false
    )
    $termsPath = Join-Path $PSScriptRoot 'TERMS.txt'
    $termsVersion = Get-TermsVersion $termsPath
    $C = $script:BrandColors
    $script:wizard = @{ Page = 0; Result = 'cancelled'; Process = $null; Reads = @{}; Status = @{}; Details = @{}; Join = $null; ExitCode = $null }
    $showTeam = $AskDetails -or $HasEnrollmentFile

    $form = New-BrandForm -Width 680 -Height 540
    $form.Text = "$script:BrandName Setup"
    $null = Add-BrandHeader $form -Subtitle $(if ($Version) { "Version $Version" } else { 'Setup' })

    $footer = New-Object Windows.Forms.Panel
    $footer.Dock = 'Bottom'; $footer.Height = 64; $footer.BackColor = [Drawing.Color]::FromArgb(248, 250, 252)
    $form.Controls.Add($footer)
    $back = New-BrandButton 'Back' -Width 100; $back.Location = New-Object Drawing.Point(318, 14)
    $next = New-BrandButton 'Next' -Primary -Width 120; $next.Location = New-Object Drawing.Point(426, 14)
    $cancel = New-BrandButton 'Cancel' -Width 100; $cancel.Location = New-Object Drawing.Point(556, 14)
    $footer.Controls.AddRange(@($back, $next, $cancel))

    $body = New-Object Windows.Forms.Panel
    $body.Dock = 'Fill'; $body.Padding = New-Object Windows.Forms.Padding(32, 20, 32, 10)
    $form.Controls.Add($body); $body.BringToFront()

    # --- Page 1: Welcome
    $welcome = New-Object Windows.Forms.Panel; $welcome.Dock = 'Fill'
    $welcome.Controls.Add((New-BrandLabel 'Welcome' 32 22 -Size 16 -Bold))
    $intro = "Smart Autodesk Connector lets Codex and Claude work with Revit and AutoCAD on this computer, and keeps your team's shared workflow skills up to date.`r`n`r`nSetup will:`r`n   •  install the connector and the Revit 2024 add-in`r`n   •  connect Codex, Claude Desktop and Claude Code`r`n   •  install the shared workflow skills`r`n   •  switch on automatic updates"
    if ($showTeam) { $intro += "`r`n   •  join this computer to your team skill service" }
    $welcome.Controls.Add((New-BrandLabel $intro 34 66 -Width 600))
    $revitNote = New-BrandLabel 'Revit is open. Save your work and close Revit before you continue, so its add-in can be updated. AutoCAD can stay open.' 34 300 -Width 600
    $revitNote.ForeColor = $C.Bad
    $welcome.Controls.Add($revitNote)

    # --- Page 2: Terms
    $terms = New-Object Windows.Forms.Panel; $terms.Dock = 'Fill'
    $terms.Controls.Add((New-BrandLabel 'Terms of use' 32 18 -Size 14 -Bold))
    $termsBox = New-Object Windows.Forms.TextBox
    $termsBox.Multiline = $true; $termsBox.ScrollBars = 'Vertical'; $termsBox.WordWrap = $true
    $termsBox.ReadOnly = $true; $termsBox.BackColor = [Drawing.Color]::FromArgb(248, 250, 252); $termsBox.BorderStyle = 'FixedSingle'
    $termsBox.Location = New-Object Drawing.Point(34, 56); $termsBox.Size = New-Object Drawing.Size(612, 236)
    $termsBox.Font = New-BrandFont 9.5
    $termsBox.Text = if (Test-Path -LiteralPath $termsPath) { (Get-Content -LiteralPath $termsPath -Raw) -replace "(?<!`r)`n", "`r`n" } else { 'The terms of use file is missing from this installer.' }
    $termsBox.SelectionStart = 0
    $terms.Controls.Add($termsBox)
    $accept = New-Object Windows.Forms.CheckBox
    $accept.Text = 'I have read and accept the terms of use'
    $accept.AutoSize = $true; $accept.Location = New-Object Drawing.Point(34, 304)
    $terms.Controls.Add($accept)

    # --- Page 3: Your details
    $details = New-Object Windows.Forms.Panel; $details.Dock = 'Fill'
    $details.Controls.Add((New-BrandLabel 'Your details' 32 18 -Size 14 -Bold))
    $details.Controls.Add((New-BrandLabel 'Your administrator sees these on the team dashboard, so they know whose computer this is.' 34 54 -Width 600 -Muted))
    $details.Controls.Add((New-BrandLabel 'Full name' 34 96))
    $nameBox = New-Object Windows.Forms.TextBox; $nameBox.Location = New-Object Drawing.Point(34, 120); $nameBox.Size = New-Object Drawing.Size(420, 28); $nameBox.MaxLength = 80
    $details.Controls.Add($nameBox)
    $details.Controls.Add((New-BrandLabel 'Email' 34 162))
    $emailBox = New-Object Windows.Forms.TextBox; $emailBox.Location = New-Object Drawing.Point(34, 186); $emailBox.Size = New-Object Drawing.Size(420, 28); $emailBox.MaxLength = 254
    $details.Controls.Add($emailBox)
    $details.Controls.Add((New-BrandLabel $script:TeamJoinNotice 34 232 -Width 600 -Muted -Size 9))
    $skipJoin = New-Object Windows.Forms.LinkLabel
    $skipJoin.Text = 'Install without joining the team (skill sharing stays off)'; $skipJoin.AutoSize = $true
    $skipJoin.Location = New-Object Drawing.Point(34, 300); $skipJoin.LinkColor = $C.Accent
    $details.Controls.Add($skipJoin)

    # --- Page 4: Installing
    $installing = New-Object Windows.Forms.Panel; $installing.Dock = 'Fill'
    $installTitle = New-BrandLabel 'Installing…' 32 18 -Size 14 -Bold
    $installing.Controls.Add($installTitle)
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Location = New-Object Drawing.Point(34, 58); $progress.Size = New-Object Drawing.Size(612, 10); $progress.Style = 'Continuous'
    $installing.Controls.Add($progress)
    $stepLabels = @{}
    $y = 84
    foreach ($step in $script:WizardSteps) {
        if ($step.Id -eq 'team' -and -not $showTeam) { continue }
        $row = New-BrandLabel ("○   " + $step.Label) 34 $y -Width 600
        $row.ForeColor = $C.Muted
        $installing.Controls.Add($row)
        $stepLabels[$step.Id] = $row
        $script:wizard.Status[$step.Id] = 'pending'
        $y += 28
    }
    $detailsLink = New-Object Windows.Forms.LinkLabel
    $detailsLink.Text = 'Show details'; $detailsLink.AutoSize = $true; $detailsLink.LinkColor = $C.Accent
    $detailsLink.Location = New-Object Drawing.Point(34, ($y + 6))
    $installing.Controls.Add($detailsLink)
    $logBox = New-Object Windows.Forms.TextBox
    $logBox.Multiline = $true; $logBox.ScrollBars = 'Vertical'; $logBox.ReadOnly = $true; $logBox.Visible = $false
    $logBox.Font = New-BrandFont 8.5 -Family 'Consolas'
    $logBox.Location = New-Object Drawing.Point(34, 84); $logBox.Size = New-Object Drawing.Size(612, 250)
    $installing.Controls.Add($logBox); $logBox.BringToFront()

    # --- Page 5: Finished
    $finished = New-Object Windows.Forms.Panel; $finished.Dock = 'Fill'
    $doneTitle = New-BrandLabel '' 32 18 -Size 15 -Bold; $finished.Controls.Add($doneTitle)
    $doneSummary = New-BrandLabel '' 34 62 -Width 600; $finished.Controls.Add($doneSummary)
    $openLog = New-Object Windows.Forms.LinkLabel
    $openLog.Text = 'Open the setup log'; $openLog.AutoSize = $true; $openLog.LinkColor = $C.Accent
    $openLog.Location = New-Object Drawing.Point(34, 330)
    $finished.Controls.Add($openLog)

    $pages = @($welcome, $terms, $details, $installing, $finished)
    foreach ($p in $pages) { $p.Visible = $false; $body.Controls.Add($p) }

    $updateStep = {
        param([string]$Id, [string]$Status, [string]$Detail)
        if (-not $stepLabels.ContainsKey($Id)) { return }
        $script:wizard.Status[$Id] = $Status
        if ($Detail) { $script:wizard.Details[$Id] = $Detail }
        $label = $stepLabels[$Id]; $text = ($script:WizardSteps | Where-Object { $_.Id -eq $Id }).Label
        switch ($Status) {
            'running' { $label.Text = "◐   $text…"; $label.ForeColor = $C.Accent }
            'ok'      { $label.Text = "✓   $text"; $label.ForeColor = $C.Good }
            'skipped' { $label.Text = "–   $text" + $(if ($Detail) { "  ($Detail)" } else { '' }); $label.ForeColor = $C.Muted }
            'failed'  { $label.Text = "✗   $text" + $(if ($Detail) { "  ($Detail)" } else { '' }); $label.ForeColor = $C.Bad }
        }
        $done = @($script:wizard.Status.Values | Where-Object { $_ -in 'ok', 'skipped', 'failed' }).Count
        $progress.Value = [Math]::Min(100, [int](100 * $done / [Math]::Max(1, $stepLabels.Count)))
    }

    $showPage = {
        param([int]$Index)
        $script:wizard.Page = $Index
        for ($i = 0; $i -lt $pages.Count; $i++) { $pages[$i].Visible = ($i -eq $Index) }
        $revitNote.Visible = [bool](Get-Process -Name Revit -ErrorAction SilentlyContinue)
        $back.Visible = $Index -in 1, 2
        $cancel.Visible = $Index -lt 3
        $next.Visible = $Index -ne 3
        switch ($Index) {
            0 { $next.Text = 'Next'; $next.Enabled = $true }
            1 { $next.Text = 'Next'; $next.Enabled = $accept.Checked }
            2 { $next.Text = 'Install'; $next.Enabled = (Test-TeamJoinName $nameBox.Text) -and (Test-TeamJoinEmail $emailBox.Text) }
            3 { $next.Text = 'Install'; $next.Enabled = $false }
            4 { $next.Text = 'Finish'; $next.Enabled = $true }
        }
        if ($Index -eq 1 -and -not $AskDetails) { $next.Text = 'Install' }
    }

    $startInstall = {
        Save-TermsAcceptance $termsVersion
        $arguments = @($CoreArguments) + @('-TermsVersion', $termsVersion)
        if ($script:wizard.Join) { $arguments += @('-JoinName', $script:wizard.Join.Name, '-JoinEmail', $script:wizard.Join.Email) }
        & $showPage 3
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
        $lines = foreach ($step in $script:WizardSteps) {
            if (-not $stepLabels.ContainsKey($step.Id)) { continue }
            $s = $script:wizard.Status[$step.Id]
            $mark = switch ($s) { 'ok' { '✓' } 'failed' { '✗' } default { '–' } }
            $extra = if ($script:wizard.Details[$step.Id]) { "  ($($script:wizard.Details[$step.Id]))" } else { '' }
            "$mark   $($step.Label)$extra"
        }
        if ($script:wizard.Result -eq 'ok') {
            $doneTitle.Text = '✓  Smart Autodesk Connector is ready'; $doneTitle.ForeColor = $C.Good
            $nextSteps = "`r`n`r`nNext: open Revit and look for the Smart Autodesk Connector tab. In Codex or Claude, ask it to work with your open model or drawing."
        }
        else {
            $doneTitle.Text = 'Setup finished with problems'; $doneTitle.ForeColor = $C.Bad
            $nextSteps = "`r`n`r`nEverything that could be installed was installed. Open the setup log for details, fix the item marked ✗ and run setup again, or contact your administrator."
        }
        $doneSummary.Text = ($lines -join "`r`n") + $nextSteps
        $openLog.Visible = $true
        & $showPage 4
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

    $accept.Add_CheckedChanged({ if ($script:wizard.Page -eq 1) { $next.Enabled = $accept.Checked } })
    $validateDetails = { if ($script:wizard.Page -eq 2) { $next.Enabled = (Test-TeamJoinName $nameBox.Text) -and (Test-TeamJoinEmail $emailBox.Text) } }
    $nameBox.Add_TextChanged($validateDetails); $emailBox.Add_TextChanged($validateDetails)
    $detailsLink.Add_LinkClicked({ $logBox.Visible = -not $logBox.Visible; $detailsLink.Text = if ($logBox.Visible) { 'Hide details' } else { 'Show details' }; $logBox.BringToFront(); $detailsLink.BringToFront() })
    $openLog.Add_LinkClicked({ Start-Process notepad.exe -ArgumentList ('"{0}"' -f $LogPath) })
    $skipJoin.Add_LinkClicked({ $script:wizard.Join = $null; & $startInstall })
    $back.Add_Click({ & $showPage ([Math]::Max(0, $script:wizard.Page - 1)) })
    $cancel.Add_Click({ $form.Close() })
    $next.Add_Click({
        switch ($script:wizard.Page) {
            0 { & $showPage 1 }
            1 { if ($AskDetails) { & $showPage 2; $nameBox.Focus() } else { & $startInstall } }
            2 { $script:wizard.Join = [pscustomobject]@{ Name = $nameBox.Text.Trim(); Email = $emailBox.Text.Trim() }; & $startInstall }
            4 { $form.Close() }
        }
    })
    $form.Add_FormClosing({
        param($sender, $e)
        if ($script:wizard.Page -eq 3) { $e.Cancel = $true; return }   # never stop half way through an install
        if ($script:wizard.Page -lt 3) {
            $answer = [Windows.Forms.MessageBox]::Show($form, 'Cancel setup? Nothing has been installed yet.', "$script:BrandName Setup", 'YesNo', 'Question')
            if ($answer -ne 'Yes') { $e.Cancel = $true }
        }
    })
    # Windows may refuse focus to a window started from Explorer, leaving setup hidden behind it.
    # Stay on top until the person first switches to the window, then behave normally.
    $form.TopMost = $true
    $form.Add_Shown({ $form.Activate() })
    $form.Add_Activated({ if (-not $script:wizard.Activated) { $script:wizard.Activated = $true; $form.TopMost = $false } })

    & $showPage 0
    [void]$form.ShowDialog()
    $form.Dispose()
    [pscustomobject]@{ Result = $script:wizard.Result; ExitCode = $script:wizard.ExitCode; Joined = [bool]$script:wizard.Join; Status = $script:wizard.Status }
}
