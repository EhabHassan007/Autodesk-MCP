# BIM-CAD MCP

Portable Codex connections and reusable skills for desktop CAD/BIM applications.

## AutoCAD status

The repository includes a version-aware local MCP bridge for full AutoCAD on Windows. It discovers registered AutoCAD ActiveX ProgIDs instead of hardcoding one release. It can inspect the active drawing and layers, inspect top-level entities, create lines/circles/text, edit supported entity properties, manage layers, and explicitly save a drawing. AutoCAD 2025 is live-tested; other releases still require a compatibility test before being marked verified.

The live application still runs on the computer where AutoCAD is installed. GitHub stores and synchronizes the code; it does not host the running AutoCAD session.

## Revit 2024 status

The repository now includes a Revit 2024 add-in, a named-pipe MCP bridge, an installer path, and a Revit-specific skill. The first tool set reads document information, levels, selected elements, and element parameters, and can set one writable parameter in a Revit transaction. It never saves or synchronizes the model.

The Revit 2024 source compiles successfully against the locally installed Revit API, and MCP protocol and isolated installer tests pass. Live Revit reads and writes still need verification in a disposable project before the adapter is considered production-ready.

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

## Small Windows setup app

Double-click `installer\Start-BIM-CAD-Setup.cmd` for a guided setup. Select AutoCAD and choose **Install / Repair**. The app downloads or updates the approved repository from GitHub under `%LOCALAPPDATA%\BIM-CAD-MCP`, installs every saved skill, registers the version-aware AutoCAD MCP server globally in Codex, and checks the local AutoCAD connection. Use **Update** on future runs to retrieve newly published skills. Git is optional: when it is unavailable, the setup downloads the current `main` branch as a GitHub ZIP.

The AutoCAD path discovers installed ActiveX versions automatically. The Revit path targets Revit 2024 and builds a local add-in against the installed Revit 2024 API, installs its user manifest, and registers a separate `revit` MCP server. Restart Revit after installation so the add-in loads.

## Verify the bridge without editing a live drawing

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\src\autocad\work\test-bridge.ps1"
```

The test uses a mock AutoCAD object model. For live verification, use a disposable blank drawing and perform a create/read/move/read/delete cycle without saving.

## Current limitations

- Full AutoCAD for Windows with ActiveX automation. AutoCAD 2025 is verified; other registered versions are discovered dynamically but need version-specific compatibility verification. AutoCAD LT and AutoCAD for Mac are not supported by this bridge.
- The local STDIO bridge is available to Codex running on the same Windows computer and user session as AutoCAD.
- GitHub access alone does not provide remote control of an office workstation.
- Blocks and external references are not expanded; arbitrary AutoLISP/command execution, hatches, dimensions, plotting, and general cloning are not exposed.
- Saving is always a separate explicit tool call because it writes all unsaved changes in the active drawing.

## Roadmap

- Portable installer and AutoCAD `.bundle` add-in.
- Live-test the Revit 2024 adapter in a disposable project, then expand its narrow tool set based on verified workflows.
- Versioned GitHub releases and update/rollback support.
- Authenticated remote connector for intentionally controlled workstation access.

Do not commit DWG/RVT project files, credentials, Codex user configuration, generated logs, or client project information.
