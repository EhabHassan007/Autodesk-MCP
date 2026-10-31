---
name: image-to-cad
description: Convert a supplied picture, sketch, or technical drawing into a CAD file with minimal conversational output. Use for image-to-DXF requests or when asked to save tokens while tracing an image into CAD.
---

# Image to CAD

Create a downloadable CAD file using available code execution tools. Default to 2D DXF, millimeters, and main outlines only unless the user specifies otherwise.

## Workflow

1. Inspect the supplied image. Focus on the drawing; ignore background, shading, and decorative text. Retain dimension labels as evidence for scale.
2. Use a stated dimension and its corresponding feature to set scale. Ask one concise question if the image or essential scale information is missing. If the user accepts an unscaled trace, proceed and label it unscaled. Never invent measurements.
3. Trace with lines, arcs, circles, and closed polylines where appropriate. Preserve intentional open edges. Avoid excessive vertices and duplicate geometry. Flag material ambiguity or perspective distortion briefly.
4. Generate DXF using code, preferably Python with ezdxf when available. Keep scripts and coordinates in files rather than printing them in chat.
5. Reopen the output to check it is readable, contains geometry, and has the intended units and reference dimension. Check contour closure where intended.
6. Return the file link and at most a short note about scale or unresolved approximation. Do not print code, coordinates, CAD data, or lengthy explanations unless requested.

## Other formats and constraints

- For DWG, use a compatible converter if available; otherwise deliver DXF and explain briefly that AutoCAD can save it as DWG. Never rename DXF to DWG.
- For 3D, use STEP when requested and supported. Obtain sufficient dimensions and views; do not infer hidden geometry as fact from one picture.
- If file generation tools are unavailable, say so briefly and offer a runnable script. Do not claim a file was created.
- Minimize repeated image inspection and verbose tool output, while retaining checks needed for a usable file. A short reply reduces output tokens but does not eliminate image-processing or generation costs.

## Compact starter prompt

> Convert this image to a downloadable 2D DXF file using code. Trace main outlines only, using closed polylines where appropriate. Ignore shading and background. Units: mm. Known dimension: [feature = length]. Keep explanations minimal. Do not print code or coordinates in chat. Ask only for essential missing information.
