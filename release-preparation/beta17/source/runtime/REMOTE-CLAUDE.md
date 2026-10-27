# Claude Free and paid remote connection

Claude Chat connects from Anthropic's cloud, so each Revit workstation needs a stable public HTTPS hostname. Autodesk MCP Connector keeps Revit's named pipe local and exposes only an authenticated MCP gateway through an outbound Cloudflare Tunnel. No inbound router port is opened.

## Team administrator: one tunnel per workstation

1. In Cloudflare Zero Trust, create a remotely managed tunnel for the workstation.
2. Assign a unique hostname such as `revit-user01.example.com`.
3. Route that hostname to `http://localhost:8765`.
4. Give that workstation only its tunnel token and hostname. Never reuse one tunnel token across the team.
5. Rotate a tunnel token immediately if it is disclosed.

Cloudflare account and DNS administration are external prerequisites. The connector cannot create a company domain or consent to Claude account access on a user's behalf.

## Workstation setup

1. Run **Install / Repair**.
2. Open setup again and choose **Claude remote**.
3. Enter the assigned HTTPS hostname and Cloudflare Tunnel token. Setup installs `cloudflared` when needed, encrypts both local credentials for the current Windows user, starts the gateway and tunnel, and registers startup at Windows sign-in.
4. For an individual Free, Pro, or Max account, open **Customize > Connectors** and add a custom Web connector. For a Team or Enterprise account, an Owner or Primary Owner adds it under **Organization settings > Connectors**; members then find and connect it under **Customize > Connectors**.
5. Name it `Autodesk MCP Connector`. If an organization has several Revit workstations, use `Autodesk MCP Connector - <user or workstation>` so members select the correct live Revit session. Use the displayed `/mcp` URL and add the displayed `Authorization` request header once. Claude stores this credential encrypted and sends it automatically.
6. Enable that connector in the conversation from the **+ / Connectors** menu and ask it to call `connection_status`.

Free Claude accounts may use one custom remote connector. Paid Claude accounts use the same endpoint. Adding a connector is an account-consent action and cannot be silently completed by a Windows installer.

If Claude answers that it can only see a local pipe such as `BimCadMcp.Revit.2024.<process>`, the remote connector is not enabled in that conversation. A Revit dialog showing **Local MCP server is ready** proves only that Revit is listening; `Requests served: 0` proves no MCP client has reached it yet.

## Skills for every user

- Codex and Claude Code receive every approved skill from `.agents/skills` during installation and update.
- Free and paid Claude Chat users upload `Autodesk MCP Skills for Claude.zip` once in **Customize > Skills**.
- Team or Enterprise owners can upload that same ZIP in organization settings to provision it for all members.
- New team candidates are sanitized locally and submitted to `EhabHassan007/Autodesk-MCP` on `skill-intake/*` branches as pull requests. Nothing merges without the repository owner's approval.

## Security defaults

- The HTTP gateway listens only on `127.0.0.1`; Cloudflare makes the outbound connection.
- Every request requires the unique workstation bearer credential.
- Request bodies are capped at 1 MB and unrecognized origins are rejected.
- `execute_csharp` is excluded from remote connections by default.
- Narrow writes remain available and serialized across Codex and Claude. Revit must be open and free of modal dialogs.
- Credentials, models, drawings, logs, and client data are never committed to GitHub.
