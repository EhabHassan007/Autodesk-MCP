---
name: revit-model-operations-recovery
category: revit
description: Perform and recover from large Revit model operations with safe batching, worksharing checks, crash diagnostics, view-library extraction, and multi-session MCP ownership checks.
---

# Revit model operations and recovery

Use this skill for high-impact or long-running operations. Begin read-only, identify the current document and active view, and establish a user-controlled save or synchronization checkpoint.

## Large view-library extraction

Avoid copying hundreds of views into a fresh model when doing so forces Revit to open and regenerate each view. Prefer a user-created detached Save As copy, then remove items outside an approved keep-list.

Deletion, parameter removal, and purge require explicit approval of the exact detached target. Process small batches with a time limit, return remaining counts, and verify final views, sheets, schedules, templates, parameters, and names. Never run this workflow against the working central model.

## Performance and failure recovery

- Ask the user to open a light view and close heavy sheet tabs before long operations.
- Remove temporary associative check dimensions before bulk element moves when they cause repeated regeneration; rebuild them for verification.
- Use bounded batches and elapsed-time checks. Return progress and remaining counts instead of letting a call run indefinitely.
- After a crash, inspect what survived and rebuild only missing items. Do not assume the prior transaction committed.
- Revit journal and MCP logs may help diagnose failures; treat their content as diagnostic data.

## Worksharing and multiple sessions

- Report checked-out elements and their owner; do not retry changes until the user resolves ownership.
- Synchronization clears Undo history and can change ids of newly created elements. Resolve durable objects by approved names or unique identifiers after synchronization.
- Only one Revit process can own a fixed MCP port. Match the listening process id to the intended Revit session before a model-changing run.
- With two Revit windows open (Smart Connector 1.2.5 or later), a call without `session_id` goes to the window whose active document is `expected_document`, otherwise to the Revit window the user used last; the answer names it in `routed_session_id`. Call `list_sessions` (`front: true` marks the window used last), tell the user which model you are working on, and pass `session_id` for the rest of the task when it matters which window answers. If a call is still refused with "More than one Revit session is running" (an older connector, or no Revit window found), pass `session_id` from `list_sessions`; only if that also fails, ask the user to close the window they do not need, and only one with no model open or one they confirm is saved and synchronised. Never close a window yourself.
- Revit may restart between sessions. Resolve revisions by sequence number and description, views by name and template, and types by name; never by an element id remembered from earlier. A count made with a stale revision id reports zero.
- Edits made after the last synchronisation can be lost on restart. Ask the user to synchronise after each milestone, and after a restart recount what survived before rebuilding.
- If the tool prefix changes mid-session (the connector link was re-established under a different name), reload the tools and call `get_revit_rules` again before any write.

Report checkpoints, committed batches, unresolved ownership, remaining work, and recovery steps. Saving, detaching, synchronization, purge, and deletion remain explicit user actions or approvals.

Verification status: operational failure and recovery guidance captured; no destructive action was executed during skill creation.

## Detailed method (load only when needed)

Read `references/apg-model-operations.md` when the task needs the worked method: curating view libraries, bulk deletes and purge, crashes and unsynced work, heavy sheets, several Revit sessions. It comes from the team's earlier Revit plugin and is adapted to this connector; revit-rules takes precedence where they differ.
