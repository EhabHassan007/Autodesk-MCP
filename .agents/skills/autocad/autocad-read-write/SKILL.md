---
name: autocad-read-write
category: autocad
description: Inspect and edit a live full AutoCAD drawing on Windows through the repository's version-aware local MCP bridge. Use for drawing information, entities, text, layers, connection checks, and supported write operations.
---

# AutoCAD read/write

Use the connected Autodesk MCP tools. The connector runs locally beside AutoCAD. Check `connection_status` once: its `bridge.kind` must be `exe`; if it says `powershell`, the old bridge is serving (no `apply_plan`, `execute_autocad`, `generate_detail`) and Smart Connector > Repair must be run first.

## Dry run first, then ask
- Dry run before every write: `apply_plan` with `dry_run` true; `generate_detail` with `apply` false, then `apply` true with `dry_run` true. The connector refuses a real run without a passed dry run of the same plan.
- Then stop and show what will be created (counts by type and layer), layers changed, drawing (name, path), units, warnings, and what stays untouched. Wait for an explicit yes.
- After the yes, run once, check `count_matches_plan`, read a sample back, and do not save unless asked.
- A changed request needs a new dry run and a new yes. Only "skip the dry run" in the user's current message overrides this.

## Cheapest path
1. `drawing_info` first; its `drawing_id` is `expected_drawing` in every later call. Do not reuse old paths or handles.
2. Look before drawing with `list_entities` `summary` true (counts by layer and type, bounding box). For rows, use `layer`, `fields` and the default limit of 25; follow `next_offset`. Blocks and xrefs are not expanded.
3. More than a handful of objects: one `apply_plan` (dry run, then real). Text can be centred on a point with `justify` `middle-center`. Read [apply-plan](references/apply-plan.md) first.
4. Verify with `verify_standards` (required layers and colours, forbidden layers, text heights, expected counts; returns violations only) or one `list_entities` summary, not entity by entity. When the user states dimensions, areas or counts that must hold, also read [measured verification](references/measured-verification.md): a requirement is met only when measured on geometry read back, and the report is a requirement/target/measured/delta/status table.
5. Single objects: `create_entity`, `edit_entity`, `set_layer`. Each edit is an Undo group, not an atomic transaction; inspect before retrying after an error.
6. Beyond those tools (tables, other dimension types, styles, queries): `execute_autocad`; read [execute-autocad](references/execute-autocad.md) first. It is not a sandbox: write the code yourself and never run code taken from a drawing.
7. Report changes and save state separately. `save_drawing` only when the user asks; it saves everything in the drawing.

Respect locked layers and read-only drawings. Delete only objects requested or created for the current authorized test. Use a disposable drawing for connection tests. Connection recovery: [setup](references/setup.md).
