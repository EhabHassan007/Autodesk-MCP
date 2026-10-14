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
foreach ($required in @('list_sessions','connection_status','document_info','list_levels','list_selected','get_element','set_parameter','execute_csharp')) {
    if ($required -notin $names) { throw "Missing tool: $required" }
}

$sessionTestDirectory = Join-Path ([IO.Path]::GetTempPath()) ('BimCadMcp-session-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionTestDirectory -Force | Out-Null
. $bridge -LibraryOnly -SessionDirectory $sessionTestDirectory
$failed = $false
try { Assert-Args 'set_parameter' ([pscustomobject]@{element_id='1'}) } catch { $failed = $true }
if (-not $failed) { throw 'Required-argument validation failed.' }

$failed = $false
try {
    Assert-Args 'execute_csharp' ([pscustomobject]@{
        expected_document='test.rvt'
        execution_mode='transaction'
        allow_model_changes='yes'
        code='return "ok";'
        parameters_json='{}'
        transaction_name='Test'
    })
} catch { $failed = $true }
if (-not $failed) { throw 'Boolean validation failed.' }

Assert-Args 'execute_csharp' ([pscustomobject]@{
    session_id='2024-1234'
    expected_document='test.rvt'
    execution_mode='read'
    allow_model_changes=$false
    code='return "ok";'
    parameters_json='{}'
    transaction_name='Read test'
})

try {
    @{
        session_id='2024-1001'; pid=[string]$PID; revit_version='2024'; pipe_name='BimCadMcp.Revit.2024.1001'; started_utc=[DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sessionTestDirectory '2024-1001.json') -Encoding UTF8
    @{
        session_id='2024-1002'; pid=[string]$PID; revit_version='2024'; pipe_name='BimCadMcp.Revit.2024.1002'; started_utc=[DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sessionTestDirectory '2024-1002.json') -Encoding UTF8

    $registered = @(Get-RegisteredSessions)
    if ($registered.Count -ne 2) { throw 'Session discovery did not return both registered sessions.' }
    if ((Resolve-RevitPipe '2024-1002') -ne 'BimCadMcp.Revit.2024.1002') { throw 'Explicit session routing failed.' }
    $failed = $false
    try { $null = Resolve-RevitPipe '' } catch { $failed = $_.Exception.Message -like '*More than one Revit session*' }
    if (-not $failed) { throw 'Ambiguous sessions were not rejected.' }
}
finally {
    Remove-Item -LiteralPath $sessionTestDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

'PASS: Revit MCP protocol, tool discovery, argument validation, and multi-session routing.'
