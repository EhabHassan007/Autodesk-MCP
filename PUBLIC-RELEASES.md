# Public team releases

The private `EhabHassan007/Autodesk-MCP` repository remains the source of truth for code, approved skills, and private team intake. Team computers install and update from the separate public `EhabHassan007/Autodesk-MCP-Releases` repository, which contains release artifacts only.

## First publication

Run these commands from the private source repository on an administrator computer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\build-share-package.ps1" -OutputDirectory "D:\06-AutoCAD MCP"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\publish-public-release.ps1" -CreateRepository
```

The first command creates the connector ZIP and `latest.json`. The second command verifies that their versions and hashes match, creates the public release-only repository if needed, and publishes both files under tag `v<VERSION>`. It requires GitHub CLI (`gh`) signed in as the repository owner. It refuses to publish to a repository that is not public.

Review the ZIP contents and `latest.json` before publication. The public repository must never receive source branches, team candidates, pull requests from the private repository, project files, credentials, or client data.

## Team installation

1. Send the team the public GitHub Release page or the connector ZIP from that release.
2. Each user extracts the ZIP completely and double-clicks `INSTALL Autodesk MCP Connector.cmd`.
3. The user selects **Install / Repair**, restarts Codex or Claude, and restarts Revit if installed.
4. The user may select **Enable auto-updates**. Normal install and updates need no Git installation and no GitHub account.

Computers currently running beta.6 or beta.7 need one manual beta.8 Install / Repair. After beta.8 is installed, later releases arrive through the public release channel.

## Later releases (Smart Connector 1.2 and newer)

Smart Connector releases are built by CI, not on a PC. Every merge to `main` runs **Build setup exe**, which builds and installs the public setup exe and keeps every release file as the `smart-connector-release` artifact for 30 days: `Autodesk-MCP-Connector-<version>.zip`, `Smart-Connector-<version>.zip`, `Smart-Connector-Setup-<version>.exe`, `latest.json` and `smart-connector.json`. Publishing those exact files keeps the update manifests' SHA-256 values true.

1. Merge the change, with `release-preparation/beta17/source/runtime/VERSION` raised and a `RELEASE-NOTES.md` section for the new version, and let every workflow on the merge commit finish green.
2. Check, which changes nothing:

   ```powershell
   powershell -ExecutionPolicy Bypass -File release-preparation\beta17\publish-release.ps1
   ```

   It downloads the files CI built for the head of `main` and refuses to go on when a workflow on that commit is not green, a file is missing, a ZIP's SHA-256 differs from its manifest, a manifest names another version or URL, a TEAM file or `team-join.json` is present, the release repository is not public, or the version is already published. It writes the release notes (this version's section plus the files' SHA-256) to `%TEMP%\smart-connector-publish`.
3. Read the notes, then publish:

   ```powershell
   powershell -ExecutionPolicy Bypass -File release-preparation\beta17\publish-release.ps1 -Publish
   ```

   It runs every check again, asks you to type the version, creates the release `v<version>` with the five files as the latest release, and reads back `latest.json` to confirm what team PCs now see. From then on every installed PC is offered the update at its next check.
4. On one test computer, confirm **Update** installs the new version and keeps `skill-review`, `team-candidates`, `team-collection` and `backups`; restart Revit when the release changes the add-in.

`scripts/build-share-package.ps1` and `scripts/publish-public-release.ps1` belong to the beta packages and publish only two files; do not use them for Smart Connector releases.

The release asset URL is version-specific. The connector discovers the current approved version through:

```text
https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json
```
