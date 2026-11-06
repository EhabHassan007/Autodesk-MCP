[CmdletBinding()]
param(
    # Sync is the Skills Sync button: upload and download now. Configure saves the Skills Sync settings and the
    # weekly reminder; Enable and Disable switch only the reminder. Nothing is scheduled: the reminder appears
    # when Revit, AutoCAD or Smart Connector opens and the last successful sync is more than a week old.
    [ValidateSet('Configure','Enable','Disable','Status','Run','Preview','Sync')][string]$Action = 'Status',
    # The software whose Skills Sync button was pressed; it then downloads only that software's approved skills.
    # Empty: the installed Autodesk products plus General.
    [ValidateSet('', 'Revit', 'AutoCAD', '3dsMax')][string]$Product = '',
    [string]$RepositoryRoot = (Join-Path $env:LOCALAPPDATA 'BIM-CAD-MCP'),
    [string[]]$AdditionalSkillRoots = @(),
    [ValidateSet('', 'On', 'Off')][string]$Reminder = '',
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection')
)
$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path $StateRoot 'settings.json'
$logPath = Join-Path $StateRoot 'weekly.log'
$resultPath = Join-Path $StateRoot 'last-result.json'
# Days since 1970-01-01 (UTC) of the last successful sync; the Revit add-in and the AutoCAD panel read it too.
$lastSyncPath = Join-Path $StateRoot 'last-sync.txt'

