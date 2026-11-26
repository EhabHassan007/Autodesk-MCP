---
name: revit-facade-modelling
category: revit
description: Survey, change or generate wall-built Revit facades (core + finish-skin walls, hosted windows, balcony bands and railings, louver curtain walls, nested bay-module groups) without ungrouping. Use for facade edits, balcony door resizing and before/after facade studies.
---

# Revit facade modelling

Call `get_revit_rules` first. Facades are usually built from grouped bay modules, so the group rules (RVT-017, RVT-029) decide how a change can be made.

## Workflow

1. **Survey read-only** (RVT-012): walls by kind and type with group membership, location line, base/top constraints; top-level groups per level and their nested module types; windows/doors with host wall and sill/head; railings with base offset and path; curtain-wall grids and mullions; floor-to-floor heights. Report grouped counts only.
2. **State assumptions** (RVT-024) for any missing design value (widths, minimum solid wall, heights) and get confirmation.
3. **Prepare by script**: duplicate new types (RVT-015), list the module group types to change and every floor or facade that nests them, and the planned change per element. Show it as a dry run.
4. **Change one module at a time inside Edit Group**: the user opens Edit Group, the script changes only that module's members, reads back, the user clicks Finish, then read back on another floor that nests the same module. Never ungroup. If Revit shows "Changes to groups are allowed only in group edit mode", stop and ask the user to click Cancel (never Ungroup).
5. **Test on one facade or floor first** (RVT-013) with before/after images from dedicated test views, then roll out after approval.
6. **Verify and report** (RVT-028, RVT-057): read back every changed element and report changed, skipped and manual-review counts.

Windows and doors are hosted only in the core wall; changing an opening also means trimming or moving the finish-wall pieces around it. A global type change (for example a door width) needs no group edit but changes every instance, so use it only when the user accepts that.

## Detailed method (load only when needed)

Read `references/apg-facade-modelling.md` for the full survey list, the core + finish-skin construction, balconies and railings, podium louver curtain walls, the grouped-change pattern, the balcony-door resizing algorithm and the before/after image setup.
