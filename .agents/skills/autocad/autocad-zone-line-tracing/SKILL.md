---
name: autocad-zone-line-tracing
description: Draw and check zone / area outlines in AutoCAD that sit exactly on the plan's own linework (walls, ceiling outlines, track edges) with true arcs, shared edges between neighbouring zones, and no gaps or overlaps. Use when a user marks zones on a plan (sketch, screenshot, or their own polylines) and wants clean closed polylines per zone, or wants their zone polylines checked.
---

# Zone outlines on plan linework

A zone outline must follow the plan's existing lines exactly, not a sketch. The reliable pattern is: **the user draws the zones that need judgement; derive the rest from those and the plan; check everything numerically.** Read `drawing_info` first, and save only when asked.

## Fast path: one command per job (use this first)

[scripts/zone.ps1](scripts/zone.ps1) runs on the active drawing. It finds the xref and every `ZONE-*` / `SKETCH` polyline itself, needs Python 3 + shapely, and prints a short report.

| Job | Command |
|---|---|
| Check all zones | `zone.ps1 check -Close "x1,y1;x2,y2"` (closes the wall-face route into the space outline) |
| Neighbour after an edit | `zone.ps1 remainder -Layer ZONE-X -Close "..." [-Near "x,y"]` (replaces the single polyline on that layer) |
| New straight-walled zone | User draws a rough PLINE on layer `SKETCH`, **with OSNAP on** (Endpoint, Intersection, Apparent intersection, Extension). Then `zone.ps1 snap -Layer ZONE-X [-Color n]` snaps each corner to the nearest real plan corner, including extended-line corners such as a column face meeting a wall, and lists any corner moved more than 80 mm. |

Add `-Save` only when the user asked to save. Snap reliability, tested against a known outline:
- **Clicks with OSNAP:** exact.
- **Clicks within about 120 mm:** usually within 0.2 m2.
- **Clicks 250 mm off on 200 mm double walls:** ambiguous; ask the user to use OSNAP.

Curved zones: draw them with OSNAP along the arcs, or derive them as a `remainder`. For a project, keep the `-Close` points in a note so every run is one line.

## Workflow

1. **Agree layers and colours.** Use one layer per zone (e.g. `ZONE-INFLATABLE`, `ZONE-SKATING-TRACK`, `ZONE-CIRCULATION`, `ZONE-SLIMOOO-LAB`) and draw closed LWPOLYLINEs in model space. Find where the plan lives: often an xref at 0,0. Check its insertion point and scale.
2. **Get a user-drawn example early.** One or two zones drawn by the user (e.g. with PLINE along the plan lines) show which linework counts as an edge. Do not try to infer that from a sketch alone; see [references/lessons.md](references/lessons.md).
3. **Export geometry.** Run [scripts/export-geometry.ps1](scripts/export-geometry.ps1), which writes the xref's lines, arcs, circles and bulged polylines plus the given host polylines to JSON. It is read-only.
4. **Check the user's zones.** Run [scripts/check_zones.py](scripts/check_zones.py) `<export.json> <labels.json>` (labels as a file: PowerShell strips quotes from JSON arguments). It reports closure, vertices, true arcs, area, validity, % of the outline on plan linework (<= 20 mm) with layers and the longest off-line runs, plus pairwise overlap and shared edges. A good user zone is typically 90-100% on linework; the rest are short straight connectors where the plan has no line.
5. **Derive the remaining zone(s).**
   - One zone left: [scripts/remainder_zone.py](scripts/remainder_zone.py) `<export.json> <config.json> <out.json>`. Space = the room-facing wall route (e.g. an `AO-WALL-UNFOLD-REF` polyline) closed through `close_with` points along real lines (entrance line, a room-facing wall face). Remainder = space minus the user's zones; it then shares their edges exactly.
   - Two zones left: split the remainder along the divider: the plan entities running along the intended boundary, plus straight bridges (< 2.5 m) from their ends to the boundary. Cut with a 1 mm **round-capped** buffer strip, take the piece in the intended area, and make the other zone `remainder - piece` so the shared edge is exact.
   - Rebuild arcs **only from the source linework** (user polylines, route, closing lines, divider). Matching against every plan line turns nearby circles into fake arcs.
6. **Draw.** Use [scripts/draw-rings.ps1](scripts/draw-rings.ps1) with an Undo mark and `-Replace <old handle>` when updating. It sets colour and lineweight **ByLayer**; COM objects otherwise take the current colour (CECOLOR) and vanish into existing red linework.
7. **Verify** with `check_zones.py` on all zones: overlaps about 0, shared edges as expected. Compute space minus all zones and expect only hairline slivers (tens of mm). Report areas against the plan labels and mention labels that obviously include other area.
8. **Updates.** When the user edits one zone, re-export and rebuild only its neighbour as a remainder. The neighbour's area change should equal the edited zone's change.

## Rules

- **Follow the plan, not the sketch.** A screenshot markup gives scope and seed areas only. Hand strokes are about 0.2-0.5 m off.
- **Use room-facing faces.** Use wall *faces*, not the space between a wall's two lines. Grid axes (often layer `0` in the xref) are never boundaries.
- **Do not change the drawing to compute.** Never switch layers off or freeze them globally to compute or display zones.
- **Respect the user's linework.** The user's zones are authoritative: never edit them. Derive neighbours from them, and leave the user's construction lines (XLINEs) alone.
