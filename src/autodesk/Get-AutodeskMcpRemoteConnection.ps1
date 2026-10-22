[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\remote\remote-config.json'),
    [switch]$RevealCredential
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'Remote Claude access has not been configured on this workstation.' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$statePath = Join-Path (Split-Path -Parent $ConfigPath) 'runtime.json'
$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $null }
}
else { $null }

function Test-RecordedProcess {
    param([object]$Record, [string]$ExpectedName)
    if ($null -eq $Record -or $null -eq $Record.pid -or $null -eq $Record.started_at) { return $false }
    try {
        $process = Get-Process -Id ([int]$Record.pid) -ErrorAction Stop
        if ($process.ProcessName -notlike $ExpectedName) { return $false }
        $recordedStart = [DateTime]::Parse([string]$Record.started_at).ToUniversalTime()
        [Math]::Abs(($process.StartTime.ToUniversalTime() - $recordedStart).TotalSeconds) -le 2
    }
    catch { $false }
}

$result = [ordered]@{
    PublicUrl = [string]$config.public_url
    HeaderName = 'Authorization'
    GatewayRunning = Test-RecordedProcess -Record $state.gateway -ExpectedName 'powershell*'
    TunnelRunning = Test-RecordedProcess -Record $state.tunnel -ExpectedName 'cloudflared*'
    AdvancedControlEnabled = [bool]$config.allow_advanced_control
}
if ($RevealCredential) {
    $protectedBytes = [Convert]::FromBase64String((Get-Content -LiteralPath ([string]$config.access_token_file) -Raw).Trim())
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { $result.HeaderValue = 'Bearer ' + [Text.Encoding]::UTF8.GetString($plainBytes) }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}
[pscustomobject]$result
