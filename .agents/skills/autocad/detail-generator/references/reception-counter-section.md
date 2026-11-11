# Template: reception_counter_section

A vertical section through a reception counter, drawn at the chosen scale (default 1:10), millimetres only. Section coordinates: x runs from the staff face (0) to the customer face (depth), y up from the floor.

## Parameters (all in mm; pass them as `params`)

| Parameter | Default | Notes |
|---|---|---|
| `section` | `standard` | `standard` or `accessible` |
| `top_material` | `corian` | `corian` (12 mm on an 18 mm MDF substrate) or `stone` (20 mm on an 18 mm marine plywood backing) |
| `height` | 900 | top of the finished counter; ignored by the accessible section, which uses `accessible_height` |
| `depth` | 600 | outer faces of the end panels |
| `board_thickness` | 18 | all MDF boards and the substrate |
| `plinth_height` | 100 | floor to underside of the bottom panel |
| `plinth_setback` | 50 | from each face to the plinth board |
| `floor_clearance` | 2 | gap under the plinth boards (adjustable legs) |
| `shelf_height` | 450 | underside of the shelf above the floor; 0 for none |
| `top_overhang_staff`, `top_overhang_customer` | 0 | top beyond the end panels |
| `raised_bar` | false | standard section only |
| `bar_rise` | 200 | bar top above the counter top (1100 at the default height) |
| `bar_depth` | 300 | bar run back from the customer face; more than 350 raises a warning |
| `accessible_height`, `knee_clearance_height`, `knee_clearance_depth`, `code_reference` | none | required for `section: accessible`; see below |

Tool arguments: `scale` (denominator, default 10), `origin` (floor at the staff face), `dimension_style`, `text_style`, `dimension_scale` (default: the scale), `apply`, `dry_run`, `update_layers`, `return_plan`.

## What is drawn

