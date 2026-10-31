---
name: revit-views-sheets-workflows
category: revit
description: Manage Revit views, dependent plans, templates, sheets, schedules, legends, check images, and drafting-view reconstruction with dry runs, small batches, and documentation verification.
---

# Revit views and sheets workflows

Read the current document and inventory view types, templates, dependencies, sheets, viewports, schedules, legends, scope boxes, browser parameters, revisions, and worksharing ownership before writing.

## Names, dependent plans, and sheets

- Classify views before renaming and explicitly list excluded coordination, presentation, core, duplicate, or bare-level views.
- Export the proposed old-to-new mapping and resolve invalid characters and duplicate names before applying it.
- Rename in small batches and separately verify view name, title on sheet, sheet name, and sheet number.
- Create partial-plan parents without detailing, then dependent views with approved scope boxes and zero-padded names.
- Duplicate sheets with the intended views and detailing, then restore numbering, browser data, revisions, approvals, viewport types, and positions.

## Templates, schedules, and legends

- Create standard templates from an appropriate source view when direct template duplication or link-override copying is unreliable.
- Preserve filter order, link settings, non-controlled parameters, and scale variants; test one view first.
- For a fixed manual table, keep element rows empty and construct the controlled header/table region, documenting formatting that still needs UI work.
- Maintain separate legends for incompatible sheet scales. When scaling copied detail geometry, preserve a fixed origin and verify filled regions, text, and viewport positions.

## Review images and PDF details

Export moderate-resolution PNG checks from explicit views or sheets. Place schedules on a temporary sheet only when necessary and remove that sheet in a separately approved cleanup.

Reconstructing drafting details from PDF requires extracting vectors, fills, text, and images into reviewable data first. Create a few views per batch, reuse project line/text/fill standards, avoid duplicate view names after timeouts, and verify visually against the source.

Never ungroup, overwrite unrelated templates or types, or treat a timed-out write as failed without read-back. Report created, renamed, skipped, unresolved, and manually verified items. Ask the user to synchronize after major batches.

Verification status: operational guide captured; each mode needs test-view or test-sheet validation before project-wide rollout.
