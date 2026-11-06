# Central skill sharing — administrator deployment

The service and connector integration are implemented and locally tested. The service is not hosted yet and has not been connected to a live GitHub App. Do not publish this connector build as a working central rollout until the pilot below passes.

## One-time GitHub App setup

1. Create a GitHub App owned by your organization or account (GitHub Settings > Developer settings > GitHub Apps > New GitHub App).
2. Use your future service website as Homepage URL. User authorization callbacks are not needed; disable webhooks for this polling implementation.
3. Repository permissions: **Contents: Read and write**, **Pull requests: Read and write**, **Metadata: Read**. No account-wide permissions are needed.
4. Install it only on `EhabHassan007/Autodesk-MCP`.
5. Generate a private key. Record App ID and installation ID in your hosting secret manager. Never include the private key in a connector ZIP, repository, or chat.
6. Protect `main` with owner review requirements if other repository users must be prevented from bypassing approval. The service itself never merges, writes directly to main, or publishes a release.

This creates skill-review branches in the selected repository, not the public release repository. Draft PRs need your review and merge. Only merged skills on main are downloaded to PCs.

## Hosting

Deploy the included Dockerfile on a server/container host with a durable volume and an HTTPS reverse proxy. Use one worker and one instance for this SQLite implementation; do not run multiple replicas without adding distributed locking.

Required configuration:

- `GITHUB_APP_ID`: App ID.
- `GITHUB_INSTALLATION_ID`: selected installation ID.
- `GITHUB_REPOSITORY=EhabHassan007/Autodesk-MCP`.
- `GITHUB_PRIVATE_KEY_FILE=/run/secrets/github-app.pem`: mounted read-only private key, readable by UID 10001.
- `ADMIN_TOKEN`: a unique random secret of at least 32 characters; generate it in your hosting secret manager.
- `DATABASE_PATH=/data/intake.sqlite3`: mount persistent storage writable by UID 10001. Back it up.
- Optional: `GITHUB_BASE_BRANCH=main`, `GITHUB_REVIEWER=EhabHassan007`.

Serve HTTPS on a domain your PCs can reach. Proxy to container port 8080. Limit request bodies to 2 MB and set a finite body/read timeout. Restrict `/admin/*` to your administrator network in the proxy where possible, in addition to its admin token. Allow outbound HTTPS to api.github.com. Do not log Authorization headers or request bodies. The container intentionally disables HTTP access logs.

`GET /health` checks process availability, not GitHub permissions. Pin and scan images/dependencies through your deployment process; the Docker image was not built in this environment.

## Enroll PCs without team GitHub accounts

The administrator runs the included utility, not the team member. On Windows (Cloudflare service):

```
powershell -ExecutionPolicy Bypass -File services\skill-sharing-cloudflare\tools\New-DeviceEnrollment.ps1 -Label Office-PC-01,Office-PC-02
```

This writes `Documents\Autodesk-MCP-Enrollments\<label>\enrollment.json` per PC. With Python:

```
python admin.py enroll --service-url https://YOUR-SERVICE-HOST --label Office-PC-01 --output skill-service-device.json
```

Either utility prompts for the service administrator token without displaying it. It writes one **device credential**, which can only submit skill candidates and download approved skills. It has no GitHub API access. Enrollment requires an existing admin token; devices cannot enroll themselves anonymously.

Place that file beside `INSTALL Smart Connector.cmd` in the extracted connector folder before deploying the single setup to that PC/user. Use Intune, your endpoint-management tool, or another secure admin deployment process. Do not add the enrollment file to public release assets. Use a distinct enrollment for each participating PC/user.

Setup also accepts the file as `enrollment.json`, or from any path through `Setup-BimCad.ps1 -EnrollmentPath`. Setup stores the credential encrypted for the current Windows user using DPAPI, overwrites and deletes the plaintext enrollment file after every import attempt (successful or not), writes an `[ENROLLMENT_OK]` or `[ENROLLMENT_FAILED]` line to `%LOCALAPPDATA%\AutodeskMcpConnector\setup.log`, and starts a first background collection/sync. Weekly jobs then run in that user's session. No team GitHub account, Git installation, author name/email command, or separate skills upload is required for MCP workflow guidance.

IT must run setup in the intended user's context. An administrator/SYSTEM account would encrypt the credential for the wrong identity. Existing installs can be provisioned through the included Initialize-SkillService.ps1 under that user's context.

Revoke a lost/reassigned device:

```
python admin.py revoke --service-url https://YOUR-SERVICE-HOST --device-id DEVICE_ID
```

Device credentials are revocable but do not expire automatically in this initial version. Protect deployment files and local account access. Replace/revoke credentials when reassigning a PC.

## Flow and boundaries

- Every Friday at 16:30 local time (or the existing configured weekly schedule), the signed-in user's task scans saved-skill directories.
- New/changed candidates go to the service over HTTPS. Server validation is independent of client checks. Size/type/path/credential checks are heuristic; owner review is still required.
- The GitHub App creates a deterministic intake branch and a draft PR. The service deduplicates identical batches across PCs, reuses an existing PR after a retry, and never merges.
- After owner merge, the next successful sync downloads the approved main-branch skill library. Codex/Claude Code receive approved skills when this does not overwrite personal changes. The MCP workflow tools read the synchronized cache, so Claude can access guidance without uploading another ZIP.
- Native Claude Skills UI entries are not automatically created; the guidance is exposed through MCP tools.
- The connector's application update task remains separate and still uses public GitHub Releases. An approved skill merge does not publish a connector version.
- Pending conflicts or invalid candidates can prevent that run from completing; consult the local log. This prototype does not collect from other users' accounts or cloud chats.

## Pilot before rollout

1. Deploy HTTPS service; create/install the App and configure secrets.
2. Enroll one test PC/user; deploy the connector plus its enrollment file.
3. In Settings, verify enrolled status and run a preview; then submit a harmless sample saved skill.
4. Confirm exactly one draft PR appears in Autodesk-MCP. Repeat submission and verify no duplicate PR.
5. Merge the reviewed sample; run sync and verify Codex, Claude Code, and `list_skill_workflows` see it. Confirm a locally modified skill stays unchanged.
6. Revoke the test device; its next sync must fail with an authorization error and leave existing skills intact.
7. Enable normal rollout only after Windows scheduled-task, restart, and beta-version update tests pass.

## Tests included

Run `python -m unittest discover -s tests -v`. Tests use fake GitHub responses; they do not create real branches or PRs. PowerShell client tests are in the connector source bundle. Linux checks cannot certify Windows DPAPI, Task Scheduler, or native UI behavior.
