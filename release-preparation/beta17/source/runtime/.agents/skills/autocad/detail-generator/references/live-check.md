# Live check of the Detail Generator (paper space and custom_section)

Run in a **disposable millimetre drawing** (template `acadiso.dwt`) with AutoCAD 2024 open. Nothing here has been run live yet; every line below is something to confirm.

## Set-up

1. **Install the current connector** (the setup exe built from `main`) and restart the AI app.
2. New drawing from `acadiso.dwt`, left unsaved. `INSUNITS` must be 4. Run `drawing_info` and note the drawing id (the tab name, such as `Drawing1.dwg`, while unsaved).
3. Leave `Layout1` as it is. The ISO template's own viewport stays; the tool adds its own viewport for the detail.
4. Optional, for reference styles: copy a dimension and a text from a reference sheet so `na1`, `EN-S` and `EN-SCB` exist. Without them the result says so in `style_notes`.

## Checks, in order

| # | Call | Confirm |
|---|---|---|
| 1 | `generate_detail` `annotation: "paper"`, `layout: "Layout1"`, `create_viewport: true`, `apply: true`, `expected_drawing`, default `dry_run` | `applied` false, `plan_result` and `paper_plan_result` valid, nothing drawn. `paper_centre_source` names the sheet centre; `viewport` shows centre, size (about 80 x 110 mm), scale 1:10, `view_centre` 300, 451, layer G-ANNO-VPRT |
| 2 | Same with `dry_run: false` | `applied` true, both `count_matches_plan` true, `viewport_result` with `custom_scale` 0.1 and `display_locked` true. Model space: geometry only. `Layout1`: a new viewport showing the section, with the dimensions reading **900, 600, 100** and 2.5 mm notes **sitting exactly on the section's edges**. The viewport border is on G-ANNO-VPRT and does not plot (check Plot Preview) |
| 3 | `U` three times | Viewport, then annotation, then geometry disappear (three undo groups) |
| 4 | Step 2 with `level_block` set to a block that has a `LEVEL` attribute | Level text fills the attribute. A wrong tag must fail the annotation and leave nothing in the layout |
| 5 | `annotation: "none"` | Parts and hatches only |
| 6 | `custom_section` with the example in `reception-counter-section.md` (model-space annotation) | Parts, hatches (glass outline only), notes and dimensions as given |
| 7 | Same with `annotation: "paper"` and `create_viewport: true` | Dimensions in the layout read the model sizes and line up |
| 8 | Without `create_viewport`, against a viewport you made yourself (`view.paper_centre` = its Center, view zoomed to `model_centre`, 1:10) | Same alignment: the manual route still works |

## Things that may fail

- **Dimension factor:** if `LinearScaleFactor` is refused or does not read back, the annotation is rolled back with a message that says the geometry stays; tell me the exact message.
- **Viewport:** the tool centres the view by zooming before setting the scale, and AutoCAD cannot read the centre back. If the annotation is the right size but shifted, the centring did not take: report the shift (screenshot) and the `viewport_result`. If the viewport cannot be made at all, it is removed and the message says the geometry and annotation stay.
- **Sheet centre:** the default centre comes from the paper size and can sit a few millimetres off the true sheet centre because of printer margins. Pass `view.paper_centre` to place the detail exactly.
- Report anything that looks different from what is listed, with a screenshot of the layout.
