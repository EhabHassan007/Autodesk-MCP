[CmdletBinding()]
param(
    [ValidateSet('Run','Register','Unregister')][string]$Action = 'Run',
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'),
    [switch]$LibraryOnly
)
# Sends the per-day skill and tool counts recorded by the connector (names only) to the
# team skill service, for the administrator's dashboard. Unsent counts are kept and retried.
$ErrorActionPreference = 'Stop'
$usagePath = Join-Path $StateRoot 'usage.jsonl'
$pendingPath = Join-Path $StateRoot 'usage-pending.jsonl'
$logPath = Join-Path $StateRoot 'usage-upload.log'

function Write-UsageLog {
    param([string]$Message)
    try {
        [IO.File]::AppendAllText($logPath, "[$(Get-Date -Format o)] $Message`r`n")
        $lines = @(Get-Content -LiteralPath $logPath)
        if ($lines.Count -gt 200) { $lines[-200..-1] | Set-Content -LiteralPath $logPath -Encoding UTF8 }
    }
    catch { }
}

function Read-UsageLines {
    param([string[]]$Paths)
    # Aggregates by kind/name/day. Lines from the bridge have no count (one use each).
    $totals = [ordered]@{}
    $oldest = (Get-Date).AddDays(-55).ToString('yyyy-MM-dd')
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $e = $line | ConvertFrom-Json } catch { continue }
            $kind = [string]$e.kind; $name = [string]$e.name; $day = [string]$e.day
            # The service accepts the last 60 days only; older or malformed lines are dropped.
            if ($kind -notin @('skill','tool') -or $name -notmatch '^[A-Za-z0-9_.:-]{1,100}$' -or $day -notmatch '^\d{4}-\d{2}-\d{2}$' -or $day -lt $oldest) { continue }
            $count = if ($e.PSObject.Properties['count']) { [int]$e.count } else { 1 }
            if ($count -lt 1) { continue }
            $key = "$kind|$name|$day"
            $totals[$key] = [Math]::Min(10000, $(if ($totals.Contains($key)) { $totals[$key] } else { 0 }) + $count)
        }
    }
    foreach ($key in $totals.Keys) {
        $kind, $name, $day = $key -split '\|', 3
        [pscustomobject]@{ kind = $kind; name = $name; day = $day; count = [int]$totals[$key] }
    }
}

function Save-Pending {
    param([object[]]$Events)
    if (-not $Events -or -not $Events.Count) {
        if (Test-Path -LiteralPath $pendingPath) { Remove-Item -LiteralPath $pendingPath -Force }
        return
    }
    $temp = $pendingPath + '.tmp'
    [IO.File]::WriteAllLines($temp, [string[]]@($Events | ForEach-Object { $_ | ConvertTo-Json -Compress }), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $pendingPath -Force
}

function Get-DeviceRequest {
    $config = Get-Content -LiteralPath (Join-Path $StateRoot 'service.json') -Raw | ConvertFrom-Json
    $uri = [Uri]$config.service_url
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Invalid skill service URL.' }
    $version = 'unknown'
    $settings = Join-Path $StateRoot 'settings.json'
    if (Test-Path -LiteralPath $settings) {
        $versionPath = Join-Path ([string](Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).repository_root) 'VERSION'
        if (Test-Path -LiteralPath $versionPath) { $version = (Get-Content -LiteralPath $versionPath -Raw).Trim() }
    }
    $secure = ConvertTo-SecureString ([string]$config.protected_token)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    @{ Uri = $uri.AbsoluteUri.TrimEnd('/') + '/v1/usage'
       UserAgent = "Autodesk-MCP-Connector/$version"
       Headers = @{ Authorization = 'Bearer ' + $token; 'X-Connector-Version' = $version } }
}

function Send-Usage {
    if (-not (Test-Path -LiteralPath (Join-Path $StateRoot 'service.json') -PathType Leaf)) { return 'This PC is not enrolled; usage is not reported.' }
    # Move the live file aside first so new uses keep appending to a fresh usage.jsonl.
    $taking = $null
    if (Test-Path -LiteralPath $usagePath -PathType Leaf) {
        $taking = Join-Path $StateRoot ("usage-taking-{0}.jsonl" -f [guid]::NewGuid().ToString('N'))
        try { Move-Item -LiteralPath $usagePath -Destination $taking }
        catch { $taking = $null }
    }
    $leftovers = @(Get-ChildItem -LiteralPath $StateRoot -Filter 'usage-taking-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $events = @(Read-UsageLines -Paths (@($pendingPath) + $leftovers))
    Save-Pending $events
    foreach ($file in $leftovers) { Remove-Item -LiteralPath $file -Force }
    if (-not $events.Count) { return 'No new usage to report.' }

    $request = Get-DeviceRequest
    $sent = 0
    try {
        while ($events.Count) {
            $batch = @($events | Select-Object -First 500)
            $body = @{ events = $batch } | ConvertTo-Json -Depth 4 -Compress
            $null = Invoke-RestMethod -Uri $request.Uri -Method Post -Headers $request.Headers -UserAgent $request.UserAgent -ContentType 'application/json; charset=utf-8' `
                -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
            $sent += $batch.Count
            # Shrink the pending file after each accepted batch, so a later failure never resends it.
            $events = @($events | Select-Object -Skip $batch.Count)
            Save-Pending $events
        }
    }
    finally { $request.Headers.Authorization = $null }
    "Reported $sent usage record(s)."
}

function Register-UsageTask {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $taskName = 'Autodesk MCP Usage Report - ' + $identity.User.Value
    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runner = Join-Path $StateRoot 'scripts\send-usage.ps1'
    foreach ($path in @($runner, $StateRoot)) { if ($path.Contains('"')) { throw 'Unsupported quote in installation path.' } }
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action Run -StateRoot "{1}"' -f $runner, $StateRoot
    $taskAction = New-ScheduledTaskAction -Execute $engine -Argument $arguments
    $triggers = @((New-ScheduledTaskTrigger -AtLogOn -User $identity.Name), (New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact('12:00','HH:mm',[Globalization.CultureInfo]::InvariantCulture))))
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $triggers -Principal $principal -Settings $settings `
        -Description 'Report which Autodesk MCP Connector skills and tools were used (names and daily counts only) to the team skill service.' -Force | Out-Null
    "Usage reporting scheduled at sign-in and daily at 12:00: $taskName"
}

if ($LibraryOnly) { return }
try {
    switch ($Action) {
        'Register' { Register-UsageTask }
        'Unregister' {
            $taskName = 'Autodesk MCP Usage Report - ' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
            'Usage reporting task removed.'
        }
        'Run' {
            New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
            $result = Send-Usage
            Write-UsageLog $result
            $result
        }
    }
}
catch {
    $code = if ($_.Exception.Response) { ' (HTTP ' + [int]$_.Exception.Response.StatusCode + ')' } else { '' }
    $message = 'Usage report failed' + $code + '; unsent counts are kept for the next run.'
    Write-UsageLog $message
    Write-Error $message -ErrorAction Continue
    exit 1
}
