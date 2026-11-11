# Live check of the Detail Generator (paper space and custom_section)

Run in a **disposable millimetre drawing** (template `acadiso.dwt`) with AutoCAD 2024 open. Nothing here has been run live yet; every line below is something to confirm.

## Set-up

1. **Install the current connector** (the setup exe built from `main`) and restart the AI app, so `generate_detail` has the `annotation`, `layout` and `view` options.
2. New drawing from `acadiso.dwt`. `INSUNITS` must be 4. Run `drawing_info` and note the drawing id (full path when saved, the tab name such as `Drawing1.dwg` when not).
3. Open `Layout1` and select its viewport (the ISO template has one). In Properties set **Standard scale** to `1:10` (Custom scale 0.1).
4. Read the viewport's **Center X** and **Center Y** (Properties, Geometry). These are `view.paper_centre`. They are not fixed values: the annotation is placed around this point, so it must be the real viewport centre. The AI can read them instead, with `execute_autocad` in read mode (viewport `Center` and `CustomScale`).
5. Double-click inside the viewport and `ZOOM` > `C` > `300,451` > Enter. That is the centre of the parts of the default section drawn at origin 0,0 (the result's `model_centre` confirms it). Other sections have other centres: run the dry run first and use its `model_centre`.
6. Select the viewport again and re-enter `1:10` (the zoom may have changed it; setting the scale keeps the view centre). Set **Display locked** to Yes and return to paper space.
7. The section is about 60 x 90 mm on paper and the annotation reaches about 80 mm to the left and 120 mm to the right of it, so leave that room around the viewport.
8. Optional, for reference styles: copy a dimension and a text from a reference sheet so `na1`, `EN-S` and `EN-SCB` exist. Without them the result says so in `style_notes`.

## Checks, in order

| # | Call | Confirm |
|---|---|---|
| 1 | `generate_detail` `annotation: "paper"`, `layout: "Layout1"`, `view: {paper_centre: [Center X, Center Y]}` (from set-up step 4), `apply: true`, `expected_drawing`, default `dry_run` | `applied` false, `plan_result` and `paper_plan_result` valid, nothing drawn; read `viewport_warning` (none if the viewport is at 1:10) and `viewport_setup` |
| 2 | Same with `dry_run: false` | `applied` true, both `count_matches_plan` true. Geometry in model space; open `Layout1`: dimensions read **900, 600, 100** (the model sizes) and notes are 2.5 mm tall. Check the annotation lines up with the section in the viewport. Right size but shifted means the viewport's view centre differs from `model_centre` or `paper_centre` differs from the viewport centre: repeat set-up steps 4 to 6, not the generator |
| 3 | `U` twice | Annotation, then geometry, disappear (two undo groups) |
| 4 | Step 2 with `level_block` set to a block that has a `LEVEL` attribute | Level text fills the attribute. A wrong tag must fail the annotation and leave nothing in the layout |
| 5 | `annotation: "none"` | Parts and hatches only |
| 6 | `custom_section` with the example in `reception-counter-section.md` (model-space annotation) | Parts, hatches (glass outline only), notes and dimensions as given |
| 7 | Same with `annotation: "paper"` | Dimensions in the layout read the model sizes |

## Things that may fail

- **Dimension factor:** if `LinearScaleFactor` is refused or does not read back, the annotation is rolled back with a message that says the geometry stays; tell me the exact message.
- **Viewport:** AutoCAD does not let the tool set the viewport's view centre, so a misaligned viewport is a set-up issue (steps 4 to 6), not a drawing error.
- Report anything that looks different from what is listed, with a screenshot of the layout.
