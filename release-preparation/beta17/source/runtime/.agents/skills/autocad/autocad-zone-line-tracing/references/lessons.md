# Lessons (live AutoCAD 2025, mall floor plan, 2026-11-01)

User request: four marked zones (inflatable area, skating track, circulation, lab) as polylines on an xref'd plan.

## What failed and why

| Attempt | Result | Why |
|---|---|---|
| Trace the coloured markup from a screenshot (OpenCV), fitted to drawing coordinates on 5 ring centres (fit 0.02-0.19 m) | Areas plausible, user: "very bad" | Hand strokes, not plan lines; edges about 0.2-0.5 m off; no true arcs |
| Polygonize all xref linework, pick faces inside each zone | Faces cut by long diagonal / construction lines | A furnished plan is not a clean planar partition |
| Polygonize one layer (ceiling) | Only a few faces close | Zone boundaries span several layers and have gaps at doors and openings |
| Snap traced rings to the nearest parallel plan line within 0.6 m | About 50% of the perimeter still off-line; hops between concentric ceiling rings | Nearest is not "intended"; zones snapped independently do not share edges |
| Priority partition (track > red > yellow > magenta) with gap fill | Consistent shared edges, still not exact | Based on the snapped rings |
| Linework-only polygonize with gap bridges | Did not close into zone faces | Bridging to the nearest line can connect to the wrong line |

## What worked

- **The user drew** the inflatable and track zones: 92% and 100% on plan linework (ceiling outlines, the wall-face route, wall lines) with a few straight connectors.
- **Derived zones:**
  - Circulation = wall-face route space minus the user's zones, split from the lab along the plan's ceiling divider.
  - Later, after the user edited the lab, circulation = remainder (510.3 m2; it shrank by exactly the lab's +7.6 m2).
- **Result:** 0.04 m2 total overlap (only between the user's own zones), 1.02 m2 unzoned in hairline slivers (max 77 mm).

## Technical gotchas

- New COM objects take CECOLOR / current lineweight; set `color = 256` and `Lineweight = -1`.
- PowerShell variable names are case-insensitive: `$l = Layers.Add(...)` overwrites `$L`.
- PowerShell strips quotes from JSON passed to a native exe; pass JSON in a file.
- Flat-capped split strips can leave a hairline channel; use round caps.
- Arc rebuild: map each boundary edge to its source primitive (<= 8 mm), merge runs on one arc into a bulge `tan(sweep/4)`, sweep summed from the run's angles.
- `polygonize`, `difference` and `buffer` work in mm; ignore faces < 1 m2 and report slivers instead of hiding them.
- A selection made by the user is readable through `doc.PickfirstSelectionSet`. The connector's `list_selected` is Revit-only.

## Envelope zones when internal walls are missing (back-of-house block)

- Sketch mapped fine (194 m2), but the block's internal walls do not exist in the xref, and per-room outlines (xref layer 0) leave 150 mm wall-thickness gaps, so polygonize cannot close it.
- What worked: compose the outline explicitly from the bounding plan lines with exact intersections: diagonal wall inner face, south wall inner face, shaft wall, stair wall, wall-face route (shared with the neighbour zones), and the corner column's face where the user closed it. Result: 98.9% on linework, 0 overlap.
- The xref's layer 0 can hold room outlines as well as grid axes: keep multi-vertex polylines, drop long 2-point axes.
- When bridging wall openings, bridge only in line with the wall (the end ahead, same direction); nearest-line bridges jump across the wall thickness.
