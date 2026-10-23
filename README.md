# Autodesk MCP Connector

Current test package version: **1.0.0-beta.14**. See [TESTING.md](TESTING.md) before sharing the package with testers.

The shareable ZIP is intentionally compact. After extraction its root shows `INSTALL Autodesk MCP Connector.cmd`, `Autodesk MCP Skills for Claude.zip`, `README-FIRST.txt`, and a `Support` folder. Double-click the installer once; it installs the connector, skills, Revit add-in, and user-level Codex, Claude Code, and Claude Desktop registrations automatically, writes `%LOCALAPPDATA%\AutodeskMcpConnector\setup.log`, and displays a restart message when finished. Claude Desktop Free and paid accounts use the local registration; Claude web and mobile use the authenticated remote mode described in [Claude remote setup](REMOTE-CLAUDE.md). Claude Chat users upload the included combined skill once through **Customize > Skills**; Team and Enterprise owners may provision it organization-wide.

Every pull request and approved push to `main` builds the shareable ZIP in GitHub Actions. A signed-in repository collaborator can open **Actions → Build Autodesk MCP Connector package**, select a successful run, and download the package from **Artifacts**. Artifacts are retained for 90 days.

Do not copy or run the repository's `installer` folder by itself on another computer. Initial installation is self-contained. Manual and automatic updates use a separate public release channel over HTTPS, verify the ZIP with SHA-256, and require neither Git nor GitHub sign-in.

One Autodesk connector for local Codex/Claude Code and authenticated Claude Free/Paid Chat access, plus the private BIM-CAD reusable skill library.

## AutoCAD status

The repository includes a version-aware local MCP bridge for full AutoCAD on Windows. It discovers registered AutoCAD ActiveX ProgIDs instead of hardcoding one release. It can inspect the active drawing and layers, inspect top-level entities, create lines/circles/text, edit supported entity properties, manage layers, and explicitly save a drawing. AutoCAD 2025 is live-tested; other releases still require a compatibility test before being marked verified.

The live application still runs on the computer where AutoCAD is installed. GitHub stores and synchronizes the code; it does not host the running AutoCAD session.

## Revit 2024 status

The repository includes a Revit 2024 add-in, a named-pipe MCP bridge, an installer path, and Revit-specific skills. Its narrow tools read document information, levels, selected elements, and element parameters and can set one writable parameter in a Revit transaction. The guarded `execute_csharp` tool adds full Revit API access for workflows that are not covered by a narrow tool. It supports read-only execution, one automatic project transaction, or an explicit manual mode for family-document and advanced transaction workflows. Every call is tied to the expected active document, and model changes require an explicit write flag.

Revit gets a dedicated **Autodesk MCP Connector** ribbon tab. Open its **Connection** panel and click **Connection Status** to see whether the server is running, whether a client connected recently, the active document, request count, last operation, and last error. The connector does not save or synchronize unless a manual API call explicitly requests that operation.

The same panel includes **Check Updates**. It opens the setup app directly on the approved update check. The check never changes the model or installs files automatically; select **Update** in the setup app when an approved version is available, then restart Revit so the new add-in DLL loads.

Every Revit process registers a unique session such as `2024-12345`. `list_sessions` reports the active document in each process. Pass its `session_id` to subsequent tools when multiple Revit sessions are open; the bridge refuses to guess between them. When only one session is running, `session_id` may be omitted.

The Revit 2024 source compiles successfully against the locally installed Revit API, and MCP protocol tests pass. Use a disposable project when first verifying a new write workflow.

## Use on this or another computer

1. Install Codex and a supported full AutoCAD release on Windows. Install / Repair can install Claude Desktop automatically when it is missing.
2. Clone this repository.
3. Open the cloned repository as the Codex project and mark it trusted when prompted. Codex only loads project MCP configuration from trusted projects.
4. Start AutoCAD and open a drawing.
5. Fully restart the installed AI client after the first clone or after MCP configuration changes.
6. Ask: `Use the AutoCAD connection to read the active drawing name and layers.`

