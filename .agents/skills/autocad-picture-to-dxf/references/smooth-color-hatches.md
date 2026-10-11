# Smooth vector color fills

Use this workflow's hatch steps only after the user selects lines with hatches for the current conversion. Always ask outlines-only versus lines-with-hatches before each new conversion, as required by SKILL.md. The curve construction guidance also applies to outlines-only work; in that mode omit HATCH entities and hatch verification. The user rejected pixel-grid contour hatches and prefers smooth vector artwork.

## Geometry and color

1. Inspect the image and foreground/background intent. Sample a palette from the intended artwork, not an unrelated background gradient. Preserve main colors, shadows, highlights, and dark outlines. A limited palette approximates antialiasing and gradients; do not call it exact pixel color preservation.
2. Segment color regions, remove tiny noise where appropriate, and smooth their boundaries. In the demonstrated logo, a 48-color median-cut palette, indexed 3-pixel mode filter, five-sample contour smoothing, and 0.65-pixel simplification gave a useful result. These are example parameters, not universal thresholds. Keep essential small details and nested holes.
3. Write the same smoothed closed vertices to an LWPOLYLINE and a SOLID HATCH boundary. Keep RGB true colors on both entities/layers. Separate visible boundary layers from retained reference outlines.
4. For hatch island handling, explicitly flag exterior loops as external (`flags=1`) and interior loops as default (`flags=0`), with normal hatch style (`style=0`). The example's directed pixel contours have positive signed area for outer loops before flipping Y; another tracer may use a different winding convention. Determine topology from the actual tracer, not this example's sign alone.
5. Independently simplified adjacent regions can leave small seams. Prefer shared boundaries where feasible. The tested artistic logo used matching-color polylines of width 1 source pixel to cover subpixel seams; this slightly changes appearance and is unsuitable as a dimensional/manufacturing correction. Document the width and scale it with artwork. It is not a substitute for preserving important holes.

These example hatch boundaries are non-associative: changing a separate polyline does not automatically update its hatch. Regenerate the corresponding hatch from edited boundary geometry, or implement and verify associative boundaries if required. Smoothed straight-segment polylines are not analytic splines or fitted arcs.

### Curved-polyline correction

The user subsequently requested actual polyline curves rather than the straight segments in the smoothed version. Prefer true curved segments for this user's rounded artwork. The tested revision uses tangent circular corner arcs with LWPOLYLINE bulges, leaving short connecting straight segments and preserving turns over 120 degrees as intentional sharp corners. This is local corner rounding, not a global spline fit or a claim of exact source reconstruction.

For each eligible vertex, trim 0.49 times the shorter adjoining edge from both sides. Join the trim points with a circular arc whose bulge is `tan(signed_turn/4)`; straight connectors have zero bulge. Work in CAD coordinates so turn sign matches bulge sign. Mirror identical `(x,y,bulge)` vertices in HATCH polyline paths. Preserve the exterior/island flags. Render previews by sampling the saved arcs, not by drawing chords between their endpoints.

The demonstrated local implementation is not bundled because it was image-specific. Its output contained 375 polylines with 5,774 arc segments in total, including hidden reference geometry, and 36 RGB hatches (411 entities). Readback audit returned zero errors/fixes; every visible boundary matched its hatch path exactly, including bulges. AutoCAD opened it read-only and evaluated positive filled area 167272.6157 with FILLMODE 1 and 36 true colors. Preview inspected; final user visual approval remains separate. No existing drawing was saved.

The user subsequently approved this curved colored version with "perfect". It is the accepted visual baseline for similar artwork, in addition to passing the technical checks above.

## Verification

- Read the saved DXF back, audit it, and verify closed boundary polylines, hatch colors, island flags, and entity counts.
- Render the saved hatch loops using even/odd hole handling and include the matching boundary widths in the preview. Supersample for preview quality; that does not change CAD geometry.
- Open the generated file read-only in live AutoCAD when authorized, evaluate hatches, check positive filled area and true colors, ensure FILLMODE is enabled, and regenerate. Entity count alone missed a prior zero-area boundary problem.
- If AutoCAD rejects calls as busy, do not cancel the user's command. Retry once, then ask the user to finish the command/dialog before resuming.

## Demonstrated result — 2026-10-03

The demonstrated project used image-specific tracing code that is not part of this portable skill. It is evidence for the method, not a generic plug-and-play converter.

Saved-file audit passed with zero errors/fixes. Live AutoCAD opening succeeded after the user cleared its busy state: 411 entities, comprising 36 RGB HATCH entities, 283 smoothed boundary polylines, and 92 original hidden reference polylines. Hatch evaluation returned positive total area 167623.4 square drawing units, 36 true colors, FILLMODE 1, and read-only state. The preview was visually inspected; live checks were API-based, not a captured AutoCAD screenshot. No existing DWG was saved. Scale remains one pixel per unit with no physical size specified.

Outer blue background and corner decorations remain omitted. Palette approximation and simplification preserve the artwork's visual colors rather than every source pixel. The smooth result is delivered for user review; do not equate successful file verification with final user approval of style.
