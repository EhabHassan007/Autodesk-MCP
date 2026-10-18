# Public team releases

The private `EhabHassan007/Autodesk-MCP` repository remains the source of truth for code, approved skills, and private team intake. Team computers install and update from the separate public `EhabHassan007/Autodesk-MCP-Releases` repository, which contains release artifacts only.

## First publication

Run these commands from the private source repository on an administrator computer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\build-share-package.ps1" -OutputDirectory "D:\06-AutoCAD MCP"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\publish-public-release.ps1" -CreateRepository
```

The first command creates the four-file connector ZIP and `latest.json`. The second command verifies that their versions and hashes match, creates the public release-only repository if needed, and publishes both files under tag `v<VERSION>`. It requires GitHub CLI (`gh`) signed in as the repository owner. It refuses to publish to a repository that is not public.

Review the ZIP contents and `latest.json` before publication. The public repository must never receive source branches, team candidates, pull requests from the private repository, project files, credentials, or client data.

## Team installation

1. Send the team the public GitHub Release page or the connector ZIP from that release.
2. Each user extracts the ZIP completely and double-clicks `Start-Autodesk-MCP-Connector.cmd`.
3. The user selects **Install / Repair**, restarts Codex or Claude, and restarts Revit if installed.
4. The user may select **Enable auto-updates**. Normal install and updates need no Git installation and no GitHub account.

Computers currently running beta.6 or beta.7 need one manual beta.8 Install / Repair. After beta.8 is installed, later releases arrive through the public release channel.

## Later releases

1. Merge approved source and skill changes into the private source repository.
2. Increase `VERSION`.
3. Run `build-share-package.ps1` and review the generated ZIP and `latest.json`.
4. Run `publish-public-release.ps1` without `-CreateRepository`.
5. On one test computer, confirm **Update** installs the new version and preserves `skill-review`, `team-candidates`, and `backups`.

The release asset URL is version-specific. The connector discovers the current approved version through:

```text
https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json
```
