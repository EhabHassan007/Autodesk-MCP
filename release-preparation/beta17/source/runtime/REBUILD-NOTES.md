Smart Connector 1.0.0 build

This build is for an administrator pilot. The central service must be hosted and connected to a GitHub App before central sharing works. It has not been deployed or tested against live GitHub from this environment.

- One connector setup includes hidden weekly skill submission and approved-library synchronization.
- Team PCs use revocable service device credentials, not personal GitHub credentials or Git author commands. IT supplies one enrollment file per PC/user with setup; the credential is encrypted for that Windows user and the plaintext setup file is removed after import.
- The service creates draft pull requests in the configured Autodesk-MCP repository and never merges, publishes a release, or writes directly to main.
- After owner merge, approved workflows sync to Codex and Claude Code when this does not overwrite local edits. The MCP workflow tools expose shared guidance to Claude without a separate uploaded skills ZIP. Native Claude Skills UI entries remain optional and separate.
- Main interface stays simplified: Install / Repair, Update, Test connection, Settings. Manual skill submission runs in the background, with results in the local log.
- Devices without admin enrollment show a pending-configuration message; they are not silently granted GitHub access.

Validation: service authentication/revocation, duplicate tracking, failure/retry and request-limit tests; mocked GitHub branch/draft-PR contract; PowerShell parser checks; central preview without Git/network; task preference preservation; approved-library synchronization with local-edit preservation; MCP workflow reading and path validation. Windows DPAPI, UI and scheduler behavior, live GitHub App permissions, HTTPS hosting and end-to-end deployment still require the documented pilot.

Do not mark this build as Latest for the team until the service is deployed and a Windows pilot succeeds. Existing connector functionality remains based on the beta 16 line; service configuration is an additional admin prerequisite.
