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

. (Join-Path $PSScriptRoot 'SkillLibrary.ps1')
# Changed skill folders, as paths below .agents/skills: "<category>/<name>" or a legacy flat "<name>".
# Category READMEs and the generated catalog are not skills.
$skillFolders = @($changedRows | ForEach-Object {
    $parts = $_ -split "`t"
    $path = $parts[-1].Replace('\','/')
    if ($path -match '^\.agents/skills/(.+)$') {
        $segments = $matches[1] -split '/'
        if (Test-SkillCategory $segments[0]) { if ($segments.Count -ge 3) { "$($segments[0])/$($segments[1])" } }
        elseif ($segments.Count -ge 2) { $segments[0] }
    }
} | Sort-Object -Unique)

$blockedExtensions = @('.rvt','.rfa','.rte','.rft','.dwg','.dxf','.dgn','.nwc','.nwd','.ifc','.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.zip','.7z','.rar','.exe','.dll','.msi','.pfx','.key','.pem','.png','.jpg','.jpeg','.gif')
$sensitivePattern = '(?i)(api[_ -]?key|access[_ -]?token|client[_ -]?secret|password\s*[:=]|github_pat_|gh[pousr]_[a-z0-9_]+|begin (rsa|openssh|ec) private key|[a-z]:\\users\\|\\\\[^\\\s]+\\[^\\\s]+|autodesk docs://|bim 360://|acc://|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b)'

foreach ($folder in $skillFolders) {
    $name = ($folder -split '/')[-1]
    $category = if ($folder.Contains('/')) { ($folder -split '/')[0] } else { '' }
    if ($name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Invalid skill folder name: $name" }
    $skillPath = Join-Path $RepositoryRoot ('.agents\skills\' + $folder.Replace('/','\'))
    $manifestPath = Join-Path $skillPath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Missing SKILL.md for $folder" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifest -notmatch "(?m)^name:\s*$([regex]::Escape($name))\s*$") { throw "SKILL.md name does not match folder: $folder" }
    if ($manifest -notmatch '(?m)^description:\s*\S.+$') { throw "Missing skill description: $folder" }
    $declared = Get-SkillCategory $skillPath
    if ($category -and $declared -and $declared -ne $category) { throw "SKILL.md category '$declared' does not match its folder: $folder" }
    $sameName = @(Get-SkillFolders (Join-Path $RepositoryRoot '.agents\skills') | Where-Object Name -eq $name)
    if ($sameName.Count -gt 1) { throw "Skill name is used in more than one category: $name" }

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

Write-Output "PASS: validated $($skillFolders.Count) changed skill candidate(s)."
