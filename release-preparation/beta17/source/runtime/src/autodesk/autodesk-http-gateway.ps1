[CmdletBinding()]
param(
    [ValidatePattern('^\d{4}$')]
    [string]$RevitVersion = '2024',

    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,

    [string]$TokenFile = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\remote\access-token.dpapi'),

    [ValidateRange(4096, 4194304)]
    [int]$MaxRequestBytes = 1048576,

    [string[]]$AllowedOrigins = @(
        'https://claude.ai',
        'https://www.claude.ai',
        'https://claude.com',
        'https://www.claude.com'
    ),

    [switch]$AllowAdvancedControl,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
$gatewayLibraryOnly = [bool]$LibraryOnly
Add-Type -AssemblyName System.Security

$bridge = Join-Path $PSScriptRoot 'autodesk-bridge.ps1'
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) {
    throw "Autodesk MCP bridge was not found: $bridge"
}
. $bridge -LibraryOnly -RevitVersion $RevitVersion

$blockedRemoteTools = @('execute_csharp')
$remoteTools = @(Get-AutodeskMcpTools | Where-Object {
    $AllowAdvancedControl -or ([string]$_['name'] -notin $blockedRemoteTools)
})

function ConvertFrom-ProtectedString {
    param([Parameter(Mandatory=$true)][string]$ProtectedValue)
    $protectedBytes = [Convert]::FromBase64String($ProtectedValue)
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { [Text.Encoding]::UTF8.GetString($plainBytes) }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}

function Get-RemoteAccessToken {
    if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
        throw "Remote access token was not found: $TokenFile. Run Initialize-AutodeskMcpRemote.ps1 first."
    }
    $protected = (Get-Content -LiteralPath $TokenFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($protected)) { throw 'Remote access token file is empty.' }
    ConvertFrom-ProtectedString -ProtectedValue $protected
}

function Test-FixedTimeEqual {
    param([string]$Left, [string]$Right)

    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $leftBytes = [Text.Encoding]::UTF8.GetBytes($Left)
    $rightBytes = [Text.Encoding]::UTF8.GetBytes($Right)
    $difference = $leftBytes.Length -bxor $rightBytes.Length
    $length = [Math]::Max($leftBytes.Length, $rightBytes.Length)
    for ($index = 0; $index -lt $length; $index++) {
        $leftByte = if ($index -lt $leftBytes.Length) { $leftBytes[$index] } else { 0 }
        $rightByte = if ($index -lt $rightBytes.Length) { $rightBytes[$index] } else { 0 }
        $difference = $difference -bor ($leftByte -bxor $rightByte)
    }
    $difference -eq 0
}

function Get-HttpRequest {
    param([Parameter(Mandatory=$true)][Net.Sockets.TcpClient]$Client)

    $stream = $Client.GetStream()
    $headerBytes = New-Object System.Collections.Generic.List[byte]
    $matched = 0
    $terminator = [byte[]](13,10,13,10)
    while ($headerBytes.Count -lt 32768) {
        $value = $stream.ReadByte()
        if ($value -lt 0) { throw 'Connection closed before the HTTP headers completed.' }
        $headerBytes.Add([byte]$value)
        if ([byte]$value -eq $terminator[$matched]) {
            $matched++
            if ($matched -eq 4) { break }
        }
        else { $matched = if ([byte]$value -eq 13) { 1 } else { 0 } }
    }
    if ($matched -ne 4) { throw 'HTTP headers exceeded 32 KB.' }

    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = @($headerText -split "`r`n")
    $requestLine = @($lines[0] -split ' ')
    if ($requestLine.Count -lt 3) { throw 'Invalid HTTP request line.' }
    $headers = @{}
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $separator = $line.IndexOf(':')
        if ($separator -le 0) { throw 'Invalid HTTP header.' }
        $headerName = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        if ($headers.ContainsKey($headerName)) { throw "Duplicate HTTP header is not allowed: $headerName" }
        $headers[$headerName] = $line.Substring($separator + 1).Trim()
    }

    if ($headers.ContainsKey('transfer-encoding')) { throw 'Transfer-Encoding is not supported.' }

    $contentLength = 0
    if ($headers.ContainsKey('content-length')) {
        if (-not [int]::TryParse($headers['content-length'], [ref]$contentLength) -or $contentLength -lt 0) {
            throw 'Invalid Content-Length header.'
        }
    }
    if ($contentLength -gt $MaxRequestBytes) { throw "Request body exceeds $MaxRequestBytes bytes." }
    $bodyBytes = New-Object byte[] $contentLength
    $offset = 0
    while ($offset -lt $contentLength) {
        $read = $stream.Read($bodyBytes, $offset, $contentLength - $offset)
        if ($read -le 0) { throw 'Connection closed before the request body completed.' }
        $offset += $read
    }

    [pscustomobject]@{
        Method = $requestLine[0].ToUpperInvariant()
        Path = $requestLine[1]
        Headers = $headers
        Body = [Text.Encoding]::UTF8.GetString($bodyBytes)
        Stream = $stream
    }
}

