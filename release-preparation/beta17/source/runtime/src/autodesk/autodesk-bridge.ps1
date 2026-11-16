param(
    [ValidatePattern('^\d{4}$')]
    [string]$RevitVersion = '2024',
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

$autoCadBridge = Join-Path $PSScriptRoot '..\autocad\autocad-bridge.ps1'
$revitBridge = Join-Path $PSScriptRoot '..\revit\revit-bridge.ps1'
foreach ($required in @($autoCadBridge, $revitBridge)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Autodesk MCP component was not found: $required"
    }
}

$autoCadModule = New-Module -Name AutodeskMcpAutoCad -ArgumentList $autoCadBridge -ScriptBlock {
    param([string]$Bridge)
    . $Bridge -LibraryOnly
    function Get-McpTools { @($toolList) }
    function Invoke-McpTool($Name, $Arguments) { try { Invoke-CadTool $Name $Arguments } finally { Clear-CadReferences } }
    function Get-McpConnectionStatus($Arguments) { try { Get-AutoCadConnectionStatus } finally { Clear-CadReferences } }
    Export-ModuleMember -Function Get-McpTools, Invoke-McpTool, Get-McpConnectionStatus
}
$revitModule = New-Module -Name AutodeskMcpRevit -ArgumentList $revitBridge, $RevitVersion -ScriptBlock {
    param([string]$Bridge, [string]$Version)
    . $Bridge -LibraryOnly -RevitVersion $Version
    function Get-McpTools { @($toolList) }
    function Invoke-McpTool($Name, $Arguments) { Invoke-RevitTool $Name $Arguments }
    function Get-McpConnectionStatus($Arguments) { Get-RevitConnectionStatus $Arguments }
    Export-ModuleMember -Function Get-McpTools, Invoke-McpTool, Get-McpConnectionStatus
}

Import-Module $autoCadModule -Prefix AutoCad -Force
Import-Module $revitModule -Prefix Revit -Force

$autoCadTools = @(Get-AutoCadMcpTools)
# connection_status is answered here for both products, so it is described for both.
$revitTools = @(Get-RevitMcpTools | ForEach-Object {
    if ([string]$_['name'] -ne 'connection_status') { return $_ }
    $tool = $_.Clone()
    $tool['description'] = 'Check whether the Smart Connector can reach AutoCAD and Revit. Reports AutoCAD (running full AutoCAD over COM, version, active drawing) and Revit (add-in sessions, active document, last error) separately. Succeeds when either product is reachable; a product that is closed is reported, not an error. Optional session_id selects a Revit session.'
    $tool
})
$workflowTools = @(
    @{name='list_skill_workflows';description='List shared workflow guidance available through this connector, each with its category (revit, autocad, 3ds-max, other-software, linkedin-marketing, branding-ci, general). Read the relevant workflow before a task.';inputSchema=@{type='object';properties=@{}};annotations=@{readOnlyHint=$true}},
    @{name='read_skill_workflow';description='Read a shared Autodesk workflow or its supporting text file. This returns guidance and does not execute code or modify a model.';inputSchema=@{type='object';properties=@{name=@{type='string';description='Skill folder name from list_skill_workflows'};file=@{type='string';description='Relative text file within the skill; defaults to SKILL.md'}};required=@('name')};annotations=@{readOnlyHint=$true}}
    @{name='get_revit_rules';description='Get the team''s Revit rules: decisions, lessons and rejected approaches, by category. Call this FIRST before any Revit work and follow every rule returned; the Revit model tools refuse to run until it has been called in the session. Returns guidance only and does not touch a model.';inputSchema=@{type='object';properties=@{}};annotations=@{readOnlyHint=$true}}
)
$toolList = @($autoCadTools + $revitTools + $workflowTools)
$autoCadToolNames = @($autoCadTools | ForEach-Object { [string]$_['name'] })
$revitToolNames = @($revitTools | ForEach-Object { [string]$_['name'] })
$readOnlyTools = @{}
foreach ($tool in $toolList) {
    $readOnlyTools[[string]$tool['name']] = [bool]$tool['annotations']['readOnlyHint']
}

$versionPath = Join-Path $PSScriptRoot '..\..\VERSION'
$connectorVersion = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    (Get-Content -LiteralPath $versionPath -Raw).Trim()
}
else { 'development' }

. (Join-Path $PSScriptRoot '..\..\scripts\SkillLibrary.ps1')

