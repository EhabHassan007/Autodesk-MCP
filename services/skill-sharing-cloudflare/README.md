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
  - **Charts tab.** Six charts of the last 30 days, drawn in the browser as plain SVG from `GET /admin/api/overview` (no chart library and nothing loaded from outside, so the strict CSP is unchanged): activity per day (skills below, tools above), skills versus tools, the ten most used skills and tools, uses per person, and the connector versions the PCs run. Light and dark mode follow the browser. The per-day series is the overview's `daily` field (uses per day and kind, summed over all PCs). Hover a bar for its exact value and full name. They show uses only: the connector does not report whether a call failed.
  - A strict CSP, `no-store` and `X-Frame-Options: DENY` apply.

## Skill review (owner approval, one skill at a time)

Migration `0004_review_decisions.sql` adds the `review_decisions` table. Run `npm run migrate:remote` before deploying this version.

Skills Sync sends all of a person's saved skills in one `skill-intake/*` draft PR. The **Skill review** tab in `/admin` turns those PRs into one queue:

- **What is listed.** The 8 oldest open intake PRs are read; decide those and refresh to see more. A skill is listed only when the upload changed it compared with the PR's own base, and it still differs from `main` today. Skills that are already approved are counted, not listed. Uploads are grouped by category folder, then by skill. When two people send the same skill, both uploads are shown, oldest first.
- **For each upload**, the tab shows:
  - the sender's team name, from the device that sent the batch (never the email), and the upload time;
  - whether the skill is new, changed or moved to another category;
  - a line diff of each changed file against the approved copy. The diff is worked out in the browser, which keeps Worker CPU low;
  - the checks. "Blocked" means the service structure check failed, or `description:` is missing, or the declared category doesn't match the folder, or a file is a link, binary or too large. Flags are possible secrets, personal paths (`C:\Users\…`, UNC paths) and email or ACC/BIM 360 links, found on the lines the upload adds. These are the same patterns as `scripts/validate-team-skill-intake.ps1`. Damaged text encoding is flagged too, for example a dash that arrives as `Ã¢ÂÂ` or `â€”` after UTF-8 was read as another encoding, as in intake PR #24.
  - a warning when `main` changed that skill after the upload was made, so approving it could undo newer edits.
- **Category line.** The repository's own checks require every approved skill to declare, in `SKILL.md`, the category of the folder it sits in (`category: revit` in `.agents/skills/revit/...`). A skill without that line is shown as **Blocked** and cannot be approved, because approving it would make those checks fail on `main`. An upload that removes the line from an approved skill is blocked the same way. Approval is also refused if the category chosen differs from the one the skill declares. The fix is to add or restore the line in the skill and send it again.
- **Approve** (`POST /admin/api/reviews/decide`): the owner chooses the category. The service re-reads the PR and refuses (409) if the upload or the approved copy changed since the page loaded. Blocked uploads cannot be approved, and flagged ones need the "I checked the flagged lines" box. The service then commits exactly the reviewed blobs for that one skill to `main`. The ref update is never forced, so if `main` moved meanwhile, the approval fails and nothing is overwritten. Team PCs receive the skill on their next Skills Sync. These commits go straight to `main`, so the PR workflow check does not run on them; the dashboard checks above stand in for it.
- **Reject** records the decision. An identical later upload of the same skill is hidden automatically.
- **Closing.** Once every skill in an intake PR is decided, the service comments a summary and closes the PR **without merging**. A PR with nothing left to decide can also be closed with **Close on GitHub**.
- **What else stays the same.** Uploads still arrive as draft PRs, and nothing reaches `main` without the owner's click. The GitHub App keeps its existing `contents:write` and `pull_requests:write` permissions. Merging an intake PR on GitHub still works, but it is all-or-nothing.

## Notion dashboard (hourly sync)

Migration `0005_notion_sync.sql` adds the one-row `notion_sync` table. The Worker and D1 stay the secure backend and the source of truth; Notion is only a view. Edits made in Notion are overwritten on the next sync where they differ, and nothing in D1 changes.

