---
name: revit-rules
category: revit
description: The team's Revit rules, lessons and rejected approaches. Call get_revit_rules before any Revit work through the Autodesk MCP connector, follow every rule it returns, and save a new rule here when the user asks after a finished task.
---

# Revit rules (Get Revit rules)

This is the first step of every Revit task, for every person and every AI client using the connector.

## Before any Revit work

1. Call the MCP tool `get_revit_rules`. The connector's Revit model tools (`document_info`, `list_levels`, `list_selected`, `get_element`, `set_parameter`, `execute_csharp`) refuse to run until it has been called in the current session, and again after two hours. `list_sessions` and `connection_status` work without it.
2. Read every rule returned, then read the other skills that match the task (`list_skill_workflows`, `read_skill_workflow`).
3. A rule is a decision the owner already made. Follow it. If a rule seems wrong for the task, or a skill disagrees with it, say so and ask; do not work around it. If a task cannot be done within the rules, report that instead of using a rejected approach.
4. The rules are cumulative. A rule's `instruction` is the requirement; `title` and `category` only help you find it.

## Rule format

Rules live in `rules.json` beside this file, in the installer, and in the approved library on `main`:

```json
{ "id": "RVT-001", "title": "short imperative sentence", "category": "annotation", "decided_on": "2026-10-25", "instruction": "What to do and what never to do, with the method that worked." }
```

- `id`: `RVT-` and the next free three-digit number; never reuse a number.
- `category`: one of the existing categories first (for example `annotation`, `areas`); add a new one only when none fits.
- `instruction`: written so a model with no memory of the task can follow it. Include the rejected approach and why, the working method, and any limit (view type, element type, Revit version). No client names, project numbers, file paths, element ids or personal data.

## Saving a rule after a task

Only when the user asks ("save it as a rule"):

1. Draft the rule from what was actually demonstrated in the task, and what failed. Do not generalise beyond what was verified. Show the draft to the user and wait for approval of the wording.
2. Add it to `.agents/skills/revit/revit-rules/rules.json` (next `RVT-` id, today's date as `decided_on`). If the same rule already exists, update it instead of adding a duplicate.
3. Rebuild the stored installer in the same pull request (`powershell -ExecutionPolicy Bypass -File release-preparation\beta17\build.ps1`, public build) so PCs receive the rule, and open a pull request to `main`. Do not merge it, and do not publish a release, without the repository owner's approval.
4. Tell the user the rule reaches other PCs after they update or run Skills Sync.

Notion ("Revit MCP Rules") is the owner's editing view of the same rules; the connector reads only the installed copy, so it works offline.
