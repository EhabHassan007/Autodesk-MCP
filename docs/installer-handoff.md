# Installer handoff: moving Smart Connector from PowerShell to a compiled program

Status as of 2026-11-09. Work continues on branch `smart-connector-next` (from `main-70886s`). Merged up to PR #54; PR #55 (Notion sync) is open.

**Headline:** the script-free setup .exe was rated **Clean** by OpenTIP on 2026-11-08 (0 detections, 1 low suspicious activity), against 1 detection and 6 suspicious for 1.1.0 with scripts. The PowerShell content was the trigger.

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
| #48–#50 | Stage B: install engine (`engine`). Stage C: Skills Sync and usage scripts (`skills`). Windows test fixes (PS 5.1 quirks, `--program-files` test option because Windows ignores a ProgramFiles override for child processes). |
| #51 | Setup .exe installs no script: build strips `.ps1/.cmd/...` outside `.agents`; product checks for `bin\SmartConnector.exe`, not scripts; CI installs the setup silently and runs it. OpenTIP: Clean. |
| #53 | One installer (setup .exe opens the Setup window itself), team email + typed team code in normal setup, skills and update checks always on, PATH refresh so Claude Code/Codex are found, Claude Desktop hang fix, Revit ribbon icons drawn at slot size (CI checks sizes). |
| #54 | No Start-menu folder page, no closing programs (running exe renamed to `.old`, deleted at next start; CI installs over a running copy), ChatGPT Desktop connected through `%USERPROFILE%\.codex\config.toml`, terms of use 2026-11-08. |
| #55 (open) | Hourly Notion sync of the dashboard from the Cloudflare service (Team members, Skills and tools usage). |

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

- On a real PC: live AutoCAD COM and the Revit pipe against a real add-in, DPI rendering, AutoCAD `AI`/`AICLEAR` after
  the new setup, ChatGPT Desktop picking up `config.toml` (community reports: tools may show only in Codex mode on
  Windows), Kaspersky on the company PCs (OpenTIP is not the company policy).
- The real Notion API and the deployed hourly cron (PR #55 is tested against a stand-in).
- OpenTIP has not yet seen the newest setup .exe, which now opens the installed program after copying.

## What remains

**Owner actions**
1. Install the newest setup .exe on a PC (artifact of the latest "Build setup exe" run), check Revit's tab, AutoCAD's
   `AI`/`AICLEAR`, ChatGPT Desktop's Codex MCP list; upload the same file to OpenTIP.
2. Notion sync (after merging #55): create an internal integration (notion.so/my-integrations), add it to the page
   "Smart Connector – Team Insights" (••• → Connections), `npx wrangler secret put NOTION_TOKEN`, `npm run migrate:remote`,
   `npm run deploy`, then `POST /admin/api/notion-sync`. Notion page:
   https://app.notion.com/p/4125a80a6f4f812484d3e86894e3e30b (data sources: members
   `c05261ca-cde9-4efd-bc8c-73be82269d46`, usage `369aab91-4554-42c4-9754-401299888a3f`).
3. Review the terms of use 2026-11-08 with legal/HR (still DRAFT).

**Decisions waiting for the owner**
- **Update channel.** PCs on older versions update with the old PowerShell updater, which needs the scripts in the
  release ZIP; a script-free release would break them. Recommended: hand out 1.1.0 once as the setup .exe; from 1.1.0
  the compiled program reads a new manifest (e.g. `smart-connector.json`) and installs script-free releases; leave
  `latest.json` alone. Then make the release ZIP payload script-free and have setup delete scripts left by old versions.
- **Skill review in Notion** (approve/reject + category in a Notion database, applied by the service hourly), so the
  Cloudflare admin page is never needed.
- Ship the Revit add-in prebuilt instead of compiling on each PC (removes the last compile-on-PC step).
- Publish: nothing is published to the public `Autodesk-MCP-Releases` repo; it needs the owner's approval each time.

**Engineering left**
- Stage D proper: move the PowerShell scripts out of `source/runtime` into a non-shipped folder used by the parity
  tests, and drop the PowerShell fallbacks.
- The ZIP installer route (`INSTALL Smart Connector.cmd` / `Install-Autodesk-MCP-Connector.ps1`) is still PowerShell.

Notion is the dashboard; Cloudflare stays the secure backend (per-PC tokens, GitHub App key, usage intake) on the
Free plan. Notion cannot replace it safely: every PC would need one shared Notion key with access to everyone's data.

## Rules that still apply (from AGENTS.md and the session)

- Never commit drawings or models, credentials, user-level Codex config, logs or client project data.
- Never commit or upload the TEAM installer or any `team-join.json` (it is git-ignored; CI refuses it).
- Never merge an intake PR or publish to `main` or the team until the owner approves.
- Every change ends as a pushed branch with a PR to `main`.
