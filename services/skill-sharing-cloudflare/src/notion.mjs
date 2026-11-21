// Hourly copy of team members and skill/tool usage into two Notion databases.
// The Worker stays the source of truth; Notion is a view, except Team members → Status, which a reviewer
// (NOTION_REVIEWERS) may set to Active or Blocked to approve/unblock or deny/block that PC. New PCs show as Pending,
// and the reviewers are @mentioned on the row when a PC joins. Rows are matched by
// "Device ID" / "Key", only rows that differ are written, and nothing is deleted.
const API = 'https://api.notion.com/v1';
const DAY = 86400;
const TEXT_MAX = 2000;   // Notion's limit for one text value.
const BUDGET = 48;       // Workers Free allows 50 subrequests per invocation; keep a margin.
const isoDay = seconds => new Date(seconds*1000).toISOString().slice(0,10);
const isoTime = seconds => seconds ? new Date(seconds*1000).toISOString() : null;
export const text = v => String(v ?? '').trim().slice(0,TEXT_MAX).trim();

export class NotionError extends Error {
  constructor(status) { super('Notion HTTP '+status); this.status = status; }
}

// Write format for each property type.
export function toProp(type, v) {
  if (type === 'title' || type === 'rich_text') { const s = text(v); return {[type]:s ? [{text:{content:s}}] : []}; }
  if (type === 'email') return {email:text(v) || null};
  if (type === 'select') return {select:v ? {name:v} : null};
  if (type === 'checkbox') return {checkbox:Boolean(v)};
  if (type === 'url') return {url:text(v) || null};
  if (type === 'date') return {date:v ? {start:v} : null};
  return {number:v};
}
// Plain value read back from a Notion property.
export function fromProp(type, p) {
  if (!p) return null;
  if (type === 'title' || type === 'rich_text') return (p[type] || []).map(t=>t.plain_text ?? t.text?.content ?? '').join('');
  if (type === 'email') return p.email;
  if (type === 'select') return p.select?.name;
  if (type === 'checkbox') return p.checkbox;
  if (type === 'url') return p.url;
  if (type === 'date') return p.date?.start;
  return p.number;
}
// Comparable form: trimmed text, lowercase email, dates exact or to the minute (UTC), numbers.
export function norm(type, v) {
  if (type === 'title' || type === 'rich_text' || type === 'select' || type === 'url') return text(v);
  if (type === 'checkbox') return Boolean(v);
  if (type === 'email') return text(v).toLowerCase();
  if (type === 'date') {
    if (!v) return '';
    if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return v;
    const t = new Date(v);
    return isNaN(t) ? String(v) : t.toISOString().slice(0,16);
  }
  return v == null || v === '' ? null : Number(v);
}

const MEMBER = {Name:'title',Email:'email',PC:'rich_text','Windows user':'rich_text',Version:'rich_text',Status:'select',Joined:'date',
  'Last seen':'date','Skill uses (30 days)':'number','Tool uses (30 days)':'number','Top skills':'rich_text','Terms version':'rich_text','Device ID':'rich_text'};
const USAGE = {Name:'title',Kind:'select','Uses (30 days)':'number','People (30 days)':'number','Last used':'date',Key:'rich_text'};

const DEVICE_COLUMNS = 'id,label,active,pending,person_name,email,pc_name,windows_user,connector_version,terms_version,created_at,last_seen';
// A PC that joined and waits for approval shows as Pending; approving sets Active, denying Blocked.
const statusOf = d => d.pending === 1 ? 'Pending' : d.active === 1 ? 'Active' : 'Blocked';
function memberRow(d, s = {skill:0,tool:0,top:[]}) {
  return {key:d.id,values:{Name:d.person_name || d.label,Email:d.email,PC:d.pc_name,'Windows user':d.windows_user,Version:d.connector_version,
    Status:statusOf(d),Joined:isoTime(d.created_at),'Last seen':isoTime(d.last_seen),
    'Skill uses (30 days)':s.skill,'Tool uses (30 days)':s.tool,'Top skills':s.top.join(', '),'Terms version':d.terms_version,'Device ID':d.id}};
}

