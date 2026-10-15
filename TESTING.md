# Autodesk MCP Connector 1.0.0-beta.5 testing

This package is a Windows test build for the unified AutoCAD and Revit connector.

## Before testing

- Extract the complete ZIP before running it.
- Confirm the extracted share folder contains exactly four visible files and keep them together.
- Install and sign in to Codex, Claude Code, or Claude Desktop. Testing more than one client is recommended but not required.
- Use Revit 2024 and/or a full Windows AutoCAD installation.
- Use a blank or disposable drawing/model for write tests. Do not use client files.

## Install

1. Double-click `Start-Autodesk-MCP-Connector.cmd`.
2. Select **Install / Repair**.
3. Restart every installed AI client and any running Revit session.

Initial installation uses the extracted package and does not require repository access.

## Verify

1. Open Revit 2024 with a test project.
2. Open the **Autodesk MCP Connector** ribbon tab and select **Connection Status**.
3. Select **Check Updates** in the Revit ribbon and confirm the setup app opens directly with the approved update status. Do not install an update during a model operation.
4. In the setup app, select **Test connection**.
5. If testing AutoCAD, open a blank drawing before selecting **Test connection**.
6. Confirm that each installed AI client exposes one connector named `autodesk` with the expected AutoCAD and Revit tools.
7. For Claude Code, confirm the shared skills appear under `~/.claude/skills` and run one relevant skill.
8. If Codex and Claude are both installed, verify that both can read status. Do model-changing tests one at a time and confirm a concurrent write waits or returns the connector's busy message.

Automatic updates and the **Update** button require access to the private approved repository. Testers without repository access can still install and test this packaged version. When automatic updates are enabled, the scheduled check installs only the approved `main` version and shows a restart confirmation after success.

For an update regression test, select **Install / Repair** from the shared beta package over an older installed version, then select **Update**. The managed installation must refresh from the approved `main` branch without reporting that local changes would be overwritten. Local `skill-review`, `team-candidates`, and `backups` folders must remain present.

## Report

Report the version, Revit/AutoCAD year, installation result, connection result, and any exact error message. Do not send drawings, models, credentials, client names, or project paths.
