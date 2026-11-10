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
- Layers: `A-DETL-WIDE` 0.50, `A-DETL` 0.25, `A-DETL-THIN` 0.13, `A-DETL-GENF` 0.09, `A-ANNO-DIMS` 0.13, `G-ANNO-TEXT` 0.13, with the office layer colours.

## The accessible section

A lowered top over the full depth, with only a staff-side box under it and an open knee space on the customer side. It needs four inputs and has no defaults: the height of the lowered top, the minimum clear height under it, the clear depth, and the name and edition of the code they come from. The generator refuses the section if the underside of the top is lower than the clear height asked for, or if the knee depth leaves less than 100 mm of carcass. It prints the code reference on the drawing and marks it "to be verified". A consultant or the authority confirms the values; the generator checks only that the drawing matches what was asked.

## Not drawn yet

Plans and elevations, drawers and shutters, hardware, the raised bar's own support, curved fronts, lighting recesses, block-based level markers and leaders (levels and leaders are plain lines and text), sheet layout and viewports.

## Where the defaults come from

Board thicknesses (18 mm MDF), the 600 depth, the 900 top, the 100 plinth set back 50 and the stone-on-marine-plywood top come from conventions repeated across the office's kitchen and joinery sheets. The 12 mm Corian top and the 200 mm raised bar come from a recent reception counter and from common practice for counters. The curved front, partitions and lighting strip of that counter were treated as specific to it and are not defaults.

## Verification status

- The generator is covered by 71 mock checks: the geometry of each part, dimensions attached to real edges and showing the true distances, both top materials, the raised bar, the accessible section and its refusals, origin and scale handling, deterministic output, and a run through `apply_plan` against a stand-in AutoCAD (millimetre guard, existing layers left alone, a dimension scale on every dimension). The Windows test script covers the argument errors and a plan without AutoCAD.
- **Not yet run in a live AutoCAD.** Run a default section in a disposable millimetre drawing first: confirm the dry run, the real run, the look of the hatches and dimensions, the text and dimension sizes at the chosen scale, and that one `UNDO` removes it all. The dimension `scale` property (`ScaleFactor`) is also unconfirmed live; if AutoCAD refuses it the result carries a warning and the dimension style decides the size.
- The accessible section has been checked only for internal consistency, not against any code.
