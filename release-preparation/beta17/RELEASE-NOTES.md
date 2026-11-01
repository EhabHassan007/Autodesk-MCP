Smart Autodesk Connector 1.0.0-beta.18 — central-service pilot

This is an administrator pilot. Automatic team sharing requires the dedicated GitHub App, Render deployment and per-PC enrollment; those are not configured yet.

- One setup includes weekly saved-skill submission for owner review and approved-library synchronization, using revocable device credentials instead of team GitHub sign-ins.
- Simplified Install / Repair, Update, Test connection and Settings interface.
- 27 shared workflows, including Create unfolded walls and AutoCAD project title update.
- Fixes a Windows PowerShell 5.1 hang when reading workflow text through MCP. Workflow content is now read as plain UTF-8, preventing file metadata from expanding during JSON serialization.
- `connection_status` now checks AutoCAD and Revit together and succeeds when either is reachable, so an AutoCAD-only user is no longer told the connector is not connected while Revit is closed.
- Existing local skill edits and disabled-update preferences are preserved.

Validation on 2026-10-28: six regression scripts passed on a GitHub-hosted Windows runner using Windows PowerShell 5.1: parser/client registration isolation, approved-library sync, offline central preview, task preference preservation, MCP workflow reading/path validation, and a simulated beta15 upgrade with checksum rejection and downgrade protection. The installer interface smoke test also passed. Six Python service tests previously passed with a fake GitHub backend.

Validation run: https://github.com/EhabHassan007/Autodesk-MCP-Releases/actions/runs/40639965911
Source: https://github.com/EhabHassan007/Autodesk-MCP/tree/f3f6ecd/release-preparation/beta17

Still outstanding: live GitHub App and HTTPS hosting, Windows device enrollment/DPAPI and real scheduled execution, and installation/update with Revit running followed by successful restart and Claude/Codex connection checks. Hosted tests do not exercise a live Revit model.

Keep this release as a pilot until those checks pass. Beta15 remains the public Latest release; no team update notification has been enabled for beta17.

SHA-256: 91C9656AD457243A70331D4C9481827C2F5F2B870DD78BE18DFE7D18F03C9351
