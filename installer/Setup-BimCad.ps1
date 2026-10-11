[CmdletBinding()]
param(
    [ValidateSet('Status', 'Install', 'Update', 'Test', 'Collect')]
    [string]$Action = 'Status',

    [ValidateSet('AutoCAD', 'Revit')]
    [string]$Product = 'AutoCAD',

    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/BIM-CAD---MCP.git',

    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),

    [switch]$SkipRepositoryUpdate
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Get-RequiredCommand {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        throw "$Name is not installed or is not available in PATH."
    }
    $command.Source
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    if ($output) {
        $output | ForEach-Object { Write-Output $_ }
    }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$FilePath failed with exit code $exitCode."
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Get-Repository {
    $git = Get-RequiredCommand 'git'
    $manifest = Join-Path $RepositoryPath '.agents\skills'

    if (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git') -PathType Container) {
        if (-not $SkipRepositoryUpdate) {
            Write-Step 'Downloading the newest setup and skills from GitHub...'
            $result = Invoke-External $git @('-C', $RepositoryPath, 'pull', '--ff-only', 'origin', 'main')
            $null = $result
        }
    }
    else {
        if ($SkipRepositoryUpdate) {
            throw "No Git repository exists at $RepositoryPath."
        }
        if (Test-Path -LiteralPath $RepositoryPath) {
            $existing = @(Get-ChildItem -LiteralPath $RepositoryPath -Force -ErrorAction SilentlyContinue)
            if ($existing.Count -gt 0) {
                throw "The installation folder is not empty: $RepositoryPath"
            }
        }
        else {
            $parent = Split-Path -Parent $RepositoryPath
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Write-Step 'Downloading BIM-CAD MCP from GitHub...'
        $result = Invoke-External $git @('clone', $RepositoryUrl, $RepositoryPath)
        $null = $result
    }

    if (-not (Test-Path -LiteralPath $manifest -PathType Container)) {
        throw "The downloaded repository does not contain .agents\skills."
    }
    (Resolve-Path -LiteralPath $RepositoryPath).Path
}

function Install-Skills {
    param([string]$Root)

    $syncScript = Join-Path $Root 'scripts\sync-codex-skills.ps1'
    if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
        throw "Skill installer is missing: $syncScript"
    }
    Write-Step 'Installing all saved Codex skills...'
    $result = Invoke-External 'powershell.exe' @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $syncScript, '-Action', 'Install')
    $null = $result
}

function Register-McpServer {
    param(
        [string]$Name,
        [string]$Bridge,
        [string[]]$BridgeArguments = @()
    )

    $codex = Get-RequiredCommand 'codex'
    if (-not (Test-Path -LiteralPath $Bridge -PathType Leaf)) {
        throw "MCP bridge is missing: $Bridge"
    }

    $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }
    $configPath = Join-Path $codexHome 'config.toml'
    $backupPath = Join-Path $codexHome ("config.toml.bim-cad-setup-{0}.bak" -f $PID)
    $hasBackup = $false
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
        $hasBackup = $true
    }

    Write-Step ("Registering the {0} MCP server in Codex..." -f $Name)
    try {
        $existing = Invoke-External $codex @('mcp', 'get', $Name) -AllowFailure
        if ($existing.ExitCode -eq 0) {
            $removed = Invoke-External $codex @('mcp', 'remove', $Name)
            $null = $removed
        }

        $command = @(
            'mcp', 'add', $Name, '--',
            'powershell.exe', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', $Bridge
        ) + $BridgeArguments
        $added = Invoke-External $codex $command
        $null = $added
        $verified = Invoke-External $codex @('mcp', 'get', $Name)
        $null = $verified
    }
    catch {
        if ($hasBackup) {
            Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
        }
        throw
    }
    finally {
        if ($hasBackup -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function Get-AutoCadProgIds {
    $ids = @()
    try {
        $current = (Get-ItemProperty -LiteralPath 'Registry::HKEY_CLASSES_ROOT\AutoCAD.Application\CurVer' -ErrorAction Stop).'(default)'
        if ($current) { $ids += [string]$current }
    }
    catch { }
    try {
        $ids += @(Get-ChildItem 'Registry::HKEY_CLASSES_ROOT' -ErrorAction Stop |
            Where-Object { $_.PSChildName -match '^AutoCAD\.Application\.\d+(?:\.\d+)?$' } |
            Select-Object -ExpandProperty PSChildName)
    }
    catch { }
    @($ids + 'AutoCAD.Application' | Select-Object -Unique)
}

function Test-AutoCadSetup {
    $releases = @()
    $root = 'HKLM:\SOFTWARE\Autodesk\AutoCAD'
    if (Test-Path -LiteralPath $root) {
        $releases = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
    }
    if ($releases.Count -gt 0) {
        Write-Step ("AutoCAD installation detected: {0}" -f ($releases -join ', '))
    }
    else {
        Write-Step 'Full AutoCAD for Windows was not detected.'
    }

    $codex = Get-Command 'codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($codex) {
        $registration = Invoke-External $codex.Source @('mcp', 'get', 'autocad') -AllowFailure
        if ($registration.ExitCode -eq 0) { Write-Step 'Codex has an AutoCAD MCP registration.' }
        else { Write-Step 'The AutoCAD MCP server is not registered yet.' }
    }
    else { Write-Step 'Codex command was not detected.' }

    $cad = $null
    foreach ($progId in Get-AutoCadProgIds) {
        try { $cad = [Runtime.InteropServices.Marshal]::GetActiveObject($progId); break } catch { }
    }
    if ($cad) {
        if ($cad.Documents.Count -gt 0) {
            $document = $cad.ActiveDocument
            Write-Step ("Live AutoCAD connection passed: version {0}; {1}; {2} layer(s)." -f $cad.Version, $document.Name, $document.Layers.Count)
        }
        else { Write-Step 'AutoCAD is running, but no drawing is open.' }
    }
    else { Write-Step 'AutoCAD is not currently available for a live test. Start AutoCAD and open a drawing.' }
}

function Install-RevitAddin {
    param([string]$Root)

    $revitPath = Join-Path $env:ProgramFiles 'Autodesk\Revit 2024'
    if (-not (Test-Path -LiteralPath (Join-Path $revitPath 'RevitAPI.dll') -PathType Leaf)) {
        throw 'Revit 2024 was not detected. Install Revit 2024 before installing its MCP add-in.'
    }

    $buildScript = Join-Path $Root 'src\revit\build-revit-addin.ps1'
    Write-Step 'Building the Revit 2024 add-in against the installed Revit API...'
    $built = Invoke-External 'powershell.exe' @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$buildScript,'-RevitVersion','2024')
    $null = $built
    $assembly = Join-Path $Root 'src\revit\bin\2024\BimCadMcp.Revit.dll'
    if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) { throw 'The Revit add-in DLL was not produced.' }

    $manifestDirectory = Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2024'
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    $manifestPath = Join-Path $manifestDirectory 'BimCadMcp.addin'
    $escapedAssembly = [Security.SecurityElement]::Escape($assembly)
    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<RevitAddIns>
  <AddIn Type="Application">
    <Name>BIM-CAD MCP</Name>
    <Assembly>$escapedAssembly</Assembly>
    <AddInId>2DCE7E67-4495-4F3B-A740-3D7C9D2DA124</AddInId>
    <FullClassName>BimCadMcp.Revit.Application</FullClassName>
    <VendorId>BIMC</VendorId>
    <VendorDescription>BIM-CAD MCP local connector</VendorDescription>
  </AddIn>
