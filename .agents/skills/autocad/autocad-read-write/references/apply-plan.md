# apply_plan: many objects in one call

Use `apply_plan` when a task needs more than a handful of objects (details, layouts, repeated geometry). One call replaces hundreds of `create_entity` calls and one Undo reverses it.

`apply_plan` is a tool of SmartConnector.exe only. The older PowerShell fallback bridge (`autocad-bridge.ps1`) does not have it; if it is not in the tool list, the exe is not the connection in use, so fall back to `create_entity`.

## Workflow

1. `drawing_info` for `drawing_id`; `list_layers` to see which layers exist.
2. Build the plan as ordered steps. Put `layer` steps first: a layer must exist, or be created by an earlier `layer` step, before geometry uses it.
3. Call with `dry_run: true`. It checks every step against the drawing (layers, locks, linetypes, text styles, blocks) and changes nothing. Fix whatever it lists and repeat until it reports `valid`.
4. Call again without `dry_run`. Check `count_matches_plan` and the returned `handles`, then read a sample back with `get_entity`.
5. Save only when the user asks.

## Steps

| op | fields |
|---|---|
| `layer` | `name`, `color` (1-255), `linetype` (must be loaded), `lineweight` (hundredths of mm: 5, 18, 50, 100 ...) |
| `line` | `layer`, `start`, `end` |
| `circle` | `layer`, `center`, `radius` |
| `arc` | `layer`, `center`, `radius`, `start_angle`, `end_angle` (degrees, counter-clockwise) |
| `polyline` | `layer`, `points` as `[[x,y],...]`, `closed`, `bulges` (one number per point: the arc of the segment that starts there; 0 straight, 1 half circle, 0.41421 a quarter, positive anticlockwise) |
| `text` | `layer`, `point`, `text` (one line), `height`, `rotation`, `style` |
| `mtext` | `layer`, `point`, `width`, `text` (`\P` starts a new line), `height`, `rotation`, `style` |
| `insert` | `layer`, `name` (block already in the drawing), `point`, `scale`, `rotation`, `attributes` (object of attribute tag to one-line text; a tag the block does not have fails the step and the block is removed again) |
| `hatch` | `layer`, `pattern` (SOLID, ANSI31, AR-CONC, or a custom pattern on the support path), `boundary` (the `id` of an EARLIER closed `polyline` or `circle` step), `holes` (list of such ids, each an inner loop), `scale`, `angle` (degrees), `color` (1-255). Not associative. |
| `dim_aligned` | `layer`, `from`, `to`, `location` (a point the dimension line passes through), `style` (must exist), `scale`, `linear_factor` |
| `dim_rotated` | `layer`, `from`, `to`, `location`, `angle` (degrees; 0 = horizontal, 90 = vertical), `style` (must exist), `scale`, `linear_factor` |

Every step may carry an `id` (letters, digits, `_`, `.`, `-`; unique); the result maps each id to the object's handle. Points are `[x,y]` or `[x,y,z]` in drawing units (z defaults to 0). `linear_factor` is for a dimension drawn in a paper-space layout over model geometry: the measured paper length is multiplied by it, so a dimension of a 1:10 viewport reads the model size (`linear_factor` 10). It is applied as a negative DIMLFAC, the reference sheets' convention (paper space only); if AutoCAD refuses that sign the positive value is used, and if the value does not read back the whole plan is refused and rolled back, because a dimension reading the wrong value must never stay in a drawing. A plan has at most 500 steps; split larger work. `layout` selects a paper-space layout; the default is model space.

## Rules the tool enforces

- Unknown fields, unknown ops, bad numbers, zero radius or height, identical line ends, and invalid layer names are refused before AutoCAD is contacted, with the step number (`items[3]: ...`).
- Geometry on a locked layer is refused. A failed run deletes what it created, including layers it added.
- A hatch refers to earlier steps by id, so the boundary and hole steps must come first and carry an `id`. Order matters: the steps run top to bottom.
- Dimensions show the measured value; there is no text override, in line with the plain-numbers rule of the sheet-preparation skill.
- Not yet supported: leaders and multileaders, tables, radial, diametric and angular dimensions, gradient hatches, hatch boundaries made of separate lines or arcs, block attributes, xrefs. Use `execute_autocad` for those (see its reference) until they are added and live-tested.

## Verification status

- Plan parsing, validation and the argument schema are covered by mock tests (75 checks, including every refusal above) and by cases in `test-smart-connector-exe.ps1`.
- The orchestration (undo group, id-to-handle map, hatch loops wired to the right objects, rollback of everything including a half-built hatch and created layers, refusal before any change) is covered by 27 checks against a fake AutoCAD object model.
- **Live result, AutoCAD 24.3 (2024), 2026-11-10, blank drawing, driven directly through the program:** a plan with one layer, a line, a circle, an arc, a closed polyline, text and mtext passed `dry_run` (7 steps, nothing drawn), then ran for real: 6 objects created, `count_matches_plan` true, and one `U` removed all six together. After the later hatch run, a layer count read through `execute_autocad` showed only layer `0`, so the layers a plan creates are removed by the same Undo. Not itemised in the report: the arc orientation and the mtext line break. Insert steps are not yet run live.
- **Live finding, AutoCAD 24.3, 2026-11-10 (first attempt):** a hatch-and-dimension plan passed `dry_run`, then the real run stopped at the first hatch with `Invalid object array`. AutoCAD refuses a plain C# `object[]` for a hatch loop (it reaches AutoCAD as an array of variants; AutoCAD wants an array of automation objects, as Visual Basic sends). The plan rolled back completely: object count back to 0 and the layer `TEST-B` removed. That was the first live proof of the rollback.
- **Live result after the fix, same AutoCAD, second PC and Windows user:** the same plan (one layer, a closed polyline, a circle, an `ANSI31` hatch with the circle as a hole, a `SOLID` hatch with `color` 1, an aligned dimension and a rotated dimension, dimension style `Standard`) passed `dry_run`, then ran for real: 6 objects created, `count_matches_plan` true, `hatch_loop_array_form` `["dispatch-array"]` (the first form tried was accepted), all six objects appeared, and one `U` removed them together. So AutoCAD accepted pattern type `1` with `ANSI31` and `SOLID`, the IDispatch-array hatch loop, and the `Standard` dimension style. Not itemised in the report: the exact look of the hatch, the circle fill colour, the dimension values and the style on the dimensions. Look at them the first time you use these steps on a real drawing.
- Paper-space annotation, block attributes and `linear_factor` are covered by mock tests only (64 checks, including rollback of a failed attribute and of a refused factor). Not yet run live.
- Still not run live: `insert` (blocks and attributes), `layout` (paper space), `linear_factor`, `holes` with more than one hole, hatch scale and angle on a different pattern, and drawings in millimetre units (the tests used a blank inch drawing, `units_code` 1).