function Write-SkillSettings {
    param([bool]$ReminderOn)
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $settings = [ordered]@{
        repository_root=$RepositoryRoot; repository_url='https://github.com/EhabHassan007/Autodesk-MCP.git'
        reviewer='EhabHassan007'; additional_skill_roots=@($AdditionalSkillRoots); enabled=$ReminderOn
    }
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

function Write-LastSyncDay {
    param([datetime]$When = [DateTime]::UtcNow)
    $days = ($When.ToUniversalTime() - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalDays
    [IO.File]::WriteAllText($lastSyncPath, $days.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
}

$saved = $null
if (Test-Path $settingsPath) { try { $saved = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch { } }
if ($Action -in @('Configure','Enable','Disable')) {
    if ($Action -eq 'Configure' -and -not (Test-Path (Join-Path $RepositoryRoot '.agents\skills'))) { throw 'Install Smart Connector before setting up Skills Sync.' }
    if ($Action -ne 'Configure' -and $saved) {
        if ($saved.repository_root) { $RepositoryRoot = [string]$saved.repository_root }
        if (-not $AdditionalSkillRoots.Count) { $AdditionalSkillRoots = @($saved.additional_skill_roots) }
    }
    $on = switch ($Action) { 'Enable' { $true } 'Disable' { $false } default { if ($Reminder) { $Reminder -eq 'On' } elseif ($saved) { $saved.enabled -ne $false } else { $true } } }
    Write-SkillSettings -ReminderOn $on
    # A PC updated from an earlier version keeps its last sync date, so it is not reminded straight away.
    if (-not (Test-Path -LiteralPath $lastSyncPath) -and (Test-Path -LiteralPath $resultPath)) {
        try {
            $last = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            if ($last.sync_status -in @('ok','partial') -and $last.completed_at) { Write-LastSyncDay ([DateTime]::Parse([string]$last.completed_at)) }
        }
        catch { }
    }
    Write-Output $(if ($on) { 'Skills Sync reminder is on: you are reminded when your last sync is more than a week old.' } else { 'Skills Sync reminder is off. Use Skills Sync whenever you like.' })
    exit 0
}
if ($Action -eq 'Status') {
    if (Test-Path $resultPath) { Get-Content $resultPath -Raw }
    else { Write-Output 'No Skills Sync has completed yet.' }
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
        $RepositoryRoot = [string]$config.repository_root
        $AdditionalSkillRoots = @($config.additional_skill_roots)
    }
    if (-not (Test-Path (Join-Path $RepositoryRoot '.agents\skills'))) { throw 'The installed connector skill library is missing.' }
    # This copy of the helpers can lose a file (an interrupted update, antivirus). Restore it from the installed
    # connector instead of failing, so Skills Sync keeps working until the next Install / Repair.
    $installedScripts = Join-Path $RepositoryRoot 'scripts'
    if ([IO.Path]::GetFullPath($PSScriptRoot) -ne [IO.Path]::GetFullPath($installedScripts)) {
        foreach ($name in @('collect-skills-for-review.ps1','submit-team-knowledge.ps1','central-skill-sync.ps1','send-usage.ps1','SkillLibrary.ps1')) {
            $here = Join-Path $PSScriptRoot $name
            $source = Join-Path $installedScripts $name
            if (-not (Test-Path -LiteralPath $here -PathType Leaf)) {
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "A Skills Sync file is missing: $name. Run the installer again and choose Install / Repair." }
                Copy-Item -LiteralPath $source -Destination $here -Force
                [IO.File]::AppendAllText($logPath, "[$(Get-Date -Format o)] Restored missing $name from the installed connector.`r`n")
            }
        }
    }
    # Usage is reported first and independently, so a failed skill submission never holds it back.
    $usageSender = Join-Path $PSScriptRoot 'send-usage.ps1'
    if ($Action -in @('Run','Sync') -and (Test-Path -LiteralPath $usageSender)) {
        try { $null = & $usageSender -Action Run -StateRoot $StateRoot 2>$null } catch { }
    }
    $central=Join-Path $PSScriptRoot 'central-skill-sync.ps1'
    . (Join-Path $PSScriptRoot 'SkillLibrary.ps1')
    $categories = @(Get-SyncCategories -Product $Product)
    # Collect lines as they arrive so the summary survives even when the sync then fails.
    $output = New-Object System.Collections.Generic.List[string]
    $output.Add('Downloading approved skills in: ' + ($categories -join ', '))
    $failure = $null
    try { & $central -RepositoryRoot $RepositoryRoot -StateRoot $StateRoot -AdditionalSkillRoots $AdditionalSkillRoots -Categories $categories -Preview:($Action -eq 'Preview') 3>&1 | ForEach-Object { $output.Add($_.ToString()) } }
    catch { $failure = $_.Exception.Message }
    $text = ($output + @($(if ($failure) { "FAILED: $failure" }))) -join [Environment]::NewLine
    [IO.File]::AppendAllText($logPath, "[$(Get-Date -Format o)] $Action`r`n$text`r`n")
    $result = [ordered]@{completed_at=(Get-Date -Format o);action=$Action;product=$Product;status=$(if ($failure) { 'failed' } else { 'completed' });details=$text}
    $summaryLine = $output | Where-Object { $_.StartsWith('[SYNC_RESULT] ') } | Select-Object -Last 1
    if ($summaryLine) {
        $summary = $summaryLine.Substring(14) | ConvertFrom-Json
        foreach ($property in $summary.PSObject.Properties) { $result['sync_' + $property.Name] = $property.Value }
    }
    # The Skills Sync window shows sync_reason; without it, it can only guess at the internet connection.
    if ($failure -and -not $result['sync_reason']) { $result['sync_status'] = 'failed'; $result['sync_reason'] = 'Skills Sync stopped: ' + $failure }
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 5))
    if ($Action -in @('Run','Sync') -and -not $failure -and [string]$result['sync_status'] -in @('ok','partial')) { Write-LastSyncDay }
    Write-Output $text
    if ($failure) { exit 1 }
}
catch {
    $message = $_.Exception.Message
    [IO.File]::AppendAllText($logPath, "[$(Get-Date -Format o)] FAILED: $message`r`n")
    [IO.File]::WriteAllText($resultPath, (@{completed_at=(Get-Date -Format o);action=$Action;status='failed';details=$message;sync_status='failed';sync_reason=('Skills Sync stopped: ' + $message)}|ConvertTo-Json))
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
