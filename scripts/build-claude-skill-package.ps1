[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$sourceRoot = Join-Path $RepositoryRoot '.agents\skills'
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Skill library was not found: $sourceRoot"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $RepositoryRoot) 'Autodesk-MCP-Skills-for-Claude.zip'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("autodesk-mcp-claude-skill-{0}" -f [Guid]::NewGuid().ToString('N'))
$bundleRoot = Join-Path $temporaryRoot 'autodesk-mcp-bim-workflows'
$referenceRoot = Join-Path $bundleRoot 'references'

try {
    New-Item -ItemType Directory -Path $referenceRoot -Force | Out-Null
    $index = New-Object System.Collections.Generic.List[string]
    . (Join-Path $PSScriptRoot 'SkillLibrary.ps1')
    # References stay flat by skill name; the library itself is grouped in category folders.
    foreach ($skill in Get-SkillFolders $sourceRoot | ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.Path } } | Sort-Object Name) {
        $manifest = Join-Path $skill.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }

        $content = Get-Content -LiteralPath $manifest -Raw
        $descriptionMatch = [regex]::Match($content, '(?m)^description:\s*(.+?)\s*$')
        $description = if ($descriptionMatch.Success) { $descriptionMatch.Groups[1].Value.Trim() } else { 'Approved Autodesk MCP workflow.' }
        Copy-Item -LiteralPath $skill.FullName -Destination (Join-Path $referenceRoot $skill.Name) -Recurse -Force
        $index.Add(("- [{0}](references/{0}/SKILL.md): {1}" -f $skill.Name, $description))
    }

    $entrypoint = @"
---
name: autodesk-mcp-bim-workflows
description: Work with AutoCAD and Revit through Autodesk MCP, including modelling, documentation, coordination, rooms, links, sheets, dimensions, QA, and recovery.
---

# Autodesk MCP BIM workflows

Use this skill for Autodesk AutoCAD and Revit work performed through the local Autodesk MCP Connector.

Read only the reference that matches the current task. Preserve the user's model and documentation intent, follow every MUST rule in the selected reference, and verify live model changes by reading the affected elements back from Autodesk MCP. A skill supplies procedure; it does not grant permission for unrelated changes.

## Workflow references

$($index -join "`r`n")
"@
    Set-Content -LiteralPath (Join-Path $bundleRoot 'SKILL.md') -Value $entrypoint -Encoding UTF8

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { Remove-Item -LiteralPath $OutputPath -Force }
    Compress-Archive -LiteralPath $bundleRoot -DestinationPath $OutputPath -CompressionLevel Optimal

    [pscustomobject]@{
        Path = [IO.Path]::GetFullPath($OutputPath)
        SkillCount = $index.Count
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedSystemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemporary.StartsWith($resolvedSystemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected temporary path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
