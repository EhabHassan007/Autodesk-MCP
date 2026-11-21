# Automatic skill sharing through the central service

## Smart Connector at a glance

- **Revit ribbon tab "Smart Connector":**
  - **Connect:** open Smart Connector: connect Revit, AutoCAD, Claude and Codex, and see what is ready.
  - **Status:** is Codex or Claude connected to this Revit session?
  - **Skills Sync:** send your saved skills for review and download the latest approved team skills now.
  - **More** menu:
    - **Check updates:** look for a newer approved version. **Update now** opens the update window, which installs it as soon as Revit and AutoCAD are closed.
    - **Settings:** update checks and the weekly Skills Sync reminder.
    - **Browse Skills**, **Diagnostics** and **Help**.
- **Nothing runs in the background.** There is no scheduled task, no notification-area icon and no process left running. Setup and each update remove what earlier versions scheduled.
- **When Revit, AutoCAD or Smart Connector opens,** at most once a day:
  - it looks for a new version (one small download of the public `latest.json`, in the background) and asks **Update now** or **Later**;
  - on team computers, when the last successful Skills Sync is more than a week old, it reminds you to sync (switch the reminder off in Settings).
  - In AutoCAD this starts with the first Smart Connector button used in a session, because loading anything at AutoCAD startup made AutoCAD ask SECURELOAD for every drawing.
- **Updates never replace files while Revit or AutoCAD is open.** The update window waits for them to close and then installs.

Once IT enrolls this PC/user during the single connector setup, Skills Sync collects saved skills, submits candidates to the central service and downloads approved skills. It runs when you press **Skills Sync** or answer **Sync now** to the weekly reminder.

No team GitHub account, Git installation, Git author commands or manual skill upload is needed for this central workflow. Shared guidance is exposed through MCP tools. It does not create native Claude Skills UI entries.

The administrator must deploy the service and install its GitHub App. See CENTRAL-SERVICE-DEPLOYMENT.md. The service creates draft PRs and never merges or publishes automatically. Owner merge into main makes a skill eligible for the next successful device sync.

Settings provides Preview saved skills, Submit skills for review now, Sharing service status and the Skills Sync log. Credentials are stored encrypted for the enrolled Windows user. Existing local skill edits are preserved when approved updates are downloaded.

Discovery covers Codex skills, .agents/skills, Claude Code skills and explicit team-candidates. Additional project skill folders must be configured by the administrator. Cloud chats and native Claude cloud skill uploads are not scanned.

## Team installer and usage reporting

The normal setup asks each person for their name, email and consent, then joins the PC to the service by itself; no team code is needed. The administrator blocks or unblocks a PC by setting its Status in Notion's Team members (applied within the hour) or on the dashboard. An administrator's `enrollment.json` beside the installer still takes priority. Older private team installers (`build.ps1 -Team`) still work; their code is ignored and removed from the permanent install after setup.

Once enrolled, the connector records which workflow skills (each `SKILL.md` read) and which AutoCAD/Revit tools are used, as names and daily counts in `%LOCALAPPDATA%\AutodeskMcpSkillCollection\usage.jsonl`. It never records arguments, drawings, models or file paths. Skills Sync sends them each time it runs; nothing sends usage counts on a schedule. Unsent counts wait in `usage-pending.jsonl`. Results are in `usage-upload.log`. The administrator sees them, with name, email, PC, IP and last seen, on the service's `/admin` dashboard.

Error reports work differently. When an AutoCAD or Revit tool fails on an enrolled PC, the connector records the tool name, the error type and a cleaned copy of the first lines of the error message in `failures.jsonl`. Names, numbers, paths, file names, links, email addresses, ids and quoted text are replaced with placeholders such as `<path>` or `<n>`, and the service cleans each message again on arrival. If the same tool works later in the session, a "recovered" line is added. The connector sends these reports in the background about five seconds after the error, as a single short request; this is the one thing it sends outside Skills Sync. If the PC is offline, reports wait in `failures-pending.jsonl` (last 28 days, at most 1000) and Skills Sync sends them next time. Results are in `failure-upload.log`. The service groups identical errors across PCs and versions and lists them in the administrator's Notion "Connector failures" table.

To keep a personal skill off the review queue, add its folder name on its own line to `%LOCALAPPDATA%\AutodeskMcpSkillCollection\excluded-skills.txt`. Lines starting with `#` are comments. Excluded skills are not copied into review packages, not listed in REVIEW.md and never submitted.
