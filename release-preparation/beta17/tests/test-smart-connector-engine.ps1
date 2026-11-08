$ErrorActionPreference = 'Stop'
# The install engine of SmartConnector.exe (`SmartConnector.exe engine --action ...`): the C# port of installer\Setup-BimCad.ps1.
# The program is compiled with the Windows compiler into an install-shaped folder and run as a child process against a
# temporary LOCALAPPDATA / APPDATA / USERPROFILE / CODEX_HOME, with fake `codex` and `claude` command lines first on PATH.
# Covered: Install with each AI app combination, the Claude Desktop config (compared with Register-ClaudeDesktopMcpServer),
# saved install choices, Codex registration that is already correct, the public release update (good and wrong checksum,
# no downgrade, Revit/AutoCAD open, a locked file, a failed replacement rolled back), the AutoCAD panel (compared with the
# PowerShell build), the Revit add-in build (with a stand-in compiler), enrollment and team join (DPAPI, secure delete),
# and the removal of what earlier versions left behind. Windows only.
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { 'SKIP: the install engine needs Windows'; return }
# The engine looks at the real process list. Running this test must never close or restart someone's apps.
foreach ($name in 'Claude', 'Revit', 'acad') {
    if (Get-Process -Name $name -ErrorAction SilentlyContinue) { "SKIP: close $name before running this test (it would be restarted or would defer the update)"; return }
}
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$t = Join-Path ([IO.Path]::GetTempPath()) ('connector-engine-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $t 'root'
$exe = Join-Path $root 'bin\SmartConnector.exe'
$system = Join-Path $env:SystemRoot 'System32'
$registryTrees = New-Object System.Collections.Generic.List[string]
$started = New-Object System.Collections.Generic.List[object]
$job = $null
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Join-Parts([string]$First, [string[]]$Rest) { $path = $First; foreach ($part in $Rest) { $path = Join-Path $path $part }; $path }
function Quote-Argument([string]$Value) { if ($Value -eq '' -or $Value -match '\s') { '"' + $Value + '"' } else { $Value } }

# One isolated user: its own LOCALAPPDATA, APPDATA, home, Codex home and fake-CLI folder.
function New-State([string]$Name) {
    $base = Join-Path $t $Name
    $state = @{
        Base = $base; Local = (Join-Path $base 'local'); Roaming = (Join-Path $base 'roaming'); Home = (Join-Path $base 'home')
        Codex = (Join-Path $base 'codex'); Fake = (Join-Path $base 'fake'); Programs = (Join-Path $base 'programs')
    }
    New-Item -ItemType Directory -Force $state.Local, $state.Roaming, $state.Home, $state.Codex, $state.Fake, $state.Programs | Out-Null
    $state
}

# Runs the engine and waits. $ExtraEnv overrides more variables for this one run (a $null value removes the variable).
function Invoke-Engine {
    param([string[]]$Arguments, [hashtable]$State, [string]$Path = $script:fakeBin, [hashtable]$ExtraEnv = @{}, [int]$TimeoutSeconds = 240, [string]$Program = $script:exe)
    # Unless a test says which AutoCAD releases exist, none do (HKLM cannot be faked, and a real AutoCAD must never be touched).
    if ($Arguments -notcontains '--test-autocad-releases') { $Arguments = @($Arguments) + @('--test-autocad-releases', '') }
    # Windows does not let a test change %ProgramFiles% for a child process (cmd.exe still sees the real one), so the
    # engine takes the folder as a hidden option as well.
    if ($Arguments -notcontains '--program-files') { $Arguments = @($Arguments) + @('--program-files', $State.Programs) }
    $line = (@('engine') + $Arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $info = New-Object Diagnostics.ProcessStartInfo($Program, $line)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8; $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $variables = @{
        LOCALAPPDATA = $State.Local; APPDATA = $State.Roaming; USERPROFILE = $State.Home; HOME = $State.Home; CODEX_HOME = $State.Codex
        ProgramFiles = $State.Programs; FAKE_CLI_DIR = $State.Fake; SMARTCONNECTOR_TEST_ALLOW_LOCAL_URLS = '1'
        PATH = ($Path + ';' + $system + ';' + $env:SystemRoot)
    }
    foreach ($key in $ExtraEnv.Keys) { $variables[$key] = $ExtraEnv[$key] }
    foreach ($key in $variables.Keys) {
        if ($null -eq $variables[$key]) { $null = $info.EnvironmentVariables.Remove($key) } else { $info.EnvironmentVariables[$key] = [string]$variables[$key] }
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); throw "SmartConnector.exe engine $($Arguments -join ' ') did not finish." }
        $process.WaitForExit()
        $text = $out.Result
        [pscustomobject]@{ Code = $process.ExitCode; Text = $text; Lines = @($text -split "`r?`n" | Where-Object { $_ }); Err = $err.Result }
    }
    finally { $process.Dispose() }
}
function Has-Line($Run, [string]$Pattern) { @($Run.Lines | Where-Object { $_ -match $Pattern }).Count -gt 0 }
function Show-Run($Run) { "exit $($Run.Code)`n" + $Run.Text + "`nstderr: " + $Run.Err }

function Get-Sha256Bytes([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '') } finally { $algorithm.Dispose() }
}
function Get-Sha256File([string]$Path) { Get-Sha256Bytes ([IO.File]::ReadAllBytes($Path)) }

# A zip with forward-slash entry names, like the release build writes them.
function New-TestZip([string]$Folder, [string]$Zip, [string]$Prefix) {
    if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
    $archive = [IO.Compression.ZipFile]::Open($Zip, 'Create')
    try {
        $length = (Resolve-Path -LiteralPath $Folder).Path.TrimEnd('\').Length
        foreach ($file in Get-ChildItem -LiteralPath $Folder -Recurse -File -Force) {
            $name = $Prefix + $file.FullName.Substring($length + 1).Replace('\', '/')
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $name, [IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $archive.Dispose() }
}

function Read-ZipEntries([string]$Zip) {
    $entries = @{}
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            $stream = $entry.Open(); $memory = New-Object IO.MemoryStream
            try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
            $entries[$entry.FullName] = $memory.ToArray()
        }
    }
    finally { $archive.Dispose() }
    $entries
}

function ConvertTo-PlainText([string]$Protected) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $Protected))
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

