$ErrorActionPreference = 'Stop'
# Setup choices: which AI apps to connect, which Autodesk programs and whether to install team skills.
# Choices from the setup window are saved and reused by Update and Repair; unselected apps are left alone.
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$t = Join-Path ([IO.Path]::GetTempPath()) ('install-choices-' + [guid]::NewGuid().ToString('N'))
$saved = @{ local = $env:LOCALAPPDATA; roaming = $env:APPDATA }
$env:LOCALAPPDATA = Join-Path $t 'local'; $env:APPDATA = Join-Path $t 'roaming'
New-Item -ItemType Directory -Force $env:LOCALAPPDATA, $env:APPDATA | Out-Null
try {
    . (Join-Path $runtime 'installer/Setup-BimCad.ps1') -LibraryOnly
    $path = Join-Path $t 'choices.json'

    $c = Get-InstallChoices -Path $path
    Assert ((($c.AiClients) -join ',') -eq 'ClaudeDesktop,ClaudeCode,Codex' -and $c.Product -eq 'All' -and $c.Skills) 'Defaults must set up everything, as before'

    $c = Get-InstallChoices -AiClients 'claudedesktop, Codex' -Product 'Revit' -ProductGiven $true -Skills 'Off' -Path $path
    Assert ((($c.AiClients) -join ',') -eq 'ClaudeDesktop,Codex' -and $c.Product -eq 'Revit' -and -not $c.Skills) 'Window choices not applied'
    Save-InstallChoices $c -Path $path
    $again = Get-InstallChoices -Path $path
    Assert ((($again.AiClients) -join ',') -eq 'ClaudeDesktop,Codex' -and $again.Product -eq 'Revit' -and -not $again.Skills) 'Update and Repair must reuse the saved choices'
    $override = Get-InstallChoices -Product 'All' -ProductGiven $true -Path $path
    Assert ($override.Product -eq 'All' -and (($override.AiClients) -join ',') -eq 'ClaudeDesktop,Codex') 'A new choice must replace only what was given'
    $failed = $false; try { $null = Get-InstallChoices -AiClients 'Copilot' -Path $path } catch { $failed = $_.Exception.Message -like '*Unknown AI app*' }
    Assert $failed 'Unknown AI app names must be refused'
    'PASS: choices default to everything, are saved, reused by Update and Repair, and validated'

    # Only selected AI apps are registered; the others are reported as not selected.
    $script:registered = @()
    function Get-OptionalCommand { param($Name) "C:\fake\$Name.exe" }
    function Register-McpServer { $script:registered += 'Codex' }
    function Register-ClaudeCodeMcpServer { $script:registered += 'ClaudeCode' }
    function Register-ClaudeDesktopMcpServer { $script:registered += 'ClaudeDesktop' }
    function Get-ClaudeDesktopProcesses { @() }
    function Get-ClaudeDesktopInstallation { [pscustomobject]@{ Installed = $true } }
    function Get-ClaudeDesktopConfigPaths { @(Join-Path $t 'claude.json') }
    function Restart-ClaudeDesktopIfRunning { }
    $out = @(Register-DetectedAiClients $runtime -Clients @('Codex') 6>&1 | ForEach-Object { [string]$_ })
    Assert ((($script:registered) -join ',') -eq 'Codex') ('Unselected AI apps were registered: ' + ($script:registered -join ','))
    Assert (($out -join "`n") -match '\[RESULT\] claude_code=skipped not selected' -and ($out -join "`n") -match '\[RESULT\] claude_desktop=skipped not selected') ("Unselected apps not reported:`n" + ($out -join "`n"))
    'PASS: only the selected AI apps are connected; the others show as not selected'
}
finally { $env:LOCALAPPDATA = $saved.local; $env:APPDATA = $saved.roaming; Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
