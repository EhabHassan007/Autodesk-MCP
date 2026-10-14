[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/BIM-CAD---MCP.git',
    [string]$BaseBranch = 'main',
    [string]$Reviewer = 'EhabHassan007',
    [string]$CandidateRoot = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\team-candidates'),
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\team-collection'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Get-RequiredCommand {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "$Name is required for automatic team submission." }
    $command.Source
}

function Invoke-External {
    param([string]$FilePath, [string[]]$Arguments, [switch]$AllowFailure)
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "$FilePath failed with exit code $exitCode.`n$details"
    }
    [pscustomobject]@{ ExitCode=$exitCode; Output=@($output) }
}

function Get-DirectoryHash {
    param([string]$Path)
    $rows = foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\').Replace('\','/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        "$relative`t$hash"
    }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))
        ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','')
    }
    finally { $algorithm.Dispose() }
}

function Get-SkillName {
    param([string]$SkillPath)
    $manifest = Join-Path $SkillPath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Candidate has no SKILL.md: $SkillPath" }
    $content = Get-Content -LiteralPath $manifest -Raw
    $match = [regex]::Match($content, '(?m)^name:\s*([a-z0-9]+(?:-[a-z0-9]+)*)\s*$')
    if (-not $match.Success) { throw "Candidate has an invalid or missing skill name: $manifest" }
    $match.Groups[1].Value
}

function Test-SafeCandidate {
    param([string]$SkillPath)
    $blockedExtensions = @('.rvt','.rfa','.rte','.rft','.dwg','.dxf','.dgn','.nwc','.nwd','.ifc','.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.zip','.7z','.rar','.exe','.dll','.msi','.pfx','.key','.pem','.png','.jpg','.jpeg','.gif')
    $sensitivePattern = '(?i)(api[_ -]?key|access[_ -]?token|client[_ -]?secret|password\s*[:=]|github_pat_|gh[pousr]_[a-z0-9_]+|begin (rsa|openssh|ec) private key|[a-z]:\\users\\|\\\\[^\\\s]+\\[^\\\s]+|autodesk docs://|bim 360://|acc://|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b)'
    foreach ($item in Get-ChildItem -LiteralPath $SkillPath -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Links are not allowed in team candidates: $($item.FullName)" }
        if ($item.PSIsContainer) { continue }
        if ($item.Length -gt 256KB) { throw "Candidate file exceeds 256 KB: $($item.FullName)" }
        if ($blockedExtensions -contains $item.Extension.ToLowerInvariant()) { throw "Binary or project file is not allowed in an automatic submission: $($item.FullName)" }
        if (Select-String -LiteralPath $item.FullName -Pattern $sensitivePattern -Quiet -ErrorAction SilentlyContinue) {
            throw "Potential credential, personal path, client location, or email found: $($item.FullName)"
        }
    }
}

function Assert-ChildPath {
    param([string]$Parent, [string]$Child)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe target path: $childFull"
    }
}

$collector = Join-Path $RepositoryRoot 'scripts\collect-skills-for-review.ps1'
if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) { throw "Collector was not found: $collector" }
New-Item -ItemType Directory -Path $CandidateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reviewRoot = Join-Path $StateRoot ("review-" + $stamp)
$collectorOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $collector -RepositoryRoot $RepositoryRoot -OutputRoot $reviewRoot -AdditionalSkillRoots $CandidateRoot -OnlyAdditionalSkillRoots
if ($LASTEXITCODE -ne 0) { throw "Skill collection failed.`n$($collectorOutput -join [Environment]::NewLine)" }
$reviewDirectory = Get-ChildItem -LiteralPath $reviewRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $reviewDirectory) { throw 'The collector did not create a review directory.' }
$candidateDirectory = Join-Path $reviewDirectory.FullName 'candidates'
$candidateFolders = if (Test-Path -LiteralPath $candidateDirectory) { @(Get-ChildItem -LiteralPath $candidateDirectory -Directory) } else { @() }

$ledgerPath = Join-Path $StateRoot 'submitted-hashes.json'
$submitted = @{}
if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    try {
        $saved = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
        foreach ($property in $saved.PSObject.Properties) { $submitted[$property.Name] = [string]$property.Value }
    }
    catch { throw "Submission ledger is invalid: $ledgerPath" }
}

$selected = New-Object System.Collections.Generic.List[object]
$names = @{}
foreach ($candidate in $candidateFolders) {
    $name = Get-SkillName $candidate.FullName
    Test-SafeCandidate $candidate.FullName
    $hash = Get-DirectoryHash $candidate.FullName
    if ($submitted.ContainsKey($hash)) { continue }
    if ($names.ContainsKey($name) -and $names[$name] -ne $hash) { throw "Conflicting candidates were found for skill: $name" }
    if (-not $names.ContainsKey($name)) {
        $names[$name] = $hash
        $selected.Add([pscustomobject]@{Name=$name;Hash=$hash;Path=$candidate.FullName})
    }
}

