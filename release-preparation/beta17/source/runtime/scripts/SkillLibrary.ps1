# Skill library layout, shared by the connector scripts. Dot-source it.
# The approved library keeps skills in category folders: <root>\<category>\<skill-name>\SKILL.md.
# Older libraries and the per-PC installs (Codex, Claude, the approved cache) are flat:
# <root>\<skill-name>\SKILL.md. Both are read, so either layout works.

$script:SkillCategories = [ordered]@{
    'revit'              = 'Revit'
    'autocad'            = 'AutoCAD'
    '3ds-max'            = '3ds Max'
    'other-software'     = 'Other software'
    'linkedin-marketing' = 'LinkedIn and marketing'
    'branding-ci'        = 'Personal branding and corporate identity'
    'general'            = 'General and office'
    'uncategorized'      = 'Not yet categorised'
}

function Test-SkillCategory {
    param([string]$Category)
    $script:SkillCategories.Contains($Category)
}

# Which approved skills a Skills Sync downloads (the owner's choice). The button in Revit or AutoCAD takes only
# that software's skills. The weekly run and the notification-area menu take the Autodesk products installed on
# this PC, plus General. Skills already installed from other categories are kept, never removed.
$script:ProductSkillCategories = [ordered]@{ 'Revit' = 'revit'; 'AutoCAD' = 'autocad'; '3dsMax' = '3ds-max' }

function Get-InstalledAutodeskProducts {
    param([string]$ProgramFiles = $env:ProgramFiles, [string]$MachineRoot = 'HKLM:\SOFTWARE\Autodesk')
    if (@(Get-ChildItem -Path (Join-Path $ProgramFiles 'Autodesk\Revit 20*\RevitAPI.dll') -File -ErrorAction SilentlyContinue).Count) { 'Revit' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $MachineRoot 'AutoCAD') -ErrorAction SilentlyContinue).Count) { 'AutoCAD' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $MachineRoot '3dsMax') -ErrorAction SilentlyContinue).Count) { '3dsMax' }
}

function Get-SyncCategories {
    param([string]$Product = '', [string[]]$InstalledProducts = @(Get-InstalledAutodeskProducts))
    if ($Product) {
        if (-not $script:ProductSkillCategories.Contains($Product)) { throw "Unknown product for Skills Sync: $Product" }
        return @($script:ProductSkillCategories[$Product])
    }
    @(@($InstalledProducts | Where-Object { $script:ProductSkillCategories.Contains($_) } | ForEach-Object { $script:ProductSkillCategories[$_] }) + 'general' | Select-Object -Unique)
}

function Get-SkillCategory {
    # The "category:" line in SKILL.md; empty when the skill does not declare one.
    param([string]$SkillPath)
    $manifest = Join-Path $SkillPath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return '' }
    # Only the frontmatter: the lines between the opening and closing "---".
    $lines = @([IO.File]::ReadAllLines($manifest) | Select-Object -First 40)
    if (-not $lines.Count -or $lines[0].TrimStart([char]0xFEFF) -notmatch '^---\s*$') { return '' }
    for ($i = 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^---\s*$'; $i++) {
        if ($lines[$i] -match '^category:\s*([a-z0-9-]+)\s*$') { return $Matches[1] }
    }
    ''
}

function Get-SkillFolders {
    # One object per skill: Name (folder name, the skill's identity), Category, Path.
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    foreach ($folder in @(Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name)) {
        if (Test-Path -LiteralPath (Join-Path $folder.FullName 'SKILL.md') -PathType Leaf) {
            [pscustomobject]@{ Name = $folder.Name; Category = (Get-SkillCategory $folder.FullName); Path = $folder.FullName }
        }
        elseif (Test-SkillCategory $folder.Name) {
            foreach ($skill in @(Get-ChildItem -LiteralPath $folder.FullName -Directory -Force | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name)) {
                if (Test-Path -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -PathType Leaf) {
                    [pscustomobject]@{ Name = $skill.Name; Category = $folder.Name; Path = $skill.FullName }
                }
            }
        }
    }
}
