---
name: revit-grouped-dimension-dm
description: Safely update linear dimension types inside Revit detail groups across selected views or sheets while preserving groups, reusing one canonical DM copy per original group type, and cancelling every ungroup request.
---

# Revit Grouped Dimension DM

Use this workflow when dimensions in selected Revit views must change type and some dimensions belong to detail groups.

## Required invariants

- Never ungroup. If Revit offers **Ungroup**, choose **Cancel** or the equivalent negative option.
- Create at most one reusable duplicate for each original detail-group type. Name it `<original group name> - DM` and reuse it on every selected level or view.
- Preserve existing group instances and unrelated views. Reassign only instances in the requested views to the canonical DM group type.
- Change only linear dimensions unless the user explicitly asks for another dimension style. Leave spot, radial, angular, and other non-linear annotations unchanged.
- Verify the result from the model after each group is finished; do not rely only on a successful command response.

## Workflow

1. Resolve the target views. When sheets are selected, use their primary placed plan views if that matches the user's current sheet-to-view workflow.
2. Resolve the exact target `DimensionType` by name and verify it is a linear dimension style.
3. Audit target views and separate ungrouped linear dimensions from grouped linear dimensions. Record affected group types and representative group instances.
4. Change ungrouped linear dimensions directly through the Revit API in small committed batches.
5. For each affected original detail-group type:
   - Find or create the single canonical `<original> - DM` type.
   - Reassign all affected instances in the requested views to that canonical type.
   - Select one visible representative instance and enter Revit **Edit Group** mode.
   - Zoom out until every member of the group is visible. A partial window selection can miss dimensions outside the current display.
   - Crossing-select all editable group members, use Revit **Filter**, and keep only **Dimensions** selected.
   - Confirm the filtered count matches the API audit for the representative group. If it is lower, zoom farther out and repeat the selection.
   - In the Properties type selector, search for and choose the exact requested dimension type.
   - Click **Finish** to close Edit Group.
6. Re-audit the canonical group type. Confirm all linear dimension members use the target type and that group instances still exist under the canonical DM type.
7. Run a final audit across all requested views and report converted linear dimensions, skipped non-linear annotations, and any remaining mismatches.

## Revit 2024 behavior

In this environment, changing a group member through the API outside Edit Group raises “Changes to groups are allowed only in group edit mode” and offers Ungroup. Cancelling that dialog rolls back the attempted group-member transaction. Revit 2024 does not expose a usable `GroupEditScope` through this connection, and MCP external events do not run while the interactive Edit Group command is active. Use the Revit UI for the member-type change and the API for auditing, duplication, reassignment, and ungrouped dimensions.

Keep mutations small and independently committed. Long bulk transactions can time out or roll back even when an intermediate response looks successful.
