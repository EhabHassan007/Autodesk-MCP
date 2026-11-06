# What the Smart Connector app shows: a snapshot of this PC built only from files, the registry and the
# process list, so the app opens instantly. No network, no external commands, no secrets read.
# Dot-source, then call Get-ConnectorSnapshot. Every check is guarded; a missing item reads as not installed.
param([string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'))

$script:StatusPaths = @{
    Install        = $RepositoryPath
    ConnectorState = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
    SkillState     = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
    RevitManifest  = Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2024\AutodeskMcpConnector.addin'
    AutoCadBundle  = Join-Path $env:APPDATA 'Autodesk\ApplicationPlugins\SmartAutodeskConnector.bundle\PackageContents.xml'
}

# Skill folders and categories, as Skills Sync sees them.
$script:StatusSkillLibrary = Join-Path $RepositoryPath 'scripts\SkillLibrary.ps1'
if (Test-Path -LiteralPath $script:StatusSkillLibrary -PathType Leaf) { . $script:StatusSkillLibrary }

function Read-StatusJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $null }
}

function Get-StatusValue {
    param($Object, [string]$Name)
    if ($Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null }
}

function Test-StatusProcess {
    param([string]$Name)
    [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue)
}

function Get-AutoCadReleasesInstalled {
    try { @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Autodesk\AutoCAD' -ErrorAction Stop | ForEach-Object PSChildName) } catch { @() }
}

# True when a Claude Desktop config (roaming or Microsoft Store copy) lists the Smart Connector entry.
function Test-ClaudeDesktopConnected {
    $paths = @(Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -LiteralPath $packages) {
        $paths += @(Get-ChildItem -LiteralPath $packages -Directory -Filter '*Claude*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json' })
    }
    foreach ($path in $paths) {
        $config = Read-StatusJson $path
        $servers = Get-StatusValue $config 'mcpServers'
        if ($servers -and $servers.PSObject.Properties['Smart Connector']) { return $true }
    }
    $false
}

