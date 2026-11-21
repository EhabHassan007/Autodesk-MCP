// Hourly Notion sync: diffing, write cap, retries and errors, against an in-memory fake of the Notion API.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import worker, { handle } from '../src/index.mjs';
import { syncToNotion } from '../src/notion.mjs';

const admin = 'test-only-admin-token-at-least-32-characters';
const notionToken = 'test-only-notion-integration-value';
const MEMBERS = 'members-source', USAGE = 'usage-source';
const day = ago => new Date(Date.now()-ago*86400000).toISOString().slice(0,10);
const T0 = Date.UTC(2026,9,30,8,15,42)/1000;

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
  }};
  const env = {DB,ADMIN_TOKEN:admin,GITHUB_PRIVATE_KEY:'fake-test-key',GITHUB_APP_ID:'1',GITHUB_INSTALLATION_ID:'2',GITHUB_REPOSITORY:'owner/repo',
    NOTION_TOKEN:notionToken,NOTION_MEMBERS_SOURCE:MEMBERS,NOTION_USAGE_SOURCE:USAGE,...extra};
  const addDevice = (id, o = {}) => sqlite.prepare(`INSERT INTO devices(id,hash,label,active,source,person_name,email,pc_name,windows_user,connector_version,terms_version,created_at,last_seen)
    VALUES(?,?,?,?,'join',?,?,?,?,?,?,?,?)`).run(id,'hash-'+id,o.label ?? 'Label '+id,o.active ?? 1,o.person_name ?? null,o.email ?? null,o.pc_name ?? null,
    o.windows_user ?? null,o.connector_version ?? null,o.terms_version ?? null,o.created_at ?? 0,o.last_seen ?? 0);
  const use = (device, kind, name, d, count) => sqlite.prepare('INSERT INTO usage VALUES(?,?,?,?,?)').run(device,kind,name,d,count);
  return {sqlite,env,addDevice,use};
}

// Emulates the Notion endpoints the sync uses; stores pages in read format, keeps date-times to the minute as Notion does.
function fakeNotion({pageSize = 100} = {}) {
  const pages = {[MEMBERS]:[],[USAGE]:[]};
  const log = [];
  const hooks = [];
  let n = 0;
  const read = props => Object.fromEntries(Object.entries(props).map(([name,p]) => {
    if (p.title || p.rich_text) { const type = p.title ? 'title' : 'rich_text'; return [name,{type,[type]:p[type].map(x=>({type:'text',text:x.text,plain_text:x.text.content}))}]; }
    if ('email' in p) return [name,{type:'email',email:p.email}];
    if ('select' in p) return [name,{type:'select',select:p.select && {id:'opt',name:p.select.name}}];
    if ('date' in p) {
      const start = p.date?.start;
      return [name,{type:'date',date:start ? {start:start.length === 10 ? start : new Date(start).toISOString().slice(0,16)+':00.000+00:00',end:null} : null}];
    }
    return [name,{type:'number',number:p.number}];
  }));
  const fetcher = async (url, init) => {
    const u = new URL(url), body = init.body ? JSON.parse(init.body) : null;
    assert.equal(u.origin,'https://api.notion.com');
    assert.equal(init.headers.Authorization,'Bearer '+notionToken);
    assert.equal(init.headers['Notion-Version'],'2025-09-03');
    assert.equal(init.headers['Content-Type'],'application/json');
    log.push({method:init.method,path:u.pathname,body});
    const hook = hooks.shift();
    if (hook) { const r = hook(); if (r) return r; }
    let m;
    if (init.method === 'POST' && (m = u.pathname.match(/^\/v1\/data_sources\/([^/]+)\/query$/))) {
      const all = pages[m[1]], start = Number(body.start_cursor ?? 0), size = Math.min(body.page_size,pageSize);
      const more = start+size < all.length;
      return Response.json({object:'list',results:all.slice(start,start+size),has_more:more,next_cursor:more ? String(start+size) : null});
    }
    if (init.method === 'POST' && u.pathname === '/v1/pages') {
      assert.equal(body.parent.type,'data_source_id');
      const page = {object:'page',id:'page-'+(++n),archived:false,in_trash:false,properties:read(body.properties)};
      pages[body.parent.data_source_id].push(page);
      return Response.json(page);
    }
    if (init.method === 'PATCH' && (m = u.pathname.match(/^\/v1\/pages\/([^/]+)$/))) {
      const page = Object.values(pages).flat().find(p=>p.id === m[1]);
      Object.assign(page.properties,read(body.properties));
      return Response.json(page);
    }
    return Response.json({object:'error'},{status:404});
  };
  const writes = () => log.filter(c=>c.method === 'PATCH' || c.path === '/v1/pages');
  const value = (source, key, prop) => {
    const page = pages[source].find(p=>(p.properties[source === MEMBERS ? 'Device ID' : 'Key']?.rich_text ?? []).map(x=>x.plain_text).join('') === key);
    const p = page?.properties[prop];
    return p && (p.type === 'title' || p.type === 'rich_text' ? p[p.type].map(x=>x.plain_text).join('') : p.type === 'email' ? p.email : p.type === 'select' ? p.select?.name : p.type === 'date' ? p.date?.start : p.number);
  };
  return {pages,log,hooks,fetcher,writes,value,reset() { log.length = 0; }};
}

