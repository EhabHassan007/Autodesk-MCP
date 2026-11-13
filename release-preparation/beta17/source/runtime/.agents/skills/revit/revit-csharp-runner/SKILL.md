---
name: revit-csharp-runner
category: revit
description: Run controlled C# through a Revit MCP execution tool with correct transaction context, batching, timeout recovery, failure logging, worksharing safeguards, and mandatory read-back.
---

# Revit C# runner

Use dynamic C# only when a narrower MCP command cannot complete the authorized task. Treat the code as model-changing capability even when the intended operation is small.

## Before execution

- Read current document identity, active view, model state, and applicable team rules.
- Inspect every targeted element and skip grouped, pinned, read-only, or unowned elements unless an approved workflow handles them.
- Present the exact scope and expected changes. Obtain explicit approval before writes.
- Preserve original values or positions for a script-based revert, especially before synchronization.

## Smart Connector execute_csharp

The code is the body of a method. Predefined variables:

| Variable | Type | Notes |
|---|---|---|
| `document` | `Document` | The active project. There is no `doc`; using it is a compile error. |
| `application` | `UIApplication` | `application.Application` is the Revit `Application` (for example `NewFamilyDocument`, `FamilyTemplatePath`). |
| `parametersJson` | `string` | The `parameters_json` argument, unparsed. |

The code must return a string. Modes:

| Mode | allow_model_changes | Use |
|---|---|---|
| `read` | false | Inspection only. No transaction is supplied. |
| `transaction` | true | Project writes inside one automatic transaction. Read back in a separate call. |
| `manual` | false | Probe: create, edit, save (to a temporary path) and close family documents. The project runs inside a transaction group that is always rolled back; any project change is undone and reported as an error. |
| `manual` | true | Code that must manage its own project transactions, or that changes the project from a family document (for example `famDoc.LoadFamily(document)`). |

Errors come back as the real cause first: `C# compilation failed: Line N: ...`, or `C# execution failed at mcp_code.cs line N, in <Type.Method> (<exception type>): <message>`, followed by any Revit failure messages posted during the run with their element ids. Line numbers count from the first line of the submitted code. "Revit 2024 MCP session is not available" now means the pipe to Revit could not be reached; check `connection_status` before retrying.

## Runner constraints

- Use the document variable and transaction context supplied by the runner; do not create a second project-document transaction.
- A separately opened family document may require its own transaction.
- Prefer broadly compatible language and API constructs for the target Revit year.
- Read all geometry and bounding boxes before writes to avoid regeneration inside loops.
- Geometry `Options`: never set `DetailLevel` and `View` together. Revit throws "DetailLevel is already set. When DetailLevel is set view-specific geometry can't be extracted". For face references used by alignments or dimensions, use `new Options { ComputeReferences = true, View = targetView }` with no `DetailLevel`.
- When an API call fails with a bare message such as "Document regeneration failed", read the line and method named in the error, then isolate that one call in a probe run before changing the approach.
- Use category filters and small batches rather than scanning entire views or models.
- Return a short result with changed, skipped, failed, and remaining counts. Write large diagnostics only to an approved project working folder.

## Verification and recovery

A success response does not prove Revit committed the changes. Perform a separate read-back after every write batch. If values did not persist, capture Revit failure messages for the affected document and retry only after understanding the reason.

After a timeout, stop issuing writes. Confirm the MCP is responsive, discard any stale response, and inspect the model before deciding whether to retry. If Revit remains blocked, ask the user to check for an open dialog. Never use blind retries or Ctrl+Z during an uncertain call.

Keep batches proportional to model complexity and use remaining-count loops. Ask the user to synchronize at major milestones, then reacquire ids or resolve objects by stable names where appropriate.

Verification status: safety rules captured from repeated operational use; each new script still requires task-specific review and live read-back.
