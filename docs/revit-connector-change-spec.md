# Revit connector: change spec from the STR link session

Status: proposal for developer review. No connector code was changed.
Source: the session handoff (8 requested connector changes) checked against the code in
`release-preparation/beta17/source/runtime/src` (`connector/RevitAndWorkflows.cs`, `connector/McpServer.cs`,
`revit/addin/RevitMcpApplication.cs`, `revit/addin/AdvancedControl.cs`, `revit/revit-bridge.ps1`).
Nothing here was run against a live Revit; statements marked **Confirmed** come from reading the code,
**Likely** from inference, **Not reproduced** where the code does not show the reported behaviour.

## Summary and recommended order

| # | Request | What the code does today | Change | Priority |
|---|---------|--------------------------|--------|----------|
| 1 | Own error types | Every failure from the add-in is wrapped as "Revit 2024 MCP session is not available" | Classify errors, return `error_type` | 1 |
| 2 | Document the runner contract | Tool description says nothing about variables or language level | Rewrite the `execute_csharp` description | 1 |
| 5 | Session routing | `session_id` is honoured; routing fails only when it is empty and several windows run | Route by `expected_document`; find out why the reported call failed | 1 |
| 4 | Busy state | `connection_status` needs Revit's main thread, so it cannot answer while Revit is busy | Answer status on the pipe thread | 1 |
| 3 | Results after a timeout | Result is discarded when the 120 s wait ends | Job id, `get_job`, progress | 2 |
| 6 | Dry run | Not present | `execution_mode` dry run for transaction code | 2 |
| 8 | Stable-key lookup | `get_element` takes an element id only | Read-only `resolve_keys` tool | 2 |
| 7 | Revision-cloud helpers | Not present | Read-only helpers only; keep creation in the skill | 3 |

Items 1, 2, 4 and 5 are small and remove most of the confusion seen in the session. Items 3 and 6 need a
protocol change between connector and add-in.

## 1. Compile and runtime errors under their own type

**Confirmed.** `RevitBridge.Call` catches every exception from `Pipe` and rethrows
`"Revit 2024 MCP session is not available. Start Revit or call list_sessions. " + message`. A compile error
from the add-in ("C# compilation failed: Line N: ...") and a runtime error ("C# execution failed: ...") therefore
arrive under the "not available" prefix. The failure `'doc' does not exist` was reported this way. The add-in
already separates the cases by message prefix; only the connector hides them. `tests/test-smart-connector-exe.ps1`
asserts the "session is not available" text for the no-Revit case, so that case must keep its wording.

Change:
- In `Call`, wrap only connect and I/O failures (`TimeoutException`, `IOException`) as `session_unavailable`.
  Errors the add-in returns (`ERR` lines) pass through unwrapped.
- Return a structured error: `error_type` plus `message`. Types: `compile_error` (with `lines`),
  `runtime_error`, `timeout`, `busy`, `document_changed`, `read_only`, `session_unavailable`,
  `session_ambiguous`, `rules_required`, `invalid_argument`.
- Minimal first step, no protocol change: classify by the existing prefixes ("C# compilation failed",
  "C# execution failed", "Active Revit document changed", "The active Revit document is read-only").
- Fuller step: the add-in sends `ERR<TAB>base64({"error_type":..., "message":...})`. The connector must still accept
  a plain-text `ERR` payload, because the add-in and the connector can be on different versions after a partial update.
