---
name: detail-generator
category: autocad
description: Generate a draft construction detail in AutoCAD from a short brief, in millimetres: a vertical section through a reception counter (boards, plinth, Corian or stone top, optional raised bar, wheelchair-accessible variant), or a section of any joinery from a parts list read off pictures, with hatches, dimensions, levels and notes, in model space or in a paper-space layout. Use when asked to draw or revise a counter section, or to start a new joinery detail from parameters.
---

# Detail Generator

`generate_detail` turns a brief (a template name and a few parameters) into an `apply_plan` plan and, when asked, draws it. Everything it makes is a **draft for a designer's review**: confirm dimensions and construction with the project designer, and the accessible section with the authority or consultant.

## Workflow

1. `drawing_info` for the drawing id. The drawing must be in millimetres (`units_code` 4); the tool refuses anything else and draws nothing. For a new drawing use a millimetre template such as `acadiso.dwt`.
2. Agree the parameters with the user. Everything has a default except the accessible section's values (see below). Ask for what the brief leaves open instead of guessing: depth, top height, top material, whether a raised bar or an accessible section is wanted.
3. Call `generate_detail` with `apply` false first (the default) and `return_plan` if the steps are wanted. AutoCAD is not contacted; you get a summary and warnings. Show the summary and any warning to the user.
4. Call it with `apply` true and `expected_drawing` set. `dry_run` defaults to true: read what it would create, then repeat with `dry_run` false. Choose `origin` (where the floor meets the staff face) so the section does not overlap existing work; a free area to the right of the drawing is usual.
5. Verify: `count_matches_plan` true, then read a sample back with `get_entity`. Tell the user the drawing is unsaved. One `UNDO` removes the whole detail. Save only when asked.

Read [reception counter section](references/reception-counter-section.md) for the parameters, defaults, what is drawn and what is not.

## Annotation: model space, paper space, or none

`annotation` chooses where dimensions, notes, levels and titles go.

| Value | What you get |
|---|---|
| `model` (default) | Everything in model space at the detail scale (text 2.5 x the scale denominator). |
| `paper` | Geometry in model space; dimensions, notes, levels and titles in the layout named by `layout`, at **true paper size: notes and levels 2.5 mm, title 3.5 mm**. Dimensions measure paper distances and carry `linear_factor` = the scale denominator, so they read the model size. |
| `none` | Geometry only (parts, hatches, floor line). |

For `paper`, pass `layout` (with `apply`). **Recommended: `create_viewport` true.** The tool then makes the viewport itself on layer `G-ANNO-VPRT` (created not plotted, colour 8; an existing layer is used as it is): at `view.paper_centre`, which defaults to the centre of the layout's sheet when applying (approximate by a few millimetres because of printer margins), sized to the parts plus 10 mm each side or `view.viewport_size [w, h]` in paper mm, set to 1:scale with its view centred on the detail's model centre, and display-locked. It is made last, in its own Undo group (three groups in all: geometry, annotation, viewport); if it fails, it is removed and the message says the geometry and annotation stay. The view centre is set by zooming before the scale is set; AutoCAD cannot read it back, so check the first result by eye. Without `create_viewport`, pass `view.paper_centre` = the Center of an existing 1:scale viewport whose view is centred on the result's `model_centre`; the tool warns (`viewport_warning`) if the layout has no viewport at that scale but cannot check the centre. Optional `view.model_centre`; the default is the centre of the parts. Office level blocks can be used with `level_block` (and `level_tag`, default `LEVEL`, `level_block_scale`).

Both plans are checked against the drawing before anything is drawn. If the annotation fails after the geometry was drawn, the annotation is rolled back and the message says the geometry stays; undo once to remove it.

## Working from renders and plans

The usual brief is not a list of parameters but **rendered pictures from several angles, plans, and some dimensions**. Do not draw from the pictures directly.

1. Read the pictures and plans and write an **interpretation list**: the parts, their materials, the overall length, depth and heights, and any special feature (curves, steel frames, glass, lighting).
2. Mark every number as **given** (from the user's dimensions or plan) or **estimated from the picture**. Pictures have no scale, so ask for at least two real dimensions per view, such as an overall length and a counter height. Never present an estimate as a fact.
3. Show the list and the open questions, and **wait for the user's confirmation or corrections** before drawing anything.
4. Build from the confirmed design, sections first, then plan and elevations, as drafts for review. Use `template` `custom_section` for anything the reception template does not cover: the confirmed list becomes `params.parts` (id, material, x0, y0, x1, y1 in mm; x from the staff face, y up from the floor), with `levels`, `notes`, `dimensions` and `title` written from the specification. Every number and every word of a note is yours to supply; the generator invents none, warns when parts have no note, refuses overlapping parts and unknown materials (mdf, ply, stone, corian, steel, glass, outline), and does not check the design against the pictures or any code.

Where the pictures show something the template cannot draw yet, say so and offer the nearest standard construction, clearly marked.

## Rules

- Millimetres only. Never convert or reinterpret units.
- Existing layers are left as they are (their colours and lineweights are not changed). Pass `update_layers` only when the user asks for the generator's layer settings.
- **The accessible section has no built-in numbers.** It needs `accessible_height`, `knee_clearance_height`, `knee_clearance_depth` and `code_reference`, taken from the code and edition the project uses. Never fill them from memory, and never carry a figure from one jurisdiction into another. The generator prints the code reference on the drawing, marked "to be verified".
- Top material follows the item: Corian (the default) for counters, stone for kitchens and F&B.
- Do not copy dimensions or curves from one project's drawing into a default. The defaults come from conventions repeated across the office's kitchen and joinery sheets; anything specific to one counter is an option.
- **Annotation follows the reference sheets.** When the drawing has them, dimensions use style `na1`, notes and levels use text style `EN-S`, and titles use `EN-SCB`; the result lists them under `reference_styles` and says in `style_notes` which are missing. Pass `dimension_style` or `text_style` to override, or `use_reference_styles` false to use the current styles. See the reference for the numbers behind these styles.
- Dimension and text sizes depend on the style and the detail scale. In model space the generator sets each dimension's scale to the detail scale, so a 3.5 mm style prints 3.5 mm at that scale; check the first dimension on screen, and if the size is wrong pass `dimension_scale` or fix the style. In paper space the style's own size applies (no scale is set unless `dimension_scale` is given).
- If the plan is refused, the message names the step; fix the parameter and retry. A failed plan removes what it created.
