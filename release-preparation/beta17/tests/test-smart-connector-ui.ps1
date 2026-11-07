$ErrorActionPreference = 'Stop'
# The Smart Connector windows compiled into SmartConnector.exe (app, setup, action windows, settings): the launchers
# prefer the installed program, the icon family matches Brand.ps1, every window builds (--smoke-test), the icons render
# through WPF, a second start hands its section to the open window like SmartConnectorApp.ps1, and the status snapshot,
# reminder rules and action outcomes give the same answers as ConnectorStatus.ps1 and ConnectorActions.ps1.
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$connector = Join-Path $runtime 'src/connector'

# 1. Source checks (any platform).
$brandPs = Get-Content (Join-Path $runtime 'installer/Brand.ps1') -Raw
$brandCs = Get-Content (Join-Path $connector 'Brand.cs') -Raw
$icons = @([regex]::Matches($brandPs, "(?m)^\s+([a-z]+)\s+=\s+'(M[^']+)'") | ForEach-Object { , @($_.Groups[1].Value, $_.Groups[2].Value) })
Assert ($icons.Count -ge 26) "Brand.ps1 icon paths were not found ($($icons.Count))"
foreach ($icon in $icons) { Assert ($brandCs.Contains('{ "' + $icon[0] + '", "' + $icon[1] + '" }')) "Brand.cs path for $($icon[0]) differs from Brand.ps1" }
'PASS: Brand.cs carries the same {0} icon paths as Brand.ps1' -f $icons.Count

$iss = Get-Content (Join-Path $runtime '../../setup/SmartAutodeskConnector.iss') -Raw
$build = Get-Content (Join-Path $runtime '../../setup/build-connector-exe.ps1') -Raw
$revit = Get-Content (Join-Path $runtime 'src/revit/addin/ConnectorUi.cs') -Raw
$lisp = Get-Content (Join-Path $runtime 'src/autocad/SmartAutodeskConnector.bundle/Contents/SmartAutodeskConnector.lsp') -Raw
$cmd = Get-Content (Join-Path $runtime 'installer/Start-Autodesk-MCP-Connector.cmd') -Raw
$wizard = Get-Content (Join-Path $runtime 'installer/SetupWizard.ps1') -Raw
$appPs = Get-Content (Join-Path $runtime 'installer/SmartConnectorApp.ps1') -Raw
$core = Get-Content (Join-Path $runtime 'installer/Setup-BimCad.ps1') -Raw
$main = Get-Content (Join-Path $connector 'McpServer.cs') -Raw
Assert ($iss.Contains('Filename: "{#InstallRoot}\bin\SmartConnector.exe"; Parameters: "app"')) 'The Start menu entry does not open the installed program'
Assert ($build.Contains("'/target:winexe'") -and $build.Contains("'WPF\PresentationCore.dll'") -and $build.Contains("'WPF\WindowsBase.dll'") -and $build.Contains("'System.Windows.Forms.dll'")) 'The program is not built as a Windows program with WinForms and WPF'
Assert ($revit.Contains('Path.Combine(root, "bin", "SmartConnector.exe")') -and $revit.Contains('"app --section " + section')) 'Revit does not open the installed program'
Assert ($lisp.Contains('"app --section Overview"') -and $lisp.Contains('"action --action SkillsSync"') -and $lisp.Contains('"\\bin\\SmartConnector.exe"')) 'AutoCAD does not open the installed program'
Assert ($cmd.Contains('"%~dp0..\bin\SmartConnector.exe" app') -and $cmd.Contains('SmartConnectorApp.ps1')) 'The start command does not prefer the program, or lost the PowerShell fallback'
Assert ($wizard.Contains("'bin\SmartConnector.exe'") -and $appPs.Contains("-ArgumentList 'setup'") -and $core.Contains("`$shortcut.Arguments = 'app'")) 'Setup, the first open or the Start menu repair does not prefer the program'
Assert ($revit.Contains('-Action InstallUpdate') -and $lisp.Contains('"-Action InstallUpdate"')) 'The update window must stay PowerShell: it replaces the folder the program runs from'
Assert ($main.Contains('args[0] == "mcp"') -and $main.Contains('command == "app" || command == "setup" || command == "action" || command == "settings"')) 'Program.Main lost a command'
'PASS: Start menu, Revit, AutoCAD, the start command, setup and the first open prefer the installed program'

if ([Environment]::OSVersion.Platform -ne 'Win32NT') { 'SKIP: the Smart Connector windows need Windows'; return }

