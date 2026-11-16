// Connector error reports: cleaning (shared examples with the connector), the /v1/failures endpoint, the overview,
// and the hourly copy to the Notion "Connector failures" database against an in-memory fake of the Notion API.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import worker, { handle } from '../src/index.mjs';
import { cleanMessage, fingerprint, syncFailures } from '../src/failures.mjs';

const admin = 'test-only-admin-token-at-least-32-characters';
const notionToken = 'test-only-notion-integration-value';
const FAILURES = 'failures-source';
const today = new Date().toISOString().slice(0,10);
const day = ago => new Date(Date.now()-ago*86400000).toISOString().slice(0,10);

function setup(t, extra = {}) {
  const sqlite = new DatabaseSync(':memory:');
  for (const file of readdirSync(new URL('../migrations/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())
    sqlite.exec(readFileSync(new URL('../migrations/'+file,import.meta.url),'utf8'));
  t.after(()=>sqlite.close());
  const DB = {prepare(sql) {
    const stmt = sqlite.prepare(sql);
    const wrapper = params => ({bind(...values) { return wrapper(values); },async first() { return stmt.get(...params) || null; },
      async run() { return stmt.run(...params); },async all() { return {results:stmt.all(...params)}; }});
    return wrapper([]);
  },async batch(statements) { sqlite.exec('BEGIN'); try { const out=[]; for (const s of statements) out.push(await s.run()); sqlite.exec('COMMIT'); return out; } catch (e) { sqlite.exec('ROLLBACK'); throw e; } }};
  const env = {DB,ADMIN_TOKEN:admin,GITHUB_PRIVATE_KEY:'fake-test-key',GITHUB_APP_ID:'1',GITHUB_INSTALLATION_ID:'2',GITHUB_REPOSITORY:'owner/repo',
    NOTION_TOKEN:notionToken,NOTION_FAILURES_SOURCE:FAILURES,...extra};
  const request = (path,method='GET',token,content,headers={}) => handle(new Request('https://test.local'+path,{method,
    headers:{...(token?{Authorization:'Bearer '+token}:{}),...headers},body:content===undefined?undefined:JSON.stringify(content)}),env);
  const enroll = async (person, pc, user) => {
    const d = await (await request('/admin/devices','POST',admin,{label:pc})).json();
    sqlite.prepare('UPDATE devices SET person_name=?,pc_name=?,windows_user=? WHERE id=?').run(person,pc,user,d.device_id);
    return d;
  };
  return {sqlite,env,request,enroll};
}

const event = (o = {}) => ({tool:'execute_csharp',product:'revit',code:'compile_error',
  message:'C# compilation failed (your code did not run and nothing was changed): | Line <n>: The name <text> does not exist in the current context (CS0103)',
  outcome:'failed',day:today,count:1,...o});

test('the service cleans messages exactly as the connector does (shared examples)',()=>{
  const examples = JSON.parse(readFileSync(new URL('./error-messages.json',import.meta.url),'utf8'));
  assert.ok(examples.length >= 10);
  for (const e of examples) assert.equal(cleanMessage(e.message,{user:e.windows_user,pc:e.pc_name}),e.cleaned,e.message);
  // Cleaning twice changes nothing, so a message the connector already cleaned keeps its fingerprint.
  for (const e of examples) assert.equal(cleanMessage(e.cleaned,{user:e.windows_user,pc:e.pc_name}),e.cleaned);
  // The service also knows the sender's name; only whole words are replaced.
  assert.equal(cleanMessage('Ahmed Ali has no access to the Alignment view',{person:'Ahmed Ali'}),'<user> has no access to the Alignment view');
  assert.equal(cleanMessage('x'.repeat(400)).length,243);
});

test('error reports need a device, are validated, and have their own budget',async t=>{
  const s = setup(t);
  const d = await s.enroll('Ahmed Ali','DESK-07','ahmed');
  assert.equal((await s.request('/v1/failures','POST',undefined,{events:[event()]})).status,401);
  assert.equal((await s.request('/v1/failures','POST','not-a-device',{events:[event()]})).status,401);
  for (const bad of [{events:[]},{events:[event({extra:1})]},{events:[event({product:'max'})]},{events:[event({outcome:'fixed'})]},
    {events:[event({code:'Bad Code'})]},{events:[event({day:'2000-01-01'})]},{events:[event({count:0})]},{events:[event({message:'a\u0000b'})]},
    {events:[event({message:'x'.repeat(301)})]},{events:Array.from({length:101},()=>event())},{other:[]}])
    assert.equal((await s.request('/v1/failures','POST',d.device_token,bad)).status,422,JSON.stringify(bad).slice(0,80));
  // 60 requests an hour per PC (rejected ones count too), separate from the library/submission budget.
  const e = await s.enroll('Sara Noor','DESK-09','sara');
  for (let i=0;i<60;i++) assert.equal((await s.request('/v1/failures','POST',e.device_token,{events:[event()]})).status,200);
  assert.equal((await s.request('/v1/failures','POST',e.device_token,{events:[event()]})).status,429);
  // The library/submission budget is untouched.
  assert.equal(s.sqlite.prepare('SELECT COUNT(*) AS n FROM rate').get().n,0);
});

test('the same error from two PCs is one row; counts are kept per PC, day and version',async t=>{
  const s = setup(t);
  const a = await s.enroll('Ahmed Ali','DESK-07','ahmed'), b = await s.enroll('Sara Noor','DESK-09','sara');
  let r = await s.request('/v1/failures','POST',a.device_token,{events:[event({count:3}),event({outcome:'recovered',count:2})]},{'X-Connector-Version':'1.2.0'});
  assert.equal(r.status,200);
  assert.deepEqual(await r.json(),{accepted:2});
  // An older client that sent a raw message: the service cleans it, including this PC's own names, before keying it.
  await s.request('/v1/failures','POST',b.device_token,{events:[event({tool:'drawing_info',product:'autocad',code:'error',
    message:'Could not open C:\\Users\\sara\\Desktop\\Tower.dwg on DESK-09 for Sara'})]},{'X-Connector-Version':'1.1.0'});
  await s.request('/v1/failures','POST',b.device_token,{events:[event()]},{'X-Connector-Version':'1.1.0'});
  const rows = s.sqlite.prepare('SELECT * FROM failures ORDER BY tool').all();
  assert.equal(rows.length,2);
  assert.equal(rows[0].message,'Could not open <path> on <pc> for <user>');
  assert.ok(!JSON.stringify(rows).match(/sara|DESK-09|Tower/i));
  const compile = rows.find(x=>x.tool==='execute_csharp');
  assert.equal(compile.fingerprint,await fingerprint(event()));
  const counts = s.sqlite.prepare('SELECT device,version,failed,recovered FROM failure_counts WHERE fingerprint=? ORDER BY version').all(compile.fingerprint);
  assert.deepEqual(counts.map(c=>[c.version,c.failed,c.recovered]),[['1.1.0',1,0],['1.2.0',3,2]]);
  // Same report again adds up.
  await s.request('/v1/failures','POST',a.device_token,{events:[event()]},{'X-Connector-Version':'1.2.0'});
  assert.equal(s.sqlite.prepare("SELECT failed FROM failure_counts WHERE version='1.2.0'").get().failed,4);
  // A bad version header is stored as unknown.
  await s.request('/v1/failures','POST',a.device_token,{events:[event()]},{'X-Connector-Version':'bad version!'});
  assert.equal(s.sqlite.prepare("SELECT COUNT(*) AS n FROM failure_counts WHERE version='unknown'").get().n,1);

  const overview = await (await s.request('/admin/api/overview','GET',admin)).json();
  const listed = overview.failures.find(f=>f.fingerprint===compile.fingerprint);
  assert.equal(listed.failed,6);
  assert.equal(listed.recovered,2);
  assert.equal(listed.people,2);
  assert.deepEqual(listed.who,['Ahmed Ali','Sara Noor']);
  assert.deepEqual(listed.versions,['1.1.0','1.2.0','unknown']);
  assert.equal(listed.last_day,today);
  assert.equal(overview.notion_failure_sync,null);
});

// The Notion endpoints the sync uses, keeping pages in read format.
function fakeNotion() {
  const pages = [];
  const log = [];
  let n = 0;
  const read = props => Object.fromEntries(Object.entries(props).map(([name,p]) => {
    if (p.title || p.rich_text) { const type = p.title ? 'title' : 'rich_text'; return [name,{type,[type]:p[type].map(x=>({type:'text',text:x.text,plain_text:x.text.content}))}]; }
    if ('select' in p) return [name,{type:'select',select:p.select && {name:p.select.name}}];
    if ('date' in p) return [name,{type:'date',date:p.date}];
    return [name,{type:'number',number:p.number}];
  }));
  const fetcher = async (url, init) => {
    const u = new URL(url), body = init.body ? JSON.parse(init.body) : null;
    assert.equal(init.headers.Authorization,'Bearer '+notionToken);
    log.push({method:init.method,path:u.pathname,body});
    let m;
    if (init.method === 'POST' && u.pathname === `/v1/data_sources/${FAILURES}/query`) return Response.json({results:pages,has_more:false,next_cursor:null});
    if (init.method === 'POST' && u.pathname === '/v1/pages') {
      assert.equal(body.parent.data_source_id,FAILURES);
      const page = {id:'page-'+(++n),archived:false,in_trash:false,properties:read(body.properties)};
      pages.push(page);
      return Response.json(page);
    }
    if (init.method === 'PATCH' && (m = u.pathname.match(/^\/v1\/pages\/([^/]+)$/))) {
      Object.assign(pages.find(p=>p.id === m[1]).properties,read(body.properties));
      return Response.json({});
    }
    return Response.json({},{status:404});
  };
  const value = (key, prop) => {
    const page = pages.find(p=>p.properties.Fingerprint.rich_text.map(x=>x.plain_text).join('') === key);
    const p = page?.properties[prop];
    return p && (p.type === 'title' || p.type === 'rich_text' ? p[p.type].map(x=>x.plain_text).join('') : p.type === 'select' ? p.select?.name : p.type === 'date' ? p.date?.start : p.number);
  };
  return {pages,log,fetcher,value,writes:() => log.filter(c=>c.method === 'PATCH' || c.path === '/v1/pages')};
}

test('hourly copy to Notion: one row per error, Status set once and then left to the owner',async t=>{
  const s = setup(t);
  const notion = fakeNotion();
  assert.deepEqual(Object.keys(await syncFailures({...s.env,NOTION_FAILURES_SOURCE:''})),['skipped','at']);
  const a = await s.enroll('Ahmed Ali','DESK-07','ahmed');
  await s.request('/v1/failures','POST',a.device_token,{events:[event({count:2}),event({tool:'list_views',code:'busy',message:'Revit is busy.',day:day(1)})]},{'X-Connector-Version':'1.2.0'});
  let summary = await syncFailures(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(summary.failures,{created:2,updated:0,unchanged:0});
  const key = await fingerprint(event());
  assert.equal(notion.value(key,'Status'),'New');
  assert.equal(notion.value(key,'Product'),'Revit');
  assert.equal(notion.value(key,'Failures (30 days)'),2);
  assert.equal(notion.value(key,'Who'),'Ahmed Ali');
  assert.equal(notion.value(key,'Versions'),'1.2.0');
  assert.equal(notion.value(key,'Last seen'),today);
  assert.ok(notion.value(key,'Name').startsWith('execute_csharp: C# compilation failed'));
  // Nothing changed: no writes. The owner marks a row; the service never touches Status again.
  notion.pages[0].properties.Status = {type:'select',select:{name:'Planned'}};
  notion.log.length = 0;
  summary = await syncFailures(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(summary.failures,{created:0,updated:0,unchanged:2});
  assert.equal(notion.writes().length,0);
  await s.request('/v1/failures','POST',a.device_token,{events:[event()]},{'X-Connector-Version':'1.2.0'});
  summary = await syncFailures(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(summary.failures,{created:0,updated:1,unchanged:1});
  assert.deepEqual(Object.keys(notion.writes()[0].body.properties),['Failures (30 days)']);
  assert.equal(notion.value(key,'Status'),'Planned');
  // An error with no failure in 30 days keeps its row with zero counts.
  s.sqlite.prepare("UPDATE failure_counts SET day=? WHERE fingerprint=?").run(day(40),key);
  summary = await syncFailures(s.env,{fetcher:notion.fetcher});
  assert.equal(notion.value(key,'Failures (30 days)'),0);
  assert.equal(notion.value(key,'Last seen'),today);
  // A Notion failure reports the status only.
  const failing = await syncFailures(s.env,{fetcher:async()=>new Response('secret body',{status:503})});
  assert.equal(failing.error,'Notion HTTP 503');
});

test('the write cap leaves the rest pending for the next hour',async t=>{
  const s = setup(t);
  const notion = fakeNotion();
  const a = await s.enroll('Ahmed Ali','DESK-07','ahmed');
  await s.request('/v1/failures','POST',a.device_token,{events:Array.from({length:5},(_,i)=>event({tool:'tool_'+i}))});
  let summary = await syncFailures(s.env,{fetcher:notion.fetcher,maxWrites:3});
  assert.equal(summary.failures.created,3);
  assert.equal(summary.pending,2);
  summary = await syncFailures(s.env,{fetcher:notion.fetcher,maxWrites:3});
  assert.equal(summary.failures.created,2);
  assert.equal(summary.pending,0);
});

test('cron at minute 7 and the admin endpoint run the sync and keep the summary',async t=>{
  const s = setup(t,{NOTION_TOKEN:''});
  const waiting = [];
  worker.scheduled({cron:'7 * * * *',scheduledTime:Date.now()},s.env,{waitUntil:p=>waiting.push(p)});
  await Promise.all(waiting);
  assert.equal(JSON.parse(s.sqlite.prepare('SELECT summary FROM notion_failure_sync').get().summary).skipped,'not configured');
  assert.equal((await s.request('/admin/api/notion-failures','POST','wrong')).status,403);
  const r = await s.request('/admin/api/notion-failures','POST',admin);
  assert.equal(r.status,200);
  assert.equal((await r.json()).skipped,'not configured');
  const wrangler = readFileSync(new URL('../wrangler.jsonc',import.meta.url),'utf8');
  assert.match(wrangler,/"7 \* \* \* \*"/);
});
