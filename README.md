# BIM-CAD MCP

Portable Codex connections and reusable skills for desktop CAD/BIM applications.

## AutoCAD 2025 status

The repository currently includes a tested local MCP bridge for full AutoCAD 2025 on Windows. It can inspect the active drawing and layers, inspect top-level entities, create lines/circles/text, edit supported entity properties, manage layers, and explicitly save a drawing.

The live application still runs on the computer where AutoCAD is installed. GitHub stores and synchronizes the code; it does not host the running AutoCAD session.

## Use on this or another computer

1. Install Codex and full AutoCAD 2025 on Windows.
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

## Verify the bridge without editing a live drawing

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\src\autocad\work\test-bridge.ps1"
```

The test uses a mock AutoCAD object model. For live verification, use a disposable blank drawing and perform a create/read/move/read/delete cycle without saving.

## Current limitations

- AutoCAD 2025 Windows only (`AutoCAD.Application.25`).
- The local STDIO bridge is available to Codex running on the same Windows computer and user session as AutoCAD.
- GitHub access alone does not provide remote control of an office workstation.
- Blocks and external references are not expanded; arbitrary AutoLISP/command execution, hatches, dimensions, plotting, and general cloning are not exposed.
- Saving is always a separate explicit tool call because it writes all unsaved changes in the active drawing.

## Roadmap

- Portable installer and AutoCAD `.bundle` add-in.
- Revit adapter and Revit-specific skill.
- Versioned GitHub releases and update/rollback support.
- Authenticated remote connector for intentionally controlled workstation access.

Do not commit DWG/RVT project files, credentials, Codex user configuration, generated logs, or client project information.
