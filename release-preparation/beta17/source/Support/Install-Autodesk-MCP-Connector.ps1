[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
# Started from the 32-bit setup .exe, this 64-bit PowerShell can inherit the 32-bit Program Files paths;
# use the real ones so Revit, AutoCAD and Git are found.
if ([Environment]::Is64BitProcess -and $env:ProgramW6432) { $env:ProgramFiles = $env:ProgramW6432 }
if ([Environment]::Is64BitProcess -and $env:CommonProgramW6432) { $env:CommonProgramFiles = $env:CommonProgramW6432 }
Add-Type -AssemblyName System.Windows.Forms
$payload = Join-Path $PSScriptRoot 'Autodesk-MCP-Payload.zip'
# Unpacked into one fixed folder, not %TEMP%, so a single antivirus exclusion covers setup. Removed afterwards.
$setupRoot = Join-Path $env:LOCALAPPDATA 'SmartConnectorSetup'
$temporaryRoot = Join-Path $setupRoot ("payload-{0}" -f [Guid]::NewGuid().ToString('N'))
$logDirectory = Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector'
$logPath = Join-Path $logDirectory 'setup.log'

function Show-SetupMessage {
    param(
        [string]$Message,
        [System.Windows.Forms.MessageBoxIcon]$Icon
    )

    $owner = New-Object System.Windows.Forms.Form
    $owner.ShowInTaskbar = $false
    $owner.TopMost = $true
    $owner.StartPosition = 'CenterScreen'
    $owner.Size = New-Object System.Drawing.Size(1, 1)
    $owner.Opacity = 0
    try {
        $owner.Show()
        $owner.Activate()
        [System.Windows.Forms.MessageBox]::Show(
            $owner, $Message, 'Smart Connector',
            [System.Windows.Forms.MessageBoxButtons]::OK, $Icon
        ) | Out-Null
    }
    finally {
        $owner.Close()
        $owner.Dispose()
    }
}

try {
    if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) {
        throw "The installation payload is missing: $payload"
    }
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Expand-Archive -LiteralPath $payload -DestinationPath $temporaryRoot -Force
    $packageRoot = Join-Path $temporaryRoot 'Autodesk-MCP-Payload'
    $setup = Join-Path $packageRoot 'installer\BIM-CAD-Setup.ps1'
    $coreSetup = Join-Path $packageRoot 'installer\Setup-BimCad.ps1'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf) -or
        -not (Test-Path -LiteralPath $coreSetup -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $packageRoot '.agents\skills') -PathType Container)) {
        throw 'The Smart Connector installation payload is invalid.'
    }

    if ($SmokeTest) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $setup -SmokeTest
        if ($LASTEXITCODE -ne 0) { throw "Smart Connector smoke test stopped with exit code $LASTEXITCODE." }
    }
    elseif ($Install) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        "[{0}] Starting Smart Connector installation." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
            Set-Content -LiteralPath $logPath -Encoding UTF8
        $coreArguments = @('-Action', 'Install', '-RepositoryPath', (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'), '-InstallClaudeDesktopIfMissing')
        # Administrators deploy the enrollment file beside the INSTALL .cmd, outside the extracted payload.
        $enrollmentFile = @('enrollment.json', 'skill-service-device.json') |
            ForEach-Object { Join-Path (Split-Path -Parent $PSScriptRoot) $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($enrollmentFile) { $coreArguments += @('-EnrollmentPath', $enrollmentFile) }
        # The private TEAM build carries a join code; the administrator's enrollment file always wins.
        $payloadInstaller = Join-Path $packageRoot 'installer'
        . (Join-Path $payloadInstaller 'SetupWizard.ps1')
        $askDetails = (-not $enrollmentFile) -and (Test-TeamJoinRequired -PayloadInstaller $payloadInstaller)
        $version = (Get-Content -LiteralPath (Join-Path $packageRoot 'VERSION') -Raw).Trim()
        $outcome = Show-SetupWizard -CoreSetup $coreSetup -CoreArguments $coreArguments -LogPath $logPath -Version $version `
            -AskDetails $askDetails -HasEnrollmentFile ([bool]$enrollmentFile)
        if ($outcome.Result -eq 'cancelled') {
            "[{0}] Setup was cancelled before anything was installed." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Add-Content -LiteralPath $logPath -Encoding UTF8
            exit 0
        }
        # First skill sync and usage report in the background once the PC is enrolled.
        $centralRunner = Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\scripts\weekly-skill-collection.ps1'
        if (Test-Path (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\service.json')) {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Sync' -f $centralRunner)
        }
        if ($outcome.Result -ne 'ok') { exit 1 }
    }
    else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $setup
        if ($LASTEXITCODE -ne 0) { throw "Smart Connector setup stopped with exit code $LASTEXITCODE." }
    }
}
catch {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    "[{0}] ERROR: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message |
        Add-Content -LiteralPath $logPath -Encoding UTF8
    Show-SetupMessage -Message ("Setup could not finish.`r`n`r`n{0}`r`n`r`nLog: {1}" -f $_.Exception.Message, $logPath) `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedSetupRoot = [IO.Path]::GetFullPath($setupRoot).TrimEnd('\') + '\'
        if (-not $resolvedTemporary.StartsWith($resolvedSetupRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected temporary path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
