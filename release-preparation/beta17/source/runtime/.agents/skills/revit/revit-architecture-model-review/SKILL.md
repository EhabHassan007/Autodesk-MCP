---
name: revit-architecture-model-review
category: revit
description: Review a Revit architectural model for spatial completeness, level and hosting integrity, modelling quality, documentation risks, and submission readiness. Use for model audits and architecture QA/QC; keep code or authority-specific compliance claims tied to supplied standards.
---

# Revit architecture model review

Review the current model in read-only mode unless the user explicitly asks for fixes. Use available Revit MCP tools and state when a check cannot be completed with the connected toolset.

## Establish the review

1. Read fresh document identity before using element ids or reporting results. Record Revit version, document title, central/local status when available, active phase, and whether links are loaded.
2. Identify the intended review stage and deliverable: design coordination, authority submission, IFC handover, tender, or construction documentation. If no stage is stated, perform a general architecture QA/QC review and label standards-dependent items as unverified.
3. Separate host-model findings from linked-model findings. Apply the link transform before comparing coordinates or geometry.
4. Use project standards, authority requirements, and agreed tolerances supplied for the task. Never invent a regulatory threshold or treat an office convention as a code requirement.

## Review sequence

Work from model-wide conditions toward individual elements:

1. **Model identity and setup** â units, phases, design options, worksets, coordinates, project/base/survey points, warnings, imported CAD, and loaded links.
2. **Levels and storeys** â duplicate or inconsistent names, missing plan views, reference levels exposed as storeys, elements hosted outside the vertical range of their assigned level, and cross-discipline level misalignment.
3. **Rooms and areas** â unplaced, unenclosed, redundant, zero-area, or duplicate-numbered rooms; uncovered occupied regions; room-bounding failures; upper limits that miss ceilings; and inconsistent department, occupancy, or usage data.
4. **Architectural elements** â walls spanning unintended storeys, floors or roofs at incorrect elevations, openings without suitable hosts, stairs and ramps with incomplete geometry or annotations, misplaced doors/windows, and inappropriate in-place or generic-model use.
5. **Envelope, circulation, and access** â discontinuities, blocked routes, unresolved shafts, inconsistent floor openings, and apparent clearance concerns. Treat bounding-box proximity as a candidate issue, not proof of a clash or code failure.
6. **Documentation health** â view/template consistency, missing tags, duplicate or conflicting annotations, grids and levels not shown where required, and key plans/sections that do not support review.
7. **Output readiness** â naming, classifications, required parameters, links, coordinates, element ownership, and export configuration. Use the `revit-ifc-export-readiness` skill when IFC is the deliverable.

## Evidence and severity

Every finding should contain:

- a stable finding id and severity;
- host or link document name;
- element id, category, type, and level when available;
- the observed condition and the evidence used;
- why it matters at the stated project stage;
- a concrete correction or review action;
- verification status: confirmed, probable, or manual review required.

Use **Critical** only for conditions likely to invalidate the deliverable or prevent safe use. Use **Error** for clear model failures, **Warning** for credible risks, and **Information** for improvement opportunities. Group repeated instances under one finding while retaining the complete element-id list.

## Safe correction

- Present findings before changing the model.
- Change only the approved scope and re-inspect each affected element first.
- Derive values from authoritative model data or user-provided standards; do not fill missing project data with examples.
- Keep renaming, deletion, purging, room placement, element rehosting, group editing, and broad type changes for explicit approval.
- Verify writes by readback. Report model save and synchronization separately from transaction success.

## Deliverable

Lead with readiness and the highest-impact blockers. Provide counts by severity and review area, then a finding register ordered by severity and practical correction sequence. Clearly separate completed checks, checks limited by MCP capability, and checks requiring visual or exported-file verification.
