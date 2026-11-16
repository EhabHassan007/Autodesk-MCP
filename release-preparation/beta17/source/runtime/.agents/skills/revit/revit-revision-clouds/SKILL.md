---
name: revit-revision-clouds
category: revit
description: Compare host elements (for example columns, or shafts on request) against a linked model, cloud the differences in a set of plan views with a note on each cloud, on an open revision, and hide the old clouds. Use for link-coordination markups, revision clouds, change clouds and cloud notes in batches.
---

# Revit revision clouds with notes

Follow the Revit rules first (`get_revit_rules`), then `revit-csharp-runner` for the runner contract, errors and jobs. This skill is the workflow for clouding differences between the host model and a link. It was built from two live sessions (115 column clouds in 20 plans; 77 column clouds in a workshared model with more than 200 links), and the failures it guards against all happened.

## Before anything is created

1. `list_sessions`, `document_info`, `connection_status` (Revit must report idle). If every call is refused with "More than one Revit session is running", follow `revit-model-operations-recovery`.
2. Agree the scope with the user: which categories (columns by default; shafts only when asked), which linked model, which view template, which revision. Nothing is written before this.
3. Resolve every object by a stable key at the start of each session and again after any restart or synchronisation, never from an id remembered from earlier (a restart changed a revision's id, and a count by the old id reported zero clouds):
   - the revision by sequence number and description;
   - the views by name and view template;
   - the note text type by name (the office's 2 mm red type);
   - the link instance by name and loaded state.
4. `revision_cloud_info` with the target view ids. It returns the revisions (id, number, issued), the Revision Cloud Tags types with `likely_tag`, and for each view whether it is dependent and which primary view holds its annotations.
   - Annotate **primary views only**. A dependent view shows its primary view's clouds; creating them in both gives duplicates.
   - The revision must be the one the user named, must exist and must not be issued. Create a new revision only when the user asks; it is a separate, approved step done in Revit's Sheet Issues/Revisions dialog or by a reviewed script.
   - If `likely_tag_types` is 0 there is no real cloud tag family loaded. Ask whether to use text notes or to load a tag family. Do not promise tags.
5. Ask the user to close views they do not need.

## Comparing host and link

Do the comparison with read-only `execute_csharp` calls, one or two views at a time.

- **Units.** Revit's internal length unit is the foot. Convert with `UnitUtils.ConvertFromInternalUnits(value, UnitTypeId.Millimeters)` before comparing with any value stated in mm. State the position tolerance in mm in the report; use 10 mm unless the user gives another value, and confirm it on the first run.
- **Transforms.** Bring linked positions into host coordinates with the link instance's `GetTotalTransform()`. If the linked model is nested inside another link, combine the parent instance's total transform with the nested instance's transform. Before batching, check one known column by eye against the host position.
- **Which elements a view compares.** For each target plan view, take the cut-plane elevation from its view range (level elevation plus cut-plane offset). Compare only host and linked elements whose vertical extent, in host coordinates, crosses that elevation. This replaces any test of height overlap between host and link: multi-storey structural columns and per-floor architectural columns would fail such a test, and matching by plan position alone across all levels hides a column that is missing on one level but present on the same grid on another.
- **Position.** Match by insertion point (`LocationPoint.Point`, transformed), within the tolerance. Do not use the bounding-box centre: rotated and corner columns give wrong positions. Do not consume matches one-to-one in a greedy loop; a host element may legitimately match more than one linked element, and greedy consumption produced false "not in link" results.
- **Section.** Read width and depth from the family type name first, because linked families may have no width/depth parameters and no symbol geometry. Take the last `number x number` pair in the name (`...C2(400x800)` gives 400 and 800, not 2 and 400). Fall back to type parameters when the name has no pair. Never use the bounding box, which is inflated when the element is rotated.
- **Rotation.** Compare orientation as well as size. Host angle is `LocationPoint.Rotation`; linked angle is its own rotation plus the link transform's angle (`atan2(BasisX.Y, BasisX.X)`). For rectangular sections compare modulo 180 degrees. A section with width and depth swapped and a 90-degree turn has the same footprint and is a match; the same type rotated 90 degrees is a difference.
- **Separate groups, held back:** angled or corner columns; host elements with no linked partner; types whose size cannot be parsed (round sections given by diameter only, names with no dimensions). List each group on its own and do not cloud it until the user has checked it.

Report the differences by view and by kind (missing in link, size differs, orientation differs, position differs, held back) and get the user's approval of the list before any cloud is created.

## Creating the clouds

- Use `create_revision_clouds`: one call per primary view, at most 40 boxes per call, boxes in model-space millimetres (`x_min_mm`, `y_min_mm`, `x_max_mm`, `y_max_mm`), an optional `comment` (the cloud's Comments value) and an optional `note` placed beside the cloud (`note_side` right or left, `gap_mm`, `note_type_id`).
- **Dry run first.** Run the first view with `dry_run=true`, show the user the counts, and wait for their yes before the real run. The dry run rolls back changes in the host document only; it does not cover a script that also changes another open document. In a workshared model it can leave elements checked out until the next synchronise.
- **Partial failures.** `create_revision_clouds` creates each cloud, then its comment, then its note, inside one transaction per call, and an item that fails is reported but not undone. If the note fails, the cloud stays in the model with no note and the item is listed under `failed`. Never resend a failed item as it is: add the missing note to the existing cloud instead, or with the user's approval delete that one cloud first.
- **Duplicate guard.** Start each cloud's comment with a key for the host element, `HOST:<UniqueId> | <reason>`. The comment is written before the note, so a cloud whose note failed still carries its key. Before every batch, and always before continuing after a timeout, a failed item or a restart, read the clouds already on that revision in that view and skip any element whose key is already there.
- Expand each box by a margin so the cloud reads around the element, and keep boxes inside the view's crop where possible.
- **Note gap.** The team rule is a note beside its cloud, 200 mm clear of the cloud edge, with no leader. The drawn cloud's arcs bulge beyond its sketch, so a gap measured from the sketch box overlaps the cloud. `create_revision_clouds` currently measures `gap_mm` from the box you pass, so after each batch read the drawn cloud's bounding box in the view (`get_BoundingBox(view)`, after the batch's single regeneration) and check the note clears it.
- After each batch, read back: count clouds and notes per view and revision with a read-only `execute_csharp`, compare with the requested counts, and report created, failed (with the reason per item) and remaining. Trim `TextNote.Text` before comparing note text: it ends with a line break, and an untrimmed comparison finds no pairs.
- The tool does not resolve overlaps between notes or against other annotation. Check overlaps in a separate light read, one view at a time, and move a note only when the user wants it.

## Hiding old clouds

Hide the previous revision's clouds in each target view by hiding the cloud elements in the view, unless the user confirms another method. Do not change the revision's project-wide visibility in Sheet Issues/Revisions, which affects every view and sheet. Deleting is not hiding and needs the user's explicit request. Hiding is a change in each view: show the list of clouds to hide, do it in batches per view, and read back that exactly the old clouds are hidden and the new ones are visible.

## Verify and checkpoint

- Count clouds and notes with two independent methods (by revision, resolved from its sequence number, and by view) before telling the user a count or a loss.
- Report clouds and notes per view, differences by kind, held-back elements, and hidden older clouds.
- Ask the user to synchronise after each milestone. Edits after the last synchronise can be lost when Revit restarts: after one overnight restart, 115 clouds and 115 notes came back as 114 and 109. After a restart, recount what survived before creating anything.

## Recovery

- `completed=false` with a `job_id`: wait and call `get_job`; never run the batch again.
- `[busy]`, or `connection_status` reporting `revit_busy` (for example Generating graphics): nothing new ran. Wait until it reports idle, read the model state, then continue with the remaining items only, using the duplicate guard.
- Never delete and recreate every cloud and note in one transaction. One transaction of 173 clouds and 173 notes in a 236-link model timed out at 120 s and left Revit unresponsive for about 15 minutes. If a batch has to be redone, delete only that revision's clouds in that view, with the user's approval, then create them again in batches of 40.
- Nothing is saved or synchronised unless the user asks.

Verification status: workflow and failure causes taken from two live Revit 2024 sessions. The `revision_cloud_info` and `create_revision_clouds` tools were written afterwards and are compiled and simulated but not yet run in a live Revit session; the first live use of each should be one view, dry run first. The cut-plane filtering, rotation comparison, nested-link transform and comment-key duplicate guard are review additions not yet run live; confirm each on the first view.
