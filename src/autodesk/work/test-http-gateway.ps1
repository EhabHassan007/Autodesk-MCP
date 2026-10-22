[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Net.Http
$gatewayScript = Resolve-Path (Join-Path $PSScriptRoot '..\autodesk-http-gateway.ps1')
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('AutodeskMcpHttpTest-' + [Guid]::NewGuid().ToString('N'))
$port = Get-Random -Minimum 20000 -Maximum 45000
$token = 'test-' + [Guid]::NewGuid().ToString('N')
$process = $null

function Send-Request {
    param(
        [string]$Method = 'POST',
        [string]$Path = '/mcp',
        [string]$Body = '',
        [string]$Bearer,
        [string]$Origin
    )
    $client = New-Object Net.Http.HttpClient
    try {
        $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::new($Method), "http://127.0.0.1:$port$Path")
        if (-not [string]::IsNullOrWhiteSpace($Bearer)) { $request.Headers.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Bearer) }
        if (-not [string]::IsNullOrWhiteSpace($Origin)) { $request.Headers.TryAddWithoutValidation('Origin', $Origin) | Out-Null }
        if ($Method -eq 'POST') { $request.Content = New-Object Net.Http.StringContent($Body, [Text.Encoding]::UTF8, 'application/json') }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        [pscustomobject]@{
            Status = [int]$response.StatusCode
            Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
    }
    finally { $client.Dispose() }
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $tokenFile = Join-Path $temporaryRoot 'token.dpapi'
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($token)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [Convert]::ToBase64String($protectedBytes) | Set-Content -LiteralPath $tokenFile -Encoding UTF8
    }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    $stdout = Join-Path $temporaryRoot 'stdout.log'
    $stderr = Join-Path $temporaryRoot 'stderr.log'
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',[string]$gatewayScript,
        '-Port',[string]$port,'-TokenFile',$tokenFile
    ) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru

    $ready = $false
    $lastHealthDiagnostic = ''
    foreach ($attempt in 1..30) {
        Start-Sleep -Milliseconds 100
        if ($process.HasExited) {
            $diagnostic = @(
                Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
                Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
            ) -join [Environment]::NewLine
            throw "Gateway stopped during test startup: $diagnostic"
        }
        try {
            $health = Send-Request -Method GET -Path '/health' -Bearer $token
            $lastHealthDiagnostic = "HTTP $($health.Status): $($health.Body)"
            if ($health.Status -eq 200) { $ready = $true; break }
        }
        catch { $lastHealthDiagnostic = $_.Exception.Message }
    }
    if (-not $ready) {
        $gatewayOutput = @(
            Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
        ) -join [Environment]::NewLine
        throw "Gateway did not become ready. Last health result: $lastHealthDiagnostic`n$gatewayOutput"
    }

    $unauthorized = Send-Request -Body '{"jsonrpc":"2.0","id":1,"method":"ping"}'
    if ($unauthorized.Status -ne 401) { throw "Expected 401 without a credential; got $($unauthorized.Status)." }

    $badOrigin = Send-Request -Body '{"jsonrpc":"2.0","id":1,"method":"ping"}' -Bearer $token -Origin 'https://example.invalid'
    if ($badOrigin.Status -ne 403) { throw "Expected 403 for an invalid origin; got $($badOrigin.Status)." }

    $initialize = Send-Request -Bearer $token -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
    $initializeJson = $initialize.Body | ConvertFrom-Json
    if ($initialize.Status -ne 200 -or $initializeJson.result.serverInfo.name -ne 'Autodesk MCP Connector') { throw 'Initialize response is invalid.' }

    $listed = Send-Request -Bearer $token -Body '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    $listedJson = $listed.Body | ConvertFrom-Json
    $names = @($listedJson.result.tools | Select-Object -ExpandProperty name)
    if ('execute_csharp' -in $names) { throw 'Remote tools must not expose execute_csharp by default.' }
    if ('connection_status' -notin $names -or 'document_info' -notin $names) { throw 'Expected Revit read tools are missing.' }

    [pscustomobject]@{
        Status = 'passed'
        Port = $port
        ToolCount = $names.Count
        AdvancedControlExposed = ('execute_csharp' -in $names)
        AuthenticationRequired = $true
        OriginValidation = $true
    }
}
finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedSystemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemporary.StartsWith($resolvedSystemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
