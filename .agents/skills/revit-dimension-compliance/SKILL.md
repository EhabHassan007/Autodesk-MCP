---
name: revit-dimension-compliance
description: Audit and, with phased approval, align Revit walls, columns, openings, and slab edges to clean grid or host references with dedicated check views and verification dimensions.
---

# Revit dimension compliance

Use a project-approved snap module, tolerance, dimension type, check-view template, browser parameters, and scope. Grids are reference geometry unless the user explicitly approves a grid correction.

## Mandatory phases

1. **P0 Audit, read-only:** inventory grid systems, in-scope elements, levels, existing check views, templates, and dimension types. Report exceptions.
2. **P1 Check views:** after approval, create the check template, view set, and check dimension type. Move no model elements.
3. **P2 As-is evidence:** after approval, create dimensions and angle checks on current geometry. Export non-clean values and elements that cannot yet be dimensioned.
4. **P3 Corrections:** require separate approval and dry-run data for walls, doors, windows, and optional slab boundaries. Correct walls before hosted inserts. Work in small batches.
5. **P4 Verification:** read every check dimension, verify counts after regeneration, confirm insert positions, and issue a final exceptions report.

## Geometry rules

- Group straight grids by actual direction and support rotated or radial systems.
- Align each element to its nearest applicable grid direction; report intentional angled elements instead of forcing them.
- Measure offsets to the relevant element face, not automatically to the centreline.
- Move doors and windows only along their host wall and reference the nearest valid wall end or intersection, never a remote grid.
- Preserve hosts, types, sizes, sill heights, levels, and slab construction.
- Skip pinned, grouped, curved, in-place, or unsupported geometry and report it.

## Execution safety

Before each correction batch, preserve original positions and write a reviewable dry-run file. Ask the user to synchronize at phase milestones. After a timeout, establish that the MCP is responsive and perform a fresh read-back before continuing. Do not trust the next response after a timed-out call without checking it. Remove or reduce heavy associative check dimensions before large moves if regeneration becomes unsafe, then rebuild them for verification.

Report maximum shift and rotation, changed ids, skipped items, undimensionable axes, and final non-clean dimensions. Never claim compliance from transaction success alone.

Verification status: operational guide captured; exact tolerances and live behavior must be validated against the current company standard and model.
