param(
    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/BIM-CAD---MCP.git',
    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$coreScript = Join-Path $PSScriptRoot 'Setup-BimCad.ps1'

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BIM-CAD MCP Setup'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(680, 550)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'BIM-CAD MCP Setup'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 20)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Download approved skills from GitHub and connect Codex to your CAD application.'
$subtitle.AutoSize = $true
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(28, 62)
$form.Controls.Add($subtitle)

$productLabel = New-Object System.Windows.Forms.Label
$productLabel.Text = 'Application'
$productLabel.AutoSize = $true
$productLabel.Location = New-Object System.Drawing.Point(28, 102)
$form.Controls.Add($productLabel)

$product = New-Object System.Windows.Forms.ComboBox
$product.DropDownStyle = 'DropDownList'
$product.Items.Add('AutoCAD - automatic version detection') | Out-Null
$product.Items.Add('Revit 2024') | Out-Null
$product.SelectedIndex = 0
$product.Location = New-Object System.Drawing.Point(28, 126)
$product.Size = New-Object System.Drawing.Size(320, 30)
$form.Controls.Add($product)

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Install / Repair'
$installButton.Location = New-Object System.Drawing.Point(370, 123)
$installButton.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($installButton)

$updateButton = New-Object System.Windows.Forms.Button
$updateButton.Text = 'Update'
$updateButton.Location = New-Object System.Drawing.Point(510, 123)
$updateButton.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($updateButton)

$testButton = New-Object System.Windows.Forms.Button
$testButton.Text = 'Test connection'
$testButton.Location = New-Object System.Drawing.Point(28, 174)
$testButton.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($testButton)

$folderButton = New-Object System.Windows.Forms.Button
$folderButton.Text = 'Install folder'
$folderButton.Location = New-Object System.Drawing.Point(518, 174)
$folderButton.Size = New-Object System.Drawing.Size(122, 34)
$form.Controls.Add($folderButton)

$collectButton = New-Object System.Windows.Forms.Button
$collectButton.Text = 'Review local skills'
$collectButton.Location = New-Object System.Drawing.Point(178, 174)
$collectButton.Size = New-Object System.Drawing.Size(160, 34)
$form.Controls.Add($collectButton)

$submitButton = New-Object System.Windows.Forms.Button
$submitButton.Text = 'Submit review package'
$submitButton.Location = New-Object System.Drawing.Point(348, 174)
$submitButton.Size = New-Object System.Drawing.Size(160, 34)
$form.Controls.Add($submitButton)

$teamButton = New-Object System.Windows.Forms.Button
$teamButton.Text = 'Team collection check'
$teamButton.Location = New-Object System.Drawing.Point(28, 220)
$teamButton.Size = New-Object System.Drawing.Size(190, 34)
$form.Controls.Add($teamButton)

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

    $selectedProduct = if ($product.SelectedIndex -eq 0) { 'AutoCAD' } else { 'Revit' }
    $status.Text = "Working...`r`n"
    $form.UseWaitCursor = $true
    foreach ($button in @($installButton, $updateButton, $testButton, $collectButton, $submitButton, $teamButton)) { $button.Enabled = $false }
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $coreScript `
            -Action $Action -Product $selectedProduct -RepositoryUrl $RepositoryUrl -RepositoryPath $RepositoryPath 2>&1
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
        foreach ($button in @($installButton, $updateButton, $testButton, $collectButton, $submitButton, $teamButton)) { $button.Enabled = $true }
    }
}

$installButton.Add_Click({ Invoke-SetupAction 'Install' })
$updateButton.Add_Click({ Invoke-SetupAction 'Update' })
$testButton.Add_Click({ Invoke-SetupAction 'Test' })
$collectButton.Add_Click({ Invoke-SetupAction 'Collect' })
$teamButton.Add_Click({ Invoke-SetupAction 'TeamStatus' })
$submitButton.Add_Click({
    $reviewRoot = Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\skill-review'
    $package = Get-ChildItem -LiteralPath $reviewRoot -Filter 'skill-review-*.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $package) {
        [System.Windows.Forms.MessageBox]::Show('Choose Review local skills first.', 'BIM-CAD MCP Setup') | Out-Null
        return
    }
    Start-Process explorer.exe -ArgumentList ("/select,`"{0}`"" -f $package.FullName)
    Start-Process 'https://github.com/EhabHassan007/BIM-CAD---MCP/issues/new?template=skill-submission.yml'
    [System.Windows.Forms.MessageBox]::Show('Review the ZIP, then attach it to the GitHub submission form. Nothing is uploaded automatically.', 'BIM-CAD MCP Setup') | Out-Null
})
$folderButton.Add_Click({
    if (Test-Path -LiteralPath $RepositoryPath) {
        Start-Process explorer.exe -ArgumentList $RepositoryPath
    }
    else {
        [System.Windows.Forms.MessageBox]::Show('Run Install / Repair first.', 'BIM-CAD MCP Setup') | Out-Null
    }
})
$closeButton.Add_Click({ $form.Close() })

$form.Add_Shown({
    if ($SmokeTest) {
        $form.Close()
    }
    else {
        Invoke-SetupAction 'Status'
    }
})
[void]$form.ShowDialog()
