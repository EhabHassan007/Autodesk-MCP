[CmdletBinding()]
param(
    # Sync is the on-demand Skills Sync button: upload and download now, even if the weekly run is off.
    [ValidateSet('Enable','Disable','Status','Run','Preview','Sync')][string]$Action = 'Status',
    [string]$RepositoryRoot = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),
    [string[]]$AdditionalSkillRoots = @(),
    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')][string]$Day = 'Friday',
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')][string]$Time = '16:30',
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection')
)
$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path $StateRoot 'settings.json'
$logPath = Join-Path $StateRoot 'weekly.log'
$resultPath = Join-Path $StateRoot 'last-result.json'
if ($Action -in @('Enable','Disable','Status')) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $taskName = 'Autodesk MCP Weekly Skills - ' + $identity.User.Value
}

if ($Action -eq 'Enable') {
    if (-not (Test-Path (Join-Path $RepositoryRoot '.agents\skills'))) { throw 'Install Smart Autodesk Connector before enabling skill collection.' }

    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $installRoot = Join-Path $StateRoot 'scripts'
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    foreach ($name in @('weekly-skill-collection.ps1','collect-skills-for-review.ps1','submit-team-knowledge.ps1','central-skill-sync.ps1','Initialize-SkillService.ps1','send-usage.ps1','connector-agent.ps1','SkillLibrary.ps1')) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $installRoot $name
        if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($destination)) { Copy-Item -LiteralPath $source -Destination $destination -Force }
    }
    $settings = [ordered]@{
        repository_root=$RepositoryRoot; repository_url='https://github.com/EhabHassan007/Autodesk-MCP.git'
        reviewer='EhabHassan007'; additional_skill_roots=@($AdditionalSkillRoots)
        day=$Day; time=$Time; task_name=$taskName; enabled=$true
    }
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runner = Join-Path $installRoot 'weekly-skill-collection.ps1'
    foreach ($path in @($runner,$StateRoot)) { if ($path.Contains('"')) { throw 'Unsupported quote in installation path.' } }
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action Run -StateRoot "{1}"' -f $runner,$StateRoot
    $taskAction = New-ScheduledTaskAction -Execute $engine -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $Day -At ([datetime]::ParseExact($Time,'HH:mm',[Globalization.CultureInfo]::InvariantCulture))
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $taskSettings -Description 'Submit saved skill changes as draft GitHub pull requests for owner review. Never merges or publishes.' -Force | Out-Null
    Write-Output "Enabled: $Day at $Time (this PC's local time), while this user is signed in. Missed runs are eligible to catch up."
    Write-Output "Administrator device enrollment is required. Team GitHub accounts are not needed. Log: $logPath"
    exit 0
}
if ($Action -eq 'Disable') {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    if (Test-Path $settingsPath) {
        $saved = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $saved | Add-Member -NotePropertyName enabled -NotePropertyValue $false -Force
        [IO.File]::WriteAllText($settingsPath, ($saved | ConvertTo-Json -Depth 5))
    }
    Write-Output 'Weekly collection disabled. Local review history retained.'
    exit 0
}
if ($Action -eq 'Status') {
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Select-Object TaskName,State
    if (Test-Path $resultPath) { Get-Content $resultPath -Raw }
    else { Write-Output 'No collection run has completed yet.' }
    Write-Output "Log: $logPath"
    exit 0
}
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
$lock = $null
try {
    try { $lock = [IO.File]::Open((Join-Path $StateRoot 'run.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] { Write-Output 'A collection run is already active.'; exit 0 }
    if (Test-Path $settingsPath) {
        $config = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($Action -eq 'Run' -and $config.enabled -eq $false) { Write-Output 'Weekly collection is disabled.'; exit 0 }
        $RepositoryRoot = [string]$config.repository_root
        $AdditionalSkillRoots = @($config.additional_skill_roots)
    }
    if (-not (Test-Path (Join-Path $RepositoryRoot '.agents\skills'))) { throw 'The installed connector skill library is missing.' }
    # Usage is reported first and independently, so a failed skill submission never holds it back.
    $usageSender = Join-Path $PSScriptRoot 'send-usage.ps1'
    if ($Action -in @('Run','Sync') -and (Test-Path -LiteralPath $usageSender)) {
        try { $null = & $usageSender -Action Run -StateRoot $StateRoot 2>$null } catch { }
    }
    $central=Join-Path $PSScriptRoot 'central-skill-sync.ps1'
    # Collect lines as they arrive so the summary survives even when the sync then fails.
    $output = New-Object System.Collections.Generic.List[string]
    $failure = $null
    try { & $central -RepositoryRoot $RepositoryRoot -StateRoot $StateRoot -AdditionalSkillRoots $AdditionalSkillRoots -Preview:($Action -eq 'Preview') 3>&1 | ForEach-Object { $output.Add($_.ToString()) } }
    catch { $failure = $_.Exception.Message }
    $text = ($output + @($(if ($failure) { "FAILED: $failure" }))) -join [Environment]::NewLine
    [IO.File]::AppendAllText($logPath, "[$(Get-Date -Format o)] $Action`r`n$text`r`n")
    $result = [ordered]@{completed_at=(Get-Date -Format o);action=$Action;status=$(if ($failure) { 'failed' } else { 'completed' });details=$text}
    $summaryLine = $output | Where-Object { $_.StartsWith('[SYNC_RESULT] ') } | Select-Object -Last 1
    if ($summaryLine) {
        $summary = $summaryLine.Substring(14) | ConvertFrom-Json
        foreach ($property in $summary.PSObject.Properties) { $result['sync_' + $property.Name] = $property.Value }
    }
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 5))
    Write-Output $text
    if ($failure) { exit 1 }
}
catch {
    $message = $_.Exception.Message
    [IO.File]::AppendAllText($logPath, "[$(Get-Date -Format o)] FAILED: $message`r`n")
    [IO.File]::WriteAllText($resultPath, (@{completed_at=(Get-Date -Format o);action=$Action;status='failed';details=$message}|ConvertTo-Json))
    Write-Error $message -ErrorAction Continue
    exit 1
}
finally {
    if (Test-Path $logPath) {
        $lines = @(Get-Content $logPath)
        if ($lines.Count -gt 1000) { $lines[-1000..-1] | Set-Content $logPath -Encoding UTF8 }
    }
    if ($lock) { $lock.Dispose() }
}
