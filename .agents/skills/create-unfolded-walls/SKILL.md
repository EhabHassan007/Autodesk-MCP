---
name: create-unfolded-walls
description: Create connected unfolded wall elevations in AutoCAD from a selected or marked plan route, using measured CAD lengths and an existing dynamic wall block. Include specified door openings, preserve source geometry, and verify panels through background APIs without computer controls.
---

# Create unfolded walls

Develop the requested plan wall faces into an editable, connected elevation beside the plan. Work through Autodesk MCP tools and authorized non-UI AutoCAD APIs. Do not use mouse/keyboard automation or change the user's view to inspect the result.

## Establish the source and dimensions

- Call `drawing_info` and bind operations to the current drawing identity. Check model/paper space, units, read-only state, and relevant layer locks. Keep source entities, existing sample blocks, and unrelated edits intact.
- Use the user's selection, marked reference, or specified route to identify actual CAD geometry. A marked image establishes scope; measure CAD coordinates, not image pixels. Resolve materially ambiguous routes or wall faces before creating the affected panels.
- Record the ordered start/end points and source handles for each face, including marked returns, recesses, columns, and bends. Identify duplicate/overlapping linework so it is not counted twice. Use one consistent finish face; do not silently mix inner faces, outer faces, and centerlines.
- Establish the unfolding direction and endpoints. Keep all lengths in one working unit. For a millimetre drawing, 5.00 m is 5000 mm and 2.20 m is 2200 mm; these are examples, not automatic defaults. Use the user's heights, and ask for materially missing heights.
- Measure door widths and offsets from wall jambs or verified block geometry, accounting for rotation, mirrored scales, and paired leaves. Do not treat a swing bounding box as the clear opening. Include only doors intersecting the chosen wall route. Keep unspecified openings undeducted and explain the limitation rather than inventing dimensions.
- Use actual arc length for a curved wall; never substitute chord length. If the existing block cannot represent the intended curved development or varying height, explain the limitation and resolve that portion separately.

## Inspect the existing dynamic block

Discover available connector tools first. If they cannot insert blocks or set dynamic properties, explain that gap and use an authorized background API helper. This is not permission to bypass a rejected connector action.

Find the user's existing definition by `EffectiveName`, case-insensitively. Preserve its spelling; for example, `wall-Type-001` may resolve to `Wall-Type-001`. Read `IsDynamicBlock`, properties, writable flags, allowed visibility values, attributes, scales, rotation, and insertion point. Do not create a replacement definition merely because the block's runtime name is anonymous (`*U...`).

Use the block's actual length/height parameters and the elevation state matching the user's example. The demonstrated definition used `Wall Length`, `Wall Height`, and `Visibility1 = Wall-Elv-Graphics-noSkirt`. Treat those as verified example names, not universal names.

## Prepare and place the elevation

1. Build a route and opening schedule before mutation. For sequential calculations, use [scripts/plan_unfold.py](scripts/plan_unfold.py); its input and output are documented in [references/background-api.md](references/background-api.md). The helper only computes panels from already-measured lengths; it does not identify walls or edit DWGs.
2. Split each face at door jambs. Full-height panels start at the baseline. Above a door, use a panel with height `wall height - door height`, positioned at `baseline + door height`, keeping the common wall top. Preserve the door void below it. A full-height opening has no header.
3. Inspect existing drawing extents and choose clear space beside the plan. Keep panels in route order along one continuous baseline unless the user requests separate runs. Preserve true relative lengths; do not scale panels to make them fit a page.
4. Create one new panel and verify its dynamic parameters and visible evaluated rectangle before batching. Prefer fresh insertion from the existing definition: copying a modified sample can inherit displaced dynamic origins or other unwanted state.
5. Add the remaining instances sequentially, recording new handles immediately. Set visibility before length and height, and retain uniform unit scale and consistent rotation. Use additive output layers and an Undo group; an Undo group is not an atomic transaction.
6. Retain useful built-in dimensions and field-linked height/area labels. Number wall faces and openings. On narrow returns, adjust or hide only overlapping attributes on the new instances; do not change the shared block definition. A nonplot route reference and start/end labels can make the development traceable without altering source geometry.
7. Regenerate through the API. Do not activate tabs or open a block editor for background processing. If the target is not open, report the missing capability or use separately verified background-database support; do not claim that editing an already-open document is offline DWG editing.

## Verify independently

Read each created instance in a separate pass: correct drawing, `EffectiveName`, dynamic status, length, height, visibility, scale, rotation, insertion point, and visible evaluated outline. Block-wide bounding boxes can include annotations or hidden geometry, so they are not sufficient to verify the wall rectangle.

Check cumulative stations for unintended gaps/overlaps, wall top levels, each opening's width/height, total unfolded length, and net area. Verify that full-height openings are the only deliberate intervals with no wall/header. Compare numeric values with a small tolerance appropriate to drawing units; do not round lengths before placement. Record any intentional geometry cleanup rather than silently removing small returns.

Confirm original plan objects and the existing sample block were not changed. After errors, inspect the current drawing and creation log before retrying. Never rerun a batch blindly or delete objects except those created by this task and identified by recorded handles.

Report face/panel/opening counts, length, wall and door heights, net area, exclusions, and save status. A preview rendered from verified CAD outlines and a length schedule are useful review artifacts; label an outline preview accurately rather than presenting it as an AutoCAD screenshot. Save the DWG only when requested; saving this skill is separate authorization.

## Verification history

Live AutoCAD 2025 work on 2026-10-25 produced 68 dynamic wall/header panels across 50 faces, with ten 2.20 m openings beneath a 5.00 m wall top. Separate API readback verified 174.259044 m length, 839.447693 m2 net wall area, dynamic status, evaluated rectangles, and station continuity. Work used an existing Wall-Type-001 definition and background APIs; the DWG remained unsaved. These are past-run evidence, not future project defaults. General dynamic-block authoring, closed-file editing, and arbitrary block definitions were not verified by that run.
