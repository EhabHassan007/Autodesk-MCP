# Automatic skill sharing through the central service

## Smart Autodesk Connector at a glance

- **Revit ribbon tab "Smart Autodesk Connector":**
  - **Connection Status:** is Codex or Claude connected to this Revit session?
  - **Check Updates:** look for a newer approved version. **Update now** installs it as soon as Revit and AutoCAD are closed.
  - **Skills Sync:** send your saved skills for review and download the latest approved team skills now, even if the weekly run is off.
  - **Settings:** the one switch, "Install updates automatically".
- **Notification-area icon (the "S" logo next to the clock):** this is the connector agent. It starts at sign-in and checks for updates at start and every 6 hours.
  - When Revit or AutoCAD opens while an update is ready, it shows a Windows notification. Click it for **Update now** or **Later**.
  - With automatic updates on (the default), a ready update installs by itself once Revit and AutoCAD are closed, followed by an "Updated to version X" notice.
  - Its menu offers Check for updates, Skills Sync, Settings, Open log and Quit. The log is `%LOCALAPPDATA%\AutodeskMcpConnector\agent.log`.
- **Updates never replace files while Revit or AutoCAD is open.** The update waits and reports `[UPDATE_DEFERRED]` instead.

Once IT enrolls this PC/user during the single connector setup, the weekly background task collects saved skills, submits candidates to the central service and downloads approved skills. Default schedule: Friday 16:30 local time while signed in. Existing disabled preferences and custom schedules are preserved.

No team GitHub account, Git installation, Git author commands or manual skill upload is needed for this central workflow. Shared guidance is exposed through MCP tools. It does not create native Claude Skills UI entries.

The administrator must deploy the service and install its GitHub App. See CENTRAL-SERVICE-DEPLOYMENT.md. The service creates draft PRs and never merges or publishes automatically. Owner merge into main makes a skill eligible for the next successful device sync.

Settings provides Preview saved skills, Submit skills for review now, Sharing service status and the weekly log. Submission and scheduled runs happen in the background. Credentials are stored encrypted for the enrolled Windows user. Existing local skill edits are preserved when approved updates are downloaded.

Discovery covers Codex skills, .agents/skills, Claude Code skills and explicit team-candidates. Additional project skill folders must be configured by the administrator. Cloud chats and native Claude cloud skill uploads are not scanned.

## Team installer and usage reporting

The private team installer (`build.ps1 -Team`) asks each person for their name, email and consent, then joins the PC to the service by itself. An administrator's `enrollment.json` beside the installer still takes priority. The join code is removed from the permanent install after setup.

Once enrolled, the connector records which workflow skills (each `SKILL.md` read) and which AutoCAD/Revit tools are used, as names and daily counts in `%LOCALAPPDATA%\AutodeskMcpSkillCollection\usage.jsonl`. It never records arguments, drawings, models or file paths. A per-user task sends the counts at sign-in and daily at 12:00, and the weekly run sends them too. Unsent counts wait in `usage-pending.jsonl`. Results are in `usage-upload.log`. The administrator sees them, with name, email, PC, IP and last seen, on the service's `/admin` dashboard.

To keep a personal skill off the review queue, add its folder name on its own line to `%LOCALAPPDATA%\AutodeskMcpSkillCollection\excluded-skills.txt`. Lines starting with `#` are comments. Excluded skills are not copied into review packages, not listed in REVIEW.md and never submitted.
