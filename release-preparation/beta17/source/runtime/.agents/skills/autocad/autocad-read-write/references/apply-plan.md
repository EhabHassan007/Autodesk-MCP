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
| `polyline` | `layer`, `points` as `[[x,y],...]`, `closed` |
| `text` | `layer`, `point`, `text` (one line), `height`, `rotation`, `style` |
| `mtext` | `layer`, `point`, `width`, `text` (`\P` starts a new line), `height`, `rotation`, `style` |
| `insert` | `layer`, `name` (block already in the drawing), `point`, `scale`, `rotation` |

Every step may carry an `id` (letters, digits, `_`, `.`, `-`; unique); the result maps each id to the object's handle. Points are `[x,y]` or `[x,y,z]` in drawing units (z defaults to 0). A plan has at most 500 steps; split larger work. `layout` selects a paper-space layout; the default is model space.

## Rules the tool enforces

- Unknown fields, unknown ops, bad numbers, zero radius or height, identical line ends, and invalid layer names are refused before AutoCAD is contacted, with the step number (`items[3]: ...`).
- Geometry on a locked layer is refused. A failed run deletes what it created, including layers it added.
- Not yet supported: hatches, dimensions, leaders, tables, block attributes, xrefs. Use the existing tools or the sheet-annotation scripts for those until they are added and live-tested.

## Verification status

- Plan parsing, validation and the argument schema are covered by mock tests (55 checks, including every refusal above) and by cases in `test-smart-connector-exe.ps1`.
- The COM calls that draw each object type have **not yet been verified in a live AutoCAD**. Before relying on it, run one plan containing each op in a disposable blank drawing, read the objects back, undo once, and confirm the original object count returns. Record the AutoCAD version and result here.
