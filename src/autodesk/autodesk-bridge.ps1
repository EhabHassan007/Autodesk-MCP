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
$toolList = @($autoCadTools + $revitTools)
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
                instructions = 'Authenticated Autodesk connector for Codex and Claude with AutoCAD and Revit tools. Model-changing calls are serialized across AI clients. For AutoCAD, read drawing_info before edits and save only when explicitly requested. For Revit, call list_sessions when multiple sessions may be open, read document_info before writes, pass expected_document, and verify every write with a separate read.'
            }
        }
        'ping' { $response.result = @{} }
        'tools/list' { $response.result = @{tools=$toolList} }
        'tools/call' {
            try {
                $name = [string]$Request.params.name
                if ($name -in $autoCadToolNames) {
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
