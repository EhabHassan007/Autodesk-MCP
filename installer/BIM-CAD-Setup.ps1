param(
    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/Autodesk-MCP.git',
    [string]$ReleaseManifestUrl = 'https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json',
    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),
    [ValidateSet('Status', 'CheckUpdate')]
    [string]$InitialAction = 'Status',
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$coreScript = Join-Path $PSScriptRoot 'Setup-BimCad.ps1'

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Autodesk MCP Connector'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(680, 550)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Autodesk MCP Connector'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 20)
$form.Controls.Add($title)

$versionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'
$versionText = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    (Get-Content -LiteralPath $versionPath -Raw).Trim()
}
else {
    'development'
}
$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = "Version $versionText"
$versionLabel.AutoSize = $true
$versionLabel.ForeColor = [System.Drawing.Color]::DimGray
$versionLabel.Location = New-Object System.Drawing.Point(520, 34)
$form.Controls.Add($versionLabel)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Connect Codex and Claude to installed AutoCAD and supported Revit versions.'
$subtitle.AutoSize = $true
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(28, 62)
$form.Controls.Add($subtitle)

$productLabel = New-Object System.Windows.Forms.Label
$productLabel.Text = 'Applications'
$productLabel.AutoSize = $true
$productLabel.Location = New-Object System.Drawing.Point(28, 102)
$form.Controls.Add($productLabel)

$product = New-Object System.Windows.Forms.Label
$product.Text = 'AutoCAD and Revit - automatic detection'
$product.AutoSize = $true
$product.ForeColor = [System.Drawing.Color]::DimGray
$product.Location = New-Object System.Drawing.Point(28, 130)
$form.Controls.Add($product)

$toolTip = New-Object System.Windows.Forms.ToolTip

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Install / Repair'
$installButton.Location = New-Object System.Drawing.Point(370, 123)
$installButton.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($installButton)
$toolTip.SetToolTip($installButton, 'Install or repair the connector, shared skills, AI-client registrations, and detected Revit add-in.')

$updateButton = New-Object System.Windows.Forms.Button
$updateButton.Text = 'Update'
$updateButton.Location = New-Object System.Drawing.Point(510, 123)
$updateButton.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($updateButton)
$toolTip.SetToolTip($updateButton, 'Download and install the latest approved public release. Git and GitHub sign-in are not required.')

$testButton = New-Object System.Windows.Forms.Button
$testButton.Text = 'Test connection'
$testButton.Location = New-Object System.Drawing.Point(28, 174)
$testButton.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($testButton)
$toolTip.SetToolTip($testButton, 'Check Codex and Claude registrations and any currently running AutoCAD or Revit session.')

$folderButton = New-Object System.Windows.Forms.Button
$folderButton.Text = 'Install folder'
$folderButton.Location = New-Object System.Drawing.Point(518, 174)
$folderButton.Size = New-Object System.Drawing.Size(122, 34)
$form.Controls.Add($folderButton)
$toolTip.SetToolTip($folderButton, 'Open the local connector installation folder.')

$teamButton = New-Object System.Windows.Forms.Button
$teamButton.Text = 'Team knowledge setup (optional)'
$teamButton.Location = New-Object System.Drawing.Point(28, 220)
$teamButton.Size = New-Object System.Drawing.Size(250, 34)
$form.Controls.Add($teamButton)
$toolTip.SetToolTip($teamButton, 'Check private-repository access before enabling daily team knowledge collection in Codex.')

$alertsButton = New-Object System.Windows.Forms.Button
$alertsButton.Text = 'Enable auto-updates'
$alertsButton.Location = New-Object System.Drawing.Point(300, 220)
$alertsButton.Size = New-Object System.Drawing.Size(200, 34)
$form.Controls.Add($alertsButton)
$toolTip.SetToolTip($alertsButton, 'Check the public release channel at sign-in and daily at 9:00 AM. Git and GitHub sign-in are not required.')

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Status'
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(28, 272)
$form.Controls.Add($statusLabel)