async function desiredRows(db, today) {
  const since = isoDay(today-29*DAY);
  const devices = (await db.prepare(`SELECT ${DEVICE_COLUMNS} FROM devices ORDER BY created_at,id`).all()).results;
  const perDevice = (await db.prepare(`SELECT device,kind,name,SUM(count) AS uses FROM usage WHERE day>=?
    GROUP BY device,kind,name ORDER BY uses DESC,name`).bind(since).all()).results;
  const perName = (await db.prepare(`SELECT kind,name,SUM(count) AS uses,COUNT(DISTINCT device) AS people,MAX(day) AS last_day FROM usage
    WHERE day>=? AND kind IN ('skill','tool') GROUP BY kind,name ORDER BY kind,name`).bind(since).all()).results;
  const stats = {};
  for (const r of perDevice) {
    const s = stats[r.device] ??= {skill:0,tool:0,top:[]};
    if (r.kind in s) s[r.kind] += r.uses;
    if (r.kind === 'skill' && s.top.length < 3) s.top.push(`${r.name} (${r.uses})`);
  }
  const members = devices.map(d => memberRow(d,stats[d.id]));
  const usage = perName.map(r => {
    const key = `${r.kind}:${r.name}`;
    return {key,values:{Name:r.name,Kind:r.kind === 'tool' ? 'Tool' : 'Skill','Uses (30 days)':r.uses,'People (30 days)':r.people,'Last used':r.last_day,Key:key}};
  });
  return {members,usage};
}

// Rows to create or update for one data source, comparing with what Notion holds. Also used by failures.mjs.
export function plan(schema, keyProp, desired, pages, zeroed) {
  const existing = new Map();
  for (const page of pages) {
    if (page.archived || page.in_trash) continue;
    const key = text(fromProp('rich_text', page.properties?.[keyProp]));
    if (key && !existing.has(key)) existing.set(key, page);  // A duplicate key: the first row wins, the rest are left alone.
  }
  const writes = [];
  let unchanged = 0;
  const diff = (page, values) => {
    const changed = Object.keys(values).filter(n => norm(schema[n],values[n]) !== norm(schema[n],fromProp(schema[n],page.properties?.[n])));
    if (!changed.length) return unchanged++;
    writes.push({key:text(fromProp('rich_text',page.properties?.[keyProp])),page:page.id,properties:Object.fromEntries(changed.map(n=>[n,toProp(schema[n],values[n])]))});
  };
  for (const row of desired) {
    const page = existing.get(row.key);
    existing.delete(row.key);
    if (page) diff(page,row.values);
    else writes.push({key:row.key,properties:Object.fromEntries(Object.entries(row.values).map(([n,v])=>[n,toProp(schema[n],v)]))});
  }
  // Rows Notion still has with no recent use: zero the counts, keep "Last used".
  for (const [key,page] of existing) if (zeroed?.test(key)) diff(page,zeroed.values);
  return {writes,unchanged};
}

// One Notion API client: bearer token, API version, a single wait on 429, and a call counter for the subrequest budget.
export const BUDGET_CALLS = BUDGET;
export function notionClient(env, {fetcher = (...args) => fetch(...args), sleep = ms => new Promise(r=>setTimeout(r,ms))} = {}) {
  const headers = {Authorization:`Bearer ${env.NOTION_TOKEN}`,'Notion-Version':'2025-09-03','Content-Type':'application/json'};
  let calls = 0;
  const call = async (method, path, body) => {
    for (let retried = false;; retried = true) {
      calls++;
      const response = await fetcher(API+path,{method,headers,body:JSON.stringify(body)});
      if (response.status === 429 && !retried) {
        const after = Number(response.headers.get('Retry-After'));
        await sleep(Math.min(Number.isFinite(after) && after >= 0 ? after : 1, 5)*1000);
        continue;
      }
      if (!response.ok) throw new NotionError(response.status);
      return response.json();
    }
  };
  const readAll = async id => {
    const pages = [];
    let cursor;
    do {
      const data = await call('POST',`/data_sources/${encodeURIComponent(id)}/query`,{page_size:100,...(cursor ? {start_cursor:cursor} : {})});
      pages.push(...(data.results || []));
      cursor = data.has_more ? data.next_cursor : null;
    } while (cursor);
    return pages;
  };
  return {call,readAll,get calls() { return calls; }};
}

const reviewerIds = env => [...new Set(String(env.NOTION_REVIEWERS ?? '').split(',').map(v=>v.trim().toLowerCase()).filter(Boolean))];

