# Demonstrated workflow â 2026-10-03

A supplied 684 x 676 colorful mascot/lettering image was traced as 92 closed polylines containing 1,969 vertices on INK_OUTLINES and HIGHLIGHTS layers. The user approved the preview. Background and corner decorations were omitted, along with color fills and shading. Scale remained unitless at one pixel per drawing unit.

The first minimal, manually written DXF passed coordinate and vertex-count checks but the user reported an Enter prompt followed by an empty drawing. No exact AutoCAD diagnostic was captured, so the specific rejection cause is unproven. Rebuilding with ezdxf 1.4.4 as R2010 DXF produced zero library audit errors/fixes with exact geometry preservation. A separate approved Windows PowerShell COM operation opened the repaired DXF read-only in AutoCAD and returned 92 model-space entities. The user then requested saving this as a new skill.

The original workspace retained image-specific trace, repair code, preview, reports, and fixed DXF outside the portable skill. The trace used Pillow and NumPy, binary pixel boundary extraction, five-sample contour smoothing, and 0.65-pixel simplification. Its masks and crop exclusion were specific to that artwork and must not be reused as general thresholds.

The bundled generic exporter accepts a local dependency directory through `--library-dir`. Dependency folders are not bundled into the skill; each computer needs its own Python/ezdxf setup.

The live check used Windows PowerShell 5.1 and AutoCAD's COM API. PowerShell 7 did not expose `Marshal.GetActiveObject` in this environment. The verification required approved execution outside the sandbox; retain those access boundaries. This is a separate API procedure, not an additional MCP tool.

The supplied logo's outlines and subsequent smooth color-hatch version were live-tested. See [smooth-color-hatches.md](smooth-color-hatches.md) for the latter and the user's style correction. Automatic arbitrary-photo reconstruction, dimensions, centerline extraction, spline fitting, physical scaling of this example, and DWG export were not demonstrated. A new skill does not add tools to the MCP server.
