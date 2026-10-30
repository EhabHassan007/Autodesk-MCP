[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$RepositoryUrl = 'https://github.com/EhabHassan007/Autodesk-MCP.git',
    [string]$BaseBranch = 'main',
    [string]$Reviewer = 'EhabHassan007',
    [string]$CandidateRoot = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\team-candidates'),
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\team-collection'),
    [switch]$IncludeSavedSkills,
    [string[]]$AdditionalSkillRoots = @(),
    [switch]$LibraryOnly,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

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

function Get-RequiredCommand {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "$Name is required for automatic team submission." }
    $command.Source
}

function Invoke-External {
    param([string]$FilePath, [string[]]$Arguments, [switch]$AllowFailure)
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "$FilePath failed with exit code $exitCode.`n$details"
    }
    [pscustomobject]@{ ExitCode=$exitCode; Output=@($output) }
}

function Get-DirectoryHash {
    param([string]$Path)
    $rows = foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\','/').Replace('\','/')
        $hash = Get-Sha256Hex -Path $file.FullName
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
        if ($item.Extension.ToLowerInvariant() -notin @('.md','.txt','.json','.yaml','.yml','.toml','.py','.ps1','.js','.ts','.sh','.csv','.xml')) { throw ('Unsupported candidate file type: ' + $item.Name) }
        if ($item.Length -gt 256KB) { throw "Candidate file exceeds 256 KB: $($item.FullName)" }
        if ($blockedExtensions -contains $item.Extension.ToLowerInvariant()) { throw "Binary or project file is not allowed in an automatic submission: $($item.FullName)" }
        if (Select-String -LiteralPath $item.FullName -Pattern $sensitivePattern -Quiet -ErrorAction Stop) {
            throw "Potential credential, personal path, client location, or email found: $($item.FullName)"
        }
    }
}

function Assert-ChildPath {
    param([string]$Parent, [string]$Child)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $childFull = [IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe target path: $childFull"
    }
}

if ($LibraryOnly) { return }

