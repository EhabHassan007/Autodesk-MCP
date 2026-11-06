; Smart Autodesk Connector setup .exe (Inno Setup 6). Compiled by build.ps1; do not compile by hand.
; The .exe only carries the connector payload and its install script. When opened it shows the connector's
; own setup window and waits for it; Inno Setup's own wizard pages never appear. Updates still arrive
; automatically through latest.json and the release ZIP.
#ifndef AppVersion
  #error Define AppVersion, NumericVersion, PayloadZip, InstallScript and IconFile (build.ps1 does this).
#endif

[Setup]
AppId={{6B1E3C1A-5D2F-4F0B-9A47-3C8E2D7A9B10}
AppName=Smart Autodesk Connector
AppVersion={#AppVersion}
AppPublisher=Smart Autodesk Connector
VersionInfoVersion={#NumericVersion}
VersionInfoProductName=Smart Autodesk Connector
VersionInfoDescription=Smart Autodesk Connector setup
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
Source: "{#InstallScript}"; DestDir: "{tmp}"; Flags: dontcopy
Source: "{#PayloadZip}"; DestDir: "{tmp}"; DestName: "Autodesk-MCP-Payload.zip"; Flags: dontcopy

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
  PowerShell, Parameters: String;
begin
  Result := False;
  if not IsWin64 then
  begin
    MsgBox('Smart Autodesk Connector needs 64-bit Windows.', mbError, MB_OK);
    exit;
  end;
  ExtractTemporaryFile('Install-Autodesk-MCP-Connector.ps1');
  ExtractTemporaryFile('Autodesk-MCP-Payload.zip');
  { Setup is a 32-bit program; Sysnative reaches the 64-bit PowerShell that Revit and AutoCAD detection need. }
  PowerShell := ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' +
    ExpandConstant('{tmp}\Install-Autodesk-MCP-Connector.ps1') + '" -Install';
  if not Exec(PowerShell, Parameters, ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    MsgBox('Smart Autodesk Connector setup could not start Windows PowerShell (' + SysErrorMessage(ResultCode) + ').', mbError, MB_OK);
  { The connector's setup window has finished; leave without showing Inno Setup's own pages. }
end;