The repository-scoped configuration in `.codex/config.toml` starts the included bridge with a relative path for Codex. The setup app creates equivalent local registrations for detected Codex and Claude Code installations. Claude Chat uses the authenticated HTTPS gateway. Reusable skills live under `.agents/skills`; GitHub is their reviewed source of truth.

## Keep skills synchronized through GitHub

On every computer, clone this same repository and create or update skills inside `.agents/skills/<skill-name>`. Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\sync-codex-skills.ps1" -Action Publish -Message "Update CAD skills"
```

The command validates every stored skill, commits only `.agents/skills`, rebases on `origin/main`, pushes the commit, and installs the current library into that computer's Codex user skills folder. The setup app also copies the approved library to `~/.claude/skills` for Claude Code. GitHub authentication must already be configured on that computer.

To download the newest skills on another computer and install them for use in every Codex project:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\sync-codex-skills.ps1" -Action Update
```

Restart Codex or Claude Code after installation if a new skill does not appear immediately. Chat history is outside this workflow and is never copied by the script.

The optional team workflow can collect reusable CAD/BIM skill candidates for owner review. Nothing is added to the approved library until the repository owner accepts that individual skill. See [skill submissions](SKILL-SUBMISSIONS.md).

## Daily team knowledge approval

The optional team workflow turns reusable lessons from each member's CAD/BIM chats into text-only skill candidates and opens a private GitHub pull request for `EhabHassan007`. It never merges or installs a candidate automatically.

Each team member completes this once:

1. Install Git, sign in to the private repository through Git Credential Manager, and obtain permission to push intake branches.
2. Install or update Autodesk MCP Connector, then use **Team knowledge setup (optional)** in the setup app.
3. In Codex ask: `Use cad-team-knowledge-approval to enable my daily team knowledge collection.`

Codex creates a daily automation on that user's account. It reviews only CAD/BIM chats accessible to that signed-in user, distills reusable lessons into `%LOCALAPPDATA%\BIM-CAD-MCP\team-candidates`, removes project-specific context, and runs `scripts\submit-team-knowledge.ps1`. The script blocks common credentials, user paths, cloud model paths, email addresses, project/model files, binaries, links, and files above 256 KB. Previously submitted content hashes are skipped.

Each successful run creates a `skill-intake/...` branch and pull request requesting the repository owner's review. `CODEOWNERS` and the validation workflow protect the approval boundary. Configure the `main` branch ruleset to require the **Validate team skill intake** check, require the repository owner's review, dismiss stale approvals, and block direct pushes. Automatic checks reduce accidental disclosure; the owner must still read every candidate before approval.

Before wider deployment, follow [Safe company rollout](COMPANY-ROLLOUT.md).

## Autodesk MCP Connector setup app

Install / Repair uses the extracted package automatically and copies its runtime files to `%LOCALAPPDATA%\BIM-CAD-MCP`. It does not require a second GitHub download or manual PowerShell commands. Setup detects Codex, Claude Code, and Claude Desktop and preserves their unrelated integrations. Claude Desktop Free/Paid and Claude Code use the local MCP registration; Claude web and mobile require **Claude remote** setup with a stable Cloudflare hostname and per-workstation tunnel token. The remote gateway listens only on loopback, requires its own generated bearer credential, caps requests, and excludes `execute_csharp` by default. AutoCAD versions are discovered dynamically; Revit 2024 is the currently supported Revit build. Update downloads `latest.json` and the approved ZIP from the public `Autodesk-MCP-Releases` repository, verifies the SHA-256, and preserves local team-candidate folders. Git is needed only for private team knowledge submission.

