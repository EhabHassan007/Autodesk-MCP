# Installer handoff: moving Smart Connector from PowerShell to a compiled program

Status as of 2026-11-08. Branch `main-70886s`, merged work up to PR #47; stages B and C are in the PR that adds this file.

## Why this work exists

Kaspersky (IT-managed, the user cannot change its settings) deletes the Smart Connector setup file as
`HEUR:Trojan.PowerShell.Agent.c`. This is a heuristic verdict, not a named malware match. OpenTIP showed 0 flagged
files inside the package in 1.1.0 but still flagged the setup on its dynamic run, and later builds were deleted on
write or on unzip. The conclusion reached with the owner: the scanner objects to a PowerShell-heavy, unsigned
installer, not to one specific behaviour. So the plan is to remove PowerShell from what the setup carries.

What was ruled out, on purpose: obfuscating or renaming scripts, splitting files, or anything else that exists only
to dodge the scanner. Only changes that are real, reviewable improvements are made.

Two routes that do not depend on code remain the only guaranteed fix, and both belong to IT:
1. a central Kaspersky exclusion for the setup and the install folder, plus a false-positive report;
2. a company code-signing certificate so the setup .exe and `SmartConnector.exe` are signed.

## History

| PR | What |
|---|---|
| #43 | Lean core: no scheduled tasks, no background agent, no web gateway or tunnel. Update check on open (once a day), weekly Skills Sync reminder. Version 1.1.0. |
| #44 | Setup installs files itself; Start menu entry runs under RemoteSigned. |
| #45 | Setup .exe runs no program or script. It installs files and a Start menu entry; the first open of Smart Connector finishes setup (`setup\setup-pending.txt` marker). |
| #46 | Stage 1: `SmartConnector.exe mcp`, the compiled MCP server, replaces the three PowerShell bridges. |
| #47 | Stage A: the Smart Connector app, setup window, Skills Sync / Check Updates / Status windows, Settings and team join dialog are C#. |
| this PR | Stage B: install engine (`engine`). Stage C: Skills Sync and usage scripts (`skills`). |

## What the compiled program does

`release-preparation/beta17/source/runtime/src/connector/*.cs` builds one program, installed at
`%LOCALAPPDATA%\BIM-CAD-MCP\bin\SmartConnector.exe`. It is compiled by the release build with the Windows .NET
Framework 4 compiler (C# 5, no NuGet), never on a user's PC. It is a Windows (GUI) program so no console flashes;
`mcp` and `engine` still use the pipes they are given.

| Command | Replaces | Files |
|---|---|---|
| `mcp` | `src\autodesk\autodesk-bridge.ps1`, `autocad-bridge.ps1`, `revit-bridge.ps1` | McpServer.cs, AutoCad.cs, RevitAndWorkflows.cs |
| `app`, `setup`, `action`, `settings` | `SmartConnectorApp.ps1`, `SetupWizard.ps1`, `ConnectorActions.ps1`, `Settings.ps1`, `TeamJoinDialog.ps1`, `Brand.ps1`, `ConnectorStatus.ps1` | SmartConnectorApp.cs, SetupWizard.cs, ConnectorActions.cs, ConnectorStatus.cs, Brand.cs |
| `engine --action Install\|Update\|CheckUpdate\|Status\|...` | `installer\Setup-BimCad.ps1` | Engine*.cs |
| `skills sync\|preview\|collect\|submit\|usage\|codex-sync\|retire-tasks\|configure\|initialize` | `scripts\*.ps1` | Skills*.cs |

Every launcher (Start menu, Revit ribbon `ConnectorUi.cs`, AutoCAD `.lsp`, `Start-Autodesk-MCP-Connector.cmd`, the
windows themselves) starts the program when `bin\SmartConnector.exe` exists and falls back to the PowerShell script
when it does not. That fallback serves an install taken straight from the repository, which has no compiled file.

### Things that behave differently on purpose

- **Update replaces files in place.** A running `SmartConnector.exe` locks its own file, so moving the whole install
  folder aside (the PowerShell way) cannot work. The engine downloads and verifies the release (SHA-256, no
  downgrade), stops only the other Smart Connector processes of this install, replaces files in place, and renames
  a locked file to `<name>.old`. Any Smart Connector command deletes `*.old` leftovers at start. A failed update
  puts everything back. It never copies the program to a temp folder to run from there (a pattern scanners flag).
- **The setup .exe still runs nothing.** It copies files and creates the Start menu entry. Everything else happens
  when the user opens Smart Connector.
- **Self-repair of a missing Skills Sync helper script** has no meaning for a compiled program and was dropped; a
  failed sync still records a reason.
- **A usage line with a non-numeric count** is dropped (the script failed every run on it).
- **The Revit add-in is still compiled on each PC** by the Windows `csc.exe`, now launched from the compiled
  program, against the installed Revit API. This is the one remaining compile-on-PC step.

### Test hooks (read before shipping)

These exist only so Windows CI can use a stand-in server. Each is off unless set, and none can send a token or file
to another computer:
- `SMART_CONNECTOR_ALLOW_LOOPBACK_HTTP=1` lets the skill-service address and `SMART_CONNECTOR_GITHUB_API` be
  `http://` on a loopback address. Everything else must be HTTPS.
- `SMARTCONNECTOR_TEST_ALLOW_LOCAL_URLS=1` allows `file:` and loopback `http` for the release manifest, the download
  and the team join service.
- `engine --test-autocad-releases` and `--autocad-registry-root` fake AutoCAD detection and point the registry work
  at a throwaway tree.
Keep these out of user documentation.

## Build and verify

- `release-preparation/beta17/build.ps1` (Windows; add `-Team` for the private team installer, never upload that):
  compiles the program, builds the release ZIP and the setup .exe (needs Inno Setup 6), writes `latest.json`.
- `release-preparation/beta17/build.py` rebuilds only the **stored** payload
  (`source/Support/Autodesk-MCP-Payload.zip`), which is source only and holds no binary. Whenever anything under
  `source/runtime` changes, run it in the same PR (CI "Check stored installer is current" enforces this), then
  revert line-ending churn: `git checkout -- release-preparation/beta17/source/runtime/.agents "release-preparation/beta17/source/Autodesk MCP Skills for Claude.zip"`.
- The release payload (ZIP and setup .exe) adds `bin/SmartConnector.exe`; `tests/test-team-build.ps1` checks that
  the stored payload has none and the release payloads have exactly that one extra file.
- Windows CI (`.github/workflows/connector-tests.yml`) runs every `tests/test-*.ps1`, compiles the Revit add-in
  against the Revit 2024 API reference assemblies from NuGet (references only, never shipped), and runs the
  upgrade test. New tests for the program: `test-smart-connector-exe.ps1` (MCP parity with the PowerShell bridge and
  a stand-in Revit pipe), `-ui.ps1`, `-engine.ps1`, `-skills.ps1`.
- No Windows, PowerShell or Revit/AutoCAD exists in the cloud session. C# is checked with Mono (`mcs -langversion:5`,
  WPF stubbed because Mono lacks `PresentationCore`); the `.ps1` tests only run in CI.
