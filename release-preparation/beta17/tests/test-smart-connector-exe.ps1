$ErrorActionPreference = 'Stop'
# SmartConnector.exe, the compiled MCP server that replaces the PowerShell bridges: it compiles with the Windows
# .NET Framework compiler, offers exactly the tools of autodesk-bridge.ps1 with the same arguments, and answers MCP
# requests, workflow skills, argument errors and the Revit add-in pipe the same way. Windows only.
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { 'SKIP: SmartConnector.exe needs Windows'; return }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$t = Join-Path ([IO.Path]::GetTempPath()) ('connector-exe-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $t 'root'
$saved = $env:LOCALAPPDATA
$process = $null; $job = $null
try {
    # 1. Build into an install-shaped folder: <root>\bin\SmartConnector.exe beside VERSION and the skill library.
    $exe = Join-Path $root 'bin\SmartConnector.exe'
    $null = & (Join-Path $PSScriptRoot '../setup/build-connector-exe.ps1') -OutputPath $exe
    Copy-Item (Join-Path $runtime 'VERSION') $root
    New-Item -ItemType Directory -Force (Join-Path $root '.agents') | Out-Null
    Copy-Item (Join-Path $runtime '.agents\skills') (Join-Path $root '.agents') -Recurse
    $version = (Get-Content (Join-Path $runtime 'VERSION') -Raw).Trim()
    # A Windows (GUI) program: PowerShell neither waits for nor captures "& $exe", so read its output through a pipe.
    $versionInfo = New-Object Diagnostics.ProcessStartInfo($exe, '--version')
    $versionInfo.UseShellExecute = $false; $versionInfo.RedirectStandardOutput = $true
    $versionRun = [Diagnostics.Process]::Start($versionInfo)
    $printed = $versionRun.StandardOutput.ReadToEnd(); $versionRun.WaitForExit()
    Assert ($versionRun.ExitCode -eq 0 -and $printed.Trim() -eq $version) "SmartConnector.exe --version is wrong: $printed"
    'PASS: SmartConnector.exe compiles with the Windows compiler and reports its version'

    $env:LOCALAPPDATA = Join-Path $t 'local'
    New-Item -ItemType Directory -Force (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection') | Out-Null
    $info = New-Object Diagnostics.ProcessStartInfo($exe, 'mcp')
    $info.UseShellExecute = $false; $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process = [Diagnostics.Process]::Start($info)
    $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true; $writer.NewLine = "`n"
    $script:nextId = 0
    function Read-Answer([int]$Timeout = 20000) {
        $read = $process.StandardOutput.ReadLineAsync()
        if (-not $read.Wait($Timeout)) { throw 'SmartConnector.exe did not answer in time.' }
        $read.Result | ConvertFrom-Json
    }
    function Send-Raw([string]$Line) { $writer.WriteLine($Line) }
    function Invoke-Mcp([string]$Method, $Params = @{}) {
        $script:nextId++
        Send-Raw (@{ jsonrpc = '2.0'; id = $script:nextId; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress)
        $answer = Read-Answer
        Assert ($answer.id -eq $script:nextId) "Answer id $($answer.id) does not match request $($script:nextId)"
        $answer
    }
    function Invoke-Tool([string]$Name, $Arguments = @{}) { (Invoke-Mcp 'tools/call' @{ name = $Name; arguments = $Arguments }).result }

    # 2. MCP basics.
    $init = Invoke-Mcp 'initialize' @{ protocolVersion = '2025-06-18' }
    Assert ($init.result.protocolVersion -eq '2025-06-18' -and $init.result.serverInfo.name -eq 'Smart Connector' -and $init.result.serverInfo.version -eq $version) 'initialize answer is wrong'
    Assert ((Invoke-Mcp 'initialize' @{ protocolVersion = '1999-01-01' }).result.protocolVersion -eq '2024-11-05') 'Unknown protocol versions must fall back to 2024-11-05'
    Send-Raw '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    Assert ((Invoke-Mcp 'ping').result -ne $null) 'ping failed, or a notification was answered'
    Assert ((Invoke-Mcp 'no/such/method').error.code -eq -32601) 'Unknown methods must return -32601'
    Send-Raw 'this is not json'
    Assert ((Read-Answer).error.code -eq -32700) 'A parse error must return -32700'
    'PASS: initialize, ping, notifications, unknown methods and parse errors'

    # 3. The same tools as the PowerShell bridge, in the same order, with the same arguments.
    . (Join-Path $runtime 'src\autodesk\autodesk-bridge.ps1') -LibraryOnly
    $expected = @(Get-AutodeskMcpTools)
    $actual = @((Invoke-Mcp 'tools/list').result.tools)
    Assert ((($actual | ForEach-Object name) -join ',') -eq (($expected | ForEach-Object { $_['name'] }) -join ',')) ('Tool list differs: ' + (($actual | ForEach-Object name) -join ','))
    for ($i = 0; $i -lt $expected.Count; $i++) {
        $e = $expected[$i]; $a = $actual[$i]; $n = $e['name']
        Assert ($a.description -eq $e['description']) "Description of $n differs"
        Assert ((@($a.inputSchema.required) -join ',') -eq (@($e['inputSchema']['required']) -join ',')) "Required arguments of $n differ"
        Assert ((@($a.inputSchema.properties.PSObject.Properties.Name | Sort-Object) -join ',') -eq (@($e['inputSchema']['properties'].Keys | Sort-Object) -join ',')) "Arguments of $n differ"
        Assert ([bool]$a.annotations.readOnlyHint -eq [bool]$e['annotations']['readOnlyHint']) "Read-only flag of $n differs"
        foreach ($key in $e['inputSchema']['properties'].Keys) {
            $rule = $e['inputSchema']['properties'][$key]
            $mine = $a.inputSchema.properties.$key
            Assert ([string]$mine.type -eq [string]$rule['type']) "Type of $n.$key differs"
            if ($rule['enum']) { Assert ((@($mine.enum) -join ',') -eq (@($rule['enum']) -join ',')) "Choices of $n.$key differ" }
            foreach ($limit in 'minLength', 'maxLength', 'minimum', 'maximum', 'exclusiveMinimum') { if ($rule.ContainsKey($limit)) { Assert ([double]$mine.$limit -eq [double]$rule[$limit]) "$limit of $n.$key differs" } }
        }
    }
    "PASS: the same $($expected.Count) tools, arguments and limits as the PowerShell bridge"

    # 4. Workflow skills: same list as the bridge, files readable, paths refused.
    $skills = @(($(Invoke-Tool 'list_skill_workflows').content[0].text | ConvertFrom-Json).skills)
    $bridgeSkills = @(Get-SharedWorkflows)
    Assert ($skills.Count -ge 30 -and $skills.Count -eq $bridgeSkills.Count) "Skill count $($skills.Count) differs from the bridge ($($bridgeSkills.Count))"
    foreach ($skill in $bridgeSkills) { Assert (@($skills | Where-Object { $_.name -eq $skill['name'] -and $_.category -eq $skill['category'] }).Count -eq 1) "Skill $($skill['name']) missing or in another category" }
    $first = $skills[0]
    $read = Invoke-Tool 'read_skill_workflow' @{ name = $first.name }
    $content = ($read.content[0].text | ConvertFrom-Json).content
    Assert (-not $read.isError -and $content -eq (Read-SharedWorkflow -Name $first.name).content) 'SKILL.md content differs from the bridge'
    Assert ((Invoke-Tool 'read_skill_workflow' @{ name = 'Bad Name' }).content[0].text -eq 'Invalid skill name.') 'Invalid skill names must be refused'
    Assert ((Invoke-Tool 'read_skill_workflow' @{ name = $first.name; file = '../x.md' }).content[0].text -eq 'Use a relative file path within the selected skill.') 'Path traversal must be refused'
    '{}' | Set-Content (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\service.json')
    $null = Invoke-Tool 'read_skill_workflow' @{ name = $first.name }
    $usage = Get-Content (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection\usage.jsonl') -Raw
    Assert ($usage -match ('"kind":"skill","name":"' + [regex]::Escape($first.name) + '"') -or $usage -match ('"name":"' + [regex]::Escape($first.name) + '"')) "Skill use was not recorded: $usage"
    'PASS: workflow skills match the bridge, invalid names and paths are refused, use is recorded on team PCs'

    # 5. Argument checks and messages, before AutoCAD or Revit is contacted.
    $checks = @(
        @('create_entity', @{}, 'Missing argument: expected_drawing'),
        @('drawing_info', @{ x = 1 }, 'Unknown argument: x'),
        @('create_entity', @{ expected_drawing = 'a.dwg'; kind = 'Line'; layer = '0'; point = @(0, 0, 0) }, 'Invalid choice: kind'),
        @('create_entity', @{ expected_drawing = 'a.dwg'; kind = 'line'; layer = '0'; point = @(0, 0) }, 'A point must have three coordinates.'),
        @('list_entities', @{ limit = 500 }, 'Number out of range: limit'),
        @('get_element', @{ element_id = ' ' }, 'Empty argument: element_id'),
        @('drawing_info', @{}, 'No running full AutoCAD instance was found*'),
        @('connection_status', @{}, 'Smart Connector is running, but neither AutoCAD nor Revit is reachable.*'),
        @('document_info', @{}, 'Revit 2024 MCP session is not available.*'),
        @('no_such_tool', @{}, 'Unknown Autodesk MCP tool: no_such_tool')
    )
    foreach ($check in $checks) {
        $result = Invoke-Tool $check[0] $check[1]
        Assert ($result.isError -and $result.content[0].text -like $check[2]) ("{0}: expected '{1}', got '{2}'" -f $check[0], $check[2], $result.content[0].text)
    }
    'PASS: argument errors, AutoCAD and Revit not running, unknown tools'

    # 6. Revit add-in pipe: a stand-in add-in answers on the pipe name a single Revit 2024 session uses.
    $job = Start-Job -ScriptBlock {
        $server = New-Object IO.Pipes.NamedPipeServerStream('BimCadMcp.Revit.2024', [IO.Pipes.PipeDirection]::InOut, 1)
        for ($n = 0; $n -lt 3; $n++) {
            $server.WaitForConnection()
            $reader = New-Object IO.StreamReader($server, [Text.Encoding]::UTF8, $false, 4096, $true)
            $writer = New-Object IO.StreamWriter($server, (New-Object Text.UTF8Encoding($false)), 4096, $true); $writer.AutoFlush = $true
            $fields = $reader.ReadLine() -split "`t"
            $decoded = @($fields | Select-Object -Skip 1 | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
            $encode = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
            switch ($fields[0]) {
                'document_info' { $writer.WriteLine('OK' + "`t" + (& $encode '{"document_id":"doc-1","title":"Test \u00e9.rvt"}')) }
                'get_element' { $writer.WriteLine('ERR' + "`t" + (& $encode ('Element ' + $decoded[0] + ' was not found.'))) }
                'execute_csharp' { $writer.WriteLine('OK' + "`t" + (& $encode ((@{ fields = $decoded } | ConvertTo-Json -Compress)))) }
            }
            $reader.Dispose(); $writer.Dispose(); $server.Disconnect()
        }
        $server.Dispose()
    }
    $ready = $false
    for ($wait = 0; $wait -lt 100 -and -not $ready; $wait++) { Start-Sleep -Milliseconds 100; $ready = [IO.Directory]::GetFiles('\\.\pipe\') -contains '\\.\pipe\BimCadMcp.Revit.2024' }
    Assert $ready 'The stand-in Revit add-in did not start'
    $doc = Invoke-Tool 'document_info'
    Assert (-not $doc.isError -and ($doc.content[0].text | ConvertFrom-Json).title -eq ('Test ' + [char]0xE9 + '.rvt')) ("document_info over the pipe failed: " + $doc.content[0].text)
    $missing = Invoke-Tool 'get_element' @{ element_id = '42' }
    Assert ($missing.isError -and $missing.content[0].text -like '*Element 42 was not found.') ("Add-in errors are not passed on: " + $missing.content[0].text)
    $run = Invoke-Tool 'execute_csharp' @{ expected_document = 'doc-1'; execution_mode = 'READ'; allow_model_changes = $false; code = 'return "x";'; parameters_json = '{}'; transaction_name = 'T' }
    $sent = @(($run.content[0].text | ConvertFrom-Json).fields)
    Assert (-not $run.isError -and ($sent -join '|') -eq 'doc-1|READ|False|return "x";|{}|T') ("execute_csharp sent the wrong fields: " + ($sent -join '|'))
    'PASS: Revit add-in pipe: answers, add-in errors and execute_csharp fields as the bridge sends them'
}
finally {
    $env:LOCALAPPDATA = $saved
    if ($process -and -not $process.HasExited) { try { $process.StandardInput.Close() } catch { }; if (-not $process.WaitForExit(5000)) { $process.Kill() } }
    if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
