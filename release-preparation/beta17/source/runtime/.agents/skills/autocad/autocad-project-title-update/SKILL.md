---
name: autocad-project-title-update
category: autocad
description: Update AutoCAD project titles in TEXT/MTEXT or drawing custom properties such as PROJ.TITLE, preserving formatting and field links. Use connector tools and authorized background APIs without computer controls; excludes raster titles and unsupported block/xref edits.
---

# AutoCAD project-title update

Update only the requested project-title wording or custom property in the drawings the user names. Prefer the Autodesk MCP connector; no screenshots, mouse or keyboard control, or computer-use tools.

## Dry run first, then ask
Before any write, show the user the list: drawing, object (handle or property key), old text, new text, and what stays unchanged. Wait for an explicit yes. A changed request needs a new list and a new yes. Only "skip the dry run" in the user's current message overrides this.

## Steps
1. Tell literal TEXT/MTEXT from a field linked to a DWG custom property (Drawing Properties > Custom > PROJ.TITLE). A linked field is updated at its source property, never replaced by literal text.
2. For each drawing: `drawing_info`, use its `drawing_id` as `expected_drawing`; respect read-only drawings and locked layers. Find targets across all layouts with `list_entities` (use `layer` and `fields` to keep answers small) and `get_entity`. Match the old title phrase only. Details: [discover targets](references/discover-targets.md).
3. Literal text: record before-values (content, layer, color, height, rotation, position, style), change only the old substring inside the original MTEXT string (keep `\f`, `\C`, `\H`, `\P` codes), re-read just before writing, then `edit_entity` with `replace_text`. Details: [literal text](references/literal-text.md).
4. Custom property: the connector has no write; use the authorized ActiveX helper, snapshot all keys, set only the requested key, verify the other keys unchanged. Details: [custom properties](references/custom-properties.md).
5. Verify with a separate read after each edit, process drawings one at a time, report counts, skipped files and what stayed unsaved. Save only when the user asks. Details and past runs: [verify and demonstrated behaviour](references/verify-and-demonstrated.md).