try {
    # ---------- 0. Build into an install-shaped folder ----------
    New-Item -ItemType Directory -Force (Join-Path $root 'bin') | Out-Null
    $null = & (Join-Path $PSScriptRoot '../setup/build-connector-exe.ps1') -OutputPath $exe
    Assert (Test-Path -LiteralPath $exe -PathType Leaf) 'SmartConnector.exe was not built'
    Copy-Item (Join-Path $runtime 'VERSION') $root
    foreach ($folder in 'assets', 'installer', 'scripts', 'src') { Copy-Item (Join-Path $runtime $folder) (Join-Path $root $folder) -Recurse }
    New-Item -ItemType Directory -Force (Join-Path $root '.agents') | Out-Null
    Copy-Item (Join-Path $runtime '.agents\skills') (Join-Path $root '.agents') -Recurse
    Set-Content -LiteralPath (Join-Path $root 'README.md') -Value 'installed readme' -Encoding ASCII
    Assert (-not (Test-Path (Join-Path $root 'installer\team-join.json'))) 'A team join code reached the test install'
    $version = (Get-Content (Join-Path $runtime 'VERSION') -Raw).Trim()

    # Fake `codex` and `claude` command lines: they log their arguments to %FAKE_CLI_DIR% and answer the way setup asks.
    # `mcp get <name>` succeeds when %FAKE_CLI_DIR%\<cli>-<name>.txt exists (its text is the answer); `mcp add` creates it.
    $fakeBin = Join-Path $t 'fakebin'
    New-Item -ItemType Directory -Force $fakeBin | Out-Null
    $codexCmd = @'
@echo off
echo %* >>"%FAKE_CLI_DIR%\codex.log"
if /i "%~1"=="mcp" if /i "%~2"=="get" goto get
if /i "%~1"=="mcp" if /i "%~2"=="add" goto add
if /i "%~1"=="mcp" if /i "%~2"=="remove" goto remove
exit /b 0
:get
if exist "%FAKE_CLI_DIR%\codex-%~3.txt" (
  type "%FAKE_CLI_DIR%\codex-%~3.txt"
  exit /b 0
)
echo no such server %~3 1>&2
exit /b 1
:add
if defined FAKE_CODEX_FAIL_ADD (
  echo the codex config is locked 1>&2
  exit /b 1
)
echo registered>"%FAKE_CLI_DIR%\codex-%~3.txt"
echo Added %~3
exit /b 0
:remove
del "%FAKE_CLI_DIR%\codex-%~3.txt" >nul 2>&1
echo Removed %~3
exit /b 0
'@
    $claudeCmd = @'
@echo off
echo %* >>"%FAKE_CLI_DIR%\claude.log"
if /i "%~1"=="mcp" if /i "%~2"=="get" goto get
if /i "%~1"=="mcp" if /i "%~2"=="add" goto add
if /i "%~1"=="mcp" if /i "%~2"=="remove" goto remove
exit /b 0
:get
if exist "%FAKE_CLI_DIR%\claude-%~3.txt" (
  type "%FAKE_CLI_DIR%\claude-%~3.txt"
  exit /b 0
)
echo no such server %~3 1>&2
exit /b 1
:add
echo registered>"%FAKE_CLI_DIR%\claude-%~7.txt"
echo Added %~7
exit /b 0
:remove
del "%FAKE_CLI_DIR%\claude-%~3.txt" >nul 2>&1
echo Removed %~3
exit /b 0
'@
    [IO.File]::WriteAllText((Join-Path $fakeBin 'codex.cmd'), $codexCmd, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $fakeBin 'claude.cmd'), $claudeCmd, [Text.Encoding]::ASCII)

    # The program is a Windows program: PowerShell neither waits for nor captures it, so everything goes through pipes.
    $run = Invoke-Engine -State (New-State 'version') -Path (Join-Path $t 'no-cli') -Arguments @('--action', 'Status', '--product', 'Revit')
    Assert ($run.Code -eq 0) ('engine Status failed: ' + (Show-Run $run))
    Assert ($run.Lines[0] -match '^\[\d\d:\d\d:\d\d\] Smart Connector - Status$') ('The first line is not the heading: ' + $run.Lines[0])
    Assert (Has-Line $run '^\[\d\d:\d\d:\d\d\] Revit 2024 was not detected\.$') (Show-Run $run)
    Assert (Has-Line $run 'Codex command was not detected\.') ('Codex should not be found with no CLI folder on PATH: ' + (Show-Run $run))
    $run = Invoke-Engine -State (New-State 'badaction') -Arguments @('--action', 'Nonsense')
    Assert ($run.Code -eq 1 -and $run.Err -match 'ValidateSet') ('An unknown action must stop with exit code 1: ' + (Show-Run $run))
    'PASS: the engine compiles with the Windows compiler, answers Status with the same lines, and refuses an unknown action'

    # ---------- 1. Install with every AI app ----------
    $s = New-State 'install-all'
    New-Item -ItemType Directory -Force (Join-Path $s.Local 'AnthropicClaude') | Out-Null
    [IO.File]::WriteAllText((Join-Path $s.Local 'AnthropicClaude\Claude.exe'), 'not a program')
    $roamingConfig = Join-Path $s.Roaming 'Claude\claude_desktop_config.json'
    $packageConfig = Join-Path $s.Local 'Packages\Claude_test\LocalCache\Roaming\Claude\claude_desktop_config.json'
    New-Item -ItemType Directory -Force (Split-Path $roamingConfig), (Split-Path $packageConfig) | Out-Null
    $original = '{"mcpServers":{"keep-me":{"command":"keep.exe","args":["a"]},"Revit Connector":{"command":"legacy.exe","args":[]},"autodesk":{"command":"old-combined.exe"},"Autodesk MCP Connector":{"command":"older-name.exe"}},"theme":"dark","count":3}'
    [IO.File]::WriteAllText($roamingConfig, $original)
    [IO.File]::WriteAllText($packageConfig, $original)
    # The same config, registered by Register-ClaudeDesktopMcpServer in Setup-BimCad.ps1 into its own copy.
    $referenceConfig = Join-Path $t 'reference\claude_desktop_config.json'
    New-Item -ItemType Directory -Force (Split-Path $referenceConfig) | Out-Null
    [IO.File]::WriteAllText($referenceConfig, $original)
    . (Join-Path $runtime 'installer\Setup-BimCad.ps1') -LibraryOnly
    function Write-Step { param([string]$Message) }
    $legacy = @('autocad', 'revit', 'AutoCAD MCP', 'Revit Connector', 'revit-mcp')
    Register-ClaudeDesktopMcpServer -Name 'Smart Connector' -Bridge $exe -BridgeArguments @('mcp') -LegacyNames ($legacy + 'autodesk' + 'Autodesk MCP Connector' + 'Smart Autodesk Connector') -ConfigPath $referenceConfig

    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off', '--auto-updates', 'On')
    Assert ($run.Code -eq 0) ('Install failed: ' + (Show-Run $run))
    foreach ($pattern in '^\[PHASE\] files$', '^\[RESULT\] files=ok$', '^\[PHASE\] skills$', '^\[RESULT\] skills=skipped not selected$', '^\[PHASE\] team$', '^\[PHASE\] revit$',
        '^\[RESULT\] revit=skipped Revit 2024 is not installed$', '^\[PHASE\] autocad$', '^\[RESULT\] autocad=skipped AutoCAD is not installed$', '^\[PHASE\] updates$', '^\[RESULT\] updates=ok$',
        '^\[RESULT\] codex=ok$', '^\[RESULT\] claude_code=ok$', '^\[RESULT\] claude_desktop=ok Claude restarts to load it$',
        '\] \[ENROLLMENT_PENDING\] ', '\] Setup complete\. Restart Codex, Claude, and any running Revit session, then open AutoCAD or Revit\.$',
        '\] Codex has the Smart Connector registration\.$', '\] Claude Code has the Smart Connector registration\.$', 'Claude Desktop has the Smart Connector registration at ') {
        Assert (Has-Line $run $pattern) ("Install did not print a line matching $pattern`n" + (Show-Run $run))
    }
    Assert (-not (Has-Line $run '^\[RESULT\] \w+=failed')) ('A step failed: ' + (Show-Run $run))
    $order = @($run.Lines | Where-Object { $_ -match '^\[PHASE\] ' })
    Assert (($order -join ',') -eq '[PHASE] files,[PHASE] skills,[PHASE] team,[PHASE] revit,[PHASE] autocad,[PHASE] autocad,[PHASE] updates,[PHASE] codex,[PHASE] codex,[PHASE] claude_code,[PHASE] claude_desktop') ('Phases differ from Setup-BimCad.ps1: ' + ($order -join ','))
    $codexLog = (Get-Content (Join-Path $s.Fake 'codex.log') -Raw).Replace('"', '')
    Assert ($codexLog.Contains("mcp add autodesk -- $exe mcp")) "Codex was not registered with the program: $codexLog"
    $claudeLog = (Get-Content (Join-Path $s.Fake 'claude.log') -Raw).Replace('"', '')
    Assert ($claudeLog.Contains("mcp add --transport stdio --scope user autodesk -- $exe mcp")) "Claude Code was not registered with the program: $claudeLog"
    # Claude Desktop: both config files hold exactly what the PowerShell function writes, without a byte-order mark.
    $referenceJson = (Get-Content $referenceConfig -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 30 -Compress)
    foreach ($config in $roamingConfig, $packageConfig) {
        $bytes = [IO.File]::ReadAllBytes($config)
        Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) "Config has a byte-order mark: $config"
        $parsed = Get-Content $config -Raw | ConvertFrom-Json
        Assert ($parsed.mcpServers.'Smart Connector'.command -eq $exe -and (@($parsed.mcpServers.'Smart Connector'.args) -join ',') -eq 'mcp') 'The Smart Connector entry is wrong'
        Assert ($parsed.mcpServers.'keep-me'.command -eq 'keep.exe' -and $parsed.theme -eq 'dark' -and $parsed.count -eq 3) 'Unrelated servers or settings were not preserved'
        foreach ($gone in 'Revit Connector', 'autodesk', 'Autodesk MCP Connector') { Assert (-not $parsed.mcpServers.PSObject.Properties[$gone]) "Legacy entry $gone was not removed" }
        Assert (($parsed | ConvertTo-Json -Depth 30 -Compress) -eq $referenceJson) "The config differs from what Register-ClaudeDesktopMcpServer writes:`n$($parsed | ConvertTo-Json -Depth 30 -Compress)`n$referenceJson"
    }
    # Start menu entry, install choices and update state.
    $lnk = Join-Path $s.Roaming 'Microsoft\Windows\Start Menu\Programs\Smart Connector.lnk'
    Assert (Test-Path $lnk) 'The Start menu entry was not created'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    Assert ($shortcut.TargetPath -eq $exe -and $shortcut.Arguments -eq 'app') 'The Start menu entry does not open the program'
    $updateState = Get-Content (Join-Path $s.Local 'AutodeskMcpConnector\update-state.json') -Raw | ConvertFrom-Json
    Assert ($updateState.installed_version -eq $version -and $updateState.notifications_enabled -eq $true -and $updateState.notifications_user_disabled -eq $false) 'update-state.json is wrong'
    # Run again: everything is already right; Codex is left alone.
    $before = (Get-Content (Join-Path $s.Fake 'codex.log') -Raw)
    $codexJson = @{ name = 'autodesk'; enabled = $true; transport = @{ type = 'stdio'; command = $exe; args = @('mcp') } } | ConvertTo-Json -Depth 5 -Compress
    [IO.File]::WriteAllText((Join-Path $s.Fake 'codex-autodesk.txt'), $codexJson)
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off')
    Assert ($run.Code -eq 0 -and (Has-Line $run 'The Smart Connector registration in Codex is already correct\.') -and (Has-Line $run 'Smart Connector is in the Start menu\.')) ('Second install: ' + (Show-Run $run))
    $after = (Get-Content (Join-Path $s.Fake 'codex.log') -Raw).Substring($before.Length).Replace('"', '')
    Assert ($after -notmatch 'mcp add' -and $after -notmatch 'mcp remove autodesk') "A correct Codex registration was rewritten: $after"
    'PASS: Install runs every step with the same phases and results; Codex, Claude Code and both Claude Desktop configs match the PowerShell output (no BOM, other servers kept, legacy entries gone)'

    # A malformed config is left as it is, the others are still done, and setup reports it.
    $s = New-State 'install-malformed'
    New-Item -ItemType Directory -Force (Join-Path $s.Local 'AnthropicClaude') | Out-Null
    [IO.File]::WriteAllText((Join-Path $s.Local 'AnthropicClaude\Claude.exe'), 'x')
    $roamingConfig = Join-Path $s.Roaming 'Claude\claude_desktop_config.json'
    $packageConfig = Join-Path $s.Local 'Packages\Claude_test\LocalCache\Roaming\Claude\claude_desktop_config.json'
    New-Item -ItemType Directory -Force (Split-Path $roamingConfig), (Split-Path $packageConfig) | Out-Null
    [IO.File]::WriteAllText($roamingConfig, '{invalid json')
    [IO.File]::WriteAllText($packageConfig, '{"mcpServers":{"keep":{"command":"keep.exe"}}}')
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off')
    Assert ($run.Code -eq 1 -and $run.Err -match 'Setup finished, but these steps failed: claude_desktop') ('A malformed config must fail the step: ' + (Show-Run $run))
    Assert (Has-Line $run 'Claude Desktop at .*claude_desktop_config\.json: Claude Desktop registration failed') (Show-Run $run)
    Assert ([IO.File]::ReadAllText($roamingConfig) -eq '{invalid json') 'The malformed config was changed'
    $other = Get-Content $packageConfig -Raw | ConvertFrom-Json
    Assert ($other.mcpServers.'Smart Connector' -and $other.mcpServers.keep) 'The other config path was not updated'
    Assert ((Has-Line $run '^\[RESULT\] codex=ok$') -and (Has-Line $run '^\[RESULT\] claude_code=ok$')) 'The other clients were not registered'
    Assert ((Test-Path (Join-Path $s.Local 'AutodeskMcpConnector\install-choices.json'))) 'The choices were not saved'
    'PASS: a malformed Claude Desktop config is left untouched, the other path and the other clients are still done, and the failed step is reported'

    # A failing Codex registration does not stop Claude; the reason is reported and the exit code is 1.
    $s = New-State 'install-codex-fails'
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off', '--ai-clients', 'Codex,ClaudeCode') -ExtraEnv @{ FAKE_CODEX_FAIL_ADD = '1' }
    Assert ($run.Code -eq 1) ('Setup must exit 1 when a registration fails: ' + (Show-Run $run))
    Assert ((Has-Line $run '^\[RESULT\] codex=failed see the setup log$') -and (Has-Line $run '^\[RESULT\] claude_code=ok$')) ('Claude Code must still be registered: ' + (Show-Run $run))
    Assert ((Has-Line $run '^WARNING: Codex registration failed; continuing with other clients: ') -and (Has-Line $run 'Codex: ')) ('The Codex failure was not reported: ' + (Show-Run $run))
    Assert (-not (Test-Path (Join-Path $s.Fake 'codex-autodesk.txt'))) 'A failed registration left an entry'
    'PASS: a Codex failure is reported, Claude Code is still registered, and setup exits with an error'

    # ---------- 2. Install choices ----------
    $s = New-State 'choices'
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--ai-clients', 'claudecode, Codex', '--product', 'Revit', '--skills', 'Off', '--auto-updates', 'Off')
    Assert ($run.Code -eq 0) ('Install with choices failed: ' + (Show-Run $run))
    Assert (Has-Line $run 'Setting up: Revit; AI apps: ClaudeCode, Codex; team skills: no\.') (Show-Run $run)
    Assert ((Has-Line $run '^\[RESULT\] claude_desktop=skipped not selected$') -and -not (Has-Line $run '^\[PHASE\] autocad$') -and (Has-Line $run '^\[RESULT\] updates=skipped switched off in setup$')) ('Choices not applied: ' + (Show-Run $run))
    $saved = Get-Content (Join-Path $s.Local 'AutodeskMcpConnector\install-choices.json') -Raw | ConvertFrom-Json
    Assert ((@($saved.ai_clients) -join ',') -eq 'ClaudeCode,Codex' -and $saved.product -eq 'Revit' -and $saved.skills -eq $false -and $saved.saved_utc) 'install-choices.json is wrong'
    $state = Get-Content (Join-Path $s.Local 'AutodeskMcpConnector\update-state.json') -Raw | ConvertFrom-Json
    Assert ($state.notifications_enabled -eq $false -and $state.notifications_user_disabled -eq $true) 'Switching updates off in setup was not recorded'
    # Repair reuses them; a new choice replaces only what was given; the person's "off" is kept without a new choice.
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root)
    Assert ((Has-Line $run 'Setting up: Revit; AI apps: ClaudeCode, Codex; team skills: no\.') -and (Has-Line $run '^\[RESULT\] updates=skipped switched off in Settings$')) ('Saved choices not reused: ' + (Show-Run $run))
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--product', 'All')
    Assert (Has-Line $run 'Setting up: Revit and AutoCAD; AI apps: ClaudeCode, Codex; team skills: no\.') (Show-Run $run)
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--ai-clients', 'Copilot')
    Assert ($run.Code -eq 1 -and $run.Err -match 'Unknown AI app: Copilot') ('Unknown AI apps must be refused: ' + (Show-Run $run))
    # Update checks can be switched on and off from the app.
    $run = Invoke-Engine -State $s -Arguments @('--action', 'EnableNotifications', '--repository-path', $root)
    Assert ($run.Code -eq 0 -and (Has-Line $run 'Update checks are on:')) (Show-Run $run)
    Assert ((Get-Content (Join-Path $s.Local 'AutodeskMcpConnector\update-state.json') -Raw | ConvertFrom-Json).notifications_user_disabled -eq $false) 'EnableNotifications did not record the choice'
    $run = Invoke-Engine -State $s -Arguments @('--action', 'DisableNotifications', '--repository-path', $root)
    Assert ($run.Code -eq 0 -and (Has-Line $run 'Update checks are off\.') -and (Get-Content (Join-Path $s.Local 'AutodeskMcpConnector\update-state.json') -Raw | ConvertFrom-Json).notifications_user_disabled -eq $true) (Show-Run $run)
    'PASS: choices are saved, reused by Repair, replaced only where given, validated; update checks switch on and off'

    # Skills On runs the shipped skill installer for Codex and Claude Code (the skill scripts stay PowerShell).
    $s = New-State 'skills'
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--ai-clients', 'Codex', '--product', 'Revit', '--skills', 'On')
    Assert ($run.Code -eq 0 -and (Has-Line $run '^\[RESULT\] skills=ok$')) ('Install with skills failed: ' + (Show-Run $run))
    Assert (@(Get-ChildItem (Join-Path $s.Codex 'skills') -Directory).Count -ge 30 -and @(Get-ChildItem (Join-Path $s.Home '.claude\skills') -Directory).Count -ge 30) 'The skills were not installed for Codex and Claude Code'
    'PASS: the team skills are installed for Codex and Claude Code'

    # ---------- 3. Codex that is already correct ----------
    $s = New-State 'codex-correct'
    $codexJson = @{ name = 'autodesk'; enabled = $true; transport = @{ type = 'stdio'; command = $exe; args = @('mcp') } } | ConvertTo-Json -Depth 5 -Compress
    [IO.File]::WriteAllText((Join-Path $s.Fake 'codex-autodesk.txt'), $codexJson)
    [IO.File]::WriteAllText((Join-Path $s.Fake 'codex-AutoCAD MCP.txt'), "AutoCAD MCP`n  command: powershell.exe -File C:\Users\x\AppData\Local\BIM-CAD-MCP\src\autocad\autocad-bridge.ps1")
    [IO.File]::WriteAllText((Join-Path $s.Fake 'codex-revit-mcp.txt'), "revit-mcp`n  command: npx -y someone-elses-revit-server")
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'Revit')
    $log = (Get-Content (Join-Path $s.Fake 'codex.log') -Raw).Replace('"', '')
    Assert ($run.Code -eq 0 -and (Has-Line $run 'The Smart Connector registration in Codex is already correct\.')) ('Correct registration not recognised: ' + (Show-Run $run))
    Assert ($log -notmatch 'mcp add') 'A correct registration was rewritten'
    Assert ($log -match 'mcp remove AutoCAD MCP' -and (Has-Line $run "Removed the older duplicate Codex MCP entry 'AutoCAD MCP'\.")) 'The older duplicate entry was not removed'
    Assert ($log -notmatch 'mcp remove revit-mcp' -and (Test-Path (Join-Path $s.Fake 'codex-revit-mcp.txt'))) 'Another tool''s server was removed'
    # A different command is replaced without touching other servers.
    [IO.File]::WriteAllText((Join-Path $s.Fake 'codex-autodesk.txt'), (@{ name = 'autodesk'; enabled = $true; transport = @{ type = 'stdio'; command = 'old.exe'; args = @('x') } } | ConvertTo-Json -Depth 5 -Compress))
    Remove-Item (Join-Path $s.Fake 'codex.log')
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'Revit')
    Assert ((Get-Content (Join-Path $s.Fake 'codex.log') -Raw).Replace('"', '').Contains("mcp add autodesk -- $exe mcp")) ('A wrong registration was not repaired: ' + (Show-Run $run))
    'PASS: a correct Codex registration is left alone, an older duplicate is removed, another tool''s server is kept, a wrong registration is replaced'

    # ---------- 4. Public release update ----------
    # A release: the installed files with a newer VERSION, a changed README, a new file, a file gone, and a different program.
    $releaseRoot = Join-Path $t 'release'
    function New-Release([string]$Name, [string]$ReleaseVersion, [switch]$WrongChecksum, [switch]$Collide) {
        $folder = Join-Path $releaseRoot $Name
        $stage = Join-Path $folder 'stage\Autodesk-MCP-Payload'
        New-Item -ItemType Directory -Force $stage | Out-Null
        foreach ($entry in 'assets', 'installer', 'scripts', 'src', '.agents', 'bin') { Copy-Item (Join-Path $root $entry) $stage -Recurse }
        [IO.File]::WriteAllText((Join-Path $stage 'VERSION'), $ReleaseVersion + "`n")
        [IO.File]::WriteAllText((Join-Path $stage 'README.md'), 'updated readme ' + $ReleaseVersion)
        [IO.File]::WriteAllText((Join-Path $stage 'scripts\new-in-release.ps1'), '# new')
        # A skill that this release no longer ships, and a file only older installs have.
        Remove-Item (Join-Path $stage '.agents\skills\uncategorized\squeeze') -Recurse -Force
        # A different program: the same one with one more byte, so the running exe has to be replaced.
        $stream = [IO.File]::Open((Join-Path $stage 'bin\SmartConnector.exe'), 'Append'); $stream.WriteByte(0); $stream.Close()
        if ($Collide) { New-Item -ItemType Directory -Force (Join-Path $stage 'zzz') | Out-Null; [IO.File]::WriteAllText((Join-Path $stage 'zzz\child.txt'), 'x') }
        $payload = Join-Path $folder 'Autodesk-MCP-Payload.zip'
        New-TestZip (Split-Path $stage -Parent) $payload ''
        $outer = Join-Path $folder 'outer'
        New-Item -ItemType Directory -Force (Join-Path $outer "Autodesk-MCP-Connector-$ReleaseVersion\Support") | Out-Null
        Copy-Item $payload (Join-Path $outer "Autodesk-MCP-Connector-$ReleaseVersion\Support\Autodesk-MCP-Payload.zip")
        $zip = Join-Path $folder "release-$Name.zip"
        New-TestZip $outer $zip ''
        $sha = if ($WrongChecksum) { '0' * 64 } else { Get-Sha256File $zip }
        [pscustomobject]@{ Folder = $folder; Zip = $zip; Sha = $sha; Version = $ReleaseVersion; Name = "release-$Name.zip"; Exe = (Get-Item (Join-Path $stage 'bin\SmartConnector.exe')).Length }
    }
    # latest.json for a release, with download_url under $BaseUrl (a file: address or the local HTTP listener).
    function Write-Manifest($Release, [string]$BaseUrl, [string]$Name = 'latest.json') {
        $url = if ($BaseUrl) { $BaseUrl + '/' + $Release.Name } else { ([Uri]$Release.Zip).AbsoluteUri }
        $manifest = @{ schema_version = 1; version = ' v' + $Release.Version + ' '; download_url = $url; sha256 = ' ' + $Release.Sha.ToLowerInvariant() + ' ' } | ConvertTo-Json
        $path = Join-Path $Release.Folder $Name
        [IO.File]::WriteAllText($path, $manifest, (New-Object Text.UTF8Encoding($true)))
        $path
    }

    # A local web server for latest.json, the release zip and the team service (skipped when the machine does not allow it).
    $port = $null
    $tcp = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $tcp.Start(); $freePort = $tcp.LocalEndpoint.Port; $tcp.Stop()
    $serve = Join-Path $t 'serve'
    New-Item -ItemType Directory -Force $serve | Out-Null
    $job = Start-Job -ArgumentList $freePort, $serve -ScriptBlock {
        param($listenPort, $folder)
        $listener = New-Object Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$listenPort/")
        $listener.Start()
        while ($true) {
            $context = $listener.GetContext()
            $request = $context.Request; $response = $context.Response
            try {
                if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/v1/enroll') {
                    $reader = New-Object IO.StreamReader($request.InputStream, [Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd()
                    [IO.File]::WriteAllText((Join-Path $folder 'enroll-request.json'), (@{ authorization = $request.Headers['Authorization']; version = $request.Headers['X-Connector-Version']; agent = $request.UserAgent; body = $body } | ConvertTo-Json))
                    $expected = [IO.File]::ReadAllText((Join-Path $folder 'join-code.txt')).Trim()
                    if ($request.Headers['Authorization'] -ne ('Bearer ' + $expected)) { $response.StatusCode = 403; $bytes = [Text.Encoding]::UTF8.GetBytes('{"detail":"bad code"}') }
                    else { $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $folder 'device.json'))) }
                    $response.ContentLength64 = $bytes.Length; $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else {
                    $file = Join-Path $folder $request.Url.AbsolutePath.TrimStart('/')
                    if (Test-Path -LiteralPath $file -PathType Leaf) { $bytes = [IO.File]::ReadAllBytes($file); $response.ContentLength64 = $bytes.Length; $response.OutputStream.Write($bytes, 0, $bytes.Length) }
                    else { $response.StatusCode = 404 }
                }
            }
            catch { $response.StatusCode = 500 }
            finally { $response.Close() }
        }
    }
    for ($wait = 0; $wait -lt 100 -and -not $port; $wait++) {
        Start-Sleep -Milliseconds 100
        if ($job.State -eq 'Failed') { break }
        try { $null = (New-Object Net.WebClient).DownloadString("http://127.0.0.1:$freePort/probe"); $port = $freePort } catch [Net.WebException] { if ($_.Exception.Response) { $port = $freePort } } catch { }
    }
    $http = if ($port) { "http://127.0.0.1:$port" } else { $null }
    if (-not $http) { 'NOTE: the local web server could not start here; the update and team join tests use file: addresses only' }

    $good = New-Release 'good' '9.9.0'
    $wrong = New-Release 'wrong' '9.9.0' -WrongChecksum
    $older = New-Release 'older' '0.0.1'
    foreach ($release in $good, $wrong, $older) { Copy-Item $release.Zip $serve }
    $goodFile = ([Uri](Write-Manifest $good $null 'latest-file.json')).AbsoluteUri
    if ($http) {
        $null = Write-Manifest $good $http 'latest.json'
        Copy-Item (Join-Path $good.Folder 'latest.json') (Join-Path $serve 'latest.json')
        $httpGood = "$http/latest.json"
    }
    else { $httpGood = $goodFile }
    $wrongManifest = ([Uri](Write-Manifest $wrong $null)).AbsoluteUri
    $olderManifest = ([Uri](Write-Manifest $older $null)).AbsoluteUri

    # A fresh install of the current version for the update tests.
    function New-InstalledCopy([string]$Name) {
        $copy = Join-Path $t $Name
        New-Item -ItemType Directory -Force $copy | Out-Null
        Copy-Item (Join-Path $root '*') $copy -Recurse -Force
        foreach ($folder in 'skill-review', 'team-candidates', 'team-collection', 'backups') {
            New-Item -ItemType Directory -Force (Join-Path $copy $folder) | Out-Null
            Set-Content -LiteralPath (Join-Path $copy "$folder\preserve.txt") -Value $folder -Encoding ASCII
        }
        # Something only an earlier version shipped.
        Set-Content -LiteralPath (Join-Path $copy 'scripts\only-in-old-version.ps1') -Value '# gone in the new release' -Encoding ASCII
        $copy
    }

    # CheckUpdate: reads latest.json (UTF-8 with a byte-order mark, spaces and a "v" around the values) and records it.
    $s = New-State 'check'
    $installed = New-InstalledCopy 'install-check'
    $installedExe = Join-Path $installed 'bin\SmartConnector.exe'
    $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'CheckUpdate', '--repository-path', $installed, '--release-manifest-url', $httpGood)
    Assert ($run.Code -eq 0 -and (Has-Line $run '\[UPDATE_AVAILABLE\] Version 9\.9\.0 is available\.')) ('CheckUpdate: ' + (Show-Run $run))
    $state = Get-Content (Join-Path $s.Local 'AutodeskMcpConnector\update-state.json') -Raw | ConvertFrom-Json
    Assert ($state.available_version -eq '9.9.0' -and $state.installed_version -eq $version -and $state.last_checked_utc) 'update-state.json was not updated by the check'
    $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'CheckUpdate', '--repository-path', $installed, '--release-manifest-url', $olderManifest)
    Assert ($run.Code -eq 0 -and (Has-Line $run '\[UP_TO_DATE\] Installed version .* is newer than public version 0\.0\.1; no downgrade will be performed\.')) ('CheckUpdate with an older release: ' + (Show-Run $run))
    $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'CheckUpdate', '--repository-path', $installed, '--release-manifest-url', 'http://example.invalid/latest.json')
    Assert ($run.Code -eq 1 -and $run.Err -match 'must use HTTPS') ('A manifest that is not HTTPS must be refused: ' + (Show-Run $run))
    'PASS: CheckUpdate reads the manifest, records the available version, reports older releases and refuses a manifest that is not HTTPS'

    # Update: wrong checksum changes nothing.
    $s = New-State 'update-wrong'
    $installed = New-InstalledCopy 'install-wrong'
    $installedExe = Join-Path $installed 'bin\SmartConnector.exe'
    $exeLength = (Get-Item $installedExe).Length
    $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'Update', '--repository-path', $installed, '--release-manifest-url', $wrongManifest, '--skills', 'Off')
    Assert ($run.Code -eq 1 -and $run.Err -match 'Release checksum verification failed\. Expected 0{64}') ('A wrong checksum must stop the update: ' + (Show-Run $run))
    Assert ((Get-Content (Join-Path $installed 'VERSION') -Raw).Trim() -eq $version -and (Get-Item $installedExe).Length -eq $exeLength -and (Get-Content (Join-Path $installed 'README.md') -Raw).Trim() -eq 'installed readme') 'A rejected release changed the installed files'
    # No downgrade.
    $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'Update', '--repository-path', $installed, '--release-manifest-url', $olderManifest, '--skills', 'Off')
    Assert ($run.Code -eq 0 -and (Has-Line $run 'is newer than public version 0\.0\.1; the update was skipped to prevent a downgrade\.') -and (Has-Line $run 'No newer release was installed\.')) ('Downgrade: ' + (Show-Run $run))
    Assert ((Get-Content (Join-Path $installed 'VERSION') -Raw).Trim() -eq $version) 'The updater downgraded the installation'
    'PASS: a release with a wrong checksum is rejected without changing anything, and an older release is never installed'

    # Revit or AutoCAD open: the update waits.
    $fakeApps = Join-Path $t 'apps'
    New-Item -ItemType Directory -Force $fakeApps | Out-Null
    foreach ($app in 'Revit', 'acad') {
        Copy-Item (Join-Path $system 'ping.exe') (Join-Path $fakeApps "$app.exe")
        $started.Add((Start-Process -FilePath (Join-Path $fakeApps "$app.exe") -ArgumentList '-n 120 127.0.0.1' -WindowStyle Hidden -PassThru))
    }
    Start-Sleep -Milliseconds 500
    $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'Update', '--repository-path', $installed, '--release-manifest-url', $httpGood, '--skills', 'Off')
    Assert ($run.Code -eq 0 -and (Has-Line $run '\[UPDATE_DEFERRED\] AutoCAD and Revit is open\. Close it, and the update window installs the update\.')) ('Open apps did not defer the update: ' + (Show-Run $run))
    Assert ((Get-Content (Join-Path $installed 'VERSION') -Raw).Trim() -eq $version) 'A deferred update changed files'
    foreach ($process in $started) { try { $process.Kill() } catch { } }
    $started.Clear()
    Start-Sleep -Milliseconds 500
    'PASS: with Revit or AutoCAD open the update prints [UPDATE_DEFERRED] and changes nothing'

    # A failed replacement is rolled back: one file cannot be replaced (it is open without sharing), so what was already replaced
    # (including the running program) is put back. The update starts from a payload with a file inside a file's place.
    $s = New-State 'update-rollback'
    $installed = New-InstalledCopy 'install-rollback'
    $installedExe = Join-Path $installed 'bin\SmartConnector.exe'
    $exeLength = (Get-Item $installedExe).Length
    $collide = New-Release 'collide' '9.9.0' -Collide
    $collideManifest = ([Uri](Write-Manifest $collide $null)).AbsoluteUri
    [IO.File]::WriteAllText((Join-Path $installed 'zzz'), 'a file where the release wants a folder')
    $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'Update', '--repository-path', $installed, '--release-manifest-url', $collideManifest, '--skills', 'Off')
    Assert ($run.Code -eq 1) ('An update that cannot replace a file must fail: ' + (Show-Run $run))
    Assert ((Get-Content (Join-Path $installed 'VERSION') -Raw).Trim() -eq $version -and (Get-Item $installedExe).Length -eq $exeLength -and (Get-Content (Join-Path $installed 'README.md') -Raw).Trim() -eq 'installed readme') 'The failed update was not rolled back'
    Assert ((Test-Path (Join-Path $installed 'scripts\only-in-old-version.ps1')) -and -not (Test-Path (Join-Path $installed 'scripts\new-in-release.ps1')) -and (Get-Content (Join-Path $installed 'zzz') -Raw) -match 'a file where') 'Files were left half-replaced'
    Assert (@(Get-ChildItem -LiteralPath $installed -Recurse -Force -Filter '*.old*').Count -eq 0) 'Renamed files were not put back'
    # The same, by a file that is held open without sharing.
    $s = New-State 'update-locked'
    $installed = New-InstalledCopy 'install-locked'
    $installedExe = Join-Path $installed 'bin\SmartConnector.exe'
    $exeLength = (Get-Item $installedExe).Length
    $lock = [IO.File]::Open((Join-Path $installed 'VERSION'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'Update', '--repository-path', $installed, '--release-manifest-url', $httpGood, '--skills', 'Off') }
    finally { $lock.Dispose() }
    Assert ($run.Code -eq 1) ('A file that cannot be moved aside must fail the update: ' + (Show-Run $run))
    Assert ((Get-Content (Join-Path $installed 'VERSION') -Raw).Trim() -eq $version -and (Get-Item $installedExe).Length -eq $exeLength -and (Get-Content (Join-Path $installed 'README.md') -Raw).Trim() -eq 'installed readme') 'The update with a locked file was not rolled back'
    Assert (@(Get-ChildItem -LiteralPath $installed -Recurse -Force -Filter '*.old*').Count -eq 0) 'Renamed files were left behind after the rollback'
    'PASS: when a file cannot be replaced, everything that was replaced or renamed aside (the running program included) is put back'

    # The update itself, in place: the running program replaces itself, other copies of it stop, preserved folders stay, the shipped
    # library is replaced (a skill the release no longer has is gone), a file held open with sharing is renamed aside.
    $s = New-State 'update-good'
    New-Item -ItemType Directory -Force (Join-Path $s.Local 'AnthropicClaude') | Out-Null
    $installed = New-InstalledCopy 'install-good'
    $installedExe = Join-Path $installed 'bin\SmartConnector.exe'
    # An MCP server that Claude or Codex started from this install: the update stops it. Another install's copy keeps running.
    $serverInfo = New-Object Diagnostics.ProcessStartInfo($installedExe, 'mcp')
    $serverInfo.UseShellExecute = $false; $serverInfo.RedirectStandardInput = $true; $serverInfo.RedirectStandardOutput = $true; $serverInfo.CreateNoWindow = $true
    $server = [Diagnostics.Process]::Start($serverInfo)
    $started.Add($server)
    $elsewhere = New-InstalledCopy 'install-elsewhere'
    $otherInfo = New-Object Diagnostics.ProcessStartInfo((Join-Path $elsewhere 'bin\SmartConnector.exe'), 'mcp')
    $otherInfo.UseShellExecute = $false; $otherInfo.RedirectStandardInput = $true; $otherInfo.RedirectStandardOutput = $true; $otherInfo.CreateNoWindow = $true
    $other = [Diagnostics.Process]::Start($otherInfo)
    $started.Add($other)
    $shared = [IO.File]::Open((Join-Path $installed 'scripts\only-in-old-version.ps1'), [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]'ReadWrite,Delete'))
    Set-Content -LiteralPath (Join-Path $installed '.agents\skills\old-flat-leftover.txt') -Value 'only in the old library' -Encoding ASCII
    try {
        $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'Update', '--repository-path', $installed, '--release-manifest-url', $httpGood, '--skills', 'Off', '--ai-clients', 'Codex,ClaudeCode')
    }
    finally { $shared.Dispose() }
    Assert ($run.Code -eq 0) ('Update failed: ' + (Show-Run $run))
    Assert (Has-Line $run 'Release checksum verification passed\.') (Show-Run $run)
    Assert (Has-Line $run '\[UPDATE_INSTALLED\] Smart Connector 9\.9\.0 is installed\.') ('No [UPDATE_INSTALLED] line: ' + (Show-Run $run))
    Assert ((Get-Content (Join-Path $installed 'VERSION') -Raw).Trim() -eq '9.9.0' -and (Get-Content (Join-Path $installed 'README.md') -Raw) -eq 'updated readme 9.9.0') 'The files were not replaced'
    Assert ((Test-Path (Join-Path $installed 'scripts\new-in-release.ps1')) -and -not (Test-Path (Join-Path $installed 'scripts\only-in-old-version.ps1'))) 'A file new in the release is missing, or a file the release no longer has stayed'
    Assert ((Get-Item $installedExe).Length -eq $good.Exe) 'The running program was not replaced'
    Assert (-not (Test-Path (Join-Path $installed '.agents\skills\uncategorized\squeeze')) -and -not (Test-Path (Join-Path $installed '.agents\skills\old-flat-leftover.txt'))) 'The shipped skill library was merged, not replaced'
    foreach ($folder in 'skill-review', 'team-candidates', 'team-collection', 'backups') { Assert ((Get-Content (Join-Path $installed "$folder\preserve.txt") -Raw).Trim() -eq $folder) "$folder was not preserved" }
    $source = Get-Content (Join-Path $installed '.bim-cad-source.json') -Raw | ConvertFrom-Json
    Assert ($source.method -eq 'public-release' -and $source.version -eq '9.9.0' -and $source.sha256 -eq $good.Sha) '.bim-cad-source.json is wrong'
    $state = Get-Content (Join-Path $s.Local 'AutodeskMcpConnector\update-state.json') -Raw | ConvertFrom-Json
    Assert ($state.installed_version -eq '9.9.0' -and $state.installed_sha256 -eq $good.Sha) 'update-state.json does not hold the installed release and its SHA-256'
    Assert ($server.WaitForExit(10000)) 'The MCP server of this install was not stopped'
    Assert (-not $other.HasExited) 'A SmartConnector.exe of another install was stopped'
    # The AI apps were pointed at the new program.
    Assert ((Get-Content (Join-Path $s.Fake 'codex.log') -Raw).Replace('"', '').Contains("mcp add autodesk -- $installedExe mcp")) 'Codex was not registered again after the update'
    # The old program (the engine's own exe while it ran) was renamed aside and could not be deleted while running; the next start of any command removes it.
    $recorded = Join-Path $s.Local 'AutodeskMcpConnector\old-files.txt'
    Assert ((Test-Path (Join-Path $installed 'bin\SmartConnector.exe.old')) -and (Test-Path $recorded)) 'The running program was not set aside as SmartConnector.exe.old'
    $other.Kill(); $started.Clear()
    $run = Invoke-Engine -State $s -Program $installedExe -Arguments @('--action', 'Status', '--product', 'Revit', '--repository-path', $installed)
    Assert ($run.Code -eq 0) ('The updated program does not start: ' + (Show-Run $run))
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $installed 'bin') -Filter '*.old*').Count -eq 0) 'The renamed program was not deleted at the next start'
    Assert (-not (Test-Path $recorded)) 'The list of files to delete was not cleared'
    'PASS: update from a local release: files replaced in place (running program included), MCP servers of this install stopped, preserved folders kept, skill library replaced, old files deleted at the next start'

    # Installing a package into a permanent folder (the ZIP installer): the program is not copied anywhere else to run.
    $s = New-State 'package'
    $package = New-InstalledCopy 'package-source'
    Remove-Item (Join-Path $package 'scripts\only-in-old-version.ps1')
    $destination = Join-Path $t 'package-dest'
    foreach ($folder in '.agents\skills\old-flat-skill', 'bin', 'skill-review') { New-Item -ItemType Directory -Force (Join-Path $destination $folder) | Out-Null }
    Set-Content (Join-Path $destination '.agents\skills\old-flat-skill\SKILL.md') 'old' -Encoding ASCII
    Set-Content (Join-Path $destination 'skill-review\keep.txt') 'keep' -Encoding ASCII
    Set-Content (Join-Path $destination 'VERSION') '0.0.1' -Encoding ASCII
    Copy-Item (Join-Path $package 'bin\SmartConnector.exe') (Join-Path $destination 'bin\SmartConnector.exe')
    New-Item -ItemType Directory -Force (Join-Path $package 'installer') | Out-Null
    [IO.File]::WriteAllText((Join-Path $package 'installer\team-join.json'), '{"service_url":"https://skills.example.test","join_code":"must-not-be-copied-to-the-install-0123456789"}')
    $run = Invoke-Engine -State $s -Program (Join-Path $package 'bin\SmartConnector.exe') -Arguments @('--action', 'Install', '--repository-path', $destination, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'Revit')
    Assert ($run.Code -eq 0 -and (Has-Line $run 'Installing the downloaded package to a permanent local folder\.\.\.')) ('Package install: ' + (Show-Run $run))
    Assert ((Get-Content (Join-Path $destination 'VERSION') -Raw).Trim() -eq $version -and (Test-Path (Join-Path $destination 'bin\SmartConnector.exe')) -and (Test-Path (Join-Path $destination 'installer\Setup-BimCad.ps1'))) 'The package was not copied'
    Assert (-not (Test-Path (Join-Path $destination '.agents\skills\old-flat-skill')) -and (Test-Path (Join-Path $destination '.agents\skills\README.md'))) 'The shipped skill library was merged, not replaced'
    Assert ((Test-Path (Join-Path $destination 'skill-review\keep.txt')) -and -not (Test-Path (Join-Path $destination 'installer\team-join.json'))) 'A preserved folder was lost, or the team join code was copied into the install'
    $inner = $run.Text + (Get-Content (Join-Path $s.Local 'AutodeskMcpConnector\update-state.json') -Raw)
    Assert (-not $inner.Contains('must-not-be-copied')) 'The join code was printed'
    $run = Invoke-Engine -State $s -Program (Join-Path $package 'bin\SmartConnector.exe') -Arguments @('--action', 'Install', '--repository-path', (Join-Path $package 'installer'), '--skills', 'Off')
    Assert ($run.Code -eq 1 -and $run.Err -match 'cannot be inside or contain the downloaded package') ('An install folder inside the package must be refused: ' + (Show-Run $run))
    'PASS: Install copies a downloaded package to the permanent folder (library replaced, preserved folders and join code handled)'

    # ---------- 5. AutoCAD panel: the same files as the PowerShell build ----------
    $s = New-State 'autocad'
    $treeName = 'SmartConnectorEngineTest-' + [guid]::NewGuid().ToString('N')
    $referenceTree = 'SmartConnectorEngineRef-' + [guid]::NewGuid().ToString('N')
    $registryTrees.Add("HKCU:\Software\$treeName"); $registryTrees.Add("HKCU:\Software\$referenceTree")
    function New-AutoCadRegistry([string]$Tree) {
        # One profile that already trusts a folder, one with no trusted paths, a current profile without a Variables key, a product without profiles.
        $registry = "HKCU:\Software\$Tree"
        $profiles = "$registry\R25.0\ACAD-8101:409\Profiles"
        New-Item -Path "$profiles\<<Unnamed Profile>>\Variables" -Force | Out-Null
        New-Item -Path "$profiles\Second\Variables" -Force | Out-Null
        New-Item -Path "$registry\R24.3\ACAD-7101:409" -Force | Out-Null
        Set-ItemProperty -LiteralPath "$profiles\<<Unnamed Profile>>\Variables" -Name TRUSTEDPATHS -Value 'C:\Existing'
        $profilesC = "$registry\R26.0\ACAD-9101:409\Profiles"
        New-Item -Path "$profilesC\Office" -Force | Out-Null
        Set-Item -LiteralPath $profilesC -Value 'Office'
        $registry
    }
    $null = New-AutoCadRegistry $treeName
    $referenceRegistry = New-AutoCadRegistry $referenceTree
    $support = Join-Path $s.Roaming 'Autodesk\AutoCAD 2025\R25.0\enu\Support'
    New-Item -ItemType Directory -Force $support | Out-Null
    Set-Content (Join-Path $support 'SmartAutodeskConnector.cuix') 'stale' -Encoding ASCII
    Set-Content (Join-Path $support 'acad.CUIX') 'keep' -Encoding ASCII
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'AutoCAD', '--test-autocad-releases', 'R25.0', '--autocad-registry-root', "Software\$treeName")
    Assert ($run.Code -eq 0) ('AutoCAD Install failed: ' + (Show-Run $run))
    Assert ((Has-Line $run '^\[RESULT\] autocad=ok restart AutoCAD to load it$') -and (Has-Line $run "Added the panel's folder to AutoCAD's trusted paths in 3 profile\(s\)\.")) ('AutoCAD step: ' + (Show-Run $run))
    $bundle = Join-Parts $s.Roaming @('Autodesk', 'ApplicationPlugins', 'SmartAutodeskConnector.bundle')
    $contents = Join-Path $bundle 'Contents'
    foreach ($file in 'PackageContents.xml', 'Contents\SmartAutodeskConnector.lsp', 'Contents\AI-Markup.lsp', 'Contents\SmartAutodeskConnector.cuix') { Assert (Test-Path (Join-Path $bundle $file)) "The bundle lacks $file" }
    Assert (-not (Test-Path (Join-Path $contents 'cuix-source'))) 'The CUIX source parts were copied into the bundle'
    Assert (-not (Test-Path (Join-Path $support 'SmartAutodeskConnector.cuix')) -and (Test-Path (Join-Path $support 'acad.CUIX'))) 'The stale AutoCAD copy of the panel menu was not removed, or another menu file was'
    $profileA = "HKCU:\Software\$treeName\R25.0\ACAD-8101:409\Profiles\<<Unnamed Profile>>\Variables"
    $profileB = "HKCU:\Software\$treeName\R25.0\ACAD-8101:409\Profiles\Second\Variables"
    Assert ((Get-ItemProperty -LiteralPath $profileA).TRUSTEDPATHS -eq "C:\Existing;$contents") 'Existing trusted path not kept, or the bundle folder not added'
    Assert ((Get-ItemProperty -LiteralPath $profileB).TRUSTEDPATHS -eq $contents) 'The bundle folder is not trusted in a profile without trusted paths'
    Assert ((Get-ItemProperty -LiteralPath "HKCU:\Software\$treeName\R26.0\ACAD-9101:409\Profiles\Office\Variables").TRUSTEDPATHS -eq $contents) 'The current profile without a Variables key was not trusted'
    # The PowerShell build of the same panel, into its own folders: every part, icon and file is the same.
    $psPlugins = Join-Path $t 'ps-plugins'
    Install-AutoCadBundle -Root $runtime -PluginsRoot $psPlugins -RegistryRoot $referenceRegistry -RoamingRoot (Join-Path $t 'ps-roaming')
    $psBundle = Join-Path $psPlugins 'SmartAutodeskConnector.bundle'
    $mine = @(Get-ChildItem -LiteralPath $bundle -Recurse -File | ForEach-Object { $_.FullName.Substring($bundle.Length + 1) } | Sort-Object)
    $reference = @(Get-ChildItem -LiteralPath $psBundle -Recurse -File | ForEach-Object { $_.FullName.Substring($psBundle.Length + 1) } | Sort-Object)
    Assert (($mine -join '|') -eq ($reference -join '|')) ("The bundle files differ from the PowerShell build:`n" + ($mine -join ', ') + "`n" + ($reference -join ', '))
    foreach ($file in $mine) {
        if ($file -like '*.cuix') { continue }
        Assert ((Get-Sha256File (Join-Path $bundle $file)) -eq (Get-Sha256File (Join-Path $psBundle $file))) "$file differs from the PowerShell build"
    }
    $partsMine = Read-ZipEntries (Join-Path $contents 'SmartAutodeskConnector.cuix')
    $partsReference = Read-ZipEntries (Join-Path $psBundle 'Contents\SmartAutodeskConnector.cuix')
    Assert ((($partsMine.Keys | Sort-Object) -join '|') -eq (($partsReference.Keys | Sort-Object) -join '|')) 'The .cuix holds different parts than the PowerShell build'
    foreach ($name in $partsMine.Keys) {
        if ($name -eq 'Menu_Package_Info.xml') { continue }
        Assert ((Get-Sha256Bytes $partsMine[$name]) -eq (Get-Sha256Bytes $partsReference[$name])) "The .cuix part $name differs from the PowerShell build"
    }
    $infoMine = [xml][Text.Encoding]::UTF8.GetString($partsMine['Menu_Package_Info.xml'])
    $infoReference = [xml][Text.Encoding]::UTF8.GetString($partsReference['Menu_Package_Info.xml'])
    Assert ((@($infoMine.MenuPackageParts.PartData | ForEach-Object { $_.PartData_Name }) -join '|') -eq (@($infoReference.MenuPackageParts.PartData | ForEach-Object { $_.PartData_Name }) -join '|')) 'Menu_Package_Info.xml lists different parts'
    Assert ((@($infoMine.MenuPackageParts.PartData | Where-Object { $_.PartData_Modified -notmatch '^\d{4}-\d\d-\d\dT' }).Count) -eq 0) 'Menu_Package_Info.xml has a bad time stamp'
    $zipMine = [IO.Compression.ZipFile]::OpenRead((Join-Path $contents 'SmartAutodeskConnector.cuix'))
    try { foreach ($entry in $zipMine.Entries | Where-Object { $_.Name -like '*.png' }) { Assert ($entry.CompressedLength -ge $entry.Length) "$($entry.Name) is compressed; Autodesk packs icons uncompressed" } } finally { $zipMine.Dispose() }
    # A second install changes nothing in the registry; Uninstall restores it exactly.
    $run = Invoke-Engine -State $s -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'AutoCAD', '--test-autocad-releases', 'R25.0', '--autocad-registry-root', "Software\$treeName")
    Assert ($run.Code -eq 0 -and (Get-ItemProperty -LiteralPath $profileA).TRUSTEDPATHS -eq "C:\Existing;$contents") ('A reinstall added the folder twice: ' + (Show-Run $run))
    $run = Invoke-Engine -State $s -Arguments @('--action', 'UninstallAutoCadPanel', '--autocad-registry-root', "Software\$treeName")
    Assert ($run.Code -eq 0 -and (Has-Line $run 'Removed the AutoCAD Add-ins panel and its trusted path\. Restart AutoCAD to finish\.')) ('Uninstall: ' + (Show-Run $run))
    Assert (-not (Test-Path $bundle) -and (Get-ItemProperty -LiteralPath $profileA).TRUSTEDPATHS -eq 'C:\Existing' -and (Get-ItemProperty -LiteralPath $profileB).TRUSTEDPATHS -eq '') 'Uninstall did not restore the other trusted paths exactly'
    'PASS: the AutoCAD panel (bundle files, .cuix parts, trusted folders, stale menu copy) is the same as the PowerShell build, installs once and uninstalls cleanly'

    # ---------- 6. Revit add-in: built by the Windows compiler (a stand-in compiler records how it was started) ----------
    $s = New-State 'revit'
    $fakeWindows = Join-Path $t 'fake-windows'
    $fakeFramework = Join-Path $fakeWindows 'Microsoft.NET\Framework64\v4.0.30319'
    New-Item -ItemType Directory -Force (Join-Path $fakeFramework 'WPF'), (Join-Path $s.Programs 'Autodesk\Revit 2024') | Out-Null
    foreach ($dll in 'WPF\WindowsBase.dll', 'WPF\PresentationCore.dll', 'Microsoft.CSharp.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll') { Set-Content (Join-Path $fakeFramework $dll) 'stand-in reference' -Encoding ASCII }
    Set-Content (Join-Path $s.Programs 'Autodesk\Revit 2024\RevitAPI.dll') 'stand-in' -Encoding ASCII
    Set-Content (Join-Path $s.Programs 'Autodesk\Revit 2024\RevitAPIUI.dll') 'stand-in' -Encoding ASCII
    $stubSource = Join-Path $t 'stub-csc.cs'
    Set-Content $stubSource -Encoding ASCII -Value @'
