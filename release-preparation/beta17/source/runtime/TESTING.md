# Smart Connector 1.0.0 testing

This package is a Windows test build for the unified AutoCAD and Revit connector.

## Before testing

- Extract the complete ZIP before running it.
- Confirm the extracted share folder root contains `INSTALL Smart Connector.cmd`, `Autodesk MCP Skills for Claude.zip`, `README-FIRST.txt`, and the `Support` folder.
- Install and sign in to Codex. Install / Repair installs Claude Desktop automatically when it is missing; signing in to the user's Claude account remains an account action. Testing more than one client is recommended but not required.
- Use Revit 2024 and/or a full Windows AutoCAD installation.
- Use a blank or disposable drawing/model for write tests. Do not use client files.

## Install

1. Double-click `INSTALL Smart Connector.cmd`.
2. Wait for the installation-completed message. If setup fails, read `%LOCALAPPDATA%\AutodeskMcpConnector\setup.log`.
3. Restart every installed local AI client and any running Revit session. Codex and Claude Code use the local connector. Claude Chat requires the separate authenticated remote setup.

For Claude workflow guidance, open **Customize > Skills**, choose **Upload a skill**, and select `Autodesk MCP Skills for Claude.zip`. Confirm `autodesk-mcp-bim-workflows` is enabled. This skill package is separate from the MCP connection.

Initial installation uses the extracted package and does not require repository access.

If setup cannot find its payload, extract `Autodesk-MCP-Connector-<version>.zip` completely, keep the root items together, and start `INSTALL Smart Connector.cmd` again.

## Verify

1. Open Revit 2024 with a test project.
2. Open the **Autodesk MCP Connector** ribbon tab and select **Connection Status**.
3. Select **Check Updates** in the Revit ribbon and confirm the setup app opens directly with the approved update status. Do not install an update during a model operation.
4. In the setup app, select **Test connection**.
5. If testing AutoCAD, open a blank drawing before selecting **Test connection**.
6. Confirm Codex and Claude Code expose `autodesk`; Claude Desktop exposes **Autodesk MCP Connector**.
7. Verify Claude registration in standard roaming AppData and each detected Claude MSIX package-local roaming directory.
8. Confirm unrelated MCP integrations remain, legacy Autodesk entries are removed, and JSON is UTF-8 without a BOM.
9. For Claude Code, confirm the shared skills appear under `~/.claude/skills` and run one relevant skill.
10. If Codex and Claude are both installed, verify that both can read status. Do model-changing tests one at a time and confirm a concurrent write waits or returns the connector's busy message.

## Verify nothing runs in the background

1. After Install / Repair, Task Scheduler (Task Scheduler Library) has no task starting with `Smart Autodesk Connector Agent`, `Autodesk MCP Usage Report`, `Autodesk MCP Weekly Skills` or `Autodesk MCP Connector Update Alerts`, and Task Manager shows no `powershell.exe` once the setup and Smart Connector windows are closed.
2. On a PC upgraded from 1.0.0 or earlier, the same holds after the update, `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Autodesk MCP Remote Connector.cmd` is gone, and `%LOCALAPPDATA%\AutodeskMcpConnector\remote` is deleted.
3. Delete `%LOCALAPPDATA%\AutodeskMcpConnector\open-check.txt` and open Revit: with a newer public release, Revit asks **Update now** / **Later**. **Update now** opens the update window, which waits for Revit and AutoCAD to close and then installs.
4. On a team PC, delete `%LOCALAPPDATA%\AutodeskMcpSkillCollection\last-sync.txt` and `sync-reminder.txt`, then open Revit (or use a Smart Connector button in AutoCAD): the Skills Sync reminder appears once.

Update checks and the **Update** button require ordinary HTTPS access to the public release repository. They must work on Windows PowerShell when GitHub returns `latest.json` as either text or UTF-8 bytes, without Git and without a GitHub sign-in. The updater must reject a ZIP whose SHA-256 or internal `VERSION` differs from `latest.json`, and it must never replace a newer installed version with an older public release. Update checks only offer a newer approved public release, and nothing is installed until the person chooses **Update now**.

Claude Desktop registration must be written to `%APPDATA%\Claude\claude_desktop_config.json` for both classic and Microsoft Store/MSIX installations. Setup must preserve unrelated MCP registrations, add the **Autodesk MCP Connector** server, and report the exact configuration path. Fully quit and reopen Claude Desktop after Install / Repair; **Autodesk MCP Connector** must appear under the chat `+` menu → Connectors.

Install / Repair must detect Claude package identities that contain `Claude`, remove the known legacy AutoCAD/Revit MCP registrations (including the old `autodesk` display key), write the combined **Autodesk MCP Connector** registration even when AppX enumeration is restricted, and restart a running Claude Desktop process so the connector appears without a manual tray exit.

For an update regression test, install an older package, create harmless marker files under local `skill-review`, `team-candidates`, and `backups`, publish the newer test release, then select **Update**. The managed runtime must change to the manifest version and all three local folders must remain present.

## Revit execute_csharp regression

Use a copy of a workshared Revit 2024 project, or a detached test model. Do not synchronize or save.

1. Call `execute_csharp` in `read` mode with `return doc.Title;`. The error must start with `C# compilation failed:` and name line 1; it must not say the session is not available. `connection_status` must still report the session as connected.
2. Call it in `read` mode with code that throws on line 2 (for example `var e = document.GetElement(ElementId.InvalidElementId);` then `return e.Name;`). The error must read `C# execution failed at mcp_code.cs line 2` with the exception type.
3. Call it in `manual` mode with `allow_model_changes=false` and code that creates a family document from the Metric Structural Column template, adds an extrusion, saves it to `%TEMP%` and closes it. It must succeed, and the project must show no new undo entry.
4. Repeat step 3 with `famDoc.LoadFamily(document)` before closing. It must fail with "The code changed the project document", and the family must not be in the project afterwards.
5. Run the load with `manual` and `allow_model_changes=true`, then place one instance in `transaction` mode and read it back (the custom column workflow in the `revit-family-modelling` skill, steps 7 to 9). Undo or discard the test changes afterwards.

## Report

Report the version, Revit/AutoCAD year, installation result, connection result, and any exact error message. Do not send drawings, models, credentials, client names, or project paths.
