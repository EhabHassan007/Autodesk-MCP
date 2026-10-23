# Autodesk MCP Connector 1.0.0-beta.14 testing

This package is a Windows test build for the unified AutoCAD and Revit connector.

## Before testing

- Extract the complete ZIP before running it.
- Confirm the extracted share folder root contains `INSTALL Autodesk MCP Connector.cmd`, `Autodesk MCP Skills for Claude.zip`, `README-FIRST.txt`, and the `Support` folder.
- Install and sign in to Codex. Install / Repair installs Claude Desktop automatically when it is missing; signing in to the user's Claude account remains an account action. Testing more than one client is recommended but not required.
- Use Revit 2024 and/or a full Windows AutoCAD installation.
- Use a blank or disposable drawing/model for write tests. Do not use client files.

## Install

1. Double-click `INSTALL Autodesk MCP Connector.cmd`.
2. Wait for the installation-completed message. If setup fails, read `%LOCALAPPDATA%\AutodeskMcpConnector\setup.log`.
3. Restart every installed local AI client and any running Revit session. Codex and Claude Code use the local connector. Claude Chat requires the separate authenticated remote setup.

For Claude workflow guidance, open **Customize > Skills**, choose **Upload a skill**, and select `Autodesk MCP Skills for Claude.zip`. Confirm `autodesk-mcp-bim-workflows` is enabled. This skill package is separate from the MCP connection.

Initial installation uses the extracted package and does not require repository access.

If setup cannot find its payload, extract `Autodesk-MCP-Connector-<version>.zip` completely, keep the root items together, and start `INSTALL Autodesk MCP Connector.cmd` again.

## Verify

1. Open Revit 2024 with a test project.
2. Open the **Autodesk MCP Connector** ribbon tab and select **Connection Status**.
3. Select **Check Updates** in the Revit ribbon and confirm the setup app opens directly with the approved update status. Do not install an update during a model operation.
4. In the setup app, select **Test connection**.
5. If testing AutoCAD, open a blank drawing before selecting **Test connection**.
6. Confirm that each installed local AI client exposes one connector named `autodesk` with the expected AutoCAD and Revit tools.
7. On a machine with only a stale `%APPDATA%\Claude\claude_desktop_config.json`, confirm setup does not report Claude Desktop as installed until the application package or executable is present.
8. For a Microsoft Store/MSIX Claude installation, confirm `autodesk` is added to `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json`; this connector's old `autocad`/`revit` entries are removed and unrelated MCP integrations remain.
9. For Claude Code, confirm the shared skills appear under `~/.claude/skills` and run one relevant skill.
10. If Codex and Claude are both installed, verify that both can read status. Do model-changing tests one at a time and confirm a concurrent write waits or returns the connector's busy message.

## Verify Claude remote mode

1. Run `src\autodesk\work\test-http-gateway.ps1`. Confirm authentication and origin checks pass, `execute_csharp` is absent, and the expected read/write tools remain.
2. Assign the workstation a unique Cloudflare named tunnel and HTTPS hostname routed to `http://localhost:8765`.
3. In setup choose **Claude remote** and enter that hostname and the workstation's tunnel token. Never reuse credentials between workstations.
4. Confirm `Get-AutodeskMcpRemoteConnection.ps1` reports both gateway and tunnel running.
5. Add the displayed `/mcp` URL and Authorization header to one Claude custom Web connector. Free accounts may have only one custom connector.
6. From Claude, call `connection_status` and `document_info`. Verify `execute_csharp` is unavailable remotely.
7. Close any Revit modal dialog before testing; a modal dialog prevents Revit's external event queue from processing requests.

Automatic updates and the **Update** button require ordinary HTTPS access to the public release repository. They must work on Windows PowerShell when GitHub returns `latest.json` as either text or UTF-8 bytes, without Git and without a GitHub sign-in. The updater must reject a ZIP whose SHA-256 or internal `VERSION` differs from `latest.json`, and it must never replace a newer installed version with an older public release. When automatic updates are enabled, the scheduled check installs only a newer approved public release and shows a restart confirmation after success.

Claude Desktop registration must be written to `%APPDATA%\Claude\claude_desktop_config.json` for both classic and Microsoft Store/MSIX installations. Setup must preserve unrelated MCP registrations, add the **Autodesk MCP Connector** server, and report the exact configuration path. Fully quit and reopen Claude Desktop after Install / Repair; **Autodesk MCP Connector** must appear under the chat `+` menu → Connectors.

Install / Repair must detect Claude package identities that contain `Claude`, remove the known legacy AutoCAD/Revit MCP registrations (including the old `autodesk` display key), write the combined **Autodesk MCP Connector** registration even when AppX enumeration is restricted, and restart a running Claude Desktop process so the connector appears without a manual tray exit.

For an update regression test, install an older package, create harmless marker files under local `skill-review`, `team-candidates`, and `backups`, publish the newer test release, then select **Update**. The managed runtime must change to the manifest version and all three local folders must remain present.

## Report

Report the version, Revit/AutoCAD year, installation result, connection result, and any exact error message. Do not send drawings, models, credentials, client names, or project paths.
