[CmdletBinding()]
param(
    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/Autodesk-MCP.git',
    [string]$RepositoryPath = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP')
)

$ErrorActionPreference = 'Stop'
$setup = Join-Path $RepositoryPath 'installer\Setup-BimCad.ps1'
$launcher = Join-Path $RepositoryPath 'installer\BIM-CAD-Setup.ps1'
if (-not (Test-Path -LiteralPath $setup -PathType Leaf) -or
    -not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    exit 0
}

try {
    $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $setup `
        -Action CheckUpdate -RepositoryUrl $RepositoryUrl -RepositoryPath $RepositoryPath 2>&1
    if ($LASTEXITCODE -ne 0) { exit 0 }
    $message = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($message -notmatch '\[UPDATE_AVAILABLE\]') { exit 0 }

    Add-Type -AssemblyName System.Windows.Forms
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "An approved Autodesk MCP Connector or skill update is available.`r`n`r`nOpen the updater now?",
        'Autodesk MCP Connector',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
            '-RepositoryUrl', $RepositoryUrl, '-RepositoryPath', $RepositoryPath
        )
    }
}
catch {
    # Scheduled checks stay quiet when the network or private repository is unavailable.
    exit 0
}
