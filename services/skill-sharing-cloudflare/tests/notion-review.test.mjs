// Skill review in Notion: who may decide, what a decision applies to, the queue rows, retries and the request budget.
// Runs against an in-memory fake of the Notion API that records who edited each row, and a fake GitHub backend.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import worker, { handle, runReviewSync } from '../src/index.mjs';
import { syncReviews } from '../src/notion-review.mjs';

const admin = 'test-only-admin-token-at-least-32-characters';
const notionToken = 'test-only-notion-integration-value';
const SOURCE = 'review-source', BOT = 'bot-user', OWNER = 'owner-user';

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
    NOTION_TOKEN:notionToken,NOTION_REVIEW_SOURCE:SOURCE,NOTION_REVIEWERS:OWNER,...extra};
  return {sqlite,env};
}

// Pages in Notion's read format. Every write by the service is made by BOT; edit() plays a person using Notion.
function fakeNotion() {
  const pages = [], log = [], hooks = [];
  let n = 0;
  const read = props => Object.fromEntries(Object.entries(props).map(([name,p]) => {
    if (p.title || p.rich_text) { const type = p.title ? 'title' : 'rich_text'; return [name,{type,[type]:p[type].map(x=>({type:'text',text:x.text,plain_text:x.text.content}))}]; }
    if ('select' in p) return [name,{type:'select',select:p.select && {id:'o',name:p.select.name}}];
    if ('checkbox' in p) return [name,{type:'checkbox',checkbox:p.checkbox}];
    if ('url' in p) return [name,{type:'url',url:p.url}];
    if ('date' in p) return [name,{type:'date',date:p.date?.start ? {start:p.date.start,end:null} : null}];
    throw new Error('unexpected property '+JSON.stringify(p));
  }));
  const fetcher = async (url, init) => {
    const u = new URL(url), body = init.body ? JSON.parse(init.body) : null;
    assert.equal(u.origin,'https://api.notion.com');
    assert.equal(init.headers.Authorization,'Bearer '+notionToken);
    assert.equal(init.headers['Notion-Version'],'2025-09-03');
    log.push({method:init.method,path:u.pathname,body});
    const hook = hooks.shift();
    if (hook) { const r = hook(); if (r) return r; }
    let m;
    if (init.method === 'POST' && (m = u.pathname.match(/^\/v1\/data_sources\/([^/]+)\/query$/))) {
      assert.equal(m[1],SOURCE);
      return Response.json({object:'list',results:pages,has_more:false,next_cursor:null});
    }
    if (init.method === 'POST' && u.pathname === '/v1/pages') {
      assert.equal(body.parent.data_source_id,SOURCE);
      const page = {object:'page',id:'page-'+(++n),archived:false,in_trash:false,last_edited_by:{object:'user',id:BOT},properties:read(body.properties)};
      pages.push(page);
      return Response.json(page);
    }
    if (init.method === 'PATCH' && (m = u.pathname.match(/^\/v1\/pages\/([^/]+)$/))) {
      const page = pages.find(p=>p.id === m[1]);
      Object.assign(page.properties,read(body.properties));
      page.last_edited_by = {object:'user',id:BOT};
      return Response.json(page);
    }
    return Response.json({object:'error'},{status:404});
  };
  const get = (page, name) => { const p = page.properties[name]; return !p ? undefined : p.type === 'title' || p.type === 'rich_text' ? p[p.type].map(x=>x.plain_text).join('') : p.type === 'select' ? p.select?.name : p.type === 'checkbox' ? p.checkbox : p.type === 'url' ? p.url : p.date?.start; };
  const edit = (page, props, user = OWNER) => { Object.assign(page.properties,read(props)); page.last_edited_by = {object:'user',id:user}; };
  const writes = () => log.filter(c=>c.method === 'PATCH' || c.path === '/v1/pages');
  return {pages,log,hooks,fetcher,get,edit,writes,reset() { log.length = 0; }};
}