# Skills shipped with the connector (in category folders) and the approved cache downloaded by
# Skills Sync (flat, one folder per skill). The approved cache wins: it follows the latest approval.
function Get-WorkflowSkills {
    $skills=@{}
    foreach($skill in Get-SkillFolders ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../.agents/skills')))){$skills[$skill.Name]=$skill}
    foreach($skill in Get-SkillFolders (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection/approved-skills')){
        $category=if($skill.Category){$skill.Category}elseif($skills.ContainsKey($skill.Name)){$skills[$skill.Name].Category}else{''}
        $skills[$skill.Name]=[pscustomobject]@{Name=$skill.Name;Category=$category;Path=$skill.Path}
    }
    $skills
}

function Get-SharedWorkflows {
    $skills=Get-WorkflowSkills
    @($skills.Values|Where-Object {((Get-Item -LiteralPath $_.Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0}|
        Sort-Object @{Expression={if($_.Category){$_.Category}else{'zz'}}},Name|
        ForEach-Object {@{name=$_.Name;category=$(if($_.Category){$_.Category}else{'uncategorized'});file='SKILL.md'}})
}

function Read-SharedWorkflow {
    param([string]$Name,[string]$File='SKILL.md')
    if ($Name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {throw 'Invalid skill name.'}
    if ([string]::IsNullOrWhiteSpace($File)) {$File='SKILL.md'}
    $parts=@($File -split '[\\/]')
    if ([IO.Path]::IsPathRooted($File) -or $File.Contains(':') -or @($parts|Where-Object {$_ -in @('','..','.')}).Count) {throw 'Use a relative file path within the selected skill.'}
    $skills=Get-WorkflowSkills
    if(-not $skills.ContainsKey($Name)){throw 'Skill file was not found.'}
    $path=$skills[$Name].Path
    $folder=Get-Item -LiteralPath $path -Force
    if(($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked skill paths cannot be read.'}
    foreach($part in $parts){
        $path=Join-Path $path $part
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked skill paths cannot be read.'}
    }
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Skill file was not found.'}
    $item=Get-Item -LiteralPath $path
    if($item.Length -gt 256KB -or $item.Extension.ToLowerInvariant() -notin @('.md','.txt','.json','.yaml','.yml','.toml','.py','.ps1','.js','.ts','.sh','.csv','.xml')){throw 'Only small skill text files can be read.'}
    @{name=$Name;file=$File;content=([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))}
}

# Read-only status for both products. Succeeds when either is reachable; otherwise the error
# message carries both product summaries so the client can tell the user what to start.
function Get-AutodeskConnectionStatus {
    param([object]$Arguments)
    $autoCad = Get-AutoCadMcpConnectionStatus $Arguments
    $revit = Get-RevitMcpConnectionStatus $Arguments
    $summary = "AutoCAD: $($autoCad.summary) Revit: $($revit.summary)"
    if (-not ($autoCad.available -or $revit.available)) {
        throw "Smart Connector is running, but neither AutoCAD nor Revit is reachable. $summary"
    }
    @{connected=$true; summary=$summary; bridge=@{kind='powershell'; version=$connectorVersion; warning='This is the old PowerShell bridge. It lacks apply_plan, execute_autocad and generate_detail, so every object costs one call. Open Smart Connector, run Repair, then restart the AI app.'}; autocad=$autoCad; revit=$revit}
}

function Invoke-WithWriteLock {
    param([string]$Name, [scriptblock]$Operation)

    if ($readOnlyTools[$Name]) { return (& $Operation) }

    $mutex = New-Object Threading.Mutex($false, 'Local\AutodeskMcpConnector.ModelWrite')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(2)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw 'Another Codex or Claude session is modifying an Autodesk model. Wait for it to finish and retry.'
        }
        & $Operation
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Every Revit model tool needs the Revit rules to have been read in this session, and again after two hours.
$script:RevitRulesReadAt = [DateTime]::MinValue
$revitRulesFresh = [TimeSpan]::FromHours(2)
$revitRulesFirst = 'Call get_revit_rules first and follow every rule it returns, then repeat this call. The Revit rules are read once per session and again after two hours.'

# The team's Revit rules (revit-rules/rules.json in the shipped or approved skill library), returned by get_revit_rules.
function Get-RevitRules {
    try { $text = (Read-SharedWorkflow -Name 'revit-rules' -File 'rules.json').content }
    catch { throw 'The Revit rules are not installed (revit-rules/rules.json). Reinstall the connector or run Skills Sync, then call get_revit_rules again.' }
    try { $parsed = $text.TrimStart([char]0xFEFF) | ConvertFrom-Json }
    catch { throw 'The Revit rules file (revit-rules/rules.json) is not valid JSON. Run Skills Sync or reinstall, then call get_revit_rules again.' }
    $rules = @(@($parsed.rules) | Where-Object { $null -ne $_ } | ForEach-Object {
        @{id=[string]$_.id;title=[string]$_.title;category=[string]$_.category;decided_on=[string]$_.decided_on;instruction=[string]$_.instruction}
    } | Sort-Object { $_['category'] })
    @{
        must_follow = 'These rules apply to every Revit task. Follow every rule. If a rule conflicts with a skill or the request, say so and ask; never use a rejected approach. Report any rule you cannot follow.'
        count = $rules.Count
        updated = [string]$parsed.updated
        rules = $rules
        to_add_a_rule = 'Only when the user asks after a finished task: read skill revit-rules (read_skill_workflow) for how to draft and save a rule.'
    }
}

function Get-AutodeskMcpTools {
    @($toolList)
}

# Records which skill or tool was used, by name only (never arguments or results), for the
# administrator's usage report. Only enrolled PCs record. Failures never affect the tool call.
function Write-UsageEvent {
    param([string]$Kind, [string]$Name)
    try {
        if ($Name -notmatch '^[A-Za-z0-9_.:-]{1,100}$') { return }
        $state = Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
        if (-not (Test-Path -LiteralPath (Join-Path $state 'service.json') -PathType Leaf)) { return }
        $line = (@{kind=$Kind;name=$Name;day=(Get-Date).ToString('yyyy-MM-dd')} | ConvertTo-Json -Compress) + "`n"
        $path = Join-Path $state 'usage.jsonl'
        # Several Codex/Claude sessions can append at once; retry briefly if the file is busy.
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try { [IO.File]::AppendAllText($path, $line, (New-Object Text.UTF8Encoding($false))); return }
            catch [IO.IOException] { Start-Sleep -Milliseconds 50 }
        }
    }
    catch { }
}

function Invoke-AutodeskMcpRequest {
    param([Parameter(Mandatory=$true)][object]$Request)

    if ($null -eq $Request.id) { return $null }

    $response = @{jsonrpc='2.0';id=$Request.id}
    switch ([string]$Request.method) {
        'initialize' {
            $protocol = '2024-11-05'
            if ($Request.params.protocolVersion -in @('2024-11-05','2025-03-26','2025-06-18','2025-11-25','2026-07-28')) {
                $protocol = [string]$Request.params.protocolVersion
            }
            $response.result = @{
                protocolVersion = $protocol
                capabilities = @{tools=@{}}
                serverInfo = @{name='Smart Connector';version=$connectorVersion}
                instructions = 'Before any Revit work call get_revit_rules and follow every rule it returns; the Revit model tools refuse to run until it has been called. Use list_skill_workflows and read_skill_workflow to load relevant shared guidance before CAD/BIM tasks; no separate skill upload is required to read this guidance. Authenticated Autodesk connector for Codex and Claude with AutoCAD and Revit tools. Model-changing calls are serialized across AI clients. For AutoCAD, read drawing_info before edits and save only when explicitly requested. For Revit, call list_sessions when multiple sessions may be open, read document_info before writes, pass expected_document, and verify every write with a separate read. Revit errors are typed: [compile_error] and [runtime_error] are problems in the submitted code, not a lost connection. After a timeout never run the request again: call connection_status first.'
            }
        }
        'ping' { $response.result = @{} }
        'tools/list' { $response.result = @{tools=$toolList} }
        'tools/call' {
            try {
                $name = [string]$Request.params.name
                if ($name -eq 'list_skill_workflows') {
                    $data = @{skills=@(Get-SharedWorkflows)}
                }
                elseif ($name -eq 'read_skill_workflow') {
                    $data = Read-SharedWorkflow -Name ([string]$Request.params.arguments.name) -File ([string]$Request.params.arguments.file)
                }
                elseif ($name -eq 'get_revit_rules') {
                    $data = Get-RevitRules
                    $script:RevitRulesReadAt = [DateTime]::UtcNow
                }
                elseif ($name -eq 'connection_status') {
                    $data = Get-AutodeskConnectionStatus $Request.params.arguments
                }
                elseif ($name -in $autoCadToolNames) {
                    $data = Invoke-WithWriteLock $name { Invoke-AutoCadMcpTool $name $Request.params.arguments }
                }
                elseif ($name -in $revitToolNames) {
                    if ($name -ne 'list_sessions' -and ([DateTime]::UtcNow - $script:RevitRulesReadAt) -gt $revitRulesFresh) { throw $revitRulesFirst }
                    $data = Invoke-WithWriteLock $name { Invoke-RevitMcpTool $name $Request.params.arguments }
                }
                else { throw "Unknown Autodesk MCP tool: $name" }
                $response.result = @{content=@(@{type='text';text=($data | ConvertTo-Json -Depth 20 -Compress)});isError=$false}
                # Opening a skill's SKILL.md counts as using that skill; supporting files are not counted.
                if ($name -eq 'read_skill_workflow') {
                    if ([string]::IsNullOrWhiteSpace([string]$Request.params.arguments.file) -or [string]$Request.params.arguments.file -eq 'SKILL.md') {
                        Write-UsageEvent 'skill' ([string]$Request.params.arguments.name)
                    }
                }
                elseif ($name -ne 'list_skill_workflows') { Write-UsageEvent 'tool' $name }
            }
            catch {
                $response.result = @{content=@(@{type='text';text=$_.Exception.Message});isError=$true}
            }
        }
        default { $response.error = @{code=-32601;message='Method not found'} }
    }
    $response
}

if (-not $LibraryOnly) {
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    while ($null -ne ($line = [Console]::ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $request = $line | ConvertFrom-Json }
        catch {
            [Console]::WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}')
            continue
        }
        $response = Invoke-AutodeskMcpRequest -Request $request
        if ($null -eq $response) { continue }
        [Console]::WriteLine(($response | ConvertTo-Json -Depth 30 -Compress))
    }
}
