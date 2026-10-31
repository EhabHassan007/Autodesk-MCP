[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Label,

    [string]$OutputDirectory = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Autodesk-MCP-Enrollments'),

    [string]$ServiceUrl = 'https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev',

    # Prompted for (hidden) when omitted. Never pass it as plain text on a command line.
    [Security.SecureString]$AdminToken
)
# Creates one enrollment.json per PC/user for setup to import. Tokens are written only into
# those files, which are restricted to the current Windows user, and are never printed.
$ErrorActionPreference = 'Stop'

$uri = [Uri]$ServiceUrl
if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw 'The service URL must be HTTPS without credentials, query or fragment.'
}
$base = $uri.AbsoluteUri.TrimEnd('/')

$labels = @($Label | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $labels.Count) { throw 'Give at least one PC label, for example -Label Office-PC-01.' }
$seen = @{}
foreach ($name in $labels) {
    # Labels become folder names, so keep them to safe characters.
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
        throw "Invalid label '$name'. Use letters, digits, dot, dash or underscore (max 80)."
    }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { throw "Duplicate label '$name'." }
    $seen[$name.ToLowerInvariant()] = $true
    if (Test-Path -LiteralPath (Join-Path (Join-Path $OutputDirectory $name) 'enrollment.json')) {
        throw "An enrollment file for '$name' already exists. Deliver or delete it first; each file is single-use."
    }
}

function Protect-Directory {
    param([string]$Path)

    # Only the current user can read the tokens: drop inherited access and grant this user alone.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Protect-Directory $OutputDirectory

if (-not $AdminToken) { $AdminToken = Read-Host -AsSecureString 'Paste ADMIN_TOKEN (input hidden), then press Enter' }
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminToken)
$headers = @{ 'User-Agent' = 'Autodesk-MCP-Connector/1.0.0-beta.17' }
$created = New-Object System.Collections.Generic.List[object]
try {
    $headers.Authorization = 'Bearer ' + [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    foreach ($name in $labels) {
        try {
            $device = Invoke-RestMethod -Uri ($base + '/admin/devices') -Method Post -Headers $headers `
                -ContentType 'application/json' -Body (@{ label = $name } | ConvertTo-Json) -TimeoutSec 60
        }
        catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $hint = if ($code -eq 403) { ' The admin token does not match ADMIN_TOKEN in Cloudflare.' } else { '' }
            throw ("The service refused '{0}' (HTTP {1}).{2} Enrollments created before this one are kept." -f $name, $code, $hint)
        }
        if ([string]$device.device_token -notmatch '^[A-Za-z0-9_-]{40,100}$' -or [string]$device.device_id -notmatch '^[a-f0-9]{32}$') {
            throw "The service returned an unexpected enrollment for '$name'."
        }
        $folder = Join-Path $OutputDirectory $name
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $json = @{ service_url = $base; device_id = [string]$device.device_id; device_token = [string]$device.device_token } | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $folder 'enrollment.json'), $json, (New-Object Text.UTF8Encoding($false)))
        $json = $null
        $created.Add([pscustomobject]@{ label = $name; device_id = [string]$device.device_id; created_utc = (Get-Date).ToUniversalTime().ToString('o') })
        $device = $null
        Write-Host ("Created {0}  device {1}" -f $name, $created[-1].device_id)
    }
}
finally {
    $headers.Authorization = $null
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    # The register holds no tokens; keep it to revoke a lost or retired PC later.
    if ($created.Count) {
        $register = Join-Path $OutputDirectory 'devices.csv'
        $created | Export-Csv -LiteralPath $register -NoTypeInformation -Append -Encoding UTF8
    }
}

Write-Host ''
Write-Host ("{0} enrollment file(s) in {1}" -f $created.Count, $OutputDirectory)
Write-Host 'For each PC: copy <label>\enrollment.json beside "INSTALL Smart Autodesk Connector.cmd" and run setup as that PC''s user.'
Write-Host 'Setup imports it and deletes it. Deliver files privately and never reuse one on a second PC.'