const SKILL = '---\nname: acad-zones\ndescription: Draws zone outlines on plan linework.\ncategory: autocad\n---\nSteps.';
function upload(pr, name, extra = {}) {
  return {pr,pr_url:`https://github.com/owner/repo/pull/${pr}`,head_sha:'a'.repeat(40)+pr,submitted_at:1793000000+pr,name,category:'autocad',folder:'autocad/'+name,
    approved_folder:null,status:'new',stale:false,key:'key-'+name,approved_key:'none',head_files:{'SKILL.md':'blob1'},
    files:[{path:'SKILL.md',status:'added',before:null,after:SKILL.replace('acad-zones',name)}],checks:{blocked:[],flags:[]},...extra};
}
function fakeGitHub(items) {
  const gh = {items,approved:[],closed:[],queueCalls:0,failRead:false,
    async reviewQueue(limit) { gh.queueCalls++; assert.ok(limit <= 4); return {library_commit:'lib',more:false,prs:[...new Set(gh.items.map(i=>i.pr))].map(number=>({number,url:`https://github.com/owner/repo/pull/${number}`})),items:gh.items}; },
    async reviewOne(pr) { if (gh.failRead) throw new Error('GitHub HTTP 503'); const mine = gh.items.filter(i=>i.pr === pr); return mine.length ? {pr:{number:pr},items:mine} : null; },
    async approveSkill(item, category) { gh.approved.push([item.name,category,item.head_files]); return 'c0ffee1234567890'; },
    async closeIntake(pr, summary) { gh.closed.push([pr,summary]); }};
  return gh;
}
const run = (s, gh, notion, options = {}) => runReviewSync(s.env,{gh,fetcher:notion.fetcher,sleep:async()=>{},...options});
const row = (s, name) => s.sqlite.prepare('SELECT * FROM notion_review WHERE skill=?').get(name);

test('not configured: skipped without any request',async t=>{
  for (const missing of ['NOTION_TOKEN','NOTION_REVIEW_SOURCE']) {
    const s = setup(t,{[missing]:undefined});
    const r = await syncReviews(s.env,{fetcher:()=>assert.fail('no request expected'),gh:fakeGitHub([])});
    assert.equal(r.skipped,'not configured');
  }
});

test('a skill waiting for review becomes one row with exact properties; a second run writes nothing',async t=>{
  const s = setup(t), notion = fakeNotion();
  const gh = fakeGitHub([upload(7,'acad-zones',{checks:{blocked:['SKILL.md has no "description:" line.'],flags:[{kind:'secret',path:'SKILL.md',line:5,text:'api_key = hunter2'}]},
    files:[{path:'SKILL.md',status:'added',after:SKILL},{path:'scripts/zone.ps1',status:'added',after:'x'}]})]);
  const r = await run(s,gh,notion);
  assert.equal(r.created,1);
  assert.equal(notion.pages.length,1);
  const page = notion.pages[0];
  assert.deepEqual(notion.writes()[0].body.properties,{Name:{title:[{text:{content:'acad-zones'}}]},Status:{select:{name:'Pending'}},Decision:{select:null},
    Category:{select:{name:'autocad'}},'Flagged lines checked':{checkbox:false},Change:{select:{name:'New'}},
    Description:{rich_text:[{text:{content:'Draws zone outlines on plan linework.'}}]},Sender:{rich_text:[{text:{content:'Unknown sender'}}]},
    Uploaded:{date:{start:'2026-10-26T07:33:27.000Z'}},'Pull request':{url:'https://github.com/owner/repo/pull/7/files'},
    Files:{rich_text:[{text:{content:'added: SKILL.md, scripts/zone.ps1'}}]},Blocked:{rich_text:[{text:{content:'SKILL.md has no "description:" line.'}}]},
    Flags:{rich_text:[{text:{content:'secret in SKILL.md line 5'}}]},Result:{rich_text:[]},Reference:{rich_text:[{text:{content:'7/acad-zones/'+'a'.repeat(12)}}]}});
  assert.ok(!JSON.stringify(notion.log).includes('hunter2'),'flagged text must never be copied to Notion');
  assert.deepEqual({pr:row(s,'acad-zones').pr,page:row(s,'acad-zones').page_id,flagged:row(s,'acad-zones').flagged},{pr:7,page:page.id,flagged:1});
  notion.reset();
  const again = await run(s,gh,notion);
  assert.equal(again.created,0); assert.equal(notion.writes().length,0);
});