$collector = Join-Path $PSScriptRoot 'collect-skills-for-review.ps1'
if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) { throw "Collector was not found: $collector" }
New-Item -ItemType Directory -Path $CandidateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$reviewRoot = Join-Path $StateRoot ("review-" + $stamp)
$engine = (Get-Process -Id $PID).Path
# Invoke the collector in this process so array-valued roots keep their boundaries.
$collectorOutput = & $collector -RepositoryRoot $RepositoryRoot -OutputRoot $reviewRoot -AdditionalSkillRoots (@($CandidateRoot) + @($AdditionalSkillRoots)) -OnlyAdditionalSkillRoots:(-not $IncludeSavedSkills)

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
    try { $name = Get-SkillName $candidate.FullName }
    catch { Write-Warning ('Skipped invalid skill: ' + $candidate.Name); continue }
    try { Test-SafeCandidate $candidate.FullName }
    catch { Write-Warning ("Skipped candidate {0}: {1}" -f $name, $_.Exception.Message); continue }
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
$repositoryUri = [Uri]$RepositoryUrl
$repositorySlug = $repositoryUri.AbsolutePath.Trim('/').Replace('.git','')
$identityPath = Join-Path $StateRoot 'installation-id.txt'
if (-not (Test-Path -LiteralPath $identityPath)) { [IO.File]::WriteAllText($identityPath, [guid]::NewGuid().ToString('N')) }
$identity = (Get-Content -LiteralPath $identityPath -Raw).Trim()
$batchText = (($selected.Hash | Sort-Object) -join ':')
$sha = [Security.Cryptography.SHA256]::Create()
try { $batchId = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($batchText)))).Replace('-','').Substring(0,20).ToLowerInvariant() }
finally { $sha.Dispose() }
$branch = "skill-intake/$identity/$batchId"
$checkout = Join-Path ([IO.Path]::GetTempPath()) ("BimCadMcp-intake-" + [Guid]::NewGuid().ToString('N'))
$previousPrompt = $env:GIT_TERMINAL_PROMPT
$previousInteractive = $env:GCM_INTERACTIVE
$env:GCM_INTERACTIVE = 'Never'
$env:GIT_TERMINAL_PROMPT = '0'
try {
    $credentialQuery = "protocol=https`nhost=github.com`n`n"
    $credentialLines = @($credentialQuery | & $git credential fill)
    $credential = @{}
    foreach ($line in $credentialLines) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) { $credential[$line.Substring(0,$separator)] = $line.Substring($separator + 1) }
    }
    if ([string]::IsNullOrWhiteSpace([string]$credential.password)) {
        throw 'Git Credential Manager did not return GitHub credentials. Open connector Settings > Connect GitHub, then retry.'
    }
    $headers = @{
        Authorization = 'Bearer ' + [string]$credential.password
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'BIM-CAD-MCP-team-intake'
    }
    # Use the authenticated account's GitHub identity without changing global Git settings.
    $account = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/user' -Headers $headers
    if ([string]$account.login -notmatch '^[A-Za-z0-9-]+$' -or [string]$account.id -notmatch '^\d+$') {
        throw 'GitHub did not return a valid account identity. Use Settings > Connect GitHub and retry.'
    }
    $authorName = [string]$account.login
    $authorEmail = '{0}+{1}@users.noreply.github.com' -f $account.id,$account.login
    $null = Invoke-External $git @('clone','--quiet','--single-branch','--branch',$BaseBranch,$RepositoryUrl,$checkout)
    $null = Invoke-External $git @('-C',$checkout,'config','--local','user.name',$authorName)
    $null = Invoke-External $git @('-C',$checkout,'config','--local','user.email',$authorEmail)
    $remoteBranch = Invoke-External $git @('-C',$checkout,'ls-remote','--heads','origin',"refs/heads/$branch")
    $branchExists = @($remoteBranch.Output).Count -gt 0
    if ($branchExists) {
        $null = Invoke-External $git @('-C',$checkout,'fetch','origin',"refs/heads/$branch")
        $null = Invoke-External $git @('-C',$checkout,'switch','-c',$branch,'FETCH_HEAD')
    }
    else { $null = Invoke-External $git @('-C',$checkout,'switch','-c',$branch) }
    $skillsRoot = Join-Path $checkout '.agents\skills'
    New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
    foreach ($candidate in $selected) {
        $target = Join-Path $skillsRoot $candidate.Name
        Assert-ChildPath $skillsRoot $target
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath $candidate.Path -Destination $target -Recurse -Force
    }

    $paths = @($selected | ForEach-Object { ".agents/skills/$($_.Name)" })
    $null = Invoke-External $git (@('-C',$checkout,'add','--') + $paths)
    $diff = Invoke-External $git @('-C',$checkout,'diff','--cached','--quiet') -AllowFailure
    if ($diff.ExitCode -eq 0 -and -not $branchExists) {
        [pscustomobject]@{status='already_approved';skills=@($selected.Name)} | ConvertTo-Json -Depth 4
        exit 0
    }

    $title = "Team skill review: " + (($selected.Name | Sort-Object) -join ', ')
    if ($diff.ExitCode -eq 1) { $null = Invoke-External $git @('-C',$checkout,'commit','--quiet','-m',$title) }
    elseif ($diff.ExitCode -ne 0) { throw 'Could not inspect staged changes.' }
    $null = Invoke-External $git @('-C',$checkout,'push','--quiet','--set-upstream','origin',$branch)

    $bodyPath = Join-Path $checkout 'team-review-body.md'
    $body = New-Object System.Collections.Generic.List[string]
    $body.Add('Automated team knowledge candidate for owner review.')
    $body.Add('')
    $body.Add('Automated local checks found no flagged content in these candidates. These checks are not exhaustive; review contents before approval.')
    $body.Add('The candidate is untrusted until the repository owner reviews and approves it.')
    $body.Add('')
    $body.Add('Skills:')
    foreach ($candidate in $selected | Sort-Object Name) {
        $body.Add(('- `{0}` - `{1}`' -f $candidate.Name, $candidate.Hash.Substring(0,12).ToLowerInvariant()))
    }
    Set-Content -LiteralPath $bodyPath -Value $body -Encoding UTF8

    try {
        $owner = $repositorySlug.Split('/')[0]
        $repository = $repositorySlug.Split('/')[1]
        $existingUri = "https://api.github.com/repos/$owner/$repository/pulls?state=all&head=$owner`:$branch"
        $existing = @(Invoke-RestMethod -Method Get -Uri $existingUri -Headers $headers | Where-Object { $null -ne $_ -and $_.html_url })
        if ($existing.Count -gt 0) {
            $prUrl = [string]$existing[0].html_url
        }
        else {
            $payload = @{title=$title;head=$branch;base=$BaseBranch;body=(Get-Content -LiteralPath $bodyPath -Raw);draft=$true} | ConvertTo-Json -Depth 5
            $created = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$owner/$repository/pulls" -Headers $headers -ContentType 'application/json' -Body $payload
            $prUrl = [string]$created.html_url
            if (-not [string]::IsNullOrWhiteSpace($Reviewer)) {
                $reviewPayload = @{reviewers=@($Reviewer)} | ConvertTo-Json -Depth 3
                try {
                    $null = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$owner/$repository/pulls/$($created.number)/requested_reviewers" -Headers $headers -ContentType 'application/json' -Body $reviewPayload
                }
                catch { }
            }
        }
    }
    finally {
        $headers.Authorization = $null
        $credential.Clear()
        $credentialLines = $null
    }

    foreach ($candidate in $selected) { $submitted[$candidate.Hash] = $prUrl }
    $temporaryLedger = $ledgerPath + '.tmp'
    $submitted | ConvertTo-Json | Set-Content -LiteralPath $temporaryLedger -Encoding UTF8
    Move-Item -LiteralPath $temporaryLedger -Destination $ledgerPath -Force

    [pscustomobject]@{status='submitted_for_approval';pull_request=$prUrl;reviewer=$Reviewer;skills=@($selected.Name)} | ConvertTo-Json -Depth 5
}
finally {
    if ($headers) { $headers.Authorization = $null }
    if ($credential) { $credential.Clear() }
    $credentialLines = $null
    $env:GIT_TERMINAL_PROMPT = $previousPrompt
    $env:GCM_INTERACTIVE = $previousInteractive
    if (Test-Path -LiteralPath $checkout) {
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        $resolvedCheckout = [IO.Path]::GetFullPath($checkout)
        if ($resolvedCheckout.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $checkout -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