Double-click `INSTALL Autodesk MCP Connector.cmd` in the extracted share folder. The one-click setup installs the approved package under `%LOCALAPPDATA%\BIM-CAD-MCP`, installs every saved skill for Codex and Claude Code, installs the Revit add-in when Revit 2024 is present, checks that no Windows policy disables Claude Desktop local MCP, and registers one local `autodesk` MCP server named **Autodesk MCP Connector**. It synchronizes both classic and Microsoft Store/MSIX Claude configuration locations. Client registrations are isolated so a temporary Codex CLI failure cannot block Claude Desktop setup. The setup app provides Install / Repair, Update, Test connection, **Claude remote**, Install folder, optional Team knowledge setup, and **Enable auto-updates**. The updater preserves local `skill-review`, `team-candidates`, `team-collection`, `remote`, and `backups` data while replacing the managed runtime with the verified public release.

**Enable auto-updates** registers a per-user Windows task that checks the public release manifest at sign-in and every day at 9:00 AM. When a new approved release appears, it verifies and installs it automatically, then shows a restart confirmation. Failures show an action-required notification and are recorded in `%LOCALAPPDATA%\AutodeskMcpConnector\update-alert.log`. Private branches and unapproved skill submissions never enter this update channel.

Release maintainers build both the ZIP and its manifest with `scripts\build-share-package.ps1`, then publish them to the public release-only repository with `scripts\publish-public-release.ps1`. The public repository contains distributable artifacts only; source code, private team intake, and review history remain in the private source repository. See [Public team releases](PUBLIC-RELEASES.md).

The unified connector exposes both AutoCAD and Revit tools through the `autodesk` MCP registration. A cross-process lock serializes model-changing calls when Codex and Claude are open together. The AutoCAD path discovers installed ActiveX versions automatically. The Revit path targets Revit 2024 and builds a local add-in against the installed Revit 2024 API, then installs a content-addressed DLL and user manifest. This allows the updater to finish while an older DLL is loaded. Restart Revit after installation so the new add-in loads, and restart Codex or Claude after bridge-schema changes so its combined tool list refreshes.

The Revit named pipe remains local to the Windows computer. Codex and Claude Code use the STDIO bridge on that PC. Claude Free and paid Chat connect through the optional authenticated HTTPS gateway and Cloudflare Tunnel; see [Claude remote setup](REMOTE-CLAUDE.md). Free accounts support one custom remote connector.

## Verify the bridge without editing a live drawing

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\src\autocad\work\test-bridge.ps1"
```

The test uses a mock AutoCAD object model. For live verification, use a disposable blank drawing and perform a create/read/move/read/delete cycle without saving.

For the Revit bridge protocol, multi-session routing, and tool schema:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\src\revit\work\test-bridge.ps1"
```

After restarting Revit, open the **Autodesk MCP Connector** ribbon tab and click **Connection Status**. In Codex or Claude, call `list_sessions`, then use `document_info` for the intended session. Verify a write with a separate read.

## Current limitations

- Full AutoCAD for Windows with ActiveX automation. AutoCAD 2025 is verified; other registered versions are discovered dynamically but need version-specific compatibility verification. AutoCAD LT and AutoCAD for Mac are not supported by this bridge.
- The local STDIO bridge is available to Codex and Claude Code running on the same Windows computer and user session as AutoCAD/Revit.
- Claude Chat requires the remote gateway, a stable HTTPS hostname, and a one-time account connector authorization. No Windows installer can silently grant access to a Claude account.
- Local `SKILL.md` installation applies to Codex and Claude Code. Free and paid Claude Chat users install the generated combined skill in Customize; Team/Enterprise owners can provision it organization-wide.
- GitHub access alone does not provide remote control of an office workstation.
- AutoCAD blocks and external references are not expanded; arbitrary AutoLISP/command execution, hatches, dimensions, plotting, and general cloning are not exposed.
- Saving is always a separate explicit tool call because it writes all unsaved changes in the active drawing.
- Revit 2025 and newer use .NET 8 and are not built by the current Revit 2024 compiler path.

## Roadmap

- Portable installer and AutoCAD `.bundle` add-in.
- Add narrow Revit tools for recurring verified workflows while retaining the guarded API runner for advanced cases.
- Versioned GitHub releases and update/rollback support.
- OAuth support and centralized tunnel provisioning for larger managed deployments.

Do not commit DWG/RVT project files, credentials, AI-client user configuration, generated logs, or client project information.
