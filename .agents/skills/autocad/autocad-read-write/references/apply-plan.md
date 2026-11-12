# apply_plan: many objects in one call

Use `apply_plan` when a task needs more than a handful of objects (details, layouts, repeated geometry). One call replaces hundreds of `create_entity` calls and one Undo reverses it.

`apply_plan` is a tool of SmartConnector.exe only. The older PowerShell fallback bridge (`autocad-bridge.ps1`) does not have it; if it is not in the tool list, the exe is not the connection in use, so fall back to `create_entity`.

## Workflow

1. `drawing_info` for `drawing_id`; `list_layers` to see which layers exist.
2. Build the plan as ordered steps. Put `layer` steps first: a layer must exist, or be created by an earlier `layer` step, before geometry uses it.
3. Call with `dry_run: true`. It checks every step against the drawing (layers, locks, linetypes, text styles, blocks) and changes nothing. Fix whatever it lists and repeat until it reports `valid`. Then show the user what will be created and wait for a yes.
4. Call again without `dry_run`. The connector refuses this unless the same plan passed a dry run on this drawing in this session in the last 30 minutes (one real run per dry run; a changed plan needs a new one). Check `count_matches_plan` and the returned `handles`, then verify with `verify_standards` or `list_entities` `summary` instead of reading objects one by one.
5. Save only when the user asks.

## Steps

| op | fields |
|---|---|
| `layer` | `name`, `color` (1-255), `linetype` (must be loaded), `lineweight` (hundredths of mm: 5, 18, 50, 100 ...) |
| `line` | `layer`, `start`, `end` |
| `circle` | `layer`, `center`, `radius` |
| `arc` | `layer`, `center`, `radius`, `start_angle`, `end_angle` (degrees, counter-clockwise) |
| `polyline` | `layer`, `points` as `[[x,y],...]`, `closed`, `bulges` (one number per point: the arc of the segment that starts there; 0 straight, 1 half circle, 0.41421 a quarter, positive anticlockwise) |
| `text` | `layer`, `point`, `text` (one line), `height`, `rotation`, `style`, `justify` (where the point sits on the text: `middle-center`, `bottom-left`, `center`, `right`, ...; default left on the baseline). Use `middle-center` to centre a label on a point, not an estimated offset. Mock-tested; not yet live |
| `mtext` | `layer`, `point`, `width`, `text` (`\P` starts a new line), `height`, `rotation`, `style`, `justify` (attachment point; default `top-left`) |
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
- `leader` (not yet live-verified): `{"op":"leader","layer":"A","point":[x,y],"target":[x,y],"text":"...","block":"Multiple Leader Lab","tag":"LABEL","landing":4,"width":45}` places the label block at `point`, fills its text attribute and sets its dynamic Distance1, Distance2, Angle1 (and `visibility`) so the leader runs to `target`. Without `block` it makes a native multileader (`height` sets the text size). `insert` attributes accept the roles `@elevation` and `@description` besides plain tags.
- Not yet supported: tables, radial, diametric and angular dimensions, gradient hatches, hatch boundaries made of separate lines or arcs, xrefs. Use `execute_autocad` for those (see its reference) until they are added and live-tested.

What has been verified live, and what has not: [apply-plan-verification](apply-plan-verification.md).
