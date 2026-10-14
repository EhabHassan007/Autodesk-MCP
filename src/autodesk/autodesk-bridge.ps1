param(
    [ValidatePattern('^\d{4}$')]
    [string]$RevitVersion = '2024'
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

[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
while ($null -ne ($line = [Console]::ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $request = $line | ConvertFrom-Json }
    catch {
        [Console]::WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}')
        continue
    }
    if ($null -eq $request.id) { continue }

    $response = @{jsonrpc='2.0';id=$request.id}
    switch ($request.method) {
        'initialize' {
            $protocol = '2024-11-05'
            if ($request.params.protocolVersion -in @('2024-11-05','2025-03-26','2025-06-18','2025-11-25')) {
                $protocol = $request.params.protocolVersion
            }
            $response.result = @{
                protocolVersion = $protocol
                capabilities = @{tools=@{}}
                serverInfo = @{name='Autodesk MCP Connector';version='1.0.0'}
                instructions = 'One local Autodesk connector for AutoCAD and Revit. For AutoCAD, read drawing_info before edits and save only when explicitly requested. For Revit, call list_sessions when multiple sessions may be open, read document_info before writes, pass expected_document, and verify every write with a separate read.'
            }
        }
        'ping' { $response.result = @{} }
        'tools/list' { $response.result = @{tools=$toolList} }
        'tools/call' {
            try {
                $name = [string]$request.params.name
                if ($name -in $autoCadToolNames) {
                    $data = Invoke-AutoCadMcpTool $name $request.params.arguments
                }
                elseif ($name -in $revitToolNames) {
                    $data = Invoke-RevitMcpTool $name $request.params.arguments
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
    [Console]::WriteLine(($response | ConvertTo-Json -Depth 30 -Compress))
}
