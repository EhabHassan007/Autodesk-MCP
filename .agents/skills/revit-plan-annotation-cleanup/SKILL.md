---
name: revit-plan-annotation-cleanup
description: Clean room, area, door, window, and lift tags in Revit plan views while preserving readable placement, room containment, groups, and existing documentation. Use for annotation clash resolution and tag alignment.
---

# Revit plan annotation cleanup

Work view by view and read the current view, scale, crop, links, tags, dimensions, text, and relevant model obstacles before changing anything. Confirm the office's tag types and placement rules instead of assuming them.

## Pass order

1. Remove unwanted leaders from eligible room and door tags in a separate pass. Bounding boxes must be reread afterward because leaders alter them.
2. Add missing lift or shaft-room tags from visible loaded links, using both link instance id and linked room id to detect existing tags.
3. Resolve room-tag clashes. Process identity/name tags before unit tags. Search candidate locations around the current head, score overlaps with annotation and hard/soft model obstacles, penalize unnecessary travel, and require the tag head and visual centre to stay inside its room.
4. Centre door tags on the transformed door insertion point with leaders off.
5. Run a fresh read-back and report remaining clashes and manual-review items.

Use paper-space offsets multiplied by view scale. Prefer spatial indexing over comparing every tag with every obstacle. Read all geometry before moving elements to avoid repeated regeneration. Limit each batch to one to three views.

## Constraints

- Never ungroup or move grouped tags.
- Keep room tags inside their rooms without leaders unless the user approves an office-specific exception.
- Area tags for spaces too small to contain their text may use a short leader only when the applicable standard permits it; try an internal placement first.
- Ignore giant annotation bounding boxes that do not represent a local obstruction.
- Use each `RevitLinkInstance` total transform when reading linked rooms and doors. Skip hidden or unloaded links.
- Do not move clean tags merely to make the layout more uniform.

After writes, separately recount tag types, positions, missing tags, and clashes. Report moved, unchanged, added, skipped, and unresolved counts per view. A successful transaction is not verification.

Verification status: this workflow was captured from an operational MCP guide; apply it first to a test view and obtain visual approval before broad rollout.
