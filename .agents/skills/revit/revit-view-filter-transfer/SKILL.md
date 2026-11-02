---
name: revit-view-filter-transfer
description: Build or use a Revit add-in that copies selected view-filter definitions from the active project to another open project without activating or saving the destination.
---

# Revit view-filter transfer

Use this workflow when filter definitions must move between two project documents in the same Revit process. The source is the active command document; the destination is another open, writable project document. Exclude family documents, linked documents, the active source, and read-only destinations.

## Transfer design

1. Enumerate open project documents through the Revit application and present only valid inactive destinations. Do not require the destination to become active.
2. List supported source filter definitions with clear type and rule summaries. Treat parameter filters and selection filters separately; do not silently convert between them.
3. Default same-name behavior to **skip**. Offer an explicit renamed copy with a predictable suffix when needed. Never overwrite an existing filter definition implicitly.
4. Validate categories, parameters, shared or project parameter bindings, and rule operands in the destination before copying. Report missing dependencies per filter instead of creating a partially valid definition.
5. Use a destination transaction group with one transaction per filter. Commit successful filters, roll back a failed filter, and assimilate the group only after the requested batch has a coherent result.
6. Do not save or synchronize either document unless the user separately requests it.

When direct cross-document element copying is used, supply an identity transform and duplicate-type handling, then verify that the returned destination elements have the expected names, categories, rules, and counts. If the API cannot preserve a filter safely, recreate its supported rules explicitly or skip it with a reason.

## Add-in packaging

Run the command in a valid Revit API context and keep the selector UI owned by Revit. Compile against the intended Revit API. Package the compiled DLL, manifest installer, and instructions without source or build-tool dependencies. Use a content-addressed DLL filename so an installed update can coexist with a currently loaded version until Revit restarts. Embed a simple ribbon icon and verify the resource name in the built assembly.

Report copied, renamed, skipped, and failed filters separately, including dependency reasons. Read the destination back before claiming success.

Verification status: add-in build, installer, manifest, embedded icon, and open-document discovery were file-tested or read-tested. A cross-document write transfer still requires a test session with both source and destination projects open.
