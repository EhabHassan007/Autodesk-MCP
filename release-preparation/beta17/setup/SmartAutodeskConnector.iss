; Smart Connector setup .exe (Inno Setup 6). Compiled by build.ps1; do not compile by hand.
; The .exe only installs files: the connector into %LOCALAPPDATA%\BIM-CAD-MCP and a Start menu entry. It runs no
; script. The first time Smart Connector is opened from the Start menu, it shows the setup window (which AI apps and
; Autodesk programs to connect, team details) and finishes setup. Updates arrive through latest.json and the release ZIP.
#ifndef AppVersion
  #error Define AppVersion, NumericVersion, PayloadDir and IconFile (build.ps1 does this).
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
; The Start menu entry has a fixed place; there is nothing to choose.
DisableProgramGroupPage=yes
; Only the progress bar of this .exe shows; the Smart Connector Setup window it opens is the setup the person goes through.
DisableFinishedPage=yes
ShowLanguageDialog=no
Compression=lzma2/max
SolidCompression=yes
; Nothing is closed and nobody is asked to close programs. A running Smart Connector (the MCP server Claude or Codex
; started, which has no window, or an open Smart Connector window) keeps bin\SmartConnector.exe in use; the code below
; moves that file aside instead, and the program deletes the old copy the next time it starts.
CloseApplications=no
RestartApplications=no

[Messages]
FinishedHeadingLabel=Smart Connector is installed
FinishedLabelNoIcons=Smart Connector opens when you click Finish and shows the setup window: the terms of use, which AI apps (Claude, Codex) and Autodesk programs (Revit, AutoCAD) to connect, and joining the team. If you untick it, open Smart Connector from the Start menu to finish.
FinishedLabel=Smart Connector opens when you click Finish and shows the setup window: the terms of use, which AI apps (Claude, Codex) and Autodesk programs (Revit, AutoCAD) to connect, and joining the team. If you untick it, open Smart Connector from the Start menu to finish.

[InstallDelete]
; The shipped skill library is replaced, not merged: older versions kept skills flat, and merging would leave every
; skill twice. Approved team skills live elsewhere and are kept.
Type: filesandordirs; Name: "{#InstallRoot}\.agents\skills"
; The unpack folder used by setup 1.0.0 and 1.1.0.
Type: filesandordirs; Name: "{localappdata}\SmartConnectorSetup"

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{#InstallRoot}"; Flags: ignoreversion recursesubdirs createallsubdirs
; An administrator's enrollment file beside this setup .exe; setup imports it, encrypts it and deletes the copy.
Source: "{src}\enrollment.json"; DestDir: "{#InstallRoot}"; Flags: external skipifsourcedoesntexist ignoreversion
Source: "{src}\skill-service-device.json"; DestDir: "{#InstallRoot}"; Flags: external skipifsourcedoesntexist ignoreversion

[Icons]
; The compiled Smart Connector program this setup installed (bin\SmartConnector.exe, always in this payload): the
; shortcut runs no script. On the first open it shows the setup window.
Name: "{userprograms}\Smart Connector"; Filename: "{#InstallRoot}\bin\SmartConnector.exe"; Parameters: "app"; \
  WorkingDir: "{localappdata}"; IconFilename: "{#InstallRoot}\assets\logo.ico"; \
  Comment: "Smart Connector for Autodesk Revit and AutoCAD"

[Run]
; Once the files are copied, the Smart Connector Setup window opens: the terms of use, the AI apps, the Revit add-in, the
; AutoCAD panel and the team. It is the installed program, not a script, and it does not open in a silent install.
Filename: "{#InstallRoot}\bin\SmartConnector.exe"; Parameters: "app"; WorkingDir: "{localappdata}"; Flags: nowait skipifsilent

[Code]
function InitializeSetup(): Boolean;
begin
  Result := IsWin64;
  if not Result then
    MsgBox('Smart Connector needs 64-bit Windows.', mbError, MB_OK);
end;

{ Windows lets a file that is in use be renamed. The running copy keeps working from the renamed file; the new one is
  installed under the usual name. Smart Connector deletes SmartConnector.exe.old (or .old1 ... .old9) when it starts. }
procedure MoveRunningProgramAside;
var
  ExePath, Target: String;
  I: Integer;
begin
  ExePath := ExpandConstant('{#InstallRoot}\bin\SmartConnector.exe');
  if not FileExists(ExePath) then
    exit;
  for I := 0 to 9 do
  begin
    if I = 0 then
      Target := ExePath + '.old'
    else
      Target := ExePath + '.old' + IntToStr(I);
    if FileExists(Target) then
      DeleteFile(Target);
    if (not FileExists(Target)) and RenameFile(ExePath, Target) then
      exit;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    MoveRunningProgramAside;
    exit;
  end;
  if CurStep <> ssPostInstall then
    exit;
  { Smart Connector reads this on its first open and shows the setup window; setup removes it when done. The folder
    is made here: no file of the payload lives in it any more, so nothing else creates it. }
  ForceDirectories(ExpandConstant('{#InstallRoot}\setup'));
  SaveStringToFile(ExpandConstant('{#InstallRoot}\setup\setup-pending.txt'),
    'Open Smart Connector from the Start menu to finish setup.', False);
end;
