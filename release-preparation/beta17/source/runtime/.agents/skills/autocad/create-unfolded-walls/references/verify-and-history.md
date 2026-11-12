# Verify independently, and verification history

Read each created instance in a separate pass: correct drawing, `EffectiveName`, dynamic status, length, height, visibility, scale, rotation, insertion point, and visible evaluated outline. Block-wide bounding boxes can include annotations or hidden geometry, so they are not sufficient to verify the wall rectangle.

Check cumulative stations for unintended gaps/overlaps, wall top levels, each opening's width/height, total unfolded length, and net area. Verify that full-height openings are the only deliberate intervals with no wall/header. Compare numeric values with a small tolerance appropriate to drawing units; do not round lengths before placement. Record any intentional geometry cleanup rather than silently removing small returns.

Confirm original plan objects and the existing sample block were not changed. After errors, inspect the current drawing and creation log before retrying. Never rerun a batch blindly or delete objects except those created by this task and identified by recorded handles.

Report face/panel/opening counts, length, wall and door heights, net area, exclusions, and save status. A preview rendered from verified CAD outlines and a length schedule are useful review artifacts; label an outline preview accurately rather than presenting it as an AutoCAD screenshot. Save the DWG only when requested; saving this skill is separate authorization.

## Verification history

Live AutoCAD 2025 work on 2026-10-25 produced 68 dynamic wall/header panels across 50 faces, with ten 2.20 m openings beneath a 5.00 m wall top. Separate API readback verified 174.259044 m length, 839.447693 m2 net wall area, dynamic status, evaluated rectangles, and station continuity. Work used an existing Wall-Type-001 definition and background APIs; the DWG remained unsaved. These are past-run evidence, not future project defaults. General dynamic-block authoring, closed-file editing, and arbitrary block definitions were not verified by that run.