</RevitAddIns>
"@
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8
    Write-Step ("Installed Revit add-in manifest: {0}" -f $manifestPath)
}

function Test-RevitSetup {
    $installed = Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Autodesk\Revit 2024\RevitAPI.dll')
    if ($installed) { Write-Step 'Revit 2024 installation detected.' }
    else { Write-Step 'Revit 2024 was not detected.' }

    $manifest = Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2024\BimCadMcp.addin'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) { Write-Step 'Revit 2024 MCP add-in manifest is installed.' }
    else { Write-Step 'Revit 2024 MCP add-in manifest is not installed yet.' }

    $codex = Get-Command 'codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($codex) {
        $registration = Invoke-External $codex.Source @('mcp','get','revit') -AllowFailure
        if ($registration.ExitCode -eq 0) { Write-Step 'Codex has a Revit MCP registration.' }
        else { Write-Step 'The Revit MCP server is not registered yet.' }
    }
    else { Write-Step 'Codex command was not detected.' }

    $client = New-Object IO.Pipes.NamedPipeClientStream('.', 'BimCadMcp.Revit.2024', [IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(250)
        Write-Step 'Live Revit 2024 add-in connection is available.'
    }
    catch { Write-Step 'Live Revit connection is not available. Restart Revit 2024 after installation and open a project.' }
    finally { $client.Dispose() }
}

try {
    Write-Step ("BIM-CAD MCP Setup - {0} / {1}" -f $Product, $Action)

    if ($Action -eq 'Collect') {
        $root = Get-Repository
        $collector = Join-Path $root 'scripts\collect-skills-for-review.ps1'
        Write-Step 'Collecting local user skills for review without uploading them...'
        $collected = Invoke-External 'powershell.exe' @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$collector,'-RepositoryRoot',$root)
        $null = $collected
        exit 0
    }

    switch ($Action) {
        'Status' {
            if ($Product -eq 'AutoCAD') { Test-AutoCadSetup } else { Test-RevitSetup }
        }
        'Test' {
            if ($Product -eq 'AutoCAD') { Test-AutoCadSetup } else { Test-RevitSetup }
        }
        'Install' {
            $root = Get-Repository
            Install-Skills $root
            if ($Product -eq 'AutoCAD') {
                Register-McpServer 'autocad' (Join-Path $root 'src\autocad\autocad-bridge.ps1')
                Test-AutoCadSetup
                Write-Step 'Setup complete. Restart Codex, then open AutoCAD and a drawing.'
            }
            else {
                Install-RevitAddin $root
                Register-McpServer 'revit' (Join-Path $root 'src\revit\revit-bridge.ps1') @('-RevitVersion','2024')
                Test-RevitSetup
                Write-Step 'Setup complete. Restart Codex and Revit 2024, then open a project.'
            }
        }
        'Update' {
            $root = Get-Repository
            Install-Skills $root
            if ($Product -eq 'AutoCAD') {
                Register-McpServer 'autocad' (Join-Path $root 'src\autocad\autocad-bridge.ps1')
                Write-Step 'Skills and AutoCAD MCP configuration are up to date. Restart Codex.'
            }
            else {
                Install-RevitAddin $root
                Register-McpServer 'revit' (Join-Path $root 'src\revit\revit-bridge.ps1') @('-RevitVersion','2024')
                Write-Step 'Skills and Revit 2024 MCP configuration are up to date. Restart Codex and Revit.'
            }
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