test('a decision by a listed reviewer is applied to what the service stored, then the row and the PR are closed out',async t=>{
  const s = setup(t), notion = fakeNotion(), gh = fakeGitHub([upload(7,'acad-zones')]);
  await run(s,gh,notion);
  const page = notion.pages[0];
  // The person also changes the visible name and reference: only the stored values count.
  notion.edit(page,{Decision:{select:{name:'Approve'}},Category:{select:{name:'general'}},Name:{title:[{text:{content:'something-else'}}]},Reference:{rich_text:[{text:{content:'9/other/x'}}]}});
  const r = await run(s,gh,notion);
  assert.equal(r.applied,1);
  assert.deepEqual(gh.approved.map(a=>[a[0],a[1]]),[['acad-zones','general']]);
  assert.equal(notion.get(page,'Status'),'Approved');
  assert.equal(notion.get(page,'Decision'),undefined);
  assert.match(notion.get(page,'Result'),/Approved into general: commit c0ffee1\. The upload was closed on GitHub\./);
  assert.equal(gh.closed.length,1);
  assert.equal(s.sqlite.prepare('SELECT decision,category,commit_sha FROM review_decisions WHERE pr=7').get().decision,'approve');
  // An approved row is never acted on again.
  notion.edit(page,{Decision:{select:{name:'Reject'}}});
  const later = await run(s,gh,notion);
  assert.equal(later.applied,0); assert.equal(gh.approved.length,1);
});

test('a reject is recorded and needs no category',async t=>{
  const s = setup(t), notion = fakeNotion(), gh = fakeGitHub([upload(7,'acad-zones',{category:'uncategorized'})]);
  await run(s,gh,notion);
  assert.equal(notion.get(notion.pages[0],'Category'),undefined,'an unknown folder gets no preset category');
  notion.edit(notion.pages[0],{Decision:{select:{name:'Reject'}}});
  await run(s,gh,notion);
  assert.equal(notion.get(notion.pages[0],'Status'),'Rejected');
  assert.equal(gh.approved.length,0);
  assert.equal(s.sqlite.prepare('SELECT decision FROM review_decisions').get().decision,'reject');
});

test('a change by anyone who is not a reviewer, or with no reviewers configured, is never applied',async t=>{
  for (const [reviewers,editor,pattern] of [['owner-user','intruder',/made by Notion user intruder, who is not a reviewer/],['',OWNER,/no reviewers are configured\. Add your Notion user ID \(owner-user\)/]]) {
    const s = setup(t,{NOTION_REVIEWERS:reviewers}), notion = fakeNotion(), gh = fakeGitHub([upload(7,'acad-zones')]);
    await run(s,gh,notion);
    const page = notion.pages[0];
    notion.edit(page,{Decision:{select:{name:'Approve'}}},editor);
    const r = await run(s,gh,notion);
    assert.equal(r.not_applied,1);
    assert.equal(gh.approved.length,0);
    assert.equal(s.sqlite.prepare('SELECT COUNT(*) AS n FROM review_decisions').get().n,0);
    assert.equal(notion.get(page,'Status'),'Not applied');
    assert.equal(notion.get(page,'Decision'),undefined,'the decision is cleared so it is not retried');
    assert.match(notion.get(page,'Result'),pattern);
  }
});

