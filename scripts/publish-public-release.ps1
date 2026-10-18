[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PublicReleaseRepository = 'EhabHassan007/Autodesk-MCP-Releases',
    [string]$PackagePath,
    [string]$ManifestPath,
    [string]$Version,
    [switch]$CreateRepository
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path (Split-Path -Parent $repositoryRoot) ("Autodesk-MCP-Connector-{0}.zip" -f $Version)
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path (Split-Path -Parent $repositoryRoot) 'latest.json'
}
foreach ($path in @($PackagePath, $ManifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release file is missing: $path" }
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$actualHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
if (-not ([string]$manifest.version).Equals($Version, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Manifest version $($manifest.version) does not match $Version."
}
if (-not $actualHash.Equals([string]$manifest.sha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The package SHA-256 does not match latest.json.'
}

$gh = Get-Command gh -ErrorAction SilentlyContinue | Select-Object -First 1
$ghPath = if ($gh) { $gh.Source } else { $null }
if (-not $ghPath) {
    $ghPath = @(
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $ghPath) { throw 'GitHub CLI (gh) is required for release publishing.' }
& $ghPath auth status
if ($LASTEXITCODE -ne 0) { throw 'Sign in with gh auth login, then retry.' }

$previousErrorPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $visibilityOutput = & $ghPath repo view $PublicReleaseRepository --json visibility --jq '.visibility' 2>&1
    $repoViewExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorPreference
}
$visibility = if ($repoViewExitCode -eq 0) { [string]($visibilityOutput | Select-Object -First 1) } else { '' }
if ($repoViewExitCode -ne 0) {
    if (-not $CreateRepository) {
        throw "Public release repository $PublicReleaseRepository does not exist or is not accessible. Retry with -CreateRepository after reviewing the repository name."
    }
    if ($PSCmdlet.ShouldProcess($PublicReleaseRepository, 'Create public GitHub release repository')) {
        & $ghPath repo create $PublicReleaseRepository --public --description 'Public, read-only releases for Autodesk MCP Connector' --add-readme
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the public release repository.' }
        $visibility = 'PUBLIC'
    }
}
if (-not ([string]$visibility).Trim().Equals('PUBLIC', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to publish installer assets because $PublicReleaseRepository is not public."
}

$tag = "v$Version"
if ($PSCmdlet.ShouldProcess("$PublicReleaseRepository $tag", 'Publish connector ZIP and checksum manifest')) {
    & $ghPath release create $tag $PackagePath $ManifestPath --repo $PublicReleaseRepository --title "Autodesk MCP Connector $Version" --notes "Approved Autodesk MCP Connector release $Version. The installer verifies the package SHA-256 from latest.json." --latest
    if ($LASTEXITCODE -ne 0) { throw 'GitHub release publishing failed.' }
    Write-Output "Published https://github.com/$PublicReleaseRepository/releases/tag/$tag"
}
