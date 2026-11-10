---
name: detail-generator
category: autocad
description: Generate a draft construction detail in AutoCAD from a short brief, in millimetres: a vertical section through a reception counter (boards, plinth, Corian or stone top, optional raised bar, wheelchair-accessible variant) with hatches, dimensions, levels and notes. Use when asked to draw or revise a counter section, or to start a new joinery detail from parameters.
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

## Rules

- Millimetres only. Never convert or reinterpret units.
- Existing layers are left as they are (their colours and lineweights are not changed). Pass `update_layers` only when the user asks for the generator's layer settings.
- **The accessible section has no built-in numbers.** It needs `accessible_height`, `knee_clearance_height`, `knee_clearance_depth` and `code_reference`, taken from the code and edition the project uses. Never fill them from memory, and never carry a figure from one jurisdiction into another. The generator prints the code reference on the drawing, marked "to be verified".
- Top material follows the item: Corian (the default) for counters, stone for kitchens and F&B.
- Do not copy dimensions or curves from one project's drawing into a default. The defaults come from conventions repeated across the office's kitchen and joinery sheets; anything specific to one counter is an option.
- Dimension and text sizes depend on the dimension style and the detail scale. The generator sets each dimension's scale to the detail scale; check the first dimension on screen, and if the size is wrong pass `dimension_scale` or fix the style.
- If the plan is refused, the message names the step; fix the parameter and retry. A failed plan removes what it created.
