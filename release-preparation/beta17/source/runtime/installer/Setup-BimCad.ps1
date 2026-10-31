[CmdletBinding()]
param(
    [ValidateSet('Status', 'Install', 'Update', 'Test', 'Collect', 'TeamStatus', 'RemoteStatus', 'CheckUpdate', 'EnableNotifications', 'DisableNotifications', 'ConnectGitHub')]
    [string]$Action = 'Status',

    [ValidateSet('All', 'AutoCAD', 'Revit')]
    [string]$Product = 'All',

    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/Autodesk-MCP.git',

    [string]$ReleaseManifestUrl = 'https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json',

    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),

    [switch]$SkipRepositoryUpdate,

    [switch]$LibraryOnly,

    [switch]$InstallGitIfMissing,

    [switch]$InstallClaudeDesktopIfMissing,

    [string]$EnrollmentPath = '',

    # Typed by the person in the team join dialog; used only with a TEAM build's installer\team-join.json.
    [string]$JoinName = '',

    [string]$JoinEmail = '',

    # Version of the terms of use the person accepted in the setup window; sent when joining the team.
    [string]$TermsVersion = ''
)

$ErrorActionPreference = 'Stop'
$updateStateDirectory = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
$updateStatePath = Join-Path $updateStateDirectory 'update-state.json'
$updateTaskName = 'Autodesk MCP Connector Update Alerts'

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

# Machine-readable progress for the setup window (SetupWizard.ps1 ConvertFrom-SetupOutputLine).
function Write-InstallPhase {
    param([string]$Step)
    Write-Host ("[PHASE] {0}" -f $Step)
}

function Write-InstallResult {
    param([string]$Step, [ValidateSet('ok', 'skipped', 'failed')][string]$Status, [string]$Detail = '')
    Write-Host ("[RESULT] {0}={1} {2}" -f $Step, $Status, $Detail).TrimEnd()
}

