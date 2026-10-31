# Outline tracing and reusable exporter

Segment using image-specific masks or trace manually. Inspect background, detached details, closed loops, and holes. Do not reuse example logo thresholds or crop coordinates. Thick-stroke tracing yields two boundaries, not a centerline. Lettering can remain geometry unless editable text is requested. Outline tracing alone is not manufacturing preparation.

Pixel-to-CAD conversion: `x = pixel_x * scale`, `y = (image_height - pixel_y) * scale`. Resolution does not imply physical size; a known length establishes uniform scale, while perspective distortion needs separate correction.

Use [export_paths.py](../scripts/export_paths.py) for closed straight-segment outline paths. It writes R2010 DXF, refuses overwrites, checks finite coordinates, and verifies exact geometry readback and audit results. It does not segment images, create bulges/hatches, or render previews.

Input JSON:

```json
{"image_height":100,"scale":1,"units":0,"paths":[{"layer":"OUTLINES","points":[[10,10],[90,10],[90,90],[10,90]]}]}
```

Paths require at least three distinct vertices and no duplicate closing vertex. `units` is the DXF insertion-unit code: 0 is unitless, 4 is millimeters. Run from the skill directory with an available Python executable:

```text
python scripts/export_paths.py input.json output.dxf --library-dir <ezdxf-directory>
```

Omit the library option when ezdxf is installed in the selected runtime. Otherwise pass a local directory containing ezdxf. Do not commit downloaded dependency folders; each computer needs its own Python/ezdxf setup.

Render and inspect a preview from the exported geometry. The exporter's `live_autocad_verified: false` means its successful audit is not an AutoCAD import test. Prior round-trip and live repair evidence: [verified-workflow.md](verified-workflow.md).
