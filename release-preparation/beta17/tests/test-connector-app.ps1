$ErrorActionPreference = 'Stop'
# Smart Connector app: the status snapshot reads only local files, the Overview headline matches what is set
# up, and on Windows the app builds every section without errors (-SmokeTest).
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$t = Join-Path ([IO.Path]::GetTempPath()) ('connector-app-' + [guid]::NewGuid().ToString('N'))
$saved = @{ local = $env:LOCALAPPDATA; roaming = $env:APPDATA }
$env:LOCALAPPDATA = Join-Path $t 'local'; $env:APPDATA = Join-Path $t 'roaming'
New-Item -ItemType Directory -Force $env:LOCALAPPDATA, (Join-Path $env:APPDATA 'Claude') | Out-Null
try {
    . (Join-Path $runtime 'installer/ConnectorStatus.ps1') -RepositoryPath $runtime

    $s = Get-ConnectorSnapshot
    Assert ($s.Installed -and $s.Version) 'Snapshot does not see the installed connector'
    Assert (-not $s.ClaudeDesktop.Connected -and -not $s.TeamJoined) 'Snapshot reports connections that do not exist'
    '{"mcpServers":{"keep":{},"Smart Connector":{"command":"powershell.exe"}}}' | Set-Content (Join-Path $env:APPDATA 'Claude/claude_desktop_config.json')
    New-Item -ItemType Directory -Force (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection') | Out-Null
    '{}' | Set-Content (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection/service.json')
    $s = Get-ConnectorSnapshot
    Assert ($s.ClaudeDesktop.Connected -and $s.TeamJoined) 'Snapshot misses the Claude Desktop entry or team join'
    Assert (@(Get-InstalledWorkflowSkills).Count -ge 30) 'Installed skills are not listed'
    'PASS: snapshot reads Claude Desktop, team and skills from local files only'

    $base = @{ Installed = $true; RevitAddin = $true; AutoCadPanel = $false; LastSyncStatus = 'ok'; LastSyncReason = ''
        ClaudeDesktop = [pscustomobject]@{ Connected = $true }; ClaudeCode = [pscustomobject]@{ Connected = $false }; Codex = [pscustomobject]@{ Connected = $false } }
    $h = Get-ConnectorHeadline ([pscustomobject]$base)
    Assert ($h.Kind -eq 'Good' -and $h.Text -eq 'Claude can work with Revit.') "Headline wrong: $($h.Text)"
    $none = $base.Clone(); $none.ClaudeDesktop = [pscustomobject]@{ Connected = $false }
    Assert ((Get-ConnectorHeadline ([pscustomobject]$none)).Kind -eq 'Warn') 'No AI app connected must warn'
    $cad = $base.Clone(); $cad.RevitAddin = $false
    Assert ((Get-ConnectorHeadline ([pscustomobject]$cad)).Title -like '*Autodesk*') 'No Autodesk program must warn'
    $sync = $base.Clone(); $sync.LastSyncStatus = 'failed'; $sync.LastSyncReason = 'Skills Sync stopped: test'
    Assert ((Get-ConnectorHeadline ([pscustomobject]$sync)).Text -eq 'Skills Sync stopped: test') 'Failed sync reason not shown'
    'PASS: Overview headline names only what is connected and surfaces a failed Skills Sync'

    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File (Join-Path $runtime 'installer/SmartConnectorApp.ps1') -RepositoryPath $runtime -SmokeTest 2>&1
        Assert ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match 'SMOKE_OK') ("The app did not build every section:`n" + ($out -join "`n"))
        'PASS: the app builds all nine sections'
    }
    else { 'SKIP: app smoke test needs Windows' }
}
finally { $env:LOCALAPPDATA = $saved.local; $env:APPDATA = $saved.roaming; Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
