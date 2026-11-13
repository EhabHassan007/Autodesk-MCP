---
name: revit-link-comparison-revision-clouds
category: revit
description: Compare host columns (or shafts) against a linked structural model, cloud the differences in plan views on a new revision, add a note beside each cloud, and hide superseded clouds. Use for link-coordination markups where clouds and notes must be created in batches without timeouts or duplicates.
---

# Link comparison and revision clouds

Use this when the host architectural model must be checked against a linked model (typically structure), and every difference is marked with a revision cloud and a note in the plan views that use a given view template. The procedure below was demonstrated on a workshared model with more than 200 links; the failures it avoids all happened.

Start with `get_revit_rules`, `document_info`, and `list_sessions`. Do not write until the user has approved the scope: which categories (columns, shafts), which linked model, which view template, which revision.

## 1. Resolve objects by stable keys

Element ids can change after a Revit restart or a synchronisation. Resolve each of these at the start of every session, and again after any restart, never from a remembered id:

- the revision, by sequence number and description (a restart changed one revision's id and a count by the old id wrongly reported zero clouds);
- the views, by name and view template;
- the note text type, by name (the office's 2 mm red text type);
- the link instance, by name and loaded state.

Confirm the revision exists and is the one the user named before creating anything. Create a new revision only when asked.

## 2. Compare host and link

- Transform linked geometry into host coordinates with the link instance total transform.
- Match host to linked elements by **insertion point** within a stated tolerance. Do not match by bounding-box centre: rotated and corner columns give wrong positions.
- Do not consume matches one-to-one in a greedy loop. A host element may legitimately match more than one linked element, and greedy consumption produced false "not in link" results.
- Do not decide a match with a height-overlap test.
- Compare sections from the family **type**, not the bounding box, which is inflated when the element is rotated. Parse "width x depth" from the type name (a name such as `...C2(400x800)` must yield 400 and 800, not 2 and 400). Linked families may have no width/depth parameters and no symbol geometry, so read the type name first.
- Report angled and corner columns as a separate group, not mixed with the plain result.
- Host elements with no linked partner are a distinct list. Hold them back until the user has checked them visually; do not cloud them automatically.
- Shafts are compared and clouded only when the user asks for them. Remove them when the user says so.

## 3. Choose the views

Annotate **primary views only**. A dependent view shows the primary view's annotations, so clouds and notes placed in both appear twice. Check `GetPrimaryViewId` and skip dependents. Filter by the view template the user named.

## 4. Clouds and notes

- Put each cloud on the new revision. Write the reason into the cloud's Comments parameter by `LookupParameter("Comments")`; `BuiltInParameter.REVISION_CLOUD_COMMENTS` does not exist in Revit 2024.
- Before promising revision cloud tags, check that a real cloud tag family is loaded. A category named for cloud tags may hold a mis-categorised family that cannot be cast to a tag. If no real tag family is loaded, ask the user whether to use text notes. The team rule is that a tag or note sits beside its cloud with no leader.
- Place each note beside its cloud. Measure the gap from the **drawn** cloud bounding box, not from the sketch line: the arcs bulge beyond the sketch and a gap taken from the sketch overlaps every cloud.
- Compare note text only after trimming: `TextNote.Text` carries a trailing line break, and an untrimmed comparison finds no pairs.
- After placement, check that no note overlaps a cloud or another note.

## 5. Superseded clouds

Hide the older clouds rather than deleting them, unless the user asks for deletion. After hiding, read back that the new clouds are visible and the old ones are not. The handoff does not record the hiding method; choose the narrowest one (element hide in the view) and verify it.

## 6. Batch, do not rebuild

- At most about 25 creations per call, with a remaining-count loop and one regeneration per batch.
- Never delete and rebuild every cloud and note in one transaction. One transaction of 173 clouds and 173 notes in a 236-link model timed out the runner at 120 s and left Revit silent for about 15 minutes.
- After a timeout, do not re-run. Wait for the Revit status bar to clear, read `connection_status`, read the model state, and only then continue with the remaining items.
- Test an unfamiliar API call on one element first.

## 7. Verify and checkpoint

- Count clouds and notes with two independent methods (for example by revision id resolved from the sequence number, and by view) before telling the user a count or a loss.
- Report: clouds per view, notes per view, differences found by type (missing in link, size differs, position differs, angled or corner), held-back elements, hidden older clouds.
- Ask the user to synchronise after each milestone. Edits made after the last sync can be lost when Revit restarts: after one overnight restart, 115 clouds and 115 notes came back as 114 and 109.
- Saving and synchronising remain the user's actions.

Verification status: procedure and failure causes taken from one live Revit 2024 session (final state: 77 column clouds with notes, no overlaps, 16 older clouds hidden). The hiding method and tolerance values were not recorded; confirm both on the first run.
