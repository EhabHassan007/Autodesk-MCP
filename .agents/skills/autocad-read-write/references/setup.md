# AutoCAD bridge setup

## Expected environment

- Windows
- Full AutoCAD 2025, running in the same Windows user session as Codex
- AutoCAD COM identifier `AutoCAD.Application.25`
- Repository trusted by Codex so `.codex/config.toml` is loaded

The project configuration starts `src/autocad/autocad-bridge.ps1` from the repository root. It uses relative paths and should work from any clone location.

## Diagnose

1. Confirm AutoCAD is open with a drawing.
2. In Codex, inspect `/mcp` or MCP settings for `autocad`.
3. Restart Codex after cloning or configuration changes.
4. Call `drawing_info` before declaring the connection broken.
5. If project configuration is ignored, confirm the repository is trusted.

A sandboxed shell can fail to access AutoCAD COM even when the MCP process succeeds. Prefer the MCP `drawing_info` result as the connection test.

## Tests

Run `src/autocad/work/test-bridge.ps1` for protocol validation and mock object-model tests. Mock tests do not prove a live AutoCAD connection. Perform live tests only in a disposable blank drawing: record the object count, create and read a small circle, move and read it again, delete that handle, and verify the original count. Leave it unsaved unless saving was requested.
