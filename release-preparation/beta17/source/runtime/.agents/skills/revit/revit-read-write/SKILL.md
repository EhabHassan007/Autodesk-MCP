---
name: revit-read-write
category: revit
description: Inspect and edit a live Revit 2024 document through the local MCP add-in. Use for document information, levels, selected elements, element parameters, connection checks, and narrow parameter writes.
---

# Revit 2024 read/write

Use the connected `revit` MCP tools. Revit must be open with a project, and the BIM-CAD MCP add-in must have loaded at startup.

1. Call `document_info` before an editing task. Use its fresh `document_id` as `expected_document`; do not reuse historical element ids without inspecting them again.
2. Use `list_selected` or `get_element` to inspect the target. Parameter names can be duplicated or localized, so verify the returned parameter and storage type before writing.
3. Use `set_parameter` only for the requested element and parameter. Each call creates one Revit transaction. Numeric double values are Revit internal units; obtain or calculate the correct internal value before writing.
4. Read the element back after a write. An MCP success confirms the transaction committed, not that the model was saved or synchronized.
5. Keep save, Save As, synchronize, element deletion, and broad model changes outside this skill until dedicated tools and live tests exist.

The current adapter is for Revit 2024. It exposes document information, levels, selected elements, element/parameter inspection, and parameter writes. Treat build tests, pipe tests, live read verification, live write verification, and user visual approval as separate evidence.
