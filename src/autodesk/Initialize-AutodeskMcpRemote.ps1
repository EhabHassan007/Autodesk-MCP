[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^https://')]
    [string]$PublicUrl,

    [Parameter(Mandatory=$true)]
    [Security.SecureString]$CloudflareTunnelToken,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,

    [string]$CloudflaredPath,
    [string]$ConfigurationDirectory = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\remote'),
    [switch]$InstallCloudflaredIfMissing,
    [switch]$AllowAdvancedControl,
    [switch]$SkipStartupRegistration,
    [switch]$DoNotStart
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Get-CloudflaredExecutable {
    if (-not [string]::IsNullOrWhiteSpace($CloudflaredPath)) {
        if (-not (Test-Path -LiteralPath $CloudflaredPath -PathType Leaf)) { throw "cloudflared was not found: $CloudflaredPath" }
        return [IO.Path]::GetFullPath($CloudflaredPath)
    }
    $command = Get-Command cloudflared.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe'),
        (Join-Path $env:ProgramFiles 'Cloudflare\Cloudflared\cloudflared.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\cloudflared.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    if ($InstallCloudflaredIfMissing) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $winget) { throw 'Windows Package Manager is required to install cloudflared automatically.' }
        & $winget.Source install --id Cloudflare.cloudflared --exact --source winget --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "cloudflared installation failed with exit code $LASTEXITCODE." }
        $command = Get-Command cloudflared.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
        foreach ($candidate in @(
            (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\cloudflared.exe')
        )) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    throw 'cloudflared is not installed. Install Cloudflare.cloudflared or rerun with -InstallCloudflaredIfMissing.'
}

function New-AccessToken {
    $bytes = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) }
    finally { $generator.Dispose() }
    ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Protect-PlainText {
    param([Parameter(Mandatory=$true)][string]$Value)
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [Convert]::ToBase64String($protectedBytes)
    }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}

$publicUri = $null
if (-not [Uri]::TryCreate($PublicUrl, [UriKind]::Absolute, [ref]$publicUri) -or
    $publicUri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($publicUri.Host) -or
    -not [string]::IsNullOrWhiteSpace($publicUri.Query) -or -not [string]::IsNullOrWhiteSpace($publicUri.Fragment)) {
    throw 'PublicUrl must be a plain HTTPS hostname or path without a query string or fragment.'
}
$baseUrl = $PublicUrl.TrimEnd('/')
if ($baseUrl.EndsWith('/mcp', [StringComparison]::OrdinalIgnoreCase)) { $baseUrl = $baseUrl.Substring(0, $baseUrl.Length - 4).TrimEnd('/') }
$normalizedUrl = $baseUrl + '/mcp'

$resolvedCloudflared = Get-CloudflaredExecutable
$resolvedDirectory = [IO.Path]::GetFullPath($ConfigurationDirectory)
New-Item -ItemType Directory -Path $resolvedDirectory -Force | Out-Null

$accessToken = New-AccessToken
$accessTokenPath = Join-Path $resolvedDirectory 'access-token.dpapi'
$tunnelTokenPath = Join-Path $resolvedDirectory 'cloudflare-token.dpapi'
$configPath = Join-Path $resolvedDirectory 'remote-config.json'
$temporaryConfig = $configPath + '.tmp'

Protect-PlainText -Value $accessToken | Set-Content -LiteralPath $accessTokenPath -Encoding UTF8
$tunnelPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($CloudflareTunnelToken)
try { $tunnelTokenText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tunnelPointer) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tunnelPointer) }
$protectedTunnelToken = Protect-PlainText -Value $tunnelTokenText
$tunnelTokenText = $null
$protectedTunnelToken | Set-Content -LiteralPath $tunnelTokenPath -Encoding UTF8

$config = [ordered]@{
    schema_version = 1
    public_url = $normalizedUrl
    port = $Port
    cloudflared_path = $resolvedCloudflared
    gateway_script = (Join-Path $PSScriptRoot 'autodesk-http-gateway.ps1')
    start_script = (Join-Path $PSScriptRoot 'Start-AutodeskMcpRemote.ps1')
    access_token_file = $accessTokenPath
    tunnel_token_file = $tunnelTokenPath
    allow_advanced_control = [bool]$AllowAdvancedControl
    configured_at = [DateTime]::UtcNow.ToString('o')
}
$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryConfig -Encoding UTF8
$null = Get-Content -LiteralPath $temporaryConfig -Raw | ConvertFrom-Json
Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force

$startupPath = $null
if (-not $SkipStartupRegistration) {
    $startupDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    New-Item -ItemType Directory -Path $startupDirectory -Force | Out-Null
    $startupPath = Join-Path $startupDirectory 'Autodesk MCP Remote Connector.cmd'
    $escapedStartScript = ([string]$config.start_script).Replace('"','""')
    $escapedConfigPath = $configPath.Replace('"','""')
    @"
@echo off
start "" /min powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$escapedStartScript" -ConfigPath "$escapedConfigPath"
"@ | Set-Content -LiteralPath $startupPath -Encoding ASCII
}

if (-not $DoNotStart) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $config.start_script -ConfigPath $configPath
    if ($LASTEXITCODE -ne 0) { throw "Remote connector startup failed with exit code $LASTEXITCODE." }
}

[pscustomobject]@{
    Status = 'configured'
    PublicUrl = $normalizedUrl
    RequestHeaderName = 'Authorization'
    RequestHeaderValue = 'Bearer ' + $accessToken
    ConfigPath = $configPath
    StartsAtSignIn = (-not $SkipStartupRegistration)
    AdvancedControlEnabled = [bool]$AllowAdvancedControl
}
