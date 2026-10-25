---
name: autocad-project-title-update
description: Update AutoCAD project titles in TEXT/MTEXT or drawing custom properties such as PROJ.TITLE, preserving formatting and field links. Use connector tools and authorized background APIs without computer controls; excludes raster titles and unsupported block/xref edits.
---

# AutoCAD project-title update

Update only the requested project-title wording or custom property in the user's specified drawings. Prefer the Autodesk MCP connector for supported edits; use the authorized non-UI API path below for custom properties that the connector cannot edit. Do not use screenshots, mouse/keyboard control, or computer-use tools for this workflow. User-supplied screenshots may identify the title source without controlling the computer.

First distinguish literal TEXT/MTEXT from a field linked to a DWG custom property. If the user identifies Drawing Properties > Custom > PROJ.TITLE, update that source property instead of replacing field-bearing text with a literal value. Use the custom-property path below; layout text enumeration is not required merely to change the property.

## Discover the targets

- Confirm the source folder or drawing set from the user's request. Inventory DWG files and record files with no matching title separately from files that could not be inspected. Do not collect adjacent client files for a skill package.
- Discover the actual connector tools. The current narrow AutoCAD tool set has no drawing-open or activate command. Where available and authorized, a local non-UI file/session helper may open or activate the specified drawings and perform supplemental reads. Otherwise report this capability gap and request that the next drawing be opened; do not claim every file was processed. Never use a helper to bypass connector write approvals.
- After each drawing activation, call `drawing_info`. Bind every edit to its fresh `drawing_id` as `expected_drawing`. Respect read-only drawings and locked layers; a handle is meaningful only in its own drawing.
- Enumerate all relevant layouts, following `list_entities` pagination, and inspect candidate objects with `get_entity` and their layers with `list_layers`. A matching title can occur on several layouts. Top-level enumeration does not expand blocks or xrefs; report this limit when relevant. Do not explode blocks or rewrite xref definitions to make a title editable.
- Match the old project-title phrase, not every occurrence of a brand name. Leave room labels, activity names, legends, drawing numbers, and unrelated text unchanged. Use the exact requested replacement, including spelling, punctuation, and capitalization, unless the user has authorized a presentation convention.

## Literal TEXT/MTEXT

Capture a local before-record keyed by drawing path and handle: original content, entity type, layer, color, height, rotation, insertion point, and any exposed text style, width, attachment/alignment, or line-spacing properties. Supplemental non-UI API reads may supply properties that the connector omits. Do not claim verification of properties that were unavailable.

For MTEXT, change only the literal project-name substring inside the original `TextString`. Preserve formatting groups and controls, including font runs (`\f...;`), color (`\C...;`), height overrides (`\H...;`), paragraph/alignment settings, and intentional paragraph breaks (`\P`). Escape backslashes as required by the tool-call serialization; do not add literal duplicate backslashes to the stored text. Replacing the entire formatted string with plain text loses inline styling even when the entity's style name is unchanged.

Immediately before writing, re-read the object and confirm that its text still matches the before-record. Use `edit_entity` with `action: replace_text` and the complete original formatted string containing only the requested wording substitution. Keep the existing height, width, position, alignment, font, and color. Do not shrink or move the title simply because the new name is longer. Report any demonstrated fit problem separately.

Process drawings and mutations sequentially; the active drawing can change between calls. After a failed or interrupted write, re-read the identity and target before deciding whether to retry. Undo groups are not atomic transactions.

## Custom properties and background updates

The narrow connector tool set used in the verified workflow does not expose custom-property writes. Discover current tools first. If still absent, explain the gap and use an authorized AutoCAD ActiveX API helper; this is a separate property capability, not a substitute for a denied connector edit. Do not use UI automation or alter unrelated custom properties.

1. Inventory the requested drawings and explicitly excluded files. Bind each open document by its exact current `FullName`, check `ReadOnly`, and snapshot every custom key/value through `SummaryInfo.NumCustomInfo()` and `GetCustomByIndex`. Do not assume all files contain the same old project name. If the user requests one replacement only, match that value; if they request standardizing PROJ.TITLE throughout the set, target that key regardless of its old value.
2. Read `PROJ.TITLE` again with `GetCustomByKey`. Stop on an unexpected change since inspection, a missing or ambiguous key, or a newly read-only document. Preserve user exclusions even if a file becomes writable later.
3. Set only the exact requested key with `SummaryInfo.SetCustomByKey(key, replacement)`. Preserve field expressions, entity formatting, other properties, and existing drawing names. Do not change related project codes or drawing numbers merely because they look outdated.
4. In a separate read pass, verify the replacement, unchanged custom-property count, and unchanged values for every other key. Regenerate eligible documents using `Document.Regen(1)` where available. Check whether the existing `FIELDEVAL` value includes bit 16 for evaluation on regeneration; do not change that setting silently. Regeneration alone does not prove every displayed field or visual fit was inspected.
5. Keep persistence explicit. In the verified run, `Document.Saved` often remained true after `SetCustomByKey`; that flag alone cannot prove that custom-property changes reached disk. Report whether a Save operation actually occurred. When saving is authorized, verify the saved result with a supported independent read where possible, without discarding other unsaved edits.

Already-open documents can be edited and regenerated through their API objects without opening or activating tabs. Respect a request for background-only processing: do not call `Documents.Open` or `Activate` merely to simplify a loop. If a target is closed, use a separately verified ObjectDBX/side-database capability or report the capability gap. Do not call already-open-document editing an offline or closed-file workflow. Do not close drawings or overwrite their on-disk versions when unsaved work could be lost.

If a modal Drawing Properties dialog causes `RPC_E_CALL_REJECTED`, ask the user to close it, then retry the read. Retry loading/busy errors with a bounded wait and reinspection; do not repeatedly issue a failed write or dismiss dialogs with computer controls.

## Verify and finish

- For literal text edits, use a separate `get_entity` read after each edit. Confirm the exact replacement and compare the available formatting and position properties to the before-record. Compare floating-point properties with a small tolerance, for example `1e-7` drawing units, rather than exact JSON decimal equality.
- Where the API exposes additional MTEXT properties or bounding boxes, verify those without UI automation. A successful text readback proves content and the compared properties, not the absence of visual overlap. A display may need regeneration; use an exposed API capability if available and report any remaining display/fit uncertainty without starting computer controls.
- Check remaining old-title matches within the inspected scope. Report updated title count, updated drawing count, unchanged files, and any skipped or unsupported targets.
- Save DWGs only when the user has requested saving them; saving or publishing this skill does not authorize drawing saves. If drawing saving is already authorized, do not ask again. `save_drawing` writes the whole active drawing, including unrelated unsaved changes. Verify persistence separately and state clearly when changes remain open and unsaved.

## Demonstrated behavior

Live AutoCAD verification on 2026-10-25 updated 19 MTEXT project titles across 13 drawings through connector `replace_text` calls. Separate API reads confirmed content and preservation of font formatting, height, color controls, style, width, attachment, rotation, and position. A fourteenth drawing had no matching project-title phrase. The drawings were left unsaved. The final visual check was interrupted, and the user requested no computer controls; visual fit and saved-file persistence were not verified. These counts are evidence of a past run, never a target list for future edits.

A subsequent live run on the same date updated PROJ.TITLE in 13 already-open drawings through `SummaryInfo.SetCustomByKey`, verified all other custom values were unchanged, and independently re-read the replacements. One read-only drawing was excluded at the user's request. API regeneration completed with regeneration field evaluation enabled and the active document unchanged. No Save operation or computer controls were used. Closed-file ObjectDBX editing and saved-file persistence were not tested.
