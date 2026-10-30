# Fails when the installer ZIPs stored in the repository no longer match the source they are built
# from, or when a team join code is present. Runs locally and in GitHub Actions:
#   powershell -ExecutionPolicy Bypass -File release-preparation\beta17\tests\check-installer-current.ps1
param([string]$BuildRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$b = (Resolve-Path -LiteralPath $BuildRoot).Path
$runtime = Join-Path $b 'source\runtime'
$fix = 'Run "powershell -ExecutionPolicy Bypass -File release-preparation\beta17\build.ps1" and commit the updated ZIPs and RELEASE-NOTES.md.'

function Get-ContentHash([byte[]]$Bytes) {
    # Git may check text out with CRLF or LF; compare text with LF so only real changes count.
    if ([Array]::IndexOf($Bytes, [byte]0) -lt 0) {
        $Bytes = [Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($Bytes).Replace("`r`n", "`n"))
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') } finally { $sha.Dispose() }
}
function Get-TreeHashes([string]$Root) {
    $map = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $map[$file.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')] = Get-ContentHash ([IO.File]::ReadAllBytes($file.FullName))
    }
    $map
}
function Get-ZipHashes([string]$Zip, [string]$Prefix) {
    $map = @{}
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name.StartsWith($Prefix) -or $name.EndsWith('/')) { continue }
            $stream = $entry.Open(); $memory = New-Object IO.MemoryStream
            try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
            $map[$name.Substring($Prefix.Length)] = Get-ContentHash $memory.ToArray()
        }
    }
    finally { $archive.Dispose() }
    $map
}
function Compare-Trees([string]$Label, [hashtable]$Expected, [hashtable]$Actual) {
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($path in $Expected.Keys | Sort-Object) {
        if (-not $Actual.ContainsKey($path)) { $problems.Add("missing from $Label`: $path") }
        elseif ($Actual[$path] -ne $Expected[$path]) { $problems.Add("out of date in $Label`: $path") }
    }
    foreach ($path in $Actual.Keys | Sort-Object) {
        if (-not $Expected.ContainsKey($path)) { $problems.Add("extra in $Label (no longer in source): $path") }
    }
    $problems
}

$problems = New-Object System.Collections.Generic.List[string]

# 1. No join code anywhere in the source tree or the stored payload.
foreach ($file in Get-ChildItem -LiteralPath $b -Recurse -File -Force -Filter 'team-join.json') { $problems.Add("team join file must never be committed: $($file.FullName.Substring($b.Length + 1))") }

# 2. Connector payload == source/runtime.
$payload = Join-Path $b 'source\Support\Autodesk-MCP-Payload.zip'
$payloadHashes = Get-ZipHashes $payload 'Autodesk-MCP-Payload/'
if ($payloadHashes.ContainsKey('installer/team-join.json')) { $problems.Add('the stored public payload contains installer/team-join.json (a join code)') }
foreach ($p in Compare-Trees 'Support/Autodesk-MCP-Payload.zip' (Get-TreeHashes $runtime) $payloadHashes) { $problems.Add($p) }

# 3. Claude skills bundle references == runtime/.agents/skills (SKILL.md at its root is generated).
$bundle = Get-ZipHashes (Join-Path $b 'source\Autodesk MCP Skills for Claude.zip') 'autodesk-mcp-bim-workflows/references/'
foreach ($p in Compare-Trees 'Autodesk MCP Skills for Claude.zip' (Get-TreeHashes (Join-Path $runtime '.agents\skills')) $bundle) { $problems.Add($p) }

if ($problems.Count) {
    Write-Host "The stored installer does not match the source ($($problems.Count) problem(s)):"
    $problems | Select-Object -First 25 | ForEach-Object { Write-Host "  - $_" }
    if ($problems.Count -gt 25) { Write-Host "  ... and $($problems.Count - 25) more" }
    Write-Host $fix
    exit 1
}
"PASS: stored installer matches source/runtime ($($payloadHashes.Count) payload files, $($bundle.Count) skill references); no join code committed"
