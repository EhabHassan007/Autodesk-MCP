---
name: revit-mcp-plugin-development
description: Develop, register, build, test, and release Revit MCP server tools and version-specific Revit command sets with guarded writes and safe update behavior.
---

# Revit MCP plugin development

Understand the full path before changing it: AI client, MCP server transport, Revit add-in, command registry, version-specific command assemblies, and Revit API execution context.

## Add or change a command

1. Define a narrow server tool schema and send a named command with validated parameters.
2. Implement the Revit command in the correct command set and register it in that set's manifest.
3. Maintain the supported target frameworks and Revit API differences for every declared Revit year.
4. Add model-changing commands to the rules or authorization gate.
5. Build all supported targets, package them, and verify registration with a harmless read-only command.

Revit 2024 and later .NET-based releases may require different compilation paths. Keep dynamic compilation isolated, surface compile diagnostics with useful line numbers, unload transient assemblies where supported, and avoid assuming one compiler works for every Revit year.

## Registration and updates

Commands register when the MCP service starts. Updating files on disk does not prove a loaded Revit session sees them; restart the service or Revit and test. Loaded DLLs can remain locked. An updater that replaces a command directory must package every supported Revit build.

Treat downloaded command assemblies as executable code. Verify release signatures or pinned hashes before extraction, authenticate any non-loopback transport, cap message size and connections, and keep arbitrary-code and deletion commands disabled unless explicitly enabled.

## Release boundary

Follow repository ownership rules for version selection, tags, and releases. Ordinary implementation work should stop at a reviewed branch or main commit unless the authorized release owner approves publication. Release verification must include supported-version coverage, installer contents, registration, and rollback instructions.

Verification status: architecture and release guidance captured from the connected MCP; builds and releases require repository-specific tests.
