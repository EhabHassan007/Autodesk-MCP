# Live check of the Detail Generator (paper space and custom_section)

Run in a **disposable millimetre drawing**: first the blank template `acadiso.dwt`, then, for the office-standard checks 9 to 12, a copy of a reference counter sheet or the office template (it has the office layers and the `Multiple Leader Lab`, `level indicator` and `DWG-VIEWTITLE` blocks) with AutoCAD 2024 open. Nothing here has been run live yet; every line below is something to confirm.

## Set-up

1. **Install the current connector** (the setup exe built from `main`) and restart the AI app.
2. New drawing from `acadiso.dwt`, left unsaved. `INSUNITS` must be 4. Run `drawing_info` and note the drawing id (the tab name, such as `Drawing1.dwg`, while unsaved).
3. Leave `Layout1` as it is. The ISO template's own viewport stays; the tool adds its own viewport for the detail.
4. Optional, for reference styles: copy a dimension and a text from a reference sheet so `na1`, `EN-S` and `EN-SCB` exist. Without them the result says so in `style_notes`.

## Checks, in order

| # | Call | Confirm |
|---|---|---|
| 1 | `generate_detail` `annotation: "paper"`, `layout: "Layout1"`, `create_viewport: true`, `apply: true`, `expected_drawing`, default `dry_run` | `applied` false, `plan_result` and `paper_plan_result` valid, nothing drawn. `paper_centre_source` names the sheet centre; `viewport` shows centre, size (about 80 x 110 mm), scale 1:10, `view_centre` 300, 451, layer G-ANNO-VPRT |
| 2 | Same with `dry_run: false` | `applied` true, both `count_matches_plan` true, `viewport_result` with `method` (zoom or target), `custom_scale` 0.1, `display_locked` true and `view_centre_read_back` true with `view_centre` 300, 451. No `viewport_error`. Model space: geometry only. `Layout1`: a new viewport showing the section, with the dimensions reading **900, 600, 100** and 2.5 mm notes **sitting exactly on the section's edges**. The viewport border is on G-ANNO-VPRT and does not plot (check Plot Preview) |
| 3 | Type `U` three times **in AutoCAD yourself** (an AI's `U` sent as a command does not run) | Viewport, then annotation, then geometry disappear (three undo groups) |
| 4 | Step 2 with `level_block` set to a block that has a `LEVEL` attribute | Level text fills the attribute. A wrong tag must fail the annotation and leave nothing in the layout |
| 5 | `annotation: "none"` | Parts and hatches only |
| 6 | `custom_section` with the example in `reception-counter-section.md` (model-space annotation) | Parts, hatches (glass outline only), notes and dimensions as given |
| 7 | Same with `annotation: "paper"` and `create_viewport: true` | Dimensions in the layout read the model sizes and line up |
| 8 | Without `create_viewport`, against a viewport you made yourself (`view.paper_centre` = its Center, view zoomed to `model_centre`, 1:10) | Same alignment: the manual route still works |
| 9 | In the office template, `custom_section` paper mode with `levels` given as `elevation` + `description`, `sheet {project, sheet_no, view_no}`, `layer_scheme` left on auto | `generated.summary.layer_scheme` is `ao`; sections on `AO-MDF_SECTION_PLAN`, `AO-CORIAN C-TOP` and so on; no `A-DETL*` layers created |
| 10 | Same, applied | Each note is a `Multiple Leader Lab` block with the arrow on the section edge and the text wrapped at 45 mm; no bare lines. Report any leader pointing the wrong way or with a wrong length (screenshot) |
| 11 | Same | Each level is a `level indicator` with `EL +0.75` in LEVEL and `WORKTOP` in Area; the title is a `DWG-VIEWTITLE` with the sheet fields filled |
| 12 | Blank template (no office blocks) | Native multileaders with arrowheads, text indicators, a warning for each missing block; still no bare lines |

## Things that may fail

- **Dimension factor:** if `LinearScaleFactor` is refused or does not read back, the annotation is rolled back with a message that says the geometry stays; tell me the exact message.
- **Viewport:** the tool reads the view centre back and corrects it. If `view_centre_read_back` is false (AutoCAD did not answer the read-only query), check by eye that the section sits in the middle of the viewport and report a shift with a screenshot. If the viewport cannot be made at all, the result carries `viewport_error` and `viewport_next_step`; the geometry and annotation stay.
- **Sheet centre:** the default centre comes from the paper size and can sit a few millimetres off the true sheet centre because of printer margins. Pass `view.paper_centre` to place the detail exactly.
- Report anything that looks different from what is listed, with a screenshot of the layout.
