# Autodesk MCP Connector 1.0.0-beta.8 testing

This package is a Windows test build for the unified AutoCAD and Revit connector.

## Before testing

- Extract the complete ZIP before running it.
- Confirm the extracted share folder root contains `INSTALL Autodesk MCP Connector.cmd`, `README-FIRST.txt`, and the `Support` folder.
- Install and sign in to Codex, Claude Code, or Claude Desktop. Testing more than one client is recommended but not required.
- Use Revit 2024 and/or a full Windows AutoCAD installation.
- Use a blank or disposable drawing/model for write tests. Do not use client files.

## Install

1. Double-click `INSTALL Autodesk MCP Connector.cmd`.
2. Wait for the installation-completed message. If setup fails, read `%LOCALAPPDATA%\AutodeskMcpConnector\setup.log`.
3. Restart every installed AI client and any running Revit session.

Initial installation uses the extracted package and does not require repository access.

If setup cannot find its payload, extract `Autodesk-MCP-Connector-<version>.zip` completely, keep the root items together, and start `INSTALL Autodesk MCP Connector.cmd` again.

## Verify

1. Open Revit 2024 with a test project.
2. Open the **Autodesk MCP Connector** ribbon tab and select **Connection Status**.
3. Select **Check Updates** in the Revit ribbon and confirm the setup app opens directly with the approved update status. Do not install an update during a model operation.
4. In the setup app, select **Test connection**.
5. If testing AutoCAD, open a blank drawing before selecting **Test connection**.
6. Confirm that each installed AI client exposes one connector named `autodesk` with the expected AutoCAD and Revit tools.
7. For Claude Code, confirm the shared skills appear under `~/.claude/skills` and run one relevant skill.
8. If Codex and Claude are both installed, verify that both can read status. Do model-changing tests one at a time and confirm a concurrent write waits or returns the connector's busy message.

Automatic updates and the **Update** button require ordinary HTTPS access to the public release repository. They must work on a computer without Git and without a GitHub sign-in. The updater must reject a ZIP whose SHA-256 or internal `VERSION` differs from `latest.json`. When automatic updates are enabled, the scheduled check installs only the approved public release and shows a restart confirmation after success.

For an update regression test, install an older package, create harmless marker files under local `skill-review`, `team-candidates`, and `backups`, publish the newer test release, then select **Update**. The managed runtime must change to the manifest version and all three local folders must remain present.

## Report

Report the version, Revit/AutoCAD year, installation result, connection result, and any exact error message. Do not send drawings, models, credentials, client names, or project paths.
