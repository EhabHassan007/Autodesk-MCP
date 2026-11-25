---
name: revit-template-standardisation
category: revit
description: Capture a reference Revit plan's visual standard and roll it out through view templates, filters, dimension types, and tag families with test-view approval and reversible batches.
---

# Revit template standardisation

Confirm the reference model, view, building or unit, applicable scales, and desired visual result. A marked-up image can supplement the model but does not replace inspecting the actual view settings.

## Workflow

1. Capture the reference view template, ordered filters and overrides, category overrides, detail level, linked-model display, dimension type values, and tag-family text types.
2. Survey target views by template and scale, existing reusable filters, dimension types, grouped dimensions, host and linked tag types, fill patterns, and line patterns.
3. Create clearly named standard templates from suitable reference views when that is the only way to preserve settings the API cannot reconstruct. Keep scale-specific variants.
4. Reuse or duplicate filters, apply overrides only to the new standard templates, and preserve the intended filter order because earlier filters can win.
5. Duplicate the closest dimension type. Change writable parameters only. Skip system, spot, markup, and grouped dimension types unless the approved workflow handles them.
6. Save edited tag families under new names and verify reload results.
7. Apply everything to one representative test floor and obtain visual approval.
8. Roll out in small view batches, skipping grouped items and reporting remaining work.
9. Run annotation cleanup only after template, type, and family changes are stable.

Back up old template assignments, type values, filter order, and tag positions before changes. Test linked-model display carefully; switching to host-controlled display can hide linked content. Resolve templates by name after synchronization because newly created ids may change.

Report templates and filters created, scale mapping, dimensions and tags changed, views switched, items skipped, backups written, and any UI reload steps.

Verification status: guide-derived rollout method; apply to a test view and obtain user approval before broader use.

## Detailed method (load only when needed)

Read `references/apg-template-standardisation.md` when the task needs the worked method: capturing a reference view standard and rolling it out (STD templates, filter order, dimension types, tag families, test floor). It comes from the team's earlier Revit plugin and is adapted to this connector; revit-rules takes precedence where they differ.
