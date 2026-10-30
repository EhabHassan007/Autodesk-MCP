---
name: cad-team-knowledge-approval
description: Configure or troubleshoot weekly collection of saved Codex and Claude Code skills into draft GitHub pull requests for repository-owner review.
---

# Weekly team skill review

Use Autodesk MCP Connector Settings to preview saved skills, submit for review now, or enable/disable weekly collection. The default schedule is Friday at 16:30 in the Windows PC's local time while the user is signed in.

The integrated helper is `scripts/weekly-skill-collection.ps1`. Actions: Enable, Disable, Status, Preview, Run. The installed helper is also maintained under `%LOCALAPPDATA%\AutodeskMcpSkillCollection\scripts`.

Collection covers Codex skills, `.agents/skills`, Claude Code skills, and `team-candidates`. Additional project skill roots can be configured explicitly. It does not read chats or retrieve skills uploaded to Claude's cloud account. Use Preview before troubleshooting submissions; inspect the local report without copying private content into chat.

The Git account needs permission to push branches and create pull requests in `EhabHassan007/Autodesk-MCP`. Authenticate through Git Credential Manager; never ask for tokens in chat or place credentials in skills. The script creates draft pull requests and requests review from the repository owner. It never merges, publishes a release, or pushes to main. The owner must review and approve before distribution in a new connector release.

Do not silently bypass sensitive-content checks, resolve conflicting skill revisions by discarding one, or enable collection on someone else's PC without authorization. Preserve local skill files. Check `weekly.log` and `last-result.json` under the helper's data folder when a scheduled run fails. Report the precise blocker and avoid claiming a task is active without checking Windows Task Scheduler.
