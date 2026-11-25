# Linked models, nested links, cloud links and coordinates

Transforms and tags across links, nested link bounding boxes, ACC cloud link GUIDs, survey point / shared coordinate batch work.

Related rules (revit-rules): RVT-004, RVT-012, RVT-046, RVT-049, RVT-056

Imported from the APG team Revit guide "linked-models-and-coordinates" (2026-11-25) and adapted to Smart Connector: C# runs through `execute_csharp` (rules RVT-005, RVT-026), and timeouts follow RVT-007. Where this text and revit-rules disagree, revit-rules wins.

## Working across links

- Link instance -> host: `link.GetTotalTransform()`; host -> link: `.Inverse.OfPoint(p)`.
- Linked elements in tags: `RoomTag.TaggedRoomId` and `IndependentTag.GetTaggedElementIds()` return `LinkElementId` (`LinkInstanceId` + `LinkedElementId`; host elements use `HostElementId`).
- Tag a linked room: `document.Create.NewRoomTag(new LinkElementId(link.Id, room.Id), new UV(p.X, p.Y), view.Id)` with `p` in host coordinates.
- Collect linked elements near a view with a `BoundingBoxIntersectsFilter` built from the view crop box transformed into link coordinates.
- Nested link instances: `get_BoundingBox(null)` is null - compute from the link document and transform the 8 corners.
- Skip links hidden in the view (`link.IsHidden(view)`).

## Cloud (ACC) links

- `RevitLinkType.GetExternalFileReference()` returns null for ACC links. Use `lt.GetExternalResourceReferences()` and read `GetReferenceInformation()` keys such as `LinkedModelModelId` and `LinkedModelProjectId` (plus region) to open them with `ModelPathUtils.ConvertCloudGUIDsToCloudPath`.
- Batch tools over cloud models keep a model list (CSV) with Run Y/N, name, region, project GUID, model GUID and the target values.

## Survey point / shared coordinates batch

- Values the user enters are **absolute targets**, not shifts: read the current survey point (or base point), compute `target - current`, apply only the difference, read back.
- Unpin before moving; re-pin afterwards if it was pinned.
- Support "fixed to project base point" mode and **every shared site** (`ProjectLocation`s) in a model, not only the active one.
- Run outside the target models (from a small local file) and log each model's before/after values to a CSV.
- Revit Macro Manager may be unusable when the SharpDevelop editor is missing from the install - compile an add-in instead.

## Property line / site outline from linked walls

- Collect the outer edges of the link's walls and curtain walls on the relevant level(s) and transform them to host coordinates (`link.GetTotalTransform()`).
- Union them into ONE continuous closed loop - no duplicate or overlapping segments. For several levels (e.g. ground + podiums) take the outer envelope across them.
- Draw the loop as detail lines in a plan view; the user then uses Pick Lines in the property-line sketch.
- Do not drive the property-line sketch with UI automation.