using System;
using System.IO;
class StubCompiler {
    static int Main(string[] args) {
        string folder = Path.GetDirectoryName(typeof(StubCompiler).Assembly.Location);
        File.WriteAllLines(Path.Combine(folder, "csc-args.log"), args);
        foreach (string argument in args) {
            if (!argument.StartsWith("/out:")) continue;
            string output = argument.Substring(5);
            Directory.CreateDirectory(Path.GetDirectoryName(output));
            File.WriteAllText(output, "stand-in assembly for " + args.Length + " arguments");
        }
        return 0;
    }
}
'@
    $realCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $ErrorActionPreference = 'Continue'
    $compiled = & $realCompiler /nologo /target:exe "/out:$(Join-Path $fakeFramework 'csc.exe')" $stubSource 2>&1
    $ErrorActionPreference = 'Stop'
    Assert (Test-Path (Join-Path $fakeFramework 'csc.exe')) ("The stand-in compiler did not build: $compiled")
    $addinFolder = Join-Parts $s.Roaming @('Autodesk', 'Revit', 'Addins', '2024')
    New-Item -ItemType Directory -Force $addinFolder | Out-Null
    Set-Content (Join-Path $addinFolder 'BimCadMcp.addin') '<legacy/>' -Encoding ASCII
    $revitCopy = New-InstalledCopy 'install-revit'
    $oldBuilds = Join-Path $revitCopy 'src\revit\bin\2024'
    New-Item -ItemType Directory -Force $oldBuilds | Out-Null
    Set-Content (Join-Path $oldBuilds 'BimCadMcp.Revit.aaaaaaaaaaaa.dll') 'old build' -Encoding ASCII
    # Before the install: does the program see the stand-in Revit, with and without the stand-in Windows folder?
    # (When it does not, say which, so the cause is clear.)
    $revitProgram = Join-Path $revitCopy 'bin\SmartConnector.exe'
    $seen = '^\[\d\d:\d\d:\d\d\] Revit 2024 installation detected\.$'
    $plainProbe = Invoke-Engine -State $s -Program $revitProgram -Arguments @('--action', 'Status', '--product', 'Revit')
    $fakeProbe = Invoke-Engine -State $s -Program $revitProgram -Arguments @('--action', 'Status', '--product', 'Revit') -ExtraEnv @{ WINDIR = $fakeWindows }
    if (-not ((Has-Line $plainProbe $seen) -and (Has-Line $fakeProbe $seen))) {
        $files = (Get-ChildItem -LiteralPath $s.Programs -Recurse -File | ForEach-Object { $_.FullName }) -join '; '
        # Two more facts: is the program 32-bit (Windows then replaces %ProgramFiles% for it), and what does a plain
        # Windows process see for %ProgramFiles% when started the same way?
        $architecture = [Reflection.AssemblyName]::GetAssemblyName($revitProgram).ProcessorArchitecture
        $peBytes = [IO.File]::ReadAllBytes($revitProgram); $peMagic = '{0:X}' -f [BitConverter]::ToUInt16($peBytes, [BitConverter]::ToInt32($peBytes, 0x3C) + 24)
        $echo = New-Object Diagnostics.ProcessStartInfo($env:ComSpec, '/c echo %ProgramFiles%')
        $echo.UseShellExecute = $false; $echo.RedirectStandardOutput = $true; $echo.CreateNoWindow = $true
        $echo.EnvironmentVariables['ProgramFiles'] = $s.Programs
        $echoProcess = [Diagnostics.Process]::Start($echo); $echoSees = $echoProcess.StandardOutput.ReadToEnd().Trim(); $echoProcess.WaitForExit()
        throw ('The stand-in Revit was not detected. Program architecture: ' + $architecture + ' (PE magic ' + $peMagic + '); cmd.exe sees ProgramFiles as: ' + $echoSees + '; this PowerShell is 64-bit: ' + [Environment]::Is64BitProcess + '. Programs folder: ' + $s.Programs + ' holds: ' + $files + '. Detected without WINDIR override: ' + (Has-Line $plainProbe $seen) + '; with it: ' + (Has-Line $fakeProbe $seen) + '. Output with the override: ' + (Show-Run $fakeProbe))
    }
    $run = Invoke-Engine -State $s -Program $revitProgram -Arguments @('--action', 'Install', '--repository-path', $revitCopy, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'Revit') -ExtraEnv @{ WINDIR = $fakeWindows }
    Assert ($run.Code -eq 0) ('Revit Install failed: ' + (Show-Run $run))
    Assert ((Has-Line $run '^\[RESULT\] revit=ok restart Revit to load it$') -and (Has-Line $run 'Building the Revit 2024 add-in against the installed Revit API\.\.\.')) ('Revit step: ' + (Show-Run $run))
    $built = 'stand-in assembly for 15 arguments'
    $hash = (Get-Sha256Bytes ([Text.Encoding]::ASCII.GetBytes($built))).Substring(0, 12).ToLowerInvariant()
    $dll = Join-Path $oldBuilds "BimCadMcp.Revit.$hash.dll"
    Assert (Test-Path $dll) ('The add-in was not installed under its content hash: ' + (Get-ChildItem $oldBuilds | ForEach-Object Name) -join ', ')
    Assert (-not (Test-Path (Join-Path $oldBuilds 'BimCadMcp.Revit.aaaaaaaaaaaa.dll')) -and -not (Test-Path (Join-Path $addinFolder 'BimCadMcp.addin'))) 'The old build or the legacy manifest was not removed'
    $manifest = [xml](Get-Content (Join-Path $addinFolder 'AutodeskMcpConnector.addin') -Raw)
    Assert ($manifest.RevitAddIns.AddIn.Assembly -eq $dll -and $manifest.RevitAddIns.AddIn.FullClassName -eq 'BimCadMcp.Revit.Application' -and $manifest.RevitAddIns.AddIn.AddInId -eq '2DCE7E67-4495-4F3B-A740-3D7C9D2DA124' -and $manifest.RevitAddIns.AddIn.Name -eq 'Smart Connector') 'The add-in manifest is wrong'
    $compilerArguments = @(Get-Content (Join-Path $fakeFramework 'csc-args.log'))
    $expectedArguments = @('/nologo', '/target:library', '/optimize+', '/platform:anycpu')
    foreach ($argument in $expectedArguments) { Assert ($compilerArguments -contains $argument) "The compiler was not given $argument" }
    $api = Join-Path $s.Programs 'Autodesk\Revit 2024'
    foreach ($argument in "/reference:$api\RevitAPI.dll", "/reference:$api\RevitAPIUI.dll", "/reference:$fakeFramework\WPF\WindowsBase.dll", "/reference:$fakeFramework\WPF\PresentationCore.dll",
        "/reference:$fakeFramework\Microsoft.CSharp.dll", "/reference:$fakeFramework\System.Windows.Forms.dll", "/reference:$fakeFramework\System.Drawing.dll") { Assert ($compilerArguments -contains $argument) "The compiler was not given $argument" }
    foreach ($source in 'RevitMcpApplication.cs', 'AdvancedControl.cs', 'ConnectorUi.cs') { Assert ($compilerArguments -contains (Join-Parts $revitCopy @('src', 'revit', 'addin', $source))) "$source was not compiled" }
    # The same references and sources as src\revit\build-revit-addin.ps1.
    $psBuild = Get-Content (Join-Path $runtime 'src\revit\build-revit-addin.ps1') -Raw
    foreach ($needle in "'addin\RevitMcpApplication.cs'", "'addin\AdvancedControl.cs'", "'addin\ConnectorUi.cs'", '/target:library', '/optimize+', '/platform:anycpu') { Assert ($psBuild.Contains($needle)) "build-revit-addin.ps1 no longer has $needle" }
    # Without Revit: skipped, no compiler needed.
    $run = Invoke-Engine -State (New-State 'revit-absent') -Arguments @('--action', 'Install', '--repository-path', $root, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'Revit')
    Assert ((Has-Line $run '^\[RESULT\] revit=skipped Revit 2024 is not installed$') -and $run.Code -eq 0) (Show-Run $run)
    'PASS: the Revit add-in is built with the Windows compiler child process (same references and sources), installed under its content hash, with the manifest, old builds and the legacy manifest handled'

    # ---------- 7. Enrollment and team join ----------
    $token = ([guid]::NewGuid().ToString('N')) * 2
    function New-EnrollmentFile([string]$State, [string]$Name, [string]$Text) { $path = Join-Path $State $Name; [IO.File]::WriteAllText($path, $Text); $path }
    function Valid-Enrollment([string]$Secret) { @{ service_url = 'https://skills.example.test'; device_id = '0123456789abcdef0123456789abcdef'; device_token = $Secret } | ConvertTo-Json }
    $s = New-State 'enroll'
    $service = Join-Path $s.Local 'AutodeskMcpSkillCollection\service.json'
    $deploy = Join-Path $s.Base 'deploy'
    New-Item -ItemType Directory -Force $deploy | Out-Null
    $file = New-EnrollmentFile $deploy 'pc-07.json' (Valid-Enrollment $token)
    $arguments = @('--action', 'Install', '--repository-path', $root, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'Revit')
    $run = Invoke-Engine -State $s -Arguments ($arguments + @('--enrollment-path', $file))
    Assert ($run.Code -eq 0 -and (Has-Line $run '\[ENROLLMENT_OK\]') -and (Has-Line $run '\[ENROLLMENT_FILE_REMOVED\]')) ('Enrollment: ' + (Show-Run $run))
    Assert (-not (Test-Path $file)) 'The plaintext enrollment file was left on disk'
    $config = Get-Content $service -Raw | ConvertFrom-Json
    Assert ($config.service_url -eq 'https://skills.example.test' -and $config.device_id -eq '0123456789abcdef0123456789abcdef' -and -not (Get-Content $service -Raw).Contains($token)) 'service.json is wrong or holds the plaintext token'
    Assert ((ConvertTo-PlainText $config.protected_token) -eq $token) 'The protected token does not decrypt for this user with ConvertTo-SecureString'
    Assert (-not $run.Text.Contains($token) -and -not $run.Err.Contains($token)) 'The token was written to the setup output'
    Assert (Has-Line $run 'Importing central skill sharing enrollment from pc-07\.json\.\.\.') 'The import was not announced'
    # Already enrolled and no file: kept.
    $run = Invoke-Engine -State $s -Arguments $arguments
    Assert ((Has-Line $run '\[ENROLLMENT_UNCHANGED\]') -and $run.Code -eq 0) (Show-Run $run)
    # An invalid replacement is refused and the working enrollment is not changed; the plaintext is still removed.
    $before = Get-Content $service -Raw
    $file = New-EnrollmentFile $deploy 'bad-token.json' (Valid-Enrollment 'short')
    $run = Invoke-Engine -State $s -Arguments ($arguments + @('--enrollment-path', $file))
    Assert ((Has-Line $run '\[ENROLLMENT_FAILED\] Invalid device enrollment token\.') -and -not (Test-Path $file) -and (Get-Content $service -Raw) -eq $before) ('Invalid token: ' + (Show-Run $run))
    # Invalid JSON: the error must not copy the secret; the file is still removed. A missing file is reported as pending.
    $s2 = New-State 'enroll-bad'
    $file = New-EnrollmentFile $deploy 'broken.json' ('{"device_token":"' + $token + '" broken')
    $run = Invoke-Engine -State $s2 -Arguments ($arguments + @('--enrollment-path', $file))
    Assert ((Has-Line $run '\[ENROLLMENT_FAILED\] The enrollment file is not valid JSON\.') -and -not $run.Text.Contains($token) -and -not (Test-Path $file) -and -not (Test-Path (Join-Path $s2.Local 'AutodeskMcpSkillCollection\service.json'))) ('Broken JSON: ' + (Show-Run $run))
    $run = Invoke-Engine -State $s2 -Arguments ($arguments + @('--enrollment-path', (Join-Path $deploy 'absent.json')))
    Assert (Has-Line $run '\[ENROLLMENT_MISSING\] Enrollment file not found: ') (Show-Run $run)
    $run = Invoke-Engine -State $s2 -Arguments $arguments
    Assert (Has-Line $run '\[ENROLLMENT_PENDING\] ') (Show-Run $run)
    'PASS: enrollment is imported, protected with DPAPI (decrypts with ConvertTo-SecureString), overwritten and deleted; invalid, broken and missing files are reported without leaking the token'

    if ($http) {
        $s = New-State 'join'
        $code = 'team-join-code-for-tests-' + [guid]::NewGuid().ToString('N')
        $deviceToken = ([guid]::NewGuid().ToString('N')) * 2
        Set-Content (Join-Path $serve 'join-code.txt') $code -Encoding ASCII
        [IO.File]::WriteAllText((Join-Path $serve 'device.json'), (@{ device_id = '0123456789abcdef0123456789abcdef'; device_token = $deviceToken } | ConvertTo-Json))
        $joinCopy = New-InstalledCopy 'install-join'
        $joinFile = Join-Path $joinCopy 'installer\team-join.json'
        [IO.File]::WriteAllText($joinFile, (@{ service_url = $http + '/'; join_code = $code } | ConvertTo-Json))
        $run = Invoke-Engine -State $s -Program (Join-Path $joinCopy 'bin\SmartConnector.exe') -Arguments @('--action', 'Install', '--repository-path', $joinCopy, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'Revit', '--join-name', ' Ahmed Ali ', '--join-email', 'ahmed@example.com', '--terms-version', '2026-01-01')
        Assert ($run.Code -eq 0 -and (Has-Line $run 'Joining the team skill service as Ahmed Ali\.\.\.') -and (Has-Line $run '\[ENROLLMENT_OK\]') -and (Has-Line $run '\[ENROLLMENT_FILE_REMOVED\]')) ('Team join: ' + (Show-Run $run))
        $request = Get-Content (Join-Path $serve 'enroll-request.json') -Raw | ConvertFrom-Json
        $body = $request.body | ConvertFrom-Json
        Assert ($request.authorization -eq ('Bearer ' + $code) -and $request.version -eq $version -and $request.agent -eq ('Autodesk-MCP-Connector/' + $version)) 'The join request headers are wrong'
        Assert ($body.name -eq 'Ahmed Ali' -and $body.email -eq 'ahmed@example.com' -and $body.pc_name -eq $env:COMPUTERNAME -and $body.windows_user -eq $env:USERNAME -and $body.terms_version -eq '2026-01-01' -and $body.connector_version -eq $version) 'The join profile is wrong'
        $config = Get-Content (Join-Path $s.Local 'AutodeskMcpSkillCollection\service.json') -Raw | ConvertFrom-Json
        Assert ($config.service_url -eq $http -and $config.device_id -eq '0123456789abcdef0123456789abcdef' -and (ConvertTo-PlainText $config.protected_token) -eq $deviceToken) 'The device token was not stored protected for this user'
        Assert (@(Get-ChildItem (Join-Path $s.Local 'AutodeskMcpSkillCollection') -Filter 'enrollment-*.json').Count -eq 0) 'A plaintext enrollment file was left behind'
        Assert (-not (Test-Path $joinFile)) 'The join code was left in the install'
        Assert (-not $run.Text.Contains($code) -and -not $run.Text.Contains($deviceToken) -and -not $run.Err.Contains($code)) 'The join code or the device token was written to the output'
        # Wrong code: a clear failure, the install continues, nothing is stored.
        $s = New-State 'join-wrong'
        [IO.File]::WriteAllText($joinFile, (@{ service_url = $http; join_code = 'another-code-that-the-service-does-not-know-0123' } | ConvertTo-Json))
        $run = Invoke-Engine -State $s -Program (Join-Path $joinCopy 'bin\SmartConnector.exe') -Arguments @('--action', 'Install', '--repository-path', $joinCopy, '--skills', 'Off', '--ai-clients', 'Codex', '--product', 'Revit', '--join-name', 'Ahmed', '--join-email', 'a@example.com')
        Assert ($run.Code -eq 0 -and (Has-Line $run '\[ENROLLMENT_FAILED\] The team join code was not accepted') -and -not (Test-Path (Join-Path $s.Local 'AutodeskMcpSkillCollection\service.json')) -and -not (Test-Path $joinFile)) ('Wrong join code: ' + (Show-Run $run))
        'PASS: team join sends the profile with the code, stores the device token with DPAPI, removes the join code and plaintext, and explains a refused code'
    }

    # ---------- 8. What earlier versions left behind ----------
    $s = New-State 'retire'
    $oldInstall = New-InstalledCopy 'install-retire'
    foreach ($relative in 'scripts\connector-agent.ps1', 'src\autodesk\autodesk-http-gateway.ps1', 'REMOTE-CLAUDE.md') { Set-Content (Join-Path $oldInstall $relative) 'x' -Encoding ASCII }
    $stateScripts = Join-Path $s.Local 'AutodeskMcpSkillCollection\scripts'
    $remote = Join-Path $s.Local 'AutodeskMcpConnector\remote'
    $startup = Join-Parts $s.Roaming @('Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup')
    New-Item -ItemType Directory -Force $stateScripts, $remote, $startup | Out-Null
    Set-Content (Join-Path $stateScripts 'connector-agent.ps1') 'x' -Encoding ASCII
    Set-Content (Join-Path $stateScripts 'send-usage.ps1') 'x' -Encoding ASCII
    Set-Content (Join-Path $remote 'cloudflare-token.dpapi') 'token' -Encoding ASCII
    Set-Content (Join-Path $remote 'runtime.json') '{"gateway":{"pid":999999,"started_at":"2026-01-01T00:00:00Z"}}' -Encoding ASCII
    Set-Content (Join-Path $startup 'Autodesk MCP Remote Connector.cmd') '@echo off' -Encoding ASCII
    Set-Content (Join-Path $startup 'Other.cmd') '@echo off' -Encoding ASCII
    Set-Content (Join-Path $s.Local 'AutodeskMcpConnector\update-requested.flag') 'x' -Encoding ASCII
    $taskName = 'Autodesk MCP Usage Report - engine-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $otherTask = 'Engine Test Unrelated Task ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $registeredTasks = $false
    if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
        try {
            $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
            foreach ($name in $taskName, $otherTask) { $null = Register-ScheduledTask -TaskName $name -Action $action -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)) -Force }
            $registeredTasks = $true
        }
        catch { "NOTE: scheduled tasks cannot be created here ($($_.Exception.Message)); the task part of the cleanup is not tested" }
    }
    try {
        $run = Invoke-Engine -State $s -Program (Join-Path $oldInstall 'bin\SmartConnector.exe') -Arguments @('--action', 'CheckUpdate', '--repository-path', $oldInstall, '--release-manifest-url', $olderManifest)
        Assert ($run.Code -eq 0) ('CheckUpdate: ' + (Show-Run $run))
        Assert ((Has-Line $run 'Removed connector-agent\.ps1 from the skills folder\.') -and (Has-Line $run 'Removed Claude remote access') -and (Has-Line $run 'Removed 3 file\(s\) of the agent and remote access from the install folder\.')) ('Cleanup report: ' + (Show-Run $run))
        Assert (-not (Test-Path (Join-Path $stateScripts 'connector-agent.ps1')) -and (Test-Path (Join-Path $stateScripts 'send-usage.ps1'))) 'The agent copy was not removed, or a Skills Sync helper was'
        Assert (-not (Test-Path $remote) -and -not (Test-Path (Join-Path $s.Local 'AutodeskMcpConnector\update-requested.flag'))) 'Remote credentials or the update request flag were left'
        Assert (-not (Test-Path (Join-Path $startup 'Autodesk MCP Remote Connector.cmd')) -and (Test-Path (Join-Path $startup 'Other.cmd'))) 'The remote start-up entry was left, or another start-up entry was removed'
        Assert (-not (Test-Path (Join-Path $oldInstall 'scripts\connector-agent.ps1')) -and -not (Test-Path (Join-Path $oldInstall 'REMOTE-CLAUDE.md')) -and (Test-Path (Join-Path $oldInstall 'src\autodesk\autodesk-bridge.ps1'))) 'Old agent files were left, or the MCP bridge was removed'
        if ($registeredTasks) {
            Assert (Has-Line $run ('Removed scheduled tasks from an earlier version: ' + [regex]::Escape($taskName))) ('The earlier task was not reported: ' + (Show-Run $run))
            Assert (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) 'The earlier usage task was not unregistered'
            Assert ($null -ne (Get-ScheduledTask -TaskName $otherTask -ErrorAction SilentlyContinue)) 'Another program''s task was removed'
        }
    }
    finally {
        foreach ($name in $taskName, $otherTask) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
    }
    'PASS: earlier tasks, the agent copy, the remote gateway and its files are removed; nothing else is touched'
}
finally {
    foreach ($process in $started) { try { if (-not $process.HasExited) { $process.Kill() } } catch { } }
    if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    foreach ($tree in $registryTrees) { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
}
