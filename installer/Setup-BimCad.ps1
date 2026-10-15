[CmdletBinding()]
param(
    [ValidateSet('Status', 'Install', 'Update', 'Test', 'Collect', 'TeamStatus', 'CheckUpdate', 'EnableNotifications', 'DisableNotifications')]
    [string]$Action = 'Status',

    [ValidateSet('All', 'AutoCAD', 'Revit')]
    [string]$Product = 'All',

    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/Autodesk-MCP.git',

    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),

    [switch]$SkipRepositoryUpdate,

    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
$updateStateDirectory = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
$updateStatePath = Join-Path $updateStateDirectory 'update-state.json'
$updateTaskName = 'Autodesk MCP Connector Update Alerts'

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
    if ($Name -eq 'claude') {
        $candidates = @(
            (Join-Path $HOME '.local\bin\claude.exe'),
            (Join-Path $env:APPDATA 'npm\claude.cmd'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Claude Code\claude.exe')
        )
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

function Read-UpdateState {
    if (-not (Test-Path -LiteralPath $updateStatePath -PathType Leaf)) {
        return [pscustomobject]@{
            repository = $RepositoryUrl
            installed_commit = ''
            notifications_enabled = $false
            last_checked_utc = ''
        }
    }
    try {
        Get-Content -LiteralPath $updateStatePath -Raw | ConvertFrom-Json
    }
    catch {
        throw "The connector update state is damaged: $updateStatePath"
    }
}

function Write-UpdateState {
    param([object]$State)

    New-Item -ItemType Directory -Path $updateStateDirectory -Force | Out-Null
    $State | ConvertTo-Json | Set-Content -LiteralPath $updateStatePath -Encoding UTF8
}

function Get-RemoteMainCommit {
    $git = Get-RequiredCommand 'git'
    $result = Invoke-External $git @('ls-remote', $RepositoryUrl, 'refs/heads/main') -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw 'Git cannot check the private repository. Sign in through Git Credential Manager and retry.'
    }
    $line = @($result.Output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }) | Select-Object -First 1
    if (-not $line -or $line -notmatch '^([0-9a-fA-F]{40})\s+refs/heads/main$') {
        throw 'GitHub did not return the approved main branch revision.'
    }
    $Matches[1].ToLowerInvariant()
}

function Set-InstalledCommit {
    param([string]$Commit)

    $state = Read-UpdateState
    $state.repository = $RepositoryUrl
    $state.installed_commit = $Commit
    $state.last_checked_utc = [DateTime]::UtcNow.ToString('o')
    Write-UpdateState $state
}

function Test-ApprovedUpdate {
    $remoteCommit = Get-RemoteMainCommit
    $state = Read-UpdateState
    $state.repository = $RepositoryUrl
    $state.last_checked_utc = [DateTime]::UtcNow.ToString('o')
    Write-UpdateState $state

    if ([string]::IsNullOrWhiteSpace([string]$state.installed_commit)) {
        Write-Step '[UPDATE_STATUS_UNKNOWN] Press Update once to connect this installation to the approved main channel.'
        return
    }
    if (-not $remoteCommit.Equals([string]$state.installed_commit, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Step '[UPDATE_AVAILABLE] Approved connector or skill updates are available. Press Update to install them.'
        return
    }
    Write-Step '[UP_TO_DATE] Autodesk MCP Connector and approved skills are up to date.'
}

function Enable-UpdateNotifications {
    $remoteCommit = Get-RemoteMainCommit
    $state = Read-UpdateState
    if ([string]::IsNullOrWhiteSpace([string]$state.installed_commit)) {
        $state.installed_commit = $remoteCommit
    }
    $state.repository = $RepositoryUrl
    $state.notifications_enabled = $true
    $state.last_checked_utc = [DateTime]::UtcNow.ToString('o')
    Write-UpdateState $state

    $notifier = Join-Path $RepositoryPath 'scripts\autodesk-mcp-update-notifier.ps1'
    if (-not (Test-Path -LiteralPath $notifier -PathType Leaf)) {
        throw "The update notifier is missing: $notifier"
    }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -RepositoryUrl "{1}" -RepositoryPath "{2}"' -f $notifier, $RepositoryUrl, $RepositoryPath
    $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskTrigger = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $identity),
        (New-ScheduledTaskTrigger -Daily -At '09:00')
    )
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $updateTaskName -Action $taskAction -Trigger $taskTrigger -Principal $principal -Description 'Notify the signed-in user when approved Autodesk MCP Connector or skill updates are available.' -Force | Out-Null
    Write-Step 'Automatic update alerts are enabled at sign-in and daily at 9:00 AM. Updates still require the user to press Update.'
}

