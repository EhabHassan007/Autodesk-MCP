# Counter detail standard

Observed in the verified counter package (circular reception counter with cubby back wall). Treat values as a template; take project values from the brief.

## Views and model regions

Draw everything 1:1 in mm, with views side by side in model space and a gap of at least 1500 mm.

| View | Typical scale on sheet | Content |
|---|---|---|
| Plan (key / reference) | 1:30-1:50 | Outline traced from the client plan, centre lines, section lines X1/X2, overall dimension, radii |
| Front elevation (view A) | 1:30-1:50 | Back wall/cubbies, counter, drip profile, finishes as hatches |
| Side elevation (view B) | 1:30-1:50 | End pilaster, counter wing, dimensions |
| Section X1 (counter) | 1:8-1:10 | Worktop, top, drawers, shutters, shelf, skirting, legs, LED, service void |
| Section X2 (back wall) | 1:16-1:20 | Shelves at a regular pitch, parapet box, rising drip board, base frame |

Keep each view's finished floor level at the same model Y so levels and the DXF-to-sheet mapping stay simple.

## Layers

- Linework: `AO_ELEVATION 3` (main), `AO-ELEVATION`, `AO-DECO WALL`, `AO-N_LIGHTING`, `AO_HATCH BOUNDARY`, `AO_N_HATCH`.
- Section materials: `0_AO_MDF_SECTION_PLAN`, `0_AO_CORIAN C-TOP`, `0_AO_STAINLESS STEEL`.
- Annotation in the DXF: `AO-TEXT`, `AO-DIMZ`, `AO-Z.Lvl`, `AO_DRAWING TITLE BASE`, `AO_SECTION LINE`, `AO-ARROW` (leader line plus a 5-10 mm dot at the target).

Match the receiving drawing's layer names when they differ.

## Text heights (model units, sized for the view scale)

- Notes: 90-100 at 1:50, 22 at 1:10, 44 at 1:20.
- View titles: 180 at 1:50, 45 at 1:10, 90 at 1:20.
- Gives about 2-4.5 mm on paper.

## Content conventions

- In the DXF, mark dimensions scaled from renders with `*` and add a general note. On the issued sheet, show plain measured numbers (user preference).
- Give every note in a section a leader and dot on `AO-ARROW`. These dots are the exact arrow targets when the sheet is annotated.
- Level texts in pairs: `EL. +1.10` / `TOP OF COUNTER`; also `F.F.L.`, worktop, parapet, top of drips.
- Curved panels: state the plan radii (e.g. R1750 / R2240 / R2561), with flexible or kerfed FR-MDF.
- General notes: units in mm and drawn 1:1; confirmed client dimensions; verification of scaled values; indicative artwork profiles; section sheet references; exclusions.

## DXF to DWG

Convert with `scripts/dxf-to-dwg.ps1`. Compare entities, hatches, gradient hatches (HatchObjectType 1), and ByRGB entities (ColorMethod 194) before and after; all must match. Raw DXF group-420 counts are higher than ByRGB entity counts and are not a failure.
