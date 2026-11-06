[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))
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
    if($code -ne 0){throw "Task configuration failed (exit $code). Open Settings to retry."}
}
# Refresh installed collection helpers even when the user has disabled scheduling.
try {
    $stateRoot=Join-Path $env:LOCALAPPDATA 'AutodeskMcpSkillCollection'
    $settingsPath=Join-Path $stateRoot 'settings.json'
    $installedScripts=Join-Path $stateRoot 'scripts'
    New-Item -ItemType Directory -Path $installedScripts -Force|Out-Null
    # Each file is copied on its own: one file in use (the running connector agent) must not leave the rest
    # out of date or missing. Skills Sync also restores a missing helper from the installed connector.
    $notCopied=@()
    foreach($name in @('SkillLibrary.ps1','weekly-skill-collection.ps1','collect-skills-for-review.ps1','submit-team-knowledge.ps1','central-skill-sync.ps1','Initialize-SkillService.ps1','send-usage.ps1','connector-agent.ps1')) {
        try {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $installedScripts $name) -Force -ErrorAction Stop}
        catch {$notCopied+=$name}
    }
    if($notCopied.Count){Write-Warning ('Skill helpers not refreshed (in use): '+($notCopied -join ', ')+'. They are refreshed on the next setup or restored by Skills Sync.')}
    $saved=if(Test-Path $settingsPath){Get-Content $settingsPath -Raw|ConvertFrom-Json}else{$null}
    if($saved -and $saved.enabled -eq $false){Write-Host 'Weekly skills remain disabled in Settings.'}
    else {
        # Invoke within this process to preserve array arguments, including custom skill roots.
        $options=@{Action='Enable';RepositoryRoot=$RepositoryRoot;StateRoot=$stateRoot}
        if($saved){
            $options.Day=[string]$saved.day;$options.Time=[string]$saved.time
            $options.AdditionalSkillRoots=@($saved.additional_skill_roots)
        }
        & (Join-Path $PSScriptRoot 'weekly-skill-collection.ps1') @options
        if($LASTEXITCODE -ne 0){throw 'Weekly task could not be registered.'}
    }
}
catch {Write-Warning ('Weekly skills setup needs attention: '+$_.Exception.Message)}
# Usage reporting only sends once the PC is enrolled; the task is harmless before that.
try {& (Join-Path $installedScripts 'send-usage.ps1') -Action Register -StateRoot $stateRoot}
catch {Write-Warning ('Usage reporting setup needs attention: '+$_.Exception.Message)}
# The agent shows update notices, installs updates when Revit and AutoCAD are closed, and offers Skills Sync.
try {& (Join-Path $installedScripts 'connector-agent.ps1') -Action Register -StateRoot $stateRoot -InstallRoot $RepositoryRoot}
catch {Write-Warning ('Connector agent setup needs attention: '+$_.Exception.Message)}
try {
    $updateState=Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector\update-state.json'
    $saved=if(Test-Path $updateState){Get-Content $updateState -Raw|ConvertFrom-Json}else{$null}
    # Only the person's own choice in Settings keeps updates off. Earlier versions could save "off"
    # on a fresh install by mistake; those PCs are switched back on here.
    if($saved -and $saved.PSObject.Properties['notifications_user_disabled'] -and $saved.notifications_user_disabled){
        Write-Host 'Automatic updates remain disabled in Settings.'
    }
    else {
        Invoke-TaskSetup -Script (Join-Path $RepositoryRoot 'installer\Setup-BimCad.ps1') -ScriptArguments @('-Action','EnableNotifications','-RepositoryPath',$RepositoryRoot)
    }
}
catch {Write-Warning ('Automatic updates need attention: '+$_.Exception.Message)}
