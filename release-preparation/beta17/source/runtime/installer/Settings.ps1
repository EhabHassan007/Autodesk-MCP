# Smart Autodesk Connector settings: one switch for automatic updates, plus version information.
# Opened from the Revit ribbon, the notification-area menu and the Setup window. Run directly
# (powershell -STA -File Settings.ps1) or dot-source with -LibraryOnly and call Show-ConnectorSettings.
param([string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot), [switch]$LibraryOnly)

function Get-ConnectorSettingsState {
    param([string]$StatePath = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\update-state.json'))
    $state = $null
    if (Test-Path -LiteralPath $StatePath) { try { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { } }
    # No state yet, or a value never chosen by the person, both mean the default: on.
    $userOff = $state -and $state.PSObject.Properties['notifications_user_disabled'] -and [bool]$state.notifications_user_disabled
    [pscustomobject]@{
        AutoUpdate = -not $userOff
        Installed = if ($state) { [string]$state.installed_version } else { '' }
        Available = if ($state -and $state.PSObject.Properties['available_version']) { [string]$state.available_version } else { '' }
        LastChecked = if ($state -and $state.last_checked_utc) { [string]$state.last_checked_utc } else { '' }
    }
}

function Show-ConnectorSettings {
    param([string]$Root = $RepositoryPath)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    . (Join-Path $Root 'installer\Brand.ps1')
    $current = Get-ConnectorSettingsState
    $form = New-BrandForm -Width 480 -Height 300
    $form.Text = 'Smart Autodesk Connector settings'
    $null = Add-BrandHeader $form -Title 'Settings' -Subtitle 'Smart Autodesk Connector' -Height 76

    $auto = New-Object Windows.Forms.CheckBox
    $auto.Text = 'Install updates automatically (recommended)'
    $auto.Font = New-BrandFont 10.5 ([Drawing.FontStyle]::Bold) 'Segoe UI Semibold'
    $auto.AutoSize = $true; $auto.Location = New-Object Drawing.Point(26, 100)
    $auto.Checked = $current.AutoUpdate
    $form.Controls.Add($auto)
    $form.Controls.Add((New-BrandLabel 'Updates install by themselves when Revit and AutoCAD are closed. You get a notice when one is ready. When this is off, use Check Updates in Revit or AutoCAD to look for a new version.' 46 128 -Width 400 -Muted -Size 9))

    $when = ''
    if ($current.LastChecked) { try { $when = ([DateTime]::Parse($current.LastChecked).ToLocalTime()).ToString('g') } catch { } }
    $info = 'Installed version: ' + $(if ($current.Installed) { $current.Installed } else { 'unknown' })
    if ($current.Available) { $info += "    Update ready: $($current.Available)" }
    if ($when) { $info += "`r`nLast checked: $when" }
    $form.Controls.Add((New-BrandLabel $info 26 196 -Width 420 -Size 9))

    $save = New-BrandButton 'Save' -Primary -Width 110; $save.Location = New-Object Drawing.Point(226, 248)
    $close = New-BrandButton 'Cancel' -Width 110; $close.Location = New-Object Drawing.Point(346, 248)
    $close.DialogResult = 'Cancel'
    $form.Controls.AddRange(@($save, $close)); $form.AcceptButton = $save; $form.CancelButton = $close
    $save.Add_Click({
        if ($auto.Checked -ne $current.AutoUpdate) {
            $action = if ($auto.Checked) { 'EnableNotifications' } else { 'DisableNotifications' }
            $setup = Join-Path $Root 'installer\Setup-BimCad.ps1'
            $p = Start-Process powershell.exe -WindowStyle Hidden -Wait -PassThru -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action {1} -RepositoryPath "{2}"' -f $setup, $action, $Root)
            if ($p.ExitCode -ne 0) {
                [Windows.Forms.MessageBox]::Show($form, 'The setting could not be saved. Try again, or contact your administrator.', 'Smart Autodesk Connector', 'OK', 'Warning') | Out-Null
                return
            }
        }
        $form.DialogResult = 'OK'; $form.Close()
    })
    $form.TopMost = $true
    [void]$form.ShowDialog()
    $form.Dispose()
}

if (-not $LibraryOnly -and $MyInvocation.InvocationName -ne '.') { Show-ConnectorSettings }
