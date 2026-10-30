---
name: revit-linked-coordinates
description: Work safely with Revit links, nested and cloud links, linked-element tags, transforms, survey points, shared coordinates, and batch coordinate updates.
---

# Revit linked models and coordinates

Read the host document, every relevant link instance, load and visibility state, positioning method, total transform, shared sites, and coordinate reference before changing anything.

## Linked geometry and tags

- Convert linked coordinates to host coordinates with the link instance total transform and host points into the link with its inverse.
- Preserve both link instance id and linked element id in findings and tags.
- When filtering linked elements near a view, transform the view crop into link coordinates before spatial collection.
- Nested links may not expose a useful host bounding box. Compute bounds from link-document geometry and transform all corners.
- Skip links hidden in the active view and report unloaded documents.

## Cloud links

Cloud-hosted links may use external-resource references instead of ordinary file references. Resolve them from the platform's project/model identifiers and region. Keep batch model lists free of access tokens and credentials.

## Survey and shared-coordinate changes

- Treat user-entered coordinates as absolute targets unless the user explicitly specifies a delta.
- Read current values, calculate target minus current, apply only that difference, and read back the result.
- Preserve pin state: unpin only when required and restore it afterward.
- Account for every `ProjectLocation`, not only the active site, when the scope includes all shared sites.
- Run multi-model changes from a small controller model and log each model's before/after values.

Coordinate changes can affect all disciplines and exports. Require explicit approval of the coordinate basis, models, sites, and target values. Test one model first, verify against a control point, and have the user synchronize before proceeding to the next batch.

Verification status: live-guide knowledge captured; coordinate updates themselves were not performed during skill creation.
