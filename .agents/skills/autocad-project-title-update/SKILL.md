---
name: autocad-project-title-update
description: Replace project names in AutoCAD TEXT and MTEXT title blocks across specified DWG files while preserving text formatting. Use the Autodesk MCP connector without computer UI automation; excludes raster titles, block attributes, and xref edits unless supported tools are available.
---

# AutoCAD project-title update

Update only the requested project-title wording in the user's specified drawings. Use the Autodesk MCP connector for drawing edits. Do not use screenshots, mouse/keyboard control, or computer-use tools for this workflow.

## Discover the targets

- Confirm the source folder or drawing set from the user's request. Inventory DWG files and record files with no matching title separately from files that could not be inspected. Do not collect adjacent client files for a skill package.
- Discover the actual connector tools. The current narrow AutoCAD tool set has no drawing-open or activate command. Where available and authorized, a local non-UI file/session helper may open or activate the specified drawings and perform supplemental reads. Otherwise report this capability gap and request that the next drawing be opened; do not claim every file was processed. Never use a helper to bypass connector write approvals.
- After each drawing activation, call `drawing_info`. Bind every edit to its fresh `drawing_id` as `expected_drawing`. Respect read-only drawings and locked layers; a handle is meaningful only in its own drawing.
- Enumerate all relevant layouts, following `list_entities` pagination, and inspect candidate objects with `get_entity` and their layers with `list_layers`. A matching title can occur on several layouts. Top-level enumeration does not expand blocks or xrefs; report this limit when relevant. Do not explode blocks or rewrite xref definitions to make a title editable.
- Match the old project-title phrase, not every occurrence of a brand name. Leave room labels, activity names, legends, drawing numbers, and unrelated text unchanged. Use the exact requested replacement, including spelling, punctuation, and capitalization, unless the user has authorized a presentation convention.

## Preserve formatting and edit

Capture a local before-record keyed by drawing path and handle: original content, entity type, layer, color, height, rotation, insertion point, and any exposed text style, width, attachment/alignment, or line-spacing properties. Supplemental non-UI API reads may supply properties that the connector omits. Do not claim verification of properties that were unavailable.

For MTEXT, change only the literal project-name substring inside the original `TextString`. Preserve formatting groups and controls, including font runs (`\f...;`), color (`\C...;`), height overrides (`\H...;`), paragraph/alignment settings, and intentional paragraph breaks (`\P`). Escape backslashes as required by the tool-call serialization; do not add literal duplicate backslashes to the stored text. Replacing the entire formatted string with plain text loses inline styling even when the entity's style name is unchanged.

Immediately before writing, re-read the object and confirm that its text still matches the before-record. Use `edit_entity` with `action: replace_text` and the complete original formatted string containing only the requested wording substitution. Keep the existing height, width, position, alignment, font, and color. Do not shrink or move the title simply because the new name is longer. Report any demonstrated fit problem separately.

Process drawings and mutations sequentially; the active drawing can change between calls. After a failed or interrupted write, re-read the identity and target before deciding whether to retry. Undo groups are not atomic transactions.

## Verify and finish

- Use a separate `get_entity` read after each edit. Confirm the exact replacement and compare the available formatting and position properties to the before-record. Compare floating-point properties with a small tolerance, for example `1e-7` drawing units, rather than exact JSON decimal equality.
- Where the API exposes additional MTEXT properties or bounding boxes, verify those without UI automation. A successful text readback proves content and the compared properties, not the absence of visual overlap. A display may need regeneration; use an exposed API capability if available and report any remaining display/fit uncertainty without starting computer controls.
- Check remaining old-title matches within the inspected scope. Report updated title count, updated drawing count, unchanged files, and any skipped or unsupported targets.
- Save only when the user has requested saving. If saving is already authorized, do not ask again. `save_drawing` writes the whole active drawing, including unrelated unsaved changes. Verify save state separately and state clearly when changes remain open and unsaved.

## Demonstrated behavior

Live AutoCAD verification on 2026-10-25 updated 19 MTEXT project titles across 13 drawings through connector `replace_text` calls. Separate API reads confirmed content and preservation of font formatting, height, color controls, style, width, attachment, rotation, and position. A fourteenth drawing had no matching project-title phrase. The drawings were left unsaved. The final visual check was interrupted, and the user requested no computer controls; visual fit and saved-file persistence were not verified. These counts are evidence of a past run, never a target list for future edits.
