[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))
# Runs at Install / Repair and when an earlier version installs this one as an update (its updater runs the new
# sync-codex-skills.ps1, which calls this). Smart Connector registers nothing in the background any more:
# update checks and the weekly Skills Sync reminder happen when Revit, AutoCAD or Smart Connector opens.
# This removes what earlier versions set up, refreshes the Skills Sync helpers and keeps the person's choices.
$ErrorActionPreference='Stop'
$engine=(Get-Process -Id $PID).Path
function Invoke-TaskSetup {
    param([string]$Script,[string[]]$ScriptArguments)
    $previous=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $output=& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ScriptArguments 2>&1
        $code=$LASTEXITCODE
    }
    finally {$ErrorActionPreference=$previous}
    $output | ForEach-Object {Write-Host $_}
    if($code -ne 0){throw "Settings could not be saved (exit $code). Open Settings to retry."}
}
$stateRoot=Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
# Scheduled tasks, the notification-area agent and Claude remote access from earlier versions. The agent is not
# stopped here: when an earlier version updates to this one, its agent is the process running this update.
try {& (Join-Path $PSScriptRoot 'retire-background-tasks.ps1') -StateRoot $stateRoot | ForEach-Object {Write-Host $_}}
catch {Write-Warning ('Earlier background tasks could not be removed: '+$_.Exception.Message)}
try {
    $settingsPath=Join-Path $stateRoot 'settings.json'
    $installedScripts=Join-Path $stateRoot 'scripts'
    New-Item -ItemType Directory -Path $installedScripts -Force|Out-Null
    # Each file is copied on its own: one file in use must not leave the rest out of date or missing.
    # Skills Sync also restores a missing helper from the installed connector.
    $notCopied=@()
    foreach($name in @('SkillLibrary.ps1','weekly-skill-collection.ps1','collect-skills-for-review.ps1','submit-team-knowledge.ps1','central-skill-sync.ps1','Initialize-SkillService.ps1','send-usage.ps1')) {
        try {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $installedScripts $name) -Force -ErrorAction Stop}
        catch {$notCopied+=$name}
    }
    if($notCopied.Count){Write-Warning ('Skill helpers not refreshed (in use): '+($notCopied -join ', ')+'. They are refreshed on the next setup or restored by Skills Sync.')}
    # Skills Sync settings (folders and the weekly reminder), keeping what the person chose before.
    $saved=if(Test-Path $settingsPath){Get-Content $settingsPath -Raw|ConvertFrom-Json}else{$null}
    $options=@{Action='Configure';RepositoryRoot=$RepositoryRoot;StateRoot=$stateRoot}
    if($saved){
        $options.AdditionalSkillRoots=@($saved.additional_skill_roots)
        if($saved.enabled -eq $false){$options.Reminder='Off'}
    }
    & (Join-Path $PSScriptRoot 'weekly-skill-collection.ps1') @options
    if($LASTEXITCODE -ne 0){throw 'Skills Sync settings could not be saved.'}
}
catch {Write-Warning ('Skills Sync setup needs attention: '+$_.Exception.Message)}
try {
    $updateState=Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\update-state.json'
    $saved=if(Test-Path $updateState){Get-Content $updateState -Raw|ConvertFrom-Json}else{$null}
    # Only the person's own choice in Settings keeps update checks off.
    if($saved -and $saved.PSObject.Properties['notifications_user_disabled'] -and $saved.notifications_user_disabled){
        Write-Host 'Update checks remain off in Settings.'
    }
    else {
        Invoke-TaskSetup -Script (Join-Path $RepositoryRoot 'installer\Setup-BimCad.ps1') -ScriptArguments @('-Action','EnableNotifications','-RepositoryPath',$RepositoryRoot)
    }
}
catch {Write-Warning ('Update checks need attention: '+$_.Exception.Message)}
