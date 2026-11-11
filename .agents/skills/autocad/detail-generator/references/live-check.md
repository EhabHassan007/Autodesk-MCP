# Live check of the Detail Generator (paper space and custom_section)

Run in a **disposable millimetre drawing** (template `acadiso.dwt`) with AutoCAD 2024 open. Nothing here has been run live yet; every line below is something to confirm.

## Set-up

1. `drawing_info`: note the drawing id and that `units_code` is 4.
2. Rename or use `Layout1`. Draw one viewport (`MVIEW`), scale it to **1:10** (`1/10xp`), and make it show the area where the section will be drawn (origin 0,0 is fine; pan the view roughly onto 300, 450 and zoom to 1/10xp).
3. Optional, for reference styles: insert a drawing that has dimension style `na1` and text styles `EN-S` and `EN-SCB`. Without them the result says so in `style_notes`.

## Checks, in order

| # | Call | Confirm |
|---|---|---|
| 1 | `generate_detail` `annotation: "paper"`, `layout: "Layout1"`, `view: {paper_centre: [200,150]}`, `apply: true`, `expected_drawing`, default `dry_run` | `applied` false, `plan_result` and `paper_plan_result` valid, nothing drawn; read `viewport_warning` (none if the viewport is at 1:10) and `viewport_setup` |
| 2 | Same with `dry_run: false` | `applied` true, both `count_matches_plan` true. Geometry in model space; open `Layout1`: dimensions read **900, 600, 100** (the model sizes) and notes are 2.5 mm tall. Check the annotation lines up with the section in the viewport (if not, the viewport's view centre differs from `model_centre`; pan it) |
| 3 | `U` twice | Annotation, then geometry, disappear (two undo groups) |
| 4 | Step 2 with `level_block` set to a block that has a `LEVEL` attribute | Level text fills the attribute. A wrong tag must fail the annotation and leave nothing in the layout |
| 5 | `annotation: "none"` | Parts and hatches only |
| 6 | `custom_section` with the example in `reception-counter-section.md` (model-space annotation) | Parts, hatches (glass outline only), notes and dimensions as given |
| 7 | Same with `annotation: "paper"` | Dimensions in the layout read the model sizes |

## Things that may fail

- **Dimension factor:** if `LinearScaleFactor` is refused or does not read back, the annotation is rolled back with a message that says the geometry stays; tell me the exact message.
- **Viewport:** AutoCAD does not let the tool set the viewport's view centre, so a misaligned viewport is a set-up issue, not a drawing error.
- Report anything that looks different from what is listed, with a screenshot of the layout.
