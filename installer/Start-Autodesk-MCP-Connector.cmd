@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0BIM-CAD-Setup.ps1"
endlocal
