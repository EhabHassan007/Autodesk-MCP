[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputRoot = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\skill-review'),
    [string[]]$AdditionalSkillRoots = @(),
    [switch]$OnlyAdditionalSkillRoots
)

$ErrorActionPreference = 'Stop'
$repositorySkills = Join-Path $RepositoryRoot '.agents\skills'
if (-not (Test-Path -LiteralPath $repositorySkills -PathType Container)) {
    throw "Repository skill library was not found: $repositorySkills"
}

function Get-Sha256Hex {
    param([string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-DirectoryHash {
    param([string]$Path)

    $rows = foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\').Replace('\','/')
        if ($relative -match '(^|/)(__pycache__|\.git)(/|$)') { continue }
        $hash = Get-Sha256Hex -Path $file.FullName
        "$relative`t$hash"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','') }
    finally { $algorithm.Dispose() }
}

function Get-SensitiveFlagCount {
    param([string]$Path)

    $patterns = '(?i)(api[_ -]?key|access[_ -]?token|client[_ -]?secret|password\s*[:=]|begin (rsa|openssh|ec) private key|[a-z]:\\users\\)'
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File) {
        if ($file.Length -gt 1MB) { continue }
        try {
            if (Select-String -LiteralPath $file.FullName -Pattern $patterns -Quiet -ErrorAction Stop) { $count++ }
        }
        catch { }
    }
    $count
}

$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }
$userProfilePath = $env:USERPROFILE
$sources = if ($OnlyAdditionalSkillRoots) { @() } else {
    @(
        [pscustomobject]@{ Label='Codex user skills'; Path=(Join-Path $codexHome 'skills') },
        [pscustomobject]@{ Label='Agent user skills'; Path=(Join-Path $userProfilePath '.agents\skills') }
    )
}
$sourceNumber = 1
foreach ($root in $AdditionalSkillRoots) {
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $sources += [pscustomobject]@{ Label="Additional root $sourceNumber"; Path=$root }
        $sourceNumber++
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$computer = ($env:COMPUTERNAME -replace '[^A-Za-z0-9_-]','_')
$reviewDirectory = Join-Path $OutputRoot "$computer-$stamp"
$candidateDirectory = Join-Path $reviewDirectory 'candidates'
New-Item -ItemType Directory -Path $candidateDirectory -Force | Out-Null

. (Join-Path $PSScriptRoot 'SkillLibrary.ps1')
$repositoryHashes = @{}
foreach ($skill in Get-SkillFolders $repositorySkills) {
    $repositoryHashes[$skill.Name] = Get-DirectoryHash $skill.Path
}

$results = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source.Path -PathType Container)) { continue }
    if ((Resolve-Path $source.Path).Path -eq (Resolve-Path $repositorySkills).Path) { continue }

    foreach ($skill in Get-ChildItem -LiteralPath $source.Path -Directory | Where-Object { -not $_.Name.StartsWith('.') }) {
        if (-not (Test-Path -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -PathType Leaf)) { continue }
        $hash = Get-DirectoryHash $skill.FullName
        $key = "$($skill.Name)|$hash"
        if ($seen[$key]) { continue }
        $seen[$key] = $true

        $status = if (-not $repositoryHashes.ContainsKey($skill.Name)) { 'NEW' }
            elseif ($repositoryHashes[$skill.Name] -eq $hash) { 'IDENTICAL' }
            else { 'CHANGED' }
        $flags = Get-SensitiveFlagCount $skill.FullName

        if ($status -ne 'IDENTICAL') {
            $targetName = "{0}-{1}" -f $skill.Name, $hash.Substring(0,8).ToLowerInvariant()
            Copy-Item -LiteralPath $skill.FullName -Destination (Join-Path $candidateDirectory $targetName) -Recurse -Force
        }

        $results.Add([pscustomobject]@{
            Skill = $skill.Name
            Status = $status
            Source = $source.Label
            Hash = $hash.Substring(0,12).ToLowerInvariant()
            Files = @(Get-ChildItem -LiteralPath $skill.FullName -Recurse -File).Count
            SensitiveFlags = $flags
        })
    }
}

$reportPath = Join-Path $reviewDirectory 'REVIEW.md'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Local skill review')
$lines.Add('')
$lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$lines.Add("Computer: $computer")
$lines.Add('')
$lines.Add('Nothing in this package was added or pushed to GitHub. Review candidate contents and sensitive-content flags before approving publication.')
$lines.Add('To propose this package to the repository owner, open https://github.com/EhabHassan007/Autodesk-MCP/issues/new?template=skill-submission.yml and attach the ZIP after reviewing it.')
$lines.Add('')
$lines.Add('| Skill | Status | Source | Files | Sensitive flags | Hash |')
$lines.Add('|---|---|---|---:|---:|---|')
foreach ($item in $results | Sort-Object Status,Skill) {
    $lines.Add("| $($item.Skill) | $($item.Status) | $($item.Source) | $($item.Files) | $($item.SensitiveFlags) | $($item.Hash) |")
}
if ($results.Count -eq 0) {
    $lines.Add('| _No user skills found_ | - | - | 0 | 0 | - |')
}
$lines.Add('')
$lines.Add('Statuses: NEW is absent from the repository; CHANGED has the same name but different contents; IDENTICAL already matches the repository and is not copied into candidates.')
Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8

$zipPath = Join-Path $OutputRoot "skill-review-$computer-$stamp.zip"
Compress-Archive -Path (Join-Path $reviewDirectory '*') -DestinationPath $zipPath -CompressionLevel Optimal

Write-Output "Review report: $reportPath"
Write-Output "Review package: $zipPath"
Write-Output "Candidates requiring a decision: $(@($results | Where-Object Status -ne 'IDENTICAL').Count)"
