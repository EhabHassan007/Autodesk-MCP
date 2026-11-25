# Publishes a Smart Connector release to the public Autodesk-MCP-Releases repository from the files that the
# "Build setup exe" workflow built on main. It never builds anything itself, so the published ZIPs, setup exe and
# update files are exactly the ones CI built and tested, and their SHA-256 values match the update manifests.
#
# Check only (default, changes nothing):
#   powershell -ExecutionPolicy Bypass -File release-preparation\beta17\publish-release.ps1
# Publish (asks you to type the version before anything is sent):
#   powershell -ExecutionPolicy Bypass -File release-preparation\beta17\publish-release.ps1 -Publish
#
# Publishing makes every installed PC see the new version at its next update check. Needs GitHub CLI (gh) signed in
# as the repository owner.
[CmdletBinding()]
param(
    [string]$Version,
    # The commit on main whose build to publish. Default: the current head of main.
    [string]$Commit,
    [string]$SourceRepository = 'EhabHassan007/Autodesk-MCP',
    [string]$ReleaseRepository = 'EhabHassan007/Autodesk-MCP-Releases',
    [string]$WorkDirectory = (Join-Path $env:TEMP 'smart-connector-publish'),
    [switch]$Publish
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$problems = New-Object System.Collections.Generic.List[string]
function Step([string]$Text) { Write-Host ('- ' + $Text) }
function Problem([string]$Text) { $problems.Add($Text); Write-Host ('  PROBLEM: ' + $Text) -ForegroundColor Red }

# --- gh ------------------------------------------------------------------------------------------------------------
$gh = Get-Command gh -ErrorAction SilentlyContinue | Select-Object -First 1
$ghPath = if ($gh) { $gh.Source } else { $null }
if (-not $ghPath) {
    $ghPath = @((Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $ghPath) { throw 'GitHub CLI (gh) is required: install it from https://cli.github.com and run gh auth login.' }
# Standard output is the answer; gh's own messages (stderr) go straight to the console.
function Gh {
    $output = & $ghPath @args
    if ($LASTEXITCODE -ne 0) { throw ('gh ' + ($args -join ' ') + ' failed (see the message above).') }
    $output
}
$null = Gh auth status

# --- What to publish -------------------------------------------------------------------------------------------------
if (-not $Version) { $Version = (Get-Content -LiteralPath (Join-Path $here 'source\runtime\VERSION') -Raw).Trim() }
if (-not $Commit) { $Commit = ((Gh api "repos/$SourceRepository/commits/main" --jq '.sha') | Select-Object -First 1).Trim() }
$tag = 'v' + $Version
Write-Host ''
Write-Host "Smart Connector $Version from $SourceRepository@$($Commit.Substring(0, 7)) to $ReleaseRepository ($tag)"
Write-Host ''

# --- 1. Every workflow on that commit finished green -----------------------------------------------------------------
Step 'CI on that commit'
$runs = (Gh run list -R $SourceRepository --commit $Commit --json 'databaseId,name,status,conclusion,event,workflowName' --limit 50) -join "`n" | ConvertFrom-Json
$runs = @($runs | Where-Object { $_.event -eq 'push' })
if (-not $runs.Count) { Problem "No CI run was found for $Commit on main. Wait for the merge's workflows to start." }
foreach ($run in $runs) {
    $state = if ($run.status -ne 'completed') { $run.status } else { $run.conclusion }
    Write-Host ("  {0}: {1}" -f $run.workflowName, $state)
    if ($state -ne 'success') { Problem "$($run.workflowName) is $state; publish only a commit whose CI is green." }
}
$build = @($runs | Where-Object { $_.workflowName -eq 'Build setup exe' -and $_.conclusion -eq 'success' }) | Select-Object -First 1
if (-not $build) { throw 'There is no successful "Build setup exe" run for this commit, so there are no release files to publish.' }

# --- 2. Download the release files CI built --------------------------------------------------------------------------
Step "Downloading the release files from run $($build.databaseId)"
$files = Join-Path $WorkDirectory $Version
if (Test-Path -LiteralPath $files) { Remove-Item -LiteralPath $files -Recurse -Force }
$null = New-Item -ItemType Directory -Path $files -Force
$null = Gh run download $build.databaseId -R $SourceRepository -n smart-connector-release -D $files

# --- 3. Check the files ----------------------------------------------------------------------------------------------
Step 'Checking the files'
$expected = @("Autodesk-MCP-Connector-$Version.zip", "Smart-Connector-$Version.zip", "Smart-Connector-Setup-$Version.exe", 'latest.json', 'smart-connector.json')
$present = @(Get-ChildItem -LiteralPath $files -File | ForEach-Object Name)
foreach ($name in $expected) { if ($present -notcontains $name) { Problem "missing from the build: $name" } }
foreach ($name in $present) {
    if ($name -match 'TEAM' -or $name -eq 'team-join.json') { Problem "a TEAM file is in the build and must never be published: $name" }
}
function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
foreach ($pair in @(@('latest.json', "Autodesk-MCP-Connector-$Version.zip"), @('smart-connector.json', "Smart-Connector-$Version.zip"))) {
    $manifestPath = Join-Path $files $pair[0]; $zipPath = Join-Path $files $pair[1]
    if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $zipPath)) { continue }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $url = "https://github.com/$ReleaseRepository/releases/download/$tag/$($pair[1])"
    if ([string]$manifest.version -ne $Version) { Problem "$($pair[0]) says version $($manifest.version), not $Version" }
    if ([string]$manifest.download_url -ne $url) { Problem "$($pair[0]) points to $($manifest.download_url), not $url" }
    $hash = Get-Sha $zipPath
    if ($hash -ne ([string]$manifest.sha256).ToUpperInvariant()) { Problem "$($pair[1]) SHA-256 $hash does not match $($pair[0])" }
    else { Write-Host "  $($pair[1]): SHA-256 matches $($pair[0])" }
}
# No team join code anywhere, including in the ZIPs inside the ZIPs.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function Test-ZipForJoinCode([IO.Stream]$Stream, [string]$Label) {
    $archive = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.Name -eq 'team-join.json') { Problem "$Label contains $($entry.FullName) (a team join code)" }
            elseif ($entry.Name -like '*.zip') {
                $inner = New-Object IO.MemoryStream
                $source = $entry.Open(); try { $source.CopyTo($inner) } finally { $source.Dispose() }
                $inner.Position = 0
                Test-ZipForJoinCode $inner ($Label + '/' + $entry.FullName)
            }
        }
    }
    finally { $archive.Dispose() }
}
foreach ($zip in @(Get-ChildItem -LiteralPath $files -Filter '*.zip' -File)) {
    $stream = [IO.File]::OpenRead($zip.FullName)
    try { Test-ZipForJoinCode $stream $zip.Name } finally { $stream.Dispose() }
}
Write-Host '  no team join code in any ZIP'

