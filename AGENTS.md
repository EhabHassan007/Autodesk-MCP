# BIM-CAD MCP project instructions

Use the repository-scoped AutoCAD skill for live AutoCAD work. Read current drawing identity before edits, verify writes by readback, and keep drawing saves explicit.

Treat meaningful work as reusable skill development. Update the relevant skill or project documentation after demonstrated improvements. Separate proposals, mock tests, file audits, and live application verification.

Use `.agents/skills` as the source of truth for every reusable CAD/BIM skill in this project. Create new skills there, not only in a computer's user-level Codex folder. After creating or improving a skill, validate it and run `scripts/sync-codex-skills.ps1 -Action Publish` so the skill is committed and pushed to GitHub. This is the user's standing request for skill-library changes. Stage only `.agents/skills`; never include drawings, models, credentials, logs, chat transcripts, or client project data. If publishing fails because authentication, network access, or a Git conflict requires the user, preserve the local commit and report the exact next action.

Do not commit drawings/models, credentials, user-level Codex configuration, logs, or client project data. Changes outside the skill library still require the user's request before publication.