- **What is synced.** Two existing databases on the "Smart Connector – Team Insights" page. Their data source IDs are the `NOTION_MEMBERS_SOURCE` and `NOTION_USAGE_SOURCE` vars in `wrangler.jsonc`.
  - **Team members**, one row per device, matched by `Device ID`: name, work email, PC, Windows user, connector version, Active/Blocked, joined, last seen, skill and tool uses in the last 30 days, top 3 skills and terms version.
  - **Skills and tools usage**, one row per skill or tool, matched by `Key` (`skill:<name>` / `tool:<name>`): uses and distinct people in the last 30 days, and the last day used. A row with no use in 30 days is set to 0 uses and 0 people; its last-used day is kept. Rows are never deleted.
- **Schedule.** Cron `17 * * * *` (minute 17 of every hour, UTC). `POST /admin/api/notion-sync` (admin token) runs it now and returns the summary `{members:{created,updated,unchanged}, usage:{…}, pending, at}`, or `error: "Notion HTTP <status>"` with HTTP 502. The last summary is also in `GET /admin/api/overview` as `notion_sync`.
- **Free-plan limits.** Workers Free allows 50 subrequests per run. Each run reads both databases (one request per 100 rows), compares, and writes only rows that differ: at most 40 writes, and never more than 48 Notion requests in total. Team members go first. Anything left is reported as `pending` and is written on the next hourly run. Notion allows about 3 requests a second; on HTTP 429 the Worker waits for `Retry-After` (at most 5 s) once, and any other failure stops that run. Errors report only the HTTP status, never the token, request bodies or personal data. Note that `Last seen` changes whenever a PC calls the service, so a team much larger than 40 active devices fills the write cap with member updates and usage rows wait longer.
- **Privacy.** Names and work emails, PC and Windows user names are copied to Notion. The company's terms/privacy notice for the connector must say so before this is turned on.

Owner setup:

