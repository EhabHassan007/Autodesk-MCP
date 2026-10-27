[CmdletBinding()]
param(
    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/Autodesk-MCP.git',
    [string]$ReleaseManifestUrl = 'https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json',
    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),
    [switch]$TestNotification
)

$ErrorActionPreference = 'Stop'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
$logPath = Join-Path $stateDirectory 'update-alert.log'
$setup = Join-Path $RepositoryPath 'installer\Setup-BimCad.ps1'
$launcher = Join-Path $RepositoryPath 'installer\BIM-CAD-Setup.ps1'

function Write-AlertLog {
    param([string]$Message)

    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $line = '[{0}] {1}' -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    $lines = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 200) {
        $lines[-200..-1] | Set-Content -LiteralPath $logPath -Encoding UTF8
    }
}

function Show-UpdateAlert {
    param(
        [ValidateSet('Test', 'Updated', 'Failed')]
        [string]$Mode
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Autodesk MCP Connector'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(520, 190)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = switch ($Mode) {
        'Test' { 'Automatic update notifications are working' }
        'Updated' { 'Autodesk MCP Connector was updated' }
        'Failed' { 'Autodesk MCP Connector needs attention' }
    }
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 22)
    $form.Controls.Add($title)

    $message = New-Object System.Windows.Forms.Label
    $message.Text = switch ($Mode) {
        'Test' { 'This is a test. Future approved updates will install automatically, then this confirmation will appear.' }
        'Updated' { 'The approved connector and skills were installed automatically. Restart Revit, Codex, and Claude to load them.' }
        'Failed' { 'The automatic update could not finish. Open Autodesk MCP Connector and select Update.' }
    }
    $message.AutoSize = $false
    $message.Size = New-Object System.Drawing.Size(470, 48)
    $message.Location = New-Object System.Drawing.Point(27, 66)
    $form.Controls.Add($message)

    $primary = New-Object System.Windows.Forms.Button
    $primary.Text = 'OK'
    $primary.Size = New-Object System.Drawing.Size(130, 34)
    $primary.Location = New-Object System.Drawing.Point(350, 132)
    $primary.Add_Click({ $form.Close() })
    $form.Controls.Add($primary)
    $form.AcceptButton = $primary

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 30000
    $timer.Add_Tick({ $timer.Stop(); $form.Close() })
    $form.Add_Shown({ $form.Activate(); $primary.Focus(); $timer.Start() })
    try { [void]$form.ShowDialog() }
    finally { $timer.Dispose(); $form.Dispose() }
}

try {
    Write-AlertLog $(if ($TestNotification) { 'Starting test notification.' } else { 'Starting scheduled update check.' })
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf) -or
        -not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw 'The installed updater files are missing.'
    }

    if ($TestNotification) {
        Show-UpdateAlert -Mode Test
        Write-AlertLog 'Test notification displayed successfully.'
        exit 0
    }

    $statePath = Join-Path $stateDirectory 'update-state.json'
    $savedState = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    else { $null }
    $installedVersion = if ($savedState -and $savedState.installed_version) { [string]$savedState.installed_version } else { 'unknown' }
    Write-AlertLog ("Installed version: {0}; checking public release manifest." -f $installedVersion)

    $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $setup `
        -Action CheckUpdate -RepositoryUrl $RepositoryUrl -ReleaseManifestUrl $ReleaseManifestUrl -RepositoryPath $RepositoryPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Update check stopped with exit code $LASTEXITCODE." }
    $message = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    $markers = @([regex]::Matches($message, '\[(?:UPDATE_AVAILABLE|UP_TO_DATE|UPDATE_STATUS_UNKNOWN)\]') |
        ForEach-Object { $_.Value } | Select-Object -Unique)
    Write-AlertLog ("Update check marker: {0}" -f $(if ($markers.Count -gt 0) { $markers -join ', ' } else { 'none' }))
    if ($message -notmatch '\[UPDATE_AVAILABLE\]') {
        Write-AlertLog 'No approved update is currently available.'
        exit 0
    }

    Write-AlertLog 'An approved update is available; starting automatic installation.'
    $updateOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $setup `
        -Action Update -RepositoryUrl $RepositoryUrl -ReleaseManifestUrl $ReleaseManifestUrl -RepositoryPath $RepositoryPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($updateOutput | ForEach-Object { $_.ToString() }) -join ' '
        Write-AlertLog ("Automatic update failed: {0}" -f $details.Replace("`r", ' ').Replace("`n", ' '))
        Show-UpdateAlert -Mode Failed
        exit 1
    }
    Write-AlertLog 'Automatic update completed successfully; displaying restart notice.'
    Show-UpdateAlert -Mode Updated
    exit 0
}
catch {
    Write-AlertLog ("Notification failed: {0}" -f $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' '))
    try { Show-UpdateAlert -Mode Failed } catch { }
    exit 1
}
