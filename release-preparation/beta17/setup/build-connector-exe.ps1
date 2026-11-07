[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputPath)
# Builds SmartConnector.exe (the MCP server and the Smart Connector windows) from source\runtime\src\connector\*.cs
# with the .NET Framework 4 compiler that ships with Windows (C# 5). Used by build.ps1 for the release and the setup
# .exe, and by the tests. Never runs on users' PCs.
$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw "The .NET Framework compiler was not found: $compiler" }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\source\runtime')).Path
$sources = @(Get-ChildItem -LiteralPath (Join-Path $runtime 'src\connector') -Filter '*.cs' | Sort-Object Name | ForEach-Object FullName)
if (-not $sources.Count) { throw 'No connector sources were found.' }
# The windows use WinForms and System.Drawing; the icon family is drawn with WPF (PresentationCore and WindowsBase,
# in the WPF subfolder; System.Xaml for the bitmap encoder's interfaces). Skills Sync (the `skills` command) uses
# System.Security (the encrypted device token), System.IO.Compression (the review package) and System.Management
# (finding the connector agent of earlier versions).
$references = foreach ($name in 'System.dll', 'System.Core.dll', 'Microsoft.CSharp.dll', 'Microsoft.VisualBasic.dll', 'System.Web.Extensions.dll',
    'System.Windows.Forms.dll', 'System.Drawing.dll', 'System.Xaml.dll', 'System.Security.dll', 'System.IO.Compression.dll', 'System.Management.dll',
    'WPF\PresentationCore.dll', 'WPF\WindowsBase.dll') {
    $path = Join-Path $framework $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required reference was not found: $path" }
    "/reference:$path"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
$icon = Join-Path $runtime 'assets\logo.ico'
# A Windows (GUI) program, so `app` and `setup` open without a console window flashing; Claude and Codex still
# talk to `mcp` over the pipes they pass in.
# One plain argument list: splatting an array (@name) into a native command mangles it in Windows PowerShell 5.1.
$arguments = @('/nologo', '/noconfig', '/target:winexe', '/optimize+', '/platform:anycpu', "/out:$OutputPath") + @($references)
if (Test-Path -LiteralPath $icon -PathType Leaf) { $arguments += "/win32icon:$icon" }
$arguments += $sources
$output = & $compiler $arguments 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw ("SmartConnector.exe did not compile:`n" + ($output -join "`n"))
}
$OutputPath
