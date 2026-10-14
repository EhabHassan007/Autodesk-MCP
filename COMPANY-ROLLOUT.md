# Safe company rollout

Use this checklist after the automated team knowledge workflow is merged and before inviting the wider team.

## Repository and identity

1. Move the repository to the company GitHub organization when available. Keep it **Private**, or **Internal** only when every enterprise member is allowed to see the connector and approved skills.
2. Require two-factor authentication and company SSO. Remove access promptly when a team member changes role or leaves.
3. Give ordinary contributors the minimum access needed to push `skill-intake/*` branches. Keep repository administration and release rights with named maintainers.
4. Do not use shared GitHub or Windows accounts. The Revit named pipe trusts the current Windows user, so every person needs a separate Windows account.

## Protect `main`

Create a GitHub ruleset for the default branch with:

- Require a pull request before merging.
- Require approval from code owner `EhabHassan007` for `.agents/skills`.
- Require the **Validate team skill intake** status check.
- Dismiss stale approvals when new commits are pushed.
- Require approval of the most recent reviewable push.
- Block force pushes and branch deletion.
- Restrict direct pushes to named maintainers.

The validation workflow reads candidate files but never executes submitted scripts. Treat every intake branch as untrusted until the owner reviews the complete diff.

## Protect project and personal data

- Keep RVT, RFA, DWG, IFC, NWC, PDFs, spreadsheets, screenshots, logs, and chat transcripts out of GitHub.
- Keep client names, project names/numbers, model paths, cloud paths, element IDs, usernames, email addresses, credentials, and personal absolute paths out of skills.
- Enable GitHub secret scanning and push protection. If a real credential is detected or committed, revoke and replace it; deleting the file from the latest commit is insufficient.
- Review rejected pull-request branches and delete them after the contributor has preserved any safe local correction.

The automatic local and GitHub checks catch common leaks. They do not understand every client term, so owner review remains mandatory.

## Package and distribute

1. Pilot with two or three trusted users and disposable Revit/AutoCAD files.
2. Build releases from an approved commit, record SHA-256 hashes, and code-sign the installer and Revit DLL with the company certificate before broad deployment.
3. Publish approved release packages through the company software channel, such as Intune or an access-controlled SharePoint library. Do not ask staff to run arbitrary files from intake branches.
4. Keep a rollback package and the previous content-addressed Revit DLL available for each release.
5. Restart Revit and Codex after connector or MCP schema updates, then verify `list_sessions`, `document_info`, and one harmless read.

## Full-control policy

`execute_csharp` provides full Revit API access under the signed-in Windows user. Limit it to trained users and approved tasks. Require:

- `document_info` and the intended `session_id` before writes.
- The expected document ID and explicit model-change flag.
- A separate read-back after every write batch.
- Small reversible batches in workshared models.
- Explicit user direction before save, synchronize, publish, export, or deletion.

Use narrow tools for recurring operations. Promote a repeatedly proven workflow into a reviewed skill or narrow connector tool rather than repeatedly generating unrestricted code.

## Team onboarding

For each team member:

1. Install the approved BIM-CAD MCP release and authenticate Git through Git Credential Manager to the private repository.
2. Run **Team collection check** in Autodesk MCP Connector.
3. In Codex ask: `Use cad-team-knowledge-approval to enable my daily team knowledge collection.`
4. Confirm the automation is scheduled in the correct local timezone.
5. Confirm a harmless test candidate produces a pull request requesting the repository owner's review and does not merge automatically.

No central service can read every employee's Codex chats. Each person must enable the local automation on their own signed-in account; it reviews only the CAD/BIM chats available to that account.
