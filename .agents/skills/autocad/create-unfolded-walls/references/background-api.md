# Background API and panel calculations

Read when implementing the non-UI helper or using the station calculator. Discover current connector tools before supplementing them. Keep tool and filesystem approval requirements in force.

## AutoCAD API mechanics

- Bind an already-open document by exact current `FullName`; check `ReadOnly` and layer locks before writing. In each batch, verify document identity again. Use `drawing_info` for connector identity guards and direct document checks for supplemental API operations.
- Inspect the current version/registered COM identifier rather than hardcoding a product year. Windows PowerShell COM calls may need execution outside a restricted sandbox. Request the required execution permission; do not bypass it.
- Read geometry properties specific to each entity type. Iterating thousands of objects and requesting every conceivable property is slow and error-prone. Read nested definitions only where needed; transform their geometry to the relevant coordinate system.
- Use `ModelSpace.InsertBlock(point, definitionName, 1, 1, 1, 0)` for a new unit-scale elevation. Access `GetDynamicBlockProperties()`, inspect `PropertyName`/`ReadOnly`/`AllowedValues`, and assign floating-point distances as typed doubles. Change the visibility selector before length and height; then update and read back the instance.
- Read the instance's anonymous evaluated definition through `Blocks.Item(instance.Name)`. In the verified block, the visible closed polyline was the wall rectangle; its area and vertices matched the dynamic length/height. Another block may require a different outline check. Bounding boxes alone included attribute/annotation extents beyond the wall.
- Keep field-driven height and area attributes intact. Attribute visibility/placement changes for readability should affect only newly created instances. Changing a block definition would affect other users of that definition.
- Use `StartUndoMark` / `EndUndoMark` with `try/finally`, and checkpoint handles after each creation. Respect the user's unsaved changes. On interruption, compare the creation log with live handles before resuming.
- Use `Document.Regen(1)` where supported. Retry `RPC_E_CALL_REJECTED` with bounded busy-state handling; stop for a blocking modal and ask the user to close it. Never dismiss it with computer controls in this workflow.
- Parenthesize arithmetic inside PowerShell coordinate arrays: `[double[]]@(($baseX + $station), ($baseY + $bottom), 0)`. Without parentheses, comma/operator precedence can produce an `Object[]` addition error.

## Station calculator

Run with an available Python 3 interpreter; it uses only the standard library:

```text
python scripts/plan_unfold.py measured-input.json panel-plan.json
```

Input is measured lengths in millimetres. Opening offsets run from the beginning of their wall face in unfolding direction. `door_height_mm` is an optional fallback only when the user has supplied a common height; an opening can instead specify its own `height_mm`.

```json
{
  "wall_height_mm": 5000,
  "door_height_mm": 2200,
  "segments": [
    {
      "id": "W01",
      "length_mm": 6000,
      "source": "current drawing handle and face reference",
      "openings": [
        {"id": "D01", "start_mm": 2000, "width_mm": 1000}
      ]
    },
    {"id": "W02", "length_mm": 3000, "openings": []}
  ]
}
```

The output contains ordered faces, cumulative stations, solid wall/header panels, opening records, total length, and gross/opening/net areas. Place each panel at `baseX + station_mm`, `baseY + bottom_mm`; its length and height are the dynamic parameter values. A full-height opening remains in the opening records but produces no header panel. Inputs are validated for finite positive dimensions, unique identifiers, boundary violations, and overlapping openings. The calculator does not repair routes, infer door sizes, round dimensions, generate CAD objects, or save a DWG.