function Write-HttpResponse {
    param(
        [Parameter(Mandatory=$true)][IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$Reason,
        [string]$Body = '',
        [string]$ContentType = 'application/json'
    )

    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $headers = "HTTP/1.1 $StatusCode $Reason`r`n" +
        "Content-Type: $ContentType; charset=utf-8`r`n" +
        "Content-Length: $($bodyBytes.Length)`r`n" +
        "Connection: close`r`n" +
        "Cache-Control: no-store`r`n" +
        "X-Content-Type-Options: nosniff`r`n" +
        "MCP-Protocol-Version: 2025-06-18`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
}

function New-JsonRpcError {
    param([object]$Id, [int]$Code, [string]$Message)
    @{jsonrpc='2.0';id=$Id;error=@{code=$Code;message=$Message}}
}

function Invoke-RemoteMcpRequest {
    param([Parameter(Mandatory=$true)][object]$Request)

    if ([string]$Request.method -eq 'tools/list' -and $null -ne $Request.id) {
        return @{jsonrpc='2.0';id=$Request.id;result=@{tools=$remoteTools}}
    }
    if ([string]$Request.method -eq 'tools/call') {
        $name = [string]$Request.params.name
        if (-not $AllowAdvancedControl -and $name -in $blockedRemoteTools) {
            return @{jsonrpc='2.0';id=$Request.id;result=@{
                content=@(@{type='text';text='This advanced-control tool is disabled on remote connections.'})
                isError=$true
            }}
        }
    }
    Invoke-AutodeskMcpRequest -Request $Request
}

function Invoke-HttpConnection {
    param(
        [Parameter(Mandatory=$true)][Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory=$true)][string]$ExpectedToken
    )

    try {
        $request = Get-HttpRequest -Client $Client
        $authorization = [string]$request.Headers['authorization']
        $presentedToken = if ($authorization.StartsWith('Bearer ', [StringComparison]::OrdinalIgnoreCase)) {
            $authorization.Substring(7).Trim()
        }
        else { [string]$request.Headers['x-autodesk-mcp-key'] }
        if (-not (Test-FixedTimeEqual -Left $presentedToken -Right $ExpectedToken)) {
            Write-HttpResponse -Stream $request.Stream -StatusCode 401 -Reason 'Unauthorized' -Body '{"error":"Unauthorized"}'
            return
        }

        $origin = [string]$request.Headers['origin']
        if (-not [string]::IsNullOrWhiteSpace($origin) -and $origin.TrimEnd('/') -notin $AllowedOrigins) {
            Write-HttpResponse -Stream $request.Stream -StatusCode 403 -Reason 'Forbidden' -Body '{"error":"Origin is not allowed"}'
            return
        }

        if ($request.Path.Split('?')[0].TrimEnd('/') -notin @('/mcp','/health')) {
            Write-HttpResponse -Stream $request.Stream -StatusCode 404 -Reason 'Not Found' -Body '{"error":"Not found"}'
            return
        }
        if ($request.Method -eq 'OPTIONS') {
            Write-HttpResponse -Stream $request.Stream -StatusCode 204 -Reason 'No Content' -ContentType 'text/plain'
            return
        }

        $pathOnly = $request.Path.Split('?')[0].TrimEnd('/')
        if ($pathOnly -eq '/health') {
            if ($request.Method -ne 'GET') {
                Write-HttpResponse -Stream $request.Stream -StatusCode 405 -Reason 'Method Not Allowed' -Body '{"error":"Method not allowed"}'
            }
            else {
                Write-HttpResponse -Stream $request.Stream -StatusCode 200 -Reason 'OK' -Body '{"status":"ready","transport":"streamable-http"}'
            }
            return
        }

        if ($request.Method -eq 'GET') {
            Write-HttpResponse -Stream $request.Stream -StatusCode 405 -Reason 'Method Not Allowed' -Body '{"error":"SSE stream is not supported by this stateless server"}'
            return
        }
        if ($request.Method -ne 'POST') {
            Write-HttpResponse -Stream $request.Stream -StatusCode 405 -Reason 'Method Not Allowed' -Body '{"error":"Method not allowed"}'
            return
        }

        try { $payload = $request.Body | ConvertFrom-Json }
        catch {
            $parseError = New-JsonRpcError -Id $null -Code -32700 -Message 'Parse error'
            Write-HttpResponse -Stream $request.Stream -StatusCode 400 -Reason 'Bad Request' -Body ($parseError | ConvertTo-Json -Depth 10 -Compress)
            return
        }

        $items = if ($payload -is [array]) { @($payload) } else { @($payload) }
        $responses = New-Object System.Collections.Generic.List[object]
        foreach ($item in $items) {
            try {
                $response = Invoke-RemoteMcpRequest -Request $item
                if ($null -ne $response) { $responses.Add($response) }
            }
            catch { $responses.Add((New-JsonRpcError -Id $item.id -Code -32603 -Message $_.Exception.Message)) }
        }
        if ($responses.Count -eq 0) {
            Write-HttpResponse -Stream $request.Stream -StatusCode 202 -Reason 'Accepted' -ContentType 'text/plain'
            return
        }
        $responseBody = if ($payload -is [array]) {
            ConvertTo-Json -InputObject @($responses) -Depth 30 -Compress
        }
        else { $responses[0] | ConvertTo-Json -Depth 30 -Compress }
        Write-HttpResponse -Stream $request.Stream -StatusCode 200 -Reason 'OK' -Body $responseBody
    }
    catch {
        try {
            if ($null -ne $Client -and $Client.Connected) {
                Write-HttpResponse -Stream $Client.GetStream() -StatusCode 400 -Reason 'Bad Request' -Body '{"error":"Invalid request"}'
            }
        }
        catch { }
    }
    finally { $Client.Dispose() }
}

if ($gatewayLibraryOnly) { return }

$token = Get-RemoteAccessToken
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start(16)
try {
    Write-Output ("Autodesk MCP authenticated HTTP gateway listening on http://127.0.0.1:{0}/mcp" -f $Port)
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 130000
        $client.SendTimeout = 130000
        Invoke-HttpConnection -Client $client -ExpectedToken $token
    }
}
finally {
    $listener.Stop()
    $token = $null
}