1. At [notion.so/my-integrations](https://www.notion.so/my-integrations), create an **internal** integration for the workspace with the **Read content**, **Update content** and **Insert content** capabilities. No user-information capability is needed.
2. Open the "Smart Connector – Team Insights" page in Notion, choose **••• → Connections**, and add the integration. This lets it reach both databases under that page.
3. From this directory, run `npx wrangler secret put NOTION_TOKEN` and paste the integration's secret at the prompt. Never paste it into chat or commit it. Without `NOTION_TOKEN` the sync skips itself (`{skipped: "not configured"}`) and nothing else changes.
4. Run `npm run migrate:remote`, then `npm run deploy`. Deploying also registers the hourly cron.
5. Run `POST /admin/api/notion-sync` once with the admin token, or wait for the next hour, and check the summary. A first run on a larger team may show `pending` above 0; the next runs catch up.

## Skill review in Notion

Migration `0006_notion_review.sql` adds `notion_review` (what each Notion row is about) and `notion_review_sync` (the last run). The dashboard's **Skill review** tab keeps working as before; this adds the same review as a Notion database, "Skill review" on the "Smart Connector – Team Insights" page (data source `NOTION_REVIEW_SOURCE`, `ca563d75-3682-47a0-a994-d574182fb2b3`).

- **What you see.** One row per skill waiting for review: name, description, sender (team name, never the email), upload time, new/changed/moved, the files, a link to *Files changed* on GitHub, `Blocked` (a required check failed) and `Flags` (where a heuristic check found something: the place only, never the text, because a flagged line may be a secret).
- **How you decide.** Set **Decision** to Approve or Reject. For Approve, check **Category** (pre-filled from the upload) and, when the row shows Flags, tick **Flagged lines checked**. Within the hour the service applies it and writes **Status** (Approved, Rejected, Not applied, Changed) and **Result**. Approving still writes exactly one skill to `main` and closes the intake PR without merging, through the same function the dashboard uses (`applyDecision`).
- **Who may decide.** Notion lets everyone with edit access change a row, so the service applies a decision only when the person who last edited the row is listed in `NOTION_REVIEWERS` (comma-separated Notion user IDs). With no list, nothing is applied, and the row's Result prints the editor's ID so it can be added. Anyone else's change is cleared and reported as Not applied.
- **What a decision applies to.** The values the service stored in D1 when it wrote the row (PR, skill, head commit, content keys), not what the page says now, so editing Name or Reference changes nothing. The live upload is re-read and compared exactly as in the dashboard: if the upload or the approved copy changed, the decision is refused (Status Changed) and the row is refreshed for a new look. Blocked uploads cannot be approved. Flagged ones need the tick.
- **Schedule and limits.** A second cron, `47 * * * *`, so this run has its own 50-subrequest budget (the members/usage cron is `17 * * * *`). A run applies at most 2 decisions (about 15 GitHub requests each), reads the queue only if budget remains (4 pull requests at most), and writes at most 15 rows. The rest carries over to the next hour. `POST /admin/api/notion-review` (admin token) runs it now. A GitHub outage leaves the decision in place to retry; a Notion error reports only its HTTP status.
- **Rows.** Rows of decided or vanished uploads are marked Closed, not deleted. A row you delete is made again while the upload still waits.

Owner setup (after the Notion dashboard steps above, so the integration already has access to the page):

1. In Notion, open the "Smart Connector – Team Insights" page and make sure the integration is connected (••• → Connections). It reaches the new database through the page.
2. `npx wrangler secret put NOTION_REVIEWERS` and enter your own Notion user ID. To find it: set Decision on any row first; the service answers in Result with "Add your Notion user ID (…)" and that value is what to enter. Several reviewers: comma-separated.
3. `npm run migrate:remote`, then `npm run deploy` (registers the second cron).
4. Run `POST /admin/api/notion-review` once. Rows appear for uploads that wait.

## Connector error reports

Migration `0007_failures.sql` adds `failures` (one cleaned message per fingerprint), `failure_counts` (counts per fingerprint, device, day and connector version) and `notion_failure_sync` (the last run). Run `npm run migrate:remote` before deploying this version.

- **What arrives.** `POST /v1/failures` (device token, at most 60 requests per device per hour, 1 to 100 events each). An event has exactly `tool`, `product` (revit, autocad or connector), `code`, `message` (at most 300 characters, already cleaned by the connector), `outcome` (failed or recovered), `day` and `count`. The service cleans each message again, also removing the sender's name, Windows user and PC name, then groups it by `sha256(product, tool, code, message)`. The same error from many PCs or versions is one row. `tests/error-messages.json` holds the examples that the C# and JavaScript cleaners must both pass.
- **Retention.** Counts older than 180 days are deleted. The dashboard and Notion show the last 30 days.
- **Notion.** A third cron, `7 * * * *`, copies the last 30 days into a "Connector failures" database whose data source ID is the `NOTION_FAILURES_SOURCE` var. Without that var or `NOTION_TOKEN` the run skips itself. A run writes at most 40 rows; the rest carries over. `POST /admin/api/notion-failures` (admin token) runs it now. Errors that stopped happening keep their row with zero counts.
- **Columns.** Name (title), Status (select: New, plus any options you add), Product (select), Tool, Error code, Message, Who, Versions, Fingerprint (text), Failures (30 days), Recovered (30 days), People (30 days) (number), First seen, Last seen (date). The service sets Status to New only when it creates a row and never changes it afterwards, so you can use Status for your own triage.

Owner setup:

1. The "Connector failures" database already exists on the "Smart Connector – Team Insights" page (data source `NOTION_FAILURES_SOURCE`, `41a5a80a-6f4f-8187-a925-000beeaf74ac`, set in `wrangler.jsonc`). Its Status options are New, Investigating, Fix planned, Fixed, User mistake and Ignore.
2. Make sure the integration is connected to that page (••• → Connections), as for the other databases.
3. `npm run migrate:remote`, then `npm run deploy` (registers the third cron).
4. Run `POST /admin/api/notion-failures` once.

Check before deploying that the account's plan allows a third cron trigger. Error reports are still stored in D1 without the Notion step.

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
