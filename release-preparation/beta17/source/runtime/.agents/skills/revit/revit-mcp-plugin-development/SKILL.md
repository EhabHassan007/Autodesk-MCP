---
name: revit-mcp-plugin-development
description: Develop, register, build, test, update, and release Revit MCP tools and combined Autodesk connectors with guarded writes, portable setup, recoverable updates, and multi-client skill delivery.
category: revit
---

# Revit MCP plugin development

Trace the full path before changing it: AI client, MCP transport, combined bridge, Revit add-in, command registry, version-specific command assembly, installer, update channel, and skill distribution.

## Commands and Revit builds

1. Define a narrow server tool schema and send a named command with validated parameters.
2. Implement the command in the correct Revit command set and register it in that set's manifest.
3. Maintain the target framework and Revit API differences for each supported year.
4. Put model-changing commands behind the connector's authorization rules.
5. Build every supported target, restart the loaded service or Revit session, and verify with a harmless read plus write read-back when applicable.

Revit can lock loaded DLLs. Install content-addressed assembly filenames and update the add-in manifest so an update can finish while Revit is open and load after restart. Embed ribbon icons in the assembly when a self-contained add-in is required.

## Portable one-click setup

A shareable installer should expose one clearly named launcher, a short readme, and an internal support payload. Initial installation must use the packaged payload and must not require Git, private-repository access, Visual Studio, or a second download. Copy the managed runtime to a per-user installation folder, install skills and detected Revit builds, register detected AI clients, write an actionable setup log, and show one restart message on success.

Do not assume PowerShell module commands are available in a restricted launcher process. For file hashes, use `System.Security.Cryptography.SHA256` directly and close both the algorithm and file stream in `finally`. Parse every packaged PowerShell script, inspect both ZIP layers, verify the version and skill count, run the exact launcher, then read back installed files and registrations.

## Client registration and skills

Expose one stable user-level MCP name such as `autodesk`; remove only known legacy registrations and preserve unrelated servers. Register Codex and Claude Desktop from their backed-up configuration files, and register Claude Code only when its executable is detected. Restore the backup if registration fails.

Local skill destinations differ by client. Codex user skills and Claude Code user skills can be copied to their local folders. Claude Desktop account skills do not automatically import from a local Claude Code folder. For a free Claude account, generate one valid aggregate skill ZIP with a concise entrypoint and the individual workflows under references; the user uploads it once through Claude's Skills interface. Do not claim an account upload happened when only local files were copied. Paid plugin distribution and organization provisioning are separate release paths.

## Approved automatic updates

Use an approved branch as the only update source. An opt-in per-user task may compare the installed baseline with the approved remote commit, install a validated update automatically, and display only a restart notice after success. Keep ordinary progress on the host stream and emit explicit status markers for the notifier so progress text cannot corrupt return values. Test update-available, up-to-date, private-access failure, and rollback paths. Stay quiet when no approved change exists.

Treat incomplete Git metadata as a damaged managed installation. Validate with `git rev-parse`; download into a temporary location, verify required files, preserve only documented local state, replace with rollback protection, and record the installed baseline only after successful registration and read-back.

## Release boundary

Treat downloaded assemblies and scripts as executable code. Validate hashes or signatures, authenticate non-loopback transports, cap message size and connections, and keep arbitrary-code or deletion tools disabled unless explicitly enabled. Stop at a reviewed branch or pull request until the release owner approves publication.

Verification status: file-tested, installer-tested, live Codex and Claude Desktop registration read-tested, and live AutoCAD/Revit connection read-tested. Claude account skill upload remains a user-account UI step.
