# Beta17 central skills pilot

This directory preserves the complete connector build source and tests. It is not a live rollout.

Build with `python release-preparation/beta17/build.py` from the repository root. Output is written beside build.py. Run PowerShell test files under tests; pass the generated ZIP as -PackagePath to test-beta15-upgrade.ps1. Tests use isolated fixtures and do not certify Windows/Revit.

The service source and deployment instructions are in services/skill-sharing. The existing root runtime is left available while this pilot is reviewed. This branch is not owner approval of submitted skills.

Verified on 2026-10-27: six Python service tests; PowerShell parser and client registration checks; central sync/preview, task preference preservation, 27 MCP workflow entries and path rejection; simulated beta15 upgrade, folder preservation, checksum rejection and downgrade prevention.

Outstanding: dedicated GitHub App installation, Render deployment, per-PC admin enrollment, and real Windows/Revit update tests. Do not mark the public release Latest until these are complete.
