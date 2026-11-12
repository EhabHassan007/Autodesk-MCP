---
name: create-unfolded-walls
category: autocad
description: Create connected unfolded wall elevations in AutoCAD from a selected or marked plan route, using measured CAD lengths and an existing dynamic wall block. Include specified door openings, preserve source geometry, and verify panels through background APIs without computer controls.
---

# Create unfolded walls

Develop the requested plan wall faces into an editable, connected elevation beside the plan, from measured CAD lengths and the user's existing dynamic wall block. Use Autodesk MCP tools and authorized non-UI APIs; no mouse or keyboard automation, and do not change the user's view.

## Dry run first, then ask
Before anything is created, show the user the schedule: faces and panels in route order, lengths, wall and door heights, openings deducted, the block and its visibility state, where the elevation goes, layers, and the assumptions. Wait for an explicit yes. A changed request needs a new schedule and a new yes. Only "skip the dry run" in the user's current message overrides this.

## Steps
1. `drawing_info`; bind every call to its `drawing_id`. Measure CAD coordinates, never image pixels; one consistent wall face; actual arc length for curves. [Source and dimensions](references/source-and-dimensions.md).
2. Find the existing dynamic block by `EffectiveName`; read its parameters and visibility states; never recreate it. [Dynamic block](references/dynamic-block.md).
3. Build the route and opening schedule first (`scripts/plan_unfold.py`, see [background API](references/background-api.md)); split faces at door jambs; place one panel and verify before batching. [Place the elevation](references/place-elevation.md).
4. Verify each instance in a separate read (dynamic status, length, height, visibility, outline), check stations for gaps, net area, and that the plan and sample block are unchanged. Report counts and save status; save only when asked. [Verify and history](references/verify-and-history.md).
