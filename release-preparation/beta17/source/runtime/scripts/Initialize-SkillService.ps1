[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$data=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$uri=[Uri]([string]$data.service_url)
if($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw 'The skill service must use an HTTPS URL without embedded credentials.'}
if([string]$data.device_token -notmatch '^[A-Za-z0-9_-]{40,100}$'){throw 'Invalid device enrollment token.'}
$root=Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
New-Item -ItemType Directory -Path $root -Force|Out-Null
$secure=ConvertTo-SecureString ([string]$data.device_token) -AsPlainText -Force
$encrypted=ConvertFrom-SecureString $secure
@{service_url=$uri.AbsoluteUri.TrimEnd('/');device_id=[string]$data.device_id;protected_token=$encrypted}|ConvertTo-Json|
    Set-Content -LiteralPath (Join-Path $root 'service.json') -Encoding UTF8
$data.device_token=$null
Write-Output 'Central skill sharing is configured for this Windows user. No GitHub sign-in is needed.'
