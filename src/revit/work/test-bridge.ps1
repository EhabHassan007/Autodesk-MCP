$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '..\revit-bridge.ps1'
$inputLines = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
) -join "`n"
$output = $inputLines | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bridge
if ($LASTEXITCODE -ne 0) { throw 'Revit MCP bridge process failed.' }
$responses = @($output | ForEach-Object { $_ | ConvertFrom-Json })
if ($responses.Count -ne 2) { throw 'Expected two MCP responses.' }
if ($responses[0].result.protocolVersion -ne '2025-03-26') { throw 'Protocol negotiation failed.' }
$names = @($responses[1].result.tools | Select-Object -ExpandProperty name)
foreach ($required in @('document_info','list_levels','list_selected','get_element','set_parameter')) {
    if ($required -notin $names) { throw "Missing tool: $required" }
}

. $bridge -LibraryOnly
$failed = $false
try { Assert-Args 'set_parameter' ([pscustomobject]@{element_id='1'}) } catch { $failed = $true }
if (-not $failed) { throw 'Required-argument validation failed.' }

'PASS: Revit MCP protocol, tool discovery, and argument validation.'
