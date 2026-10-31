$ErrorActionPreference='Stop'
# AutoCAD Add-ins panel: bundle manifest, CUIX parts and their IDs, LISP commands, the built .cuix,
# the installer step and the ConnectorActions outcomes. No AutoCAD needed.
$t=Join-Path ([IO.Path]::GetTempPath()) ('autocad-bundle-'+[guid]::NewGuid().ToString('N'))
$savedLocal=$env:LOCALAPPDATA
$runtime=Join-Path $PSScriptRoot '../source/runtime'
$bundle=Join-Path $runtime 'src/autocad/SmartAutodeskConnector.bundle'
$cuixSource=Join-Path $bundle 'Contents/cuix-source'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Read-Xml([string]$Path){ $x=New-Object Xml.XmlDocument; $x.Load((Resolve-Path -LiteralPath $Path).Path); $x }
New-Item -ItemType Directory $t|Out-Null
$env:LOCALAPPDATA=Join-Path $t 'local'; New-Item -ItemType Directory $env:LOCALAPPDATA|Out-Null
try{
 # 1. PackageContents.xml: valid, AutoCAD 2019+ Win64, the .cuix and the LISP file loaded per document.
 $package=Read-Xml (Join-Path $bundle 'PackageContents.xml')
 Assert ($package.ApplicationPackage.AutodeskProduct -eq 'AutoCAD') 'Bundle is not for AutoCAD'
 $requirements=$package.SelectSingleNode('//Components/RuntimeRequirements')
 Assert ($requirements.SeriesMin -eq 'R23.0' -and $requirements.OS -eq 'Win64') 'Bundle must target R23.0+ Win64'
 $entries=@($package.SelectNodes('//ComponentEntry'))
 $cuixEntry=$entries|Where-Object{$_.ModuleName -eq './Contents/SmartAutodeskConnector.cuix'}
 $lspEntry=$entries|Where-Object{$_.ModuleName -eq './Contents/SmartAutodeskConnector.lsp'}
 Assert ($null -ne $cuixEntry) 'PackageContents does not load the .cuix'
 # Loading at startup raised a SECURELOAD prompt for every drawing and AutoCAD looked hung; the LISP is demand-loaded.
 Assert ($lspEntry -and $lspEntry.LoadOnCommandInvocation -eq 'True') 'LISP is not demand-loaded on command invocation'
 Assert (-not $package.SelectSingleNode('//ComponentEntry[@LoadOnAutoCADStartup="True"]')) 'Something of ours still loads when AutoCAD starts'
 $declared=@($lspEntry.SelectNodes('Commands/Command')|ForEach-Object{$_.Global})
 Assert (($declared -join ',') -eq 'SACSKILLSSYNC,SACCHECKUPDATES,SACSETTINGS,SACSTATUS') "Demand-load command list wrong: $($declared -join ',')"
 'PASS: PackageContents.xml'

 # 2. CUIX parts: every part is XML, every macro and panel the ribbon references exists, the Add-ins alias is set.
 foreach($part in '[Content_Types].xml','_rels/.rels','Header.cui','MenuGroup.cui','RibbonRoot.cui'){ $null=Read-Xml (Join-Path $cuixSource $part) }
 $menu=Read-Xml (Join-Path $cuixSource 'MenuGroup.cui')
 $ribbon=Read-Xml (Join-Path $cuixSource 'RibbonRoot.cui')
 $macros=@{}; foreach($m in $menu.SelectNodes('//MenuMacro')){ $macros[$m.UID]=$m }
 Assert ($macros.Count -eq 4) "Expected 4 menu macros, found $($macros.Count)"
 $buttons=@($ribbon.SelectNodes('//RibbonCommandButton'))
 Assert ($buttons.Count -eq 4) "Expected 4 ribbon buttons, found $($buttons.Count)"
 foreach($b in $buttons){
  Assert ($macros.ContainsKey($b.MenuMacroID)) "Ribbon button $($b.UID) references missing macro $($b.MenuMacroID)"
  Assert ($b.ButtonStyle -eq 'LargeWithText') "Ribbon button $($b.UID) is not a large button"
 }
 $panels=@($ribbon.SelectNodes('//RibbonPanelSource')|ForEach-Object{$_.UID})
 foreach($ref in $ribbon.SelectNodes('//RibbonPanelSourceReference')){ Assert ($panels -contains $ref.PanelId) "Tab references missing panel $($ref.PanelId)" }
 Assert ($ribbon.SelectSingleNode('//RibbonPanelSource').Text -eq 'Smart Autodesk Connector') 'Panel title wrong'
 Assert ($ribbon.SelectSingleNode('//RibbonTabSource/Alias').InnerText -eq 'ID_ADDINSTAB') 'Panel is not placed on the Add-ins tab (ID_ADDINSTAB)'
 $uids=@($menu.SelectNodes('//*[@UID]')+$ribbon.SelectNodes('//*[@UID]')|ForEach-Object{$_.UID})
 Assert (@($uids|Select-Object -Unique).Count -eq $uids.Count) 'Duplicate UID in the CUIX parts'
 $rels=(Get-Content -LiteralPath (Join-Path $cuixSource '_rels/.rels') -Raw)
 foreach($image in $menu.SelectNodes('//SmallImage|//LargeImage')){
  Assert (Test-Path -LiteralPath (Join-Path $runtime "assets/$($image.Name)")) "Button icon $($image.Name) is missing from assets"
  Assert ($rels.Contains('Target="/'+$image.Name+'"')) "Button icon $($image.Name) is not in _rels/.rels"
 }
 'PASS: CUIX parts, macro IDs, panel reference and ID_ADDINSTAB'

 # 3. LISP: balanced, defines the four commands, and every macro runs one of them.
 $lisp=Get-Content -LiteralPath (Join-Path $bundle 'Contents/SmartAutodeskConnector.lsp') -Raw
 $code=($lisp -split "`n"|ForEach-Object{ ($_ -replace '"(?:[^"\\]|\\.)*"','""') -replace ';.*$','' }) -join "`n"
 Assert (($code.ToCharArray()|Where-Object{$_ -eq '('}).Count -eq ($code.ToCharArray()|Where-Object{$_ -eq ')'}).Count) 'LISP parentheses are unbalanced'
 foreach($command in 'SACSKILLSSYNC','SACCHECKUPDATES','SACSETTINGS','SACSTATUS'){
  Assert ($lisp -match "\(defun c:$command\s*\(\)") "LISP does not define $command"
  Assert (@($menu.SelectNodes('//MenuMacro/Macro/Command')|Where-Object{$_.InnerText -eq "^C^C_$command"}).Count -eq 1) "No macro runs $command"
 }
 foreach($script in 'ConnectorActions.ps1','Settings.ps1'){ Assert ($lisp.Contains('"'+$script+'"')) "LISP does not start $script"; Assert (Test-Path -LiteralPath (Join-Path $runtime "installer/$script")) "installer/$script is missing" }
 Assert ($lisp.Contains('-STA -WindowStyle Hidden')) 'LISP does not start PowerShell hidden in STA mode'
 'PASS: LISP commands'

 # 4. Installer: builds the .cuix with the expected parts and copies the bundle without its source folder.
 . (Join-Path $runtime 'installer/Setup-BimCad.ps1') -LibraryOnly
 function Write-Step {param($Message)}
 $plugins=Join-Path $t 'ApplicationPlugins'
 # A throwaway registry tree shaped like HKCU\Software\Autodesk\AutoCAD: one profile already trusting a folder,
 # one with no trusted paths, a current profile AutoCAD has not written Variables for, and a product with no profiles.
 $registry='HKCU:\Software\SmartAutodeskConnectorTest-'+[guid]::NewGuid().ToString('N')
 $profiles="$registry\R25.0\ACAD-8101:409\Profiles"
 $profileA="$profiles\<<Unnamed Profile>>\Variables"
 $profileB="$profiles\Second\Variables"
 New-Item -Path $profileA -Force|Out-Null; New-Item -Path $profileB -Force|Out-Null; New-Item -Path "$registry\R24.3\ACAD-7101:409" -Force|Out-Null
 Set-ItemProperty -LiteralPath $profileA -Name TRUSTEDPATHS -Value 'C:\Existing'
 $profilesC="$registry\R26.0\ACAD-9101:409\Profiles"
 New-Item -Path "$profilesC\Office" -Force|Out-Null; Set-Item -LiteralPath $profilesC -Value 'Office'
 $registryTest=$registry
 Install-AutoCadBundle -Root (Resolve-Path $runtime).Path -PluginsRoot $plugins -RegistryRoot $registry
 $installed=Join-Path $plugins 'SmartAutodeskConnector.bundle'
 foreach($file in 'PackageContents.xml','Contents/SmartAutodeskConnector.lsp','Contents/SmartAutodeskConnector.cuix'){ Assert (Test-Path -LiteralPath (Join-Path $installed $file)) "Installed bundle lacks $file" }
 Assert (-not (Test-Path -LiteralPath (Join-Path $installed 'Contents/cuix-source'))) 'CUIX source parts were copied into the installed bundle'
 Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
 $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $installed 'Contents/SmartAutodeskConnector.cuix'))
 try{ $names=@($zip.Entries|ForEach-Object{$_.FullName}) } finally { $zip.Dispose() }
 foreach($name in '[Content_Types].xml','_rels/.rels','Header.cui','MenuGroup.cui','RibbonRoot.cui'){ Assert ($names -contains $name) "Built .cuix lacks $name" }
 foreach($image in $menu.SelectNodes('//SmallImage|//LargeImage')){ Assert ($names -contains $image.Name) "Built .cuix lacks $($image.Name)" }
 $contents=Join-Path $installed 'Contents'
 Assert ((Get-ItemProperty -LiteralPath $profileA).TRUSTEDPATHS -eq "C:\Existing;$contents") 'Existing trusted path not kept, or bundle folder not added'
 Assert ((Get-ItemProperty -LiteralPath $profileB).TRUSTEDPATHS -eq $contents) 'Bundle folder not trusted in a profile without trusted paths'
 Install-AutoCadBundle -Root (Resolve-Path $runtime).Path -PluginsRoot $plugins -RegistryRoot $registry   # a reinstall replaces the files in place
 Assert ((Get-ItemProperty -LiteralPath $profileA).TRUSTEDPATHS -eq "C:\Existing;$contents") 'Reinstall added the bundle folder twice'
 Assert ((Add-AutoCadTrustedPath -Path $contents -RegistryRoot $registry) -eq 0) 'Already-trusted profiles were rewritten'
 Assert ((Get-ItemProperty -LiteralPath "$profilesC\Office\Variables").TRUSTEDPATHS -eq $contents) 'Current profile without a Variables key was not trusted'
 Uninstall-AutoCadBundle -PluginsRoot $plugins -RegistryRoot $registry
 Assert (-not (Test-Path -LiteralPath $installed)) 'Uninstall left the bundle folder'
 Assert ((Get-ItemProperty -LiteralPath $profileA).TRUSTEDPATHS -eq 'C:\Existing') 'Uninstall did not restore the other trusted paths exactly'
 Assert ((Get-ItemProperty -LiteralPath $profileB).TRUSTEDPATHS -eq '') 'Uninstall left the bundle folder trusted'
 Install-AutoCadBundle -Root (Resolve-Path $runtime).Path -PluginsRoot $plugins -RegistryRoot $registry
 function Get-AutoCadReleases { @() }
 $out=Install-AutoCadBundleStep (Resolve-Path $runtime).Path 6>&1|Out-String
 Assert ($out -match '\[PHASE\] autocad' -and $out -match '\[RESULT\] autocad=skipped') "No AutoCAD should skip the step: $out"
 function Get-AutoCadReleases { @('R25.0') }
 function Install-AutoCadBundle { throw 'locked' }
 $out=Install-AutoCadBundleStep (Resolve-Path $runtime).Path 6>&1 3>$null|Out-String
 Assert ($out -match '\[RESULT\] autocad=failed') "A failed panel install was not reported: $out"
 'PASS: installer builds the .cuix and reports the autocad step'

 # 5. ConnectorActions outcomes (the windows themselves need a desktop and are checked live).
 . (Join-Path $runtime 'installer/ConnectorActions.ps1') -LibraryOnly
 Assert ((Get-SkillsSyncOutcome 'A collection run is already active.').Title -eq 'Skills Sync is already running') 'Active sync not recognised'
 $result=Join-Path $t 'last-result.json'
 @{sync_status='ok';sync_submitted=1;sync_added=2;sync_updated=0;sync_preserved=0;sync_approved_total=30}|ConvertTo-Json|Set-Content $result
 $o=Get-SkillsSyncOutcome 'done' $result
 Assert ($o.Kind -eq 'Good' -and $o.Body -match 'Sent for review:  1 saved skill\n' -and $o.Body -match 'available:  30') "Sync counts wrong: $($o.Body)"
 @{sync_status='failed';sync_reason='No network.'}|ConvertTo-Json|Set-Content $result
 $o=Get-SkillsSyncOutcome '' $result; Assert ($o.Kind -eq 'Bad' -and $o.Body -eq 'No network.') 'Sync failure reason not shown'
 $state=Join-Path $t 'update-state.json'
 @{installed_version='1.0.0-beta.18';available_version='1.0.0-beta.19';notifications_user_disabled=$true}|ConvertTo-Json|Set-Content $state
 $o=Get-CheckUpdatesOutcome '[10:00:00] [UPDATE_AVAILABLE] Version 1.0.0-beta.19 is available.' $state
 Assert ($o.State -eq 'Available' -and $o.Title -match 'beta\.19' -and $o.UserOff) 'Available update not recognised'
 Assert ((Get-CheckUpdatesOutcome '[UP_TO_DATE] ok' $state).State -eq 'Current') 'Up to date not recognised'
 Assert ((Get-CheckUpdatesOutcome 'error' $state).State -eq 'Unknown') 'Failed check not recognised'
 function Start-ConnectorAgent {}
 Request-ConnectorUpdate
 Assert (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'AutodeskMcpConnector/update-requested.flag')) 'Update now did not write update-requested.flag'
 # Live AutoCAD 2025 run: the installer also echoes raw `codex mcp get` output, which must not reach the window.
 $o=Get-ConnectionStatusOutcome "Smart Autodesk Connector - Status`n[10:00:00] AutoCAD installation detected: R25.0`n[10:00:01] Live AutoCAD connection passed: version 25.0; a.dwg; 3 layer(s).`nautodesk`n  enabled: true`n  transport: stdio`n[10:00:02] Codex has the Smart Autodesk Connector registration." $true
 Assert ($o.Kind -eq 'Good' -and $o.Body -match 'Codex has' -and $o.Body -match 'agent is running' -and $o.Body -notmatch '\[10:') "Status lines wrong: $($o.Body)"
 Assert ($o.Body -notmatch 'transport|enabled|- Status' -and @($o.Body -split "`n").Count -eq 4) "Raw command output leaked into Status: $($o.Body)"
 Assert ((Get-ConnectionStatusOutcome '[10:00:00] AutoCAD is running, but no drawing is open.' $false).Title -eq 'Open a drawing to connect') 'No-drawing state not recognised'
 Assert ((Get-ConnectionStatusOutcome '' $false).Kind -eq 'Bad') 'Unreachable AutoCAD not reported'
 'PASS: ConnectorActions outcomes'
}
finally{
 $env:LOCALAPPDATA=$savedLocal
 Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
 if ($registryTest) { Remove-Item -LiteralPath $registryTest -Recurse -Force -ErrorAction SilentlyContinue }
}
'PASS: AutoCAD Add-ins bundle'