function team(s) {
  s.addDevice('d1',{person_name:'Ahmed Ali',email:'Ahmed.Ali@Example.com',pc_name:'DESK-07',windows_user:'ahmed',connector_version:'1.0.0-beta.18',
    terms_version:'2026-10-30',created_at:T0,last_seen:T0+3600});
  s.addDevice('d2',{label:'Office PC',active:0});
  s.use('d1','skill','revit-check',day(0),5);
  s.use('d1','skill','revit-check',day(3),2);
  s.use('d1','skill','acad-layers',day(1),4);
  s.use('d1','skill','sheet-index',day(2),1);
  s.use('d1','skill','tiny',day(2),1);
  s.use('d1','tool','get_elements',day(0),9);
  s.use('d2','skill','revit-check',day(29),3);
  s.use('d2','skill','old-skill',day(30),8);
}

test('not configured: skipped without any request',async t=>{
  for (const missing of ['NOTION_TOKEN','NOTION_MEMBERS_SOURCE','NOTION_USAGE_SOURCE']) {
    const s = setup(t,{[missing]:undefined});
    const r = await syncToNotion(s.env,{fetcher:()=>assert.fail('no request expected')});
    assert.equal(r.skipped,'not configured');
  }
});

test('first run creates member and usage rows with exact property shapes; second run writes nothing',async t=>{
  const s = setup(t), notion = fakeNotion();
  team(s);
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(r.members,{created:2,updated:0,unchanged:0});
  assert.deepEqual(r.usage,{created:5,updated:0,unchanged:0});
  assert.equal(r.pending,0);
  assert.ok(Number.isInteger(r.at));
  const creates = notion.writes();
  const created = key => creates.find(c=>(c.body.properties['Device ID'] ?? c.body.properties.Key).rich_text[0].text.content === key).body;
  assert.deepEqual(created('d1'),{parent:{type:'data_source_id',data_source_id:MEMBERS},properties:{
    Name:{title:[{text:{content:'Ahmed Ali'}}]},Email:{email:'Ahmed.Ali@Example.com'},PC:{rich_text:[{text:{content:'DESK-07'}}]},
    'Windows user':{rich_text:[{text:{content:'ahmed'}}]},Version:{rich_text:[{text:{content:'1.0.0-beta.18'}}]},Status:{select:{name:'Active'}},
    Joined:{date:{start:'2026-10-30T08:15:42.000Z'}},'Last seen':{date:{start:'2026-10-30T09:15:42.000Z'}},
    'Skill uses (30 days)':{number:13},'Tool uses (30 days)':{number:9},'Top skills':{rich_text:[{text:{content:'revit-check (7), acad-layers (4), sheet-index (1)'}}]},
    'Terms version':{rich_text:[{text:{content:'2026-10-30'}}]},'Device ID':{rich_text:[{text:{content:'d1'}}]}}});
  assert.deepEqual(created('d2').properties,{Name:{title:[{text:{content:'Office PC'}}]},Email:{email:null},PC:{rich_text:[]},'Windows user':{rich_text:[]},
    Version:{rich_text:[]},Status:{select:{name:'Blocked'}},Joined:{date:null},'Last seen':{date:null},'Skill uses (30 days)':{number:3},
    'Tool uses (30 days)':{number:0},'Top skills':{rich_text:[{text:{content:'revit-check (3)'}}]},'Terms version':{rich_text:[]},'Device ID':{rich_text:[{text:{content:'d2'}}]}});
  assert.deepEqual(created('skill:revit-check'),{parent:{type:'data_source_id',data_source_id:USAGE},properties:{Name:{title:[{text:{content:'revit-check'}}]},
    Kind:{select:{name:'Skill'}},'Uses (30 days)':{number:10},'People (30 days)':{number:2},'Last used':{date:{start:day(0)}},Key:{rich_text:[{text:{content:'skill:revit-check'}}]}}});
  assert.equal(notion.value(USAGE,'tool:get_elements','Kind'),'Tool');
  assert.equal(notion.value(USAGE,'skill:old-skill','Name'),undefined,'usage older than 30 days is not created');
  notion.reset();
  const again = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(again.members,{created:0,updated:0,unchanged:2});
  assert.deepEqual(again.usage,{created:0,updated:0,unchanged:5});
  assert.equal(notion.writes().length,0);
  assert.deepEqual(notion.log.map(c=>c.path),[`/v1/data_sources/${MEMBERS}/query`,`/v1/data_sources/${USAGE}/query`]);
});

