Smart Connector for Autodesk Revit and AutoCAD 1.0.0

Easiest: run the Smart-Connector-Setup .exe your administrator shared. With this ZIP instead: extract it completely, save your work, close Revit and AutoCAD, and run INSTALL Smart Connector.cmd. Then restart Revit, AutoCAD and your AI clients.

During setup you choose which AI apps to connect (Claude Desktop, Claude Code, Codex) and which Autodesk software to set up (Revit 2024, AutoCAD). Updates and Repair keep your choices.

After setup, open Smart Connector from the Start menu, from its icon in the notification area, or with Open Connector in Revit and AutoCAD. It shows whether everything is connected and has Skills Sync, updates, settings, diagnostics and help in one place.

Updates install automatically: the connector checks when you sign in to Windows, every 6 hours, and when you open Revit or AutoCAD, and installs a new version as soon as Revit and AutoCAD are closed.

With the team installer, setup asks for your name and email and joins this PC to the team skill service automatically. Otherwise your administrator supplies enrollment.json (or skill-service-device.json) beside the installer for this PC/user; setup imports and encrypts it and removes that plaintext file after import. No GitHub account, Git installation or Git author commands are needed on team PCs.

What is reported to your administrator once this PC has joined: your name and email, the PC name and Windows user, the IP address the service sees, when the PC last connected, the connector version, which connector skills and tools are used (names and daily counts only, never drawings, models, file paths or what you type), and the skills submitted for review. The administrator can see this on a private dashboard and can block a PC.

Weekly skill submissions and approved skill downloads run in the background. You approve candidates through draft GitHub pull requests. Local skill edits are preserved. Shared guidance is also available to Claude through the Autodesk MCP workflow tools.

Without administrator enrollment, the connector can run but central skill sharing remains pending. Settings > Sharing service status and Open weekly skill log show the current state. Do not distribute any enrollment file publicly or reuse it across the team.
