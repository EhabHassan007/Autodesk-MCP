# PowerShell equivalent of build.py for Windows PCs without Python. Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File release-preparation\beta17\build.ps1
# Add -Team to also build the PRIVATE team installer, which carries the team join code.
# The team ZIP is git-ignored: share it inside the company only, never in public releases.
param(
    [switch]$Team,
    [string]$ServiceUrl = 'https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev',
    # Prompted for (hidden) with -Team when omitted. Never pass it as plain text.
    [Security.SecureString]$TeamJoinCode
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$b = $PSScriptRoot; $s = Join-Path $b 'source'; $r = Join-Path $s 'runtime'
$version = (Get-Content -LiteralPath (Join-Path $r 'VERSION') -Raw).Trim()
$utf8 = New-Object Text.UTF8Encoding($false)

function Get-Files([string]$Root) {
    # Entry order is cosmetic; sort for a stable archive like sorted(rglob).
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        ForEach-Object { [pscustomobject]@{ Full = $_.FullName; Rel = $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/') } } |
        Sort-Object Rel -CaseSensitive
}
function New-Zip([string]$Path, [scriptblock]$Fill) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try { & $Fill $zip } finally { $zip.Dispose() }
}
function Add-File($Zip, [string]$Source, [string]$Name) {
    $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Zip, $Source, $Name, [IO.Compression.CompressionLevel]::Optimal)
}
function Add-Text($Zip, [string]$Name, [string]$Text) {
    $entry = $Zip.CreateEntry($Name, [IO.Compression.CompressionLevel]::Optimal)
    $writer = New-Object IO.StreamWriter($entry.Open(), $utf8)
    try { $writer.Write($Text) } finally { $writer.Dispose() }
}
function Add-Payload($Zip, [string]$JoinJson) {
    foreach ($f in Get-Files $r) {
        # A stray join file in the source tree must never reach any payload.
        if ($f.Rel -eq 'installer/team-join.json') { throw 'Remove source/runtime/installer/team-join.json; the join code is added only by -Team.' }
        Add-File $Zip $f.Full ('Autodesk-MCP-Payload/' + $f.Rel)
    }
    if ($JoinJson) { Add-Text $Zip 'Autodesk-MCP-Payload/installer/team-join.json' $JoinJson }
}
function Add-Release($Zip, [string]$PayloadPath) {
    foreach ($f in Get-Files $s) {
        if ($f.Rel.StartsWith('runtime/')) { continue }
        $source = if ($f.Rel -eq 'Support/Autodesk-MCP-Payload.zip') { $PayloadPath } else { $f.Full }
        Add-File $Zip $source ("Autodesk-MCP-Connector-$version/" + $f.Rel)
    }
}

# Ask before writing anything, so a cancelled prompt leaves no half-built output.
$joinJson = $null
if ($TeamJoinCode) { $Team = [switch]$true }
if ($Team) {
    $uri = [Uri]$ServiceUrl
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'The service URL must be HTTPS without credentials, query or fragment.' }
    if (-not $TeamJoinCode) { $TeamJoinCode = Read-Host -AsSecureString 'Paste JOIN_CODE (input hidden), then press Enter' }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($TeamJoinCode)
    try { $code = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    if ($code.Trim().Length -lt 32) { throw 'The join code must be at least 32 characters, matching JOIN_CODE in Cloudflare.' }
    $joinJson = @{ service_url = $uri.AbsoluteUri.TrimEnd('/'); join_code = $code.Trim() } | ConvertTo-Json
    $code = $null
}

# 1. Refresh the Claude skills bundle to match the runtime skill library.
$skillsZip = Join-Path $s 'Autodesk MCP Skills for Claude.zip'
$old = [IO.Compression.ZipFile]::OpenRead($skillsZip)
try {
    $entry = $old.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq 'autodesk-mcp-bim-workflows/SKILL.md' } | Select-Object -First 1
    $reader = New-Object IO.StreamReader($entry.Open(), $utf8, $true)
    try { $skillText = $reader.ReadToEnd().Replace('daily team', 'weekly team') } finally { $reader.Dispose() }
}
finally { $old.Dispose() }
New-Zip $skillsZip {
    param($z)
    Add-Text $z 'autodesk-mcp-bim-workflows/SKILL.md' $skillText
    foreach ($f in Get-Files (Join-Path $r '.agents\skills')) { Add-File $z $f.Full ('autodesk-mcp-bim-workflows/references/' + $f.Rel) }
}

# 2. Connector payload from the runtime tree (public: never contains a join code).
$payload = Join-Path $s 'Support\Autodesk-MCP-Payload.zip'
New-Zip $payload { param($z) Add-Payload $z $null }

# 3. Release ZIP: everything in source except the runtime tree.
$name = "Autodesk-MCP-Connector-$version.zip"
New-Zip (Join-Path $b $name) { param($z) Add-Release $z $payload }
$h = (Get-FileHash -LiteralPath (Join-Path $b $name) -Algorithm SHA256).Hash.ToUpperInvariant()

# 4. latest.json and the SHA line in the release notes.
$published = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.ffffffzzz")
$latest = "{`n  `"schema_version`": 1,`n  `"version`": `"$version`",`n  `"download_url`": `"https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/download/v$version/$name`",`n  `"sha256`": `"$h`",`n  `"published_at`": `"$published`"`n}`n"
[IO.File]::WriteAllText((Join-Path $b 'latest.json'), $latest, $utf8)
$notesPath = Join-Path $b 'RELEASE-NOTES.md'
$notes = ([IO.File]::ReadAllText($notesPath) -split "`nSHA-256:", 2)[0] + "`nSHA-256: $h`n"
[IO.File]::WriteAllText($notesPath, $notes, $utf8)

# 5. Upload bundle and source/tests archive (local only, git-ignored).
New-Zip (Join-Path $b 'beta17-github-upload.zip') {
    param($z)
    foreach ($n in @($name, 'latest.json', 'RELEASE-NOTES.md')) { Add-File $z (Join-Path $b $n) $n }
}
New-Zip (Join-Path $b 'beta17-source-and-tests.zip') {
    param($z)
    foreach ($folder in @($r, (Join-Path $b 'tests'))) {
        foreach ($f in Get-Files $folder) { Add-File $z $f.Full ($f.Full.Substring($b.Length).TrimStart('\').Replace('\', '/')) }
    }
    Add-File $z (Join-Path $b 'build.py') 'build.py'
    Add-File $z (Join-Path $b 'build.ps1') 'build.ps1'
}
"$name $h"

# 6. Optional private team installer: same files, plus the join code inside its payload.
if ($Team) {
    $teamPayload = Join-Path ([IO.Path]::GetTempPath()) ("team-payload-{0}.zip" -f [guid]::NewGuid().ToString('N'))
    try {
        New-Zip $teamPayload { param($z) Add-Payload $z $joinJson }
        $teamName = "Autodesk-MCP-Connector-$version-TEAM.zip"
        New-Zip (Join-Path $b $teamName) { param($z) Add-Release $z $teamPayload }
        "$teamName (private: share inside the company only)"
    }
    finally {
        $joinJson = $null
        if (Test-Path -LiteralPath $teamPayload) { Remove-Item -LiteralPath $teamPayload -Force }
    }
}
