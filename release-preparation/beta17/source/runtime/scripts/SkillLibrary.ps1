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

# UTF-8 text that was once read as Latin-1 or Windows-1252, possibly more than once, so an em dash
# turns into three or six accented characters. Each character in such a run stands for one byte of the original UTF-8.
$script:StrictUtf8 = New-Object Text.UTF8Encoding($false, $true)
$script:MojibakeBytes = @{}
foreach ($value in 0x80..0x9F) {
    $character = [Text.Encoding]::GetEncoding(1252).GetString([byte[]]@($value))[0]
    if ([int]$character -ne $value) { $script:MojibakeBytes[$character] = $value }
}
$script:MojibakeRun = '[\u0080-\u00FF' + [regex]::Escape(-join $script:MojibakeBytes.Keys) + ']{2,}'

function Get-MojibakeByte {
    param([char]$Character)
    if ([int]$Character -le 0xFF) { return [int]$Character }
    $script:MojibakeBytes[$Character]
}

function Repair-MojibakeRun {
    # Decodes each complete, valid UTF-8 sequence in the run and keeps every other character as it was.
    param([string]$Run)
    $text = New-Object Text.StringBuilder
    $i = 0
    while ($i -lt $Run.Length) {
        $lead = Get-MojibakeByte $Run[$i]
        $length = if ($lead -ge 0xC2 -and $lead -le 0xDF) { 2 } elseif ($lead -ge 0xE0 -and $lead -le 0xEF) { 3 } elseif ($lead -ge 0xF0 -and $lead -le 0xF4) { 4 } else { 0 }
        if ($length -and $i + $length -le $Run.Length) {
            $bytes = [byte[]]@(for ($k = 0; $k -lt $length; $k++) { Get-MojibakeByte $Run[$i + $k] })
            try {
                [void]$text.Append($script:StrictUtf8.GetString($bytes))
                $i += $length
                continue
            }
            catch { }
        }
        [void]$text.Append($Run[$i])
        $i++
    }
    $text.ToString()
}

function Repair-Mojibake {
    # Undoes up to three wrong decodings. Correct text, including Arabic and real dashes or quotes, is unchanged.
    param([string]$Text)
    for ($pass = 0; $pass -lt 3; $pass++) {
        $repaired = [regex]::Replace($Text, $script:MojibakeRun, { param($match) Repair-MojibakeRun $match.Value })
        if ($repaired -ceq $Text) { break }
        $Text = $repaired
    }
    $Text
}

function Read-SkillText {
    # A skill's text files by relative path, read as UTF-8 without a BOM and with mojibake repaired.
    param([string]$Path)
    $files = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\','/').Replace('\','/')
        # Plain .NET read: Get-Content attaches PSPath/PSDrive properties that Windows PowerShell 5.1's
        # ConvertTo-Json serialises recursively, turning a small skill into gigabytes.
        $files[$relative] = Repair-Mojibake ([IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF))
    }
    $files
}

function Get-SkillTextKey {
    # Compares skills by repaired text, so a corrupted copy of an approved skill matches the approved one.
    param([hashtable]$Files)
    ($Files.Keys | Sort-Object | ForEach-Object { $_ + "`0" + $Files[$_] }) -join "`0`0"
}