function Disable-UpdateNotifications {
    $task = Get-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $updateTaskName -Confirm:$false
    }
    $state = Read-UpdateState
    $state.notifications_enabled = $false
    Write-UpdateState $state
    Write-Step 'Daily update alerts are disabled.'
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

function Test-GitRepository {
    param(
        [string]$Git,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $result = Invoke-External $Git @('-C', $Path, 'rev-parse', '--is-inside-work-tree') -AllowFailure
    $result.ExitCode -eq 0 -and (@($result.Output | ForEach-Object { $_.ToString().Trim() }) -contains 'true')
}

function Install-RepositoryClone {
    param([string]$Git)

    Assert-SafeRepositoryPath
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("autodesk-mcp-clone-{0}" -f [Guid]::NewGuid().ToString('N'))
    $downloadedRoot = Join-Path $temporaryRoot 'repository'
    $backupPath = "$RepositoryPath.previous-$PID"
    $repositoryMoved = $false

    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    try {
        Write-Step 'Downloading the approved main version through Git...'
        $cloned = Invoke-External $Git @('clone', '--depth', '1', '--branch', 'main', '--single-branch', $RepositoryUrl, $downloadedRoot)
        $null = $cloned
        if (-not (Test-Path -LiteralPath (Join-Path $downloadedRoot '.agents\skills') -PathType Container)) {
            throw 'The downloaded repository does not contain .agents\skills.'
        }

        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Recurse -Force
        }
        if (Test-Path -LiteralPath $RepositoryPath) {
            Move-Item -LiteralPath $RepositoryPath -Destination $backupPath
            $repositoryMoved = $true
        }
        try {
            Move-Item -LiteralPath $downloadedRoot -Destination $RepositoryPath
            foreach ($name in @('skill-review', 'team-candidates', 'backups')) {
                $saved = Join-Path $backupPath $name
                $destination = Join-Path $RepositoryPath $name
                if ($repositoryMoved -and (Test-Path -LiteralPath $saved) -and -not (Test-Path -LiteralPath $destination)) {
                    Move-Item -LiteralPath $saved -Destination $destination
                }
            }
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
            foreach ($entry in @('installer','scripts','src','.agents','README.md','SKILL-SUBMISSIONS.md','VERSION','TESTING.md')) {
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
        if (Test-GitRepository -Git $git -Path $RepositoryPath) {
            Write-Step 'Downloading the newest setup and skills from GitHub...'
            $result = Invoke-External $git @('-C', $RepositoryPath, 'pull', '--ff-only', 'origin', 'main')
            $null = $result
        }
        else {
            if (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git') -PathType Container) {
                Write-Step 'The installed Git metadata is incomplete. Rebuilding the local copy safely...'
            }
            Install-RepositoryClone -Git $git
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
    Write-Step 'Installing all saved skills for Codex...'
    $result = Invoke-External 'powershell.exe' @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $syncScript, '-Action', 'Install')
    $null = $result

    $claudeSkills = Join-Path $HOME '.claude\skills'
    Write-Step 'Installing the same saved skills for Claude Code...'
    $result = Invoke-External 'powershell.exe' @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $syncScript, '-Action', 'Install', '-Destination', $claudeSkills)
    $null = $result
}

function Register-McpServer {
    param(
        [string]$Name,
        [string]$Bridge,
        [string[]]$BridgeArguments = @(),
        [string[]]$LegacyNames = @()
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
        foreach ($legacyName in $LegacyNames) {
            $legacy = Invoke-External $codex @('mcp', 'get', $legacyName) -AllowFailure
            if ($legacy.ExitCode -eq 0) {
                $removedLegacy = Invoke-External $codex @('mcp', 'remove', $legacyName)
                $null = $removedLegacy
                Write-Step ("Removed legacy MCP registration: {0}." -f $legacyName)
            }
        }
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

function Test-ClaudeDesktopInstalled {
    $claudeDirectory = Join-Path $env:APPDATA 'Claude'
    if (Test-Path -LiteralPath $claudeDirectory -PathType Container) { return $true }

    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $match = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { [string]$_.DisplayName -match '^Claude(?: Desktop)?$' } |
            Select-Object -First 1
        if ($match) { return $true }
    }
    $false
}

function Register-ClaudeCodeMcpServer {
    param(
        [string]$Name,
        [string]$Bridge,
        [string[]]$BridgeArguments = @(),
        [string[]]$LegacyNames = @()
    )

    $claude = Get-OptionalCommand 'claude'
    if (-not $claude) {
        Write-Step 'Claude Code was not detected, so its MCP registration was skipped.'
        return
    }
    if (-not (Test-Path -LiteralPath $Bridge -PathType Leaf)) {
        throw "MCP bridge is missing: $Bridge"
    }

    $configPath = Join-Path $HOME '.claude.json'
    $backupPath = "$configPath.autodesk-mcp-$PID.bak"
    $hadConfig = Test-Path -LiteralPath $configPath -PathType Leaf
    if ($hadConfig) { Copy-Item -LiteralPath $configPath -Destination $backupPath -Force }

    Write-Step ("Registering the {0} MCP server in Claude Code..." -f $Name)
    try {
        foreach ($legacyName in $LegacyNames) {
            foreach ($scope in @('local','user')) {
                $removedLegacy = Invoke-External $claude @('mcp','remove',$legacyName,'--scope',$scope) -AllowFailure
                if ($removedLegacy.ExitCode -eq 0) {
                    Write-Step ("Removed legacy Claude MCP registration: {0} ({1})." -f $legacyName, $scope)
                }
            }
        }
        foreach ($scope in @('local','user')) {
            $removed = Invoke-External $claude @('mcp','remove',$Name,'--scope',$scope) -AllowFailure
            $null = $removed
        }

        $command = @(
            'mcp', 'add', '--transport', 'stdio', '--scope', 'user', $Name, '--',
            'powershell.exe', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', $Bridge
        ) + $BridgeArguments
        $added = Invoke-External $claude $command
        $null = $added
        $verified = Invoke-External $claude @('mcp','get',$Name)
        $null = $verified
    }
    catch {
        if ($hadConfig) {
            Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
        }
        elseif (Test-Path -LiteralPath $configPath) {
            Remove-Item -LiteralPath $configPath -Force
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
    }
}

function Register-ClaudeDesktopMcpServer {
    param(
        [string]$Name,
        [string]$Bridge,
        [string[]]$BridgeArguments = @()
    )

    if (-not (Test-ClaudeDesktopInstalled)) {
        Write-Step 'Claude Desktop was not detected, so its local MCP registration was skipped.'
        return
    }
    if (-not (Test-Path -LiteralPath $Bridge -PathType Leaf)) {
        throw "MCP bridge is missing: $Bridge"
    }

    $claudeDirectory = Join-Path $env:APPDATA 'Claude'
    $configPath = Join-Path $claudeDirectory 'claude_desktop_config.json'
    $backupPath = "$configPath.autodesk-mcp-$PID.bak"
    $temporaryPath = "$configPath.autodesk-mcp-$PID.tmp"
    New-Item -ItemType Directory -Path $claudeDirectory -Force | Out-Null
    $hadConfig = Test-Path -LiteralPath $configPath -PathType Leaf
    if ($hadConfig) { Copy-Item -LiteralPath $configPath -Destination $backupPath -Force }

    Write-Step ("Registering the {0} local MCP server in Claude Desktop..." -f $Name)
    try {
        $config = if ($hadConfig) {
            Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        }
        else { [pscustomobject]@{} }

        if (-not $config.PSObject.Properties['mcpServers']) {
            $config | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([pscustomobject]@{})
        }
        elseif ($null -eq $config.mcpServers) {
            $config.mcpServers = [pscustomobject]@{}
        }

        $entry = [pscustomobject][ordered]@{
            command = 'powershell.exe'
            args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Bridge) + $BridgeArguments
        }
        if ($config.mcpServers.PSObject.Properties[$Name]) {
            $config.mcpServers.PSObject.Properties[$Name].Value = $entry
        }
        else {
            $config.mcpServers | Add-Member -MemberType NoteProperty -Name $Name -Value $entry
        }

        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        $null = Get-Content -LiteralPath $temporaryPath -Raw | ConvertFrom-Json
        if ($hadConfig) {
            Copy-Item -LiteralPath $temporaryPath -Destination $configPath -Force
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $configPath
        }
    }
    catch {
        if ($hadConfig -and (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
        }
        elseif (-not $hadConfig -and (Test-Path -LiteralPath $configPath)) {
            Remove-Item -LiteralPath $configPath -Force
        }
        throw "Claude Desktop registration failed. $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
    }
}

function Register-DetectedAiClients {
    param([string]$Root)

    $bridge = Join-Path $Root 'src\autodesk\autodesk-bridge.ps1'
    $arguments = @('-RevitVersion','2024')
    $legacyNames = @('autocad','revit')
    $detected = 0

    if (Get-OptionalCommand 'codex') {
        Register-McpServer 'autodesk' $bridge $arguments $legacyNames
        $detected++
    }
    else { Write-Step 'Codex was not detected, so its MCP registration was skipped.' }

    if (Get-OptionalCommand 'claude') {
        Register-ClaudeCodeMcpServer 'autodesk' $bridge $arguments $legacyNames
        $detected++
    }
    else { Write-Step 'Claude Code was not detected, so its MCP registration was skipped.' }

    if (Test-ClaudeDesktopInstalled) {
        Register-ClaudeDesktopMcpServer 'autodesk' $bridge $arguments
        $detected++
    }
    else { Write-Step 'Claude Desktop was not detected, so its local MCP registration was skipped.' }

    if ($detected -eq 0) {
        Write-Step 'No supported AI client was detected. Connector files and skills were installed; run Install / Repair after installing Codex or Claude.'
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

function Test-AutodeskRegistration {
    $codex = Get-OptionalCommand 'codex'
    if ($codex) {
        $registration = Invoke-External $codex @('mcp','get','autodesk') -AllowFailure
        if ($registration.ExitCode -eq 0) { Write-Step 'Codex has the Autodesk MCP Connector registration.' }
        else { Write-Step 'Autodesk MCP Connector is not registered yet.' }
    }
    else { Write-Step 'Codex command was not detected.' }

    $claude = Get-OptionalCommand 'claude'
    if ($claude) {
        $registration = Invoke-External $claude @('mcp','get','autodesk') -AllowFailure
        if ($registration.ExitCode -eq 0) { Write-Step 'Claude Code has the Autodesk MCP Connector registration.' }
        else { Write-Step 'Autodesk MCP Connector is not registered in Claude Code yet.' }
    }
    else { Write-Step 'Claude Code command was not detected.' }

    if (Test-ClaudeDesktopInstalled) {
        $configPath = Join-Path (Join-Path $env:APPDATA 'Claude') 'claude_desktop_config.json'
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($config.mcpServers.PSObject.Properties['autodesk']) {
                Write-Step 'Claude Desktop has the Autodesk MCP Connector registration.'
            }
            else { Write-Step 'Autodesk MCP Connector is not registered in Claude Desktop yet.' }
        }
        catch { Write-Step 'Claude Desktop was detected, but its local MCP configuration is missing or invalid.' }
    }
    else { Write-Step 'Claude Desktop was not detected.' }
}

function Test-Revit2024Installed {
    Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Autodesk\Revit 2024\RevitAPI.dll') -PathType Leaf
}

function Install-RevitAddin {
    param([string]$Root)

    $revitPath = Join-Path $env:ProgramFiles 'Autodesk\Revit 2024'
    if (-not (Test-Revit2024Installed)) {
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
    $manifestPath = Join-Path $manifestDirectory 'AutodeskMcpConnector.addin'
    $legacyManifestPath = Join-Path $manifestDirectory 'BimCadMcp.addin'
    $escapedAssembly = [Security.SecurityElement]::Escape($assembly)
    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<RevitAddIns>
  <AddIn Type="Application">
    <Name>Autodesk MCP Connector</Name>
    <Assembly>$escapedAssembly</Assembly>
    <AddInId>2DCE7E67-4495-4F3B-A740-3D7C9D2DA124</AddInId>
    <FullClassName>BimCadMcp.Revit.Application</FullClassName>
    <VendorId>BIMC</VendorId>
    <VendorDescription>Autodesk MCP Connector for local Revit sessions</VendorDescription>
  </AddIn>
</RevitAddIns>
"@
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8
    if (Test-Path -LiteralPath $legacyManifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $legacyManifestPath -Force
    }
    Write-Step ("Installed Revit add-in {0} and manifest {1}. Restart Revit to load it." -f (Split-Path -Leaf $assembly), $manifestPath)
}

function Test-RevitSetup {
    $installed = Test-Revit2024Installed
    if ($installed) { Write-Step 'Revit 2024 installation detected.' }
    else { Write-Step 'Revit 2024 was not detected.' }

    $manifest = Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2024\AutodeskMcpConnector.addin'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) { Write-Step 'Autodesk MCP Connector add-in is installed for Revit 2024.' }
    else { Write-Step 'Autodesk MCP Connector add-in is not installed for Revit 2024 yet.' }
    if ($installed) { Write-Step 'In Revit, open the Autodesk MCP Connector ribbon tab and click Connection Status.' }

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

if ($LibraryOnly) { return }

try {
    Write-Step ("Autodesk MCP Connector - {0}" -f $Action)

    if ($Action -eq 'Collect') {
        $root = Get-Repository
        $collector = Join-Path $root 'scripts\collect-skills-for-review.ps1'
        Write-Step 'Collecting local user skills for review without uploading them...'
        $collected = Invoke-External 'powershell.exe' @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$collector,'-RepositoryRoot',$root)
        $null = $collected
        exit 0
    }

    if ($Action -eq 'CheckUpdate') {
        Test-ApprovedUpdate
        exit 0
    }

    if ($Action -eq 'EnableNotifications') {
        Enable-UpdateNotifications
        exit 0
    }

    if ($Action -eq 'DisableNotifications') {
        Disable-UpdateNotifications
        exit 0
    }

    if ($Action -eq 'TeamStatus') {
        $installedManifest = Join-Path $RepositoryPath '.agents\skills'
        if (Test-Path -LiteralPath $installedManifest -PathType Container) {
            $root = (Resolve-Path -LiteralPath $RepositoryPath).Path
        }
        else {
            $root = Get-Repository
        }
        $submitter = Join-Path $root 'scripts\submit-team-knowledge.ps1'
        if (-not (Test-Path -LiteralPath $submitter -PathType Leaf)) { throw "Team submitter is missing: $submitter" }
        $git = Get-OptionalCommand 'git'
        if ($git) {
            Write-Step 'Git is installed.'
            $access = Invoke-External $git @('ls-remote',$RepositoryUrl,'HEAD') -AllowFailure
            if ($access.ExitCode -eq 0) { Write-Step 'Git authentication can access the private repository.' }
            else { Write-Step 'Git cannot access the private repository. Sign in through Git Credential Manager and retry.' }
        }
        else { Write-Step 'Git is required for automatic team collection.' }
        Write-Step 'In Codex, ask: Use cad-team-knowledge-approval to enable my daily team knowledge collection.'
        Write-Step 'Codex will create the per-user daily automation only after that user asks for it.'
        exit 0
    }

    switch ($Action) {
        'Status' {
            if ($Product -in @('All','AutoCAD')) { Test-AutoCadSetup }
            if ($Product -in @('All','Revit')) { Test-RevitSetup }
            Test-AutodeskRegistration
        }
        'Test' {
            if ($Product -in @('All','AutoCAD')) { Test-AutoCadSetup }
            if ($Product -in @('All','Revit')) { Test-RevitSetup }
            Test-AutodeskRegistration
        }
        'Install' {
            $root = Get-Repository
            Install-Skills $root
            if ($Product -in @('All','Revit') -and (Test-Revit2024Installed)) {
                Install-RevitAddin $root
            }
            elseif ($Product -in @('All','Revit')) {
                Write-Step 'Revit 2024 was not detected, so its add-in was skipped.'
            }
            Register-DetectedAiClients $root
            if ($Product -in @('All','AutoCAD')) { Test-AutoCadSetup }
            if ($Product -in @('All','Revit')) { Test-RevitSetup }
            Test-AutodeskRegistration
            Write-Step 'Setup complete. Restart Codex, Claude, and any running Revit session, then open AutoCAD or Revit.'
        }
        'Update' {
            $root = Get-Repository
            Install-Skills $root
            if ($Product -in @('All','Revit') -and (Test-Revit2024Installed)) {
                Install-RevitAddin $root
            }
            elseif ($Product -in @('All','Revit')) {
                Write-Step 'Revit 2024 was not detected, so its add-in was skipped.'
            }
            Register-DetectedAiClients $root
            Set-InstalledCommit (Get-RemoteMainCommit)
            Write-Step 'Skills and Autodesk MCP Connector are up to date. Restart Codex, Claude, and any running Revit session.'
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
