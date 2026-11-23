param(
    # Optional live part: a folder holding the LibreDWG pack (dwglayers.exe, dwg2dxf.exe, ..., libredwg.dll) and a real .dwg
    # to read. Without them only the checks that need no pack run, which is what a clean CI runner can do.
    [string]$PackFolder = $env:LIBREDWG_PACK_DIR,
    [string]$SampleDwg = $env:LIBREDWG_TEST_DWG
)
$ErrorActionPreference = 'Stop'
# The offline DWG tools (dwg_inspect, dwg_convert): they are listed with the right read-only flags, refuse bad arguments with
# clear messages, say plainly when the LibreDWG pack is not installed and, when a pack and a sample drawing are given,
# read and convert a real file without ever overwriting or changing it. Windows only (SmartConnector.exe).
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { 'SKIP: SmartConnector.exe needs Windows'; return }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$t = Join-Path ([IO.Path]::GetTempPath()) ('dwg-offline-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $t 'root'
$saved = $env:LOCALAPPDATA
$process = $null
try {
    # 1. An install-shaped folder: <root>\bin\SmartConnector.exe beside VERSION and the skill library.
    $exe = Join-Path $root 'bin\SmartConnector.exe'
    $null = & (Join-Path $PSScriptRoot '../setup/build-connector-exe.ps1') -OutputPath $exe
    Copy-Item (Join-Path $runtime 'VERSION') $root
    New-Item -ItemType Directory -Force (Join-Path $root '.agents') | Out-Null
    Copy-Item (Join-Path $runtime '.agents\skills') (Join-Path $root '.agents') -Recurse
    $work = Join-Path $t 'work'
    New-Item -ItemType Directory -Force $work | Out-Null
    $stub = Join-Path $work 'stub.dwg'
    [IO.File]::WriteAllBytes($stub, [byte[]](1, 2, 3, 4, 5, 6))

    $env:LOCALAPPDATA = Join-Path $t 'local'
    New-Item -ItemType Directory -Force (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection') | Out-Null
    $info = New-Object Diagnostics.ProcessStartInfo($exe, 'mcp')
    $info.UseShellExecute = $false; $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process = [Diagnostics.Process]::Start($info)
    $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true; $writer.NewLine = "`n"
    $script:nextId = 0
    function Invoke-Mcp([string]$Method, $Params = @{}) {
        $script:nextId++
        $writer.WriteLine((@{ jsonrpc = '2.0'; id = $script:nextId; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress))
        $read = $process.StandardOutput.ReadLineAsync()
        Assert ($read.Wait(120000)) "$Method did not answer"
        $answer = $read.Result | ConvertFrom-Json
        Assert ($answer.id -eq $script:nextId) "Answer id $($answer.id) does not match request $($script:nextId)"
        $answer
    }
    function Invoke-Tool([string]$Name, $Arguments = @{}) { (Invoke-Mcp 'tools/call' @{ name = $Name; arguments = $Arguments }).result }
    function Get-Text($Result) { [string]$Result.content[0].text }
    function Assert-Refused($Result, [string]$Pattern, [string]$What) {
        Assert ($Result.isError -eq $true -and (Get-Text $Result) -match $Pattern) "$What was not refused as expected: $(Get-Text $Result)"
    }

    # 2. Listed once each, with the right read-only flags and choices.
    $tools = @((Invoke-Mcp 'tools/list').result.tools)
    $inspect = @($tools | Where-Object name -eq 'dwg_inspect'); $convert = @($tools | Where-Object name -eq 'dwg_convert')
    Assert ($inspect.Count -eq 1 -and $convert.Count -eq 1) 'dwg_inspect and dwg_convert must each be listed once'
    Assert ($inspect[0].annotations.readOnlyHint -eq $true) 'dwg_inspect must be read-only'
    Assert ($convert[0].annotations.readOnlyHint -eq $false) 'dwg_convert writes a file, so it must not be read-only'
    Assert ((@($inspect[0].inputSchema.properties.action.enum) -join ',') -eq 'layers,search') 'dwg_inspect actions are wrong'
    Assert ((@($convert[0].inputSchema.properties.action.enum) -join ',') -eq 'to_dxf,to_json,save_as_version,thumbnail') 'dwg_convert actions are wrong'
    'PASS: dwg_inspect (read-only) and dwg_convert (writes a new file) are listed with their choices'

    # 3. Bad arguments are refused before any program starts.
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'layers'; file = 'relative\plan.dwg' }) 'absolute path' 'A relative path'
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'layers'; file = (Join-Path $work 'plan.dxf') }) 'Only \.dwg' 'A .dxf file'
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'layers'; file = (Join-Path $work 'missing.dwg') }) 'was not found' 'A missing file'
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'layers'; file = ($stub + '" -o x') }) 'Invalid path' 'A path with a quote'
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'layers'; file = '-o C:\x.dwg' }) 'absolute path|Invalid' 'A path that looks like an option'
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'explode'; file = $stub }) 'Invalid choice' 'An unknown action'
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'layers'; file = $stub; flags = 'x' }) 'Unknown argument' 'An unknown argument'
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'search'; file = $stub }) 'Missing argument: pattern' 'A search without a pattern'
    Assert-Refused (Invoke-Tool 'dwg_convert' @{ action = 'save_as_version'; file = $stub }) 'needs version' 'save_as_version without a version'
    Assert-Refused (Invoke-Tool 'dwg_convert' @{ action = 'to_dxf'; file = $stub; output_dir = (Join-Path $work 'nowhere') }) 'output folder was not found' 'A missing output folder'
    'PASS: relative, non-.dwg, missing, quoted and option-like paths and bad choices are refused'

    # 4. Without the pack the answer says so, and nothing is written.
    $before = @(Get-ChildItem $work).Count
    Assert-Refused (Invoke-Tool 'dwg_convert' @{ action = 'to_dxf'; file = $stub }) 'not installed' 'A conversion without the LibreDWG pack'
    Assert-Refused (Invoke-Tool 'dwg_inspect' @{ action = 'layers'; file = $stub }) 'not installed' 'A layer list without the LibreDWG pack'
    Assert (@(Get-ChildItem $work).Count -eq $before) 'A refused conversion must leave no file behind'
    'PASS: a missing pack is reported plainly and writes nothing'

    # 5. Live part, only with a pack and a sample drawing.
    if ($PackFolder -and $SampleDwg -and (Test-Path -LiteralPath (Join-Path $PackFolder 'libredwg.dll')) -and (Test-Path -LiteralPath $SampleDwg)) {
        $pack = Join-Path $root 'bin\libredwg'
        New-Item -ItemType Directory -Force $pack | Out-Null
        Copy-Item (Join-Path $PackFolder '*') $pack -Recurse
        $drawing = Join-Path $work 'sample.dwg'
        Copy-Item -LiteralPath $SampleDwg $drawing
        $hash = (Get-FileHash $drawing -Algorithm SHA256).Hash

        $layers = Invoke-Tool 'dwg_inspect' @{ action = 'layers'; file = $drawing; with_flags = $true }
        Assert (-not $layers.isError) "Layer list failed: $(Get-Text $layers)"
        $layerData = Get-Text $layers | ConvertFrom-Json
        Assert ($layerData.count -ge 1 -and $layerData.layers[0].name) 'The layer list is empty'

        $first = Invoke-Tool 'dwg_convert' @{ action = 'to_dxf'; file = $drawing }
        Assert (-not $first.isError) "to_dxf failed: $(Get-Text $first)"
        $firstData = Get-Text $first | ConvertFrom-Json
        Assert ((Split-Path -Leaf $firstData.output) -eq 'sample.dxf' -and (Test-Path -LiteralPath $firstData.output) -and $firstData.bytes -gt 0 -and $firstData.note) 'to_dxf did not write sample.dxf with a note'
        $second = Get-Text (Invoke-Tool 'dwg_convert' @{ action = 'to_dxf'; file = $drawing }) | ConvertFrom-Json
        Assert ((Split-Path -Leaf $second.output) -eq 'sample-1.dxf') 'A second conversion must use a new name, not overwrite sample.dxf'

        $rewritten = Get-Text (Invoke-Tool 'dwg_convert' @{ action = 'save_as_version'; file = $drawing; version = 'r2000' }) | ConvertFrom-Json
        Assert ((Split-Path -Leaf $rewritten.output) -eq 'sample-r2000.dwg' -and (Test-Path -LiteralPath $rewritten.output)) 'save_as_version did not write sample-r2000.dwg'

        $thumb = Invoke-Tool 'dwg_convert' @{ action = 'thumbnail'; file = $drawing }
        Assert (-not $thumb.isError) "thumbnail failed: $(Get-Text $thumb)"

        $search = Invoke-Tool 'dwg_inspect' @{ action = 'search'; file = $drawing; pattern = 'zzz-no-such-text-zzz' }
        Assert (-not $search.isError -and ((Get-Text $search | ConvertFrom-Json).count -eq 0)) 'A search with no match must answer with an empty list, not an error'

        $bad = Join-Path $work 'damaged.dwg'
        [IO.File]::WriteAllBytes($bad, [byte[]](1, 2, 3, 4, 5, 6))
        Assert-Refused (Invoke-Tool 'dwg_convert' @{ action = 'to_dxf'; file = $bad }) 'failed' 'A damaged drawing'
        Assert (-not (Test-Path -LiteralPath (Join-Path $work 'damaged.dxf'))) 'A failed conversion must not leave an empty output file'

        Assert ((Get-FileHash $drawing -Algorithm SHA256).Hash -eq $hash) 'The source drawing was changed'
        'PASS: layers, DXF, a second DXF under a new name, an older DWG version, thumbnail, an empty search and a damaged file; the source is unchanged'
    }
    else {
        'SKIP: live conversion (set LIBREDWG_PACK_DIR and LIBREDWG_TEST_DWG to run it)'
    }
}
finally {
    if ($process -and -not $process.HasExited) { try { $process.StandardInput.Close(); if (-not $process.WaitForExit(5000)) { $process.Kill() } } catch { } }
    $env:LOCALAPPDATA = $saved
    Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
}
'dwg-offline: all checks passed'
