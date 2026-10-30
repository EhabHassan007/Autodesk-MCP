[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\remote\remote-config.json')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function ConvertFrom-ProtectedFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Protected credential was not found: $Path" }
    $protectedBytes = [Convert]::FromBase64String((Get-Content -LiteralPath $Path -Raw).Trim())
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { [Text.Encoding]::UTF8.GetString($plainBytes) }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}

function Test-RecordedProcess {
    param([object]$Record, [string]$ExpectedName)
    if ($null -eq $Record -or $null -eq $Record.pid) { return $false }
    try {
        $process = Get-Process -Id ([int]$Record.pid) -ErrorAction Stop
        if ($process.ProcessName -notlike $ExpectedName) { return $false }
        if ($null -ne $Record.started_at) {
            $recordedStart = [DateTime]::Parse([string]$Record.started_at).ToUniversalTime()
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $recordedStart).TotalSeconds) -gt 2) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function ConvertTo-QuotedProcessArgument {
    param([Parameter(Mandatory=$true)][string]$Value)
    '"' + $Value.Replace('"', '\"') + '"'
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Remote connector config was not found: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$stateDirectory = Split-Path -Parent $ConfigPath
$statePath = Join-Path $stateDirectory 'runtime.json'
$logPath = Join-Path $stateDirectory 'cloudflared.log'
$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $null }
}
else { $null }

$gatewayRunning = Test-RecordedProcess -Record $state.gateway -ExpectedName 'powershell*'
$tunnelRunning = Test-RecordedProcess -Record $state.tunnel -ExpectedName 'cloudflared*'
$gatewayStartedHere = $false
$tunnelStartedHere = $false

if (-not $gatewayRunning) {
    $gatewayArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -Port {1} -TokenFile {2}' -f
        (ConvertTo-QuotedProcessArgument -Value ([string]$config.gateway_script)),
        ([int]$config.port),
        (ConvertTo-QuotedProcessArgument -Value ([string]$config.access_token_file))
    if ([bool]$config.allow_advanced_control) { $gatewayArguments += ' -AllowAdvancedControl' }
    $gateway = Start-Process -FilePath 'powershell.exe' -ArgumentList $gatewayArguments -WindowStyle Hidden -PassThru
    $gatewayStartedHere = $true
}
else { $gateway = Get-Process -Id ([int]$state.gateway.pid) }

try {
    if (-not $tunnelRunning) {
        $tunnelToken = ConvertFrom-ProtectedFile -Path ([string]$config.tunnel_token_file)
        try {
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = [string]$config.cloudflared_path
            $startInfo.Arguments = "tunnel --no-autoupdate --loglevel info --logfile `"$logPath`" run"
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.EnvironmentVariables['TUNNEL_TOKEN'] = $tunnelToken
            $tunnel = [Diagnostics.Process]::Start($startInfo)
            $tunnelStartedHere = $true
        }
        finally { $tunnelToken = $null }
    }
    else { $tunnel = Get-Process -Id ([int]$state.tunnel.pid) }

    Start-Sleep -Milliseconds 750
    if ($gateway.HasExited) { throw 'The authenticated MCP HTTP gateway stopped during startup.' }
    if ($tunnel.HasExited) { throw "Cloudflare Tunnel stopped during startup. See $logPath" }
}
catch {
    if ($tunnelStartedHere -and $null -ne $tunnel) {
        Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
    }
    if ($gatewayStartedHere -and $null -ne $gateway) {
        Stop-Process -Id $gateway.Id -Force -ErrorAction SilentlyContinue
    }
    throw
}

$runtime = [ordered]@{
    gateway = @{pid=$gateway.Id;started_at=$gateway.StartTime.ToUniversalTime().ToString('o')}
    tunnel = @{pid=$tunnel.Id;started_at=$tunnel.StartTime.ToUniversalTime().ToString('o')}
    public_url = [string]$config.public_url
}
$temporaryState = $statePath + '.tmp'
$runtime | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryState -Encoding UTF8
Move-Item -LiteralPath $temporaryState -Destination $statePath -Force

[pscustomobject]@{
    Status = 'running'
    PublicUrl = [string]$config.public_url
    GatewayProcessId = $gateway.Id
    TunnelProcessId = $tunnel.Id
}