test('a row the service did not create is ignored for decisions',async t=>{
  const s = setup(t), notion = fakeNotion(), gh = fakeGitHub([]);
  notion.pages.push({id:'foreign',archived:false,last_edited_by:{id:OWNER},properties:{Decision:{type:'select',select:{name:'Approve'}},Name:{type:'title',title:[{plain_text:'x',text:{content:'x'}}]}}});
  const r = await run(s,gh,notion);
  assert.equal(r.not_applied,1); assert.equal(gh.approved.length,0);
  assert.match(notion.get(notion.pages[0],'Result'),/did not create this row/);
});

test('an upload that changed after the row was written is refused and the row is refreshed for review',async t=>{
  const s = setup(t), notion = fakeNotion(), gh = fakeGitHub([upload(7,'acad-zones')]);
  await run(s,gh,notion);
  const page = notion.pages[0];
  gh.items = [upload(7,'acad-zones',{head_sha:'b'.repeat(41),key:'key-new'})];
  notion.edit(page,{Decision:{select:{name:'Approve'}}});
  const r = await run(s,gh,notion);
  assert.equal(gh.approved.length,0,'the decision was made on the old content');
  assert.equal(r.not_applied,1);
  assert.equal(r.updated,1);
  assert.equal(notion.get(page,'Status'),'Pending');
  assert.match(notion.get(page,'Result'),/changed after the last version/);
  assert.equal(row(s,'acad-zones').content_key,'key-new');
  // The refreshed row can now be decided.
  notion.edit(page,{Decision:{select:{name:'Approve'}}});
  await run(s,gh,notion);
  assert.equal(gh.approved.length,1);
});

test('blocked uploads and flagged lines are held to the same rules as in the dashboard',async t=>{
  const s = setup(t), notion = fakeNotion();
  const gh = fakeGitHub([upload(7,'blocked-one',{checks:{blocked:['bad'],flags:[]}}),upload(8,'flagged-one',{checks:{blocked:[],flags:[{kind:'personal-path',path:'SKILL.md',line:2,text:'C:\\Users\\x'}]}})]);
  await run(s,gh,notion);
  const [blocked,flagged] = notion.pages;
  notion.edit(blocked,{Decision:{select:{name:'Approve'}}});
  notion.edit(flagged,{Decision:{select:{name:'Approve'}}});
  await run(s,gh,notion);
  assert.match(notion.get(blocked,'Result'),/fails a required check/);
  assert.match(notion.get(flagged,'Result'),/Confirm that you checked the flagged lines/);
  assert.equal(gh.approved.length,0);
  notion.edit(flagged,{Decision:{select:{name:'Approve'}},'Flagged lines checked':{checkbox:true}});
  await run(s,gh,notion);
  assert.deepEqual(gh.approved.map(a=>a[0]),['flagged-one']);
});

test('a GitHub outage leaves the decision in place to retry; a decision needs a valid category',async t=>{
  const s = setup(t), notion = fakeNotion(), gh = fakeGitHub([upload(7,'acad-zones')]);
  await run(s,gh,notion);
  const page = notion.pages[0];
  notion.edit(page,{Decision:{select:{name:'Approve'}}});
  gh.failRead = true;
  notion.reset();
  const down = await run(s,gh,notion);
  assert.equal(down.retry,1);
  assert.equal(notion.writes().length,0,'the row is untouched so the reviewer check still passes next time');
  assert.equal(notion.get(page,'Decision'),'Approve');
  gh.failRead = false;
  notion.edit(page,{Category:{select:null}});
  const noCategory = await run(s,gh,notion);
  assert.equal(noCategory.not_applied,1);
  assert.match(notion.get(page,'Result'),/Choose the category/);
  assert.equal(gh.approved.length,0);
});

