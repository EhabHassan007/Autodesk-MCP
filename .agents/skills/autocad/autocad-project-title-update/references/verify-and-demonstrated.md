# Verify, finish, and demonstrated behaviour

- For literal text edits, use a separate `get_entity` read after each edit. Confirm the exact replacement and compare the available formatting and position properties to the before-record. Compare floating-point properties with a small tolerance, for example `1e-7` drawing units, rather than exact JSON decimal equality.
- Where the API exposes additional MTEXT properties or bounding boxes, verify those without UI automation. A successful text readback proves content and the compared properties, not the absence of visual overlap. A display may need regeneration; use an exposed API capability if available and report any remaining display/fit uncertainty without starting computer controls.
- Check remaining old-title matches within the inspected scope. Report updated title count, updated drawing count, unchanged files, and any skipped or unsupported targets.
- Save DWGs only when the user has requested saving them; saving or publishing this skill does not authorize drawing saves. If drawing saving is already authorized, do not ask again. `save_drawing` writes the whole active drawing, including unrelated unsaved changes. Verify persistence separately and state clearly when changes remain open and unsaved.

## Demonstrated behavior

Live AutoCAD verification on 2026-10-25 updated 19 MTEXT project titles across 13 drawings through connector `replace_text` calls. Separate API reads confirmed content and preservation of font formatting, height, color controls, style, width, attachment, rotation, and position. A fourteenth drawing had no matching project-title phrase. The drawings were left unsaved. The final visual check was interrupted, and the user requested no computer controls; visual fit and saved-file persistence were not verified. These counts are evidence of a past run, never a target list for future edits.

A subsequent live run on the same date updated PROJ.TITLE in 13 already-open drawings through `SummaryInfo.SetCustomByKey`, verified all other custom values were unchanged, and independently re-read the replacements. One read-only drawing was excluded at the user's request. API regeneration completed with regeneration field evaluation enabled and the active document unchanged. No Save operation or computer controls were used. Closed-file ObjectDBX editing and saved-file persistence were not tested.