function Test-ClaudeDesktopInstalled {
    (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')) -or
        (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Claude')) -or
        [bool](Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter '*Claude*' -ErrorAction SilentlyContinue)
}

function Test-ClaudeCodeConnected {
    $config = Read-StatusJson (Join-Path $HOME '.claude.json')
    $servers = Get-StatusValue $config 'mcpServers'
    [bool]($servers -and $servers.PSObject.Properties['autodesk'])
}

function Test-CodexConnected {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $config = Join-Path $codexHome 'config.toml'
    (Test-Path -LiteralPath $config -PathType Leaf) -and [bool](Select-String -LiteralPath $config -Pattern '^\s*\[mcp_servers\.autodesk\]' -Quiet)
}

function Test-CommandOnPath {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Every installed workflow skill (shipped library and approved downloads), each once, by category.
function Get-InstalledWorkflowSkills {
    if (-not (Get-Command Get-SkillFolders -ErrorAction SilentlyContinue)) { return @() }
    $skills = @{}
    foreach ($skill in @(Get-SkillFolders (Join-Path $RepositoryPath '.agents\skills'))) { $skills[$skill.Name] = $skill }
    foreach ($skill in @(Get-SkillFolders (Join-Path $script:StatusPaths.SkillState 'approved-skills'))) {
        $category = if ($skill.Category) { $skill.Category } elseif ($skills.ContainsKey($skill.Name)) { $skills[$skill.Name].Category } else { 'uncategorized' }
        $skills[$skill.Name] = [pscustomobject]@{ Name = $skill.Name; Category = $category; Path = $skill.Path }
    }
    @($skills.Values | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Category = $(if ($_.Category) { $_.Category } else { 'uncategorized' })
            CategoryTitle = $(if ($script:SkillCategories -and $script:SkillCategories.Contains([string]$_.Category)) { $script:SkillCategories[[string]$_.Category] } else { 'Not yet categorised' }) }
    } | Sort-Object Category, Name)
}

function Get-ConnectorSnapshot {
    $versionPath = Join-Path $RepositoryPath 'VERSION'
    $update = Read-StatusJson (Join-Path $script:StatusPaths.ConnectorState 'update-state.json')
    $sync = Read-StatusJson (Join-Path $script:StatusPaths.SkillState 'last-result.json')
    $autoCadReleases = @(Get-AutoCadReleasesInstalled)
    $agentRunning = $false
    try { $mutex = [Threading.Mutex]::OpenExisting('Local\SmartAutodeskConnector.Agent'); $mutex.Dispose(); $agentRunning = $true } catch { }
    [pscustomobject]@{
        Version          = $(if (Test-Path -LiteralPath $versionPath) { (Get-Content -LiteralPath $versionPath -Raw).Trim() } else { '' })
        Installed        = Test-Path -LiteralPath (Join-Path $RepositoryPath 'installer\Setup-BimCad.ps1')
        RevitInstalled   = Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Autodesk\Revit 2024\RevitAPI.dll')
        RevitRunning     = Test-StatusProcess 'Revit'
        RevitAddin       = Test-Path -LiteralPath $script:StatusPaths.RevitManifest
        AutoCadInstalled = $autoCadReleases.Count -gt 0
        AutoCadReleases  = $autoCadReleases
        AutoCadRunning   = Test-StatusProcess 'acad'
        AutoCadPanel     = Test-Path -LiteralPath $script:StatusPaths.AutoCadBundle
        ClaudeDesktop    = [pscustomobject]@{ Installed = (Test-ClaudeDesktopInstalled); Connected = (Test-ClaudeDesktopConnected) }
        ClaudeCode       = [pscustomobject]@{ Installed = (Test-CommandOnPath 'claude'); Connected = (Test-ClaudeCodeConnected) }
        Codex            = [pscustomobject]@{ Installed = (Test-CommandOnPath 'codex'); Connected = (Test-CodexConnected) }
        TeamJoined       = Test-Path -LiteralPath (Join-Path $script:StatusPaths.SkillState 'service.json')
        AutoUpdates      = -not [bool](Get-StatusValue $update 'notifications_user_disabled')
        AvailableVersion = [string](Get-StatusValue $update 'available_version')
        LastChecked      = [string](Get-StatusValue $update 'last_checked_utc')
        LastSync         = [string](Get-StatusValue $sync 'completed_at')
        LastSyncStatus   = [string]$(if (Get-StatusValue $sync 'sync_status') { Get-StatusValue $sync 'sync_status' } else { Get-StatusValue $sync 'status' })
        LastSyncReason   = [string](Get-StatusValue $sync 'sync_reason')
        SyncSubmitted    = [int](Get-StatusValue $sync 'sync_submitted')
        SyncUpdated      = [int](Get-StatusValue $sync 'sync_updated') + [int](Get-StatusValue $sync 'sync_added')
        AgentRunning     = $agentRunning
    }
}

# One line for the top of the Overview, plus its badge kind.
function Get-ConnectorHeadline {
    param($Snapshot)
    $ai = @($Snapshot.ClaudeDesktop.Connected, $Snapshot.ClaudeCode.Connected, $Snapshot.Codex.Connected) -contains $true
    $cad = $Snapshot.RevitAddin -or $Snapshot.AutoCadPanel
    if (-not $Snapshot.Installed) { return [pscustomobject]@{ Kind = 'Bad'; Title = 'Smart Connector is not installed'; Text = 'Run the Smart Connector setup to install it.' } }
    if (-not $ai) { return [pscustomobject]@{ Kind = 'Warn'; Title = 'No AI app is connected'; Text = 'Connect Claude or Codex: open Components and choose Repair.' } }
    if (-not $cad) { return [pscustomobject]@{ Kind = 'Warn'; Title = 'No Autodesk program is set up'; Text = 'Install Revit 2024 or AutoCAD, then choose Repair in Components.' } }
    if ($Snapshot.LastSyncStatus -eq 'failed') { return [pscustomobject]@{ Kind = 'Warn'; Title = 'Working, but Skills Sync needs attention'; Text = $(if ($Snapshot.LastSyncReason) { $Snapshot.LastSyncReason } else { 'The last Skills Sync did not finish. Open Diagnostics for the log.' }) } }
    $apps = @(); if ($Snapshot.RevitAddin) { $apps += 'Revit' }; if ($Snapshot.AutoCadPanel) { $apps += 'AutoCAD' }
    $clients = @(); if ($Snapshot.ClaudeDesktop.Connected -or $Snapshot.ClaudeCode.Connected) { $clients += 'Claude' }; if ($Snapshot.Codex.Connected) { $clients += 'Codex' }
    [pscustomobject]@{ Kind = 'Good'; Title = 'Everything is set up'; Text = ('{0} can work with {1}.' -f ($clients -join ' and '), ($apps -join ' and ')) }
}
