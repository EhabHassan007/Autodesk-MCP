---
name: revit-linked-property-region
category: revit
description: Create a Revit filled region from a PropertyLine selected inside a linked model, including curved and unordered boundary segments.
---

# Linked PropertyLine Region

- A linked subelement selection can return no element IDs. Read selection references with 'new UIApplication(document.Application).ActiveUIDocument.Selection.GetReferences()' and resolve 'ElementId' as the link instance plus 'LinkedElementId' as the linked PropertyLine.
- Read the PropertyLine geometry, transform every Curve with 'RevitLinkInstance.GetTotalTransform()', and leave the linked model unchanged.
- Geometry enumeration is not boundary order. Cluster matching endpoints, verify one connected degree-2 closed loop, then order the curves and reverse individual curves as needed. Preserve Arcs as true curves.
- Reject open, branched, or ambiguous boundaries instead of guessing. Validate the final closure against a small model-unit tolerance.
- Create the FilledRegion in the active plan with the requested existing FilledRegionType; if none is specified, use the established project type rather than modifying a type.
- Read back owner view, type, loop/segment count, bounding box, and computed area after creation.

