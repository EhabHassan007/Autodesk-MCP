@echo off
rem Opens the Smart Connector setup window. This console closes straight away;
rem progress and any errors are shown in the setup window and in
rem %LOCALAPPDATA%\AutodeskMcpConnector\setup.log
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Support\Install-Autodesk-MCP-Connector.ps1" -Install %*
