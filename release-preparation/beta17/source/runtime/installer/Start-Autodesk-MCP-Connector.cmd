@echo off
setlocal
rem The compiled Smart Connector program when it is installed (..\bin\SmartConnector.exe); otherwise the PowerShell window.
if not exist "%~dp0..\bin\SmartConnector.exe" goto powershell
start "" "%~dp0..\bin\SmartConnector.exe" app
goto done
:powershell
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0SmartConnectorApp.ps1"
:done
endlocal
