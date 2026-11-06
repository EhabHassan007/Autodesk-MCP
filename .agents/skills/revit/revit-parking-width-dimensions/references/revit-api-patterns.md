# Revit API implementation notes

These are adaptation patterns from the successful Revit 2024 workflow, not a script to run against stale IDs. Resolve sessions, documents, views, dimension types, families and references afresh. Use the Autodesk connector's current tool schema and team rules.

## Runner contract

The tested `mcp__autodesk__execute_csharp` runner supplies `document`, not `doc`. Start with `var doc = document;` if desired and return a string. `Newtonsoft.Json` was not available; a `System.Text.StringBuilder` and compact delimited output worked. Avoid outer-scope variable names already used by inner scopes/lambdas: the tested compiler rejected this shadowing.

Use `execution_mode="read"` and `allow_model_changes=false` for inspection. Use `execution_mode="transaction"` and `allow_model_changes=true` for annotation creation; that mode supplies the transaction. Do not start another project transaction. Always pass `session_id` and `expected_document`.

## Inspect geometry before composing a write

```csharp
var doc = document;
var options = new Options {
    ComputeReferences = true,
    IncludeNonVisibleObjects = true
};
var geometry = parking.get_Geometry(options);
foreach (GeometryInstance instance in geometry.OfType<GeometryInstance>()) {
    Transform transform = instance.Transform;
    foreach (Line side in instance.GetSymbolGeometry().OfType<Line>()) {
        if (side.Reference == null) continue;
        XYZ localStart = side.GetEndPoint(0);
        XYZ worldStart = transform.OfPoint(localStart);
        // Inspect both endpoints and retain side.Reference unchanged.
    }
}
```

Here `parking` is a freshly inspected `FamilyInstance`. This shallow traversal matched the tested families. Inspect and handle nested instances deliberately; do not silently take the first geometry instance when several could represent different parts.

For the tested local convention:

- Width runs along local X, with side boundaries at 0 and W.
- Both side lines are parallel to local Y with length L; either positive or negative Y is possible.
- Validate endpoint coordinates and measured separation against the width/length parameters. Use numerical geometry tolerances only for floating-point matching, not as relaxed compliance tolerances.
- Determine the signed length direction from the side line endpoints, not `FacingOrientation` alone. Confirm which end is the entrance using the family graphics/wheel stop.
- Accessible-family graphics include an extra side line beyond W for the access aisle; selecting the outermost line would measure the wrong width.
- Symbol geometry and instance transforms account for rotated and mirrored variants. A family type may yield more than one symbol geometry variant in the model.

## Existing coverage

Inspect view-visible native `Dimension` elements. For a simple linear dimension, first require valid references, a numeric `Value`, no override, appropriate direction and the correct projected interval. Inspect the referenced boundary geometry or planes; same parking ID plus same value is not proof of width coverage.

For a simple symmetric linear dimension, its measured endpoints can be evaluated from `Origin +/- line.Direction * Value / 2`, then transformed back to the bay's local coordinates. Validate that this interpretation matches its reference positions before relying on it. The tested workflow used this to recognize an existing dimension referencing a neighbouring bay. Proximity alone is insufficient. Chained dimensions require separate segment origins/values and reference-pair checks.

Keep a coverage mapping from each bay to its verified existing or newly created dimension. This is more reliable than comparing total dimension counts.

## Placement and creation

After confirming the local convention and entrance, a starting dimension position is:

```csharp
double offsetFeet = 700.0 / 304.8;
double localY = lengthSign * (lengthFeet - offsetFeet);
XYZ start = transform.OfPoint(new XYZ(0, localY, 0));
XYZ end = transform.OfPoint(new XYZ(widthFeet, localY, 0));
// For the tested horizontal floor plans, use the plan level elevation.
start = new XYZ(start.X, start.Y, view.GenLevel.Elevation);
end = new XYZ(end.X, end.Y, view.GenLevel.Elevation);
Line dimensionLine = Line.CreateBound(start, end);
var referenceArray = new ReferenceArray();
referenceArray.Append(leftBoundaryReference);
referenceArray.Append(rightBoundaryReference);
Dimension created = doc.Create.NewDimension(
    view, dimensionLine, referenceArray, dimensionType);
```

All variables in this fragment are resolved during current-session preflight. Reject missing levels or unsuitable view planes rather than substituting a guessed elevation. Geometry lengths are Revit internal feet; multiply by 304.8 for millimetres.

Record `created.Id` with parking ID, view ID, expected measured width and reference identities. Verify exactly those IDs in a separate call. Do not use a numeric ID threshold to identify new elements; that was a one-session shortcut, not a reusable identification method.

## Independent read-back

For each recorded ID, retrieve the `Dimension` again and verify:

- It exists, has the intended `OwnerViewId` and type, and `AreReferencesAvailable` is true.
- It is the intended simple dimension (`NumberOfSegments == 0`) with two verified boundary references.
- `Value` matches the independently measured expected width after unit conversion, at the precision required by current project rules.
- `ValueOverride` is empty; the displayed number was not fabricated.

Re-read parking geometry or its identifying state if the model changed between planning and writing. Reference access to grouped/pinned parking is distinct from editing its parameters or position.

## Visual verification

`document.ExportImage` worked through the read runner with `ImageExportOptions` using `ExportRange.SetOfViews`, an explicit view-ID list, PNG, `ZoomFitType.FitToPage`, and 6000-pixel horizontal output. Export to an approved local working folder and inspect the resulting files. Large exports may take longer than a tool's initial wait; wait for completion without issuing concurrent model writes.

Check close details as well as the full plan: angled bays, accessible bays, tandem bays, crowded rows and retained existing dimensions. Reusing a check style can retain its colour, dual units or precision; inspect these rather than silently redefining the type.
