# AutoCAD bridge setup

## Expected environment

- Windows
- Full AutoCAD for Windows with ActiveX automation, running in the same Windows user session as Codex
- A registered version-specific AutoCAD COM identifier. The bridge discovers the current and installed ProgIDs dynamically and does not hardcode one release.
- Repository trusted by Codex so `.codex/config.toml` is loaded

The project configuration starts `src/autocad/autocad-bridge.ps1` from the repository root. It uses relative paths and should work from any clone location.

## Diagnose

1. Confirm a full Windows AutoCAD release is open with a drawing. AutoCAD LT and AutoCAD for Mac do not expose the required ActiveX interface.
2. In Codex, inspect `/mcp` or MCP settings for `autocad`.
3. Restart Codex after cloning or configuration changes.
4. Call `drawing_info` before declaring the connection broken.
5. If project configuration is ignored, confirm the repository is trusted.

A sandboxed shell can fail to access AutoCAD COM even when the MCP process succeeds. Prefer the MCP `drawing_info` result as the connection test.

## Tests

Run `src/autocad/work/test-bridge.ps1` for protocol validation and mock object-model tests. Mock tests do not prove a live AutoCAD connection. Perform live tests only in a disposable blank drawing: record the object count, create and read a small circle, move and read it again, delete that handle, and verify the original count. Leave it unsaved unless saving was requested.

## Live findings

- 2026-11-10, AutoCAD 24.3 (2024, LMS Tech licence), blank unsaved `Drawing1.dwg`: the drawing reports a non-empty `Path` but an empty `FullName`. The old rule (unsaved when `Path` is empty) therefore returned a blank `drawing_id`, and every `expected_drawing` was refused. The id is now the full path when `FullName` is a drive or network path, and the drawing name otherwise. If a tool says the active drawing changed, run `drawing_info` and use its `drawing_id` exactly.
- 2026-11-10, AutoCAD 24.3 (2024): `GetVariable("HANDSEED")` fails over COM with "Error getting system variable". Do not rely on `HANDSEED`; other variables such as `DBMOD` and `INSUNITS` read fine. Code that calls `GetVariable` should treat any variable as possibly unreadable.
- Drive the installed connector directly to test it without an AI app: start `SmartConnector.exe mcp` with redirected input and output, send `initialize`, `notifications/initialized`, then `tools/call` messages, one JSON object per line. Read each answer with a time limit.
