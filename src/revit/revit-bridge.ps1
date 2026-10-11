param(
    [switch]$LibraryOnly,
    [ValidatePattern('^\d{4}$')]
    [string]$RevitVersion = '2024'
)

$ErrorActionPreference = 'Stop'

function New-Tool($name, $description, $properties, $required, [bool]$readOnly) {
    @{ name=$name; description=$description; inputSchema=@{type='object';properties=$properties;required=@($required);additionalProperties=$false}; annotations=@{readOnlyHint=$readOnly;openWorldHint=$false;destructiveHint=(!$readOnly);idempotentHint=$readOnly} }
}
$str = @{type='string';minLength=1}
$toolList = @(
    (New-Tool 'document_info' 'Read active Revit document identity and state. Call before writes.' @{} @() $true),
    (New-Tool 'list_levels' 'Read levels in the active Revit document. Elevations are returned in Revit internal units.' @{} @() $true),
    (New-Tool 'list_selected' 'Read the elements currently selected in Revit.' @{} @() $true),
    (New-Tool 'get_element' 'Read an element and up to 200 parameters by integer element id.' @{element_id=$str} @('element_id') $true),
    (New-Tool 'set_parameter' 'Set one writable element parameter in a Revit transaction. Numeric values use Revit internal units. Does not save or synchronize.' @{expected_document=$str;element_id=$str;parameter=$str;value=@{type='string'}} @('expected_document','element_id','parameter','value') $false)
)

function Assert-Args($name,$arguments) {
    $tool = $toolList | Where-Object name -eq $name
    if (!$tool) { throw "Unknown tool: $name" }
    if ($null -eq $arguments) { $arguments = [pscustomobject]@{} }
    foreach ($key in $tool.inputSchema.required) {
        if ($null -eq $arguments.PSObject.Properties[$key]) { throw "Missing argument: $key" }
    }
    foreach ($property in $arguments.PSObject.Properties) {
        if (!$tool.inputSchema.properties[$property.Name]) { throw "Unknown argument: $($property.Name)" }
        if ($null -eq $property.Value) { throw "Null argument: $($property.Name)" }
        if ($tool.inputSchema.properties[$property.Name].type -eq 'string' -and $property.Value -isnot [string]) { throw "Invalid string: $($property.Name)" }
        if ($tool.inputSchema.properties[$property.Name].minLength -and [string]::IsNullOrWhiteSpace($property.Value)) { throw "Empty argument: $($property.Name)" }
    }
}

function ConvertTo-PipeField([string]$value) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
}

function Invoke-RevitPipe($operation, [string[]]$arguments) {
    $pipeName = "BimCadMcp.Revit.$RevitVersion"
    $client = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        try { $client.Connect(1500) } catch { throw "Revit $RevitVersion MCP add-in is not available. Start Revit, then restart Revit after installing the add-in." }
        $writer = New-Object IO.StreamWriter($client, (New-Object Text.UTF8Encoding($false)), 4096, $true)
        $reader = New-Object IO.StreamReader($client, [Text.Encoding]::UTF8, $false, 4096, $true)
        $writer.AutoFlush = $true
        $fields = @($operation) + @($arguments | ForEach-Object { ConvertTo-PipeField $_ })
        $writer.WriteLine(($fields -join "`t"))
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { throw 'Revit add-in returned an empty response.' }
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2) { throw 'Revit add-in returned an invalid response.' }
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
        if ($parts[0] -eq 'ERR') { throw $payload }
        if ($parts[0] -ne 'OK') { throw 'Revit add-in returned an unknown response.' }
        $payload | ConvertFrom-Json
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($writer) { $writer.Dispose() }
        $client.Dispose()
    }
}

function Invoke-RevitTool($name,$arguments) {
    Assert-Args $name $arguments
    switch ($name) {
        'document_info' { Invoke-RevitPipe 'document_info' @() }
        'list_levels' { Invoke-RevitPipe 'list_levels' @() }
        'list_selected' { Invoke-RevitPipe 'list_selected' @() }
        'get_element' { Invoke-RevitPipe 'get_element' @([string]$arguments.element_id) }
        'set_parameter' { Invoke-RevitPipe 'set_parameter' @([string]$arguments.expected_document,[string]$arguments.element_id,[string]$arguments.parameter,[string]$arguments.value) }
    }
}

if ($LibraryOnly) { return }
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
while ($null -ne ($line=[Console]::ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) {continue}
    try {$request=$line | ConvertFrom-Json} catch {
        [Console]::WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}'); continue
    }
    if ($null -eq $request.id) {continue}
    $response=@{jsonrpc='2.0';id=$request.id}
    switch ($request.method) {
        'initialize' {
            $protocol='2024-11-05'; if ($request.params.protocolVersion -in @('2024-11-05','2025-03-26','2025-06-18','2025-11-25')) {$protocol=$request.params.protocolVersion}
            $response.result=@{protocolVersion=$protocol;capabilities=@{tools=@{}};serverInfo=@{name='revit-2024-local';version='0.1.0'};instructions='Read document_info before writes and use document_id as expected_document. Revit API calls run through an ExternalEvent in Revit. Inspect an element before setting a parameter. Each parameter write uses a Revit transaction and does not save or synchronize the document.'}
        }
        'ping' {$response.result=@{}}
        'tools/list' {$response.result=@{tools=$toolList}}
        'tools/call' {
            try {$data=Invoke-RevitTool $request.params.name $request.params.arguments; $response.result=@{content=@(@{type='text';text=($data | ConvertTo-Json -Depth 20 -Compress)});isError=$false}}
            catch {$response.result=@{content=@(@{type='text';text=$_.Exception.Message});isError=$true}}
        }
        default {$response.error=@{code=-32601;message='Method not found'}}
    }
    [Console]::WriteLine(($response | ConvertTo-Json -Depth 30 -Compress))
}
