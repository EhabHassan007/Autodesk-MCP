# Token benchmark: two rooms, 26 objects

A scratch drawing, saved to a real path first, with 0 objects at the start. The plan is `benchmark-plan.json` (4 layers, 21 lines, 1 circle, 4 texts = 26 objects, 30 steps).

## Run it (the dry-run rule applies)

1. `connection_status`: `bridge.kind` must be `exe`. If it says `powershell`, stop and run Smart Connector > Repair.
2. `drawing_info`: note `drawing_id`, `units_code` 4, `model_space_objects` 0.
3. `apply_plan` with `expected_drawing` = the id, `dry_run` true, `items` = the plan's items. Report the answer, then STOP and ask for a yes.
4. After the yes: the same call with `dry_run` false. Check `count_matches_plan` and `objects_created` 26.
5. `verify_standards` with the rules below. All clear is `{"ok":true,...}`.
6. Do not save. Type `U` in AutoCAD to remove the drawing; the object count must return to 0.

```json
{"expected_drawing":"<id>","required_layers":[{"name":"A-GRID","color":8},{"name":"A-WALL","color":7},{"name":"A-DOOR","color":3},{"name":"G-ANNO-TEXT","color":231}],"forbidden_layers":["0"],"text_height":{"min":100,"max":150},"expected_counts":[{"count":26},{"layer":"A-GRID","type":"line","count":5},{"layer":"A-WALL","type":"line","count":16},{"layer":"A-DOOR","type":"circle","count":1},{"layer":"G-ANNO-TEXT","type":"text","count":4}]}
```

Targets: at most 3 calls to build (dry run, real run, verify), verify output under 500 tokens, whole workflow under 10k tokens.

## Estimated size of the calls (characters / 4, measured on the code, not by a model)

| Step | Sent | Answer | Tokens (est.) |
|---|---|---|---|
| `drawing_info` | 40 chars | 330 chars | ~95 |
| dry run | 2025 chars | 218 chars | ~560 |
| real run | 2025 chars | 307 chars | ~580 |
| `verify_standards` | 780 chars | 60 chars | ~210 |
| **Calls total** | | | **~1.5k** |

Fixed cost the connector adds to every session: the tool list, about 3.7k tokens (3.2k before this change: `verify_standards` adds about 0.3k; the longer descriptions of `list_entities` and `apply_plan` add about 0.3k; `generate_detail` was cut from 4.1k to 3.5k characters). Skills read on demand: `autocad-read-write` about 0.7k, its `apply-plan` reference about 1.4k.

These are estimates of what the connector sends and returns. A live run with the AI app's own token counter is still needed; record it in the pull request.

## Live result (AutoCAD 24.3, 2026-11-12, installed 1.1.0)

Run two ways on an empty millimetre drawing, nothing saved:

- **Directly against `SmartConnector.exe`** (a PowerShell script speaking the MCP protocol, no AI app): 23 tools offered, `bridge: kind=exe version=1.1.0`; a real run before any dry run was refused ("Run dry_run first and get the user's approval."); dry run valid (30 steps); real run created 26 objects, `count_matches_plan` true; the same plan again was refused; `verify_standards` returned `{"ok":true,"scanned":26}`. Sizes (characters / 4, the connector's own traffic): tool list about 5.4k tokens (all 23 tools, Revit and skills included), the seven calls about 3.3k tokens (the two refusals included; the five calls a real job needs about 2.1k).
- **Through the Claude desktop app** (an AI session): `bridge.kind` exe, version 1.1.0, 23 tools; dry run valid; real run 26 objects, `count_matches_plan` true; 5 tool calls plus one search to load the tool schemas. The app shows no token count.

Finding: `verify_standards` counted an unknown `type` ("total") as zero objects and reported a violation. A type of `total`, `all` or `any` (or no type) now counts every object, and an unknown type is refused with a message.

