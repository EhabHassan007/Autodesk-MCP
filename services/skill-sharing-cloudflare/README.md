# Cloudflare skills sharing (free-plan pilot)

This is the Cloudflare Workers + D1 alternative to the paid Render blueprint. It preserves the beta17 connector API: admin enrollment/revocation, weekly candidate submission, and approved-library download. No connector rebuild is needed to choose this service URL during enrollment. The Worker and D1 schema were deployed on 2026-10-28. GitHub App authentication and device enrollment remain pending secret configuration and live checks.

Deployed URL: `https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev`. Current verified version is `4e8994c9-e2c0-4328-a639-829c1b83e7c6`. Database `autodesk-skills` has UUID `3abe835e-22d1-4441-9c0c-ef844d8a1116`; migration `0001_initial.sql` succeeded remotely. Both encrypted secret names are configured. No billing-plan upgrade or connector release publication was performed.

Live verification on 2026-10-29: `/health` returns 200; anonymous and revoked-device library requests return 401. An authenticated disposable device reaches the GitHub integration but receives 502: the saved `GITHUB_PRIVATE_KEY` cannot be parsed or used for signing. Literal escaped newlines and JSON-quoted PEM strings are normalized, so these common paste formats no longer cause failures. The owner needs to replace the secret directly in Cloudflare with the full contents of a valid GitHub App PEM. GitHub permissions, skill downloads and submissions are not yet verified live. The disposable test device was revoked even after failure.

The invalid administrator secret was replaced with a cryptographically random value directly in Cloudflare; its value was not printed or retained locally. The administrator can rotate it in Cloudflare when manual use of `admin.py` is needed. `tools/live-check.py` instead uses authorized Cloudflare D1 administration to create a temporary hashed device credential, performs a read-only GitHub check, and always revokes that device. It never reads secret values or writes GitHub. Python's default HTTP user-agent received Cloudflare error 1010; probes using `Autodesk-MCP-Connector/1.0.0-beta.17` reach the Worker normally.

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

The Worker has no browser admin UI and does not enable cross-origin browser access. Deployment/API tokens, the GitHub private key, service admin token, and per-PC tokens are separate credentials with different purposes.

For local CLI work in the managed cloud workspace, use `XDG_CONFIG_HOME=/tmp/autodesk-cloudflare-config WRANGLER_SEND_METRICS=false` so Wrangler writes only to the permitted local directory. Use inherited proxy/CA settings. Do not bypass the environment's network policy.

## Connect team PCs

Use the existing administrator tool in `../skill-sharing/admin.py` with the resulting HTTPS `workers.dev` URL. Each PC/user gets a unique revocable device token:

```
python ../skill-sharing/admin.py enroll --service-url https://YOUR-WORKER.YOUR-SUBDOMAIN.workers.dev --label Office-PC-01 --output skill-service-device.json
```

The utility prompts privately for the admin token. Place that enrollment file beside the beta17 installer, and deliver it privately using your admin deployment process. Run setup in the intended Windows user's context. Setup imports the token with user-scoped DPAPI and starts background collection/sync; weekly scheduling remains in the connector, not Cloudflare. The team needs no GitHub sign-in, Git author configuration, or separate skills setup. A public download by itself cannot securely enroll an unknown PC: admin provisioning remains necessary. Never embed a shared admin credential into a public installer.

Devices already enrolled against another service need a new enrollment file because the URL and credential store differ. There are no known live Render devices to migrate at preparation time.

## Validation

```
npm ci
npm test
npm run test:runtime
npm run migrate:local
```

Unit/contract tests use actual SQLite with a D1 adapter. Runtime tests execute the **production bundle** in workerd with real local D1 and mocked GitHub responses. They generate a disposable RSA test key in memory, exercise signing, enrollment, approved library download, draft submission, restart persistence, duplicate suppression and revocation. They never use real credentials or create live PRs. The runtime test caught and fixed a Worker-specific unbound `fetch` invocation that Node alone did not catch.

Verified on 2026-10-29: all 14 unit/contract tests pass, including controlled secret-safe diagnostics and escaped/JSON-encoded PEM signatures; production bundle dry run and workerd/D1 integration test pass, including process restart. Local and remote D1 migrations passed previously. Runtime checks also required `redirect: manual` because Workers does not support Fetch's `error` redirect mode. Redirect statuses are rejected and credentials are never forwarded to a redirect target. These checks do not establish live library CPU usage, GitHub App authorization, or Revit operation.

Before publishing the connector update: validate live GitHub App permissions, free-plan CPU/quota usage, per-PC provisioning, real Windows/Revit scheduled sync, owner-approved merge/download, revocation and the beta15-to-beta17 update path. Keep beta17 a pilot/draft until those checks pass. Do not merge a sample candidate without owner approval.
