---
name: cad-team-knowledge-approval
category: general
description: Set up or run daily team collection of reusable CAD/BIM skills and lessons into private GitHub pull requests that require the repository owner's approval.
---

# CAD/BIM team knowledge approval

Use this skill when a team member asks to enable, run, or troubleshoot shared daily knowledge collection for BIM-CAD MCP.

## Enable collection for one team member

1. Confirm that BIM-CAD MCP is installed from the private team repository and that Git is authenticated through Git Credential Manager for an account with permission to push intake branches.
2. Use the Codex automation tool to create one daily heartbeat named **Daily BIM team knowledge intake**, normally at 4:30 PM in that user's local timezone. The user must explicitly request this setup on their own account; never create automations for other people or claim access to their chats.
3. Use this automation prompt:

   > Review the CAD/BIM-related chats accessible to this signed-in user that changed since the previous run. Extract only demonstrated, reusable workflow knowledge. Create or update candidate skills under `%LOCALAPPDATA%\BIM-CAD-MCP\team-candidates\<skill-name>\SKILL.md`. Use generic names and examples. Do not copy chat transcripts, client or project names, model paths, cloud paths, element IDs, usernames, email addresses, credentials, screenshots, drawings, models, or generated logs. State whether each workflow was instruction-only, file-tested, read-tested, or write-tested with read-back. Then run `%LOCALAPPDATA%\BIM-CAD-MCP\scripts\submit-team-knowledge.ps1`. Stay quiet when there are no new candidates. When a pull request is created, report its link and that repository-owner approval is still required. If authentication or the privacy gate blocks submission, report the exact local problem without uploading anything.

4. Keep notifications for meaningful results: a created pull request, a blocked privacy/authentication check, or required user action. Do not send a daily ânothing changedâ message.

Each team member needs this one-time local setup because one Codex account cannot read another person's chats.

## Candidate rules

- Turn a lesson into a concise skill or a focused update to an existing skill. Do not store a raw conversation.
- Reuse an existing skill name when the lesson improves that workflow. Do not create duplicates for each project, level, element, or chat.
- Preserve user-approved working rules and rejected approaches when they generalize safely.
- Keep company/client/project information out of the candidate. Replace specific names and identifiers with generic terms.
- Describe verification accurately. Never turn one successful project operation into a universal guarantee.
- Keep candidate submissions text-only. Binary assets and project files require separate owner review.

## Submit for approval

Run:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\BIM-CAD-MCP\scripts\submit-team-knowledge.ps1"
```

The script performs a local privacy scan, skips previously submitted hashes, creates a temporary clean clone, pushes a `skill-intake/...` branch, and opens a pull request requesting review from `EhabHassan007`. It must never merge the pull request. If the scan flags content, leave the candidate local for correction.

The repository owner approves or rejects every candidate through the pull request. Approved skills become available to the team only after merge and the normal BIM-CAD MCP update.
