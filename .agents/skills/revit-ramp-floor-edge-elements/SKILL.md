---
name: revit-ramp-floor-edge-elements
description: Create and trim native Revit walls or pavement strips along selected sloped or curved ramp and floor edges while preserving the source geometry.
---

# Ramp and Floor Edge Elements

- Work from the selected ramps/floors and inspect their true edge geometry, slope, levels, offsets, and nearby slabs/columns before writing.
- Preserve each ramp's beginning, ending, slope, and curved outline. Do not approximate curves with many straight segments.
- Prefer native Walls. For a wall that must follow a sloped or curved face, use a mass plus Wall by Face. Never use Model-in-Place. Use Structural Framing only when the user explicitly accepts it.
- Use the requested thickness and height; common project values are 300 mm thick and 1200 mm high. Align the exterior wall face with the slab/ramp edge.
- Keep the wall base on the floor/ramp slope. Attach or trim its top to the underside of a nearby slab only at the real intersection, with no crossing. Remove any wall portion above the slab.
- Stop walls at column faces; do not pass through columns.
- For pavement strips, follow the source slab slope and requested thickness/width. Preserve the external edge when aligning the internal edge to a selected detail-group line. Apply the same construction to every selected source floor when requested.
- Read back element type, boundary, offsets, constraints, and intersections after changes. Never ungroup.