- Keep `RevitBridge` (C#) and `revit-bridge.ps1` in step.

## 2. Document the runner contract

**Confirmed from `AdvancedControl.ExecuteCSharp`:**
- The code is the body of `public static string Run(UIApplication application, Document document, string parametersJson)`.
  The variables are `application`, `document` and `parametersJson`. **There is no `uidoc`**; use
  `application.ActiveUIDocument`. The handoff asked for `uidoc` to be documented: it does not exist, so either
  document `application.ActiveUIDocument` or add `uidoc` deliberately.
- Pre-imported namespaces: `System`, `System.Collections.Generic`, `System.Globalization`, `System.IO`,
  `System.Linq`, `System.Text`, `Autodesk.Revit.DB`, `Autodesk.Revit.UI`.
- Compiled with `CSharpCodeProvider` and `CompilerVersion v4.0`. **Likely** C# 5: no `?.`, no `$""` interpolation,
  no `nameof`, no expression-bodied members. This matches the `?.` compile error in the session.
- The code must return a string. `transaction` mode wraps it in one transaction and commits; `read` mode requires
  `allow_model_changes=false`; `manual` and `transaction` require `true`.
- Hard limit: 120 s for `execute_csharp`, 30 s for other operations (see item 3).

Change: put this into the `execute_csharp` description in `RevitBridge.Tools` and in `revit-bridge.ps1`
(the two descriptions are kept identical on purpose), and into the `revit-csharp-runner` skill.

## 3. Results retrievable after a timeout

**Confirmed.** `PipeHost` waits `request.Completed.Wait(120 s)` and then writes an error. The queued request is not
cancelled: Revit still runs it to the end on its main thread, and the result is thrown away. The pipe has one server
instance (`NamedPipeServerStream(..., 1, ...)`) and handles one request at a time, so while a long call is
waited on, a second client's `Connect(1500)` fails and is reported as "session not available". This explains the
80 s timeouts on read-only calls in the session. The timeout message ("Finish any active command or dialog and
retry") also invites the blind retry the team rules forbid.

Change:
- Keep the pipe thread free: accept connections concurrently (more than one server instance), and answer
  `connection_status`, `get_job` and `cancel_job` on the pipe thread without the Revit thread.
- `execute_csharp` returns `{job_id, state}` when the work has not finished within a short wait, or when
  `async=true` is passed. `get_job(job_id)` returns `queued | running | succeeded | failed`, the result or error,
  and progress. Keep finished results for a limited time and a limited count.
- Progress: expose a small static helper to the compiled code (for example `McpProgress.Report(done, remaining)`
  and `McpProgress.CancelRequested`), referenced from the add-in assembly the way `Document` is referenced now.
- Limit: Revit API calls cannot run off the main thread and cannot be interrupted. A job id makes the result
  retrievable; it does not make the call cancellable. Cancel only between batches, by the script checking
  `CancelRequested`.
- Rewrite the timeout message to say the request may still be running, to wait for the status bar to clear,
  and to read state before any new write.

## 4. Busy state in `connection_status`

**Confirmed.** `connection_status` goes through the same `ExternalEvent` queue as every other operation, so it cannot
be answered while Revit is regenerating. The connector then reports "the Revit 2024 add-in is not answering; it may
still be loading or busy".

Change:
- Answer `connection_status` on the pipe thread from `ConnectionState` plus a cached last document id.
- Add `busy` (a request is in flight or queued), `busy_since`, `current_operation` and `queue_length`.
  A request that is queued and not yet started while the pipe thread still answers is the signal for
  "Revit is busy" (the session's "Generating graphics").
- The connector summary should say "Revit is busy with <operation> since <time>" instead of "not answering".
- Not available from the API: the reason for the busy state. Report what the add-in knows (a queued request),
  not why the main thread is occupied.

## 5. `session_id` and several Revit windows

**Not reproduced by the code.** `ResolvePipe` returns the pipe for a given `session_id` and only throws
"More than one Revit session is running" when `session_id` is empty and more than one registered session exists.
The reported behaviour, a refusal with `session_id` passed, does not follow from this code path. Candidates to check
on a PC with two windows: the client relay (the remote-devices layer) dropping an optional argument; a stale
registry file in `revit-sessions`; or a call that went through another route. This needs a live reproduction,
with the arguments logged on the connector side, before any fix is claimed.

`list_sessions` already returns `document_id` for each window, so listing "which window holds which document"
exists. What is missing is routing by document.

Change:
- When `session_id` is empty and several sessions exist, and the call carries `expected_document`
  (`set_parameter` and `execute_csharp` always do), route to the one session whose `document_id` matches exactly.
  If none or more than one match, return `session_ambiguous` with the candidates.
- Log the received `session_id` in the error text so a dropped argument is visible.

## 6. Dry run

**Confirmed absent.** `transaction` mode starts a `Transaction`, runs the code and commits.

Change:
- New `execution_mode` value `dry_run` (transaction code only). Run the same code in a transaction, collect
  added, deleted and modified element ids through the `DocumentChanged` event while it runs, then `RollBack()`
  and return the counts per category.
- `manual` mode cannot be dry-run safely because the code manages its own transactions. A `TransactionGroup`
  rolled back around manual code might work; treat it as unverified and refuse `dry_run` for `manual` at first.
- A dry run costs about as much time as a real run because Revit still regenerates. It does not replace
  testing on one element first.
- **Uncertain, must be tested live:** in a workshared model, whether a rolled-back dry run still requests
  element ownership. Test on a detached copy before offering it on a central model.

## 7. Revision-cloud helpers

**Not present.** Recommendation: build only the read-only helpers, and keep creation in the skill.

Read-only, low risk:
- `list_cloud_tag_types`: loaded `FamilySymbol`s in the revision cloud tag category, with each family's real
  category, so a mis-categorised family is visible before anyone promises tags.
- `resolve_primary_views`: given view names and/or a view template name, return each view's primary view
  (`View.GetPrimaryViewId`) and mark dependents to skip.
- Both fit the stable-key tool in item 8.

Not recommended as a built-in tool yet: batch creation of clouds with notes and returning drawn bounding boxes.
The placement logic (gap from the drawn cloud box, note type, overlap handling) is workflow and office-standard
specific, and it is already covered by the `revit-link-comparison-revision-clouds` skill running through
`execute_csharp` in batches. Revisit when the same script has been used on several projects.
If it is built, it must take at most about 25 items per call, return `remaining`, and use one regeneration per batch.

## 8. Stable-key lookup

**Confirmed absent.** `get_element` accepts an integer element id only. In the session a revision id changed after a
restart and a count by the old id reported zero.

Change: a read-only tool `resolve_keys` taking any of
- `revision`: sequence number (and optionally description) returns id, sequence, description, issued state;
- `view`: name (and optionally view template name) returns id, view type, primary view id, template name;
- `type`: family and type name returns the element id and category;
- `link`: link instance name returns id, loaded state, transform summary.

Return `not_found` and `ambiguous` explicitly, with candidates. Scripts then never hold ids across a restart.

## Delivery notes

- Two bridges carry the Revit tools: the C# exe (`RevitAndWorkflows.cs`) and `revit/revit-bridge.ps1`.
  Change both, keep the tool descriptions identical, and update `tests/test-smart-connector-exe.ps1` and
  `tests/test-workflow-tools.ps1` where they assert messages or tool lists.
- The add-in (`revit/addin`) is built by `build-revit-addin.ps1` and installed into Revit. Connector and add-in
  can be on different versions, so every new protocol field must degrade to the old behaviour.
- Rebuild the stored installer in the same pull request (`build.ps1`, public build) because the runtime source changes.
  Do not publish to the public releases repository without the owner's approval.
- Live verification needs Revit 2024 on Windows: a long-running transaction (timeout and job), two open windows
  (routing), and a workshared copy (dry run). None of that was possible in the session that wrote this spec.