# --- 4. Release notes: this version's section of RELEASE-NOTES.md --------------------------------------------------
$notesSource = Join-Path $files 'RELEASE-NOTES.md'
if (-not (Test-Path -LiteralPath $notesSource)) { $notesSource = Join-Path $here 'RELEASE-NOTES.md' }
$heading = 'Smart Connector for Autodesk Revit and AutoCAD '
$lines = [IO.File]::ReadAllLines($notesSource)
if (-not $lines.Count -or $lines[0].Trim() -ne ($heading + $Version)) { Problem "RELEASE-NOTES.md does not start with '$heading$Version'" }
$section = New-Object System.Collections.Generic.List[string]
for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].StartsWith($heading)) { break }
    $section.Add($lines[$i])
}
$section.Add('')
$section.Add('SHA-256')
foreach ($name in $expected) {
    $path = Join-Path $files $name
    if ($name -notlike '*.json' -and (Test-Path -LiteralPath $path)) { $section.Add(('- {0}: {1}' -f $name, (Get-Sha $path))) }
}
$notesFile = Join-Path $WorkDirectory "release-notes-$Version.md"
[IO.File]::WriteAllText($notesFile, (($section -join "`n").Trim() + "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "  release notes: $notesFile"

# --- 5. The release repository ---------------------------------------------------------------------------------------
Step 'Release repository'
$visibility = ((Gh repo view $ReleaseRepository --json visibility --jq '.visibility') | Select-Object -First 1).Trim()
if ($visibility -ne 'PUBLIC') { Problem "$ReleaseRepository is $visibility, not PUBLIC; team PCs could not download from it" }
# Windows PowerShell turns a redirected native error into an exception under Stop, so look with Continue.
$ErrorActionPreference = 'Continue'
$existing = & $ghPath release view $tag -R $ReleaseRepository --json tagName 2>$null
$viewExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($viewExit -eq 0 -and $existing) { Problem "$ReleaseRepository already has a release $tag; a published version is never replaced" }
$current = ''
try { $current = (Invoke-RestMethod -Uri "https://github.com/$ReleaseRepository/releases/latest/download/latest.json" -UseBasicParsing -TimeoutSec 15).version } catch { }
Write-Host "  version team PCs see now: $current"

# --- Summary ---------------------------------------------------------------------------------------------------------
Write-Host ''
Write-Host 'Files that would be published:'
foreach ($name in $expected) {
    $path = Join-Path $files $name
    if (Test-Path -LiteralPath $path) { Write-Host ('  {0,-40} {1,10:N0} KB' -f $name, ((Get-Item -LiteralPath $path).Length / 1KB)) }
}
if ($problems.Count) {
    Write-Host ''
    Write-Host "Not publishable: $($problems.Count) problem(s) above. Nothing was published." -ForegroundColor Red
    exit 1
}
if (-not $Publish) {
    Write-Host ''
    Write-Host "All checks passed. Nothing was published. Read $notesFile, then run again with -Publish." -ForegroundColor Green
    exit 0
}

# --- 6. Publish ------------------------------------------------------------------------------------------------------
Write-Host ''
Write-Host "Publishing sends $Version to every installed PC at its next update check (now: $current)." -ForegroundColor Yellow
$answer = Read-Host "Type $Version to publish, anything else to stop"
if ($answer.Trim() -ne $Version) { Write-Host 'Stopped. Nothing was published.'; exit 1 }
$assets = @($expected | ForEach-Object { Join-Path $files $_ })
$null = Gh release create $tag @assets -R $ReleaseRepository --title "Smart Connector $Version" --notes-file $notesFile --latest
Write-Host "Published https://github.com/$ReleaseRepository/releases/tag/$tag"

# --- 7. Read back what team PCs will see -----------------------------------------------------------------------------
$seen = ''
for ($try = 0; $try -lt 12 -and $seen -ne $Version; $try++) {
    Start-Sleep -Seconds 5
    try { $seen = (Invoke-RestMethod -Uri "https://github.com/$ReleaseRepository/releases/latest/download/latest.json" -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' }).version } catch { }
}
if ($seen -eq $Version) { Write-Host "Update check now reports $Version." -ForegroundColor Green }
else { Write-Host "The update check still reports '$seen'. Check the release page; GitHub can take a minute to serve the new files." -ForegroundColor Yellow }
