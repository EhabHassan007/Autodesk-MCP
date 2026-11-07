$ErrorActionPreference='Stop'
$root=(Join-Path $PSScriptRoot '../source/runtime')
$tmp=[IO.Path]::GetTempPath();$env:LOCALAPPDATA=Join-Path $tmp 'reg-test-local';$env:APPDATA=Join-Path $tmp 'reg-test-roaming'
. "$root/installer/Setup-BimCad.ps1" -LibraryOnly
# A shell that exists on both Windows (cmd) and Linux (sh), for one command with known output and exit code.
$windows=[Environment]::OSVersion.Platform -eq 'Win32NT'
$shell=if($windows){'cmd.exe'}else{'/bin/sh'};$flag=if($windows){'/c'}else{'-c'}
$r=@(Invoke-External $shell @($flag,'echo diagnostic& exit 0'.Replace('&',$(if($windows){'&'}else{';'}))))
if($r.Count -ne 1 -or $r[0].ExitCode -ne 0 -or $r[0].Output[0] -ne 'diagnostic'){throw 'Mixed command output with result object'}
try { Invoke-External $shell @($flag,$(if($windows){'echo actual-error 1>&2& exit 1'}else{'echo actual-error >&2; exit 1'}));throw 'Expected failure' }
catch {if($_.Exception.Message -notmatch 'actual-error'){throw}}
'PASS: external command returns one result; captures stderr and operation on failure'
function Get-RequiredCommand { 'fake-codex' }
$script:calls=@();$script:matching=$true
function Invoke-External {
 param($FilePath,$Arguments,[switch]$AllowFailure)
 $script:calls+=($Arguments -join ' ')
 # Only an older duplicate of this connector, listed as a legacy name, may be removed; never the live entry or another tool's.
 if($Arguments[1] -eq 'remove' -and $Arguments[2] -ne 'AutoCAD MCP'){throw "Unexpected removal of $($Arguments[2])"}
 if($Arguments[1] -eq 'get'){
  $cmd=if($script:matching){'powershell.exe'}else{'old.exe'}
  return [pscustomobject]@{ExitCode=0;Output=@((@{enabled=$true;transport=@{command=$cmd;args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$root/src/autodesk/autodesk-bridge.ps1",'-RevitVersion','2024')}}|ConvertTo-Json -Depth 5 -Compress))}
 }
 [pscustomobject]@{ExitCode=0;Output=@('registered')}
}
Register-McpServer -Name autodesk -Bridge "$root/src/autodesk/autodesk-bridge.ps1" -BridgeArguments @('-RevitVersion','2024') -LegacyNames @('AutoCAD MCP')
if($script:calls -match '^mcp add'){throw 'Rewrote correct registration'}
if(@($script:calls -match '^mcp remove').Count -ne 1 -or -not ($script:calls -match '^mcp remove AutoCAD MCP')){throw 'Older duplicate entry was not removed'}
$script:calls=@();$script:matching=$false
Register-McpServer -Name autodesk -Bridge "$root/src/autodesk/autodesk-bridge.ps1" -BridgeArguments @('-RevitVersion','2024')
if(-not ($script:calls -match '^mcp add autodesk')){throw 'Did not repair wrong registration'}
'PASS: existing correct Codex registration preserved; older duplicate removed; wrong registration replaced without removing other connectors'
# The compiled SmartConnector.exe is started directly with "mcp"; a .ps1 bridge still goes through powershell.exe.
$exe=Join-Path $tmp 'reg-test-bin/SmartConnector.exe';New-Item -ItemType Directory -Force (Split-Path $exe)|Out-Null;'x'|Set-Content $exe
$launch=Get-McpLaunch $exe @('mcp')
if($launch.Command -ne $exe -or (@($launch.Arguments) -join ' ') -ne 'mcp'){throw 'The exe is not launched directly with mcp'}
$launch=Get-McpLaunch "$root/src/autodesk/autodesk-bridge.ps1" @('-RevitVersion','2024')
if($launch.Command -ne 'powershell.exe' -or $launch.Arguments[-3] -notlike '*autodesk-bridge.ps1' -or $launch.Arguments[-1] -ne '2024'){throw 'The .ps1 bridge launch changed'}
$script:calls=@();$script:matching=$false
Register-McpServer -Name autodesk -Bridge $exe -BridgeArguments @('mcp')
if(-not ($script:calls -contains "mcp add autodesk -- $exe mcp")){throw "Codex was not registered with the exe: $($script:calls -join ' | ')"}
if(Test-OwnConnectorEntry 'other-tool.exe mcp'){throw 'Another tool counted as this connector'}
if(-not (Test-OwnConnectorEntry "$exe mcp")){throw 'SmartConnector.exe not recognised as this connector'}
'PASS: SmartConnector.exe registered directly with mcp; the .ps1 bridge launch is unchanged'
# Execute the real Update action body with dependency stubs.
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile("$root/installer/Setup-BimCad.ps1",[ref]$t,[ref]$e)
$sw=$ast.FindAll({param($n) $n -is [Management.Automation.Language.SwitchStatementAst]},$true)|Where-Object {$_.Condition.Extent.Text -eq '$Action'}
$body=($sw.Clauses|Where-Object {$_.Item1.Value -eq 'Update'}).Item2.Extent.Text
function Get-Repository { $script:UpdateDownloaded=$false; $root }
function Install-Skills { throw 'No-op update must not reinstall skills' }
function Register-DetectedAiClients { throw 'No-op update must not re-register clients' }
& ([scriptblock]::Create("switch ('Update') { 'Update' $body }"))
'PASS: no-update action does not reinstall or re-register'
. "$root/src/autodesk/autodesk-bridge.ps1" -LibraryOnly
foreach($method in @('initialize','ping','tools/list')){
 $response=Invoke-AutodeskMcpRequest ([pscustomobject]@{id=1;method=$method;params=[pscustomobject]@{protocolVersion='2024-11-05'}})
 if($response.error -or -not $response.result){throw "MCP $method failed"}
 if($method -eq 'tools/list' -and $response.result.tools.Count -lt 1){throw 'No MCP tools'}
}
'PASS: unified MCP initialization, ping, and tool discovery (no live Autodesk calls)'
