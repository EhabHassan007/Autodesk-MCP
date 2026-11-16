# Custom structural column family from a plan polygon

One loadable family per column outline, created through Smart Connector `execute_csharp` in Revit 2024. Demonstrated live on a workshared project (13 columns placed and read back; nothing saved or synchronized by the scripts). Steps 1 to 6 touch only the family document; steps 7 to 9 change the project.

## Before starting

- Read `document_info`, the target levels and the original elements the new columns replace or follow. Record their base and top levels and offsets, Moves With Grids, workset and Structural Material for step 9.
- Derive each outline from a reliable source (for example the footprint of the linked walls on the level below only) and check every loop is closed and does not self-overlap before building geometry. An outline-tracing routine that produced self-overlapping loops had to be replaced.
- Confirm family and type naming with the user.

## Steps

| Step | Mode | Action |
|---|---|---|
| 1 | probe | `application.Application.NewFamilyDocument(templatePath)` with the Metric Structural Column template (by default `<FamilyTemplatePath>\Metric Structural Column.rft`; the folder differs by language and install, so read `application.Application.FamilyTemplatePath`). |
| 2 | probe | Find the template levels by name: "Lower Ref. Level" (elevation 0) and "Upper Ref Level" (4000 mm) in the English template. Fall back to ordering the two levels by elevation. |
| 3 | probe | In a family transaction, create the extrusion on `SketchPlane.Create(famDoc, Plane.CreateByNormalAndOrigin(XYZ.BasisZ, XYZ.Zero))`. Build the profile relative to the outline's bounding-box centre, so the family origin is the column centre. |
| 4 | probe | Get the extrusion's top and bottom planar faces with `new Options { ComputeReferences = true, View = frontView }`. Do not set `DetailLevel` as well (see the runner skill). |
| 5 | probe | In the "Front" elevation, `famDoc.FamilyCreate.NewAlignment(frontView, lowerLevel.GetPlaneReference(), bottomFaceRef)` and the same for the upper level and top face. One transaction per alignment worked; a single transaction for both was not tested. |
| 6 | probe | `famDoc.FamilyManager.RenameCurrentType("<type name>")` in a family transaction. |
| 7 | manual, allow_model_changes=true | `famDoc.SaveAs(tempPath, new SaveAsOptions { OverwriteExistingFile = true })`, then `Family family = famDoc.LoadFamily(document)`, then `famDoc.Close(false)`. Do not load with `document.LoadFamily(tempPath, out family)` (see the family skill). |
| 8 | transaction | Activate the symbol, then `document.Create.NewFamilyInstance(new XYZ(cx, cy, baseLevel.Elevation), symbol, baseLevel, StructuralType.Column)`. |
| 9 | transaction | Copy from the original: base and top level and their offsets, Moves With Grids, workset, Structural Material. Read every value back in a separate call. |

Steps 1 to 6 and the SaveAs can run as one probe call. The probe rolls back any project change, so a load in the same call is undone and reported; run step 7 separately with model changes allowed.

## Known limits

- Linking the extrusion's material (`MATERIAL_ID_PARAM`) to the family "Structural Material" parameter with `FamilyManager.AssociateElementParameterToFamilyParameter` failed with "Document regeneration failed". Cause not established. Workaround used: skip the link and set Structural Material on each placed instance; the family geometry keeps the default material. Material takeoffs and views shaded by material will not follow the instance value until this is solved.
- Re-check outlines derived with a looser filter (for example walls that start at the column's own level) against the strict "level below only" filter before issue.

Verification status: steps 1 to 9 demonstrated live once in Revit 2024 (13 columns). The probe mode (`manual` without model changes) and the step 7 split are connector behaviour added afterwards and still need a live run.
