param(
    [switch]$LibraryOnly,
    [ValidatePattern('^\d{4}$')]
    [string]$RevitVersion = '2024',
    [string]$SessionDirectory = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP\runtime\revit-sessions')
)

$ErrorActionPreference = 'Stop'

function New-Tool($name, $description, $properties, $required, [bool]$readOnly) {
    @{ name=$name; description=$description; inputSchema=@{type='object';properties=$properties;required=@($required);additionalProperties=$false}; annotations=@{readOnlyHint=$readOnly;openWorldHint=$false;destructiveHint=(!$readOnly);idempotentHint=$readOnly} }
}

$str = @{type='string';minLength=1}
$plainString = @{type='string'}
$bool = @{type='boolean'}
$session = @{type='string';minLength=1;description='Revit session ID returned by list_sessions. Optional only when one Revit session is running.'}
$toolList = @(
    (New-Tool 'list_sessions' 'List running Revit sessions, their unique session IDs, active documents, and connection state. Call this first when more than one Revit window is open.' @{} @() $true),
    (New-Tool 'connection_status' 'Read Autodesk MCP Connector add-in status, session and pipe identity, active document, request count, and the last connection or error.' @{session_id=$session} @() $true),
    (New-Tool 'document_info' 'Read active Revit document identity and state. Call before writes.' @{session_id=$session} @() $true),
    (New-Tool 'list_levels' 'Read levels in the active Revit document. Elevations are returned in Revit internal units.' @{session_id=$session} @() $true),
    (New-Tool 'list_selected' 'Read the elements currently selected in Revit.' @{session_id=$session} @() $true),
    (New-Tool 'get_element' 'Read an element and up to 200 parameters by integer element id.' @{session_id=$session;element_id=$str} @('element_id') $true),
    (New-Tool 'set_parameter' 'Set one writable element parameter in a Revit transaction. Numeric values use Revit internal units. Does not save or synchronize.' @{session_id=$session;expected_document=$str;element_id=$str;parameter=$str;value=@{type='string'}} @('expected_document','element_id','parameter','value') $false),
    (New-Tool 'execute_csharp' 'Execute controlled Revit 2024 C# against the active document. Use read for inspection, transaction for writes inside one automatic transaction, and manual only for workflows that must manage their own transactions or family documents. Read document_info first. Code must return a string. Model changes require allow_model_changes=true. Does not save or synchronize unless the supplied manual code explicitly does so. RUNNER: your code is the body of Run(UIApplication application, Document document, string parametersJson); those three are the only variables (no doc, no uidoc: use application.ActiveUIDocument). Language level is C# 5: no ?. , no string interpolation, no nameof, no expression-bodied members, no out var. Namespaces already imported: System, System.Collections.Generic, System.Globalization, System.IO, System.Linq, System.Text, Autodesk.Revit.DB, Autodesk.Revit.UI; use full names for any other. ERRORS come typed as [compile_error], [runtime_error], [commit_failed], [document_changed] or [busy]: a typed error is a problem in the code or in Revit, not a lost connection. TIME: the call waits wait_seconds (default 60). If Revit is still working it returns completed=false and a job_id: do NOT run the code again, call get_job. background=true returns the job_id at once. If Revit never started the request it returns [busy] and nothing ran. dry_run=true (transaction mode only) runs the code, rolls everything back and returns change counts; in a workshared model Revit may keep elements checked out until the next synchronise. Keep writes small: about 40 creations per call, regenerate once per call, never delete and recreate everything in one transaction. A long script can report progress with McpProgress.Report(done, total, note).' @{session_id=$session;expected_document=$str;execution_mode=@{type='string';enum=@('read','transaction','manual')};allow_model_changes=$bool;code=@{type='string';minLength=1;maxLength=100000};parameters_json=$plainString;transaction_name=$str;dry_run=$bool;background=$bool;wait_seconds=@{type='integer';minimum=1;maximum=110}} @('expected_document','execution_mode','allow_model_changes','code','parameters_json','transaction_name') $false)
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
        if ($tool.inputSchema.properties[$property.Name].type -eq 'boolean' -and $property.Value -isnot [bool]) { throw "Invalid boolean: $($property.Name)" }
        if ($tool.inputSchema.properties[$property.Name].type -eq 'integer') {
            if ($property.Value -isnot [int] -and $property.Value -isnot [long] -and -not ($property.Value -is [double] -and $property.Value -eq [math]::Truncate($property.Value))) { throw "Invalid integer: $($property.Name)" }
            if ($tool.inputSchema.properties[$property.Name].minimum -and $property.Value -lt $tool.inputSchema.properties[$property.Name].minimum) { throw "Number out of range: $($property.Name)" }
            if ($tool.inputSchema.properties[$property.Name].maximum -and $property.Value -gt $tool.inputSchema.properties[$property.Name].maximum) { throw "Number out of range: $($property.Name)" }
        }
        if ($tool.inputSchema.properties[$property.Name].minLength -and [string]::IsNullOrWhiteSpace($property.Value)) { throw "Empty argument: $($property.Name)" }
        if ($tool.inputSchema.properties[$property.Name].maxLength -and ([string]$property.Value).Length -gt $tool.inputSchema.properties[$property.Name].maxLength) { throw "Argument is too long: $($property.Name)" }
        if ($tool.inputSchema.properties[$property.Name].enum -and $property.Value -notin $tool.inputSchema.properties[$property.Name].enum) { throw "Invalid value: $($property.Name)" }
    }
}

