# Annotation spec (input to scripts/annotate-sheet.ps1)

One JSON file describes a sheet. Coordinates in `labels`, `levels`, `dims` and `radials` are **source DXF coordinates** of each view; the script maps them to paper. Callout positions are **paper** coordinates. See [example-spec.json](example-spec.json).

```text
layout        target paper-space layout name
style         reference style read from the reference layout:
  leaderBlock, leaderLayer, leaderTag        e.g. "Multiple Leader Lab", "AO_DIMZ", "LABEL"
  levelBlock, levelLayer, levelScale         e.g. "level indicator", "AO-Z.Lvl", 0.015984
  levelTopTag, levelBottomTag                tags of a FRESH insert (e.g. "LEVEL", "Area")
  levelReferenceHandle                       optional instance to copy dynamic values from
  dimLayer, radialLayer, dimStyle            e.g. "0_AO_DIMZ", "A-ANNO-DIMS", "na1"
  calloutBlock, calloutLayer, calloutScale, sheetNumber
views.NAME    offset [dx,dy] (DXF -> model), paperCentre [x,y] (viewport Center),
              modelCentre [x,y] (target + DXF 12 centre), scale (viewport CustomScale)
columns.NAME  x (label anchor), width (MText box), minY, maxY: free sheet band for that label column
levelX.NAME   paper x of the level symbol for a view
labels[]      { view, x, y, text, column? }; column defaults to view (use e.g. "PLANIN" for labels inside a ring)
levels[]      { view, y, elevation, description, x? }; x staggers a level that is too close to another
dims[]        { view, p1:[x,y], p2:[x,y], line:[x,y], angle (deg), textAt?:[x,y] }; plain numbers, no override
radials[]     { view, centre:[x,y], chord:[x,y], textAt:[x,y] }
callouts[]    { name, at:[px,py] (paper), rotation }
```

## How to fill it

1. **Views:** `paperCentre` comes from the viewport `Center` and `scale` from `CustomScale`. `modelCentre` = DXF 17 + DXF 12 from `get-viewport-centres.ps1`. Find `offset` by matching one layer's DXF extents with its model extents (FFL often makes the y offset obvious).
2. **Columns:** take them from a plot of the target sheet. A column must not overlap viewports, view titles, levels, or dimension text. Wider columns give one-line labels and straighter leaders.
3. **Labels:** short specification notes. Targets are the DXF leader dots where the DXF has them. Without a dot, target the described element at a sensible height, and tell the user the target was inferred.
4. **Levels:** place them in the sheet margin left of the view. Move clashing dimension text with `textAt`.
5. **Callouts:** at rotation 0 the tail runs 16.82 mm left of the symbol, so place the symbol that far past the section-line end.

Run `-Test` first; then `-Kinds level,dim,radial,callout`; then `-Kinds leader`. Each run writes its own log.