if ($selected.Count -eq 0) {
    [pscustomobject]@{status='no_new_candidates';review=$reviewDirectory.FullName} | ConvertTo-Json
    exit 0
}

if ($DryRun) {
    [pscustomobject]@{
        status='dry_run'
        candidates=@($selected | ForEach-Object { [pscustomobject]@{name=$_.Name;hash=$_.Hash.Substring(0,12)} })
        review=$reviewDirectory.FullName
    } | ConvertTo-Json -Depth 5
    exit 0
}

$git = Get-RequiredCommand 'git'
$gh = Get-RequiredCommand 'gh'
$auth = Invoke-External $gh @('auth','status','--hostname','github.com') -AllowFailure
if ($auth.ExitCode -ne 0) { throw 'GitHub CLI is not authenticated. Run: gh auth login --hostname github.com' }
$gitName = (Invoke-External $git @('config','--global','user.name') -AllowFailure).Output | Select-Object -First 1
$gitEmail = (Invoke-External $git @('config','--global','user.email') -AllowFailure).Output | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$gitName) -or [string]::IsNullOrWhiteSpace([string]$gitEmail)) {
    throw 'Configure Git author name and email before enabling automatic submissions.'
}

$repositoryUri = [Uri]$RepositoryUrl
$repositorySlug = $repositoryUri.AbsolutePath.Trim('/').Replace('.git','')
$contributor = (($env:USERNAME + '-' + $env:COMPUTERNAME).ToLowerInvariant() -replace '[^a-z0-9-]','-').Trim('-')
$branch = "skill-intake/$contributor/$stamp"
$checkout = Join-Path ([IO.Path]::GetTempPath()) ("BimCadMcp-intake-" + [Guid]::NewGuid().ToString('N'))
$previousPrompt = $env:GIT_TERMINAL_PROMPT
$env:GIT_TERMINAL_PROMPT = '0'
try {
    $null = Invoke-External $git @('clone','--quiet','--single-branch','--branch',$BaseBranch,$RepositoryUrl,$checkout)
    $null = Invoke-External $git @('-C',$checkout,'switch','-c',$branch)
    $skillsRoot = Join-Path $checkout '.agents\skills'
    foreach ($candidate in $selected) {
        $target = Join-Path $skillsRoot $candidate.Name
        Assert-ChildPath $skillsRoot $target
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath $candidate.Path -Destination $target -Recurse -Force
    }

    $paths = @($selected | ForEach-Object { ".agents/skills/$($_.Name)" })
    $null = Invoke-External $git (@('-C',$checkout,'add','--') + $paths)
    $diff = Invoke-External $git @('-C',$checkout,'diff','--cached','--quiet') -AllowFailure
    if ($diff.ExitCode -eq 0) {
        [pscustomobject]@{status='already_approved';skills=@($selected.Name)} | ConvertTo-Json -Depth 4
        exit 0
    }

    $title = "Team skill review: " + (($selected.Name | Sort-Object) -join ', ')
    $null = Invoke-External $git @('-C',$checkout,'commit','--quiet','-m',$title)
    $null = Invoke-External $git @('-C',$checkout,'push','--quiet','--set-upstream','origin',$branch)

    $bodyPath = Join-Path $checkout 'team-review-body.md'
    $body = New-Object System.Collections.Generic.List[string]
    $body.Add('Automated team knowledge candidate for owner review.')
    $body.Add('')
    $body.Add('No model files, chat transcripts, credentials, personal paths, client cloud paths, or binary files passed the local submission gate.')
    $body.Add('The candidate is untrusted until the repository owner reviews and approves it.')
    $body.Add('')
    $body.Add('Skills:')
    foreach ($candidate in $selected | Sort-Object Name) {
        $body.Add(('- `{0}` - `{1}`' -f $candidate.Name, $candidate.Hash.Substring(0,12).ToLowerInvariant()))
    }
    Set-Content -LiteralPath $bodyPath -Value $body -Encoding UTF8

    $pr = Invoke-External $gh @('pr','create','--repo',$repositorySlug,'--base',$BaseBranch,'--head',$branch,'--reviewer',$Reviewer,'--title',$title,'--body-file',$bodyPath)
    $prUrl = [string]($pr.Output | Select-Object -Last 1)

    foreach ($candidate in $selected) { $submitted[$candidate.Hash] = $prUrl }
    $temporaryLedger = $ledgerPath + '.tmp'
    $submitted | ConvertTo-Json | Set-Content -LiteralPath $temporaryLedger -Encoding UTF8
    Move-Item -LiteralPath $temporaryLedger -Destination $ledgerPath -Force

    [pscustomobject]@{status='submitted_for_approval';pull_request=$prUrl;reviewer=$Reviewer;skills=@($selected.Name)} | ConvertTo-Json -Depth 5
}
finally {
    $env:GIT_TERMINAL_PROMPT = $previousPrompt
    if (Test-Path -LiteralPath $checkout) {
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedCheckout = [IO.Path]::GetFullPath($checkout)
        if ($resolvedCheckout.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $checkout -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