test('a changed field updates only that row and property; blocking shows Blocked',async t=>{
  const s = setup(t), notion = fakeNotion();
  team(s);
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  s.sqlite.prepare("UPDATE devices SET active=0,email='AHMED.ALI@example.com' WHERE id='d1'").run();
  notion.reset();
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(r.members,{created:0,updated:1,unchanged:1});
  assert.deepEqual(notion.writes().map(w=>[w.method,w.body]),[['PATCH',{properties:{Status:{select:{name:'Blocked'}}}}]],'email case alone is not a change');
  assert.equal(notion.writes()[0].path,'/v1/pages/'+notion.pages[MEMBERS].find(p=>p.properties['Device ID'].rich_text[0].plain_text === 'd1').id);
  assert.equal(notion.value(MEMBERS,'d1','Status'),'Blocked');
});

test('usage with no use in 30 days is zeroed once, keeping Last used; rows are never deleted',async t=>{
  const s = setup(t), notion = fakeNotion();
  team(s);
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  s.sqlite.prepare("UPDATE usage SET day=? WHERE name='tiny'").run(day(31));
  notion.reset();
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(r.usage,{created:0,updated:1,unchanged:4});
  assert.deepEqual(r.members,{created:0,updated:1,unchanged:1});
  assert.deepEqual(notion.writes().map(w=>w.body),[{properties:{'Skill uses (30 days)':{number:12}}},
    {properties:{'Uses (30 days)':{number:0},'People (30 days)':{number:0}}}],'members first, then usage');
  assert.equal(notion.value(USAGE,'skill:tiny','Last used'),day(2));
  assert.equal(notion.pages[USAGE].length,5);
  notion.reset();
  assert.equal((await syncToNotion(s.env,{fetcher:notion.fetcher})).usage.unchanged,5);
  assert.equal(notion.writes().length,0,'already zero: no write');
});