function Get-OptionalArgument($arguments, [string]$name) {
    if ($null -ne $arguments -and $null -ne $arguments.PSObject.Properties[$name]) { return [string]$arguments.$name }
    ''
}

function ConvertTo-PipeField([string]$value) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
}

function Invoke-RevitPipeName([string]$pipeName, [string]$operation, [string[]]$arguments, [int]$connectTimeout = 1500) {
    $client = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    $reader = $null
    $writer = $null
    try {
        $client.Connect($connectTimeout)
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
        # The add-in answered with an error: its own message (typed, such as "[compile_error] ...") must reach the client, not "session is not available".
        if ($parts[0] -eq 'ERR') { throw ('ADDIN_ERR::' + $payload) }
        if ($parts[0] -ne 'OK') { throw 'Revit add-in returned an unknown response.' }
        $payload | ConvertFrom-Json
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($writer) { $writer.Dispose() }
        $client.Dispose()
    }
}

function Get-RegisteredSessions {
    $sessions = @()
    if (-not (Test-Path -LiteralPath $SessionDirectory -PathType Container)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $SessionDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ([string]$record.revit_version -ne $RevitVersion) { continue }
            $processId = [int]$record.pid
            $null = Get-Process -Id $processId -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace([string]$record.session_id) -or [string]::IsNullOrWhiteSpace([string]$record.pipe_name)) { continue }
            $sessions += [pscustomobject]@{
                session_id = [string]$record.session_id
                process_id = $processId
                revit_version = [string]$record.revit_version
                pipe_name = [string]$record.pipe_name
                started_utc = [string]$record.started_utc
            }
        }
        catch { }
    }
    @($sessions | Sort-Object process_id)
}

function Get-RevitSessions {
    $sessions = @(Get-RegisteredSessions)
    $results = @()
    foreach ($sessionRecord in $sessions) {
        try {
            $status = Invoke-RevitPipeName $sessionRecord.pipe_name 'connection_status' @() 500
            $results += [pscustomobject]@{
                session_id = $sessionRecord.session_id; process_id = $sessionRecord.process_id; revit_version = $sessionRecord.revit_version
                document_id = [string]$status.document_id; online = $true; recent_client = [bool]$status.recent_client
                last_operation = [string]$status.last_operation; last_error = [string]$status.last_error
            }
        }
        catch {
            $results += [pscustomobject]@{
                session_id = $sessionRecord.session_id; process_id = $sessionRecord.process_id; revit_version = $sessionRecord.revit_version
                document_id = ''; online = $false; recent_client = $false; last_operation = ''; last_error = $_.Exception.Message
            }
        }
    }

    if ($results.Count -eq 0) {
        $legacyPipe = "BimCadMcp.Revit.$RevitVersion"
        try {
            $status = Invoke-RevitPipeName $legacyPipe 'connection_status' @() 250
            $results += [pscustomobject]@{
                session_id = "legacy-$RevitVersion"; process_id = ''; revit_version = $RevitVersion
                document_id = [string]$status.document_id; online = $true; recent_client = [bool]$status.recent_client
                last_operation = [string]$status.last_operation; last_error = [string]$status.last_error
            }
        }
        catch { }
    }
    @($results)
}

function Resolve-RevitPipe([string]$sessionId) {
    $sessions = @(Get-RegisteredSessions)
    if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        if ($sessionId -eq "legacy-$RevitVersion") { return "BimCadMcp.Revit.$RevitVersion" }
        $match = @($sessions | Where-Object session_id -eq $sessionId)
        if ($match.Count -ne 1) { throw "Revit session was not found: $sessionId. Call list_sessions again." }
        return [string]$match[0].pipe_name
    }
    if ($sessions.Count -eq 1) { return [string]$sessions[0].pipe_name }
    if ($sessions.Count -gt 1) {
        $ids = ($sessions | ForEach-Object { $_.session_id }) -join ', '
        throw "More than one Revit session is running ($ids). Call list_sessions and pass session_id."
    }
    "BimCadMcp.Revit.$RevitVersion"
}

function Invoke-RevitPipe([string]$operation, [string[]]$arguments, [string]$sessionId) {
    $pipeName = Resolve-RevitPipe $sessionId
    try { Invoke-RevitPipeName $pipeName $operation $arguments }
    catch {
        $message = $_.Exception.Message
        if ($message.StartsWith('ADDIN_ERR::')) {
            $message = $message.Substring(11)
            if ($message -notmatch '^\[[a-z_]+\] ') { $message = "[revit_error] $message" }
            throw $message
        }
        throw "Revit $RevitVersion MCP session is not available. Start Revit or call list_sessions. $message"
    }
}

