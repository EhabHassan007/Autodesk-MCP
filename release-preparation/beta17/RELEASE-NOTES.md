Smart Connector for Autodesk Revit and AutoCAD 1.0.0

First full release. Installed PCs on any beta update to it automatically.

- New name: Smart Connector (in full, Smart Connector for Autodesk Revit and AutoCAD). On update, Claude Desktop's old "Smart Autodesk Connector" entry is replaced by "Smart Connector"; Revit shows a Smart Connector tab and AutoCAD a Smart Connector panel. Your settings, skills and team registration are unchanged.
- New logo: the S drawn as one clean line, with blue CAD grip squares at its ends, in flat brand colours that stay sharp down to 16 px. Used for the app icon, setup, the notification area and the Revit and AutoCAD buttons.
- Setup file: Smart-Connector-Setup-1.0.0.exe installs for the signed-in Windows user without administrator rights. The team version asks for name and email and joins the PC to the team skill service.
- Automatic updates: the connector checks when Windows starts, every 6 hours, and whenever Revit or AutoCAD is opened, and installs a new version as soon as Revit and AutoCAD are closed. A notification offers "Update now".
- AI Markup in AutoCAD: two new buttons on the Add-ins tab. AI Markup lets you sketch on the drawing, type what Claude should do, and copies the request with the sketch as coordinates; paste it into Claude. Clear Markup removes it. Commands AI and AICLEAR; the markup layer does not plot.
- AutoCAD stays responsive in long sessions: drawing reads are bounded and the connector releases its references to AutoCAD objects after every call.
- Skills Sync: restores its own missing helper files, shows the real reason when it fails, and holds back only a skill that has two different saved copies on the PC, naming both locations.
- Skills grouped by software category; Skills Sync buttons in Revit and on the AutoCAD Add-ins tab; setup continues past a failed step and replaces the old flat skill library on upgrade.
- Your own skill edits, team registration and update preferences are kept on update.

SHA-256: 5052ECCA11D83E7B84309741849DF1D00ED6137DFEB78DDDA63AE01203D99E6A