test('the write cap leaves pending rows for the next run, which finishes them',async t=>{
  const s = setup(t), notion = fakeNotion();
  team(s);
  const first = await syncToNotion(s.env,{fetcher:notion.fetcher,maxWrites:3});
  assert.deepEqual(first.members,{created:2,updated:0,unchanged:0});
  assert.deepEqual(first.usage,{created:1,updated:0,unchanged:0});
  assert.equal(first.pending,4);
  const second = await syncToNotion(s.env,{fetcher:notion.fetcher,maxWrites:3});
  assert.deepEqual(second.usage,{created:3,updated:0,unchanged:1});
  assert.equal(second.pending,1);
  const third = await syncToNotion(s.env,{fetcher:notion.fetcher,maxWrites:3});
  assert.equal(third.pending,0);
  assert.equal(notion.pages[USAGE].length,5);
});

test('reads every page of a data source (has_more) and ignores archived and trashed rows',async t=>{
  const s = setup(t), notion = fakeNotion({pageSize:2});
  team(s);
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  for (const p of notion.pages[USAGE]) p.properties['Uses (30 days)'].number = 999;
  notion.pages[USAGE][4].archived = true;
  notion.pages[USAGE][3].in_trash = true;
  notion.reset();
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.equal(notion.log.filter(c=>c.path.endsWith(`${USAGE}/query`)).length,3);
  assert.deepEqual(notion.log.filter(c=>c.path.endsWith('/query')).slice(1).map(c=>c.body.start_cursor),[undefined,'2','4']);
  assert.deepEqual(r.usage,{created:2,updated:3,unchanged:0},'archived/trashed rows are not reused');
  assert.equal(notion.writes().filter(w=>w.method === 'PATCH').every(w=>!w.path.endsWith(notion.pages[USAGE][4].id)),true);
});

test('duplicate keys: the first row is updated, the other left alone',async t=>{
  const s = setup(t), notion = fakeNotion();
  s.addDevice('d1',{person_name:'Ahmed Ali'});
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  const copy = structuredClone(notion.pages[MEMBERS][0]);
  copy.id = 'page-copy';
  notion.pages[MEMBERS].push(copy);
  s.sqlite.prepare("UPDATE devices SET person_name='Ahmed A.'").run();
  notion.reset();
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(r.members,{created:0,updated:1,unchanged:0});
  assert.deepEqual(notion.writes().map(w=>w.path),['/v1/pages/'+notion.pages[MEMBERS][0].id]);
});

test('429 honours Retry-After once, then succeeds; a second 429 stops the run',async t=>{
  const s = setup(t), notion = fakeNotion(), waits = [];
  s.addDevice('d1',{person_name:'Ahmed Ali'});
  notion.hooks.push(null,null,()=>new Response('',{status:429,headers:{'Retry-After':'2'}}));
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher,sleep:async ms=>{waits.push(ms);}});
  assert.deepEqual(waits,[2000]);
  assert.equal(r.error,undefined);
  assert.deepEqual(r.members,{created:1,updated:0,unchanged:0});
  assert.equal(notion.pages[MEMBERS].length,1);
  s.addDevice('d2',{person_name:'Sara'});
  s.addDevice('d3',{person_name:'Omar'});
  notion.hooks.push(null,null,()=>new Response('',{status:429,headers:{'Retry-After':'60'}}),()=>new Response('',{status:429}));
  const stopped = await syncToNotion(s.env,{fetcher:notion.fetcher,sleep:async ms=>{waits.push(ms);}});
  assert.equal(waits[1],5000,'wait is capped at 5 seconds');
  assert.equal(stopped.error,'Notion HTTP 429');
  assert.equal(stopped.pending,2);
  assert.equal(notion.writes().length,4,'no further writes after the failure');
});

test('HTTP 500 stops the run with counts so far and no personal data or token',async t=>{
  const s = setup(t), notion = fakeNotion();
  team(s);
  notion.hooks.push(null,null,null,()=>Response.json({message:'internal Ahmed.Ali@Example.com'},{status:500}));
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.equal(r.error,'Notion HTTP 500');
  assert.deepEqual(r.members,{created:1,updated:0,unchanged:0});
  assert.equal(r.pending,6);
  const text = JSON.stringify(r);
  for (const secret of [notionToken,'Ahmed','DESK-07','revit-check']) assert.ok(!text.includes(secret),secret);
  const thrown = await syncToNotion(s.env,{fetcher:async()=>{ throw new Error('network down for '+notionToken); }});
  assert.equal(thrown.error,'Notion sync failed');
});

