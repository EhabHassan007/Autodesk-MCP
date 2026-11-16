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

## Runner contract

- The code is the body of `Run(UIApplication application, Document document, string parametersJson)` and must return a string. Those three are the only variables: it is `document`, not `doc`, and there is no `uidoc` (use `application.ActiveUIDocument`).
- Language level is C# 5 (the .NET Framework compiler): no `?.`, no `$"..."` interpolation, no `nameof`, no expression-bodied members, no `out var`, no pattern matching.
- Already imported: `System`, `System.Collections.Generic`, `System.Globalization`, `System.IO`, `System.Linq`, `System.Text`, `Autodesk.Revit.DB`, `Autodesk.Revit.UI`. Any other namespace (for example `Autodesk.Revit.DB.Structure`) needs its full name.
- Read parameters with `LookupParameter`. A `BuiltInParameter` that exists in another Revit year may not exist in 2024 (`REVISION_CLOUD_COMMENTS` does not). Test an unfamiliar API call on one element before looping.
- Do not create a second project-document transaction inside `transaction` mode. A separately opened family document may need its own.
- Read all geometry and bounding boxes before writes to avoid regeneration inside loops. Use category filters and small batches rather than scanning entire views or models.
- Geometry `Options`: never set `DetailLevel` and `View` together. Revit throws "DetailLevel is already set. When DetailLevel is set view-specific geometry can't be extracted". For face references used by alignments or dimensions, use `new Options { ComputeReferences = true, View = targetView }` with no `DetailLevel`.
- Return a short result with changed, skipped, failed, and remaining counts. A long script can call `McpProgress.Report(done, total, note)` so `get_job` shows how far it is.

## Modes

| Mode | allow_model_changes | Use |
|---|---|---|
| `read` | false | Inspection only. No transaction is supplied. |
| `transaction` | true | Project writes inside one automatic transaction (`dry_run=true` to preview). Read back in a separate call. |
| `manual` | false | Probe: create, edit, save (to a temporary path) and close family documents. The project runs inside a transaction group that is always rolled back; any project change is undone and reported as `[probe_changed_project]`. Saving or synchronizing any non-family document is cancelled, and a change to another project is reported too (it cannot be rolled back, so close that document without saving). |
| `manual` | true | Code that manages its own project transactions, or changes the project from a family document (for example `famDoc.LoadFamily(document)`). |

## Errors, time limits and jobs

Errors come back typed. `[compile_error]` (with the line numbers of your own code and a hint for the usual mistakes) and `[runtime_error]` are problems in the code: fix the code. A `[runtime_error]` names the line (`at mcp_code.cs line N`, counted from the first line of your code) and the API method that threw, followed by any Revit failure messages with element ids. When it is a bare message such as "Document regeneration failed", isolate that one call in a probe run before changing the approach. `[document_changed]`, `[commit_failed]`, `[busy]` and `[invalid_request]` are about the request or Revit's state. "Revit session is not available" now means a real lost connection only.

`execute_csharp` waits `wait_seconds` (default 60, at most 110). Three outcomes:

- It finished: the normal result.
- `[busy]`: Revit never started the request (it is busy with its own work), so nothing ran and nothing changed. Check `connection_status`, wait until it reports idle, then send it again.
- `completed=false` with a `job_id`: Revit is still working. Do not run it again. Call `get_job` until `completed` is true; the result or error is kept for 60 minutes. `background=true` returns the `job_id` at once for work you expect to be long; a background request that Revit has not started within 5 minutes is cancelled and never runs, so check `get_job` and send it again when Revit is idle. `get_job` with `cancel=true` drops a job Revit has not started; a running one cannot be stopped.

`connection_status` and `get_job` answer even while Revit is busy. `connection_status` reports `busy_state`: `idle`, `executing` (with the job and its progress), `queued`, or `revit_busy` (Revit's own work: regenerating graphics, another command, a dialog).

## Dry run

`execute_csharp` with `execution_mode=transaction` and `dry_run=true` runs the code, rolls back every change to the active document and returns the change counts (added, modified, deleted, by category). It does not undo files the code writes or changes to other open documents; those documents come back as `other_documents_changed` with a warning, so keep dry-run code to the active document. Use it before any heavy or unfamiliar write and show the counts to the user. If the counts come back as unavailable, Revit raised no change events and the dry run proves only that the code runs. In a workshared model Revit may keep touched elements checked out after the rollback until the next synchronise, so do not dry-run on elements another person needs.

## Verification and recovery

A success response does not prove Revit committed the changes. Perform a separate read-back after every write batch. If values did not persist, capture Revit failure messages for the affected document and retry only after understanding the reason.

After a timeout, stop issuing writes. Never re-run the request: call `get_job` if there is a job id, otherwise `connection_status`, then inspect the model before deciding what is missing. If Revit remains blocked, ask the user to check for an open dialog. Never use blind retries or Ctrl+Z during an uncertain call.

Keep each write call to about 40 creations, one or two views at a time, regenerating once per batch. Never delete and recreate everything in one transaction: in a heavily linked model that blocks Revit for minutes. Before a heavy write confirm `connection_status` reports idle and ask the user to close views they do not need.

Keep batches proportional to model complexity and use remaining-count loops. Ask the user to synchronize at major milestones, then reacquire ids or resolve objects by stable names where appropriate.

Never report a count or a loss from a single check. Confirm it with a second method before telling the user.

Verification status: safety rules captured from repeated operational use; each new script still requires task-specific review and live read-back. The typed errors, jobs, busy state and dry run were added on 2026-11-12 after a failed session; they compile against the Revit 2024 API and pass simulated tests, and have not yet been run in a live Revit session.
