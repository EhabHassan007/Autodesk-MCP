import { timingSafeEqual } from 'node:crypto';
import { GitHub } from './github.mjs';
import { bytes, canonical, hash, MAX_BODY, validateSkills } from './validation.mjs';

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
async function admin(request, env) {
  const actual = bytes(await hash(bearer(request)));
  const expected = bytes(await hash(env.ADMIN_TOKEN));
  if (!timingSafeEqual(actual, expected)) throw new HTTPError(403,'Administrator access required.');
}
async function device(request, db) {
  const row = await db.prepare('SELECT id FROM devices WHERE hash=? AND active=1').bind(await hash(bearer(request))).first();
  if (!row) throw new HTTPError(401,'Device credential invalid or revoked.');
  // One atomic SQLite statement prevents simultaneous requests bypassing the limit.
  const rate = await db.prepare(`INSERT INTO rate(device,hour,count) VALUES(?,?,1)
    ON CONFLICT(device) DO UPDATE SET hour=excluded.hour,
    count=CASE WHEN rate.hour=excluded.hour THEN rate.count+1 ELSE 1 END RETURNING count`)
    .bind(row.id,Math.floor(now()/3600)).first();
  if (rate.count > 20) throw new HTTPError(429,'Request limit reached; retry later.');
  return row.id;
}
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

// Cached token/library belongs to this binding configuration, never to another app.
let cachedGitHub, cachedEnv;
function github(env) {
  if (cachedEnv !== env) { cachedGitHub = new GitHub(env); cachedEnv = env; }
  return cachedGitHub;
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
      await env.DB.prepare('INSERT INTO devices(id,hash,label,active) VALUES(?,?,?,1)').bind(id,await hash(token),data.label).run();
      return json({device_id:id,device_token:token});
    }
    if (/^\/admin\/devices\/[a-f0-9]{32}$/.test(path) && request.method === 'DELETE') {
      await admin(request,env);
      await env.DB.prepare('UPDATE devices SET active=0 WHERE id=?').bind(path.split('/').pop()).run();
      return json({revoked:true});
    }
    if (path === '/admin/status' && request.method === 'GET') {
      await admin(request,env);
      try {
        const library = await (backend || github(env)).library();
        return json({status:'ok',approved_skill_count:Object.keys(library.skills).length,commit:library.commit});
      } catch { throw new HTTPError(502,'GitHub App access could not be verified.'); }
    }
    if (path === '/v1/library' && request.method === 'GET') {
      await device(request,env.DB);
      try {
        const library = await (backend || github(env)).library();
        return json({commit:library.commit,skills:Object.entries(library.skills).map(([name,files])=>({name,files}))});
      } catch { throw new HTTPError(502,'Approved library is temporarily unavailable.'); }
    }
    if (path === '/v1/submissions' && request.method === 'POST') {
      await device(request,env.DB);
      const data = await readJSON(request);
      let skills;
      try { skills = validateSkills(data); }
      catch { throw new HTTPError(422,'Invalid or flagged skill content. Review the local candidates.'); }
      const digest = await hash(canonical(skills));
      const saved = await env.DB.prepare('SELECT url FROM batches WHERE digest=?').bind(digest).first();
      if (saved?.url) return json({status:saved.url==='already_approved'?'already_approved':'already_submitted',pull_request:saved.url,digest});
      const owner = random();
      const claimed = await env.DB.prepare(`INSERT INTO batches(digest,url,lease_owner,lease_until) VALUES(?,NULL,?,?)
        ON CONFLICT(digest) DO UPDATE SET lease_owner=excluded.lease_owner,lease_until=excluded.lease_until
        WHERE batches.url IS NULL AND batches.lease_until < ? RETURNING digest`).bind(digest,owner,now()+180,now()).first();
      if (!claimed) throw new HTTPError(409,'This batch is processing. Retry later.');
      try {
        const url = await (backend || github(env)).submit(skills,digest);
        if (url !== 'already_approved' && !new RegExp('^https://github\\.com/'+env.GITHUB_REPOSITORY.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'/pull/\\d+$').test(url)) throw new Error('Invalid review URL.');
        await env.DB.prepare('UPDATE batches SET url=?,lease_until=0,lease_owner=NULL WHERE digest=? AND lease_owner=?').bind(url,digest,owner).run();
        return json({status:url==='already_approved'?'already_approved':'submitted_for_approval',pull_request:url,digest});
      } catch {
        await env.DB.prepare('UPDATE batches SET lease_until=0,lease_owner=NULL WHERE digest=? AND lease_owner=?').bind(digest,owner).run();
        throw new HTTPError(502,'GitHub submission failed. Retry later; no approval was recorded.');
      }
    }
    throw new HTTPError(404,'Not found.');
  } catch (error) {
    // Never log bodies, tokens, PEMs, or upstream error bodies.
    return json({detail:error instanceof HTTPError ? error.message : 'Service unavailable. Retry later.'},error instanceof HTTPError ? error.status : 503);
  }
}
export default {fetch(request,env) { return handle(request,env); }};
