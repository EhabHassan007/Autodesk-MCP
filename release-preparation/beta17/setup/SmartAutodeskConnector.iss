; Smart Connector setup .exe (Inno Setup 6). Compiled by build.ps1; do not compile by hand.
; The .exe only carries the connector payload and its install script. It unpacks them into
; %LOCALAPPDATA%\SmartConnectorSetup, shows the connector's own setup window, waits for it and removes the folder. Updates still arrive
; automatically through latest.json and the release ZIP.
#ifndef AppVersion
  #error Define AppVersion, NumericVersion, PayloadZip, InstallScript and IconFile (build.ps1 does this).
#endif

[Setup]
AppId={{6B1E3C1A-5D2F-4F0B-9A47-3C8E2D7A9B10}
AppName=Smart Connector
AppVersion={#AppVersion}
AppPublisher=Smart Connector
VersionInfoVersion={#NumericVersion}
VersionInfoProductName=Smart Connector
VersionInfoDescription=Smart Connector for Autodesk Revit and AutoCAD setup
SetupIconFile={#IconFile}
; Installs for the signed-in Windows user only, like the ZIP installer: no administrator rights needed.
PrivilegesRequired=lowest
CreateAppDir=no
Uninstallable=no
DisableWelcomePage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
ShowLanguageDialog=no
Compression=lzma2/max
SolidCompression=yes

[Files]
; Unpacked into one fixed folder, not %TEMP%, so a single antivirus exclusion covers setup. Removed afterwards.
Source: "{#InstallScript}"; DestDir: "{localappdata}\SmartConnectorSetup"; Flags: ignoreversion
Source: "{#PayloadZip}"; DestDir: "{localappdata}\SmartConnectorSetup"; DestName: "Autodesk-MCP-Payload.zip"; Flags: ignoreversion

[Code]
function InitializeSetup(): Boolean;
begin
  Result := IsWin64;
  if not Result then
    MsgBox('Smart Connector needs 64-bit Windows.', mbError, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Folder, PowerShell, Parameters: String;
begin
  if CurStep <> ssPostInstall then
    exit;
  Folder := ExpandConstant('{localappdata}\SmartConnectorSetup');
  { Setup is a 32-bit program; Sysnative reaches the 64-bit PowerShell that Revit and AutoCAD detection need. }
  PowerShell := ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + Folder + '\Install-Autodesk-MCP-Connector.ps1" -Install';
  { The connector's own setup window takes over; Inno Setup's window steps aside. }
  WizardForm.Hide;
  if not Exec(PowerShell, Parameters, Folder, SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    MsgBox('Smart Connector setup could not start Windows PowerShell (' + SysErrorMessage(ResultCode) + ').', mbError, MB_OK);
  DelTree(Folder, True, True, True);
end;