// Status set by hand in Team members: Active approves or unblocks the PC, Blocked denies or blocks it. A change counts only when Notion's Status differs from
// the one the service last saw there (devices.notion_status) and the person who last edited the row is in
// NOTION_REVIEWERS, because everyone with edit access can change a row. Anyone else's change is put back by this run.
async function applyStatusEdits(db, env, pages, control) {
  const reviewers = new Set(reviewerIds(env));
  const devices = new Map((await db.prepare('SELECT id,notion_status FROM devices').all()).results.map(d=>[d.id,d]));
  const seen = new Set();
  for (const page of pages) {
    if (page.archived || page.in_trash) continue;
    const id = text(fromProp('rich_text',page.properties?.['Device ID']));
    if (!id || seen.has(id)) continue;  // Same rule as plan(): the first row with a Device ID is the one that counts.
    seen.add(id);
    const device = devices.get(id), status = text(fromProp('select',page.properties?.Status));
    if (!device?.notion_status || !['Active','Blocked'].includes(status) || status === device.notion_status) continue;
    const editor = String(page.last_edited_by?.id ?? '').toLowerCase();
    if (!reviewers.has(editor)) {
      control.refused++;
      if (editor && !control.editors.includes(editor) && control.editors.length < 5) control.editors.push(editor);
      continue;
    }
    await db.prepare('UPDATE devices SET active=?,pending=0,notion_status=? WHERE id=?').bind(status === 'Active' ? 1 : 0,status,id).run();
    control[status === 'Active' ? 'unblocked' : 'blocked']++;
  }
}

// The join notice: a comment on the member's row that @mentions every reviewer, so Notion alerts them
// (inbox, phone and email, per each person's Notion settings). Without reviewers the comment has no mention.
async function notify(db, env, call, pageId, d) {
  const mentions = reviewerIds(env).flatMap(id=>[{type:'mention',mention:{type:'user',user:{id}}},{type:'text',text:{content:' '}}]);
  const who = [d.person_name || d.label, d.pc_name && `(${d.pc_name})`, d.email].filter(Boolean).join(' ');
  await call('POST','/comments',{parent:{page_id:pageId},rich_text:[...mentions,{type:'text',text:{content:
    text(`New PC waiting for your approval: ${who}. Set Status to Active to approve, or Blocked to deny.`)}}]});
  await db.prepare('UPDATE devices SET notified_at=? WHERE id=?').bind(Math.floor(Date.now()/1000),d.id).run();
}

// Called right after a PC joins: its row and the reviewers' mention appear at once instead of at the next sync.
export async function announceJoin(env, deviceId, {fetcher = (...args) => fetch(...args), sleep = ms => new Promise(r=>setTimeout(r,ms))} = {}) {
  if (!env.NOTION_TOKEN || !env.NOTION_MEMBERS_SOURCE) return {skipped:'not configured'};
  const d = await env.DB.prepare(`SELECT ${DEVICE_COLUMNS} FROM devices WHERE id=?`).bind(deviceId).first();
  if (!d) return {skipped:'unknown device'};
  const {call} = notionClient(env,{fetcher,sleep});
  const row = memberRow(d);
  const page = await call('POST','/pages',{parent:{type:'data_source_id',data_source_id:env.NOTION_MEMBERS_SOURCE},
    properties:Object.fromEntries(Object.entries(row.values).map(([n,v])=>[n,toProp(MEMBER[n],v)]))});
  await env.DB.prepare('UPDATE devices SET notion_status=? WHERE id=?').bind(row.values.Status,deviceId).run();
  await notify(env.DB,env,call,page.id,d);
  return {created:true,notified:true};
}

// Every 10 minutes: only reads Team members and applies reviewers' Status changes, so an approval needs no hourly wait.
// Writes nothing to Notion; the hourly sync puts back changes made by others.
export async function applyApprovals(env, {fetcher = (...args) => fetch(...args), sleep = ms => new Promise(r=>setTimeout(r,ms))} = {}) {
  const at = Math.floor(Date.now()/1000);
  if (!env.NOTION_TOKEN || !env.NOTION_MEMBERS_SOURCE) return {skipped:'not configured',at};
  const control = {blocked:0,unblocked:0,refused:0,editors:[]};
  try {
    await applyStatusEdits(env.DB,env,await notionClient(env,{fetcher,sleep}).readAll(env.NOTION_MEMBERS_SOURCE),control);
    return {control,at};
  } catch (error) {
    return {control,at,error:error instanceof NotionError ? error.message : 'Notion approval check failed'};
  }
}

