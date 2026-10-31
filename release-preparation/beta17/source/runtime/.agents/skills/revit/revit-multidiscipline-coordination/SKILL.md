---
name: revit-multidiscipline-coordination
category: revit
description: Coordinate architectural, structural, MEP, facade, interior, and landscape Revit models using links, shared coordinates, levels, grids, spatial checks, and traceable issue reporting. Use for federated-model review and clash triage.
---

# Revit multidisciplinary coordination

Treat coordination as a read-only investigation until the user approves specific model changes. Begin with current document identity and loaded-link status; never reuse element ids from an earlier Revit session without inspection.

## Build the coordination context

1. List the host model and every linked model with discipline, instance name, load state, path availability, positioning method, transform, and shared-site information when available.
2. Identify the coordination basis: internal origin, project base point, shared coordinates, survey coordinates, or an agreed control file. Flag mixed positioning methods and unexplained transforms.
3. Record the current phase, design option, workset visibility, and view filters because they can hide or duplicate apparent issues.
4. Obtain the project's clash matrix, responsibility matrix, and tolerance rules when they exist. If they are absent, report geometric overlaps and proximity candidates without claiming a contractual clash.

## Review in this order

1. **Link health** â unloaded, missing, nested, duplicate, mirrored, or unexpectedly scaled/rotated links; obsolete file versions; and multiple instances of the same model.
2. **Coordinates** â control-point agreement, true/project north, elevations, units, and building placement. Compare geometry only after transforming linked coordinates into the host system.
3. **Levels and grids** â name, elevation, extent, and alignment differences. Distinguish intentional discipline offsets from mismatches that affect hosting or documentation.
4. **Spatial ownership** â identify which discipline owns slabs, openings, shafts, ceilings, equipment zones, facade zones, and site interfaces. Flag duplicated elements across models and gaps with no owner.
5. **Hard clashes** â actual solid intersections, with host/link element ids, categories, types, levels, and approximate intersection location. Do not call a bounding-box intersection a confirmed clash.
6. **Clearance checks** â access, maintenance, headroom, door swing, equipment replacement routes, ceiling zones, risers, and facade interfaces. Use only agreed clearance values.
7. **Continuity checks** â floor openings, shafts, stairs, ramps, risers, drainage routes, walls at slabs, facade edges, and site/building connections across levels and disciplines.
8. **Documentation interfaces** â grids, levels, room/space boundaries, penetrations, sleeves, builder's-work openings, and drawing references that should agree across models.

## Triage rules

- Group repeated clashes by rule, location, and involved systems instead of creating an unreadable flat list.
- Exclude approved exceptions, duplicates caused by link instances, temporary construction, and elements hidden by the intended phase only when evidence supports the exclusion.
- Assign each issue to the discipline that controls the correcting element. When ownership is ambiguous, mark it for coordination rather than guessing.
- Record both host and linked element identity. Include link instance identity and transformed location so another reviewer can reproduce the issue.
- Preserve previous issue ids where possible and classify each rerun as new, persistent, resolved, or changed.

## Issue register

For every issue, include:

- issue id, title, priority, status, and responsible discipline;
- host model, linked model, link instance, level, grid/zone, and coordinates;
- involved element ids, categories, and types;
- rule or agreed tolerance used;
- observation, design impact, and recommended next action;
- evidence and verification method;
- date reviewed and resolution note.

Use screenshots or section-box views when available, but retain element ids and locations because images alone are not reproducible evidence.

## Model changes

Do not move, delete, rehost, resize, or change linked elements from the host coordination session. For an approved host-model correction, inspect the target, make the narrowest change, read it back, and rerun the affected coordination check. Keep saving and synchronization explicit.

## Deliverable

Report coordinate and link blockers first, because they can invalidate every later clash result. Then provide issue counts by discipline, priority, status, and level, followed by the prioritized issue register and a short list of checks that still require visual review or discipline-owner confirmation.
