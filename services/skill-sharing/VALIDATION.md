# Final preparation status — 2026-10-27

Prepared locally; not deployed or published.

Passed in this session:
- Six Python service tests using a fake GitHub backend: authentication, draft-branch contract, deduplication, retry, revocation, validation, library and rate limiting.
- Docker build with TLS verification enabled. Application source is explicitly readable by the non-root runtime user. Docker build context excludes unrelated files and credentials.
- Offline container smoke test as UID 10001: imports, SQLite write, health, enrollment and authenticated library request.
- PowerShell approved-skill synchronization: installation, updates, preservation of personal edits and path rejection.
- PowerShell scheduled-runner preview without Git, enrollment or network.
- Existing beta17 connector ZIP integrity and manifest SHA-256 match.

Remaining blockers:
- GitHub API and Render service-list access now work. Render workspace-owner lookup returned a Cloudflare HTTP 403; deployment access is not yet fully validated.
- No Render deployment, dedicated GitHub App credentials, or device enrollment has been configured. The only observed installed App is the ChatGPT Codex connector; it is not the skills service App.
- Render persistent-disk permissions, live GitHub draft PRs, and Windows DPAPI, scheduled tasks, Revit and beta15-to-beta17 update behavior need the deployment pilot in DEPLOY.md.

The package contains a beta17 pilot connector; beta15 has not been replaced. Do not mark beta17 Latest until the service and Windows pilot work. Environment publication is separate from publishing a GitHub release.

## Windows validation and draft upload — 2026-10-28

Run https://github.com/EhabHassan007/Autodesk-MCP-Releases/actions/runs/40639965911 passed six Windows PowerShell 5.1 regression scripts and the installer UI smoke test. It uploaded and SHA-256-verified both beta17 draft assets. The workflow text reader now uses plain UTF-8 strings to avoid Windows PowerShell JSON expanding Get-Content metadata.

The release remains a draft. Live App/Render setup, DPAPI enrollment, scheduled-task execution and Revit installation/restart testing remain outstanding. Source is preserved in private PR #9.
