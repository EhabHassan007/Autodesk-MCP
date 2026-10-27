[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$BaseRef = 'origin/main',
    [string]$HeadRef = $env:GITHUB_HEAD_REF
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $output = & git -C $RepositoryRoot @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git failed: git $($Arguments -join ' ')" }
    @($output)
}

$changedRows = @(Invoke-Git diff --name-status "$BaseRef...HEAD")
if ($HeadRef -like 'skill-intake/*') {
    $outside = @($changedRows | Where-Object {
        $parts = $_ -split "`t"
        $path = $parts[-1].Replace('\','/')
        -not $path.StartsWith('.agents/skills/')
    })
    if ($outside.Count -gt 0) { throw "Automated intake branches may change only .agents/skills.`n$($outside -join [Environment]::NewLine)" }
}

$deletedSkills = @($changedRows | Where-Object { $_ -match '^D\s+\.agents/skills/' })
if ($deletedSkills.Count -gt 0) { throw 'Automated intake may not delete approved skill files.' }

$skillNames = @($changedRows | ForEach-Object {
    $parts = $_ -split "`t"
    $path = $parts[-1].Replace('\','/')
    if ($path -match '^\.agents/skills/([^/]+)/') { $matches[1] }
} | Sort-Object -Unique)

$blockedExtensions = @('.rvt','.rfa','.rte','.rft','.dwg','.dxf','.dgn','.nwc','.nwd','.ifc','.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.zip','.7z','.rar','.exe','.dll','.msi','.pfx','.key','.pem','.png','.jpg','.jpeg','.gif')
$sensitivePattern = '(?i)(api[_ -]?key|access[_ -]?token|client[_ -]?secret|password\s*[:=]|github_pat_|gh[pousr]_[a-z0-9_]+|begin (rsa|openssh|ec) private key|[a-z]:\\users\\|\\\\[^\\\s]+\\[^\\\s]+|autodesk docs://|bim 360://|acc://|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b)'

foreach ($name in $skillNames) {
    if ($name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Invalid skill folder name: $name" }
    $skillPath = Join-Path $RepositoryRoot ('.agents\skills\' + $name)
    $manifestPath = Join-Path $skillPath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Missing SKILL.md for $name" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifest -notmatch "(?m)^name:\s*$([regex]::Escape($name))\s*$") { throw "SKILL.md name does not match folder: $name" }
    if ($manifest -notmatch '(?m)^description:\s*\S.+$') { throw "Missing skill description: $name" }

    foreach ($item in Get-ChildItem -LiteralPath $skillPath -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Links are not allowed: $($item.FullName)" }
        if ($item.PSIsContainer) { continue }
        if ($item.Length -gt 256KB) { throw "File exceeds 256 KB: $($item.FullName)" }
        if ($blockedExtensions -contains $item.Extension.ToLowerInvariant()) { throw "Binary or project file is blocked: $($item.FullName)" }
        if (Select-String -LiteralPath $item.FullName -Pattern $sensitivePattern -Quiet -ErrorAction SilentlyContinue) {
            throw "Potential secret or private project information found: $($item.FullName)"
        }
    }
}

Write-Output "PASS: validated $($skillNames.Count) changed skill candidate(s)."
