---
name: detail-generator
category: autocad
description: Generate a draft construction detail in AutoCAD from a short brief, in millimetres: a vertical section through a reception counter (boards, plinth, Corian or stone top, optional raised bar, wheelchair-accessible variant), or a section of any joinery from a parts list read off pictures, with hatches, dimensions, levels and notes, in model space or in a paper-space layout. Use when asked to draw or revise a counter section, or to start a new joinery detail from parameters.
---

# Detail Generator

`generate_detail` turns a brief (a template name and a few parameters) into an `apply_plan` plan and, when asked, draws it. Everything it makes is a **draft for a designer's review**.

## Dry run first, then ask (the connector refuses a real run otherwise)
- Call with `apply` false (summary, warnings, `return_plan`), then `apply` true with `dry_run` true. Never `dry_run` false yet.
- STOP and present the brief you will draw: parts with dimensions, levels, notes, dimension chains, title, scale, origin, styles; the drawing (name, path), units, layers created, warnings, what stays untouched. List everything read off a picture or assumed. Wait for an explicit yes.
- After the yes, one real run; check `count_matches_plan` and a `get_entity` sample; do not save unless asked. A changed brief needs a new dry run and a new yes. Only "skip the dry run" in the user's current message overrides this.

## Workflow
1. `drawing_info`; the drawing must be in millimetres (`units_code` 4) or nothing is drawn.
   Read the sheet layout's `layout_details`: `sheet_size_mm` (after rotation) must be the paper the user wants, and `ready` true. A layout with no usable paper size (a freshly opened drawing reads 0 x 0, `ready` false, `sheet_size_mm` null) or the wrong size needs `prepare_layout`: ask which paper (A0 to A4) and orientation; run it with `dry_run` true and show what it would set; after the user's yes, run it for real and check `sheet_size_mm` in the result (A1 landscape reads [841, 594]). It changes the layout's page setup, so it needs its own dry run and yes, and one `UNDO` may not revert it. Also check `existing_viewports`: a viewport covering the sheet must be moved or deleted first.
2. Agree the parameters; ask for what is open (depth, top height, top material, raised bar, accessible section). Never guess a number.
3. Dry run as above, with `origin` (where the floor meets the staff face) in a free area.
4. Tell the user the drawing is unsaved; one `UNDO` removes the detail.

Parameters, defaults and what is drawn: [reception counter section](references/reception-counter-section.md).

## Annotation (`annotation`)
- `model` (default): in model space at the detail scale.
- `paper`: geometry in model space; dimensions, notes, levels, title in the layout `layout` at true paper size (notes 2.5 mm). Use `create_viewport` true. In an office drawing notes are `Multiple Leader Lab` leaders, levels `level indicator`, titles `DWG-VIEWTITLE`; `layer_scheme` auto picks the office layers. All options: [paper annotation](references/paper-annotation.md), [office standard](references/office-sheet-standard.md).
- `none`: geometry only.

## Working from renders and plans
Do not draw from pictures directly: write an interpretation list (parts, materials, dimensions), mark every number **given** or **estimated**, ask for at least two real dimensions per view, and wait for confirmation. Then build with `custom_section`, once per view. How: [working from renders](references/working-from-renders.md), [reading renders](references/reading-renders.md).

## Rules (full list: [rules](references/rules.md))
- Millimetres only. Existing layers are left as they are.
- The accessible section has no built-in numbers: heights and `code_reference` come from the code the user names. Never carry a figure between jurisdictions.
- Annotation follows the reference sheets (`na1`, `EN-S`, `EN-SCB`) when present. Check the first dimension on screen.
- A refused plan names the step; fix it and retry. A failed plan removes what it created.
