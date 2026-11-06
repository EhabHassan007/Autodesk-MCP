Smart Connector for Autodesk Revit and AutoCAD 1.1.0

Lean core: Smart Connector now runs nothing in the background. This removes the behaviour that antivirus programs such as Kaspersky treat as a PowerShell "agent", and it gives IT a much smaller footprint to approve.

- No scheduled tasks and no notification-area agent. Updating from 1.0.0 or an earlier beta removes the four tasks earlier versions created (connector agent, usage report, weekly Skills Sync, update alerts) and the agent's restart copy. The running agent exits after the update.
- Update checks happen when you open Revit, AutoCAD or Smart Connector, at most once a day: one small download of the public latest.json. You are asked "Update now" or "Later". Update now opens a visible update window, which waits for Revit and AutoCAD to close and then installs. Nothing installs without your choice.
- Weekly Skills Sync reminder: on team computers, when the last successful sync is more than a week old, Revit, AutoCAD and the Smart Connector app remind you once a day. Switch it off in Settings.
- Usage counts for the administrator's dashboard are sent only when you run Skills Sync, never on a schedule. Setup no longer starts a hidden Skills Sync after installing.
- Removed: the optional Claude remote gateway (a local web server published to the internet through a Cloudflare tunnel). On PCs that used it, the update stops it, removes its start-up entry and deletes its stored credentials. Administrators should also revoke those tunnels in Cloudflare. Claude Desktop, Claude Code and Codex on the same PC work as before.
- In AutoCAD the daily check starts with the first Smart Connector button you use in a session. Loading anything at AutoCAD startup made AutoCAD ask SECURELOAD for every drawing, so that is avoided.
- The Revit add-in is now compiled in the automated tests with the same Windows compiler the PCs use, against the Revit 2024 API reference assemblies.

SHA-256: 8048D18CE5B639F3ED4D74A376BBCFDEC7DF7BC0425EB41C99950BE1A3B98EE8
