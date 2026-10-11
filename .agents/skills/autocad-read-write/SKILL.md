---
name: autocad-read-write
description: Inspect and edit a live full AutoCAD 2025 drawing on Windows through the repository's local MCP bridge. Use for drawing information, entities, text, layers, connection checks, and supported write operations.
---

# AutoCAD read/write

Use the connected `autocad` MCP tools. The bridge runs locally beside AutoCAD; GitHub only distributes its source and configuration.

1. Call `drawing_info` before every editing task. Use the returned `drawing_id` as `expected_drawing`; do not reuse historical paths or handles.
2. Inspect the relevant layers and objects with `list_layers`, `list_entities`, and `get_entity`. Follow pagination and remember that blocks and xrefs are not expanded.
3. Perform requested edits within the user's authorization. Verify meaningful changes with readback using returned handles.
4. Treat each edit as an Undo group, not an atomic transaction. After an error, inspect the drawing before retrying.
5. Report changes and save state separately. Call `save_drawing` only when the user requests a save; it saves the whole active drawing, including unrelated unsaved changes.

Supported writes include creating lines, circles, and single-line text; moving or deleting top-level entities; changing an entity layer; replacing TEXT/MTEXT content; setting a circle radius; and creating or changing layers.

Respect locked layers and read-only drawings. Only delete requested objects or objects created for the current authorized test. Use a disposable blank drawing for connection tests and restore its original object count. Never clear an existing user drawing for testing.

For connection recovery and local verification, read [setup](references/setup.md).
