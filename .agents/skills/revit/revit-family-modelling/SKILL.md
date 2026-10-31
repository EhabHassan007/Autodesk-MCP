---
name: revit-family-modelling
category: revit
description: Edit and reload Revit families safely and create difficult native modelling such as curved or sloped upstands, sloped floors, and railings. Use when family documents or nonstandard architectural geometry need controlled changes.
---

# Revit family and advanced modelling

Inspect existing families, types, hosts, levels, geometry, and project standards before proposing changes. State all design assumptions, including slopes, widths, heights, landings, clearances, and code basis.

## Family editing

1. Open the family document from the selected project family.
2. Use a transaction in the family document for type, label, text, and parameter edits.
3. Save under a new approved family name and path; do not overwrite the original unless the user explicitly requests it.
4. Close the family document without silently saving another copy.
5. Load or reload through the supported API or Revit UI. Existing-family replacement may require the UI and a worksharing ownership prompt.
6. Verify loaded family name, type count, geometry or label positions, and parameter values.

## Curved and sloped architectural elements

- Preserve true curves when the user requires native curved walls. Do not approximate them with many straight segments without approval.
- For a sloped curved wall that Revit cannot create directly, an approved mass/face-wall workflow may provide a native wall hosted to a retained mass face. Validate the face before creation.
- Straight sloped upstands can use a profiled wall when appropriate.
- Native ramp creation may be unavailable through the API; use approved sloped floors and railings only after explaining the modelling result.
- For sloped floors, verify level, offset, slope direction, and boundary elevation after regeneration.
- Tag created elements with a project-approved identifier so they can be audited or reverted.

Use a small test instance before repeating the workflow. Never ungroup, overwrite source families, or alter unrelated types. Verify every model write separately and remind the user to save or synchronize at a suitable milestone.

Verification status: guide-derived methods; family reload and unusual geometry require live test-model and visual verification.