- Boards as closed outlines on `A-DETL-WIDE` (cut, 0.50): bottom panel, two end panels up to the underside of the top, optional shelf, top substrate and finish, two plinth boards. Raised bar: the customer-side panel runs up to the underside of the bar, the counter top stops at it, and the bar is a second substrate and finish.
- Hatches on `A-DETL-GENF` (0.09): MDF `ANSI31`, marine plywood `ANSI32`, stone `ANSI36`, Corian solid fill. Pattern scales follow the detail scale. These are standard AutoCAD patterns, so no pattern files are needed.
- Dimensions on `A-ANNO-DIMS` (0.13), all on the left or below so none crosses a note: plinth height, overall height, depth, and for the bar the step and the bar run, for the accessible section the clear height under the top and the knee depth.
- Level markers (F.F.L., counter top, bar top) on the left, notes with horizontal leaders on the customer side, a section title and the scale. Notes use the office wording style: all capitals, thickness first, for example `18MM THK. MDF CARCASS IN MELAMINE FINISH`.
- Layers (office names, this generator's lineweights): `A-DETL-WIDE` 0.50, `A-DETL` 0.25, `A-DETL-THIN` 0.13, `A-DETL-GENF` 0.09, `A-ANNO-DIMS` 0.13, `G-ANNO-TEXT` 0.13, with the office layer colours.

## Annotation and dimension style (from the reference sheets)

Read from three finished reception counter sheets. All three agree.

| Item | Reference |
|---|---|
| Dimension style | `na1`, the only style used on every dimension |
| Dimension text | 3.5 mm on paper, in text style `na1` (a Swiss condensed face), text above the dimension line and aligned with it |
| Arrows | architectural tick, 2.0 mm |
| Extension lines | start 1.5 mm off the object and extend 1.5 mm past the dimension line; dimension spacing 1.5 mm |
| Units | whole millimetres, no decimals |
| Dimension colours | dimension line by block, extension lines grey (8), text green (3) |
| Notes | text style `EN-S` (Swiss), 2.0 to 2.5 mm; the leader notes are blocks with a `LABEL` attribute, 2.5 mm in two sheets and 3.5 mm in the first |
| Titles | `EN-SCB` (Swiss bold), view title block attributes `BOTTOM-TITLE`, `SCALE`, `SHEET-NO`, `TOP-TITLE` |
| Levels | a block with attributes `LEVEL` and `Area` (for example `EL. +0.90`, `COUNTER TOP`) |
| Section markers | a block with attributes `VIEWNUMBER` and `SHEETNUMBER` |
| Where dimensions live | in paper space, over the viewports, with the scale factor of the viewport so the model value shows |

What the generator does with it: it uses `na1`, `EN-S` and `EN-SCB` when the drawing has them, sets notes and levels to 2.5 mm, titles to 3.5 mm, and gives each dimension the detail scale so the 3.5 mm style prints at 3.5 mm. It draws the annotation in model space with the detail, so it works without a sheet.

**Not matched yet:** the level, view title and section marker **blocks** (levels, titles and leaders are drawn as plain lines and text), and paper-space annotation. A later step can insert the office blocks with their attributes, and the sheet-preparation skill places paper-space annotation over viewports.

## The accessible section

A lowered top over the full depth, with only a staff-side box under it and an open knee space on the customer side. It needs four inputs and has no defaults: the height of the lowered top, the minimum clear height under it, the clear depth, and the name and edition of the code they come from. The generator refuses the section if the underside of the top is lower than the clear height asked for, or if the knee depth leaves less than 100 mm of carcass. It prints the code reference on the drawing and marks it "to be verified". A consultant or the authority confirms the values; the generator checks only that the drawing matches what was asked.

## Not drawn yet

Plans and elevations, drawers and shutters, hardware, the raised bar's own support, curved fronts, lighting recesses, creating the layout and title block (the tool annotates a layout that exists; with `create_viewport` it also makes the 1:scale viewport), leaders as blocks (levels can use an office block through `level_block`; leaders are plain lines and text).

## Where the defaults come from

Board thicknesses (18 mm MDF), the 600 depth, the 900 top, the 100 plinth set back 50 and the stone-on-marine-plywood top come from conventions repeated across the office's kitchen and joinery sheets. The 12 mm Corian top and the 200 mm raised bar come from a recent reception counter and from common practice for counters. The curved front, partitions and lighting strip of that counter were treated as specific to it and are not defaults.

## Verification status

- The generator is covered by 71 mock checks: the geometry of each part, dimensions attached to real edges and showing the true distances, both top materials, the raised bar, the accessible section and its refusals, origin and scale handling, deterministic output, and a run through `apply_plan` against a stand-in AutoCAD (millimetre guard, existing layers left alone, a dimension scale on every dimension). The Windows test script covers the argument errors and a plan without AutoCAD.
- Paper-space annotation, geometry-only mode, block attributes and the paper-space dimension factor are covered by 65 further mock checks (a dimension's paper length times its factor equals the model length for every dimension; rollback when a factor or an attribute is refused; a missing layout or block refuses the job before anything is drawn). They, and `custom_section`, have **not** been run in a live AutoCAD: whether the layout dimensions read the model size, whether the viewport lines up with the annotation, and the block attribute fill all need a live check.
- **Live, AutoCAD 24.3 (2024), 2026-11-11, paper mode with `create_viewport`:** the section (17 objects: 8 polylines, 8 hatches, 1 line) and the Layout1 annotation (11 lines, 3 dimensions, 7 texts) were drawn and matched the plan. The first viewport code failed with "There is no active modelspace viewport" and the viewport was rolled back as designed. A probe then showed that switching into the viewport works once a regen follows turning it on (scale read back 0.1), while associating a named model view fails (E_UNEXPECTED). The tool now uses that route, falls back to the Target method of the counter sheets, and reads the centre back. The dimension values and alignment in the layout are still to be confirmed by eye.
- `create_viewport` is covered by 58 mock checks. The stand-in AutoCAD refuses to switch into a viewport without the regen, as the live one did. The checks cover the order of steps, the Target fallback, centre read-back and correction, rollback at each failure point, a running command, and the sheet centre from paper size, units and rotation. Deliberate breakages (no regen, no correction, no Target on the fallback, zoom after scale, no cleanup, no rotation swap) are all caught.
- **The default model-space section is not yet run in a live AutoCAD.** Run a default section in a disposable millimetre drawing first: confirm the dry run, the real run, the look of the hatches and dimensions, the text and dimension sizes at the chosen scale, and that one `UNDO` removes it all. The dimension `scale` property (`ScaleFactor`) is also unconfirmed live; if AutoCAD refuses it the result carries a warning and the dimension style decides the size.
- The accessible section has been checked only for internal consistency, not against any code.

## Template: custom_section

A section built entirely from what the caller supplies, for details the reception template does not cover (display counters, vanities, kitchen units, shelving, anything read off renders and plans).

```json
{
  "template": "custom_section",
  "params": {
    "parts": [
      {"id": "base", "material": "mdf", "x0": 0, "y0": 100, "x1": 600, "y1": 118},
      {"id": "top",  "material": "corian", "x0": 0, "y0": 870, "x1": 600, "y1": 882}
    ],
    "levels": [{"y": 882, "label": "EL +0.88 COUNTER TOP"}],
    "notes": [{"part": "top", "text": "12MM THK. SOLID SURFACE TOP"}],
    "dimensions": [{"from": [0, 0], "to": [0, 100], "axis": "y"}],
    "title": "SECTION A-A"
  }
}
```

- **Coordinates:** millimetres, x from the staff face (or any chosen datum), y up from the floor. The tool places the section at `origin`.
- **Materials and drawing:** `mdf` ANSI31, `ply` ANSI32, `stone` ANSI36, `corian` solid, `steel` solid in grey (colour 8), `glass` and `outline` outline only. Anything else is refused rather than guessed.
- **Checks:** at most 60 parts, ids unique (case-insensitive), each part at least 1 mm each way, parts may touch but not overlap, everything within 10 m. A note must name a part and, if it gives `y`, point inside it.
- **Annotation:** notes run right from the part's right edge at its mid height unless `y` is given; vertical dimensions sit left (`axis` `y`), horizontal ones below (`axis` `x`), `chain` 1 to 4 steps outwards; overall width and height are added outside the last chain unless `overall_dimensions` is false; `floor` false drops the floor line. Levels sit left of the dimensions. `annotation`, `layout`, `view` and `level_block` work as for the reception template.
- **Views:** `view` is `section` (default: heavy cut outlines on A-DETL-WIDE, material hatches, overlapping parts refused), `elevation` or `plan` (outlines on A-DETL, no hatch unless a part asks, overlaps allowed). In elevation and plan, **parts listed later are nearer the viewer** and hide the lines of earlier parts behind them: a partly hidden part is drawn as its visible line pieces (no hatch, with a warning if it had one), a fully hidden part is not drawn, and the result lists `partly_hidden_parts`. `hidden_lines` false turns this off. A plan has no floor line by default; the default title is the view's name.
- **Polygon parts:** `points` [[x, y], ...] (3 to 100, in order, closed automatically) instead of `x0, y0, x1, y1`, for diagonal or shaped panels. Self-crossing outlines, zero area and repeated points are refused; in a section, polygon overlaps are checked exactly (touching is fine).
- **Arcs (curved fronts, S-shaped plans):** a point in `points` can carry an arc to the next point: `[x, y, bulge]`, or `{x, y, radius}`, `{x, y, rise}` or `{x, y, bulge}`. Positive turns anticlockwise, so the arc **bows out to the right of the direction of travel**; the arc always belongs to the segment that starts at that point, and a `radius` is the shorter arc. `rise` is the arc's height above its chord, which is how catalogues show curves. A bulge is AutoCAD's `tan(sweep / 4)`: 1 is a half circle, 0.41421 a quarter. The part is drawn as a true arc polyline; overlap, hidden-line and leader checks use the curve flattened to within 0.2 mm. A radius smaller than half the chord, a bulge over 10, an arc that crosses its own outline, and an arc on a repeated closing point are refused. A catalogue's "1580 wide" on a curved module is a chord: give `rise`, or the radius, from the render or the maker.
- **Repeat:** `repeat` {count 2 to 200, pitch_x, pitch_y} makes `id-1` ... `id-n` (for slats, fins, shelves). A note on the group's `id` points at its rightmost member and covers the whole group. At most 200 parts after repeats and 500 steps per plan; a larger view must be split.
- **Hatch per part:** `hatch` {pattern, scale (multiplied by the detail scale), angle} or `"none"`; the pattern must exist in AutoCAD's pattern file.
- **Lines:** `lines` [{from, to, kind}] for single lines that belong to the drawing: `led` on A-DETL-LITE (yellow, 0.18; this layer name is the generator's own) or `line` on A-DETL. Materials also include `marble` (section hatch as stone).
- **Example, front elevation of a slatted counter:** `view` elevation; `slat` mdf 0,0 to 40,1000 with `repeat` {count 24, pitch_x 80}; `end` mdf 1900,0 to 2000,1000; `marble` with `points` [[0,100],[450,100],[1200,1000],[0,1000]] listed last so it hides the slats behind it; `lines` [{from [450,100], to [1200,1000], kind led}].
- **Nothing is invented or verified.** Texts are as given (use the office style: capitals, thickness first). The result warns when no notes were given or parts have none. The generator does not compare the section with the pictures or any code, so show the interpretation list to the user before drawing and check the result against it.
- Covered by 57 mock checks, plus 33 for arcs (an S-shaped reception in plan, with five deliberate breakages caught) and 60 for views, polygons, repeat, hidden lines, hatch and lines, built around a real slatted counter with a diagonal marble panel (no visible slat line may fall inside the marble). Deliberate breakages are caught. Old `custom_section` calls give byte-identical plans. Not yet run in a live AutoCAD.
