---
name: 3dsmax-model-to-cad
category: 3ds-max
description: Read an open 3ds Max scene through Smart Connector and turn it into 2D CAD input - object list, sizes in mm, materials, and plan or section cuts as polylines or DXF - for joinery details, elevations and drawings in AutoCAD.
---

# 3ds Max model to CAD

Use the Smart Connector 3ds Max tools to measure a model that only exists in 3ds Max (for example a counter or a shopfront in a `.max` file) and bring its geometry into AutoCAD. Every length the tools return is in millimetres, whatever the scene's system units.

## Before you start

1. `connection_status` or `max_list_sessions`. With several 3ds Max windows, pass `session_id` on every call.
2. The user opens the `.max` file in 3ds Max. Never open, merge, save or close scenes yourself unless asked.
3. `max_scene_info`: note `scene`, `system_units` and `mm_per_unit`. A `mm_per_unit` that looks wrong for the model's size (a 2.4 m counter reading 2.4 mm) means the scene units are off: tell the user, do not rescale silently.

## Read the model

1. `max_list_objects` (geometry, visible). Use `name_contains`, `layer` or `selected_only` to narrow it. Ask the user to select the item in 3ds Max when the names are unclear (Box001, Object023).
2. `max_get_object` on the main parts: bounding box, face count, material colour and texture names. The bounding boxes give overall length, depth and height.
3. List the measured key dimensions for the user and ask which are client-confirmed before drawing. A render or concept model is not a setting-out drawing.

## Cut plans and sections

`max_section` cuts the meshes with a plane and returns closed and open polylines per object:

- Plan: `axis: "z"`, `offset_mm` = cut height (for a counter: just below the top, at drawer height, and at the plinth). Points are world X, Y.
- Elevation or section: `axis: "x"` or `"y"` at the cut position; the second coordinate is the height. Use `point` + `normal` for a cut square to a curved or angled counter (normal along the radius at that point).
- `tolerance_mm` 0.5 (default) for drawings; 0 only to check raw mesh points. Large scenes: pass `handles` of the parts you need and keep `max_faces` reasonable.
- `output_dxf: true` writes an R12 DXF, one layer per object (`MAX_SECTION_<object>`), into `%LOCALAPPDATA%\BIM-CAD-MCP\exports\3dsmax` unless `output_folder` is given. Files are never overwritten.

Curved fronts come back as many short segments; for the drawing, read the radius from the points (three points on the arc) and draw true arcs in AutoCAD rather than tracing the mesh. Meshes from renders are often not closed or watertight: an open polyline is normal, not an error.

## Bring it into AutoCAD

Use the AutoCAD tools and the `counter-detail-sheet-prep` skill: dry run, then draw 1:1 in mm in a free region of model space on the project layers. The section polylines are reference geometry; redraw clean joinery lines (panel thicknesses, worktop, plinth) from the measured values. Keep the 3ds Max origin: one shared origin lets the plan, elevations and sections line up.

## Other tools

- `max_capture_viewport`: a PNG of the active viewport, to check what you measured or to show the user.
- `max_export`: OBJ, FBX or DWG of chosen objects to a new file (not the scene).
- `execute_max_python`: only for what the tools above cannot do. `read` first; `write` only when the user asked for a change in 3ds Max, with `expected_scene`. Never save the scene unless asked.

## Privacy and safety

- The bridge answers only on this computer, only to the signed-in Windows user, and only to Smart Connector with the session token. It has no network access.
- Results go to the AI client that asked. Texture and file references are returned as file names only.
- Exports into a cloud-synced project folder (ACC, OneDrive) are uploaded by that sync; the default exports folder is local.
- To switch the bridge off: create the empty file `%LOCALAPPDATA%\BIM-CAD-MCP\runtime\max-bridge-disabled` and restart 3ds Max.
