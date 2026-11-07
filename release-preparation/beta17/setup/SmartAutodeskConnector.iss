; Smart Connector setup .exe (Inno Setup 6). Compiled by build.ps1; do not compile by hand.
; The .exe only installs files: the connector into %LOCALAPPDATA%\BIM-CAD-MCP and a Start menu entry. It runs no
; script. The first time Smart Connector is opened from the Start menu, it shows the setup window (which AI apps and
; Autodesk programs to connect, team details) and finishes setup. Updates arrive through latest.json and the release ZIP.
#ifndef AppVersion
  #error Define AppVersion, NumericVersion, PayloadDir, InstallScript and IconFile (build.ps1 does this).
#endif
#define InstallRoot "{localappdata}\BIM-CAD-MCP"

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
DisableFinishedPage=no
ShowLanguageDialog=no
Compression=lzma2/max
SolidCompression=yes
; An AI app may be running bin\SmartConnector.exe, which locks the file. Setup offers to close it; the AI app starts
; it again when it next opens, so setup does not restart it itself.
CloseApplications=yes
RestartApplications=no

[Messages]
FinishedHeadingLabel=Smart Connector is installed
FinishedLabelNoIcons=To finish, open Smart Connector from the Start menu. It asks which AI apps (Claude, Codex) and which Autodesk programs (Revit, AutoCAD) to connect.
FinishedLabel=To finish, open Smart Connector from the Start menu. It asks which AI apps (Claude, Codex) and which Autodesk programs (Revit, AutoCAD) to connect.

[InstallDelete]
; The shipped skill library is replaced, not merged: older versions kept skills flat, and merging would leave every
; skill twice. Approved team skills live elsewhere and are kept.
Type: filesandordirs; Name: "{#InstallRoot}\.agents\skills"
; The unpack folder used by setup 1.0.0 and 1.1.0.
Type: filesandordirs; Name: "{localappdata}\SmartConnectorSetup"

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{#InstallRoot}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#InstallScript}"; DestDir: "{#InstallRoot}\setup"; Flags: ignoreversion
; An administrator's enrollment file beside this setup .exe; setup imports it, encrypts it and deletes the copy.
Source: "{src}\enrollment.json"; DestDir: "{#InstallRoot}"; Flags: external skipifsourcedoesntexist ignoreversion
Source: "{src}\skill-service-device.json"; DestDir: "{#InstallRoot}"; Flags: external skipifsourcedoesntexist ignoreversion

[Icons]
; The compiled Smart Connector program this setup installed (bin\SmartConnector.exe, always in this payload): the
; shortcut runs no script. On the first open it shows the setup window.
Name: "{userprograms}\Smart Connector"; Filename: "{#InstallRoot}\bin\SmartConnector.exe"; Parameters: "app"; \
  WorkingDir: "{localappdata}"; IconFilename: "{#InstallRoot}\assets\logo.ico"; \
  Comment: "Smart Connector for Autodesk Revit and AutoCAD"

[Code]
function InitializeSetup(): Boolean;
begin
  Result := IsWin64;
  if not Result then
    MsgBox('Smart Connector needs 64-bit Windows.', mbError, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then
    exit;
  { Smart Connector reads this on its first open and shows the setup window; setup removes it when done. }
  SaveStringToFile(ExpandConstant('{#InstallRoot}\setup\setup-pending.txt'),
    'Open Smart Connector from the Start menu to finish setup.', False);
end;