# Read-only Revit part of the combined connection_status. Never throws; reports why Revit is unavailable.
function Get-RevitConnectionStatus($arguments) {
    Assert-Args 'connection_status' $arguments
    $sessionId = Get-OptionalArgument $arguments 'session_id'
    $running = @(Get-Process -Name Revit -ErrorAction SilentlyContinue).Count -gt 0
    if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        try {
            $status = Invoke-RevitPipeName (Resolve-RevitPipe $sessionId) 'connection_status' @() 1000
            $busy = [bool]$status.busy
            return @{available=$true; running=$true; revit_version=$RevitVersion; busy=$busy; status=$status; summary=$(if ($busy) { "Revit $RevitVersion session $sessionId is connected but busy: $($status.busy_reason) Wait, then call connection_status again; do not send the last request again." } else { "Revit $RevitVersion session $sessionId is connected." })}
        }
        catch { return @{available=$false; running=$running; revit_version=$RevitVersion; summary="Revit $RevitVersion session $sessionId is not available: $($_.Exception.Message)"} }
    }
    $sessions = @(Get-RevitSessions)
    $online = @($sessions | Where-Object online)
    $result = @{available=($online.Count -gt 0); running=($running -or $online.Count -gt 0); revit_version=$RevitVersion; sessions=$sessions}
    if ($online.Count -eq 1) {
        try { $result.status = Invoke-RevitPipeName (Resolve-RevitPipe $online[0].session_id) 'connection_status' @() 500 } catch { }
    }
    $onlyBusy = $online.Count -eq 1 -and $null -ne $result.status -and [bool]$result.status.busy
    $result.summary = if ($online.Count -eq 1) { if ($onlyBusy) { "Revit $RevitVersion is connected (session $($online[0].session_id)) but busy: $($result.status.busy_reason) Wait, then call connection_status again; do not send the last request again." } else { "Revit $RevitVersion is connected (session $($online[0].session_id))." } }
        elseif ($online.Count -gt 1) { "Revit $RevitVersion is connected with $($online.Count) sessions; pass session_id to choose one." }
        elseif ($sessions.Count -gt 0 -or $running) { "Revit is running, but the Revit $RevitVersion add-in is not answering; it may still be loading or busy." }
        else { 'Revit is not running.' }
    $result
}

function Invoke-RevitTool($name,$arguments) {
    Assert-Args $name $arguments
    $sessionId = Get-OptionalArgument $arguments 'session_id'
    switch ($name) {
        'list_sessions' { @{sessions=@(Get-RevitSessions)} }
        'connection_status' { Invoke-RevitPipe 'connection_status' @() $sessionId }
        'document_info' { Invoke-RevitPipe 'document_info' @() $sessionId }
        'list_levels' { Invoke-RevitPipe 'list_levels' @() $sessionId }
        'list_selected' { Invoke-RevitPipe 'list_selected' @() $sessionId }
        'get_element' { Invoke-RevitPipe 'get_element' @([string]$arguments.element_id) $sessionId }
        'set_parameter' { Invoke-RevitPipe 'set_parameter' @([string]$arguments.expected_document,[string]$arguments.element_id,[string]$arguments.parameter,[string]$arguments.value) $sessionId }
        'execute_csharp' {
            $dryRun = $null -ne $arguments.PSObject.Properties['dry_run'] -and [bool]$arguments.dry_run
            if ($dryRun -and [string]$arguments.execution_mode -ne 'transaction') { throw 'dry_run needs execution_mode transaction: only the automatic transaction can be rolled back.' }
            $fields = @([string]$arguments.expected_document,[string]$arguments.execution_mode,[string]$arguments.allow_model_changes,[string]$arguments.code,[string]$arguments.parameters_json,[string]$arguments.transaction_name)
            # The seventh field (options) only when one is set: "dry_run=true;background=true;wait_seconds=N".
            $options = @()
            if ($dryRun) { $options += 'dry_run=true' }
            if ($null -ne $arguments.PSObject.Properties['background'] -and [bool]$arguments.background) { $options += 'background=true' }
            if ($null -ne $arguments.PSObject.Properties['wait_seconds']) { $options += ('wait_seconds=' + [int]$arguments.wait_seconds) }
            if ($options.Count -gt 0) { $fields += ($options -join ';') }
            Invoke-RevitPipe 'execute_csharp' $fields $sessionId
        }
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
            $response.result=@{protocolVersion=$protocol;capabilities=@{tools=@{}};serverInfo=@{name='Smart Connector - Revit';version='1.2.0'};instructions='Call list_sessions when more than one Revit process may be open, then pass session_id to every command. If one session is running, session_id may be omitted. Read document_info before writes and use document_id as expected_document. Revit API calls run through an ExternalEvent. Prefer narrow tools. execute_csharp provides controlled full Revit API access: read has no transaction, transaction supplies one project transaction, and manual is reserved for code that must manage its own transactions or family documents. Verify every write with a separate read. The connector does not save or synchronize unless explicitly commanded.'}
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