function Get-Sha256Hex {
    param([string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function ConvertTo-ConnectorVersionInfo {
    param([string]$Version)

    $normalized = ([string]$Version).Trim().TrimStart([char]0xFEFF)
    if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    $match = [regex]::Match($normalized, '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<prerelease>[A-Za-z0-9.-]+))?$')
    if (-not $match.Success) {
        throw "Invalid connector version: $Version"
    }

    [pscustomobject]@{
        Normalized = $normalized
        Major = [System.Numerics.BigInteger]::Parse($match.Groups['major'].Value)
        Minor = [System.Numerics.BigInteger]::Parse($match.Groups['minor'].Value)
        Patch = [System.Numerics.BigInteger]::Parse($match.Groups['patch'].Value)
        PreRelease = $match.Groups['prerelease'].Value
    }
}

function Compare-ConnectorVersion {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftVersion = ConvertTo-ConnectorVersionInfo $Left
    $rightVersion = ConvertTo-ConnectorVersionInfo $Right
    foreach ($property in @('Major', 'Minor', 'Patch')) {
        $comparison = $leftVersion.$property.CompareTo($rightVersion.$property)
        if ($comparison -ne 0) { return [Math]::Sign($comparison) }
    }

    if ([string]::IsNullOrWhiteSpace($leftVersion.PreRelease) -and [string]::IsNullOrWhiteSpace($rightVersion.PreRelease)) { return 0 }
    if ([string]::IsNullOrWhiteSpace($leftVersion.PreRelease)) { return 1 }
    if ([string]::IsNullOrWhiteSpace($rightVersion.PreRelease)) { return -1 }

    $leftParts = @($leftVersion.PreRelease.Split('.'))
    $rightParts = @($rightVersion.PreRelease.Split('.'))
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if ($index -ge $leftParts.Count) { return -1 }
        if ($index -ge $rightParts.Count) { return 1 }
        $leftPart = $leftParts[$index]
        $rightPart = $rightParts[$index]
        $leftNumeric = $leftPart -cmatch '^\d+$'
        $rightNumeric = $rightPart -cmatch '^\d+$'
        if ($leftNumeric -and $rightNumeric) {
            $comparison = ([System.Numerics.BigInteger]::Parse($leftPart)).CompareTo([System.Numerics.BigInteger]::Parse($rightPart))
        }
        elseif ($leftNumeric) { $comparison = -1 }
        elseif ($rightNumeric) { $comparison = 1 }
        else { $comparison = [StringComparer]::Ordinal.Compare($leftPart, $rightPart) }
        if ($comparison -ne 0) { return [Math]::Sign($comparison) }
    }
    0
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
    if ($Name -eq 'git') {
        $candidates = @(
            (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
            (Join-Path $env:ProgramFiles 'Git\cmd\git.cmd'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.cmd')
        )
        if (${env:ProgramFiles(x86)}) {
            $candidates += @(
                (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.cmd')
            )
        }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
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
        $output | ForEach-Object { Write-Host $_ }
    }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"
        if ([string]::IsNullOrWhiteSpace($details)) { $details = 'The command returned no diagnostic output.' }
        $operation = (@($Arguments | Select-Object -First 2) -join ' ')
        throw "$FilePath [$operation] failed with exit code $exitCode.`r`n$details"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Install-GitForWindows {
    $git = Get-OptionalCommand 'git'
    if ($git) { return $git }

    $winget = Get-OptionalCommand 'winget'
    if (-not $winget) {
        throw 'Git is required for optional team knowledge submission, and Windows Package Manager was not found. Install Git for Windows from https://git-scm.com/download/win, then reopen the connector.'
    }

    Write-Step 'Installing Git for Windows for optional team knowledge submission...'
    $installed = Invoke-External $winget @(
        'install', '--id', 'Git.Git', '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
    ) -AllowFailure

    $git = Get-OptionalCommand 'git'
    if (-not $git) {
        $details = ($installed.Output | ForEach-Object { $_.ToString() }) -join "`r`n"
        throw "Git installation did not finish. Install Git for Windows and reopen the connector.`r`n$details"
    }
    Write-Step 'Git for Windows is installed.'
    $git
}

function Get-PrivateRepositoryGit {
    param([switch]$AllowInstall)

    $git = Get-OptionalCommand 'git'
    if (-not $git -and $AllowInstall) {
        $git = Install-GitForWindows
    }
    if (-not $git) {
        throw 'Git is required only for optional team knowledge submission. Allow the connector to install Git or install Git for Windows, then retry.'
    }

    Write-Step 'Checking access to the private GitHub repository...'
    Write-Step 'If GitHub opens, sign in with an account that can access EhabHassan007/Autodesk-MCP.'
    $oldInteractive = $env:GCM_INTERACTIVE
    $oldProvider = $env:GCM_PROVIDER
    $oldModes = $env:GCM_GITHUB_AUTHMODES
    try {
        $env:GCM_INTERACTIVE = 'always'
        $env:GCM_PROVIDER = 'github'
        $env:GCM_GITHUB_AUTHMODES = 'browser,device'
        $access = Invoke-External $git @('ls-remote', $RepositoryUrl, 'refs/heads/main') -AllowFailure
    }
    finally {
        if ($null -eq $oldInteractive) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue } else { $env:GCM_INTERACTIVE = $oldInteractive }
        if ($null -eq $oldProvider) { Remove-Item Env:GCM_PROVIDER -ErrorAction SilentlyContinue } else { $env:GCM_PROVIDER = $oldProvider }
        if ($null -eq $oldModes) { Remove-Item Env:GCM_GITHUB_AUTHMODES -ErrorAction SilentlyContinue } else { $env:GCM_GITHUB_AUTHMODES = $oldModes }
    }
    if ($access.ExitCode -ne 0) {
        $details = ($access.Output | ForEach-Object { $_.ToString() }) -join "`r`n"
        throw "GitHub sign-in or private repository access failed. Sign in as an authorized account and retry.`r`n$details"
    }
    $line = @($access.Output | ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ -match '^[0-9a-fA-F]{40}\s+refs/heads/main$' }) | Select-Object -First 1
    if (-not $line) {
        throw 'GitHub authentication succeeded, but the approved main branch was not returned.'
    }
    Write-Step 'Private GitHub repository access passed.'
    $git
}

function Read-UpdateState {
    if (-not (Test-Path -LiteralPath $updateStatePath -PathType Leaf)) {
        return [pscustomobject]@{
            repository = $RepositoryUrl
            release_manifest = $ReleaseManifestUrl
            installed_version = ''
            installed_sha256 = ''
            installed_commit = ''
            # Automatic updates are on by default; only an explicit choice in Settings turns them off.
            notifications_enabled = $true
            notifications_user_disabled = $false
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

function Set-StateProperty {
    param(
        [object]$State,
        [string]$Name,
        [object]$Value
    )

    if ($State.PSObject.Properties.Name -contains $Name) {
        $State.$Name = $Value
    }
    else {
        $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Write-UpdateState {
    param([object]$State)

    New-Item -ItemType Directory -Path $updateStateDirectory -Force | Out-Null
    $State | ConvertTo-Json | Set-Content -LiteralPath $updateStatePath -Encoding UTF8
}

function Get-PublicReleaseManifest {
    Write-Step 'Checking the Smart Autodesk Connector release channel...'
    try { $manifestUri = [Uri]$ReleaseManifestUrl }
    catch { throw "The release manifest address is invalid: $ReleaseManifestUrl" }
    if ($manifestUri.Scheme -ne 'https') {
        throw 'The release manifest must use HTTPS.'
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -Uri $manifestUri.AbsoluteUri -UseBasicParsing
        $content = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString([byte[]]$response.Content)
        }
        else { [string]$response.Content }
        $manifest = $content.TrimStart([char]0xFEFF) | ConvertFrom-Json
    }
    catch {
        throw "Could not read the public release channel. $($_.Exception.Message)"
    }

    try { $version = (ConvertTo-ConnectorVersionInfo ([string]$manifest.version)).Normalized }
    catch { throw 'The public release manifest contains an invalid version.' }
    $downloadUrl = ([string]$manifest.download_url).Trim()
    $sha256 = ([string]$manifest.sha256).Trim().ToUpperInvariant()
    if ($sha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'The public release manifest contains an invalid SHA-256 checksum.'
    }
    try { $downloadUri = [Uri]$downloadUrl }
    catch { throw 'The public release manifest contains an invalid download address.' }
    if ($downloadUri.Scheme -ne 'https') {
        throw 'The public release download must use HTTPS.'
    }

    [pscustomobject]@{
        Version = $version
        DownloadUrl = $downloadUri.AbsoluteUri
        Sha256 = $sha256
    }
}

function Get-InstalledVersion {
    $versionPath = Join-Path $RepositoryPath 'VERSION'
    if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
        return (Get-Content -LiteralPath $versionPath -Raw).Trim()
    }
    ''
}

function Set-InstalledRelease {
    param(
        [string]$Version,
        [string]$Sha256 = ''
    )

    $state = Read-UpdateState
    Set-StateProperty $state 'repository' $RepositoryUrl
    Set-StateProperty $state 'release_manifest' $ReleaseManifestUrl
    Set-StateProperty $state 'installed_version' $Version
    Set-StateProperty $state 'installed_sha256' $Sha256
    Set-StateProperty $state 'last_checked_utc' ([DateTime]::UtcNow.ToString('o'))
    Write-UpdateState $state
}

function Test-ApprovedUpdate {
    $release = Get-PublicReleaseManifest
    $state = Read-UpdateState
    $installedVersion = Get-InstalledVersion
    Set-StateProperty $state 'repository' $RepositoryUrl
    Set-StateProperty $state 'release_manifest' $ReleaseManifestUrl
    Set-StateProperty $state 'installed_version' $installedVersion
    Set-StateProperty $state 'last_checked_utc' ([DateTime]::UtcNow.ToString('o'))
    # The agent and the Revit add-in read this to say "version X is ready" without going online again.
    $newer = -not [string]::IsNullOrWhiteSpace($installedVersion) -and (Compare-ConnectorVersion -Left $release.Version -Right $installedVersion) -gt 0
    Set-StateProperty $state 'available_version' $(if ($newer) { $release.Version } else { '' })
    Write-UpdateState $state

    if ([string]::IsNullOrWhiteSpace($installedVersion)) {
        Write-Output ("[{0}] [UPDATE_STATUS_UNKNOWN] Press Install / Repair to complete this installation." -f (Get-Date -Format 'HH:mm:ss'))
        return
    }
    $comparison = Compare-ConnectorVersion -Left $release.Version -Right $installedVersion
    if ($comparison -gt 0) {
        Write-Output ("[{0}] [UPDATE_AVAILABLE] Version {1} is available." -f (Get-Date -Format 'HH:mm:ss'), $release.Version)
        return
    }
    if ($comparison -lt 0) {
        Write-Output ("[{0}] [UP_TO_DATE] Installed version {1} is newer than public version {2}; no downgrade will be performed." -f (Get-Date -Format 'HH:mm:ss'), $installedVersion, $release.Version)
        return
    }
    Write-Output ("[{0}] [UP_TO_DATE] Smart Autodesk Connector {1} and approved skills are up to date." -f (Get-Date -Format 'HH:mm:ss'), $installedVersion)
}

function Remove-LegacyUpdateTask {
    # Before the connector agent, a separate scheduled task installed updates at 9:00; the agent replaces it.
    if (Get-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $updateTaskName -Confirm:$false
    }
}

# The connector agent (scripts\connector-agent.ps1) reads this switch; it never needs network access here.
function Enable-UpdateNotifications {
    $state = Read-UpdateState
    Set-StateProperty $state 'repository' $RepositoryUrl
    Set-StateProperty $state 'release_manifest' $ReleaseManifestUrl
    Set-StateProperty $state 'installed_version' (Get-InstalledVersion)
    Set-StateProperty $state 'notifications_enabled' $true
    Set-StateProperty $state 'notifications_user_disabled' $false
    Write-UpdateState $state
    Remove-LegacyUpdateTask
    Write-Step 'Automatic updates are on: updates install by themselves when Revit and AutoCAD are closed.'
}

function Disable-UpdateNotifications {
    Remove-LegacyUpdateTask
    $state = Read-UpdateState
    Set-StateProperty $state 'notifications_enabled' $false
    Set-StateProperty $state 'notifications_user_disabled' $true
    Write-UpdateState $state
    Write-Step 'Automatic updates are off. Use Check Updates to look for a new version.'
}

function Get-RunningAutodeskApps {
    @(Get-Process -Name 'Revit', 'acad' -ErrorAction SilentlyContinue | ForEach-Object { if ($_.ProcessName -eq 'acad') { 'AutoCAD' } else { 'Revit' } } | Sort-Object -Unique)
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
            foreach ($name in @('skill-review', 'team-candidates', 'team-collection', 'backups')) {
                $saved = Join-Path $backupPath $name
                $destination = Join-Path $RepositoryPath $name
                if ($repositoryMoved -and (Test-Path -LiteralPath $saved) -and -not (Test-Path -LiteralPath $destination)) {
                    Move-Item -LiteralPath $saved -Destination $destination
                }
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

function Sync-ApprovedGitRepository {
    param([string]$Git)

    Write-Step 'Downloading the newest approved setup and skills from GitHub...'
    $configured = Invoke-External $Git @('-C', $RepositoryPath, 'remote', 'set-url', 'origin', $RepositoryUrl)
    $null = $configured
    $fetched = Invoke-External $Git @('-C', $RepositoryPath, 'fetch', '--prune', 'origin', 'main')
    $null = $fetched

    # Install / Repair can copy a packaged beta over an older installed Git checkout.
    # Treat this folder as a managed installation and restore its tracked files from
    # the approved main branch. Untracked review packages and team candidates remain.
    Write-Step 'Refreshing packaged connector files from the approved update channel...'
    $reset = Invoke-External $Git @('-C', $RepositoryPath, 'reset', '--hard', 'origin/main')
    $null = $reset
    $checkedOut = Invoke-External $Git @('-C', $RepositoryPath, 'checkout', '-B', 'main', 'origin/main')
    $null = $checkedOut
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
            foreach ($name in @('skill-review', 'team-candidates', 'team-collection', 'backups')) {
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

function Install-PublicRelease {
    param([object]$Release)

    Assert-SafeRepositoryPath
    if (-not $Release) { $Release = Get-PublicReleaseManifest }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("autodesk-mcp-release-{0}" -f [Guid]::NewGuid().ToString('N'))
    $releaseArchive = Join-Path $temporaryRoot 'release.zip'
    $outerRoot = Join-Path $temporaryRoot 'outer'
    $payloadRoot = Join-Path $temporaryRoot 'payload'
    $backupPath = "$RepositoryPath.previous-$PID"
    $repositoryMoved = $false

    New-Item -ItemType Directory -Path $outerRoot, $payloadRoot -Force | Out-Null
    try {
        Write-Step ("Downloading approved public release {0}..." -f $Release.Version)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $null = Invoke-WebRequest -Uri $Release.DownloadUrl -OutFile $releaseArchive -UseBasicParsing
        if (-not (Test-Path -LiteralPath $releaseArchive -PathType Leaf) -or (Get-Item -LiteralPath $releaseArchive).Length -eq 0) {
            throw 'The public release download is empty.'
        }

        $actualHash = (Get-Sha256Hex -Path $releaseArchive).ToUpperInvariant()
        if (-not $actualHash.Equals($Release.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Release checksum verification failed. Expected $($Release.Sha256), received $actualHash."
        }
        Write-Step 'Release checksum verification passed.'

        Expand-Archive -LiteralPath $releaseArchive -DestinationPath $outerRoot -Force
        $payloadArchive = Get-ChildItem -LiteralPath $outerRoot -Filter 'Autodesk-MCP-Payload.zip' -File -Recurse | Select-Object -First 1
        if (-not $payloadArchive) {
            throw 'The public release does not contain Autodesk-MCP-Payload.zip.'
        }
        Expand-Archive -LiteralPath $payloadArchive.FullName -DestinationPath $payloadRoot -Force
        $downloadedRoot = Get-ChildItem -LiteralPath $payloadRoot -Directory -Recurse |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.agents\skills') -PathType Container } |
            Select-Object -First 1
        if (-not $downloadedRoot) {
            throw 'The public release payload does not contain the approved skill library.'
        }
        $payloadVersion = (Get-Content -LiteralPath (Join-Path $downloadedRoot.FullName 'VERSION') -Raw).Trim()
        if (-not $payloadVersion.Equals($Release.Version, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Release version verification failed. Manifest says $($Release.Version), payload says $payloadVersion."
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
            foreach ($name in @('skill-review', 'team-candidates', 'team-collection', 'backups')) {
                $saved = Join-Path $backupPath $name
                $destination = Join-Path $RepositoryPath $name
                if ($repositoryMoved -and (Test-Path -LiteralPath $saved) -and -not (Test-Path -LiteralPath $destination)) {
                    Move-Item -LiteralPath $saved -Destination $destination
                }
            }
            [ordered]@{
                release_manifest = $ReleaseManifestUrl
                version = $Release.Version
                sha256 = $Release.Sha256
                downloaded_utc = [DateTime]::UtcNow.ToString('o')
                method = 'public-release'
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
        Set-InstalledRelease -Version $Release.Version -Sha256 $Release.Sha256
        (Resolve-Path -LiteralPath $RepositoryPath).Path
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
            foreach ($entry in @('installer','scripts','src','assets','.agents','README.md','REMOTE-CLAUDE.md','SKILL-SUBMISSIONS.md','VERSION','TESTING.md')) {
                $item = Join-Path $source $entry
                if (Test-Path -LiteralPath $item) {
                    Copy-Item -LiteralPath $item -Destination $destination -Recurse -Force
                }
            }
            # The team join code stays in the downloaded installer only, even when joining was skipped.
            $copiedJoin = Join-Path $destination 'installer\team-join.json'
            if (Test-Path -LiteralPath $copiedJoin -PathType Leaf) { Remove-Item -LiteralPath $copiedJoin -Force }
        }
        Set-InstalledRelease -Version ((Get-Content -LiteralPath (Join-Path $destination 'VERSION') -Raw).Trim())
        return $destination
    }
    $manifest = Join-Path $RepositoryPath '.agents\skills'
    if ($SkipRepositoryUpdate) {
        if (-not (Test-Path -LiteralPath $manifest -PathType Container)) {
            throw "No valid BIM-CAD MCP repository exists at $RepositoryPath."
        }
        return (Resolve-Path -LiteralPath $RepositoryPath).Path
    }

    if ($Action -eq 'Install' -and (Test-Path -LiteralPath $manifest -PathType Container)) {
        Set-InstalledRelease -Version (Get-InstalledVersion)
        return (Resolve-Path -LiteralPath $RepositoryPath).Path
    }

    $script:UpdateDownloaded = $false
    $release = Get-PublicReleaseManifest
    if ($Action -eq 'Update') {
        $installedVersion = Get-InstalledVersion
        if (-not [string]::IsNullOrWhiteSpace($installedVersion)) {
            $comparison = Compare-ConnectorVersion -Left $release.Version -Right $installedVersion
            if ($comparison -le 0) {
                if ($comparison -lt 0) {
                    Write-Step ("Installed version {0} is newer than public version {1}; the update was skipped to prevent a downgrade." -f $installedVersion, $release.Version)
                }
                else {
                    Write-Step ("Smart Autodesk Connector {0} is already up to date." -f $installedVersion)
                }
                return (Resolve-Path -LiteralPath $RepositoryPath).Path
            }
        }
    }
    $installedRoot = Install-PublicRelease -Release $release
    $script:UpdateDownloaded = $true
    return $installedRoot

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

function Test-OwnConnectorEntry {
    param([string]$Text)
    # Only entries that launch this connector's own bridges count as duplicates; another
    # tool's server with a similar name is left alone.
    $Text -match '(?i)BIM-CAD-MCP|autodesk-bridge\.ps1|autocad-bridge\.ps1|revit-bridge\.ps1'
}

function Remove-LegacyMcpEntries {
    param([string]$Client, [string]$Command, [string[]]$LegacyNames, [string[]]$RemoveArguments = @())
    foreach ($legacy in $LegacyNames) {
        $existing = Invoke-External $Command @('mcp', 'get', $legacy) -AllowFailure
        if ($existing.ExitCode -ne 0 -or -not (Test-OwnConnectorEntry ($existing.Output -join "`n"))) { continue }
        $removed = Invoke-External $Command (@('mcp', 'remove', $legacy) + $RemoveArguments) -AllowFailure
        if ($removed.ExitCode -eq 0) { Write-Step ("Removed the older duplicate {0} MCP entry '{1}'." -f $Client, $legacy) }
    }
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
        # Read-only verification avoids rewriting an already correct registration.
        $existing = Invoke-External $codex @('mcp', 'get', $Name, '--json') -AllowFailure
        if ($existing.ExitCode -eq 0) {
            try {
                $entry = ($existing.Output -join "`n") | ConvertFrom-Json
                $expectedArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Bridge) + $BridgeArguments
                if ($entry.enabled -ne $false -and $entry.transport.command -eq 'powershell.exe' -and
                    (($entry.transport.args | ConvertTo-Json -Compress) -ceq ($expectedArgs | ConvertTo-Json -Compress))) {
                    Write-Step 'The Smart Autodesk Connector registration in Codex is already correct.'
                    Remove-LegacyMcpEntries 'Codex' $codex $LegacyNames
                    return
                }
            }
            catch { Write-Step 'Existing Codex registration could not be compared; registering the requested command.' }
        }
        Remove-LegacyMcpEntries 'Codex' $codex $LegacyNames
        # mcp add replaces this named entry and leaves unrelated servers alone.
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

function Get-ClaudeDesktopInstallation {
    $candidatePaths = @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\Claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Claude\Claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Claude.exe'),
        (Join-Path $env:ProgramFiles 'Claude\Claude.exe')
    )
    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [pscustomobject]@{ Installed=$true; Executable=$candidate; Source='file' }
        }
    }

    # AppX package enumeration may be blocked in restricted Windows sessions.
    # The package data directory is sufficient evidence that Claude Desktop is
    # installed, while its MCP config still belongs in roaming AppData.
    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -LiteralPath $packagesRoot -PathType Container) {
        $packageDirectory = Get-ChildItem -LiteralPath $packagesRoot -Directory -Filter '*Claude*' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($packageDirectory) {
            return [pscustomobject]@{ Installed=$true; Executable=''; Source='appx-directory' }
        }
    }

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
        if ($match) {
            $executable = ''
            $displayIcon = ([string]$match.DisplayIcon).Trim().Trim('"') -replace ',\d+$', ''
            if ($displayIcon -and (Test-Path -LiteralPath $displayIcon -PathType Leaf)) {
                $executable = $displayIcon
            }
            elseif ($match.InstallLocation) {
                $installedCandidate = Join-Path ([string]$match.InstallLocation) 'Claude.exe'
                if (Test-Path -LiteralPath $installedCandidate -PathType Leaf) {
                    $executable = $installedCandidate
                }
            }
            return [pscustomobject]@{ Installed=$true; Executable=$executable; Source='uninstall-registry' }
        }
    }

    try {
        $package = @(Get-AppxPackage -ErrorAction Stop | Where-Object {
            $_.Name -like '*Claude*' -or $_.PackageFamilyName -like '*Claude*'
        }) | Select-Object -First 1
        if ($package) {
            $executable = ''
            foreach ($relativePath in @('Claude.exe', 'app\Claude.exe')) {
                $candidate = Join-Path ([string]$package.InstallLocation) $relativePath
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $executable = $candidate
                    break
                }
            }
            return [pscustomobject]@{ Installed=$true; Executable=$executable; Source='appx' }
        }
    }
    catch { }

    $null
}

function Test-ClaudeDesktopInstalled {
    $null -ne (Get-ClaudeDesktopInstallation)
}

function Get-ClaudeDesktopConfigPath {
    Join-Path (Join-Path $env:APPDATA 'Claude') 'claude_desktop_config.json'
}

function Get-ClaudeDesktopConfigPaths {
    $paths = @((Get-ClaudeDesktopConfigPath))
    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -LiteralPath $packagesRoot -PathType Container) {
        foreach ($package in @(Get-ChildItem -LiteralPath $packagesRoot -Directory -Filter '*Claude*' -ErrorAction SilentlyContinue)) {
            $paths += Join-Path $package.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json'
        }
    }
    $paths | Select-Object -Unique
}

function Get-ClaudeDesktopProcesses {
    @(
        Get-Process -Name 'Claude' -ErrorAction SilentlyContinue |
            Where-Object {
                $path = ''
                try { $path = [string]$_.Path } catch { }
                $_.MainWindowTitle -match 'Claude' -or
                    $path -match '(?i)\\(?:AnthropicClaude|Programs\\Claude|WindowsApps\\[^\\]*Claude|Claude)\\'
            }
    )
}

function Restart-ClaudeDesktopIfRunning {
    param(
        [object[]]$Processes,
        [object]$Installation
    )

    $running = @($Processes | Where-Object { $_ -and -not $_.HasExited })
    if ($running.Count -eq 0) { return }

    $launchPath = @(
        $running | ForEach-Object {
            try { if ($_.Path) { [string]$_.Path } } catch { }
        }
        if ($Installation -and $Installation.Executable) { [string]$Installation.Executable }
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1

    Write-Step 'Restarting Claude Desktop so it loads the Smart Autodesk Connector registration...'
    foreach ($process in $running) {
        try { $null = $process.CloseMainWindow() } catch { }
    }
    Start-Sleep -Seconds 2
    foreach ($process in $running) {
        try {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
        }
        catch { Write-Step ("Claude Desktop process {0} could not be stopped automatically." -f $process.Id) }
    }

    try {
        if ($launchPath) {
            Start-Process -FilePath $launchPath | Out-Null
            Write-Step 'Claude Desktop restarted successfully.'
            return
        }
        $startApp = Get-StartApps -ErrorAction Stop |
            Where-Object { $_.Name -match '^Claude(?: Desktop)?$' -or $_.Name -match '^Anthropic Claude' } |
            Select-Object -First 1
        if ($startApp -and $startApp.AppID) {
            Start-Process -FilePath ("shell:AppsFolder\{0}" -f $startApp.AppID) | Out-Null
            Write-Step 'Claude Desktop restarted successfully.'
            return
        }
        Write-Step 'Claude Desktop was closed to reload the connector. Open it again from the Start menu.'
    }
    catch {
        Write-Step ("Claude Desktop was closed to reload the connector, but automatic relaunch failed: {0}" -f $_.Exception.Message)
    }
}

function Install-ClaudeDesktop {
    $installed = Get-ClaudeDesktopInstallation
    if ($installed) { return $installed }

    $winget = Get-OptionalCommand 'winget'
    if (-not $winget) {
        throw 'Claude Desktop is required for a local Revit connection, but Windows Package Manager was not found. Install Claude Desktop from https://claude.com/download, then run Install / Repair again.'
    }

    Write-Step 'Claude Desktop is not installed. Installing the official Anthropic package for the current Windows user...'
    $result = Invoke-External $winget @(
        'install', '--id', 'Anthropic.Claude', '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
    ) -AllowFailure
    if ($result.ExitCode -ne 0) {
        $details = ($result.Output | ForEach-Object { $_.ToString() }) -join "`r`n"
        throw "Claude Desktop installation failed.`r`n$details"
    }

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $installed = Get-ClaudeDesktopInstallation
        if ($installed) {
            Write-Step 'Claude Desktop is installed. The Smart Autodesk Connector registration will now be added.'
            return $installed
        }
        Start-Sleep -Seconds 1
    }
    Write-Step 'Windows completed the Claude Desktop installation, but its executable is not enumerable yet. Continuing with the standard per-user MCP registration.'
    [pscustomobject]@{ Installed=$true; Executable=''; Source='winget' }
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
        Remove-LegacyMcpEntries 'Claude Code' $claude $LegacyNames @('--scope', 'user')
        $existing = Invoke-External $claude @('mcp','get',$Name) -AllowFailure
        if ($existing.ExitCode -eq 0) {
            $removed = Invoke-External $claude @('mcp','remove',$Name,'--scope','user') -AllowFailure
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
        [string[]]$BridgeArguments = @(),
        [string[]]$LegacyNames = @(),
        [string]$ConfigPath = (Get-ClaudeDesktopConfigPath)
    )

    if (-not (Test-Path -LiteralPath $Bridge -PathType Leaf)) {
        throw "MCP bridge is missing: $Bridge"
    }

    $claudeDirectory = Split-Path -Parent $configPath
    $backupPath = "$configPath.autodesk-mcp-$PID.bak"
    $temporaryPath = "$configPath.autodesk-mcp-$PID.tmp"
    New-Item -ItemType Directory -Path $claudeDirectory -Force | Out-Null
    $hadConfig = Test-Path -LiteralPath $configPath -PathType Leaf
    if ($hadConfig) { Copy-Item -LiteralPath $configPath -Destination $backupPath -Force }

    Write-Step ("Registering the {0} local MCP server in Claude Desktop at {1}..." -f $Name, $configPath)
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

        foreach ($legacyName in $LegacyNames) {
            if ($config.mcpServers.PSObject.Properties[$legacyName]) {
                $config.mcpServers.PSObject.Properties.Remove($legacyName)
                Write-Step ("Removed legacy Claude Desktop MCP registration: {0}." -f $legacyName)
            }
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

        [IO.File]::WriteAllText($temporaryPath, ($config | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
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
    $legacyNames = @('autocad','revit','AutoCAD MCP','Revit Connector','revit-mcp')
    # Claude Desktop shows the key as the connector's name; the previous product name is retired.
    $claudeDesktopLegacyNames = @($legacyNames + 'autodesk' + 'Autodesk MCP Connector')
    $detected = 0
    $registrationErrors = @()

    $claudeDesktopProcesses = @(Get-ClaudeDesktopProcesses)
    $claudeDesktopInstallation = Get-ClaudeDesktopInstallation

    Write-InstallPhase 'codex'
    if (Get-OptionalCommand 'codex') {
        try {
            Register-McpServer 'autodesk' $bridge $arguments $legacyNames
            $detected++
            Write-InstallResult 'codex' 'ok'
        }
        catch {
            $registrationErrors += 'Codex: ' + $_.Exception.Message
            Write-Warning ('Codex registration failed; continuing with other clients: ' + $_.Exception.Message)
            Write-InstallResult 'codex' 'failed' 'see the setup log'
        }
    }
    else { Write-Step 'Codex was not detected, so its MCP registration was skipped.'; Write-InstallResult 'codex' 'skipped' 'Codex is not installed' }

    Write-InstallPhase 'claude_code'
    if (Get-OptionalCommand 'claude') {
        try {
            Register-ClaudeCodeMcpServer 'autodesk' $bridge $arguments $legacyNames
            $detected++
            Write-InstallResult 'claude_code' 'ok'
        }
        catch {
            $registrationErrors += 'Claude Code: ' + $_.Exception.Message
            Write-Warning ('Claude Code registration failed; continuing with Claude Desktop: ' + $_.Exception.Message)
            Write-InstallResult 'claude_code' 'failed' 'see the setup log'
        }
    }
    else { Write-Step 'Claude Code was not detected, so its MCP registration was skipped.'; Write-InstallResult 'claude_code' 'skipped' 'Claude Code is not installed' }

    Write-InstallPhase 'claude_desktop'
    if ($InstallClaudeDesktopIfMissing -and -not $claudeDesktopInstallation) {
        $claudeDesktopInstallation = Install-ClaudeDesktop
    }
    if ($claudeDesktopInstallation -or $InstallClaudeDesktopIfMissing) {
        $desktopFailed = $false
        foreach ($configPath in @(Get-ClaudeDesktopConfigPaths)) {
            try {
                Register-ClaudeDesktopMcpServer -Name 'Smart Autodesk Connector' -Bridge $bridge -BridgeArguments $arguments -LegacyNames $claudeDesktopLegacyNames -ConfigPath $configPath
                $detected++
            }
            catch {
                $desktopFailed = $true
                $registrationErrors += ('Claude Desktop at {0}: {1}' -f $configPath, $_.Exception.Message)
                Write-Warning ('Could not update Claude config at {0}; continuing with other paths.' -f $configPath)
            }
        }
        Write-InstallResult 'claude_desktop' $(if ($desktopFailed) { 'failed' } else { 'ok' }) $(if ($desktopFailed) { 'see the setup log' } else { 'Claude restarts to load it' })
        Restart-ClaudeDesktopIfRunning -Processes $claudeDesktopProcesses -Installation $claudeDesktopInstallation
    }
    else {
        Write-Step 'Claude Desktop was not detected. Its local MCP registration was skipped; Claude web and mobile require the separate remote connector.'
        Write-InstallResult 'claude_desktop' 'skipped' 'Claude Desktop is not installed'
    }

    if ($registrationErrors.Count -gt 0) {
        throw ('Some AI client registrations failed. Other registrations were still attempted. Repair these clients and run setup again: ' + ($registrationErrors -join '; '))
    }

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
        if ($registration.ExitCode -eq 0) { Write-Step 'Codex has the Smart Autodesk Connector registration.' }
        else { Write-Step 'Smart Autodesk Connector is not registered yet.' }
    }
    else { Write-Step 'Codex command was not detected.' }

    $claude = Get-OptionalCommand 'claude'
    if ($claude) {
        $registration = Invoke-External $claude @('mcp','get','autodesk') -AllowFailure
        if ($registration.ExitCode -eq 0) { Write-Step 'Claude Code has the Smart Autodesk Connector registration.' }
        else { Write-Step 'Smart Autodesk Connector is not registered in Claude Code yet.' }
    }
    else { Write-Step 'Claude Code command was not detected.' }

    if (Test-ClaudeDesktopInstalled) {
        $configPath = Get-ClaudeDesktopConfigPath
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($config.mcpServers.PSObject.Properties['Smart Autodesk Connector']) {
                Write-Step ("Claude Desktop has the Smart Autodesk Connector registration at {0}." -f $configPath)
            }
            else { Write-Step 'Smart Autodesk Connector is not registered in Claude Desktop yet.' }
        }
        catch { Write-Step 'Claude Desktop was detected, but its local MCP configuration is missing or invalid.' }
    }
    else { Write-Step 'Claude Desktop was not detected. Its local MCP registration is not installed; Claude web and mobile require the separate remote connector.' }
}

function Test-RemoteClaudeSetup {
    param([string]$Root)

    $statusScript = Join-Path $Root 'src\autodesk\Get-AutodeskMcpRemoteConnection.ps1'
    if (-not (Test-Path -LiteralPath $statusScript -PathType Leaf)) {
        Write-Step 'Remote Claude gateway component is not installed.'
        return
    }
    try {
        $remote = & $statusScript 2>$null | Select-Object -Last 1
        if ($null -eq $remote) {
            Write-Step 'Remote Claude gateway is not configured on this workstation.'
            return
        }
        if ($remote.GatewayRunning -and $remote.TunnelRunning) {
            Write-Step ("Remote Claude gateway is running at {0}." -f $remote.PublicUrl)
        }
        else {
            Write-Step ("Remote Claude gateway is configured at {0}, but one or more background processes are stopped." -f $remote.PublicUrl)
        }
    }
    catch { Write-Step 'Remote Claude gateway is not configured on this workstation.' }
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
        $assemblyHash = (Get-Sha256Hex -Path $builtAssembly).Substring(0, 12).ToLowerInvariant()
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
    <Name>Smart Autodesk Connector</Name>
    <Assembly>$escapedAssembly</Assembly>
    <AddInId>2DCE7E67-4495-4F3B-A740-3D7C9D2DA124</AddInId>
    <FullClassName>BimCadMcp.Revit.Application</FullClassName>
    <VendorId>BIMC</VendorId>
    <VendorDescription>Smart Autodesk Connector for Codex and Claude</VendorDescription>
  </AddIn>
</RevitAddIns>
"@
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8
    if (Test-Path -LiteralPath $legacyManifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $legacyManifestPath -Force
    }
    Remove-OldRevitAddinBuilds -Directory $assemblyDirectory -Keep $assembly
    Write-Step ("Installed Revit add-in {0} and manifest {1}. Restart Revit to load it." -f (Split-Path -Leaf $assembly), $manifestPath)
}

function Remove-OldRevitAddinBuilds {
    param([string]$Directory, [string]$Keep)
    # Every build gets a content-hashed name; older ones pile up. A copy Revit still has loaded is
    # locked and simply stays until the next install.
    foreach ($old in @(Get-ChildItem -LiteralPath $Directory -Filter 'BimCadMcp.Revit.*.dll' -File -ErrorAction SilentlyContinue)) {
        if ([string]::Equals($old.FullName, $Keep, [StringComparison]::OrdinalIgnoreCase)) { continue }
        try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop } catch { }
    }
}

function Test-RevitSetup {
    $installed = Test-Revit2024Installed
    if ($installed) { Write-Step 'Revit 2024 installation detected.' }
    else { Write-Step 'Revit 2024 was not detected.' }

    $manifest = Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2024\AutodeskMcpConnector.addin'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) { Write-Step 'Smart Autodesk Connector add-in is installed for Revit 2024.' }
    else { Write-Step 'Smart Autodesk Connector add-in is not installed for Revit 2024 yet.' }
    if ($installed) { Write-Step 'In Revit, open the Smart Autodesk Connector ribbon tab and click Connection Status.' }

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

function Remove-PlaintextFileSecurely {
    param([string]$Path)

    # Overwrite before deleting so the token does not stay in freed disk space. SSD wear levelling
    # can still retain old blocks, so deployment tools must not keep their own copies either.
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.IsReadOnly) { $item.IsReadOnly = $false }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = New-Object byte[] 4096
        $remaining = [int64]$item.Length
        while ($remaining -gt 0) {
            $count = [int][Math]::Min($remaining, $buffer.Length)
            $random.GetBytes($buffer)
            $stream.Write($buffer, 0, $count)
            $remaining -= $count
        }
        $stream.Flush($true)
    }
    finally {
        $random.Dispose()
        $stream.Dispose()
    }
    Remove-Item -LiteralPath $Path -Force
}

function Import-SkillServiceEnrollment {
    param(
        [string]$Root,
        [string]$Path = $EnrollmentPath,
        [string[]]$SearchDirectories = @($PSScriptRoot, (Split-Path -Parent $PSScriptRoot))
    )

    $serviceConfig = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\service.json'
    $explicit = -not [string]::IsNullOrWhiteSpace($Path)
    $candidates = if ($explicit) { @($Path) } else {
        foreach ($directory in $SearchDirectories) {
            foreach ($name in @('enrollment.json', 'skill-service-device.json')) { Join-Path $directory $name }
        }
    }
    $file = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $file) {
        if ($explicit) {
            Write-Step ("[ENROLLMENT_MISSING] Enrollment file not found: {0}. Central skill sharing stays pending." -f $Path)
        }
        elseif (Test-Path -LiteralPath $serviceConfig -PathType Leaf) {
            Write-Step '[ENROLLMENT_UNCHANGED] No enrollment file supplied. The existing central skill sharing enrollment is kept.'
            return 'AlreadyEnrolled'
        }
        else {
            Write-Step '[ENROLLMENT_PENDING] No enrollment file supplied. Central skill sharing waits for administrator enrollment.'
        }
        return 'Missing'
    }

    Write-Step ("Importing central skill sharing enrollment from {0}..." -f (Split-Path -Leaf $file))
    $status = 'Failed'
    try {
        $initializer = Join-Path $Root 'scripts\Initialize-SkillService.ps1'
        if (-not (Test-Path -LiteralPath $initializer -PathType Leaf)) { throw "Enrollment initializer is missing: $initializer" }
        # Parse here first: PowerShell JSON errors quote the input, which could copy the token into setup.log.
        try { $null = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json }
        catch { throw 'The enrollment file is not valid JSON.' }
        $previous = if (Test-Path -LiteralPath $serviceConfig -PathType Leaf) { (Get-Item -LiteralPath $serviceConfig).LastWriteTimeUtc } else { $null }
        $output = @(& $initializer -ConfigPath $file)
        if (-not (Test-Path -LiteralPath $serviceConfig -PathType Leaf) -or
            ($previous -and (Get-Item -LiteralPath $serviceConfig).LastWriteTimeUtc -eq $previous)) {
            throw 'The initializer did not write service.json.'
        }
        $output | ForEach-Object { Write-Step ([string]$_) }
        Write-Step '[ENROLLMENT_OK] Central skill sharing is enrolled for this Windows user.'
        $status = 'Enrolled'
    }
    catch {
        Write-Step ("[ENROLLMENT_FAILED] {0} Central skill sharing stays pending. Ask your administrator for a new enrollment file." -f $_.Exception.Message)
    }
    finally {
        # The plaintext token must not stay on disk, even when the import failed.
        try {
            Remove-PlaintextFileSecurely -Path $file
            Write-Step '[ENROLLMENT_FILE_REMOVED] The plaintext enrollment file was overwritten and deleted.'
        }
        catch {
            Write-Step ("[ENROLLMENT_FILE_NOT_REMOVED] Delete the plaintext enrollment file manually: {0} ({1})" -f $file, $_.Exception.Message)
        }
    }
    return $status
}

function Register-SkillServiceDevice {
    param(
        [string]$Root,
        [string]$Name = $JoinName,
        [string]$Email = $JoinEmail,
        [string]$JoinConfigPath = (Join-Path $PSScriptRoot 'team-join.json')
    )

    $state = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
    if (Test-Path -LiteralPath (Join-Path $state 'service.json') -PathType Leaf) {
        Write-Step '[ENROLLMENT_UNCHANGED] This PC already belongs to the team skill service.'
        return 'AlreadyEnrolled'
    }
    $headers = @{}
    try {
        if (-not (Test-Path -LiteralPath $JoinConfigPath -PathType Leaf)) { throw 'This installer has no team join code. Ask your administrator for the team installer.' }
        try { $join = Get-Content -LiteralPath $JoinConfigPath -Raw | ConvertFrom-Json }
        catch { throw 'The team join file in this installer is damaged.' }
        $uri = [Uri]([string]$join.service_url)
        if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'The team join file has an invalid service address.' }
        $versionPath = Join-Path $Root 'VERSION'
        $version = if (Test-Path -LiteralPath $versionPath) { (Get-Content -LiteralPath $versionPath -Raw).Trim() } else { 'unknown' }
        $profile = @{ name = $Name.Trim(); email = $Email.Trim(); pc_name = $env:COMPUTERNAME; windows_user = $env:USERNAME; connector_version = $version }
        if ($TermsVersion -match '^[0-9A-Za-z.-]{1,20}$') { $profile.terms_version = $TermsVersion }
        $body = $profile | ConvertTo-Json -Compress
        $headers = @{ Authorization = 'Bearer ' + [string]$join.join_code; 'X-Connector-Version' = $version }
        Write-Step ("Joining the team skill service as {0}..." -f $Name.Trim())
        try {
            $device = Invoke-RestMethod -Uri ($uri.AbsoluteUri.TrimEnd('/') + '/v1/enroll') -Method Post -Headers $headers -UserAgent "Autodesk-MCP-Connector/$version" `
                -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
        }
        catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            # The service's error detail never contains secrets; it explains validation problems.
            $detail = ''
            try { $detail = [string]($_.ErrorDetails.Message | ConvertFrom-Json).detail } catch { }
            $reason = switch ($code) {
                0 { 'The team skill service could not be reached. Check the internet connection and run setup again.' }
                403 { 'The team join code was not accepted; this installer may be out of date. Ask your administrator for the current team installer.' }
                429 { 'Too many join attempts from this network. Wait an hour and run setup again.' }
                default { if ($detail) { $detail } else { "The team skill service refused the request (HTTP $code)." } }
            }
            throw $reason
        }
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $file = Join-Path $state ("enrollment-{0}.json" -f [guid]::NewGuid().ToString('N'))
        @{ service_url = $uri.AbsoluteUri.TrimEnd('/'); device_id = [string]$device.device_id; device_token = [string]$device.device_token } | ConvertTo-Json |
            Set-Content -LiteralPath $file -Encoding UTF8
        $device = $null
        # Reuses the admin-file path: DPAPI import, [ENROLLMENT_*] logging and secure deletion.
        return (Import-SkillServiceEnrollment -Root $Root -Path $file -SearchDirectories @())
    }
    catch {
        Write-Step ("[ENROLLMENT_FAILED] {0} Installation continues without central skill sharing." -f $_.Exception.Message)
        return 'Failed'
    }
    finally {
        $headers.Authorization = $null
        # Don't leave the team code in the permanent install; the installer itself is the only copy.
        $installedCopy = Join-Path $RepositoryPath 'installer\team-join.json'
        if (Test-Path -LiteralPath $installedCopy -PathType Leaf) { Remove-Item -LiteralPath $installedCopy -Force }
    }
}

if ($LibraryOnly) { return }

try {
    Write-Step ("Smart Autodesk Connector - {0}" -f $Action)

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

    if ($Action -eq 'ConnectGitHub') {
        $null = Get-PrivateRepositoryGit -AllowInstall:$InstallGitIfMissing
        Write-Step 'GitHub connection is ready. Skill submissions use your GitHub identity automatically; no name or email commands are needed.'
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
        if (-not $git -and $InstallGitIfMissing) {
            $git = Install-GitForWindows
        }
        if ($git) {
            Write-Step 'Git is installed.'
            try {
                $git = Get-PrivateRepositoryGit
                Write-Step 'Git authentication can access the private repository.'
            }
            catch { Write-Step $_.Exception.Message }
        }
        else { Write-Step 'Git is required for automatic team collection.' }
        Write-Step 'In Codex, ask: Use cad-team-knowledge-approval to enable my daily team knowledge collection.'
        Write-Step 'Codex will create the per-user daily automation only after that user asks for it.'
        exit 0
    }

    if ($Action -eq 'RemoteStatus') {
        $installedManifest = Join-Path $RepositoryPath 'src\autodesk\Get-AutodeskMcpRemoteConnection.ps1'
        $root = if (Test-Path -LiteralPath $installedManifest -PathType Leaf) {
            (Resolve-Path -LiteralPath $RepositoryPath).Path
        }
        else { Get-Repository }
        Test-RemoteClaudeSetup $root
        exit 0
    }

    switch ($Action) {
        'Status' {
            if ($Product -in @('All','AutoCAD')) { Test-AutoCadSetup }
            if ($Product -in @('All','Revit')) { Test-RevitSetup }
            Test-AutodeskRegistration
            Test-RemoteClaudeSetup $(if (Test-Path -LiteralPath $RepositoryPath) { $RepositoryPath } else { (Split-Path -Parent $PSScriptRoot) })
        }
        'Test' {
            if ($Product -in @('All','AutoCAD')) { Test-AutoCadSetup }
            if ($Product -in @('All','Revit')) { Test-RevitSetup }
            Test-AutodeskRegistration
            Test-RemoteClaudeSetup $(if (Test-Path -LiteralPath $RepositoryPath) { $RepositoryPath } else { (Split-Path -Parent $PSScriptRoot) })
        }
        'Install' {
            Write-InstallPhase 'files'
            $root = Get-Repository
            Write-InstallResult 'files' 'ok'
            Write-InstallPhase 'skills'
            Install-Skills $root
            Write-InstallResult 'skills' 'ok'
            Write-InstallPhase 'team'
            # An administrator's enrollment file wins; otherwise the setup window's details are used.
            if ($JoinName -and $JoinEmail -and [string]::IsNullOrWhiteSpace($EnrollmentPath)) { $null = Register-SkillServiceDevice -Root $root }
            else { $null = Import-SkillServiceEnrollment -Root $root }
            Write-InstallPhase 'revit'
            if ($Product -in @('All','Revit') -and (Test-Revit2024Installed)) {
                Install-RevitAddin $root
                Write-InstallResult 'revit' 'ok' 'restart Revit to load it'
            }
            elseif ($Product -in @('All','Revit')) {
                Write-Step 'Revit 2024 was not detected, so its add-in was skipped.'
                Write-InstallResult 'revit' 'skipped' 'Revit 2024 is not installed'
            }
            Write-InstallPhase 'updates'
            $updateState = Read-UpdateState
            if ($updateState.PSObject.Properties['notifications_user_disabled'] -and $updateState.notifications_user_disabled) {
                Write-InstallResult 'updates' 'skipped' 'switched off in Settings'
            }
            else {
                Enable-UpdateNotifications
                Write-InstallResult 'updates' 'ok'
            }
            Register-DetectedAiClients $root
            if ($Product -in @('All','AutoCAD')) { Test-AutoCadSetup }
            if ($Product -in @('All','Revit')) { Test-RevitSetup }
            Test-AutodeskRegistration
            Write-Step 'Setup complete. Restart Codex, Claude, and any running Revit session, then open AutoCAD or Revit.'
        }
        'Update' {
            # Revit and AutoCAD keep connector files open; replacing the install folder under them fails.
            $openApps = Get-RunningAutodeskApps
            if ($openApps.Count) {
                Write-Output ("[{0}] [UPDATE_DEFERRED] {1} is open. The update installs automatically after you close it." -f (Get-Date -Format 'HH:mm:ss'), ($openApps -join ' and '))
                break
            }
            $script:UpdateDownloaded = $false
            $root = Get-Repository
            $null = Import-SkillServiceEnrollment -Root $root
            if (-not $script:UpdateDownloaded) {
                Write-Step 'No newer release was installed. Existing client registrations were preserved. Use Install / Repair to repair connections.'
                break
            }
            Install-Skills $root
            if ($Product -in @('All','Revit') -and (Test-Revit2024Installed)) {
                Install-RevitAddin $root
            }
            elseif ($Product -in @('All','Revit')) {
                Write-Step 'Revit 2024 was not detected, so its add-in was skipped.'
            }
            Register-DetectedAiClients $root
            Set-InstalledRelease -Version ((Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()) `
                -Sha256 $(if ((Test-Path -LiteralPath (Join-Path $root '.bim-cad-source.json'))) {
                    [string]((Get-Content -LiteralPath (Join-Path $root '.bim-cad-source.json') -Raw | ConvertFrom-Json).sha256)
                } else { '' })
            Write-Output ("[{0}] [UPDATE_INSTALLED] Smart Autodesk Connector {1} is installed." -f (Get-Date -Format 'HH:mm:ss'), (Get-InstalledVersion))
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