test('long text is cut to 2000 characters',async t=>{
  const s = setup(t), notion = fakeNotion();
  s.addDevice('d1',{person_name:'x'.repeat(2500)});
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.equal(notion.value(MEMBERS,'d1','Name').length,2000);
  notion.reset();
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.equal(notion.writes().length,0);
});

test('admin endpoint needs the admin token, runs the sync and the overview shows the last summary',async t=>{
  const s = setup(t), notion = fakeNotion();
  team(s);
  const realFetch = globalThis.fetch;
  globalThis.fetch = notion.fetcher;
  t.after(()=>{ globalThis.fetch = realFetch; });
  const request = (path,method,token) => handle(new Request('https://test.local'+path,{method,headers:token ? {Authorization:'Bearer '+token} : {}}),s.env);
  assert.equal((await request('/admin/api/notion-sync','POST')).status,401);
  assert.equal((await request('/admin/api/notion-sync','POST','wrong-token')).status,403);
  assert.equal(notion.log.length,0);
  const r = await request('/admin/api/notion-sync','POST',admin);
  assert.equal(r.status,200);
  const summary = await r.json();
  assert.deepEqual(summary.members,{created:2,updated:0,unchanged:0});
  const overview = await (await request('/admin/api/overview','GET',admin)).json();
  assert.deepEqual(overview.notion_sync,summary);
  notion.hooks.push(()=>new Response('',{status:401}));
  const failed = await request('/admin/api/notion-sync','POST',admin);
  assert.equal(failed.status,502);
  assert.equal((await failed.json()).error,'Notion HTTP 401');
});

test('scheduled run syncs and stores the summary',async t=>{
  const s = setup(t), notion = fakeNotion();
  team(s);
  const realFetch = globalThis.fetch;
  globalThis.fetch = notion.fetcher;
  t.after(()=>{ globalThis.fetch = realFetch; });
  const waiting = [];
  worker.scheduled({cron:'17 * * * *',scheduledTime:Date.now()},s.env,{waitUntil:p=>waiting.push(p)});
  assert.equal(waiting.length,1);
  await Promise.all(waiting);
  const row = s.sqlite.prepare('SELECT at,summary FROM notion_sync').get();
  const summary = JSON.parse(row.summary);
  assert.deepEqual(summary.usage,{created:5,updated:0,unchanged:0});
  assert.equal(row.at,summary.at);
  assert.equal(notion.pages[MEMBERS].length,2);
});

// Status in Team members controls the PC: a reviewer's change applies, anyone else's is put back.
const OWNER = 'owner-user-id', OTHER = 'other-user-id';
function editStatus(notion, deviceId, status, editor) {
  const page = notion.pages[MEMBERS].find(p=>p.properties['Device ID'].rich_text[0].plain_text === deviceId);
  page.properties.Status = {type:'select',select:{id:'opt',name:status}};
  page.last_edited_by = {object:'user',id:editor};
}
const active = (s, id) => s.sqlite.prepare('SELECT active FROM devices WHERE id=?').get(id).active;

test('a reviewer sets Blocked in Notion: the PC is blocked and nothing is written back; Active unblocks it',async t=>{
  const s = setup(t,{NOTION_REVIEWERS:` ${OWNER.toUpperCase()} , someone-else`}), notion = fakeNotion();
  team(s);
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(s.sqlite.prepare('SELECT id,notion_status FROM devices ORDER BY id').all().map(r=>({...r})),
    [{id:'d1',notion_status:'Active'},{id:'d2',notion_status:'Blocked'}],'first run records what Notion shows');
  editStatus(notion,'d1','Blocked',OWNER);
  notion.reset();
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(r.control,{blocked:1,unblocked:0,refused:0,editors:[]});
  assert.equal(active(s,'d1'),0);
  assert.equal(notion.writes().length,0,'Notion already shows Blocked');
  editStatus(notion,'d2','Active',OWNER);
  const again = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(again.control,{blocked:0,unblocked:1,refused:0,editors:[]});
  assert.equal(active(s,'d2'),1);
  notion.reset();
  const quiet = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(quiet.control,{blocked:0,unblocked:0,refused:0,editors:[]},'a change is applied once');
  assert.equal(notion.writes().length,0);
});

