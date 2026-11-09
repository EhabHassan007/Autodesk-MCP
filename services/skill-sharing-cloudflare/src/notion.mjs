// Hourly copy of team members and skill/tool usage into two Notion databases.
// The Worker stays the source of truth; Notion is only a view. Rows are matched by
// "Device ID" / "Key", only rows that differ are written, and nothing is deleted.
const API = 'https://api.notion.com/v1';
const DAY = 86400;
const TEXT_MAX = 2000;   // Notion's limit for one text value.
const BUDGET = 48;       // Workers Free allows 50 subrequests per invocation; keep a margin.
const isoDay = seconds => new Date(seconds*1000).toISOString().slice(0,10);
const isoTime = seconds => seconds ? new Date(seconds*1000).toISOString() : null;
const text = v => String(v ?? '').trim().slice(0,TEXT_MAX).trim();

class NotionError extends Error {
  constructor(status) { super('Notion HTTP '+status); this.status = status; }
}

// Write format for each property type.
function toProp(type, v) {
  if (type === 'title' || type === 'rich_text') { const s = text(v); return {[type]:s ? [{text:{content:s}}] : []}; }
  if (type === 'email') return {email:text(v) || null};
  if (type === 'select') return {select:{name:v}};
  if (type === 'date') return {date:v ? {start:v} : null};
  return {number:v};
}
// Plain value read back from a Notion property.
function fromProp(type, p) {
  if (!p) return null;
  if (type === 'title' || type === 'rich_text') return (p[type] || []).map(t=>t.plain_text ?? t.text?.content ?? '').join('');
  if (type === 'email') return p.email;
  if (type === 'select') return p.select?.name;
  if (type === 'date') return p.date?.start;
  return p.number;
}
// Comparable form: trimmed text, lowercase email, dates exact or to the minute (UTC), numbers.
function norm(type, v) {
  if (type === 'title' || type === 'rich_text' || type === 'select') return text(v);
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

async function desiredRows(db, today) {
  const since = isoDay(today-29*DAY);
  const devices = (await db.prepare(`SELECT id,label,active,person_name,email,pc_name,windows_user,connector_version,terms_version,created_at,last_seen
    FROM devices ORDER BY created_at,id`).all()).results;
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
  const members = devices.map(d => {
    const s = stats[d.id] ?? {skill:0,tool:0,top:[]};
    return {key:d.id,values:{Name:d.person_name || d.label,Email:d.email,PC:d.pc_name,'Windows user':d.windows_user,Version:d.connector_version,
      Status:d.active === 1 ? 'Active' : 'Blocked',Joined:isoTime(d.created_at),'Last seen':isoTime(d.last_seen),
      'Skill uses (30 days)':s.skill,'Tool uses (30 days)':s.tool,'Top skills':s.top.join(', '),'Terms version':d.terms_version,'Device ID':d.id}};
  });
  const usage = perName.map(r => {
    const key = `${r.kind}:${r.name}`;
    return {key,values:{Name:r.name,Kind:r.kind === 'tool' ? 'Tool' : 'Skill','Uses (30 days)':r.uses,'People (30 days)':r.people,'Last used':r.last_day,Key:key}};
  });
  return {members,usage};
}

// Rows to create or update for one data source, comparing with what Notion holds.
function plan(schema, keyProp, desired, pages, zeroed) {
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
    writes.push({page:page.id,properties:Object.fromEntries(changed.map(n=>[n,toProp(schema[n],values[n])]))});
  };
  for (const row of desired) {
    const page = existing.get(row.key);
    existing.delete(row.key);
    if (page) diff(page,row.values);
    else writes.push({properties:Object.fromEntries(Object.entries(row.values).map(([n,v])=>[n,toProp(schema[n],v)]))});
  }
  // Rows Notion still has with no recent use: zero the counts, keep "Last used".
  for (const [key,page] of existing) if (zeroed?.test(key)) diff(page,zeroed.values);
  return {writes,unchanged};
}

export async function syncToNotion(env, {fetcher = (...args) => fetch(...args), maxWrites = 40, sleep = ms => new Promise(r=>setTimeout(r,ms))} = {}) {
  const at = Math.floor(Date.now()/1000);
  if (!env.NOTION_TOKEN || !env.NOTION_MEMBERS_SOURCE || !env.NOTION_USAGE_SOURCE) return {skipped:'not configured',at};
  const summary = {members:{created:0,updated:0,unchanged:0},usage:{created:0,updated:0,unchanged:0},pending:0,at};
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
  let queue = [];
  try {
    const desired = await desiredRows(env.DB,at);
    const members = plan(MEMBER,'Device ID',desired.members,await readAll(env.NOTION_MEMBERS_SOURCE));
    const usage = plan(USAGE,'Key',desired.usage,await readAll(env.NOTION_USAGE_SOURCE),
      {test:key => /^(skill|tool):/.test(key),values:{'Uses (30 days)':0,'People (30 days)':0}});
    summary.members.unchanged = members.unchanged;
    summary.usage.unchanged = usage.unchanged;
    queue = [...members.writes.map(w=>({...w,part:'members',source:env.NOTION_MEMBERS_SOURCE})),
      ...usage.writes.map(w=>({...w,part:'usage',source:env.NOTION_USAGE_SOURCE}))];
    let writes = 0;
    while (queue.length && writes < maxWrites && calls < BUDGET) {
      const w = queue[0];
      if (w.page) await call('PATCH',`/pages/${encodeURIComponent(w.page)}`,{properties:w.properties});
      else await call('POST','/pages',{parent:{type:'data_source_id',data_source_id:w.source},properties:w.properties});
      queue.shift();
      writes++;
      summary[w.part][w.page ? 'updated' : 'created']++;
    }
    summary.pending = queue.length;
    return summary;
  } catch (error) {
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
