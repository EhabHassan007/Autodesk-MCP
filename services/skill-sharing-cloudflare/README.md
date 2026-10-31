# Cloudflare skills sharing (free-plan pilot)

This is the Cloudflare Workers + D1 alternative to the paid Render blueprint. It preserves the beta17 connector API: admin enrollment/revocation, weekly candidate submission, and approved-library download. No connector rebuild is needed to choose this service URL during enrollment. The Worker and D1 schema were deployed on 2026-10-28. Live GitHub App download, draft submission, deduplication and revocation checks passed on 2026-10-29. A private enrolled installer is prepared for the owner's Windows/Revit pilot; team rollout remains pending that pilot.

Deployed URL: `https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev`. Current verified version is `ce7ff578-2dd3-401e-a40f-51030771ab45`. Database `autodesk-skills` has UUID `3abe835e-22d1-4441-9c0c-ef844d8a1116`; migration `0001_initial.sql` succeeded remotely. Both encrypted secrets are configured. No billing-plan upgrade or connector release publication was performed.

Live verification on 2026-10-29 after the owner replaced the private key: `/health` and authenticated library downloads return 200; anonymous and revoked-device requests return 401. The service downloads 27 skills / 36 files from main commit `3c6c3e4e51b063b9038e8a36f8bbeaeb8724daca`. A harmless test submission created [draft PR 10](https://github.com/EhabHassan007/Autodesk-MCP/pull/10) as `autodesk-mcp-skills-ehabhassan007[bot]` on an intake branch. Repeated submission returned the same PR. The unapproved fixture remained absent from downloaded skills. Both temporary validation devices were revoked. The test PR was not merged and no candidate was approved.

The invalid administrator secret was replaced with a cryptographically random value directly in Cloudflare; its value was not printed or retained locally. The administrator can rotate it in Cloudflare when manual use of `admin.py` is needed. `tools/live-check.py` instead uses authorized Cloudflare D1 administration to create a temporary hashed device credential and always revokes that device. Default mode only reads GitHub; explicit `--submit-test` creates/reuses the harmless draft PR and verifies the approval boundary. Neither mode reads secret values. Python's default HTTP user-agent received Cloudflare error 1010; probes using `Autodesk-MCP-Connector/1.0.0-beta.17` reach the Worker normally.

Only `.agents/skills` on the configured `main` branch is distributed. New submissions create deterministic `skill-intake/central-*` branches and **draft** pull requests. This service never merges, writes to main, or publishes a release. Human approval remains necessary. It does not collect drawings, models, transcripts, or general PC files. Candidate content and executable files are untrusted; path/size/secret filters are heuristic, not approval.

## Free plan and limits

Use **Workers Free** and **D1 Free**, with a supplied `workers.dev` address. No domain purchase, persistent paid Render disk, R2, Durable Objects, queue, or paid Worker subscription is required by this implementation. Deployment commands do not upgrade a billing plan.

Cloudflare's published Workers Free limits checked on 2026-10-28 are 100,000 requests/day, 10 ms CPU/request and 50 external subrequests/invocation. D1 has its own free storage/read/write quotas. Quota exhaustion can interrupt service; local tests do not certify Cloudflare's CPU accounting. Run a live pilot with representative skills before team rollout, especially for large batches. Do not enable paid billing to work around a failure without owner authorization.

The approved library is limited to 100 skill names, 800 supported text files, 256 KiB/file and 2 MiB combined content. GitHub GraphQL batches 40 blobs per request, keeping the worst-case request count below the free external-request cap. The current main library is 36 files, approximately 107 KiB. An isolate caches the installation token and approved library briefly; durable device hashes and batch records live in D1. D1 rate counters and expiring batch claims are atomic across Worker isolates. A deterministic GitHub branch and PR lookup allow recovery after process loss or a lost response.

## Administrator deployment

The account ID in `wrangler.jsonc` is `9005326001bbb3ef9bc748643745e71f`, from the owner's dashboard. App ID `5506370`, installation ID `176074887`, and the deployed D1 UUID are configured. Reuse this database for redeployments.

1. Create an account-scoped Cloudflare API token with **Account → Workers Scripts → Edit** and **Account → D1 → Edit**, limited to this account. Keep it in the deployment environment's secure `CLOUDFLARE_API_TOKEN` binding, allowed only to `api.cloudflare.com`. Do not paste it into chat or commit it. Existing dashboard login does not authorize this chat's API calls.
2. From this directory, use Node 24 and `npm ci`. Run `npx wrangler d1 create autodesk-skills` (or reuse the existing database of this exact name). Put its UUID into `d1_databases[0].database_id`. Never recreate/delete an existing database during redeployment.
3. Run `npm run migrate:remote`, then `npm run deploy`. Keep the account on the Free plan. Wrangler applies only pending migrations. The service returns 503 until its required secrets are set.
4. In Cloudflare: **Workers & Pages → autodesk-skill-service → Settings → Variables and Secrets**, add encrypted secrets:
   - `GITHUB_PRIVATE_KEY`: the **complete contents** of the downloaded GitHub `.pem`, including BEGIN/END lines and newlines. Both PKCS#1 and PKCS#8 RSA formats are accepted. Store it directly in Cloudflare, never in chat, environment draft variables, GitHub source, or the connector ZIP.
   - `ADMIN_TOKEN`: a password-manager-generated random secret of at least 32 characters. Keep it administrator-only; never give it to team PCs.
5. Save/deploy those secret settings. Check `/health` (configuration and D1 schema), then authenticated `GET /admin/status` (read-only live GitHub App check). A health success alone does not certify GitHub access.

The Worker's only browser page is the same-origin admin dashboard at `/admin`. It does not enable cross-origin browser access. Deployment/API tokens, the GitHub private key, service admin token, and per-PC tokens are separate credentials with different purposes.

For local CLI work in the managed cloud workspace, use `XDG_CONFIG_HOME=/tmp/autodesk-cloudflare-config WRANGLER_SEND_METRICS=false` so Wrangler writes only to the permitted local directory. Use inherited proxy/CA settings. Do not bypass the environment's network policy.

## Team installer and admin dashboard

Migration `0002_team_enrollment.sql` adds the person profile, last-seen data and IP to `devices`. It also adds the `usage`, `submission_log` and `limits` tables. Run `npm run migrate:remote` before deploying this version.

- **Team join (`POST /v1/enroll`).** It is authorized by the `JOIN_CODE` secret: add it in Cloudflare next to `ADMIN_TOKEN`, as a random value of 32+ characters. It takes `{name, email, pc_name, windows_user, connector_version}` and returns `{device_id, device_token}`. The code ships inside the private team installer only.
  - Without `JOIN_CODE`, joining returns 503 and everything else keeps working.
  - After 10 wrong codes from one IP in an hour, that IP waits an hour before the code is even checked. Successful joins are limited to 60 per IP per hour, because an office shares one address.
  - To retire a leaked installer, change `JOIN_CODE` and rebuild. Devices that already joined keep working.
- **Usage (`POST /v1/usage`).** Device-authenticated. Accepts up to 500 `{kind: skill|tool, name, day, count}` events, which are aggregated per device and day. Names only, never arguments or content. It has its own 30-per-hour budget, separate from the 20-per-hour library/submission limit. Rows older than 180 days are deleted.
- **Every device call** records `last_seen`, the `CF-Connecting-IP` address and the `X-Connector-Version` header.
- **Dashboard.** Open `https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev/admin` and paste `ADMIN_TOKEN`. The token is kept for the browser tab only.
  - The page and its script contain no data. They load `GET /admin/api/overview` with the token and insert every value as text.
  - It shows each person, email, PC and Windows user, IP, join date, last seen, version, skills used (7 and 30 days), tools used and submissions.
  - Block/Unblock calls `POST /admin/devices/<id>/block|unblock`.
  - A strict CSP, `no-store` and `X-Frame-Options: DENY` apply.

## Skill review (owner approval, one skill at a time)

Migration `0004_review_decisions.sql` adds the `review_decisions` table. Run `npm run migrate:remote` before deploying this version.

Skills Sync sends all of a person's saved skills in one `skill-intake/*` draft PR. The **Skill review** tab in `/admin` turns those PRs into one queue:

- **What is listed.** The 8 oldest open intake PRs are read; decide those and refresh to see more. A skill is listed only when the upload changed it compared with the PR's own base, and it still differs from `main` today. Skills that are already approved are counted, not listed. Uploads are grouped by category folder, then by skill. When two people send the same skill, both uploads are shown, oldest first.
- **For each upload**, the tab shows:
  - the sender's team name, from the device that sent the batch (never the email), and the upload time;
  - whether the skill is new, changed or moved to another category;
  - a line diff of each changed file against the approved copy. The diff is worked out in the browser, which keeps Worker CPU low;
  - the checks. "Blocked" means the service structure check failed, or `description:` is missing, or the declared category doesn't match the folder, or a file is a link, binary or too large. Flags are possible secrets, personal paths (`C:\Users\…`, UNC paths) and email or ACC/BIM 360 links, found on the lines the upload adds. These are the same patterns as `scripts/validate-team-skill-intake.ps1`.
  - a warning when `main` changed that skill after the upload was made, so approving it could undo newer edits.
- **Approve** (`POST /admin/api/reviews/decide`): the owner chooses the category. The service re-reads the PR and refuses (409) if the upload or the approved copy changed since the page loaded. Blocked uploads cannot be approved, and flagged ones need the "I checked the flagged lines" box. The service then commits exactly the reviewed blobs for that one skill to `main`. The ref update is never forced, so if `main` moved meanwhile, the approval fails and nothing is overwritten. Team PCs receive the skill on their next Skills Sync. These commits go straight to `main`, so the PR workflow check does not run on them; the dashboard checks above stand in for it.
- **Reject** records the decision. An identical later upload of the same skill is hidden automatically.
- **Closing.** Once every skill in an intake PR is decided, the service comments a summary and closes the PR **without merging**. A PR with nothing left to decide can also be closed with **Close on GitHub**.
- **What else stays the same.** Uploads still arrive as draft PRs, and nothing reaches `main` without the owner's click. The GitHub App keeps its existing `contents:write` and `pull_requests:write` permissions. Merging an intake PR on GitHub still works, but it is all-or-nothing.

## Connect team PCs

On Windows, use `tools/New-DeviceEnrollment.ps1`; it needs no Python and defaults to the deployed URL. Each PC/user gets a unique revocable device token:

```
powershell -ExecutionPolicy Bypass -File tools\New-DeviceEnrollment.ps1 -Label Office-PC-01,Office-PC-02
```

It prompts once for the admin token without displaying it, then writes `Documents\Autodesk-MCP-Enrollments\<label>\enrollment.json` for each PC. The folder is restricted to the current Windows user. `devices.csv` beside them records label and device ID, without tokens, for later revocation (`DELETE /admin/devices/<device_id>`). Existing files are never overwritten. `../skill-sharing/admin.py enroll` remains an alternative where Python is available.

Place the PC's `enrollment.json` beside the beta17 installer, and deliver it privately using your admin deployment process. Run setup in the intended Windows user's context. Setup imports the token with user-scoped DPAPI and starts background collection/sync; weekly scheduling remains in the connector, not Cloudflare. The team needs no GitHub sign-in, Git author configuration, or separate skills setup. A public download by itself cannot securely enroll an unknown PC: admin provisioning remains necessary. Never embed a shared admin credential into a public installer.

Devices already enrolled against another service need a new enrollment file because the URL and credential store differ. There are no known live Render devices to migrate at preparation time.

The owner pilot ZIP is stored privately outside the checkout at `/workspace/artifacts/autodesk-beta17-pilot/Autodesk-MCP-Connector-beta17-Ehab-Pilot.zip`. It contains one device enrollment for the owner's test PC/user. Do not commit, upload to releases, or redistribute it to the team. Its adjacent private `pilot-metadata.json` records the revocable device ID and archive checksum without the token. All original installer members were byte-verified against the Windows-tested beta17 ZIP (SHA-256 `bf9d665de935ae8fd14fbfbc69dde7fad49612709412e0e85621fa9ada935ed9`); only the enrollment JSON and pilot instructions were added. The pilot device passed live library authentication. Windows DPAPI import, actual scheduled execution and Revit/Codex/Claude operation still need testing on the user's PC.

## Validation

```
npm ci
npm test
npm run test:runtime
npm run migrate:local
```

Unit/contract tests use actual SQLite with a D1 adapter. Runtime tests execute the **production bundle** in workerd with real local D1 and mocked GitHub responses. They generate a disposable RSA test key in memory, exercise signing, enrollment, approved library download, draft submission, restart persistence, duplicate suppression and revocation. They never use real credentials or create live PRs. The runtime test caught and fixed a Worker-specific unbound `fetch` invocation that Node alone did not catch.

Verified on 2026-10-31: 27 service and 8 review unit/contract tests pass, and the workerd/D1 runtime test now also applies migration 0004 and reads an empty review queue. The review tab was checked in a browser against a local Node server with sample uploads (GitHub not contacted). Live approval against GitHub has not been run yet.

Verified on 2026-10-29: all 14 unit/contract tests pass, including controlled secret-safe diagnostics and escaped/JSON-encoded PEM signatures; production bundle dry run and workerd/D1 integration test pass, including process restart. Local and remote D1 migrations passed previously. Runtime checks also required `redirect: manual` because Workers does not support Fetch's `error` redirect mode. Redirect statuses are rejected and credentials are never forwarded to a redirect target. These checks do not establish live library CPU usage, GitHub App authorization, or Revit operation.

Before publishing the connector update: validate live GitHub App permissions, free-plan CPU/quota usage, per-PC provisioning, real Windows/Revit scheduled sync, owner-approved merge/download, revocation and the beta15-to-beta17 update path. Keep beta17 a pilot/draft until those checks pass. Do not merge a sample candidate without owner approval.
