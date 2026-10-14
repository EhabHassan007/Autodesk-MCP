# BIM-CAD MCP

Portable Codex connections and reusable skills for desktop CAD/BIM applications.

## AutoCAD status

The repository includes a version-aware local MCP bridge for full AutoCAD on Windows. It discovers registered AutoCAD ActiveX ProgIDs instead of hardcoding one release. It can inspect the active drawing and layers, inspect top-level entities, create lines/circles/text, edit supported entity properties, manage layers, and explicitly save a drawing. AutoCAD 2025 is live-tested; other releases still require a compatibility test before being marked verified.

The live application still runs on the computer where AutoCAD is installed. GitHub stores and synchronizes the code; it does not host the running AutoCAD session.

## Revit 2024 status

The repository includes a Revit 2024 add-in, a named-pipe MCP bridge, an installer path, and Revit-specific skills. Its narrow tools read document information, levels, selected elements, and element parameters and can set one writable parameter in a Revit transaction. The guarded `execute_csharp` tool adds full Revit API access for workflows that are not covered by a narrow tool. It supports read-only execution, one automatic project transaction, or an explicit manual mode for family-document and advanced transaction workflows. Every call is tied to the expected active document, and model changes require an explicit write flag.

The Revit ribbon contains **BIM-CAD MCP > MCP Connection**. The button reports whether the server is running, whether a client connected recently, the active document, request count, last operation, and last error. The connector does not save or synchronize unless a manual API call explicitly requests that operation.

Every Revit process registers a unique session such as `2024-12345`. `list_sessions` reports the active document in each process. Pass its `session_id` to subsequent tools when multiple Revit sessions are open; the bridge refuses to guess between them. When only one session is running, `session_id` may be omitted.

The Revit 2024 source compiles successfully against the locally installed Revit API, and MCP protocol tests pass. Use a disposable project when first verifying a new write workflow.

## Use on this or another computer

1. Install Codex and a supported full AutoCAD release on Windows.
2. Clone this repository.
3. Open the cloned repository as the Codex project and mark it trusted when prompted. Codex only loads project MCP configuration from trusted projects.
4. Start AutoCAD and open a drawing.
5. Fully restart Codex after the first clone or after MCP configuration changes.
6. Ask: `Use the AutoCAD connection to read the active drawing name and layers.`

The repository-scoped configuration in `.codex/config.toml` starts the included bridge with a relative path, so the clone can live anywhere. Reusable skills live under `.agents/skills`; GitHub is their shared source of truth.

## Keep skills synchronized through GitHub

On every computer, clone this same repository and create or update skills inside `.agents/skills/<skill-name>`. Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\sync-codex-skills.ps1" -Action Publish -Message "Update CAD skills"
```

The command validates every stored skill, commits only `.agents/skills`, rebases on `origin/main`, pushes the commit, and installs the current library into that computer's Codex user skills folder. GitHub authentication must already be configured on that computer.

To download the newest skills on another computer and install them for use in every Codex project:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\sync-codex-skills.ps1" -Action Update
```

Restart Codex after installation if the new skill does not appear immediately. Chat history is outside this workflow and is never copied by the script.

Any BIM-CAD MCP user can select **Review local skills** to create a local report and ZIP package marking candidates as NEW, CHANGED, or IDENTICAL. **Submit review package** opens the package and the GitHub submission form; the contributor reviews and attaches it explicitly. Nothing is uploaded automatically or added to the approved library until the repository owner accepts that individual skill. See [skill submissions](SKILL-SUBMISSIONS.md).

## Daily team knowledge approval

The optional team workflow turns reusable lessons from each member's CAD/BIM chats into text-only skill candidates and opens a private GitHub pull request for `EhabHassan007`. It never merges or installs a candidate automatically.

Each team member completes this once:

1. Install Git, sign in to the private repository through Git Credential Manager, and obtain permission to push intake branches.
2. Install or update BIM-CAD MCP, then use **Team collection check** in the setup app.
3. In Codex ask: `Use cad-team-knowledge-approval to enable my daily team knowledge collection.`

Codex creates a daily automation on that user's account. It reviews only CAD/BIM chats accessible to that signed-in user, distills reusable lessons into `%LOCALAPPDATA%\BIM-CAD-MCP\team-candidates`, removes project-specific context, and runs `scripts\submit-team-knowledge.ps1`. The script blocks common credentials, user paths, cloud model paths, email addresses, project/model files, binaries, links, and files above 256 KB. Previously submitted content hashes are skipped.

Each successful run creates a `skill-intake/...` branch and pull request requesting the repository owner's review. `CODEOWNERS` and the validation workflow protect the approval boundary. Configure the `main` branch ruleset to require the **Validate team skill intake** check, require the repository owner's review, dismiss stale approvals, and block direct pushes. Automatic checks reduce accidental disclosure; the owner must still read every candidate before approval.

Before wider deployment, follow [Safe company rollout](COMPANY-ROLLOUT.md).

## Small Windows setup app

Install / Repair uses the extracted package automatically and copies its runtime files to `%LOCALAPPDATA%\BIM-CAD-MCP`. It does not require a GitHub download or PowerShell commands. Setup finds Codex on PATH, in its Windows desktop installation, or in common CLI installation folders. Choose AutoCAD or Revit 2024 and click Install / Repair for each application. Restart Codex and Revit after installation. Update still requires access to the private GitHub repository; browser sign-in alone does not authenticate Git or direct ZIP downloads. Errors include the underlying command output.

Double-click `installer\Start-BIM-CAD-Setup.cmd` for a guided setup. Select AutoCAD and choose **Install / Repair**. The app downloads or updates the approved repository from GitHub under `%LOCALAPPDATA%\BIM-CAD-MCP`, installs every saved skill, registers the version-aware AutoCAD MCP server globally in Codex, and checks the local AutoCAD connection. Use **Update** on future runs to retrieve newly published skills. Git is optional: when it is unavailable, the setup downloads the current `main` branch as a GitHub ZIP.

The AutoCAD path discovers installed ActiveX versions automatically. The Revit path targets Revit 2024 and builds a local add-in against the installed Revit 2024 API, installs a content-addressed DLL and user manifest, and registers a separate `revit` MCP server. This allows the updater to finish while an older DLL is loaded. Restart Revit after installation so the new add-in loads, and restart Codex after bridge-schema changes so its tool list refreshes.

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

After restarting Revit, click **MCP Connection**, call `list_sessions`, then use `document_info` for the intended session. Verify a write with a separate read.

## Current limitations

- Full AutoCAD for Windows with ActiveX automation. AutoCAD 2025 is verified; other registered versions are discovered dynamically but need version-specific compatibility verification. AutoCAD LT and AutoCAD for Mac are not supported by this bridge.
- The local STDIO bridge is available to Codex running on the same Windows computer and user session as AutoCAD.
- GitHub access alone does not provide remote control of an office workstation.
- AutoCAD blocks and external references are not expanded; arbitrary AutoLISP/command execution, hatches, dimensions, plotting, and general cloning are not exposed.
- Saving is always a separate explicit tool call because it writes all unsaved changes in the active drawing.
- Revit 2025 and newer use .NET 8 and are not built by the current Revit 2024 compiler path.

## Roadmap

- Portable installer and AutoCAD `.bundle` add-in.
- Add narrow Revit tools for recurring verified workflows while retaining the guarded API runner for advanced cases.
- Versioned GitHub releases and update/rollback support.
- Authenticated remote connector for intentionally controlled workstation access.

Do not commit DWG/RVT project files, credentials, Codex user configuration, generated logs, or client project information.
