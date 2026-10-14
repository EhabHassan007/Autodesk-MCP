$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '..\autodesk-bridge.ps1'
$inputLines = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}',
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"not_an_autodesk_tool","arguments":{}}}'
) -join "`n"
$output = $inputLines | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bridge
if ($LASTEXITCODE -ne 0) { throw 'Autodesk MCP Connector process failed.' }
$responses = @($output | ForEach-Object { $_ | ConvertFrom-Json })
if ($responses.Count -ne 4) { throw 'Expected four MCP responses.' }
if ($responses[0].result.serverInfo.name -ne 'Autodesk MCP Connector') { throw 'Connector display name is incorrect.' }
if ($responses[0].result.protocolVersion -ne '2025-03-26') { throw 'Protocol negotiation failed.' }
$names = @($responses[1].result.tools | Select-Object -ExpandProperty name)
foreach ($required in @('drawing_info','list_layers','list_entities','save_drawing','list_sessions','document_info','list_selected','execute_csharp')) {
    if ($required -notin $names) { throw "Missing combined tool: $required" }
}
if ($names.Count -ne (@($names | Select-Object -Unique)).Count) { throw 'Combined tool names are not unique.' }
if ($responses[2].result.isError) { throw 'Revit tool routing failed.' }
if (-not $responses[3].result.isError -or $responses[3].result.content[0].text -notlike 'Unknown Autodesk MCP tool:*') {
    throw 'Unknown tools were not rejected by the combined connector.'
}
'PASS: Autodesk MCP Connector exposes AutoCAD and Revit through one MCP registration.'
