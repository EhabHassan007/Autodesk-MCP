[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$payload = Join-Path $PSScriptRoot 'Autodesk-MCP-Payload.zip'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("autodesk-mcp-install-{0}" -f [Guid]::NewGuid().ToString('N'))
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
            $owner, $Message, 'Autodesk MCP Connector',
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
        throw 'The Autodesk MCP installation payload is invalid.'
    }

    if ($SmokeTest) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $setup -SmokeTest
        if ($LASTEXITCODE -ne 0) { throw "Autodesk MCP Connector smoke test stopped with exit code $LASTEXITCODE." }
    }
    elseif ($Install) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        "[{0}] Starting Autodesk MCP Connector installation." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
            Set-Content -LiteralPath $logPath -Encoding UTF8
        $coreArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $coreSetup,
            '-Action', 'Install', '-RepositoryPath', (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'), '-InstallClaudeDesktopIfMissing')
        # Administrators deploy the enrollment file beside INSTALL Autodesk MCP Connector.cmd, outside the extracted payload.
        $enrollmentFile = @('enrollment.json', 'skill-service-device.json') |
            ForEach-Object { Join-Path (Split-Path -Parent $PSScriptRoot) $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($enrollmentFile) { $coreArguments += @('-EnrollmentPath', $enrollmentFile) }
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
        $output = & powershell.exe @coreArguments 2>&1
        $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedPreference }
        $outputText = @($output | ForEach-Object { $_.ToString() })
        $outputText | Add-Content -LiteralPath $logPath -Encoding UTF8
        $outputText | ForEach-Object { Write-Host $_ }
        if ($exitCode -ne 0) { throw "Installation stopped with exit code $exitCode. See $logPath" }
        $centralRunner=Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\scripts\weekly-skill-collection.ps1'
        if(Test-Path (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\service.json')){
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Run' -f $centralRunner)
        }
        Show-SetupMessage -Message 'Installation completed. Codex and Claude Desktop are configured automatically. Claude web or mobile requires the optional remote setup.' `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Information)
    }
    else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $setup
        if ($LASTEXITCODE -ne 0) { throw "Autodesk MCP Connector setup stopped with exit code $LASTEXITCODE." }
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
        $resolvedSystemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemporary.StartsWith($resolvedSystemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected temporary path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
