[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\remote\remote-config.json')
)

$ErrorActionPreference = 'Stop'
$statePath = Join-Path (Split-Path -Parent $ConfigPath) 'runtime.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    [pscustomobject]@{Status='already_stopped'}
    exit 0
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
foreach ($entry in @($state.gateway, $state.tunnel)) {
    if ($null -eq $entry -or $null -eq $entry.pid) { continue }
    try {
        $process = Get-Process -Id ([int]$entry.pid) -ErrorAction Stop
        $recordedStart = [DateTime]::Parse([string]$entry.started_at).ToUniversalTime()
        if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $recordedStart).TotalSeconds) -le 2) {
            Stop-Process -Id $process.Id -ErrorAction Stop
        }
    }
    catch { }
}
Remove-Item -LiteralPath $statePath -Force
[pscustomobject]@{Status='stopped'}
