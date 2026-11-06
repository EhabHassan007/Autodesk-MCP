Smart Connector for Autodesk Revit and AutoCAD 1.1.0

Easiest: run the Smart-Connector-Setup .exe your administrator shared. It only installs the files and adds Smart Connector to the Start menu; then open Smart Connector from the Start menu to finish setup. With this ZIP instead: extract it completely, save your work, close Revit and AutoCAD, and run INSTALL Smart Connector.cmd. Then restart Revit, AutoCAD and your AI clients.

During setup you choose which AI apps to connect (Claude Desktop, Claude Code, Codex) and which Autodesk software to set up (Revit 2024, AutoCAD). Updates and Repair keep your choices.

After setup, open Smart Connector from the Start menu or with Open Connector in Revit and AutoCAD. It shows whether everything is connected and has Skills Sync, updates, settings, diagnostics and help in one place.

Antivirus: Smart Connector is not code-signed, so Kaspersky and other antivirus programs may block or delete it. Before installing, add these folders to the antivirus exclusions (Kaspersky: Settings > Threats and Exclusions > Manage exclusions); replace <you> with your Windows user name:
  C:\Users\<you>\AppData\Local\BIM-CAD-MCP
  C:\Users\<you>\AppData\Local\AutodeskMcpSkillCollection
  C:\Users\<you>\AppData\Local\AutodeskMcpConnector
  the folder that holds this installer
Run the installer from a company network folder or a synced OneDrive folder, or right-click it > Properties > Unblock, so Windows does not show "Windows protected your PC".

Nothing runs in the background: no scheduled tasks, no notification-area icon, no process left running. Once a day, opening Revit, AutoCAD or Smart Connector looks for a new version and asks you; choose Update now, save your work and close Revit and AutoCAD, and the update window installs it. In AutoCAD the check starts with the first Smart Connector button you use. Setup and updates remove the background tasks earlier versions created.

With the team installer, setup asks for your name and email and joins this PC to the team skill service automatically. Otherwise your administrator supplies enrollment.json (or skill-service-device.json) beside the installer for this PC/user; setup imports and encrypts it and removes that plaintext file after import. No GitHub account, Git installation or Git author commands are needed on team PCs.

What is reported to your administrator once this PC has joined: your name and email, the PC name and Windows user, the IP address the service sees, when the PC last connected, the connector version, which connector skills and tools are used (names and daily counts only, never drawings, models, file paths or what you type), and the skills submitted for review. The administrator can see this on a private dashboard and can block a PC.

Skills Sync sends your saved skills for review and downloads approved skills when you press Skills Sync. On team computers a reminder appears when your last sync is more than a week old (switch it off in Settings). You approve candidates through draft GitHub pull requests. Local skill edits are preserved. Shared guidance is also available to Claude through the Autodesk MCP workflow tools.

Without administrator enrollment, the connector can run but central skill sharing remains pending. Diagnostics in Smart Connector shows the current state and the Skills Sync log. Do not distribute any enrollment file publicly or reuse it across the team.
