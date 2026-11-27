# 3ds Max bridge: design, security and privacy

Smart Connector reaches 3ds Max 2023–2027 through a small bridge that runs inside 3ds Max. It works like the Revit add-in: a local named pipe that SmartConnector.exe uses. The design is similar to the community 3dsmax-mcp project (cl0nazepamm/3dsmax-mcp, MIT), but no code was copied from it. The security model is the main difference.

## Parts

| Part | Where | What it does |
|---|---|---|
| `SmartConnector3dsMax.bundle` | `%APPDATA%\Autodesk\ApplicationPlugins` | Autodesk plug-in package. A post-start-up MAXScript starts the Python bridge and stops it at shutdown. No compiled code; no admin rights needed. |
| `smart_connector_max` (Python, standard library only) | inside the bundle | Pipe server (`server.py`), wire format (`protocol.py`), scene operations on 3ds Max's main thread (`ops.py`), section geometry and DXF output (`geometry.py`). |
| `MaxBridge.cs` | SmartConnector.exe | The `max_*` and `execute_max_python` MCP tools, plus the 3ds Max part of `connection_status`. |

Each 3ds Max session registers itself in `%LOCALAPPDATA%\BIM-CAD-MCP\runtime\max-sessions\<year>-<pid>.json`. The file holds its pipe name and a random 256-bit token, and is removed when 3ds Max closes.

## Security controls

| Risk | Control |
|---|---|
| Access from another computer | There is no TCP or HTTP port. The pipe is created with `PIPE_REJECT_REMOTE_CLIENTS`. |
| Another Windows user on the same PC | The pipe has a protected DACL granting access to the signed-in user only. The session file lives in that user's `%LOCALAPPDATA%`. |
| A local program that guesses the pipe name | Every request needs the session token, compared in constant time. A wrong token gets the same reply whatever the operation. |
| A program that takes the pipe name first (to receive code or the token) | The bridge creates the pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE` and refuses to start if the name is taken. Before sending anything, SmartConnector.exe checks that the pipe's server process (`GetNamedPipeServerProcessId`) is the registered `3dsmax.exe` process. The client connects with Anonymous impersonation, so the bridge cannot act as the connector. |
| A stale session file pointing to a reused process ID | Sessions are used only if that process is alive and named `3dsmax`. The token check fails otherwise anyway. |
| Malformed or oversized requests | Operations are allow-listed. Requests are capped at 4 MB, with one request per connection and at most 8 connections. Arguments are JSON only, never pickle or eval. |
| Unintended scene changes | Every tool except `execute_max_python` only reads the scene. `execute_max_python` requires `expected_scene`, `read` reports any scene change, and `write` runs in one undo block. Write calls share the connector's model-write lock with AutoCAD and Revit. Nothing saves the scene unless the code does. |
| Overwriting files | Exports, DXF sections and viewport captures always get a new name and never overwrite. `output_folder` must be an existing absolute local folder. |
| A blocked 3ds Max (open dialog) | Requests time out with `[max_busy]`. A request that never started is dropped, not run later. |

## Privacy

- Scene data goes only to the AI client that asked, through SmartConnector.exe on the same PC. The bridge has no network code and no telemetry.
- Answers contain only what the tool asked for. Texture and file references are returned as file names, not paths.
- Error reports to the administrator (computers joined to the team service only) use the existing cleaning rules. `.max`, `.fbx`, `.obj`, `.3ds` and `.skp` file names are now removed as well, and the product is recorded as `3dsmax`.
- The default export folder (`%LOCALAPPDATA%\BIM-CAD-MCP\exports\3dsmax`) is local. Choosing a cloud-synced project folder (ACC, OneDrive) uploads the file through that sync.
- Bridge log: `%LOCALAPPDATA%\BIM-CAD-MCP\runtime\logs\3dsmax-bridge.log`. It records start, stop and errors only, with no scene content.

## Limits

- `execute_max_python` is not a sandbox. It runs with the user's Windows permissions, like `execute_autocad`. Malware already running as the same user can read the session token, but such a program could control 3ds Max directly anyway.
- The pipe protocol is checked against offline tests (`release-preparation/beta17/tests/test_3dsmax_bridge.py`). The Windows pipe and the pymxs operations have not yet been verified live in 3ds Max; check them on the pilot PC before a release.

## Switching it off

- For one user: create the empty file `%LOCALAPPDATA%\BIM-CAD-MCP\runtime\max-bridge-disabled`, then restart 3ds Max.
- To remove it: `SmartConnector.exe engine --action Uninstall3dsMaxBridge`, or delete `%APPDATA%\Autodesk\ApplicationPlugins\SmartConnector3dsMax.bundle`.