$status = New-Object System.Windows.Forms.TextBox
$status.Multiline = $true
$status.ReadOnly = $true
$status.ScrollBars = 'Vertical'
$status.BackColor = [System.Drawing.Color]::White
$status.Location = New-Object System.Drawing.Point(28, 296)
$status.Size = New-Object System.Drawing.Size(612, 190)
$form.Controls.Add($status)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Location = New-Object System.Drawing.Point(510, 502)
$closeButton.Size = New-Object System.Drawing.Size(130, 32)
$form.Controls.Add($closeButton)

function Invoke-SetupAction {
    param([string]$Action)

    $installGit = $false
    if ($Action -eq 'TeamStatus') {
        $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $git) {
            $gitCandidates = @(
                (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
                (Join-Path $env:ProgramFiles 'Git\cmd\git.cmd'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.cmd')
            )
            if (${env:ProgramFiles(x86)}) {
                $gitCandidates += @(
                    (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
                    (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.cmd')
                )
            }
            $git = $gitCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        }
        if (-not $git) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Optional team knowledge submission requires Git for Windows.`r`n`r`nInstall Git now? Windows may ask for permission. GitHub will then open a secure one-time sign-in. The Autodesk MCP Connector does not store your password or token.",
                'Autodesk MCP Connector',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                $status.Text = 'Git installation was cancelled. Install Git for Windows, then retry.'
                return
            }
            $installGit = $true
        }
    }

    $status.Text = "Working...`r`n"
    $form.UseWaitCursor = $true
    foreach ($button in @($installButton, $updateButton, $testButton, $teamButton, $alertsButton)) { $button.Enabled = $false }
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $arguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $coreScript,
            '-Action', $Action, '-RepositoryUrl', $RepositoryUrl, '-ReleaseManifestUrl', $ReleaseManifestUrl, '-RepositoryPath', $RepositoryPath
        )
        if ($installGit) { $arguments += '-InstallGitIfMissing' }
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $status.Text = (($output | ForEach-Object { $_.ToString() }) -join "`r`n")
        if ($exitCode -eq 0) {
            $status.AppendText("`r`n`r`nFinished successfully.")
        }
        else {
            $status.AppendText("`r`n`r`nSetup stopped. Read the message above.")
        }
    }
    catch {
        $status.Text = $_.Exception.Message
    }
    finally {
        $form.UseWaitCursor = $false
        foreach ($button in @($installButton, $updateButton, $testButton, $teamButton, $alertsButton)) { $button.Enabled = $true }
    }
}

function Test-UpdateAlertsEnabled {
    $statePath = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\update-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $false }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        return [bool]$state.notifications_enabled
    }
    catch { return $false }
}

function Refresh-UpdateAlertsButton {
    if (Test-UpdateAlertsEnabled) {
        $alertsButton.Text = 'Disable auto-updates'
    }
    else {
        $alertsButton.Text = 'Enable auto-updates'
    }
}

$installButton.Add_Click({ Invoke-SetupAction 'Install' })
$updateButton.Add_Click({ Invoke-SetupAction 'Update' })
$testButton.Add_Click({ Invoke-SetupAction 'Test' })
$teamButton.Add_Click({ Invoke-SetupAction 'TeamStatus' })
$alertsButton.Add_Click({
    if (Test-UpdateAlertsEnabled) {
        Invoke-SetupAction 'DisableNotifications'
    }
    else {
        Invoke-SetupAction 'EnableNotifications'
    }
    Refresh-UpdateAlertsButton
})
$folderButton.Add_Click({
    if (Test-Path -LiteralPath $RepositoryPath) {
        Start-Process explorer.exe -ArgumentList $RepositoryPath
    }
    else {
        [System.Windows.Forms.MessageBox]::Show('Run Install / Repair first.', 'Autodesk MCP Connector') | Out-Null
    }
})
$closeButton.Add_Click({ $form.Close() })

$form.Add_Shown({
    if ($SmokeTest) {
        $form.Close()
    }
    else {
        Refresh-UpdateAlertsButton
        Invoke-SetupAction $InitialAction
    }
})
[void]$form.ShowDialog()
