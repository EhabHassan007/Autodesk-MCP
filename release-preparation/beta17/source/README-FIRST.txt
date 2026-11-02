Smart Autodesk Connector 1.0.0-beta.20 — central-service pilot

This installer is for a pilot after your administrator deploys the central skill service.
Extract the ZIP completely. Save work and close Revit. Run INSTALL Smart Autodesk Connector.cmd, then restart Revit and AI clients.

With the team installer, setup asks for your name and email and joins this PC to the team skill service automatically. Otherwise your administrator supplies enrollment.json (or skill-service-device.json) beside the installer for this PC/user; setup imports and encrypts it and removes that plaintext file after import. No GitHub account, Git installation or Git author commands are needed on team PCs.

What is reported to your administrator once this PC has joined: your name and email, the PC name and Windows user, the IP address the service sees, when the PC last connected, the connector version, which connector skills and tools are used (names and daily counts only, never drawings, models, file paths or what you type), and the skills submitted for review. The administrator can see this on a private dashboard and can block a PC.

Weekly skill submissions and approved skill downloads run in the background. You approve candidates through draft GitHub pull requests. Local skill edits are preserved. Shared guidance is also available to Claude through the Autodesk MCP workflow tools.

Without administrator enrollment, the connector can run but central skill sharing remains pending. Settings > Sharing service status and Open weekly skill log show the current state. Do not distribute any enrollment file publicly or reuse it across the team.
