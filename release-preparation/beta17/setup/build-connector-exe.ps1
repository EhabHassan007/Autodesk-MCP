[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputPath)
# Builds SmartConnector.exe from source\runtime\src\connector\*.cs with the .NET Framework 4 compiler that ships with
# Windows (C# 5). Used by build.ps1 for the release and the setup .exe, and by the tests. Never runs on users' PCs.
$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw "The .NET Framework compiler was not found: $compiler" }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\source\runtime')).Path
$sources = @(Get-ChildItem -LiteralPath (Join-Path $runtime 'src\connector') -Filter '*.cs' | Sort-Object Name | ForEach-Object FullName)
if (-not $sources.Count) { throw 'No connector sources were found.' }
$references = foreach ($name in 'System.dll', 'System.Core.dll', 'Microsoft.CSharp.dll', 'Microsoft.VisualBasic.dll', 'System.Web.Extensions.dll') {
    $path = Join-Path $framework $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required reference was not found: $path" }
    "/reference:$path"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
$icon = Join-Path $runtime 'assets\logo.ico'
$iconArgument = if (Test-Path -LiteralPath $icon -PathType Leaf) { @("/win32icon:$icon") } else { @() }
$output = & $compiler /nologo /noconfig /target:exe /optimize+ /platform:anycpu "/out:$OutputPath" @references @iconArgument $sources 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw ("SmartConnector.exe did not compile:`n" + ($output -join "`n"))
}
$OutputPath
