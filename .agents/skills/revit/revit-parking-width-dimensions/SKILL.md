---
name: revit-parking-width-dimensions
description: Add native associative width dimensions to parking bays in specified Revit plan views through the Autodesk MCP connector, including rotated and mirrored bays. Preserve groups, reuse dimension styles, avoid duplicates, and verify coverage. Excludes changing bay sizes, clearance compliance reviews, and fabricated dimensions.
---

# Revit parking width dimensions

Create actual Revit `Dimension` elements between verified parking-bay boundaries in the user's chosen model and views. Use the model's measured geometry; never substitute text, detail lines, or overridden dimension values.

## Establish the scope

- Discover the Autodesk/Revit tools, read applicable shared workflow guidance and team rules, then use `list_sessions` and `document_info`. Pass the fresh session ID and document identity on every operation.
- Resolve the requested views by current identity and name. For "the active three views", inspect `UIApplication.ActiveUIDocument.GetOpenUIViews()`; Revit has one active view but can have several open views. On a resumed task, retain previously confirmed view scope even if tabs have closed, provided the same views still exist.
- Count view-visible `OST_Parking` family instances, group by family/type, and inspect sample geometry for every variant, including rotated, mirrored, accessible and tandem bays. Review phase/crop visibility where it could change coverage.
- Inspect the dimension types already used in those views, parking tag locations, and existing width dimensions. Reuse the intended style; a style called "Check" is a project choice, not a universal default.
- Present the exact view names, bay counts, existing coverage and intended placement. An explicit request to add these dimensions authorizes that annotation work; do not require a second confirmation solely because scripting is needed.

## Find real references

Read [references/revit-api-patterns.md](references/revit-api-patterns.md) when implementing the geometry, duplicate checks, creation and read-back.

- Prefer verified family boundary references. Reference names such as `CenterLeftRight` do not establish their physical position: in the tested family, the named centre plane was at a bay edge.
- If named boundary planes are unavailable, inspect `get_Geometry` with `ComputeReferences=true` and `IncludeNonVisibleObjects=true`. Traverse `GeometryInstance.GetSymbolGeometry()` and retain its original curve references. Use the geometry-instance transform for positions and directions.
- Identify two parallel side boundaries whose separation matches the measured width. In the tested families they were local lines at X=0 and X=width, extending along positive or negative Y for the parking length. Confirm this per geometry variant; do not assume all parking families use that convention.
- Read instance/type width and length parameters and compare them to the boundaries. Family/type names can be stale: the tested accessible type name suggested 2400 mm while its actual bay width was 2500 mm. Dimension the bay itself, not its adjacent access aisle.
- Do not synthesize stable-reference strings, reuse historical geometry indices, or use transformed/copied geometry as an associative reference. For unsupported or ambiguous geometry, report the affected bay and reason.

## Preserve and place

- Create free view-owned annotations. Referencing a grouped or pinned parking instance does not require changing that instance: do not ungroup, unpin, move or resize parking, edit group members, or alter family definitions. Respect current team restrictions and view ownership.
- Verify whether an existing native dimension already covers each bay. Matching value or element ID alone is insufficient; verify direction, the actual two boundary positions, reference availability and absence of value overrides. For references on neighbouring instances, establish the measured interval geometrically. Handle chained dimensions segment by segment or leave them unresolved rather than guessing.
- Align each new dimension with the bay's local width direction. Transform its endpoints into model coordinates and project onto the target plan's plane. Account for negative local length direction and mirroring.
- The successful placement was 700 mm inside the open end of each bay, clear of centre parking tags. Treat this as a starting offset; adjust for the actual family entrance, labels, adjacent annotations, accessible symbols and drawing scale.
- Preserve existing dimensions. Record new dimension IDs and their view/parking mappings so any requested correction can target only this operation's additions.

## Create, verify and finish

1. Prepare a read-only plan for every bay: reference pair, expected width, placement, existing coverage or unresolved reason. Read geometry before writes.
2. Create one representative native dimension, then use a separate read call to verify it persisted and has the intended width, references, view and type.
3. Continue in bounded batches, normally one plan view at a time. Follow each batch with independent read-back. Recheck coverage before retrying to prevent duplicates.
4. Verify each created ID explicitly: existence, correct owner view/type, two intended references, `AreReferencesAvailable`, numeric value matching the expected width, and no value override. Apply project precision rules; never round or change bay geometry to make a dimension appear compliant.
5. Export explicit target views to PNG and inspect overall coverage and representative details, including rotated and accessible bays. Adjust only new annotations when placement needs correction. API success alone does not establish visual quality.
6. Reconcile total bays = verified existing coverage + newly verified coverage + unresolved bays. Report counts per view and any limitations. Ask the user to synchronize at completion; do not save or synchronize automatically without authorization.

For a timeout or uncertain write, stop writes and inspect current state before retrying. For an approval or usage-limit failure, do not bypass the review; report the actual block and resume only when it is resolved or the user supplies appropriate direction.

## Validation history

Verified in Revit 2024 on the M1006 POD model, 29 October 2026: Ground 36 bays, POD 01 101 bays, POD 02 103 bays. Added 237 dimensions and retained three existing dimensions; final coverage was 240/240 with no unresolved bays. New values and references were read back and all three plan exports were visually reviewed. This establishes the tested family pattern, not universal compatibility with other families or Revit versions.