test('at most two decisions per run, and no queue read when the request budget is used',async t=>{
  const s = setup(t), notion = fakeNotion();
  const gh = fakeGitHub([upload(1,'one'),upload(2,'two'),upload(3,'three')]);
  await run(s,gh,notion);
  for (const page of notion.pages) notion.edit(page,{Decision:{select:{name:'Approve'}}});
  gh.queueCalls = 0;
  const r = await run(s,gh,notion);
  assert.equal(r.applied,2); assert.equal(r.retry,1);
  assert.equal(gh.queueCalls,0,'two decisions use the budget; the queue is read next run');
  const next = await run(s,gh,notion);
  assert.equal(next.applied,1);
  assert.equal(gh.approved.length,3);
});

test('rows whose upload is gone are closed; a page deleted in Notion is made again; an unrecorded page is adopted',async t=>{
  const s = setup(t), notion = fakeNotion(), gh = fakeGitHub([upload(1,'gone-one'),upload(2,'kept-two')]);
  await run(s,gh,notion);
  const [gone,kept] = notion.pages;
  gh.items = [upload(2,'kept-two')];
  kept.archived = true;
  const r = await run(s,gh,notion);
  assert.equal(r.closed,1); assert.equal(r.created,1);
  assert.equal(notion.get(gone,'Status'),'Closed');
  assert.equal(notion.pages.filter(p=>!p.archived && notion.get(p,'Name') === 'kept-two').length,1);
  // Orphan: the page exists but the database lost its record.
  s.sqlite.exec('DELETE FROM notion_review');
  notion.reset();
  const adopted = await run(s,gh,notion);
  assert.equal(adopted.created,0);
  assert.equal(notion.pages.filter(p=>!p.archived && notion.get(p,'Name') === 'kept-two').length,1);
  assert.equal(row(s,'kept-two').page_id,notion.pages.find(p=>!p.archived && notion.get(p,'Name') === 'kept-two').id);
});

test('an upload already decided, or rejected before with the same content, is not listed',async t=>{
  const s = setup(t), notion = fakeNotion(), gh = fakeGitHub([upload(1,'done-one'),upload(2,'seen-two',{key:'same'}),upload(3,'fresh-three')]);
  s.sqlite.exec(`INSERT INTO review_decisions(pr,skill,head_sha,content_key,decision,at) VALUES(1,'done-one','h','k','approve',1),(9,'seen-two','h','same','reject',1)`);
  const r = await run(s,gh,notion);
  assert.equal(r.created,1);
  assert.equal(notion.get(notion.pages[0],'Name'),'fresh-three');
});

test('a Notion failure reports only the status code; the endpoint and the schedule use the same run',async t=>{
  const s = setup(t), notion = fakeNotion(), gh = fakeGitHub([upload(1,'one')]);
  notion.hooks.push(()=>Response.json({message:'secret detail '+notionToken},{status:500}));
  const r = await run(s,gh,notion);
  assert.equal(r.error,'Notion HTTP 500');
  assert.ok(!JSON.stringify(r).includes(notionToken));
  // The admin endpoint needs the admin token and, unconfigured, reports that it skipped.
  const bare = setup(t,{NOTION_REVIEW_SOURCE:undefined});
  const denied = await handle(new Request('https://x.test/admin/api/notion-review',{method:'POST'}),bare.env,gh);
  assert.equal(denied.status,401);
  const ok = await handle(new Request('https://x.test/admin/api/notion-review',{method:'POST',headers:{Authorization:'Bearer '+admin}}),bare.env,gh);
  assert.equal(ok.status,200); assert.equal((await ok.json()).skipped,'not configured');
  const overview = await (await handle(new Request('https://x.test/admin/api/overview',{headers:{Authorization:'Bearer '+admin}}),bare.env,gh)).json();
  assert.equal(overview.notion_review_sync.skipped,'not configured');
  const waiting = [];
  worker.scheduled({cron:'47 * * * *',scheduledTime:Date.now()},bare.env,{waitUntil:p=>waiting.push(p)});
  await Promise.all(waiting);
  assert.equal(waiting.length,1);
});
