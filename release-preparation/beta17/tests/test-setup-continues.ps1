$ErrorActionPreference='Stop'
# A failing install step is reported against that step, and the steps after it still run.
$runtime=Join-Path $PSScriptRoot '../source/runtime'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
. (Join-Path $runtime 'installer/Setup-BimCad.ps1') -LibraryOnly

$ran=New-Object System.Collections.Generic.List[string]
$lines=@(& {
    Invoke-InstallStep 'skills' { $ran.Add('skills'); throw 'Task Scheduler is unavailable' }
    Invoke-InstallStep 'team' { $ran.Add('team'); Write-InstallResult 'team' 'ok' }
    # A step that announces its own phase is blamed for its own failure, not the wrapper's name.
    Invoke-InstallStep 'codex' { Write-InstallPhase 'claude_desktop'; throw 'config is locked' }
} 6>&1 | ForEach-Object { "$_" })
$text=$lines -join "`n"
Assert ($ran -join ',' -eq 'skills,team') "A failed step stopped the later steps: ran $($ran -join ',')"
Assert ($text -match '\[RESULT\] skills=failed') 'Failed step not reported as failed'
Assert ($text -match 'skills failed: Task Scheduler is unavailable') 'Failure reason not written to the log'
Assert ($text -match '\[RESULT\] team=ok') 'Step after a failure did not report its result'
Assert ($text -match '\[RESULT\] claude_desktop=failed' -and $text -notmatch '\[RESULT\] codex=failed') 'Failure not attributed to the running phase'
Assert ((@($script:FailedInstallSteps) -join ',') -eq 'skills,claude_desktop') "Failed steps not recorded: $(@($script:FailedInstallSteps) -join ',')"

# Every install step after the connector files runs through Invoke-InstallStep, and setup still exits with an error.
$setup=Get-Content (Join-Path $runtime 'installer/Setup-BimCad.ps1') -Raw
$install=[regex]::Match($setup,"(?s)'Install' \{(.+?)\r?\n        'Update' \{").Groups[1].Value
foreach($step in 'skills','team','revit','autocad','updates','codex'){
    Assert ($install -match "Invoke-InstallStep '$step'") "Install step '$step' can still stop setup"
}
Assert ($install -match 'FailedInstallSteps\.Count\)\s*\{\s*throw') 'Setup no longer reports failed steps at the end'
"PASS: a failed install step is reported against the running step, logged, and later steps still run; every install step is wrapped; setup still exits with an error when a step failed"
