# Beta17 central skills pilot

This directory preserves the complete connector build source and tests. It is not a live rollout.

Trial on your own PC: `powershell -ExecutionPolicy Bypass -File release-preparation\beta17\build-trial.ps1` builds a private installer from the current working tree on a temporary copy, with a `-trial.<timestamp>` version, and leaves the repository unchanged. Output goes to `Documents\Smart Connector trial`. It is never a team build, never published, and is for that PC only.

Build with `python release-preparation/beta17/build.py` from the repository root. Output is written beside build.py. Run PowerShell test files under tests; pass the generated ZIP as -PackagePath to test-beta15-upgrade.ps1. Tests use isolated fixtures and do not certify Windows/Revit.

The selected free hosting service and deployment instructions are in [services/skill-sharing-cloudflare](../../services/skill-sharing-cloudflare/README.md). The original Python/Docker alternative remains in services/skill-sharing. Both implement the same connector API. The existing root runtime is left available while this pilot is reviewed. This branch is not owner approval of submitted skills.

Verified on 2026-10-27: six Python service tests; PowerShell parser and client registration checks; central sync/preview, task preference preservation, 27 MCP workflow entries and path rejection; simulated beta15 upgrade, folder preservation, checksum rejection and downgrade prevention.

Windows follow-up: six regression scripts and the installer UI smoke test passed under Windows PowerShell 5.1 in [run 40639965911](https://github.com/EhabHassan007/Autodesk-MCP-Releases/actions/runs/40639965911), after fixing workflow text serialization. These are isolated checks, not live Revit or DPAPI/scheduler certification.

The owner created GitHub App 5506370, installation 176074887 and a Cloudflare account. The Worker and D1 schema were deployed on 2026-10-28. Live GitHub App downloads (27 skills / 36 files), a harmless draft submission (PR 10), duplicate suppression, approval-boundary checks and device revocation passed on 2026-10-29. A private installer with one enrolled pilot device is prepared outside the repository. Outstanding: the owner's Windows/Revit installation and update pilot, DPAPI and actual scheduled execution, plus broader free-plan usage validation and per-device team provisioning. Paid Render deployment is no longer planned. Keep the public release a draft until the pilot passes; never include private enrollment credentials in public assets.
