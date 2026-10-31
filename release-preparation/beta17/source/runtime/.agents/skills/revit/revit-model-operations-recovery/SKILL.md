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

Report checkpoints, committed batches, unresolved ownership, remaining work, and recovery steps. Saving, detaching, synchronization, purge, and deletion remain explicit user actions or approvals.

Verification status: operational failure and recovery guidance captured; no destructive action was executed during skill creation.