test('a Status change by someone not in NOTION_REVIEWERS is refused and put back',async t=>{
  for (const reviewers of [OWNER,undefined]) {
    const s = setup(t,{NOTION_REVIEWERS:reviewers}), notion = fakeNotion();
    team(s);
    await syncToNotion(s.env,{fetcher:notion.fetcher});
    editStatus(notion,'d2','Active',OTHER);
    notion.reset();
    const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
    assert.deepEqual(r.control,{blocked:0,unblocked:0,refused:1,editors:[OTHER]});
    assert.equal(active(s,'d2'),0,'still blocked');
    assert.deepEqual(notion.writes().map(w=>w.body),[{properties:{Status:{select:{name:'Blocked'}}}}]);
    assert.equal(notion.value(MEMBERS,'d2','Status'),'Blocked');
  }
});

test('blocking on the dashboard reaches Notion and is not mistaken for a Notion change; unknown Status values are ignored',async t=>{
  const s = setup(t,{NOTION_REVIEWERS:OWNER}), notion = fakeNotion();
  team(s);
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  s.sqlite.prepare("UPDATE devices SET active=0 WHERE id='d1'").run();
  await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.equal(notion.value(MEMBERS,'d1','Status'),'Blocked');
  assert.equal(s.sqlite.prepare("SELECT notion_status FROM devices WHERE id='d1'").get().notion_status,'Blocked');
  editStatus(notion,'d1','Paused',OWNER);
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.deepEqual(r.control,{blocked:0,unblocked:0,refused:0,editors:[]});
  assert.equal(active(s,'d1'),0);
  assert.equal(notion.value(MEMBERS,'d1','Status'),'Blocked','put back to the real state');
});

test('a Status edit before the first sync recorded the row is not applied; a pending row is not recorded',async t=>{
  const s = setup(t,{NOTION_REVIEWERS:OWNER}), notion = fakeNotion();
  team(s);
  await syncToNotion(s.env,{fetcher:notion.fetcher,maxWrites:1});
  assert.deepEqual(s.sqlite.prepare('SELECT id,notion_status FROM devices ORDER BY id').all().map(r=>({...r})),
    [{id:'d1',notion_status:null},{id:'d2',notion_status:'Blocked'}],'d1 was not written yet (oldest PCs go first)');
  s.sqlite.prepare("UPDATE devices SET notion_status=NULL").run();
  editStatus(notion,'d2','Active',OWNER);
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.equal(r.control.unblocked,0);
  assert.equal(active(s,'d2'),0);
  assert.equal(notion.value(MEMBERS,'d2','Status'),'Blocked');
});

test('a failed write keeps that member unrecorded',async t=>{
  const s = setup(t,{NOTION_REVIEWERS:OWNER}), notion = fakeNotion();
  team(s);
  notion.hooks.push(null,null,()=>Response.json({},{status:500}));
  const r = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.equal(r.error,'Notion HTTP 500');
  assert.deepEqual(s.sqlite.prepare('SELECT notion_status FROM devices ORDER BY id').all().map(r=>r.notion_status),[null,null]);
  notion.hooks.push(()=>Response.json({},{status:500}));
  const early = await syncToNotion(s.env,{fetcher:notion.fetcher});
  assert.equal(early.error,'Notion HTTP 500');
  assert.deepEqual(s.sqlite.prepare('SELECT notion_status FROM devices ORDER BY id').all().map(r=>r.notion_status),[null,null],'a read failure records nothing');
});
