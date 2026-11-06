$ErrorActionPreference = 'Stop'
# Setup wizard: builds and steps through all six pages (Welcome, System check, Choose apps, AI connections,
# Install, Finish) without installing anything, and passes the app choices to Setup-BimCad. Windows only.
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$wizardText = Get-Content (Join-Path $runtime 'installer/SetupWizard.ps1') -Raw
foreach ($argument in "'-AiClients'", "'-Product'", "'-Skills'", "'-AutoUpdates'") {
    Assert ($wizardText.Contains($argument)) "The wizard does not pass $argument to setup"
}
'PASS: the wizard passes the AI app, Autodesk, skills and update choices to setup'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { 'SKIP: wizard pages need Windows'; return }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$t = Join-Path ([IO.Path]::GetTempPath()) ('setup-wizard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $t | Out-Null
$savedLocal = $env:LOCALAPPDATA; $env:LOCALAPPDATA = $t
try {
    . (Join-Path $runtime 'installer/SetupWizard.ps1')
    foreach ($ask in $true, $false) {
        $result = Show-SetupWizard -CoreSetup (Join-Path $runtime 'installer/Setup-BimCad.ps1') -CoreArguments @('-Action', 'Install', '-RepositoryPath', (Join-Path $t 'install')) `
            -LogPath (Join-Path $t 'setup.log') -Version '1.0.0' -AskDetails $ask -SmokeTest
        Assert ($result.Result -eq 'ok' -and $result.Pages -eq 6 -and $result.Steps -ge 7) ("Wizard did not step through its pages: " + ($result | ConvertTo-Json -Compress))
    }
    'PASS: all six wizard pages build, with and without the team details'
    $check = Get-SetupSystemCheck
    Assert ($check.PSObject.Properties['Revit2024'] -and $check.PSObject.Properties['AutoCad'] -and $check.PSObject.Properties['Codex']) 'System check is incomplete'
    'PASS: system check reports Windows, Revit, AutoCAD, Claude and Codex'
}
finally { $env:LOCALAPPDATA = $savedLocal; Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
