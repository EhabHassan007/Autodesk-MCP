---
name: revit-areas-rooms-numbering
description: Coordinate Revit areas, rooms, linked-room naming, spatial numbering, terrace ownership, and door marks. Use when architectural spatial data must be derived or checked across host and linked models.
---

# Revit areas, rooms, and numbering

Start with fresh document identity, level scope, phase, area scheme, loaded links, room-bounding conditions, and the project's naming and numbering rules. Perform a dry run before every bulk write.

## Area boundaries and naming

- When the requirement is wall-centre boundaries, derive them from wall location curves. Room closed-shell geometry and face boundaries can wrap around columns or follow finishes.
- Linked walls require their link instance transform. Build closed loops by ordering and trimming or extending curves at intersections, then verify placed-area values.
- Name an area from a linked room only after transforming the area point into the linked document and proving the point lies in the room.
- Skip grouped areas and report them. Renaming one member can trigger a group edit or roll back a batch.
- For terraces or small ancillary areas, use an approved rule such as longest shared boundary with a parent unit. Survey placeholder names and exclusions before applying it.

## Linked and nested rooms

For nested or repeated unit links, calculate a local bounding region from link-document geometry when a host bounding box is unavailable. Transform each room point into local coordinates and test both horizontal containment and vertical proximity. Avoid world-axis bounding-box matching for rotated or stacked instances.

## Room numbers and door marks

- Derive the floor from the room's actual level rather than its existing number.
- Choose and document the spatial ordering rule: coordinate order, user-selected anchors, or an agreed corridor path.
- Export the proposed room-number mapping, check duplicates and collisions, and obtain approval before writing.
- Derive a door mark from its phase-correct To Room or From Room. Prefer the specific room over a general circulation space when the project rule says so.
- Assign deterministic suffixes when several doors serve one room, and provide a QA schedule containing door, mark, From Room, and To Room.

Never invent missing room, unit, or department data. Verify changes with a separate read-back and report unplaced, unenclosed, unmatched, grouped, duplicate, and ambiguous items.

Verification status: guide-derived workflow; project naming patterns and thresholds require confirmation before live use.
