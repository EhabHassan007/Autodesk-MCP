# Autodesk MCP Connector 1.0.0-beta.1 testing

This package is a Windows test build for the unified AutoCAD and Revit connector.

## Before testing

- Extract the complete ZIP before running it.
- Install Codex and sign in.
- Use Revit 2024 and/or a full Windows AutoCAD installation.
- Use a blank or disposable drawing/model for write tests. Do not use client files.

## Install

1. Double-click `installer\Start-Autodesk-MCP-Connector.cmd`.
2. Select **Install / Repair**.
3. Restart Codex and any running Revit session.

Initial installation uses the extracted package and does not require repository access.

## Verify

1. Open Revit 2024 with a test project.
2. Open the **Autodesk MCP Connector** ribbon tab and select **Connection Status**.
3. In the setup app, select **Test connection**.
4. If testing AutoCAD, open a blank drawing before selecting **Test connection**.
5. Confirm that Codex exposes one connector named `autodesk` with the expected AutoCAD and Revit tools.

Automatic update alerts and the **Update** button require access to the private approved repository. Testers without repository access can still install and test this packaged version.

## Report

Report the version, Revit/AutoCAD year, installation result, connection result, and any exact error message. Do not send drawings, models, credentials, client names, or project paths.
