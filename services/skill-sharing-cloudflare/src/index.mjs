import { timingSafeEqual } from 'node:crypto';
import { GitHub, safeGitHubDetail } from './github.mjs';
import { bytes, canonical, CATEGORIES, hash, MAX_BODY, SKILL_NAME, validateProfile, validateSkills, validateUsage, VERSION } from './validation.mjs';
import { groupReviews, reviewSummary, undecided } from './review.mjs';
import { DASHBOARD_CSS, DASHBOARD_HTML, DASHBOARD_JS } from './dashboard.mjs';
import { lastSync, saveSync, syncToNotion } from './notion.mjs';
import { lastReviewSync, saveReviewSync, syncReviews } from './notion-review.mjs';

class HTTPError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const json = (data, status=200) => Response.json(data, {status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
const random = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
const now = () => Math.floor(Date.now()/1000);
function bearer(request) {
  const header = request.headers.get('Authorization') || '';
  if (!header.startsWith('Bearer ') || header.length > 512) throw new HTTPError(401,'Authorization required.');
  return header.slice(7);
}
async function secretMatches(request, secret) {
  return timingSafeEqual(bytes(await hash(bearer(request))), bytes(await hash(secret)));
}
async function admin(request, env) {
  if (!await secretMatches(request, env.ADMIN_TOKEN)) throw new HTTPError(403,'Administrator access required.');
}
// Cloudflare sets this header; it is absent only in local tests.
const clientIP = request => (request.headers.get('CF-Connecting-IP') || '').slice(0,64) || null;
// Generic hourly counter for limits that must not share the device's library/submission budget.
async function limit(db, key, max) {
  const row = await db.prepare(`INSERT INTO limits(key,hour,count) VALUES(?,?,1)
    ON CONFLICT(key) DO UPDATE SET hour=excluded.hour,
    count=CASE WHEN limits.hour=excluded.hour THEN limits.count+1 ELSE 1 END RETURNING count`)
    .bind(key,Math.floor(now()/3600)).first();
  if (row.count > max) throw new HTTPError(429,'Request limit reached; retry later.');
}
async function device(request, db, rated=true) {
  const row = await db.prepare('SELECT id FROM devices WHERE hash=? AND active=1').bind(await hash(bearer(request))).first();
  if (!row) throw new HTTPError(401,'Device credential invalid or revoked.');
  if (rated) {
    // One atomic SQLite statement prevents simultaneous requests bypassing the limit.
    const rate = await db.prepare(`INSERT INTO rate(device,hour,count) VALUES(?,?,1)
      ON CONFLICT(device) DO UPDATE SET hour=excluded.hour,
      count=CASE WHEN rate.hour=excluded.hour THEN rate.count+1 ELSE 1 END RETURNING count`)
      .bind(row.id,Math.floor(now()/3600)).first();
    if (rate.count > 20) throw new HTTPError(429,'Request limit reached; retry later.');
  }
  const version = request.headers.get('X-Connector-Version');
  await db.prepare('UPDATE devices SET last_seen=?,last_ip=COALESCE(?,last_ip),connector_version=COALESCE(?,connector_version) WHERE id=?')
    .bind(now(),clientIP(request),version && VERSION.test(version) ? version : null,row.id).run();
  return row.id;
}
const page = (body, type) => new Response(body,{headers:{
  'Content-Type':type,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','X-Frame-Options':'DENY',
  'Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"}});
const DAY = 86400;
const isoDay = seconds => new Date(seconds*1000).toISOString().slice(0,10);
async function readJSON(request) {
  const length = Number(request.headers.get('Content-Length') || 0);
  if (length > MAX_BODY) throw new HTTPError(413,'Request too large.');
  const reader = request.body?.getReader();
  if (!reader) throw new HTTPError(422,'JSON body required.');
  let lengthRead=0;
  const chunks=[];
  while (true) {
    const {value,done}=await reader.read();
    if (done) break;
    lengthRead += value.byteLength;
    if (lengthRead > MAX_BODY) { await reader.cancel(); throw new HTTPError(413,'Request too large.'); }
    chunks.push(value);
  }
  const buffer = new Uint8Array(lengthRead);
  let offset=0;
  for (const chunk of chunks) { buffer.set(chunk,offset); offset+=chunk.byteLength; }
  try { return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(buffer)); }
  catch { throw new HTTPError(422,'Invalid JSON body.'); }
}

const REVIEW_CRON = '47 * * * *';   // Must match wrangler.jsonc.
// Decided uploads ("pr/skill") and rejected content ("skill/key"), so neither comes back for review.
async function reviewState(db) {
  const rows = (await db.prepare('SELECT pr,skill,decision,content_key FROM review_decisions').all()).results;
  return {decisions:new Set(rows.map(r=>`${r.pr}/${r.skill}`)),rejected:new Set(rows.filter(r=>r.decision === 'reject').map(r=>`${r.skill}/${r.content_key}`))};
}
// Who sent each intake PR: the team member's name (never the email), plus anyone who later sent the same batch.
async function sendersFor(db, urls) {
  if (!urls.length) return {};
  const rows = (await db.prepare(`SELECT b.url,l.at,COALESCE(d.person_name,d.label) AS name FROM batches b
    JOIN submission_log l ON l.digest=b.digest JOIN devices d ON d.id=l.device
    WHERE b.url IN (${urls.map(()=>'?').join(',')}) AND l.status IN ('submitted_for_approval','already_submitted') ORDER BY l.at`).bind(...urls).all()).results;
  const senders = {};
  for (const row of rows) {
    const sender = senders[row.url] ??= {name:row.name,at:row.at,also:[]};
    if (row.name !== sender.name && !sender.also.includes(row.name)) sender.also.push(row.name);
  }
  return senders;
}
// Closes an intake PR with a summary once every skill it proposes is decided; false while any is open.
async function closeWhenDecided(db, gh, pr, items) {
  const known = await reviewState(db);
  if (undecided(items,pr,known.decisions,known.rejected).length) return false;
  const rows = (await db.prepare('SELECT skill,decision,category FROM review_decisions WHERE pr=? ORDER BY skill').bind(pr).all()).results;
  const decided = new Set(rows.map(r=>r.skill));
  await gh.closeIntake(pr,reviewSummary(rows,items.filter(i=>i.pr === pr && !decided.has(i.name)).map(i=>i.name)));
  return true;
}

// Cached token/library belongs to this binding configuration, never to another app.
let cachedGitHub, cachedEnv;
function github(env) {
  if (cachedEnv !== env) { cachedGitHub = new GitHub(env); cachedEnv = env; }
  return cachedGitHub;
}

// The one place a reviewed skill is approved or rejected, for the dashboard and for Notion alike.
// The decision applies only to the exact upload and approved copy that were reviewed. Throws HTTPError.
export async function applyDecision(env, gh, data) {
  const {pr,skill,decision,head_sha,key,approved_key,category} = data ?? {};
  if (!Number.isInteger(pr) || pr < 1 || typeof skill !== 'string' || !SKILL_NAME.test(skill) || !['approve','reject'].includes(decision)
    || ![head_sha,key,approved_key].every(v=>typeof v === 'string' && v.length <= 100)) throw new HTTPError(422,'Invalid review decision.');
  if (decision === 'approve' && (!CATEGORIES.has(category) || category === 'uncategorized')) throw new HTTPError(422,'Choose the category this skill belongs to.');
  let current;
  try { current = await gh.reviewOne(pr); }
  catch (error) { throw new HTTPError(502,safeGitHubDetail(error)); }
  const item = current?.items.find(i=>i.name === skill);
  if (!item || item.head_sha !== head_sha || item.key !== key || item.approved_key !== approved_key)
    throw new HTTPError(409,'This upload or the approved copy changed, or it was already handled. Refresh and review it again.');
  if (decision === 'approve' && item.checks.blocked.length) throw new HTTPError(422,'This upload fails a required check and cannot be approved.');
  // The skill must declare the category of the folder it is placed in, or the repository checks fail.
  const declared = item.checks.declared;
  if (decision === 'approve' && declared && declared !== category)
    throw new HTTPError(422,`This skill says "category: ${CATEGORIES.has(declared) ? declared : 'another category'}". Choose that category, or fix the line first, so the repository checks pass.`);
  if (decision === 'approve' && item.checks.flags.length && data.accept_flags !== true) throw new HTTPError(422,'Confirm that you checked the flagged lines before approving.');
  const claimed = await env.DB.prepare(`INSERT INTO review_decisions(pr,skill,head_sha,content_key,decision,category,at) VALUES(?,?,?,?,?,?,?)
    ON CONFLICT(pr,skill) DO NOTHING RETURNING pr`).bind(pr,skill,head_sha,key,decision,decision === 'approve' ? category : null,now()).first();
  if (!claimed) throw new HTTPError(409,'This upload was already decided.');
  let commit = null;
  if (decision === 'approve') {
    try { commit = await gh.approveSkill(item,category); }
    catch (error) {
      await env.DB.prepare('DELETE FROM review_decisions WHERE pr=? AND skill=?').bind(pr,skill).run();
      throw new HTTPError(502,safeGitHubDetail(error));
    }
    await env.DB.prepare('UPDATE review_decisions SET commit_sha=? WHERE pr=? AND skill=?').bind(commit,pr,skill).run();
  }
  let closed = false;
  try { closed = await closeWhenDecided(env.DB,gh,pr,current.items); } catch { /* The decision stands; the PR can be closed from the dashboard. */ }
  return {pr,skill,decision,commit,closed};
}

// Notion "Skill review": apply the owner's decisions, then list what waits for review. Same checks as the dashboard.
export async function runReviewSync(env, {gh, ...options} = {}) {
  return saveReviewSync(env.DB,await syncReviews(env,{gh:gh || github(env),decide:applyDecision,state:reviewState,sendersFor,...options}));
}

export async function handle(request, env, backend) {
  try {
    const path = new URL(request.url).pathname;
    // Report only the failed requirement, never a secret, its length or prefix.
    if (!env.DB) throw new HTTPError(503,'The administrator must configure the DB binding.');
    if (typeof env.ADMIN_TOKEN !== 'string' || env.ADMIN_TOKEN.trim().length < 32)
      throw new HTTPError(503,'The administrator must set ADMIN_TOKEN to a random secret of at least 32 characters.');
    if (typeof env.GITHUB_PRIVATE_KEY !== 'string' || !env.GITHUB_PRIVATE_KEY.trim())
      throw new HTTPError(503,'The administrator must configure the GITHUB_PRIVATE_KEY secret.');
    if (!/^\d+$/.test(env.GITHUB_APP_ID || '') || !/^\d+$/.test(env.GITHUB_INSTALLATION_ID || ''))
      throw new HTTPError(503,'The administrator must configure numeric GitHub App and installation IDs.');
    if (path === '/health' && request.method === 'GET') {
      await env.DB.prepare('SELECT id FROM devices LIMIT 1').first();
      return json({status:'ok'}); // Configuration/schema readiness, not a GitHub permission test.
    }
    if (path === '/admin/devices' && request.method === 'POST') {
      await admin(request,env);
      const data = await readJSON(request);
      if (typeof data?.label !== 'string' || !data.label.trim() || data.label.length > 80) throw new HTTPError(422,'A short device label is required.');
      const token = random(), id = crypto.randomUUID().replaceAll('-','');
      await env.DB.prepare("INSERT INTO devices(id,hash,label,active,source,created_at) VALUES(?,?,?,1,'admin',?)").bind(id,await hash(token),data.label,now()).run();
      return json({device_id:id,device_token:token});
    }
    if (/^\/admin\/devices\/[a-f0-9]{32}$/.test(path) && request.method === 'DELETE') {
      await admin(request,env);
      await env.DB.prepare('UPDATE devices SET active=0 WHERE id=?').bind(path.split('/').pop()).run();
      return json({revoked:true});
    }
    const toggle = path.match(/^\/admin\/devices\/([a-f0-9]{32})\/(block|unblock)$/);
    if (toggle && request.method === 'POST') {
      await admin(request,env);
      const result = await env.DB.prepare('UPDATE devices SET active=? WHERE id=?').bind(toggle[2]==='unblock'?1:0,toggle[1]).run();
      if (!(result.meta?.changes ?? result.changes)) throw new HTTPError(404,'Device not found.');
      return json({device_id:toggle[1],active:toggle[2]==='unblock'});
    }
    // The page and its assets hold no data or secrets; the browser fetches the overview with the admin token.
    if (path === '/admin' && request.method === 'GET') return page(DASHBOARD_HTML,'text/html; charset=utf-8');
    if (path === '/admin/app.js' && request.method === 'GET') return page(DASHBOARD_JS,'text/javascript; charset=utf-8');
    if (path === '/admin/app.css' && request.method === 'GET') return page(DASHBOARD_CSS,'text/css; charset=utf-8');
    if (path === '/admin/api/overview' && request.method === 'GET') {
      await admin(request,env);
      const today = now();
      await env.DB.prepare('DELETE FROM usage WHERE day<?').bind(isoDay(today-180*DAY)).run();
      const devices = (await env.DB.prepare(`SELECT id,label,active,source,person_name,email,pc_name,windows_user,connector_version,
        terms_version,created_at,enroll_ip,last_seen,last_ip FROM devices ORDER BY last_seen DESC`).all()).results;
      const usage = (await env.DB.prepare(`SELECT device,kind,name,
        SUM(CASE WHEN day>=? THEN count ELSE 0 END) AS last7,SUM(count) AS last30,MAX(day) AS last_day
        FROM usage WHERE day>=? GROUP BY device,kind,name ORDER BY last30 DESC`).bind(isoDay(today-6*DAY),isoDay(today-29*DAY)).all()).results;
      const submissions = (await env.DB.prepare('SELECT device,digest,at,skills,status FROM submission_log ORDER BY at DESC LIMIT 200').all()).results
        .map(row => ({...row,skills:JSON.parse(row.skills)}));
      // Before migration 0005 is applied the table is missing; the overview still loads.
      const notion_sync = await lastSync(env.DB).catch(()=>null);
      const notion_review_sync = await lastReviewSync(env.DB).catch(()=>null);
      return json({generated_at:today,devices,usage,submissions,notion_sync,notion_review_sync});
    }
    if (path === '/admin/api/notion-review' && request.method === 'POST') {
      await admin(request,env);
      const summary = await runReviewSync(env,{gh:backend});
      return json(summary,summary.error ? 502 : 200);
    }
    if (path === '/admin/api/notion-sync' && request.method === 'POST') {
      await admin(request,env);
      const summary = await saveSync(env.DB,await syncToNotion(env));
      return json(summary,summary.error ? 502 : 200);
    }
    if (path === '/v1/enroll' && request.method === 'POST') {
      const ip = clientIP(request) || 'unknown';
      // An office shares one public address, so successful joins get a loose limit
      // while wrong codes are cut off after 10 an hour, before the code is even compared.
      const failures = await env.DB.prepare('SELECT hour,count FROM limits WHERE key=?').bind('joinfail:'+ip).first();
      if (failures && failures.hour === Math.floor(now()/3600) && failures.count >= 10) throw new HTTPError(429,'Too many attempts; retry later.');
      await limit(env.DB,'join:'+ip,60);
      if (typeof env.JOIN_CODE !== 'string' || env.JOIN_CODE.trim().length < 32) throw new HTTPError(503,'Team joining is not configured.');
      if (!await secretMatches(request,env.JOIN_CODE)) {
        await limit(env.DB,'joinfail:'+ip,Infinity);
        throw new HTTPError(403,'The team join code is not valid. Ask your administrator for the current installer.');
      }
      let profile;
      try { profile = validateProfile(await readJSON(request)); }
      catch (error) { throw error instanceof HTTPError ? error : new HTTPError(422,error.message); }
      const token = random(), id = crypto.randomUUID().replaceAll('-','');
      await env.DB.prepare(`INSERT INTO devices(id,hash,label,active,source,person_name,email,pc_name,windows_user,connector_version,terms_version,created_at,enroll_ip,last_seen,last_ip)
        VALUES(?,?,?,1,'join',?,?,?,?,?,?,?,?,?,?)`)
        .bind(id,await hash(token),`${profile.name} (${profile.pc_name})`.slice(0,80),profile.name,profile.email,profile.pc_name,profile.windows_user,
          profile.connector_version,profile.terms_version,now(),clientIP(request),now(),clientIP(request)).run();
      return json({device_id:id,device_token:token});
    }
    if (path === '/v1/usage' && request.method === 'POST') {
      // Usage has its own budget so it never delays library downloads or submissions.
      const id = await device(request,env.DB,false);
      await limit(env.DB,'usage:'+id,30);
      let events;
      try { events = validateUsage(await readJSON(request),isoDay(now())); }
      catch (error) { throw error instanceof HTTPError ? error : new HTTPError(422,error.message); }
      await env.DB.batch(events.map(e => env.DB.prepare(`INSERT INTO usage(device,kind,name,day,count) VALUES(?,?,?,?,?)
        ON CONFLICT(device,kind,name,day) DO UPDATE SET count=usage.count+excluded.count`).bind(id,e.kind,e.name,e.day,e.count)));
      return json({accepted:events.length});
    }
    if (path === '/admin/status' && request.method === 'GET') {
      await admin(request,env);
      try {
        const library = await (backend || github(env)).library();
        return json({status:'ok',approved_skill_count:Object.keys(library.skills).length,commit:library.commit});
      } catch (error) { throw new HTTPError(502,safeGitHubDetail(error)); }
    }
    if (path === '/v1/library' && request.method === 'GET') {
      await device(request,env.DB);
      try {
        const library = await (backend || github(env)).library();
        // Older connectors ignore "category"; newer ones use it to group skills.
        return json({commit:library.commit,skills:Object.entries(library.skills).map(([name,files])=>({name,category:library.categories?.[name] ?? null,files}))});
      } catch (error) { throw new HTTPError(502,safeGitHubDetail(error)); }
    }
    if (path === '/v1/submissions' && request.method === 'POST') {
      const id = await device(request,env.DB);
      const data = await readJSON(request);
      let skills;
      try { skills = validateSkills(data); }
      catch { throw new HTTPError(422,'Invalid or flagged skill content. Review the local candidates.'); }
      const digest = await hash(canonical(skills));
      const record = status => env.DB.prepare('INSERT INTO submission_log(device,digest,at,skills,status) VALUES(?,?,?,?,?)')
        .bind(id,digest,now(),JSON.stringify(Object.keys(skills)),status).run();
      const saved = await env.DB.prepare('SELECT url FROM batches WHERE digest=?').bind(digest).first();
      if (saved?.url) {
        const status = saved.url==='already_approved'?'already_approved':'already_submitted';
        await record(status);
        return json({status,pull_request:saved.url,digest});
      }
      const owner = random();
      const claimed = await env.DB.prepare(`INSERT INTO batches(digest,url,lease_owner,lease_until) VALUES(?,NULL,?,?)
        ON CONFLICT(digest) DO UPDATE SET lease_owner=excluded.lease_owner,lease_until=excluded.lease_until
        WHERE batches.url IS NULL AND batches.lease_until < ? RETURNING digest`).bind(digest,owner,now()+180,now()).first();
      if (!claimed) throw new HTTPError(409,'This batch is processing. Retry later.');
      try {
        const url = await (backend || github(env)).submit(skills,digest);
        if (url !== 'already_approved' && !new RegExp('^https://github\\.com/'+env.GITHUB_REPOSITORY.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'/pull/\\d+$').test(url)) throw new Error('Invalid review URL.');
        await env.DB.prepare('UPDATE batches SET url=?,lease_until=0,lease_owner=NULL WHERE digest=? AND lease_owner=?').bind(url,digest,owner).run();
        const status = url==='already_approved'?'already_approved':'submitted_for_approval';
        await record(status);
        return json({status,pull_request:url,digest});
      } catch {
        await env.DB.prepare('UPDATE batches SET lease_until=0,lease_owner=NULL WHERE digest=? AND lease_owner=?').bind(digest,owner).run();
        throw new HTTPError(502,'GitHub submission failed. Retry later; no approval was recorded.');
      }
    }
    // Owner review of uploaded skills. Approving writes one skill to main; nothing else does.
    if (path === '/admin/api/reviews' && request.method === 'GET') {
      await admin(request,env);
      let queue;
      try { queue = await (backend || github(env)).reviewQueue(); }
      catch (error) { throw new HTTPError(502,safeGitHubDetail(error)); }
      const known = await reviewState(env.DB);
      const senders = await sendersFor(env.DB,queue.prs.map(pr=>pr.url));
      const prs = queue.prs.map(pr=>({...pr,sender:senders[pr.url] ?? null,undecided:undecided(queue.items,pr.number,known.decisions,known.rejected)}));
      return json({generated_at:now(),library_commit:queue.library_commit,more:queue.more,categories_available:[...CATEGORIES].filter(c=>c!=='uncategorized'),
        prs,...groupReviews(queue.items,{...known,senders})});
    }
    if (path === '/admin/api/reviews/decide' && request.method === 'POST') {
      await admin(request,env);
      return json(await applyDecision(env,backend || github(env),await readJSON(request)));
    }
    if (path === '/admin/api/reviews/close' && request.method === 'POST') {
      await admin(request,env);
      const pr = (await readJSON(request))?.pr;
      if (!Number.isInteger(pr) || pr < 1) throw new HTTPError(422,'Invalid pull request number.');
      const gh = backend || github(env);
      try {
        const current = await gh.reviewOne(pr);
        if (!current) throw new HTTPError(409,'That pull request is not an open skill upload.');
        if (!await closeWhenDecided(env.DB,gh,pr,current.items)) throw new HTTPError(409,'Approve or reject every skill in this upload first.');
      } catch (error) { throw error instanceof HTTPError ? error : new HTTPError(502,safeGitHubDetail(error)); }
      return json({pr,closed:true});
    }
    throw new HTTPError(404,'Not found.');
  } catch (error) {
    // Never log bodies, tokens, PEMs, or upstream error bodies.
    return json({detail:error instanceof HTTPError ? error.message : 'Service unavailable. Retry later.'},error instanceof HTTPError ? error.status : 503);
  }
}
export default {
  fetch(request,env) { return handle(request,env); },
  // Hourly cron (wrangler.jsonc): copy the team summaries to Notion and keep the result for the dashboard.
  // A second cron (minute 47) handles skill review, so each run has its own subrequest budget.
  scheduled(event,env,ctx) {
    if (event.cron === REVIEW_CRON) ctx.waitUntil(runReviewSync(env));
    else ctx.waitUntil(syncToNotion(env).then(summary=>saveSync(env.DB,summary)));
  }
};
