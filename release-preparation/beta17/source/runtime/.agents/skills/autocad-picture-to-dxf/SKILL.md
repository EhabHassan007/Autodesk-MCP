---
name: autocad-picture-to-dxf
description: Trace raster artwork or drawing references into editable 2D DXF outlines or curved color hatches, and repair generated DXFs. Excludes raster-only editing and automatic engineering reconstruction from photographs.
---

# Picture to AutoCAD DXF

1. Verify the actual source image, native dimensions, aspect ratio, and smallest relevant lines/text before converting. OCR Markdown is not the image; similarly named files may differ. If missing or illegible, request the original image/PDF. An explicitly authorized approximate conversion may proceed with stated limits; enhancement does not recover measured geometry.
2. Before every new picture conversion, ask: “Do you want outlines/lines only (no hatches), or lines with hatches?” Wait for the answer before tracing or generating CAD geometry, even if prior work used hatches. Ask once per conversion, not again after the user answers. Source-quality inspection may proceed while waiting. For outlines only, create line/polyline geometry without HATCH entities. For rounded artwork, retain the preference for actual curved segments in either mode. Preserve intentional technical corners; do not apply logo rounding to engineering drawings.
3. Use unitless geometry at one pixel per drawing unit unless a dimension establishes scale. Read only the applicable workflow below. Reuse the audited exporter for outline paths; image-specific scripts require adaptation.
4. Audit and read back saved geometry; render and inspect a preview from it. File checks do not establish live AutoCAD compatibility. When authorized and available, open read-only and verify entities; filled artwork also requires hatch evaluation. The current MCP bridge cannot open files or create polylines/hatches.
5. Deliver DXF and preview links, scale, approximations, and verification status. Promote demonstrated reusable lessons into this repository's skill files. Generating DXF or saving skill notes does not authorize saving existing DWGs.

## Load only for the selected task

- Outline tracing/export: [trace and exporter guide](references/outline-export.md), including JSON input and the existing reusable script.
- Color fills or true curved segments: [smooth color hatches](references/smooth-color-hatches.md), including topology, bulges, saved-geometry previews, and live verification.
- Failed DXF opening, local dependencies, or prior test evidence: [verified workflow](references/verified-workflow.md).
- Live drawing edits or connection recovery: [autocad-read-write](../autocad-read-write/SKILL.md).

Use a dedicated DXF library such as ezdxf, not a minimal hand-written modern DXF. After an empty-drawing/Enter-prompt failure, capture the diagnostic if possible, rebuild with the library, compare geometry, and retry read-only once; inspect remaining errors before further attempts. If AutoCAD is busy, do not cancel the user's command; retry once, then ask them to finish the command/dialog.
