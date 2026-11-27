// Connector error reports. Each enrolled PC sends what failed right after it fails (POST /v1/failures): the tool, the
// product, the error code, a cleaned message, and later whether the same tool then worked ("recovered"). The same
// error from any PC is one row, keyed by a fingerprint, and an hourly cron copies the last 30 days to the Notion
// "Connector failures" database, where the owner (or a scheduled Claude check) reads it and plans the correction.
import { hash } from './validation.mjs';
import { NotionError, notionClient, plan, text, toProp } from './notion.mjs';

const DAY = 86400;
const isoDay = seconds => new Date(seconds*1000).toISOString().slice(0,10);
export const MESSAGE_MAX = 240;
export const MAX_FAILURE_EVENTS = 100;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exactKeys = (value, keys) => object(value) && Object.keys(value).sort().join(',') === [...keys].sort().join(',');
const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');

// The same rules, in the same order, as Failures.Clean in the connector (ConnectorFailures.cs), applied again here so
// an older or altered client cannot store more. `names` are the sending device's Windows user, PC and person names.
export function cleanMessage(message, {user, pc, person} = {}) {
  let t = String(message ?? '').replace(/\r/g,'').split('\n').map(l=>l.trim()).filter(Boolean).slice(0,2).join(' | ');
  if (t.length > 1000) t = t.slice(0,1000);
  t = t.replace(/https?:\/\/\S+/gi,'<url>');
  t = t.replace(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g,'<email>');
  t = t.replace(/\\\\(?:[^\\/\n"'<>|]*[\\/])*[^\s\\/"'<>|]*/g,'<path>');
  t = t.replace(/(?<![A-Za-z])[A-Za-z]:[\\/](?:[^\\/\n"'<>|]*[\\/])*[^\s\\/"'<>|]*/g,'<path>');
  t = t.replace(/"[^"\n]{0,300}"|“[^”\n]{0,300}”|‘[^’\n]{0,300}’|(?<![A-Za-z])'[^'\n]{0,300}'(?![A-Za-z])/g,'<text>');
  t = t.replace(/[^\s<>"'/\\|]+\.(?:dwg|dxf|dwt|rvt|rfa|rte|rft|ifc|nwc|nwd|max|fbx|obj|3ds|skp|pdf|xlsx?|docx?|csv|txt|json|png|jpe?g)\b/gi,'<file>');
  t = t.replace(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b|\b[0-9a-fA-F]{16,}\b/g,'<id>');
  if (user && user.trim().length >= 3) t = t.replace(new RegExp(escape(user.trim()),'gi'),'<user>');
  if (pc && pc.trim().length >= 3) t = t.replace(new RegExp(escape(pc.trim()),'gi'),'<pc>');
  // The service also knows the person's name: the full name and each part of three letters or more.
  for (const part of [person, ...String(person ?? '').split(/\s+/)].filter(p=>p && p.trim().length >= 3).sort((a,b)=>b.length-a.length))
    t = t.replace(new RegExp(`(?<![\\p{L}\\p{N}])${escape(part.trim())}(?![\\p{L}\\p{N}])`,'giu'),'<user>');
  t = t.replace(/(?<=: )(?![a-z_][a-z0-9_]*(?:$|[.,;]))[^\s:<>,;]+?(?=$|[.,;](?:\s|$))/g,'<value>');
  t = t.replace(/(?<![A-Za-z0-9])\d+(?:[.,]\d+)*/g,'<n>');
  t = t.replace(/\s+/g,' ').trim();
  return t.length > MESSAGE_MAX ? t.slice(0,MESSAGE_MAX).trimEnd()+'...' : t;
}

// Error reports arrive counted per day; nothing else is accepted.
export function validateFailures(data, today) {
  if (!exactKeys(data,['events']) || !Array.isArray(data.events) || !data.events.length || data.events.length > MAX_FAILURE_EVENTS)
    throw new Error(`Send 1 to ${MAX_FAILURE_EVENTS} error reports.`);
  const earliest = new Date(Date.parse(today) - 31*DAY*1000).toISOString().slice(0,10);
  const tomorrow = new Date(Date.parse(today) + DAY*1000).toISOString().slice(0,10);
  return data.events.map(event => {
    if (!exactKeys(event,['tool','product','code','message','outcome','day','count'])) throw new Error('Invalid error report.');
    const {tool, product, code, message, outcome, day, count} = event;
    if (typeof tool !== 'string' || !/^[A-Za-z0-9_.:-]{1,100}$/.test(tool) || !['revit','autocad','3dsmax','connector'].includes(product)
      || typeof code !== 'string' || !/^[a-z_]{1,40}$/.test(code) || !['failed','recovered'].includes(outcome)
      || typeof message !== 'string' || !message.isWellFormed() || message.length > 300 || /[\x00-\x1f\x7f]/.test(message))
      throw new Error('Invalid error report.');
    if (typeof day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(day) || Number.isNaN(Date.parse(day)) || day < earliest || day > tomorrow) throw new Error('Error report day out of range.');
    if (!Number.isInteger(count) || count < 1 || count > 10000) throw new Error('Invalid error report count.');
    return {tool, product, code, message, outcome, day, count};
  });
}

// One fingerprint per distinct error: the same tool, product, code and cleaned message from any PC.
export const fingerprint = async e => (await hash([e.product,e.tool,e.code,e.message].join('\n'))).slice(0,16);

export async function recordFailures(db, device, version, events, now) {
  const who = await db.prepare('SELECT person_name,pc_name,windows_user FROM devices WHERE id=?').bind(device).first() ?? {};
  const statements = [];
  for (const e of events) {
    const clean = {...e,message:cleanMessage(e.message,{user:who.windows_user,pc:who.pc_name,person:who.person_name})};
    const key = await fingerprint(clean);
    statements.push(db.prepare(`INSERT INTO failures(fingerprint,product,tool,code,message,created_at) VALUES(?,?,?,?,?,?)
      ON CONFLICT(fingerprint) DO NOTHING`).bind(key,clean.product,clean.tool,clean.code,clean.message,now));
    const failed = e.outcome === 'failed' ? e.count : 0, recovered = e.outcome === 'recovered' ? e.count : 0;
    statements.push(db.prepare(`INSERT INTO failure_counts(fingerprint,device,day,version,failed,recovered) VALUES(?,?,?,?,?,?)
      ON CONFLICT(fingerprint,device,day,version) DO UPDATE SET failed=failure_counts.failed+excluded.failed,
      recovered=failure_counts.recovered+excluded.recovered`).bind(key,device,e.day,version,failed,recovered));
  }
  await db.batch(statements);
  return events.length;
}

// Errors of the last 30 days, one entry per fingerprint, newest first: for the dashboard overview and Notion.
export async function recentFailures(db, today) {
  await db.prepare('DELETE FROM failure_counts WHERE day<?').bind(isoDay(today-180*DAY)).run();
  const since = isoDay(today-29*DAY);
  const rows = (await db.prepare(`SELECT f.fingerprint,f.product,f.tool,f.code,f.message,SUM(c.failed) AS failed,SUM(c.recovered) AS recovered,
    COUNT(DISTINCT CASE WHEN c.failed>0 THEN c.device END) AS people,MAX(CASE WHEN c.failed>0 THEN c.day END) AS last_day
    FROM failures f JOIN failure_counts c ON c.fingerprint=f.fingerprint WHERE c.day>=?
    GROUP BY f.fingerprint HAVING SUM(c.failed)>0 ORDER BY last_day DESC,failed DESC,f.fingerprint`).bind(since).all()).results;
  const first = Object.fromEntries((await db.prepare(`SELECT fingerprint,MIN(day) AS day FROM failure_counts WHERE failed>0 GROUP BY fingerprint`)
    .all()).results.map(r=>[r.fingerprint,r.day]));
  const who = {}, versions = {};
  for (const r of (await db.prepare(`SELECT DISTINCT c.fingerprint,COALESCE(d.person_name,d.label) AS name FROM failure_counts c
    JOIN devices d ON d.id=c.device WHERE c.day>=? AND c.failed>0 ORDER BY name`).bind(since).all()).results) (who[r.fingerprint] ??= []).push(r.name);
  for (const r of (await db.prepare(`SELECT DISTINCT fingerprint,version FROM failure_counts WHERE day>=? AND failed>0 ORDER BY version`)
    .bind(since).all()).results) (versions[r.fingerprint] ??= []).push(r.version);
  return rows.map(r=>({...r,first_day:first[r.fingerprint] ?? r.last_day,who:who[r.fingerprint] ?? [],versions:versions[r.fingerprint] ?? []}));
}

const FAILURE = {Name:'title',Product:'select',Tool:'rich_text','Error code':'rich_text',Message:'rich_text','Failures (30 days)':'number',
  'Recovered (30 days)':'number','People (30 days)':'number',Who:'rich_text',Versions:'rich_text','First seen':'date','Last seen':'date',Fingerprint:'rich_text'};
const PRODUCT = {revit:'Revit',autocad:'AutoCAD','3dsmax':'3ds Max',connector:'Connector'};

// Hourly copy into Notion. Only the columns above are written. "Status" is set to New when a row is created and is
// never changed by the service afterwards: it belongs to whoever plans the correction.
export async function syncFailures(env, {fetcher = (...args) => fetch(...args), maxWrites = 40, sleep = ms => new Promise(r=>setTimeout(r,ms))} = {}) {
  const at = Math.floor(Date.now()/1000);
  if (!env.NOTION_TOKEN || !env.NOTION_FAILURES_SOURCE) return {skipped:'not configured',at};
  const summary = {failures:{created:0,updated:0,unchanged:0},pending:0,at};
  const client = notionClient(env,{fetcher,sleep});
  let queue = [];
  try {
    const desired = (await recentFailures(env.DB,at)).map(f=>({key:f.fingerprint,values:{
      Name:text(`${f.tool}: ${f.message}`).slice(0,120),Product:PRODUCT[f.product],Tool:f.tool,'Error code':f.code,Message:f.message,
      'Failures (30 days)':f.failed,'Recovered (30 days)':f.recovered,'People (30 days)':f.people,Who:f.who.join(', '),
      Versions:f.versions.join(', '),'First seen':f.first_day,'Last seen':f.last_day,Fingerprint:f.fingerprint}}));
    const result = plan(FAILURE,'Fingerprint',desired,await client.readAll(env.NOTION_FAILURES_SOURCE),
      {test:key => /^[0-9a-f]{16}$/.test(key),values:{'Failures (30 days)':0,'Recovered (30 days)':0,'People (30 days)':0}});
    summary.failures.unchanged = result.unchanged;
    queue = result.writes.map(w => w.page ? w : {...w,properties:{...w.properties,Status:toProp('select','New')}});
    let writes = 0;
    while (queue.length && writes < maxWrites && client.calls < 48) {
      const w = queue[0];
      if (w.page) await client.call('PATCH',`/pages/${encodeURIComponent(w.page)}`,{properties:w.properties});
      else await client.call('POST','/pages',{parent:{type:'data_source_id',data_source_id:env.NOTION_FAILURES_SOURCE},properties:w.properties});
      queue.shift();
      writes++;
      summary.failures[w.page ? 'updated' : 'created']++;
    }
    summary.pending = queue.length;
    return summary;
  } catch (error) {
    // Only the status code is reported: never the token, request bodies or personal data.
    return {...summary,pending:queue.length,error:error instanceof NotionError ? error.message : 'Notion sync failed'};
  }
}

export async function saveFailureSync(db, summary) {
  await db.prepare(`INSERT INTO notion_failure_sync(id,at,summary) VALUES(1,?,?)
    ON CONFLICT(id) DO UPDATE SET at=excluded.at,summary=excluded.summary`).bind(summary.at,JSON.stringify(summary)).run();
  return summary;
}
export async function lastFailureSync(db) {
  const row = await db.prepare('SELECT summary FROM notion_failure_sync WHERE id=1').first();
  return row ? JSON.parse(row.summary) : null;
}