$t = Join-Path ([IO.Path]::GetTempPath()) ('connector-ui-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $t 'root'
$saved = @{ local = $env:LOCALAPPDATA; roaming = $env:APPDATA }
$mutex = $null
try {
    # 2. Build into an install-shaped folder: <root>\bin\SmartConnector.exe beside VERSION, assets, skills and scripts.
    $exe = Join-Path $root 'bin\SmartConnector.exe'
    $null = & (Join-Path $PSScriptRoot '../setup/build-connector-exe.ps1') -OutputPath $exe
    Copy-Item (Join-Path $runtime 'VERSION') $root
    foreach ($folder in 'assets', 'installer', 'scripts') { Copy-Item (Join-Path $runtime $folder) (Join-Path $root $folder) -Recurse }
    New-Item -ItemType Directory -Force (Join-Path $root '.agents') | Out-Null
    Copy-Item (Join-Path $runtime '.agents\skills') (Join-Path $root '.agents') -Recurse
    Assert (-not (Test-Path (Join-Path $root 'installer\team-join.json'))) 'A team join code reached the test install'

    $env:LOCALAPPDATA = Join-Path $t 'local'; $env:APPDATA = Join-Path $t 'roaming'
    New-Item -ItemType Directory -Force $env:LOCALAPPDATA, $env:APPDATA | Out-Null

    # Runs the program with redirected pipes and waits (it is a Windows program, so PowerShell would not wait by itself).
    function Invoke-Program([string]$Arguments, [string]$InputText = '') {
        $info = New-Object Diagnostics.ProcessStartInfo($exe, $Arguments)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $errors = $process.StandardError.ReadToEndAsync()
            $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
            $writer.Write($InputText); $writer.Close()
            $output = $process.StandardOutput.ReadToEnd()
            if (-not $process.WaitForExit(120000)) { $process.Kill(); throw "SmartConnector.exe $Arguments did not finish." }
            [pscustomobject]@{ Code = $process.ExitCode; Out = $output; Err = $errors.Result }
        }
        finally { $process.Dispose() }
    }

    $version = (Get-Content (Join-Path $runtime 'VERSION') -Raw).Trim()
    $run = Invoke-Program '--version'
    Assert ($run.Code -eq 0 -and $run.Out.Trim() -eq $version) "--version does not print the version as a Windows program: $($run.Out)"
    'PASS: the Windows program still prints its version over a pipe'

    # 3. Every window builds without being shown or running anything.
    foreach ($section in 'Overview', 'Autodesk', 'AI', 'Skills', 'Components', 'Updates', 'Settings', 'Diagnostics', 'Help') {
        $run = Invoke-Program "app --section $section --smoke-test"
        Assert ($run.Code -eq 0 -and $run.Out -match 'SMOKE_OK') ("app --section $section did not build:`n" + $run.Out + $run.Err)
    }
    foreach ($command in 'setup', 'action', 'settings') {
        $run = Invoke-Program "$command --smoke-test"
        Assert ($run.Code -eq 0 -and $run.Out -match 'SMOKE_OK') ("$command did not build:`n" + $run.Out + $run.Err)
    }
    Assert (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\terms-accepted.json'))) 'A smoke test wrote setup state'
    'PASS: the app builds all nine sections; the setup, action and settings windows build'

    $run = Invoke-Program 'app --check-icons'
    Assert ($run.Code -eq 0 -and $run.Out -match 'ICONS_OK') ("The icon family does not render through WPF:`n" + $run.Out + $run.Err)
    'PASS: every icon renders through WPF, plain and as a tile, at 100 % and 150 %'

    # 4. One window per user: while another start holds the app's mutex, a second start hands over its section and exits.
    $mutex = New-Object Threading.Mutex($false, 'Local\SmartConnector.App')
    Assert ($mutex.WaitOne(0)) 'The app mutex is already held on this computer'
    $request = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\app-section.txt'
    $run = Invoke-Program 'app --section Skills'
    Assert ($run.Code -eq 0 -and (Test-Path $request) -and (Get-Content $request -Raw).Trim() -eq 'Skills') 'A second start did not hand its section to the open window'
    $mutex.ReleaseMutex(); $mutex.Dispose(); $mutex = $null
    Remove-Item $request
    'PASS: a second start writes app-section.txt for the open window, as SmartConnectorApp.ps1 does'

    # 5. Status snapshot, headline and reminder rules: the same answers as ConnectorStatus.ps1 for the same files.
    . (Join-Path $runtime 'installer/ConnectorStatus.ps1') -RepositoryPath $root
    $connectorState = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
    $skillState = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
    New-Item -ItemType Directory -Force $connectorState, $skillState | Out-Null
    function Assert-SameSnapshot([string]$Case, [double]$Now) {
        $text = $Now.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        $run = Invoke-Program "app --print-snapshot --now $text"
        Assert ($run.Code -eq 0) ("$Case`: --print-snapshot failed: " + $run.Err)
        $mine = $run.Out | ConvertFrom-Json
        $s = Get-ConnectorSnapshot
        $h = Get-ConnectorHeadline $s
        $expected = [ordered]@{
            Version = $s.Version; Installed = $s.Installed; RevitInstalled = $s.RevitInstalled; RevitAddin = $s.RevitAddin
            AutoCadInstalled = $s.AutoCadInstalled; AutoCadReleases = (@($s.AutoCadReleases) -join ','); AutoCadPanel = $s.AutoCadPanel
            ClaudeDesktopInstalled = $s.ClaudeDesktop.Installed; ClaudeDesktopConnected = $s.ClaudeDesktop.Connected
            ClaudeCodeConnected = $s.ClaudeCode.Connected; CodexConnected = $s.Codex.Connected
            TeamJoined = $s.TeamJoined; AutoUpdates = $s.AutoUpdates; AvailableVersion = $s.AvailableVersion; LastChecked = $s.LastChecked
            LastSync = $s.LastSync; LastSyncStatus = $s.LastSyncStatus; LastSyncReason = $s.LastSyncReason
            SyncSubmitted = $s.SyncSubmitted; SyncUpdated = $s.SyncUpdated; LastSyncDay = ([double]$s.LastSyncDay).ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture); SyncReminder = $s.SyncReminder
            Headline = '{0}|{1}|{2}' -f $h.Kind, $h.Title, $h.Text
            UpdateCheckDue = (Test-UpdateCheckDue $s -Now $Now); SyncReminderDue = (Test-SyncReminderDue $s -Now $Now)
            Skills = (@(Get-InstalledWorkflowSkills | ForEach-Object { $_.Name + ':' + $_.Category }) -join ',')
        }
        $actual = [ordered]@{
            Version = $mine.Version; Installed = $mine.Installed; RevitInstalled = $mine.RevitInstalled; RevitAddin = $mine.RevitAddin
            AutoCadInstalled = $mine.AutoCadInstalled; AutoCadReleases = (@($mine.AutoCadReleases) -join ','); AutoCadPanel = $mine.AutoCadPanel
            ClaudeDesktopInstalled = $mine.ClaudeDesktop.Installed; ClaudeDesktopConnected = $mine.ClaudeDesktop.Connected
            ClaudeCodeConnected = $mine.ClaudeCode.Connected; CodexConnected = $mine.Codex.Connected
            TeamJoined = $mine.TeamJoined; AutoUpdates = $mine.AutoUpdates; AvailableVersion = $mine.AvailableVersion; LastChecked = $mine.LastChecked
            LastSync = $mine.LastSync; LastSyncStatus = $mine.LastSyncStatus; LastSyncReason = $mine.LastSyncReason
            SyncSubmitted = $mine.SyncSubmitted; SyncUpdated = $mine.SyncUpdated; LastSyncDay = ([double]$mine.LastSyncDay).ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture); SyncReminder = $mine.SyncReminder
            Headline = '{0}|{1}|{2}' -f $mine.Headline.Kind, $mine.Headline.Title, $mine.Headline.Text
            UpdateCheckDue = $mine.UpdateCheckDue; SyncReminderDue = $mine.SyncReminderDue
            Skills = (@($mine.Skills | ForEach-Object { $_.Name + ':' + $_.Category }) -join ',')
        }
        foreach ($key in $expected.Keys) {
            Assert ([string]$actual[$key] -eq [string]$expected[$key]) ("{0}: {1} is '{2}', ConnectorStatus.ps1 says '{3}'" -f $Case, $key, $actual[$key], $expected[$key])
        }
    }
    $today = Get-StatusToday
    Assert-SameSnapshot 'fresh PC' $today
    Write-StatusDay (Join-Path $connectorState 'open-check.txt')
    Assert-SameSnapshot 'checked today' $today
    Assert-SameSnapshot 'checked yesterday' ($today + 1)
    '{"notifications_user_disabled":  true, "available_version": "1.2.0", "installed_version": "1.1.0", "last_checked_utc": "2026-01-02T03:04:05Z"}' | Set-Content (Join-Path $connectorState 'update-state.json')
    Assert-SameSnapshot 'update checks off' ($today + 5)
    '{}' | Set-Content (Join-Path $skillState 'service.json')
    Assert-SameSnapshot 'team PC never synced' $today
    Write-StatusDay (Join-Path $skillState 'last-sync.txt')
    Assert-SameSnapshot 'synced six days ago' ($today + 6)
    Assert-SameSnapshot 'synced over a week ago' ($today + 7.5)
    '{"enabled":  false}' | Set-Content (Join-Path $skillState 'settings.json')
    Assert-SameSnapshot 'reminder off' ($today + 30)
    New-Item -ItemType Directory -Force (Join-Path $env:APPDATA 'Claude'), (Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2024') | Out-Null
    '{"mcpServers":{"keep":{},"Smart Connector":{"command":"x"}}}' | Set-Content (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')
    '<x/>' | Set-Content (Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2024\AutodeskMcpConnector.addin')
    Assert-SameSnapshot 'Claude and Revit set up' $today
    @{ completed_at = '2026-03-04T05:06:07.0000000Z'; sync_status = 'failed'; sync_reason = 'Skills Sync stopped: test'; sync_submitted = 2; sync_added = 1; sync_updated = 3 } | ConvertTo-Json | Set-Content (Join-Path $skillState 'last-result.json')
    $approved = Join-Path $skillState 'approved-skills'
    New-Item -ItemType Directory -Force (Join-Path $approved 'zz-team-skill'), (Join-Path $approved 'autocad-read-write') | Out-Null
    "---`nname: zz-team-skill`ncategory: general`n---`n# Team" | Set-Content (Join-Path $approved 'zz-team-skill\SKILL.md')
    "# Local copy without a category" | Set-Content (Join-Path $approved 'autocad-read-write\SKILL.md')
    Assert-SameSnapshot 'failed sync and approved skills' $today
    'PASS: snapshot, headline, update-check and weekly reminder rules match ConnectorStatus.ps1'

    # 6. Action outcomes: the same titles, colours and text as ConnectorActions.ps1 for the same output and files.
    . (Join-Path $runtime 'installer/ConnectorActions.ps1') -RepositoryPath $root -LibraryOnly
    function Assert-SameOutcome([string]$Name, [string]$Output, $Expected) {
        $run = Invoke-Program "action --outcome $Name" $Output
        Assert ($run.Code -eq 0) ("action --outcome $Name failed: " + $run.Err)
        $mine = $run.Out | ConvertFrom-Json
        foreach ($key in 'Title', 'Kind', 'Body') { Assert ([string]$mine.$key -eq [string]$Expected.$key) ("{0} outcome {1} is '{2}', ConnectorActions.ps1 says '{3}'" -f $Name, $key, $mine.$key, $Expected.$key) }
        if ($Expected.PSObject.Properties['State']) { Assert ($mine.State -eq $Expected.State -and [bool]$mine.UserOff -eq [bool]$Expected.UserOff) "$Name outcome state differs" }
    }
    $result = Join-Path $skillState 'last-result.json'
    Assert-SameOutcome 'SkillsSync' 'A collection run is already active.' (Get-SkillsSyncOutcome 'A collection run is already active.')
    Assert-SameOutcome 'SkillsSync' 'done' (Get-SkillsSyncOutcome 'done')
    @{ sync_status = 'ok'; sync_submitted = 1; sync_added = 2; sync_updated = 0; sync_preserved = 1; sync_approved_total = 30 } | ConvertTo-Json | Set-Content $result
    Assert-SameOutcome 'SkillsSync' 'done' (Get-SkillsSyncOutcome 'done')
    @{ sync_status = 'partial'; sync_reason = 'Downloaded, not sent.'; sync_submitted = 0; sync_added = 1; sync_updated = 1; sync_approved_total = 31 } | ConvertTo-Json | Set-Content $result
    Assert-SameOutcome 'SkillsSync' 'done' (Get-SkillsSyncOutcome 'done')
    $state = Join-Path $connectorState 'update-state.json'
    @{ installed_version = '1.0.0-beta.18'; available_version = '1.0.0-beta.19'; notifications_user_disabled = $true } | ConvertTo-Json | Set-Content $state
    foreach ($output in '[10:00:00] [UPDATE_AVAILABLE] Version 1.0.0-beta.19 is available.', '[UP_TO_DATE] ok', 'error') {
        Assert-SameOutcome 'CheckUpdates' $output (Get-CheckUpdatesOutcome $output)
    }
    $status = "[09:59:59] Smart Connector - Status`n[10:00:00] AutoCAD installation detected: R25.0`n[10:00:01] Live AutoCAD connection passed: version 25.0; a.dwg; 3 layer(s).`nautodesk`n  enabled: true`n  transport: stdio`n[10:00:02] Codex has the Smart Connector registration."
    foreach ($output in $status, '[10:00:00] AutoCAD is running, but no drawing is open.', '') {
        Assert-SameOutcome 'Status' $output (Get-ConnectionStatusOutcome $output)
    }
    'PASS: Skills Sync, Check Updates and Connection Status outcomes match ConnectorActions.ps1'
}
finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
    $env:LOCALAPPDATA = $saved.local; $env:APPDATA = $saved.roaming
    Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
