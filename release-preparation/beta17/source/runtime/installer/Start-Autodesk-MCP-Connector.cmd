@echo off
setlocal
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0SmartConnectorApp.ps1"
endlocal
