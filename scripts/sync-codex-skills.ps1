[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update', 'Publish')]
    [string]$Action = 'Install',

    [string]$Message = 'Update Codex skills',

    [string]$Destination
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$skillsSource = Join-Path $repositoryRoot '.agents\skills'

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        Join-Path $HOME '.codex'
    }
    else {
        $env:CODEX_HOME
    }
    $Destination = Join-Path $codexHome 'skills'
}

function Get-RepositorySkills {
    if (-not (Test-Path -LiteralPath $skillsSource -PathType Container)) {
        throw "Skill library was not found: $skillsSource"
    }

    @(Get-ChildItem -LiteralPath $skillsSource -Directory | Sort-Object Name)
}

function Test-RepositorySkills {
    $skills = Get-RepositorySkills
    if ($skills.Count -eq 0) {
        throw 'The repository skill library is empty.'
    }

    foreach ($skill in $skills) {
        if ($skill.Name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "Invalid skill folder name: $($skill.Name)"
        }

        $manifestPath = Join-Path $skill.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Missing SKILL.md: $($skill.FullName)"
        }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw
        if (-not $manifest.StartsWith('---') -or $manifest -notmatch '(?m)^name:\s*\S.+$') {
            throw "Missing YAML name in $manifestPath"
        }
        if ($manifest -notmatch '(?m)^description:\s*\S.+$') {
            throw "Missing YAML description in $manifestPath"
        }
    }

    $skills
}

function Install-RepositorySkills {
    $skills = Test-RepositorySkills
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    foreach ($skill in $skills) {
        $target = Join-Path $Destination $skill.Name
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Copy-Item -LiteralPath $skill.FullName -Destination $target -Recurse -Force
        Write-Host "Installed skill: $($skill.Name)"
    }

    Write-Host "Skill library installed at: $Destination"
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & git -C $repositoryRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git $($Arguments -join ' ')"
    }
}

if ($Action -eq 'Install') {
    Install-RepositorySkills
    exit 0
}

if ($Action -eq 'Update') {
    Invoke-Git pull --ff-only origin main
    Install-RepositorySkills
    exit 0
}

$null = Test-RepositorySkills

$outsideSkillChanges = @(
    Invoke-Git status --porcelain --untracked-files=all |
        Where-Object {
            $path = if ($_.Length -gt 3) { $_.Substring(3).Replace('\', '/') } else { '' }
            $path -and -not $path.StartsWith('.agents/skills/')
        }
)

if ($outsideSkillChanges.Count -gt 0) {
    throw "Publishing stopped because files outside .agents/skills have changes. Commit, discard, or temporarily move those changes first.`n$($outsideSkillChanges -join [Environment]::NewLine)"
}

Invoke-Git add -- .agents/skills
& git -C $repositoryRoot diff --cached --quiet -- .agents/skills
$hasStagedSkillChanges = $LASTEXITCODE -ne 0

if ($hasStagedSkillChanges) {
    Invoke-Git commit -m $Message -- .agents/skills
}
else {
    Write-Host 'No local skill changes to commit.'
}

Invoke-Git pull --rebase origin main
Invoke-Git push origin HEAD:main
Install-RepositorySkills
