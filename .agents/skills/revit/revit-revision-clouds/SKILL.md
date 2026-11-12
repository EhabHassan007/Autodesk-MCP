---
name: revit-revision-clouds
category: revit
description: Cloud the differences between the host model and a linked model (for example structural columns against the STR link) in a set of plan views, with a note on each cloud, on a new revision, and hide the old clouds. Use for revision clouds, change clouds and cloud notes in batches.
---

# Revit revision clouds with notes

Follow the Revit rules first (`get_revit_rules`), then `revit-csharp-runner` for the runner contract, errors and jobs. This skill is the workflow for clouding differences between the host model and a link, built from a session that did it for 20 plans.

## Before anything is created

1. `document_info`, `connection_status` (Revit must report idle), and the list of views to work in. Confirm the view template that governs the target plans, and ask the user to close views they do not need.
2. `revision_cloud_info` with the target view ids. It returns the revisions (id, number, issued), the Revision Cloud Tags types with `likely_tag`, and for each view whether it is dependent and which primary view holds its annotations.
   - Annotate **primary views only**. A dependent view shows its primary view's clouds; creating them in both gives duplicates.
   - The revision must exist and must not be issued. If the user wants a new revision, creating it is a separate, approved step done in Revit's Sheet Issues/Revisions dialog or by a reviewed script; clouds cannot be added to an issued one.
   - If `likely_tag_types` is 0 there is no real cloud tag family loaded. Ask whether to use text notes or to load a tag family. Do not promise tags.
3. Compare the two models and list the differences before drawing anything: for each element, its position in host coordinates (apply the link instance's total transform to linked geometry), the level and the target view. Report counts per view and ask for approval of the list.

## Creating the clouds

- Use `create_revision_clouds`: one call per primary view, at most 40 boxes per call, boxes in model-space millimetres (`x_min_mm`, `y_min_mm`, `x_max_mm`, `y_max_mm`), an optional `comment` (the cloud's Comments value) and an optional `note` placed beside the cloud (`note_side` right or left, `gap_mm`, `note_type_id` for the text note type the office uses, for example a 2 mm red type).
- Run `dry_run=true` first on the first view and show the counts. A dry run in a workshared model can leave elements checked out until the next synchronise.
- Expand each box by a margin so the cloud reads around the element, and keep boxes inside the view's crop where possible.
- After each batch, read back: count clouds and notes per view and revision with a read-only `execute_csharp`, compare with the requested counts, and report created, failed (with the reason per item) and remaining.
- The tool does not resolve overlaps between notes or against other annotation. Check overlaps in a separate light read, one view at a time, and move a note only when the user wants it.

## Hiding old clouds

Hide the previous revision's clouds in each target view, with the method the user confirms (hiding the cloud elements in the view is the usual one; deleting them is not hiding). Hiding is a change in each view: do it in batches, per view, and read back that exactly the old clouds are hidden and the new ones are visible.

## Recovery

- `completed=false` with a `job_id`: wait and call `get_job`; never run the batch again.
- `[busy]`: nothing ran. Wait for `connection_status` to report idle, then send the batch again.
- Never delete and recreate every cloud in one transaction. If a batch has to be redone, delete only the clouds of that revision in that view, then create them again in batches of 40.
- Nothing is saved or synchronised unless the user asks.

Verification status: created from a real session (115 column clouds with notes in 20 plans); the `revision_cloud_info` and `create_revision_clouds` tools were written afterwards and are compiled and simulated but not yet run in a live Revit session. The first live use of each tool should be one view, dry run first.
