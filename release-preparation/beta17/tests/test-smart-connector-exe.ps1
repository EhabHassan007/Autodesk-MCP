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
    $allTools = @((Invoke-Mcp 'tools/list').result.tools)
    # Tools that only SmartConnector.exe has; the PowerShell fallback bridge does not. Every other tool must match exactly.
    $exeOnlyTools = @('apply_plan', 'execute_autocad', 'generate_detail', 'verify_standards', 'get_job', 'revision_cloud_info', 'create_revision_clouds')
    # Tools the exe has improved on purpose (summary and fields for the readers, a product filter for the workflow list); the fallback bridge keeps the old form. Only their names and order must match.
    $exeChangedTools = @('list_entities', 'get_entity', 'list_skill_workflows')
    Assert (@($allTools | Where-Object { $exeOnlyTools -contains $_.name }).Count -eq $exeOnlyTools.Count) ('An exe-only tool is missing from the tool list: ' + (($allTools | ForEach-Object name) -join ','))
    $actual = @($allTools | Where-Object { $exeOnlyTools -notcontains $_.name })
    Assert ((($actual | ForEach-Object name) -join ',') -eq (($expected | ForEach-Object { $_['name'] }) -join ',')) ('Tool list differs: ' + (($actual | ForEach-Object name) -join ','))
    for ($i = 0; $i -lt $expected.Count; $i++) {
        $e = $expected[$i]; $a = $actual[$i]; $n = $e['name']
        if ($exeChangedTools -contains $n) { continue }
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
    $cadSkills = @(($(Invoke-Tool 'list_skill_workflows' @{ product = 'autocad' }).content[0].text | ConvertFrom-Json).skills)
    Assert ($cadSkills.Count -ge 5 -and @($cadSkills | Where-Object { $_.category -ne 'autocad' }).Count -eq 0 -and @($cadSkills | Where-Object { -not $_.description }).Count -eq 0) 'list_skill_workflows with product autocad must list only AutoCAD workflows, each with a description'
    Assert (@(($(Invoke-Tool 'list_skill_workflows' @{ product = 'revit' }).content[0].text | ConvertFrom-Json).skills | Where-Object { $_.name -eq 'find-skills' }).Count -eq 0) 'The generic skill-finder is not a Revit workflow'
    Assert ((Invoke-Tool 'list_skill_workflows' @{ product = 'catia' }).content[0].text -like 'product must be*') 'An unknown product must be refused'
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

    # 4b. `mcp --product autocad` offers only the AutoCAD tools (plus connection_status and the skill tools).
    foreach ($scope in @(@('autocad', 'list_sessions', 'apply_plan'), @('revit', 'apply_plan', 'list_sessions'))) {
        $scoped = New-Object Diagnostics.ProcessStartInfo($exe, ('mcp --product ' + $scope[0]))
        $scoped.UseShellExecute = $false; $scoped.RedirectStandardInput = $true; $scoped.RedirectStandardOutput = $true
        $scoped.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $scopedProcess = [Diagnostics.Process]::Start($scoped)
        $scopedProcess.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
        $scopedRead = $scopedProcess.StandardOutput.ReadLineAsync()
        Assert ($scopedRead.Wait(20000)) "mcp --product $($scope[0]) did not answer"
        $scopedNames = @(($scopedRead.Result | ConvertFrom-Json).result.tools | ForEach-Object name)
        $scopedProcess.StandardInput.Close(); if (-not $scopedProcess.WaitForExit(5000)) { $scopedProcess.Kill() }
        Assert (($scopedNames -notcontains $scope[1]) -and ($scopedNames -contains $scope[2]) -and ($scopedNames -contains 'connection_status') -and ($scopedNames -contains 'list_skill_workflows')) "mcp --product $($scope[0]) offers the wrong tools: $($scopedNames -join ',')"
    }
    'PASS: mcp --product autocad and --product revit offer only that product''s tools'

    # 5. Argument checks and messages, before AutoCAD or Revit is contacted.
    $checks = @(
        @('create_entity', @{}, 'Missing argument: expected_drawing'),
        @('drawing_info', @{ x = 1 }, 'Unknown argument: x'),
        @('create_entity', @{ expected_drawing = 'a.dwg'; kind = 'Line'; layer = '0'; point = @(0, 0, 0) }, 'Invalid choice: kind'),
        @('create_entity', @{ expected_drawing = 'a.dwg'; kind = 'line'; layer = '0'; point = @(0, 0) }, 'A point must have three coordinates.'),
        @('list_entities', @{ limit = 500 }, 'Number out of range: limit'),
        @('apply_plan', @{ expected_drawing = 'a.dwg' }, 'Missing argument: items'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @() }, 'Too few entries: items'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @(@{ op = 'spline' }) }, 'items`[0`]: op must be one of*'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @(@{ op = 'circle'; layer = 'A'; center = @(0, 0); radius = 0 }) }, 'items`[0`]: ''radius'' must be greater than 0.'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @(@{ op = 'hatch'; layer = 'A'; pattern = 'SOLID'; boundary = 'x' }) }, 'items`[0`]: ''boundary'' must be the id of an earlier closed polyline or circle step*'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @(@{ op = 'dim_rotated'; layer = 'A'; from = @(0, 0); to = @(1, 0); location = @(0, 1) }) }, 'items`[0`]: missing ''angle''.'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @(@{ op = 'insert'; layer = 'A'; name = 'LVL'; point = @(0, 0); attributes = @{ LEVEL = 5 } }) }, 'items`[0`]: attribute ''LEVEL'' must be a tag*'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @(@{ op = 'dim_rotated'; layer = 'A'; from = @(0, 0); to = @(1, 0); location = @(0, 1); angle = 0; linear_factor = 0 }) }, 'items`[0`]: ''linear_factor'' must be greater than 0.'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @(@{ op = 'layer'; name = 'A-DETL' }) }, 'No running full AutoCAD instance was found*'),
        @('execute_autocad', @{ expected_drawing = 'a.dwg'; execution_mode = 'read'; allow_model_changes = $false }, 'Missing argument: code'),
        @('execute_autocad', @{ expected_drawing = 'a.dwg'; execution_mode = 'edit'; allow_model_changes = $false; code = 'return "x";' }, 'Invalid choice: execution_mode'),
        @('execute_autocad', @{ expected_drawing = 'a.dwg'; execution_mode = 'write'; allow_model_changes = $false; code = 'return "x";' }, 'Model-changing execution requires allow_model_changes=true.'),
        @('execute_autocad', @{ expected_drawing = 'a.dwg'; execution_mode = 'read'; allow_model_changes = $true; code = 'return "x";' }, 'Read execution requires allow_model_changes=false.'),
        @('execute_autocad', @{ expected_drawing = 'a.dwg'; execution_mode = 'read'; allow_model_changes = $false; code = 'return 1 +;' }, 'C# compilation failed:*Line 1:*'),
        @('execute_autocad', @{ expected_drawing = 'a.dwg'; execution_mode = 'read'; allow_model_changes = $false; code = 'return doc.Name;' }, 'No running full AutoCAD instance was found*'),
        @('list_entities', @{ fields = 'TextString' }, 'Invalid array: fields'),
        @('list_entities', @{ summary = 'yes' }, 'Invalid boolean: summary'),
        @('verify_standards', @{}, 'Missing argument: expected_drawing'),
        @('generate_detail', @{}, 'Missing argument: template'),
        @('generate_detail', @{ template = 'kitchen' }, 'Invalid choice: template'),
        @('generate_detail', @{ template = 'reception_counter_section'; params = @{ height = 100 } }, 'params.height must be between 300 and 1500 mm.'),
        @('generate_detail', @{ template = 'reception_counter_section'; params = @{ section = 'accessible' } }, 'The accessible section needs*'),
        @('generate_detail', @{ template = 'reception_counter_section'; apply = $true }, 'expected_drawing is required when apply is true.'),
        @('generate_detail', @{ template = 'reception_counter_section'; apply = $true; expected_drawing = 'a.dwg' }, 'No running full AutoCAD instance was found*'),
        @('generate_detail', @{ template = 'custom_section' }, 'params.parts is required.'),
        @('generate_detail', @{ template = 'custom_section'; params = @{ parts = @(@{ id = 'a'; material = 'mdf'; points = @(@{ x = 0; y = 0; radius = 40 }, @(100, 0), @(0, 100)) }) } }, 'params.parts`[0`] (''a'') point 0: radius 40 is smaller than half the chord*'),
        @('apply_plan', @{ expected_drawing = 'a.dwg'; items = @(@{ op = 'polyline'; layer = 'A'; points = @(@(0, 0), @(100, 0)); bulges = @(11, 0) }) }, 'items`[0`]: each bulge must be a number from -10 to 10*'),
        @('generate_detail', @{ template = 'custom_section'; params = @{ view = 'side'; parts = @(@{ id = 'a'; material = 'mdf'; x0 = 0; y0 = 0; x1 = 10; y1 = 10 }) } }, 'params.view must be section, elevation or plan.'),
        @('generate_detail', @{ template = 'custom_section'; params = @{ parts = @(@{ id = 'a'; material = 'mdf'; points = @(@(0, 0), @(100, 100), @(100, 0), @(0, 100)) }) } }, 'params.parts`[0`] (''a''): the outline crosses itself*'),
        @('generate_detail', @{ template = 'custom_section'; params = @{ parts = @(@{ id = 'a'; material = 'oak'; x0 = 0; y0 = 0; x1 = 10; y1 = 10 }) } }, 'params.parts`[0`]: material must be one of*'),
        @('generate_detail', @{ template = 'custom_section'; params = @{ parts = @(@{ id = 'a'; material = 'mdf'; x0 = 0; y0 = 0; x1 = 100; y1 = 100 }, @{ id = 'b'; material = 'mdf'; x0 = 50; y0 = 50; x1 = 150; y1 = 150 }) } }, 'The parts ''a'' and ''b'' overlap by 50 x 50 mm*'),
        @('generate_detail', @{ template = 'reception_counter_section'; annotation = 'sheet' }, 'Invalid choice: annotation'),
        @('generate_detail', @{ template = 'reception_counter_section'; annotation = 'paper' }, 'annotation paper needs view.paper_centre*'),
        @('generate_detail', @{ template = 'reception_counter_section'; annotation = 'paper'; view = @{ zoom = 2 } }, 'Unknown view field: zoom*'),
        @('generate_detail', @{ template = 'reception_counter_section'; annotation = 'paper'; view = @{ paper_centre = @(200, 150) }; apply = $true; expected_drawing = 'a.dwg' }, 'annotation paper needs layout*'),
        @('generate_detail', @{ template = 'reception_counter_section'; layout = 'Layout1' }, 'layout is used with annotation paper only.'),
        @('generate_detail', @{ template = 'reception_counter_section'; level_block = 'LVL' }, 'level_block, leader_block, title_block, note_width and sheet are used with annotation paper only.'),
        @('generate_detail', @{ template = 'reception_counter_section'; create_viewport = $true }, 'create_viewport is used with annotation paper only.'),
        @('generate_detail', @{ template = 'reception_counter_section'; leader_block = 'MLL' }, 'level_block, leader_block, title_block, note_width and sheet are used with annotation paper only.'),
        @('generate_detail', @{ template = 'reception_counter_section'; layer_scheme = 'office' }, 'Invalid choice: layer_scheme'),
        @('generate_detail', @{ template = 'reception_counter_section'; annotation = 'paper'; view = @{ paper_centre = @(200, 150) }; sheet = @{ number = 'A1' } }, 'Unknown sheet field: number*'),
        @('generate_detail', @{ template = 'reception_counter_section'; annotation = 'paper'; create_viewport = $true }, 'view.paper_centre is needed to preview without AutoCAD*'),
        @('generate_detail', @{ template = 'reception_counter_section'; annotation = 'paper'; view = @{ paper_centre = @(200, 150); viewport_size = @(100, 100) } }, 'view.viewport_size is used with create_viewport only.'),
        @('get_element', @{ element_id = ' ' }, 'Empty argument: element_id'),
        @('drawing_info', @{}, 'No running full AutoCAD instance was found*'),
        @('connection_status', @{}, 'Smart Connector is running, but neither AutoCAD nor Revit is reachable.*'),
        @('document_info', @{}, 'Revit 2024 MCP session is not available.*'),
        @('no_such_tool', @{}, 'Unknown Autodesk MCP tool: no_such_tool')
    )
    # The Revit model tools refuse to run until get_revit_rules has been called; list_sessions and connection_status do not need it.
    foreach ($gated in 'document_info', 'list_levels', 'list_selected', 'get_element', 'set_parameter', 'execute_csharp') {
        $blocked = Invoke-Tool $gated @{}
        Assert ($blocked.isError -and $blocked.content[0].text -like 'Call get_revit_rules first*') "$gated must be refused until get_revit_rules has been called: $($blocked.content[0].text)"
    }
    Assert (-not (Invoke-Tool 'list_sessions').isError -or (Invoke-Tool 'list_sessions').content[0].text -notlike 'Call get_revit_rules first*') 'list_sessions must not need the Revit rules'
    $rules = Invoke-Tool 'get_revit_rules'
    $rulesData = $rules.content[0].text | ConvertFrom-Json
    Assert (-not $rules.isError -and $rulesData.must_follow -and $null -ne $rulesData.count -and $null -ne $rulesData.rules) "get_revit_rules failed: $($rules.content[0].text)"
    Assert ((Invoke-Tool 'document_info').content[0].text -notlike 'Call get_revit_rules first*') 'The Revit tools must run once the rules have been read'
    'PASS: Revit model tools are refused until get_revit_rules is called, then run'
    foreach ($check in $checks) {
        $result = Invoke-Tool $check[0] $check[1]
        Assert ($result.isError -and $result.content[0].text -like $check[2]) ("{0}: expected '{1}', got '{2}'" -f $check[0], $check[2], $result.content[0].text)
    }
    $paper = Invoke-Tool 'generate_detail' @{ template = 'reception_counter_section'; annotation = 'paper'; view = @{ paper_centre = @(200, 150) }; return_plan = $true }
    Assert (-not $paper.isError -and $paper.content[0].text -like '*"paper_items"*' -and $paper.content[0].text -like '*linear_factor*' -and $paper.content[0].text -like '*viewport_setup*') 'generate_detail paper mode must return the geometry plan, the layout plan and the viewport set-up without AutoCAD'
    $ao = Invoke-Tool 'generate_detail' @{ template = 'reception_counter_section'; annotation = 'paper'; layer_scheme = 'ao'; leader_block = 'Multiple Leader Lab'; view = @{ paper_centre = @(200, 150) }; return_plan = $true }
    Assert (-not $ao.isError -and $ao.content[0].text -like '*"op":"leader"*' -and $ao.content[0].text -like '*AO-MDF_SECTION_PLAN*' -and $ao.content[0].text -like '*mm THK MDF CARCASS W/ MELAMINE FINISH*') 'generate_detail paper mode with the office scheme must return leaders on the office layers without AutoCAD'
    $custom = Invoke-Tool 'generate_detail' @{ template = 'custom_section'; params = @{ parts = @(@{ id = 'top'; material = 'corian'; x0 = 0; y0 = 870; x1 = 600; y1 = 882 }); notes = @(@{ part = 'top'; text = '12MM THK. SOLID SURFACE TOP' }) }; return_plan = $true }
    Assert (-not $custom.isError -and $custom.content[0].text -like '*12MM THK. SOLID SURFACE TOP*' -and $custom.content[0].text -like '*custom_section*') 'generate_detail custom_section must return a plan without AutoCAD'
    $curve = Invoke-Tool 'generate_detail' @{ template = 'custom_section'; scale = 20; params = @{ view = 'plan'; parts = @(@{ id = 'c'; material = 'corian'; points = @(@{ x = 1200; y = 0; radius = 800 }, @(2000, 800), @{ x = 1400; y = 800; radius = -200 }, @(1200, 600)) }) }; return_plan = $true }
    Assert (-not $curve.isError -and $curve.content[0].text -like '*"bulges"*') 'generate_detail must return a curved part with bulges without AutoCAD'
    $none = Invoke-Tool 'generate_detail' @{ template = 'reception_counter_section'; annotation = 'none'; return_plan = $true }
    Assert (-not $none.isError -and $none.content[0].text -notlike '*dim_rotated*') 'generate_detail geometry-only mode must draw no dimensions'
    $gen = Invoke-Tool 'generate_detail' @{ template = 'reception_counter_section'; return_plan = $true }
    Assert (-not $gen.isError -and $gen.content[0].text -like '*"applied":false*' -and $gen.content[0].text -like '*SECTION X2 - RECEPTION COUNTER*') 'generate_detail must return a plan without contacting AutoCAD'
    'PASS: argument errors, AutoCAD and Revit not running, unknown tools, a generated plan without AutoCAD'

    # 6. Revit add-in pipe: a stand-in add-in answers on the pipe name a single Revit 2024 session uses.
    $job = Start-Job -ScriptBlock {
        $server = New-Object IO.Pipes.NamedPipeServerStream('BimCadMcp.Revit.2024', [IO.Pipes.PipeDirection]::InOut, 1)
        for ($n = 0; $n -lt 8; $n++) {
            $server.WaitForConnection()
            $reader = New-Object IO.StreamReader($server, [Text.Encoding]::UTF8, $false, 4096, $true)
            $writer = New-Object IO.StreamWriter($server, (New-Object Text.UTF8Encoding($false)), 4096, $true); $writer.AutoFlush = $true
            $fields = $reader.ReadLine() -split "`t"
            $decoded = @($fields | Select-Object -Skip 1 | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
            $encode = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
            switch ($fields[0]) {
                'document_info' { $writer.WriteLine('OK' + "`t" + (& $encode '{"document_id":"doc-1","title":"Test \u00e9.rvt"}')) }
                'get_element' { $writer.WriteLine('ERR' + "`t" + (& $encode ('Element ' + $decoded[0] + ' was not found.'))) }
                'execute_csharp' {
                    if ($decoded[3] -like '*doc.Title*') { $writer.WriteLine('ERR' + "`t" + (& $encode "[compile_error] C# compilation failed:`nLine 1: The name 'doc' does not exist")) }
                    else { $writer.WriteLine('OK' + "`t" + (& $encode ((@{ fields = $decoded } | ConvertTo-Json -Compress)))) }
                }
                'get_job' { $writer.WriteLine('OK' + "`t" + (& $encode ((@{ fields = $decoded; completed = $false; state = 'running' } | ConvertTo-Json -Compress)))) }
                'create_revision_clouds' { $writer.WriteLine('OK' + "`t" + (& $encode ((@{ fields = $decoded } | ConvertTo-Json -Compress)))) }
                'revision_cloud_info' { $writer.WriteLine('OK' + "`t" + (& $encode ((@{ fields = $decoded } | ConvertTo-Json -Compress)))) }
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
    Assert ($missing.isError -and $missing.content[0].text.StartsWith('[revit_error] Element 42 was not found.')) ("An untyped add-in error must reach the client as [revit_error], not as a lost connection: " + $missing.content[0].text)
    $run = Invoke-Tool 'execute_csharp' @{ expected_document = 'doc-1'; execution_mode = 'READ'; allow_model_changes = $false; code = 'return "x";'; parameters_json = '{}'; transaction_name = 'T' }
    $sent = @(($run.content[0].text | ConvertFrom-Json).fields)
    Assert (-not $run.isError -and ($sent -join '|') -eq 'doc-1|READ|False|return "x";|{}|T') ("execute_csharp sent the wrong fields: " + ($sent -join '|'))
    # A mistake in the submitted code is a typed error of its own, never "session is not available".
    $bad = Invoke-Tool 'execute_csharp' @{ expected_document = 'doc-1'; execution_mode = 'read'; allow_model_changes = $false; code = 'return doc.Title;'; parameters_json = '{}'; transaction_name = 'T' }
    Assert ($bad.isError -and $bad.content[0].text.StartsWith('[compile_error] ') -and $bad.content[0].text -notlike '*session is not available*') ("A compile error was not reported as itself: " + $bad.content[0].text)
    # Options travel as a seventh field, only when one is set.
    $dry = Invoke-Tool 'execute_csharp' @{ expected_document = 'doc-1'; execution_mode = 'transaction'; allow_model_changes = $true; code = 'return "x";'; parameters_json = '{}'; transaction_name = 'T'; dry_run = $true; wait_seconds = 30 }
    $dryFields = @(($dry.content[0].text | ConvertFrom-Json).fields)
    Assert (-not $dry.isError -and $dryFields.Count -eq 7 -and $dryFields[6] -eq 'dry_run=true;wait_seconds=30') ("execute_csharp options were not sent as the seventh field: " + ($dryFields -join '|'))
    $dryRead = Invoke-Tool 'execute_csharp' @{ expected_document = 'doc-1'; execution_mode = 'read'; allow_model_changes = $false; code = 'return "x";'; parameters_json = '{}'; transaction_name = 'T'; dry_run = $true }
    Assert ($dryRead.isError -and $dryRead.content[0].text -like 'dry_run needs execution_mode transaction*') ("dry_run outside transaction mode must be refused: " + $dryRead.content[0].text)
    $slow = Invoke-Tool 'execute_csharp' @{ expected_document = 'doc-1'; execution_mode = 'read'; allow_model_changes = $false; code = 'return "x";'; parameters_json = '{}'; transaction_name = 'T'; wait_seconds = 500 }
    Assert ($slow.isError -and $slow.content[0].text -like 'Number out of range: wait_seconds') 'wait_seconds above 110 must be refused'
    # get_job needs no Revit rules and passes the job id and the cancel flag.
    $jobAnswer = Invoke-Tool 'get_job' @{ job_id = 'abc123' }
    $jobFields = @(($jobAnswer.content[0].text | ConvertFrom-Json).fields)
    Assert (-not $jobAnswer.isError -and ($jobFields -join '|') -eq 'abc123|False') ("get_job sent the wrong fields: " + ($jobFields -join '|'))
    # Revision cloud tools: the boxes travel as "xmin;ymin;xmax;ymax;base64(comment);base64(note)".
    $clouds = Invoke-Tool 'create_revision_clouds' @{ expected_document = 'doc-1'; revision_id = '7'; view_id = '9'; note_side = 'left'; dry_run = $true; items = @(@{ x_min_mm = 0; y_min_mm = 0; x_max_mm = 400; y_max_mm = 300; note = 'REV' }) }
    $cloudFields = @(($clouds.content[0].text | ConvertFrom-Json).fields)
    Assert (-not $clouds.isError -and $cloudFields.Count -eq 5 -and $cloudFields[3] -eq 'note_side=left;dry_run=true' -and $cloudFields[4] -eq ('0;0;400;300;;' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('REV')))) ("create_revision_clouds sent the wrong fields: " + ($cloudFields -join '|'))
    $badBox = Invoke-Tool 'create_revision_clouds' @{ expected_document = 'doc-1'; revision_id = '7'; view_id = '9'; items = @(@{ x_min_mm = 10; y_min_mm = 0; x_max_mm = 5; y_max_mm = 3 }) }
    Assert ($badBox.isError -and $badBox.content[0].text -like 'items[[]0] needs x_max_mm > x_min_mm*') ("An inverted box must be refused: " + $badBox.content[0].text)
    $info = Invoke-Tool 'revision_cloud_info' @{ view_ids = @('12', '13') }
    Assert (-not $info.isError -and (@(($info.content[0].text | ConvertFrom-Json).fields) -join '|') -eq '12|13') ('revision_cloud_info sent the wrong fields: ' + $info.content[0].text)
    'PASS: Revit add-in pipe: answers, typed add-in errors, execute_csharp options, get_job and the revision cloud tools as the bridge sends them'
}
finally {
    $env:LOCALAPPDATA = $saved
    if ($process -and -not $process.HasExited) { try { $process.StandardInput.Close() } catch { }; if (-not $process.WaitForExit(5000)) { $process.Kill() } }
    if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
