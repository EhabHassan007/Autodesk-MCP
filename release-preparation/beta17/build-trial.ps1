# Builds a PRIVATE trial installer from the current working tree, for testing on this PC only. Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File release-preparation\beta17\build-trial.ps1
#
# - Nothing in the repository changes: the build runs on a temporary copy, so the stored installer ZIPs,
#   RELEASE-NOTES.md and VERSION stay as they are, and nothing is committed or uploaded.
# - The trial gets its own version, <next patch>-trial.<yyyyMMddHHmm> (for example 1.2.1-trial.202611151030). The update
#   check sees it as newer than the current public release, so it is not replaced by that release, and as older than the
#   next real release, which replaces it normally once published.
# - Public build only: never -Team, never a join code, never published. Do not share the trial with other PCs.
# - -LibreDwgPack <folder> carries the LibreDWG pack (the offline DWG tools dwg_inspect and dwg_convert) in the trial, so
#   they can be tried on a real drawing. Build the folder with scripts/build-libredwg-windows.sh; every file must match
#   libredwg-pack.json. Without it the trial has the tools but answers that the pack is not installed.
# - Output: <OutputFolder>\<trial version>\ with the setup .exe (when Inno Setup 6 is installed), the connector ZIP
#   (extract it and run "INSTALL Smart Connector.cmd") and TRIAL-INFO.txt (branch, commit, uncommitted changes).
param(
    [string]$OutputFolder = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Smart Connector trial'),
    [string]$LibreDwgPack = ''
)
$ErrorActionPreference = 'Stop'
$b = $PSScriptRoot
$repo = (Resolve-Path -LiteralPath (Join-Path $b '..\..')).Path
$utf8 = New-Object Text.UTF8Encoding($false)
# The pack folder is checked against libredwg-pack.json by build.ps1; resolve it now because the build runs from a temporary copy.
if ($LibreDwgPack) { $LibreDwgPack = (Resolve-Path -LiteralPath $LibreDwgPack).Path }

$baseVersion = ([IO.File]::ReadAllText((Join-Path $b 'source\runtime\VERSION'))).Trim()
if ($baseVersion -notmatch '^(\d+)\.(\d+)\.(\d+)(-.+)?$') { throw "VERSION must start with major.minor.patch: $baseVersion" }
# A final version (1.2.0) is followed by 1.2.1-trial.*; a pre-release (1.3.0-beta.2) by 1.3.0-trial.*, which still sorts
# below the final 1.3.0.
$patch = if ($Matches[4]) { [int]$Matches[3] } else { [int]$Matches[3] + 1 }
$trialVersion = '{0}.{1}.{2}-trial.{3}' -f $Matches[1], $Matches[2], $patch, (Get-Date -Format 'yyyyMMddHHmm')

$work = Join-Path ([IO.Path]::GetTempPath()) ('smart-connector-trial-' + [guid]::NewGuid().ToString('N'))
$copy = Join-Path $work 'release-preparation\beta17'
try {
    # Same layout as the repository, so build.ps1 finds the approved skill library at ..\..\.agents\skills.
    New-Item -ItemType Directory -Path $copy -Force | Out-Null
    foreach ($item in 'build.ps1', 'build.py', 'RELEASE-NOTES.md', 'libredwg-pack.json', 'setup', 'source', 'tests') {
        Copy-Item -LiteralPath (Join-Path $b $item) -Destination $copy -Recurse
    }
    $library = Join-Path $repo '.agents\skills'
    if (Test-Path -LiteralPath $library -PathType Container) {
        New-Item -ItemType Directory -Path (Join-Path $work '.agents') -Force | Out-Null
        Copy-Item -LiteralPath $library -Destination (Join-Path $work '.agents') -Recurse
    }
    if (Get-ChildItem -LiteralPath $work -Recurse -File -Force -Filter 'team-join.json') { throw 'A team-join.json is in the source tree. Remove it; a trial never carries the join code.' }

    [IO.File]::WriteAllText((Join-Path $copy 'source\runtime\VERSION'), "$trialVersion`n", $utf8)
    $notesPath = Join-Path $copy 'RELEASE-NOTES.md'
    $notes = "TRIAL BUILD ${trialVersion}: for the owner's own testing on one PC. Not a release; do not share.`n`n" + [IO.File]::ReadAllText($notesPath)
    [IO.File]::WriteAllText($notesPath, $notes, $utf8)

    $buildArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $copy 'build.ps1'))
    if ($LibreDwgPack) { $buildArguments += @('-LibreDwgPack', $LibreDwgPack) }
    & powershell.exe @buildArguments
    if ($LASTEXITCODE -ne 0) { throw "The trial build failed (exit $LASTEXITCODE). The repository was not changed." }

    $target = Join-Path $OutputFolder $trialVersion
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    # Only the installers. latest.json, smart-connector.json and the upload bundle point at the public release
    # channel and are left behind with the temporary copy.
    $zip = Join-Path $copy "Autodesk-MCP-Connector-$trialVersion.zip"
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "The build did not produce $zip." }
    Copy-Item -LiteralPath $zip -Destination $target
    $setup = Join-Path $copy "Smart-Connector-Setup-$trialVersion.exe"
    if (Test-Path -LiteralPath $setup -PathType Leaf) { Copy-Item -LiteralPath $setup -Destination $target }

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    $source = if ($git) {
        $branch = (& git.exe -C $repo rev-parse --abbrev-ref HEAD) -join ''
        $commit = (& git.exe -C $repo rev-parse --short HEAD) -join ''
        $dirty = @(& git.exe -C $repo status --porcelain)
        "Branch: $branch`nCommit: $commit`nUncommitted changes included: " + $(if ($dirty.Count) { "yes ($($dirty.Count) files)" } else { 'no' })
    } else { 'Git was not found; branch and commit not recorded.' }
    $info = "Smart Connector trial $trialVersion`nBuilt: $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME`nBased on: $baseVersion`n$source`n`n" +
        "Install: close Revit and AutoCAD, then run the setup .exe, or extract the ZIP and run 'INSTALL Smart Connector.cmd'.`n" +
        "Then follow 'Revit execute_csharp regression' in TESTING.md (inside the ZIP: Support\Autodesk-MCP-Payload.zip).`n" +
        "Back to the public release: install the public setup again; the update check will not offer it while this trial is newer.`n" +
        "For this PC only. Do not share or upload.`n"
    [IO.File]::WriteAllText((Join-Path $target 'TRIAL-INFO.txt'), $info, $utf8)
    "Trial $trialVersion is ready in $target"
}
finally { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } }
