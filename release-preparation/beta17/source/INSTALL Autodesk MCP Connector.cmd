@echo off
setlocal
title Autodesk MCP Connector Setup
echo Starting Autodesk MCP Connector setup...
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Support\Install-Autodesk-MCP-Connector.ps1" -Install %*
if errorlevel 1 (
    echo.
    echo Setup stopped. See %%LOCALAPPDATA%%\AutodeskMcpConnector\setup.log
    pause
)
endlocal
