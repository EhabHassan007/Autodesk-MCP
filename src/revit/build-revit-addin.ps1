[CmdletBinding()]
param(
    [ValidatePattern('^\d{4}$')]
    [string]$RevitVersion = '2024',

    [string]$RevitInstallPath,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if ([int]$RevitVersion -ge 2025) {
    throw 'Revit 2025 and newer require a .NET 8 build. This source package currently builds Revit 2024 only.'
}

if ([string]::IsNullOrWhiteSpace($RevitInstallPath)) {
    $RevitInstallPath = Join-Path $env:ProgramFiles "Autodesk\Revit $RevitVersion"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "bin\$RevitVersion"
}

$revitApi = Join-Path $RevitInstallPath 'RevitAPI.dll'
$revitUiApi = Join-Path $RevitInstallPath 'RevitAPIUI.dll'
$source = Join-Path $PSScriptRoot 'addin\RevitMcpApplication.cs'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

foreach ($required in @($revitApi, $revitUiApi, $source, $compiler)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required build file was not found: $required"
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$assembly = Join-Path $OutputPath 'BimCadMcp.Revit.dll'

& $compiler /nologo /target:library /optimize+ /platform:anycpu `
    "/out:$assembly" `
    "/reference:$revitApi" `
    "/reference:$revitUiApi" `
    $source

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $assembly -PathType Leaf)) {
    throw 'Revit add-in compilation failed.'
}

Write-Output $assembly
