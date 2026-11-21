# Shared by the outer installer and BIM-CAD-Setup.ps1. Requires an STA session with WinForms loaded.
$script:TeamJoinNotice = 'Your name, email, PC name, Windows user, IP address and which connector skills/tools you use are reported to the administrator.'

function Test-TeamJoinName {
    param([string]$Name)
    $value = $Name.Trim()
    # Quotes and backslashes are refused because the values are passed on to Setup-BimCad.ps1 as
    # command-line arguments; < and > because the service rejects them.
    $value.Length -ge 1 -and $value.Length -le 80 -and $value -notmatch '["\\<>\r\n\t]'
}

function Test-TeamJoinEmail {
    param([string]$Email)
    $value = $Email.Trim()
    $value.Length -le 254 -and $value -match '^[^@\s"]+@[^@\s"]+\.[^@\s"]+$'
}

# Offered on every PC that has not joined yet; joining needs no team code. $PayloadInstaller is kept for callers.
function Test-TeamJoinRequired {
    param([string]$PayloadInstaller)
    -not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\service.json') -PathType Leaf)
}

function Show-TeamJoinDialog {
    param([System.Windows.Forms.IWin32Window]$Owner = $null)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Join the team skill service'
    $dialog.StartPosition = if ($Owner) { 'CenterParent' } else { 'CenterScreen' }
    $dialog.TopMost = -not $Owner
    $dialog.ClientSize = New-Object System.Drawing.Size(560, 300)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = 'Your name'
    $nameLabel.AutoSize = $true
    $nameLabel.Location = New-Object System.Drawing.Point(20, 20)
    $dialog.Controls.Add($nameLabel)
    $name = New-Object System.Windows.Forms.TextBox
    $name.Location = New-Object System.Drawing.Point(20, 46)
    $name.Size = New-Object System.Drawing.Size(520, 28)
    $name.MaxLength = 80
    $dialog.Controls.Add($name)

    $emailLabel = New-Object System.Windows.Forms.Label
    $emailLabel.Text = 'Email'
    $emailLabel.AutoSize = $true
    $emailLabel.Location = New-Object System.Drawing.Point(20, 86)
    $dialog.Controls.Add($emailLabel)
    $email = New-Object System.Windows.Forms.TextBox
    $email.Location = New-Object System.Drawing.Point(20, 112)
    $email.Size = New-Object System.Drawing.Size(520, 28)
    $email.MaxLength = 254
    $dialog.Controls.Add($email)

    $consent = New-Object System.Windows.Forms.CheckBox
    $consent.Text = 'I understand. ' + $script:TeamJoinNotice
    $consent.Location = New-Object System.Drawing.Point(20, 156)
    $consent.Size = New-Object System.Drawing.Size(520, 66)
    $consent.CheckAlign = 'TopLeft'
    $consent.TextAlign = 'TopLeft'
    $dialog.Controls.Add($consent)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Install'
    $ok.Location = New-Object System.Drawing.Point(330, 246)
    $ok.Size = New-Object System.Drawing.Size(100, 32)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Enabled = $false
    $dialog.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Skip'
    $cancel.Location = New-Object System.Drawing.Point(440, 246)
    $cancel.Size = New-Object System.Drawing.Size(100, 32)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    $validate = { $ok.Enabled = $consent.Checked -and (Test-TeamJoinName $name.Text) -and (Test-TeamJoinEmail $email.Text) }
    $name.Add_TextChanged($validate)
    $email.Add_TextChanged($validate)
    $consent.Add_CheckedChanged($validate)

    try {
        $answer = if ($Owner) { $dialog.ShowDialog($Owner) } else { $dialog.ShowDialog() }
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK -or -not $ok.Enabled) { return $null }
        [pscustomobject]@{Name=$name.Text.Trim();Email=$email.Text.Trim()}
    }
    finally { $dialog.Dispose() }
}
