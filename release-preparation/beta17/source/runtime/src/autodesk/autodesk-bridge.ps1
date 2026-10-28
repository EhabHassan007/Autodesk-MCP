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
    function Invoke-McpTool($Name, $Arguments) { Invoke-CadTool $Name $Arguments }
    Export-ModuleMember -Function Get-McpTools, Invoke-McpTool
}
$revitModule = New-Module -Name AutodeskMcpRevit -ArgumentList $revitBridge, $RevitVersion -ScriptBlock {
    param([string]$Bridge, [string]$Version)
    . $Bridge -LibraryOnly -RevitVersion $Version
    function Get-McpTools { @($toolList) }
    function Invoke-McpTool($Name, $Arguments) { Invoke-RevitTool $Name $Arguments }
    Export-ModuleMember -Function Get-McpTools, Invoke-McpTool
}

Import-Module $autoCadModule -Prefix AutoCad -Force
Import-Module $revitModule -Prefix Revit -Force

$autoCadTools = @(Get-AutoCadMcpTools)
$revitTools = @(Get-RevitMcpTools)
$workflowTools = @(
    @{name='list_skill_workflows';description='List shared Autodesk workflow guidance available through this connector. Read the relevant workflow before a CAD/BIM task.';inputSchema=@{type='object';properties=@{}};annotations=@{readOnlyHint=$true}},
    @{name='read_skill_workflow';description='Read a shared Autodesk workflow or its supporting text file. This returns guidance and does not execute code or modify a model.';inputSchema=@{type='object';properties=@{name=@{type='string';description='Skill folder name from list_skill_workflows'};file=@{type='string';description='Relative text file within the skill; defaults to SKILL.md'}};required=@('name')};annotations=@{readOnlyHint=$true}}
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

function Get-WorkflowRoot {
    param([string]$Name)
    $cache=Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection/approved-skills'
    if($Name -and (Test-Path -LiteralPath (Join-Path (Join-Path $cache $Name) 'SKILL.md'))){return $cache}
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../.agents/skills'))
}

function Get-SharedWorkflows {
    $roots=@((Get-WorkflowRoot),(Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection/approved-skills'))
    $names=@{}
    foreach($root in $roots){
        if(-not(Test-Path $root)){continue}
        foreach($item in Get-ChildItem -LiteralPath $root -Directory){
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and (Test-Path -LiteralPath (Join-Path $item.FullName 'SKILL.md'))){$names[$item.Name]=$true}
        }
    }
    @($names.Keys|Sort-Object|ForEach-Object {@{name=$_;file='SKILL.md'}})
}

function Read-SharedWorkflow {
    param([string]$Name,[string]$File='SKILL.md')
    if ($Name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {throw 'Invalid skill name.'}
    if ([string]::IsNullOrWhiteSpace($File)) {$File='SKILL.md'}
    $parts=@($File -split '[\\/]')
    if ([IO.Path]::IsPathRooted($File) -or $File.Contains(':') -or @($parts|Where-Object {$_ -in @('','..','.')}).Count) {throw 'Use a relative file path within the selected skill.'}
    $root=Get-WorkflowRoot -Name $Name
    $path=$root
    foreach($part in @($Name)+$parts){
        $path=Join-Path $path $part
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked skill paths cannot be read.'}
    }
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Skill file was not found.'}
    $item=Get-Item -LiteralPath $path
    if($item.Length -gt 256KB -or $item.Extension.ToLowerInvariant() -notin @('.md','.txt','.json','.yaml','.yml','.toml','.py','.ps1','.js','.ts','.sh','.csv','.xml')){throw 'Only small skill text files can be read.'}
    @{name=$Name;file=$File;content=([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))}
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

function Get-AutodeskMcpTools {
    @($toolList)
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
                serverInfo = @{name='Autodesk MCP Connector';version=$connectorVersion}
                instructions = 'Use list_skill_workflows and read_skill_workflow to load relevant shared guidance before CAD/BIM tasks; no separate skill upload is required to read this guidance. Authenticated Autodesk connector for Codex and Claude with AutoCAD and Revit tools. Model-changing calls are serialized across AI clients. For AutoCAD, read drawing_info before edits and save only when explicitly requested. For Revit, call list_sessions when multiple sessions may be open, read document_info before writes, pass expected_document, and verify every write with a separate read.'
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
                elseif ($name -in $autoCadToolNames) {
                    $data = Invoke-WithWriteLock $name { Invoke-AutoCadMcpTool $name $Request.params.arguments }
                }
                elseif ($name -in $revitToolNames) {
                    $data = Invoke-WithWriteLock $name { Invoke-RevitMcpTool $name $Request.params.arguments }
                }
                else { throw "Unknown Autodesk MCP tool: $name" }
                $response.result = @{content=@(@{type='text';text=($data | ConvertTo-Json -Depth 20 -Compress)});isError=$false}
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
