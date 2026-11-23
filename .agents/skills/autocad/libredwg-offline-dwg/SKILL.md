---
name: libredwg-offline-dwg
category: autocad
description: Read or convert a CLOSED .dwg file without AutoCAD through the connector's dwg_inspect and dwg_convert tools (LibreDWG) - list layers, search text, export DXF or JSON, save as another DWG version, extract the preview image. Not for the drawing open in AutoCAD, not for DXF input, not for authority-ready deliverables.
---

# Offline DWG tools (LibreDWG)

`dwg_inspect` and `dwg_convert` work on a closed `.dwg` file on this PC. They need no AutoCAD session. They run the LibreDWG programs bundled with the connector (GPL-3.0-or-later; licence text and source offer are in `bin\libredwg\`).

## When to use
- A DWG is on disk and AutoCAD is closed or busy: list its layers, find a text string (title, revision, room name) or search across a project one file at a time.
- A DXF or JSON copy, an older-version DWG for someone with older software, or the preview image of a drawing.
- Do not use these for the drawing that is open in AutoCAD: use `drawing_info`, `list_layers` and `list_entities` there, because they read the live state including unsaved changes.

## Dry run first, then ask
- `dwg_inspect` only reads. Run it freely.
- `dwg_convert` writes a new file. Before the first conversion say which action, which source file, which folder the new file will go to (the source's folder unless `output_dir` is given) and the name it will get, then wait for an explicit yes. The tool never overwrites: an existing name gets `-1`, `-2`, and the source is never changed.
- A changed request needs a new yes.

## Steps
1. Give an absolute path to an existing `.dwg`. DXF input and relative paths are refused.
2. `dwg_inspect` `layers` (`with_flags` adds on/off, frozen, locked) or `search` with `pattern` (plain text, not a regular expression; `ignore_case` defaults to true; `include_blocks` also looks inside block definitions). A search with no match returns an empty list, not an error.
3. `dwg_convert` with `to_dxf`, `to_json`, `save_as_version` (`version` r12 to r2018) or `thumbnail`. A drawing without a preview image answers with a message and writes nothing.
4. Report the output path, size and any `warnings` text the tool returned.

## What to tell the user
- LibreDWG is not AutoCAD. The reader handles every DWG version but skips some advanced R2010+ objects, and a log line such as "AcDs schdat segment yet unhandled" means part of the file was not decoded. Do not say a drawing was fully read when warnings point at skipped objects that matter to the task.
- A rewritten or exported file can lose dynamic blocks, proxy objects, solids, annotative detail and custom objects. In a test, a rewrite reported an object-count mismatch in its own re-read. Compare layer lists and a text search between source and result before calling a copy equivalent.
- A DWG written by `save_as_version` is not an authority or consultant deliverable. For UAE or Saudi submissions open it in AutoCAD, run AUDIT, save it there and check it against the requirements of the authority first.
- Never run these tools on a drawing the user has not named. Work only on the file given; do not copy drawings into the repository or into chat transcripts.

## If it fails
- "The offline DWG tools are not installed": this connector was installed without the LibreDWG pack. Say so, suggest Smart Connector > Repair or an update to a release that includes the pack, and carry on with AutoCAD tools if the drawing can be opened.
- A damaged file or one with unsupported objects returns "failed ... exit code" with LibreDWG's message. Do not retry the same call; try opening the file in AutoCAD, or run RECOVER there.
- A call that ran out of time was stopped; retry once with a larger `timeout_seconds` (up to 600) only if the file is known to be large.
