[CmdletBinding()]
param(
    [ValidateSet('Status', 'Install', 'Update', 'Test', 'Collect', 'TeamStatus')]
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
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Get-RequiredCommand {
    param([string]$Name)

    $command = Get-OptionalCommand $Name
    if (-not $command) {
        throw "$Name is not installed or is not available in PATH."
    }
    $command
}

function Get-OptionalCommand {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    if ($Name -eq 'codex') {
        $desktopBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        $candidates = @(
            (Join-Path $HOME '.local\bin\codex.exe'),
            (Join-Path $env:APPDATA 'npm\codex.cmd')
        )
        if (Test-Path -LiteralPath $desktopBin) {
            $candidates += @(Get-ChildItem -LiteralPath $desktopBin -Filter codex.exe -Recurse -File |
                Sort-Object LastWriteTime -Descending | Select-Object -ExpandProperty FullName)
        }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    $null
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
        $details = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"
        throw "$FilePath failed with exit code $exitCode.`r`n$details"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Get-GitHubArchiveUrl {
    param(
        [string]$Url,
        [string]$Branch = 'main'
    )

    try { $uri = [Uri]$Url }
    catch { throw "The repository address is not valid: $Url" }
    if ($uri.Host -ne 'github.com') {
        throw 'Direct download without Git currently supports github.com repositories only.'
    }

    $parts = @($uri.AbsolutePath.Trim('/') -split '/')
    if ($parts.Count -lt 2) {
        throw "The GitHub repository address is incomplete: $Url"
    }
    $owner = $parts[0]
    $repository = $parts[1] -replace '\.git$', ''
    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repository)) {
        throw "The GitHub repository address is incomplete: $Url"
    }
    "https://github.com/$owner/$repository/archive/refs/heads/$([Uri]::EscapeDataString($Branch)).zip"
}

function Assert-SafeRepositoryPath {
    $fullPath = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
    $driveRoot = [IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
    if ($fullPath -eq $driveRoot -or $fullPath -eq [IO.Path]::GetFullPath($HOME).TrimEnd('\')) {
        throw "The installation folder is not safe to replace: $fullPath"
    }
}

function Install-RepositoryArchive {
    Assert-SafeRepositoryPath
    $archiveUrl = Get-GitHubArchiveUrl -Url $RepositoryUrl
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("bim-cad-mcp-{0}" -f [Guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $temporaryRoot 'repository.zip'
    $expandedPath = Join-Path $temporaryRoot 'expanded'
    $backupPath = "$RepositoryPath.previous-$PID"
    $repositoryMoved = $false

    New-Item -ItemType Directory -Path $expandedPath -Force | Out-Null
    try {
        Write-Step 'Git is not installed. Downloading the current setup and skills directly from GitHub...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or (Get-Item -LiteralPath $archivePath).Length -eq 0) {
            throw 'GitHub returned an empty download.'
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedPath -Force

        $downloadedRoot = Get-ChildItem -LiteralPath $expandedPath -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.agents\skills') -PathType Container } |
            Select-Object -First 1
        if (-not $downloadedRoot) {
            throw 'The GitHub download does not contain the BIM-CAD MCP skill library.'
        }

        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($RepositoryPath))
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Recurse -Force
        }
        if (Test-Path -LiteralPath $RepositoryPath) {
            Move-Item -LiteralPath $RepositoryPath -Destination $backupPath
            $repositoryMoved = $true
        }

        try {
            Move-Item -LiteralPath $downloadedRoot.FullName -Destination $RepositoryPath
            $reviewBackup = Join-Path $backupPath 'skill-review'
            if ($repositoryMoved -and (Test-Path -LiteralPath $reviewBackup -PathType Container)) {
                Move-Item -LiteralPath $reviewBackup -Destination (Join-Path $RepositoryPath 'skill-review')
            }
            [ordered]@{
                repository = $RepositoryUrl
                branch = 'main'
                downloaded_utc = [DateTime]::UtcNow.ToString('o')
                method = 'github-zip'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RepositoryPath '.bim-cad-source.json') -Encoding UTF8
        }
        catch {
            if (Test-Path -LiteralPath $RepositoryPath) {
                Remove-Item -LiteralPath $RepositoryPath -Recurse -Force
            }
            if ($repositoryMoved -and (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $RepositoryPath
            }
            throw
        }

        if ($repositoryMoved -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Recurse -Force
        }
    }
    catch {
        throw "Could not download the repository from GitHub. $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-Repository {
    # A downloaded package already contains everything needed for installation.
    # Copy it to a permanent location without requiring private GitHub access.
    $packageRoot = Split-Path -Parent $PSScriptRoot
    if ($Action -eq 'Install' -and -not $SkipRepositoryUpdate -and
        (Test-Path -LiteralPath (Join-Path $packageRoot '.agents\skills') -PathType Container)) {
        $source = [IO.Path]::GetFullPath($packageRoot).TrimEnd('\')
        $destination = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
        if ($source -ne $destination) {
            if ($source.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $destination.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The installation folder cannot be inside or contain the downloaded package.'
            }
            Write-Step 'Installing the downloaded package to a permanent local folder...'
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            foreach ($entry in @('installer','scripts','src','.agents','README.md','SKILL-SUBMISSIONS.md')) {
                $item = Join-Path $source $entry
                if (Test-Path -LiteralPath $item) {
                    Copy-Item -LiteralPath $item -Destination $destination -Recurse -Force
                }
            }
        }
        return $destination
    }
    $manifest = Join-Path $RepositoryPath '.agents\skills'
    if ($SkipRepositoryUpdate) {
        if (-not (Test-Path -LiteralPath $manifest -PathType Container)) {
            throw "No valid BIM-CAD MCP repository exists at $RepositoryPath."
        }
        return (Resolve-Path -LiteralPath $RepositoryPath).Path
    }

    $git = Get-OptionalCommand 'git'
    if ($git) {
        if (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git') -PathType Container) {
            Write-Step 'Downloading the newest setup and skills from GitHub...'
            $result = Invoke-External $git @('-C', $RepositoryPath, 'pull', '--ff-only', 'origin', 'main')
            $null = $result
        }
        elseif (-not (Test-Path -LiteralPath $RepositoryPath) -or
            @(Get-ChildItem -LiteralPath $RepositoryPath -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            $parent = Split-Path -Parent $RepositoryPath
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Write-Step 'Downloading BIM-CAD MCP from GitHub...'
            $result = Invoke-External $git @('clone', $RepositoryUrl, $RepositoryPath)
            $null = $result
        }
        else {
            Write-Step 'Refreshing the installed copy directly from GitHub...'
            Install-RepositoryArchive
        }
    }
    else {
        Install-RepositoryArchive
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

    $codex = Get-OptionalCommand 'codex'
    if ($codex) {
        $registration = Invoke-External $codex @('mcp', 'get', 'autocad') -AllowFailure
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
    $buildOutput = Join-Path ([IO.Path]::GetTempPath()) ("BimCadMcp-RevitBuild-" + [Guid]::NewGuid().ToString('N'))
    $assemblyDirectory = Join-Path $Root 'src\revit\bin\2024'
    New-Item -ItemType Directory -Path $assemblyDirectory -Force | Out-Null
    try {
        Write-Step 'Building the Revit 2024 add-in against the installed Revit API...'
        $built = Invoke-External 'powershell.exe' @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$buildScript,'-RevitVersion','2024','-OutputPath',$buildOutput)
        $null = $built
        $builtAssembly = Join-Path $buildOutput 'BimCadMcp.Revit.dll'
        if (-not (Test-Path -LiteralPath $builtAssembly -PathType Leaf)) { throw 'The Revit add-in DLL was not produced.' }

        # Revit locks loaded add-in DLLs. A content-addressed filename lets an update
        # finish safely while Revit is open; the manifest takes effect on next start.
        $assemblyHash = (Get-FileHash -LiteralPath $builtAssembly -Algorithm SHA256).Hash.Substring(0, 12).ToLowerInvariant()
        $assembly = Join-Path $assemblyDirectory ("BimCadMcp.Revit.{0}.dll" -f $assemblyHash)
        Copy-Item -LiteralPath $builtAssembly -Destination $assembly -Force
    }
    finally {
        if (Test-Path -LiteralPath $buildOutput) { Remove-Item -LiteralPath $buildOutput -Recurse -Force -ErrorAction SilentlyContinue }
    }

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
    Write-Step ("Installed Revit add-in {0} and manifest {1}. Restart Revit to load it." -f (Split-Path -Leaf $assembly), $manifestPath)
}

function Test-RevitSetup {
    $installed = Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Autodesk\Revit 2024\RevitAPI.dll')
    if ($installed) { Write-Step 'Revit 2024 installation detected.' }
    else { Write-Step 'Revit 2024 was not detected.' }

    $manifest = Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2024\BimCadMcp.addin'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) { Write-Step 'Revit 2024 MCP add-in manifest is installed.' }
    else { Write-Step 'Revit 2024 MCP add-in manifest is not installed yet.' }

    $codex = Get-OptionalCommand 'codex'
    if ($codex) {
        $registration = Invoke-External $codex @('mcp','get','revit') -AllowFailure
        if ($registration.ExitCode -eq 0) { Write-Step 'Codex has a Revit MCP registration.' }
        else { Write-Step 'The Revit MCP server is not registered yet.' }
    }
    else { Write-Step 'Codex command was not detected.' }

    $pipeName = 'BimCadMcp.Revit.2024'
    $sessionDirectory = Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\runtime\revit-sessions'
    if (Test-Path -LiteralPath $sessionDirectory -PathType Container) {
        foreach ($sessionFile in @(Get-ChildItem -LiteralPath $sessionDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $session = Get-Content -LiteralPath $sessionFile.FullName -Raw | ConvertFrom-Json
                if ([string]$session.revit_version -eq '2024') {
                    $null = Get-Process -Id ([int]$session.pid) -ErrorAction Stop
                    $pipeName = [string]$session.pipe_name
                    break
                }
            }
            catch { }
        }
    }
    $client = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(250)
        Write-Step ("Live Revit 2024 add-in connection is available on {0}." -f $pipeName)
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

    if ($Action -eq 'TeamStatus') {
        $root = Get-Repository
        $submitter = Join-Path $root 'scripts\submit-team-knowledge.ps1'
        if (-not (Test-Path -LiteralPath $submitter -PathType Leaf)) { throw "Team submitter is missing: $submitter" }
        $git = Get-OptionalCommand 'git'
        $gh = Get-OptionalCommand 'gh'
        if ($git) { Write-Step 'Git is installed.' } else { Write-Step 'Git is required for automatic team collection.' }
        if ($gh) {
            $auth = Invoke-External $gh @('auth','status','--hostname','github.com') -AllowFailure
            if ($auth.ExitCode -eq 0) { Write-Step 'GitHub CLI is authenticated.' }
            else { Write-Step 'GitHub CLI is installed but not authenticated. Run: gh auth login --hostname github.com' }
        }
        else { Write-Step 'GitHub CLI is required. Install it, then run: gh auth login --hostname github.com' }
        Write-Step 'In Codex, ask: Use cad-team-knowledge-approval to enable my daily team knowledge collection.'
        Write-Step 'Codex will create the per-user daily automation only after that user asks for it.'
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
            $null = Get-RequiredCommand 'codex'
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
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