- CI has caught real bugs each time, so expect the first run of new tests to fail once. The ones fixed so far:
  array splatting into `csc` in Windows PowerShell 5.1 (`CS2007`), `%LOCALAPPDATA%` vs the known-folder API, and
  `& program.exe` not capturing output from a GUI-subsystem program.

## What is not verified

- Anything on a real PC: live AutoCAD COM, the Revit named pipe against a real add-in, WPF icon rendering at the
  user's DPI, `startapp` with a path that contains spaces, Task Scheduler COM, DPAPI blob compatibility with
  `ConvertFrom-SecureString`, renaming a running exe aside during an update.
- Whether any of this changes Kaspersky's verdict. Stages 1, A, B and C still leave `.ps1` files in the payload.

## What remains

**Stage D: remove PowerShell from the payload.**
1. Move the `.ps1` files that are only reference or fallback (`installer\*.ps1`, `scripts\*.ps1`, the three bridges,
   `src\revit\build-revit-addin.ps1`) out of `source/runtime` into a folder that is not shipped (for example
   `release-preparation/beta17/legacy/`). The parity tests dot-source them, so point those tests at the new path.
2. Remove the PowerShell fallbacks from the launchers once the program is the only route.
3. `source/Support/Install-Autodesk-MCP-Connector.ps1` (the ZIP installer, `INSTALL Smart Connector.cmd`) is still
   PowerShell. The setup .exe does not carry it, but the release ZIP does. Decide whether the ZIP stays as a
   documented fallback or the ZIP gets a compiled installer too.
4. Build a setup .exe, upload it to OpenTIP (opentip.kaspersky.com) and compare static and dynamic verdicts with 1.1.0.

**Decisions waiting for the owner**
- Ship the Revit add-in prebuilt (compiled in the build against the NuGet reference assemblies, as CI already does)
  instead of compiling on the PC. This removes the last compile-on-PC step but the add-in would no longer be built
  against the installed Revit API. Revit keeps the 2024 API binary-compatible, but it is untested here.
- Contact IT for the exclusion and the code-signing certificate (an email was drafted earlier in the session).
- Publish: nothing has been published to the public `Autodesk-MCP-Releases` repo. Publishing alerts every installed
  PC, so it needs the owner's explicit approval each time. Current public Latest is far behind the repo.

Other outstanding owner actions: revoke any Cloudflare tunnels used by the removed remote gateway; the Notion
dashboard idea (the connector failed to connect in the cloud session, needs reconnecting first).

## Rules that still apply (from AGENTS.md and the session)

- Never commit drawings or models, credentials, user-level Codex config, logs or client project data.
- Never commit or upload the TEAM installer or any `team-join.json` (it is git-ignored; CI refuses it).
- Never merge an intake PR or publish to `main` or the team until the owner approves.
- Every change ends as a pushed branch with a PR to `main`.