// Remembers the Status each member row now holds in Notion: written or already equal, not still pending.
async function recordStatus(db, members, pendingKeys) {
  for (const row of members) {
    if (pendingKeys.has(row.key)) continue;
    await db.prepare('UPDATE devices SET notion_status=? WHERE id=? AND notion_status IS NOT ?').bind(row.values.Status,row.key,row.values.Status).run();
  }
}

export async function syncToNotion(env, {fetcher = (...args) => fetch(...args), maxWrites = 40, sleep = ms => new Promise(r=>setTimeout(r,ms))} = {}) {
  const at = Math.floor(Date.now()/1000);
  if (!env.NOTION_TOKEN || !env.NOTION_MEMBERS_SOURCE || !env.NOTION_USAGE_SOURCE) return {skipped:'not configured',at};
  const summary = {members:{created:0,updated:0,unchanged:0},usage:{created:0,updated:0,unchanged:0},pending:0,
    control:{blocked:0,unblocked:0,refused:0,editors:[],notified:0},at};
  const client = notionClient(env,{fetcher,sleep});
  const {call,readAll} = client;
  let queue = [], desired = null, planned = false;
  const pageIds = new Map();  // Device ID → its Team members row, for join notices.
  const pendingMembers = () => new Set(queue.filter(w=>w.part === 'members').map(w=>w.key));
  try {
    const memberPages = await readAll(env.NOTION_MEMBERS_SOURCE);
    await applyStatusEdits(env.DB,env,memberPages,summary.control);
    for (const page of memberPages) {
      const key = text(fromProp('rich_text',page.properties?.['Device ID']));
      if (key && !page.archived && !page.in_trash && !pageIds.has(key)) pageIds.set(key,page.id);
    }
    desired = await desiredRows(env.DB,at);
    const members = plan(MEMBER,'Device ID',desired.members,memberPages);
    const usage = plan(USAGE,'Key',desired.usage,await readAll(env.NOTION_USAGE_SOURCE),
      {test:key => /^(skill|tool):/.test(key),values:{'Uses (30 days)':0,'People (30 days)':0}});
    summary.members.unchanged = members.unchanged;
    summary.usage.unchanged = usage.unchanged;
    queue = [...members.writes.map(w=>({...w,part:'members',source:env.NOTION_MEMBERS_SOURCE})),
      ...usage.writes.map(w=>({...w,part:'usage',source:env.NOTION_USAGE_SOURCE}))];
    planned = true;
    let writes = 0;
    while (queue.length && writes < maxWrites && client.calls < BUDGET) {
      const w = queue[0];
      if (w.page) await call('PATCH',`/pages/${encodeURIComponent(w.page)}`,{properties:w.properties});
      else {
        const created = await call('POST','/pages',{parent:{type:'data_source_id',data_source_id:w.source},properties:w.properties});
        if (w.part === 'members') pageIds.set(w.key,created.id);
      }
      queue.shift();
      writes++;
      summary[w.part][w.page ? 'updated' : 'created']++;
    }
    summary.pending = queue.length;
    await recordStatus(env.DB,desired.members,pendingMembers());
    // Join notices that could not be posted when the PC joined (Notion down, or before this version).
    const waiting = (await env.DB.prepare(`SELECT ${DEVICE_COLUMNS} FROM devices WHERE pending=1 AND notified_at IS NULL ORDER BY created_at`).all()).results;
    for (const d of waiting) {
      if (client.calls >= BUDGET) break;
      if (pageIds.has(d.id)) { await notify(env.DB,env,call,pageIds.get(d.id),d); summary.control.notified++; }
    }
    return summary;
  } catch (error) {
    // Rows written before the failure still count as seen; the failed row stays in the queue.
    if (planned) await recordStatus(env.DB,desired.members,pendingMembers()).catch(()=>{});
    // Only the status code is reported: never the token, request bodies or personal data.
    return {...summary,pending:queue.length,error:error instanceof NotionError ? error.message : 'Notion sync failed'};
  }
}

export async function saveSync(db, summary) {
  await db.prepare(`INSERT INTO notion_sync(id,at,summary) VALUES(1,?,?)
    ON CONFLICT(id) DO UPDATE SET at=excluded.at,summary=excluded.summary`).bind(summary.at,JSON.stringify(summary)).run();
  return summary;
}
export async function lastSync(db) {
  const row = await db.prepare('SELECT summary FROM notion_sync WHERE id=1').first();
  return row ? JSON.parse(row.summary) : null;
}
