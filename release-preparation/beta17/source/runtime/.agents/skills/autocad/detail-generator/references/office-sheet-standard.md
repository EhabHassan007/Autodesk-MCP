# Office counter-sheet standard used by the Detail Generator

Read from the office's reference counter sheets (layers, blocks and text, not any one project). Use it to check that generated sheets match.

## Layers (scheme `ao`)
- Section material layers: `AO-MDF_SECTION_PLAN` (MDF and plywood), `AO-CORIAN C-TOP`, `AO-STAINLESS STEEL`, `AO-GLASS_SECTION_PLAN`. Stone and marble have no layer on the sheets, so the generator makes `AO-STONE_SECTION_PLAN` and says so.
- Hatches of cut materials sit on the material's own layer; finish hatches on `AO_N_HATCH`. Lighting `AO-N_LIGHTING`. Plan outline `AO-COUNTER`, elevation outline `AO_ELEVATION 3`.
- Leader labels `AO_DIMZ`, dimensions `0_AO_DIMZ`, level indicators `AO-Z.Lvl`, view port `AO-MV`.

## Blocks (paper space)
- `Multiple Leader Lab`: attribute `LABEL`; dynamic Distance1 (landing), Distance2 (leader length), Angle1, optional Visibility1.
- `level indicator`: `LEVEL` = elevation (`EL. +1.10`), `Area` = description. Older sheets: `ELEVATION` = elevation, `LEVEL` = description.
- `DWG-VIEWTITLE`: `BOTTOM-TITLE`, `SCALE` (written `1:10 M.`), `TOP-TITLE`, `SHEET-NO`, `KY`.

## Wording
Capitals with a lowercase `mm`, thickness first, no dot after THK, `W/` for with, `&` for and: `18mm THK FR MDF CABINET`, `12mm THK SOLID SURFACE TOP W/ 18mm THK MDF SUBSTRATE`.

## Annotation
Paper-space notes are 2.5 mm high on paper, as leaders, never bare lines. Paper-space dimensions use `LinearScaleFactor` = minus the scale denominator.

## Status
Generated from the reference survey and the plan checker; none of the leader, level or title steps has been run in AutoCAD yet. Verify in the office template before relying on it.
