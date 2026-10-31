# Sheet annotation through AutoCAD COM

Live-verified on AutoCAD 2025 (ProgID `AutoCAD.Application.25`) through PowerShell 5.1. The connector's own tools cannot create dimensions, block inserts, or dynamic-property edits, so use an authorized background COM helper. Attach with `GetActiveObject`, never `New-Object`, while the user's drawing is open, and release the COM object in `finally`.

## Viewport mapping

- `AcadPViewport` has no view-centre property. Read DXF 12 (view centre, DCS), 17 (target) and 45 (view height) with one AutoLISP `entget` sent by `SendCommand`, writing to a file (`get-viewport-centres.ps1`).
- For untwisted plan views, model view centre = 17 + 12.
- paper = viewport Center + (model - view centre) x CustomScale.
- Find each view's DXF-to-model offset by matching per-layer extents (e.g. section-material layers, or FFL at y = 0).

## PowerShell pitfalls

- Pass points as `[double[]]`. A function's array output becomes `object[]`, and `AddDimRotated` then fails with "Object was erased".
- `@('a', [math]::PI / 2)` divides the whole array; wrap arithmetic in parentheses. `@($x[0])` flattens a nested tuple; use `, $x[0]`.
- In PS 5.1, `ConvertFrom-Json` returns a JSON array as one object; unroll with `| % { $_ }` before merging logs. Write logs only after a run succeeds.

## Dynamic blocks

- Setting a property (especially a visibility state) invalidates the wrappers from `GetDynamicBlockProperties()`; the next set fails with a "Double to String" cast. Re-fetch the block with `HandleToObject` before every property set, and skip values that are already correct.
- A fresh insert uses the current definition's attribute tags, which can differ from older reference instances. Read tags from a fresh insert.

### Leader label block (verified "Multiple Leader Lab")

- The insertion point is the label anchor. The LABEL attribute is MText, attached middle-left at +2.35 mm.
- `Distance1` is the landing, running left from the insertion point. The leader starts at the landing end, with length `Distance2` drawn at direction `Angle1 + 180 deg`, so set `Angle1 = atan2(dy, dx) - pi`. Visibility `1 arrow`.
- Set `MTextBoundaryWidth` to the column width. Attribute bounding boxes ignore wrapping, so estimate height: about 2.3 mm per character and 5.6 mm per line at 3.5 mm text.

### Level block (verified "level indicator", scale 0.015984)

- Insertion point at the level; the symbol sits at the insertion point and the line runs right towards the view.
- Tags in the current definition: `LEVEL` (top line, e.g. `EL. +1.10`) and `Area` (bottom line, e.g. `TOP OF COUNTER`). Copy writable dynamic values (not `Origin`) from a reference instance.
- Place levels in the sheet margin left of each view. Move clashing dimension text with `TextPosition`; stagger levels closer than about 10 mm apart.

### Section callout (verified "Section Callout - Metric", scale 0.9)

- Attributes VIEWNUMBER and SHEETNUMBER. At rotation 0 the tail runs 16.82 mm left of the symbol, then up by `Ref Line Length` (set 0).
- Place the symbol so the tail lies along the section line.

## Dimensions

- `AddDimRotated(xl1, xl2, dimLinePoint, angle)` in paper space. Set layer, `StyleName`, and `LinearScaleFactor = -1 / scale`.
- `AddDimRadial(centre, chordPoint, leaderLength)` for radii.
- Leave `TextOverride` empty for plain numbers.

## Display, plot and safety

- After batch attribute edits, call `doc.Regen(1)`.
- Visual check: `Plot.PlotToFile(base, 'PublishToWeb PNG.pc3')`. Read BACKGROUNDPLOT first, set it to 0, restore it in `finally`, and run the plot in its own call. Desktop screen capture can grab the wrong window; do not use it.
- `StartUndoMark`/`EndUndoMark` around each stage; log handles.
- AutoCAD deadlocked after a PowerShell task was stopped mid-COM-call. If calls start failing, stop and ask the user about dialogs. If AutoCAD is frozen, back up the `.sv$` autosave first.
- After `save_drawing`, the connector's `saved` flag can stay false when DBMOD has only window/view bits (e.g. 24). Confirm with the file timestamp instead.
