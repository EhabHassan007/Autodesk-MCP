---
name: counter-detail-sheet-prep
category: autocad
description: Produce joinery counter detail packages (plan key, elevations, sections) as DXF/DWG, then prepare the AutoCAD sheet by annotating a layout in the style of a reference layout with short specification leaders, straight arrows, plain dimensions, levels, and section callouts. Use for reception/retail counter details and similar joinery sheets.
---

# Counter details and sheet preparation

Two linked jobs: (A) the counter detail geometry drawn 1:1 in model space, and (B) the sheet: paper-space annotation of the layout viewports that show it. Work as a senior architect: annotation states material, finish, and key size, and nothing else.

Read `drawing_info` before every write, bind work to its exact path, and save only when the user asks. Keep the user's drawing usable: run AutoCAD work in short foreground steps.

## Dry run first, then ask
- Dry run before every write: `apply_plan` with `dry_run` true; `generate_detail` with `apply` false, then `apply` true with `dry_run` true. The connector refuses a real run without a passed dry run of the same plan.
- Then stop and show what will be created (counts by type and layer), layers changed, drawing (name, path), units, warnings, and what stays untouched. Wait for an explicit yes.
- After the yes, run once, check `count_matches_plan`, read a sample back, and do not save unless asked.
- A changed request needs a new dry run and a new yes. Only "skip the dry run" in the user's current message overrides this.

## A. Counter detail package

Follow [references/counter-detail-standard.md](references/counter-detail-standard.md) for views, scales, layers, text heights, and the general notes. In summary:

1. Draw 1:1 in millimetres. Give each view its own model-space region: plan key, front elevation, side elevation, section X1 (counter, 1:10) and section X2 (back wall or cubby, 1:16-1:20). Use client-confirmed dimensions as fixed, and mark scaled-from-render values for verification in your working notes, not on the issued sheet.
2. Use the project layer set: elevation linework, section materials (MDF, solid surface, stainless steel), lighting, hatches, section lines, dimensions, and levels. Gradient hatches and true colours describe finishes.
3. Deliver a DXF. When the user wants DWG, convert it with [scripts/dxf-to-dwg.ps1](scripts/dxf-to-dwg.ps1). This uses AutoCAD COM Open/SaveAs and verifies by reopening the DWG: entity, hatch, gradient, and true-colour counts must match the DXF. Never overwrite an existing DWG.

## B. Sheet preparation from a reference layout

1. **Inspect, read-only.** Dump both layouts' paper-space objects: annotation blocks with their dynamic properties and attribute tags, dimension style, text heights, layers, and viewports. Read viewport view centres with [scripts/get-viewport-centres.ps1](scripts/get-viewport-centres.ps1); COM does not expose them. Plot the reference layout to PNG to see the house style.
2. **Map views.** For each target viewport, find the DXF-to-model offset by matching geometry extents per layer. Paper = viewport centre + (model - view centre) x scale. Write everything into a JSON spec; see [references/annotation-spec.md](references/annotation-spec.md).
3. **Write notes like a senior architect.** One line where possible: material, thickness, finish, and hardware only, e.g. `18MM MDF DRAWER W/ LOCK, WHITE PU`. No `*`, "TO CONFIRM", or "(CONFIRMED)". Drop duplicates, such as the same skirting on both faces of a section. Label the plan too: counter, gate or opening, and the back wall.
4. **Dimensions show plain measured numbers.** No text overrides. Use the reference dimension style and layer, and a DIMLFAC of -1/viewport scale for paper-space dimensions. Remove `*` from level text as well.
5. **Keep leaders straight.** Put each label level with its arrow point (horizontal leader). Merge colliding labels into a group placed at the least-squares position of their targets, then fit groups within the free column. Size columns to the free sheet space so text fits on one or two lines. Labels go to the right of their target; an inner-ring label can sit inside a circular plan.
6. **Build in stages** with [scripts/annotate-sheet.ps1](scripts/annotate-sheet.ps1): test one object of each kind first, then levels, dimensions and callouts, then leaders. Each run uses an Undo mark and logs every new handle. Regenerate the display afterwards: attribute text set through COM may not appear until a regen.
7. **Verify** by handle readback (layer, owner layout, no overrides, horizontal-leader count). Then plot to PNG in a separate short call, recording and restoring BACKGROUNDPLOT. Crop and inspect overlaps. Never use desktop screenshots.
8. **Delete user content only on request**, after a readback (e.g. plain "X1"/"X2" model texts that duplicate new callouts). Recommend saving once the user accepts: unsaved COM work is lost if AutoCAD hangs.

## Safety and recovery

- Never stop a PowerShell task while it holds a COM call into AutoCAD; that deadlocked AutoCAD (0% CPU, about 1,700 threads). Keep plotting out of editing scripts and give foreground calls explicit timeouts.
- If ActiveDocument is null or calls fail with RPC_E_SYS_CALL_FAILED, stop and ask the user whether a dialog is open. If AutoCAD is frozen, copy the latest `.sv$` autosave before force-closing, and only with the user's approval.
- The spec and handle log make the sheet rebuildable from the original drawing in minutes.

COM details and block-parameter mappings are in [references/sheet-annotation-api.md](references/sheet-annotation-api.md).

## Verification history

Live AutoCAD 2025, 2026-10-30/31, on a reception-counter sheet: 85 paper-space objects were rebuilt and saved at the user's request.
- 32 leaders; 26 horizontal.
- 38 rotated and 2 radial dimensions, with no overrides.
- 11 levels and 2 section callouts.

The counter DXF converted to DWG with matching counts: 129 hatches and 27 gradients. These are past-run results, not defaults. The DXF generator script was not available on this computer, so part A records the standard rather than a generator.
