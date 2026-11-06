param(
    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/Autodesk-MCP.git',
    [string]$ReleaseManifestUrl = 'https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json',
    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),
    [ValidateSet('Status', 'CheckUpdate')]
    [string]$InitialAction = 'Status',
    [switch]$SmokeTest
)
# Smart Connector maintenance window: repair, update, test, Skills Sync and Settings.
# First-time installation uses the setup wizard (SetupWizard.ps1) instead.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$coreScript = Join-Path $PSScriptRoot 'Setup-BimCad.ps1'
. (Join-Path $PSScriptRoot 'Brand.ps1')
. (Join-Path $PSScriptRoot 'TeamJoinDialog.ps1')
# Pass RepositoryPath through: dot-sourcing runs Settings.ps1's parameter block in this scope.
. (Join-Path $PSScriptRoot 'Settings.ps1') -RepositoryPath $RepositoryPath -LibraryOnly

$versionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'
$versionText = if (Test-Path -LiteralPath $versionPath -PathType Leaf) { (Get-Content -LiteralPath $versionPath -Raw).Trim() } else { 'development' }

$form = New-BrandForm -Width 680 -Height 540
$form.Text = $script:BrandName
$null = Add-BrandHeader $form -Subtitle "Version $versionText  -  Codex and Claude for Revit and AutoCAD"

$toolTip = New-Object System.Windows.Forms.ToolTip
$buttons = @()
$x = 28
foreach ($spec in @(
        @('Repair', 'Install', 'Reinstall the connector, skills, Revit add-in and Codex/Claude connections.'),
        @('Update now', 'Update', 'Install the latest approved version now. Close Revit and AutoCAD first.'),
        @('Test connection', 'Test', 'Check Codex and Claude connections and any open AutoCAD or Revit session.'),
        @('Skills Sync', 'Sync', 'Send your saved skills for review and download the latest approved team skills.'),
        @('Settings', 'Settings', 'Turn update checks on or off.'))) {
    $button = New-BrandButton $spec[0] -Primary:($spec[1] -eq 'Install') -Width 116
    $button.Location = New-Object System.Drawing.Point($x, 110)
    $button.Tag = $spec[1]
    $toolTip.SetToolTip($button, $spec[2])
    $form.Controls.Add($button)
    $buttons += $button
    $x += 124
}

$form.Controls.Add((New-BrandLabel 'Status' 28 164 -Bold))
$status = New-Object System.Windows.Forms.TextBox
$status.Multiline = $true
$status.ReadOnly = $true
$status.ScrollBars = 'Vertical'
$status.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$status.BorderStyle = 'FixedSingle'
$status.Font = New-BrandFont 9 -Family 'Consolas'
$status.Location = New-Object System.Drawing.Point(28, 190)
$status.Size = New-Object System.Drawing.Size(624, 280)
$form.Controls.Add($status)

$closeButton = New-BrandButton 'Close' -Width 116
$closeButton.Location = New-Object System.Drawing.Point(536, 484)
$form.Controls.Add($closeButton)

function Invoke-SetupAction {
    param([string]$Action)

    $join = $null
    if ($Action -eq 'Install' -and (Test-TeamJoinRequired -PayloadInstaller $PSScriptRoot)) {
        $join = Show-TeamJoinDialog -Owner $form
    }
    $status.Text = "Working...`r`n"
    $form.UseWaitCursor = $true
    foreach ($button in $buttons) { $button.Enabled = $false }
    [System.Windows.Forms.Application]::DoEvents()

    try {
        if ($Action -eq 'Sync') {
            $runner = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\scripts\weekly-skill-collection.ps1'
            if (-not (Test-Path -LiteralPath $runner)) { $runner = Join-Path $RepositoryPath 'scripts\weekly-skill-collection.ps1' }
            $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-Action', 'Sync')
        }
        else {
            $arguments = @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $coreScript,
                '-Action', $Action, '-RepositoryUrl', $RepositoryUrl, '-ReleaseManifestUrl', $ReleaseManifestUrl, '-RepositoryPath', $RepositoryPath
            )
            if ($Action -eq 'Install') { $arguments += '-InstallClaudeDesktopIfMissing' }
            if ($join) { $arguments += @('-JoinName', $join.Name, '-JoinEmail', $join.Email) }
        }
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & powershell.exe @arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedPreference }
        $lines = @($output | ForEach-Object { $_.ToString() })
        $logDirectory = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        @("[$(Get-Date -Format o)] Action=$Action ExitCode=$exitCode") + $lines |
            Add-Content -LiteralPath (Join-Path $logDirectory 'setup.log') -Encoding UTF8
        # The progress markers are for the setup wizard; keep this view readable.
        $status.Text = (($lines | Where-Object { $_ -notmatch '^\[(PHASE|RESULT)\]' }) -join "`r`n")
        $status.AppendText($(if ($exitCode -eq 0) { "`r`n`r`nFinished successfully." } else { "`r`n`r`nThis needs attention. Read the message above, or contact your administrator." }))
    }
    catch {
        $status.Text = $_.Exception.Message
    }
    finally {
        $form.UseWaitCursor = $false
        foreach ($button in $buttons) { $button.Enabled = $true }
    }
}

foreach ($button in $buttons) {
    $button.Add_Click({
        param($sender)
        if ($sender.Tag -eq 'Settings') { Show-ConnectorSettings -Root $RepositoryPath }
        else { Invoke-SetupAction $sender.Tag }
    })
}
$closeButton.Add_Click({ $form.Close() })

$form.Add_Shown({
    if ($SmokeTest) {
        $form.Close()
    }
    else {
        Invoke-SetupAction $InitialAction
    }
})
[void]$form.ShowDialog()
