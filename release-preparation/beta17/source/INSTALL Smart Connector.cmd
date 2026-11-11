@echo off
rem Opens the Smart Connector setup window. A minimised PowerShell window sits on the taskbar until setup finishes.
rem It is deliberately not hidden: hidden-window PowerShell launches are what antivirus heuristics flag most often, and the
rem window closes by itself. Progress and any errors are shown in the setup window and in
rem %LOCALAPPDATA%\AutodeskMcpConnector\setup.log
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Support\Install-Autodesk-MCP-Connector.ps1" -Install %*
