import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { generateKeyPairSync, verify } from 'node:crypto';
import { handle } from '../src/index.mjs';
import { appJWT, GitHub, GitHubFailure, locateSkillFile, safeGitHubDetail, submissionCategory } from '../src/github.mjs';
import { canonical, hash, MAX_BODY, validateSkills } from '../src/validation.mjs';
import { DASHBOARD_CSS, DASHBOARD_HTML, DASHBOARD_JS } from '../src/dashboard.mjs';

const admin = 'test-only-admin-token-at-least-32-characters';
const join = 'test-only-team-join-code-at-least-32-characters';
const person = {name:'Ahmed Ali',email:'Ahmed.Ali@Example.com',pc_name:'DESK-07',windows_user:'ahmed',connector_version:'1.0.0-beta.18',terms_version:'2026-10-30'};
const skill = {name:'revit-check',files:{'SKILL.md':'---\nname: revit-check\n---\nRead document information.'}};
const body = {skills:[skill]};
const url = 'https://github.com/owner/repo/pull/7';
test('GitHub diagnostics expose controlled failure categories only',async()=>{
  assert.equal(safeGitHubDetail(new Error('private-token-and-key')),'GitHub App access could not be verified.');
  const gh=new GitHub({GITHUB_REPOSITORY:'owner/repo',GITHUB_PRIVATE_KEY:'invalid-test-key',GITHUB_APP_ID:'1',GITHUB_INSTALLATION_ID:'2'});
  await assert.rejects(gh.request('GET','/repos/owner/repo'),e=>e instanceof GitHubFailure && !e.message.includes('invalid-test-key') && e.message.includes('signing'));
  gh.token='test';gh.expires=Date.now()+60000;gh.fetcher=async()=>new Response('upstream-secret',{status:403});
  await assert.rejects(gh.request('GET','/repos/owner/repo'),e=>e.message==='GitHub rejected repository access (HTTP 403).');
});
test('batch digest matches existing Python service canonical format',async()=>{
  assert.equal(await hash(canonical(validateSkills(body))),'31360d69c755e6a6b2a6ed4c832c9b4a038f096465cac1ad330e3a79785815fc');
  assert.equal(canonical({'𐀀':1,'\uE000':2}),'{"\uE000":2,"𐀀":1}');
});
function setup(t) {
  const sqlite = new DatabaseSync(':memory:');
  // Apply every migration in order, as Wrangler does in production.
  for (const file of readdirSync(new URL('../migrations/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort())
    sqlite.exec(readFileSync(new URL('../migrations/'+file,import.meta.url),'utf8'));
  t.after(()=>sqlite.close());
  const DB = {prepare(sql) {
    const stmt = sqlite.prepare(sql);
    const wrapper = params => ({bind(...values) { return wrapper(values); },async first() { return stmt.get(...params) || null; },
      async run() { return stmt.run(...params); },async all() { return {results:stmt.all(...params)}; }});
    return wrapper([]);
  },async batch(statements) { sqlite.exec('BEGIN'); try { const out=[]; for (const s of statements) out.push(await s.run()); sqlite.exec('COMMIT'); return out; } catch (e) { sqlite.exec('ROLLBACK'); throw e; } }};
  const env = {DB,ADMIN_TOKEN:admin,JOIN_CODE:join,GITHUB_PRIVATE_KEY:'fake-test-key',GITHUB_APP_ID:'1',GITHUB_INSTALLATION_ID:'2',GITHUB_REPOSITORY:'owner/repo'};
  const backend = {calls:0, async submit() { this.calls++; return url; }, async library() { return {skills:{[skill.name]:skill.files},commit:'approved-main-commit'}; }};
  const request = (path,method='GET',token,content,extra={}) => handle(new Request('https://test.local'+path,{method,headers:{...(token?{Authorization:'Bearer '+token}:{}),...extra},body:content===undefined?undefined:JSON.stringify(content)}),env,backend);
  const enroll = async () => {
    const response = await request('/admin/devices','POST',admin,{label:'Office PC'});
    assert.equal(response.status,200);
    return response.json();
  };
  return {request,enroll,env,backend,sqlite};
}

test('administrator enrollment, hashed device credential, and revoke',async t=>{
  const s=setup(t);
  assert.equal((await s.request('/admin/devices','POST','invalid',{label:'PC'})).status,403);
  const d=await s.enroll();
  const row=s.sqlite.prepare('SELECT * FROM devices').get();
  assert.equal(row.hash,await hash(d.device_token));
  assert.ok(!Object.values(row).includes(d.device_token));
  assert.equal((await s.request('/admin/devices','POST',d.device_token,{label:'PC'})).status,403);
  assert.equal((await s.request('/v1/library')).status,401);
  assert.equal((await s.request('/v1/library','GET',d.device_token)).status,200);
  assert.equal((await s.request('/admin/devices/'+d.device_id,'DELETE',admin)).status,200);
  assert.equal((await s.request('/v1/library','GET',d.device_token)).status,401);
});

test('retry deduplicates across different devices and retains owner-review response contract',async t=>{
  const s=setup(t),a=await s.enroll(),b=await s.enroll();
  const first=await s.request('/v1/submissions','POST',a.device_token,body);
  assert.equal(first.status,200);
  assert.equal((await first.json()).status,'submitted_for_approval');
  const next=await s.request('/v1/submissions','POST',b.device_token,body);
  assert.equal((await next.json()).status,'already_submitted');
  assert.equal(s.backend.calls,1);
});

test('simultaneous batches claim an atomic lease; failures release it for retry',async t=>{
  const s=setup(t),d=await s.enroll();
  let release, entered;
  const started=new Promise(resolve=>{entered=resolve;});
  s.backend.submit=async()=>{s.backend.calls++;entered();await new Promise(resolve=>{release=resolve;});throw new Error('secret upstream response');};
  const first=s.request('/v1/submissions','POST',d.device_token,body);
  await started;
  assert.equal((await s.request('/v1/submissions','POST',d.device_token,body)).status,409);
  release();
  const failed=await first;
  assert.equal(failed.status,502);
  assert.ok(!(await failed.text()).includes('secret upstream'));
  s.backend.submit=async()=>url;
  assert.equal((await s.request('/v1/submissions','POST',d.device_token,body)).status,200);
});

test('crashed-worker lease expires without locking the batch permanently',async t=>{
  const s=setup(t),d=await s.enroll();
  const digest=await hash(canonical(validateSkills(body)));
  s.sqlite.prepare('INSERT INTO batches VALUES(?,NULL,?,?)').run(digest,'old-worker',1);
  assert.equal((await s.request('/v1/submissions','POST',d.device_token,body)).status,200);
});

test('rate limits are atomic and reset in the next hour',async t=>{
  const s=setup(t),d=await s.enroll();
  const responses=await Promise.all(Array.from({length:25},()=>s.request('/v1/library','GET',d.device_token)));
  assert.equal(responses.filter(r=>r.status===200).length,20);
  assert.equal(responses.filter(r=>r.status===429).length,5);
  s.sqlite.prepare('UPDATE rate SET hour=0').run();
  assert.equal((await s.request('/v1/library','GET',d.device_token)).status,200);
});

test('unsafe paths, secrets, binary content, unsupported extensions and duplicates fail closed',()=>{
  for (const [path,text] of [['../secret.txt','x'],['bad.exe','x'],['secret.md','password=example'],['user.md','C:\\Users\\Ehab\\private'],['key.md','-----BEGIN RSA PRIVATE KEY-----'],['x.md','\0'],['.env','x'],['CON.md','x'],['dir /x.md','x'],['bad\n.md','x'],['skill.md','duplicate']]) {
    assert.throws(()=>validateSkills({skills:[{...skill,files:{...skill.files,[path]:text}}]}),path);
  }
  assert.throws(()=>validateSkills({skills:[skill,skill]}));
  assert.throws(()=>validateSkills({skills:[{...skill,files:{'SKILL.md':'name: wrong'}}]}));
  assert.throws(()=>validateSkills({skills:[{...skill,files:{...skill.files,'big.md':'x'.repeat(256*1024+1)}}]}));
});

test('content rejection and streaming size limit never call GitHub',async t=>{
  const s=setup(t),d=await s.enroll();
  const invalid=await s.request('/v1/submissions','POST',d.device_token,{skills:[{...skill,files:{...skill.files,'bad.md':'api_key=secret'}}]});
  assert.equal(invalid.status,422);
  const req=new Request('https://test.local/v1/submissions',{method:'POST',headers:{Authorization:'Bearer '+d.device_token},body:'x'.repeat(MAX_BODY+1)});
  assert.equal((await handle(req,s.env,s.backend)).status,413);
  assert.equal(s.backend.calls,0);
});

test('missing secrets fail closed and administrator status verifies library separately',async t=>{
  const s=setup(t);
  assert.equal((await s.request('/health')).status,200);
  assert.equal((await s.request('/admin/status','GET',admin)).status,200);
  s.backend.library=async()=>{throw new Error('private-token');};
  assert.equal((await s.request('/admin/status','GET',admin)).status,502);
  delete s.env.GITHUB_PRIVATE_KEY;
  assert.equal((await s.request('/health')).status,503);
});

test('configuration diagnostics identify the requirement without leaking a secret',async t=>{
  const s=setup(t);
  s.env.ADMIN_TOKEN='short-test-secret';
  let response=await s.request('/health');
  assert.equal(response.status,503);
  let message=await response.text();
  assert.ok(message.includes('ADMIN_TOKEN'));
  assert.ok(!message.includes(s.env.ADMIN_TOKEN));
  s.env.ADMIN_TOKEN=' '.repeat(40);
  assert.equal((await s.request('/health')).status,503);
  s.env.ADMIN_TOKEN=admin;
  s.env.GITHUB_PRIVATE_KEY='';
  response=await s.request('/health');
  assert.equal(response.status,503);
  assert.ok((await response.text()).includes('GITHUB_PRIVATE_KEY'));
});

test('GitHub downloaded PKCS#1 key signs a valid short-lived App JWT',async()=>{
  const {privateKey,publicKey}=generateKeyPairSync('rsa',{modulusLength:2048});
  const jwt=await appJWT({GITHUB_PRIVATE_KEY:privateKey.export({format:'pem',type:'pkcs1'}),GITHUB_APP_ID:'5506370'});
  const [head,claims,sig]=jwt.split('.');
  assert.ok(verify('RSA-SHA256',Buffer.from(head+'.'+claims),publicKey,Buffer.from(sig,'base64url')));
  const payload=JSON.parse(Buffer.from(claims,'base64url'));
  assert.equal(payload.iss,'5506370');
  assert.equal(payload.exp-payload.iat,600);
  const pem=privateKey.export({format:'pem',type:'pkcs1'});
  for (const encoded of [pem.replaceAll('\n','\\n'),JSON.stringify(pem)]) {
    const [h,c,s]= (await appJWT({GITHUB_PRIVATE_KEY:encoded,GITHUB_APP_ID:'5506370'})).split('.');
    assert.ok(verify('RSA-SHA256',Buffer.from(h+'.'+c),publicKey,Buffer.from(s,'base64url')));
  }
});

test('GitHub mutations only create intake branches and draft PRs; race reuses PR',async()=>{
  const gh=new GitHub({GITHUB_REPOSITORY:'owner/repo'});
  gh.library=async()=>({skills:{},commit:'head',treeSha:'tree',tree:[]});
  const calls=[];
  gh.request=async(method,path,body)=>{
    calls.push({method,path,body});
    if(path.includes('/pulls?'))return [];
    if(path.includes('/git/ref/'))return null;
    if(path.endsWith('/git/trees'))return {sha:'new-tree'};
    if(path.endsWith('/git/commits'))return {sha:'new-commit'};
    if(path.endsWith('/pulls'))return {html_url:url};
    return {};
  };
  assert.equal(await gh.submit({[skill.name]:skill.files},'f'.repeat(64)),url);
  const pr=calls.find(c=>c.path.endsWith('/pulls')).body;
  assert.equal(pr.draft,true);assert.equal(pr.base,'main');
  assert.match(calls.find(c=>c.path.endsWith('/git/refs')).body.ref,/^refs\/heads\/skill-intake\/central-/);
  assert.ok(calls.every(c=>!c.path.includes('/merge')&&!c.path.includes('/releases')));
  let lookups=0;
  gh.existing=async()=>++lookups===1?undefined:url;
  gh.request=async(method,path)=>{if(path.includes('/git/ref/'))return {object:{sha:'existing'}};throw new Error('PR raced');};
  assert.equal(await gh.submit({[skill.name]:skill.files},'e'.repeat(64)),url);
});

test('approved library uses main, batches blob reads, skips symlinks and rejects partial GraphQL responses',async()=>{
  const gh=new GitHub({GITHUB_REPOSITORY:'owner/repo'});
  const item={path:'.agents/skills/revit-check/SKILL.md',sha:'blob',mode:'100644',type:'blob',size:Buffer.byteLength(skill.files['SKILL.md'])};
  const calls=[];
  gh.request=async(method,path)=>{
    calls.push(path);
    if(path.includes('/git/ref/heads/main'))return {object:{sha:'head'}};
    if(path.includes('/git/commits/'))return {tree:{sha:'tree'}};
    if(path.includes('/git/trees/'))return {tree:[item,{...item,mode:'120000',path:'.agents/skills/revit-check/link.md'}]};
    if(path==='/graphql')return {data:{repository:{b0:{text:skill.files['SKILL.md'],isBinary:false,byteSize:item.size}}}};
    throw new Error('unexpected endpoint');
  };
  assert.deepEqual((await gh.library()).skills,{[skill.name]:skill.files});
  assert.equal(calls.filter(p=>p==='/graphql').length,1);
  assert.equal(calls.length,4);
  gh.cached=null;
  const normal=gh.request;
  gh.request=(method,path)=>path==='/graphql'?{errors:[{message:'upstream private error'}]}:normal(method,path);
  await assert.rejects(gh.library(),/blob lookup failed/);
});

test('library reads category folders and legacy flat skills, and keeps names unique',async()=>{
  const gh=new GitHub({GITHUB_REPOSITORY:'owner/repo'});
  const text=n=>`---\nname: ${n}\n---\nGuidance.`;
  const files={'.agents/skills/revit/revit-a/SKILL.md':text('revit-a'),'.agents/skills/revit/revit-a/refs/x.md':'x',
    '.agents/skills/autocad/acad-b/SKILL.md':text('acad-b'),'.agents/skills/legacy-c/SKILL.md':text('legacy-c'),
    '.agents/skills/3ds-max/README.md':'# 3ds Max','.agents/skills/README.md':'# catalog'};
  const serve=list=>{
    const tree=Object.entries(list).map(([path,body],i)=>({path,sha:'s'+i,mode:'100644',type:'blob',size:Buffer.byteLength(body)}));
    gh.cached=null;
    gh.request=async(method,path,body)=>{
      if(path.includes('/git/ref/heads/main'))return {object:{sha:'head'+Object.keys(list).length}};
      if(path.includes('/git/commits/'))return {tree:{sha:'tree'}};
      if(path.includes('/git/trees/'))return {tree};
      if(path==='/graphql'){const ids=[...body.query.matchAll(/b(\d+): object\(oid:"s(\d+)"\)/g)];return {data:{repository:Object.fromEntries(ids.map(([,b,s])=>[`b${b}`,{text:Object.values(list)[s],isBinary:false,byteSize:Buffer.byteLength(Object.values(list)[s])}]))}};}
      throw new Error('unexpected '+path);
    };
  };
  serve(files);
  const lib=await gh.library();
  assert.deepEqual(Object.keys(lib.skills).sort(),['acad-b','legacy-c','revit-a']);
  assert.deepEqual({...lib.skills['revit-a']},{'SKILL.md':text('revit-a'),'refs/x.md':'x'});
  assert.deepEqual({...lib.categories},{'revit-a':'revit','acad-b':'autocad','legacy-c':null});
  serve({...files,'.agents/skills/general/revit-a/SKILL.md':text('revit-a')});
  await assert.rejects(gh.library(),/unique across categories/);
});

test('submissions land in the category folder and move a skill out of its old place',async()=>{
  assert.equal(submissionCategory('x','---\nname: x\ncategory: branding-ci\n---'),'branding-ci');
  assert.equal(submissionCategory('revit-new',''),'revit');
  assert.equal(submissionCategory('acad-thing',''),'autocad');
  assert.equal(submissionCategory('linkedin-profile-optimizer',''),'linkedin-marketing');
  assert.equal(submissionCategory('quote-maker','','general'),'general','an approved skill keeps its folder');
  assert.equal(submissionCategory('quote-maker','---\ncategory: nonsense\n---'),'uncategorized');
  const gh=new GitHub({GITHUB_REPOSITORY:'owner/repo'});
  gh.library=async()=>({skills:{},categories:{'old-one':null},locations:{'old-one':'old-one'},commit:'head',treeSha:'tree',
    tree:[{path:'.agents/skills/old-one/SKILL.md',type:'blob',mode:'100644'},{path:'.agents/skills/old-one/stale.md',type:'blob',mode:'100644'}]});
  let edits;
  gh.request=async(method,path,body)=>{
    if(path.includes('/pulls?'))return [];
    if(path.includes('/git/ref/'))return null;
    if(path.endsWith('/git/trees')){edits=body.tree;return {sha:'t'};}
    if(path.endsWith('/git/commits'))return {sha:'c'};
    if(path.endsWith('/pulls'))return {html_url:url};
    return {};
  };
  await gh.submit({'old-one':{'SKILL.md':'---\nname: old-one\ncategory: autocad\n---\nx'},'linkedin-profile-optimizer':{'SKILL.md':'---\nname: linkedin-profile-optimizer\n---\nx'}},'d'.repeat(64));
  const written=edits.filter(e=>e.content!==undefined).map(e=>e.path).sort();
  assert.deepEqual(written,['.agents/skills/autocad/old-one/SKILL.md','.agents/skills/linkedin-marketing/linkedin-profile-optimizer/SKILL.md']);
  assert.deepEqual(edits.filter(e=>e.sha===null).map(e=>e.path).sort(),['.agents/skills/old-one/SKILL.md','.agents/skills/old-one/stale.md']);
});

test('skill category must be a known folder',()=>{
  assert.ok(validateSkills({skills:[{name:'a-b',files:{'SKILL.md':'---\nname: a-b\ncategory: revit\n---'}}]}));
  assert.throws(()=>validateSkills({skills:[{name:'a-b',files:{'SKILL.md':'---\nname: a-b\ncategory: games\n---'}}]}));
  assert.equal(locateSkillFile('revit/revit-a/SKILL.md').category,'revit');
  assert.equal(locateSkillFile('revit/README.md'),null);
  assert.equal(locateSkillFile('legacy-c/refs/y.md').path,'refs/y.md');
});

const office = {'CF-Connecting-IP':'203.0.113.7'};
async function joinAs(s,profile=person,headers=office) {
  const response=await s.request('/v1/enroll','POST',join,profile,headers);
  assert.equal(response.status,200,await response.clone().text());
  return response.json();
}

test('team join creates a working device with profile and IP; the code is checked',async t=>{
  const s=setup(t);
  assert.equal((await s.request('/v1/enroll','POST','wrong-code-wrong-code-wrong-code-x',person,office)).status,403);
  assert.equal((await s.request('/v1/enroll','POST',admin,person,office)).status,403);
  const d=await joinAs(s);
  assert.match(d.device_id,/^[a-f0-9]{32}$/);
  assert.match(d.device_token,/^[A-Za-z0-9_-]{40,100}$/);
  const row=s.sqlite.prepare('SELECT * FROM devices WHERE id=?').get(d.device_id);
  assert.equal(row.source,'join');assert.equal(row.person_name,'Ahmed Ali');assert.equal(row.email,'ahmed.ali@example.com');
  assert.equal(row.pc_name,'DESK-07');assert.equal(row.windows_user,'ahmed');assert.equal(row.enroll_ip,'203.0.113.7');
  assert.equal(row.label,'Ahmed Ali (DESK-07)');assert.ok(row.created_at>0);assert.equal(row.terms_version,'2026-10-30');
  assert.ok(!Object.values(row).includes(d.device_token));
  assert.equal((await s.request('/v1/library','GET',d.device_token)).status,200);
});

test('team join validates the profile and is disabled without a strong JOIN_CODE',async t=>{
  const s=setup(t);
  for (const bad of [{...person,name:''},{...person,name:'x'.repeat(81)},{...person,name:'<script>'},{...person,email:'not-an-email'},
    {...person,pc_name:'bad pc'},{...person,windows_user:'a\\b'},{...person,extra:'field'},{...person,connector_version:'1.0 beta'},
    {...person,terms_version:'<script>'},{...person,terms_version:'x'.repeat(21)}]) {
    const r=await s.request('/v1/enroll','POST',join,bad,office);
    assert.equal(r.status,422,JSON.stringify(bad));
    assert.ok((await r.json()).detail);
  }
  assert.equal(s.sqlite.prepare('SELECT COUNT(*) AS n FROM devices').get().n,0);
  s.env.JOIN_CODE='short';
  const r=await s.request('/v1/enroll','POST',join,person,office);
  assert.equal(r.status,503);
  assert.ok(!(await r.text()).includes('short'));
  delete s.env.JOIN_CODE;
  assert.equal((await s.request('/v1/enroll','POST',join,person,office)).status,503);
  assert.equal((await s.request('/health')).status,200,'other routes keep working without JOIN_CODE');
});

test('wrong join codes are cut off per IP while a shared office can still join',async t=>{
  const s=setup(t);
  for (let i=0;i<10;i++) assert.equal((await s.request('/v1/enroll','POST','guess-'+i+'-'.repeat(40),person,office)).status,403);
  assert.equal((await s.request('/v1/enroll','POST',join,person,office)).status,429,'even the right code waits after 10 failures');
  assert.equal((await s.request('/v1/enroll','POST',join,person,{'CF-Connecting-IP':'198.51.100.9'})).status,200,'other addresses unaffected');
  s.sqlite.prepare("UPDATE limits SET hour=0 WHERE key LIKE 'joinfail:%'").run();
  for (let i=0;i<25;i++) await joinAs(s,{...person,pc_name:'PC-'+i});
});

test('device calls record last seen, IP and connector version',async t=>{
  const s=setup(t),d=await joinAs(s);
  s.sqlite.prepare('UPDATE devices SET last_seen=1').run();
  assert.equal((await s.request('/v1/library','GET',d.device_token,undefined,{'CF-Connecting-IP':'198.51.100.20','X-Connector-Version':'1.0.0-beta.18'})).status,200);
  let row=s.sqlite.prepare('SELECT last_seen,last_ip,connector_version,enroll_ip FROM devices').get();
  assert.ok(row.last_seen>1);assert.equal(row.last_ip,'198.51.100.20');assert.equal(row.connector_version,'1.0.0-beta.18');assert.equal(row.enroll_ip,'203.0.113.7');
  await s.request('/v1/library','GET',d.device_token,undefined,{'X-Connector-Version':'<bad>'});
  row=s.sqlite.prepare('SELECT last_ip,connector_version FROM devices').get();
  assert.equal(row.last_ip,'198.51.100.20','missing header keeps the last known IP');assert.equal(row.connector_version,'1.0.0-beta.18');
});

test('usage is validated, aggregated per day, and has its own budget',async t=>{
  const s=setup(t),d=await joinAs(s);
  const today=new Date().toISOString().slice(0,10);
  const events=[{kind:'skill',name:'revit-read-write',day:today,count:3},{kind:'tool',name:'list_levels',day:today,count:2}];
  let r=await s.request('/v1/usage','POST',d.device_token,{events});
  assert.equal(r.status,200);assert.equal((await r.json()).accepted,2);
  await s.request('/v1/usage','POST',d.device_token,{events:[{kind:'skill',name:'revit-read-write',day:today,count:4}]});
  assert.equal(s.sqlite.prepare("SELECT count FROM usage WHERE kind='skill'").get().count,7);
  // Failed calls: "errors" is optional, adds up per day, and can never exceed the count.
  await s.request('/v1/usage','POST',d.device_token,{events:[{kind:'tool',name:'list_levels',day:today,count:3,errors:1}]});
  await s.request('/v1/usage','POST',d.device_token,{events:[{kind:'tool',name:'list_levels',day:today,count:2,errors:2}]});
  assert.deepEqual({...s.sqlite.prepare("SELECT count,errors FROM usage WHERE name='list_levels'").get()},{count:7,errors:3});
  assert.equal(s.sqlite.prepare("SELECT errors FROM usage WHERE kind='skill'").get().errors,0,'clients that send no errors keep 0');
  for (const bad of [{...events[0],errors:4},{...events[0],errors:-1},{...events[0],errors:1.5},{...events[0],errors:'1'}])
    assert.equal((await s.request('/v1/usage','POST',d.device_token,{events:[bad]})).status,422);
  for (const bad of [{events:[]},{events:[{...events[0],kind:'file'}]},{events:[{...events[0],name:'C:\\drawings\\x.dwg'}]},{events:[{...events[0],day:'2000-01-01'}]},
    {events:[{...events[0],count:0}]},{events:[{...events[0],args:'secret'}]},{events:Array(501).fill(events[0])}])
    assert.equal((await s.request('/v1/usage','POST',d.device_token,bad)).status,422);
  assert.equal((await s.request('/v1/usage','POST','not-a-device-token',{events})).status,401);
  // 15 calls so far (4 accepted, 11 rejected) count toward 30 an hour, separate from the 20/hour library budget.
  for (let i=0;i<15;i++) assert.equal((await s.request('/v1/usage','POST',d.device_token,{events})).status,200);
  assert.equal((await s.request('/v1/library','GET',d.device_token)).status,200);
  assert.equal((await s.request('/v1/usage','POST',d.device_token,{events})).status,429);
});

test('admin overview lists people, usage, submissions; block and unblock work',async t=>{
  const s=setup(t),d=await joinAs(s),old=await s.enroll();
  const today=new Date().toISOString().slice(0,10);
  await s.request('/v1/usage','POST',d.device_token,{events:[{kind:'skill',name:'revit-read-write',day:today,count:5}]});
  s.sqlite.prepare("INSERT INTO usage(device,kind,name,day,count,errors) VALUES(?,?,?,?,?,0)").run(d.device_id,'skill','ancient-skill','2000-01-01',9);
  assert.equal((await s.request('/v1/submissions','POST',d.device_token,body)).status,200);
  assert.equal((await s.request('/admin/api/overview','GET',d.device_token)).status,403);
  assert.equal((await s.request('/admin/api/overview','GET',join)).status,403);
  const r=await s.request('/admin/api/overview','GET',admin);
  assert.equal(r.status,200);
  const o=await r.json();
  const text=JSON.stringify(o);
  assert.ok(!text.includes(d.device_token)&&!text.includes(old.device_token)&&!text.includes('"hash"'),'no credentials in the overview');
  const me=o.devices.find(x=>x.id===d.device_id);
  assert.equal(me.person_name,'Ahmed Ali');assert.equal(me.last_ip,'203.0.113.7');assert.equal(me.active,1);
  assert.equal(o.devices.find(x=>x.id===old.device_id).source,'admin');
  const used=o.usage.find(u=>u.device===d.device_id&&u.name==='revit-read-write');
  assert.equal(used.last7,5);assert.equal(used.last30,5);
  assert.ok(!o.usage.some(u=>u.name==='ancient-skill'));
  assert.equal(s.sqlite.prepare("SELECT COUNT(*) AS n FROM usage WHERE name='ancient-skill'").get().n,0,'usage older than 180 days is deleted');
  assert.deepEqual(o.submissions[0].skills,['revit-check']);assert.equal(o.submissions[0].status,'submitted_for_approval');
  assert.equal((await s.request('/admin/devices/'+d.device_id+'/block','POST',d.device_token)).status,403);
  assert.equal((await s.request('/admin/devices/'+d.device_id+'/block','POST',admin)).status,200);
  assert.equal((await s.request('/v1/library','GET',d.device_token)).status,401);
  assert.equal((await s.request('/v1/usage','POST',d.device_token,{events:[{kind:'skill',name:'x',day:today,count:1}]})).status,401);
  assert.equal((await s.request('/admin/devices/'+d.device_id+'/unblock','POST',admin)).status,200);
  assert.equal((await s.request('/v1/library','GET',d.device_token)).status,200);
  assert.equal((await s.request('/admin/devices/'+'0'.repeat(32)+'/block','POST',admin)).status,404);
});

test('dashboard page is static, locked down and renders data only as text',async t=>{
  const s=setup(t);
  await joinAs(s,{...person,name:'<img src=x onerror=alert(1)>'.replace(/[<>]/g,'')});
  for (const [path,type] of [['/admin','text/html'],['/admin/app.js','text/javascript'],['/admin/app.css','text/css']]) {
    const r=await s.request(path);
    assert.equal(r.status,200);
    assert.ok(r.headers.get('Content-Type').startsWith(type));
    assert.match(r.headers.get('Content-Security-Policy'),/default-src 'none'; script-src 'self'/);
    assert.equal(r.headers.get('Cache-Control'),'no-store');
    assert.equal(r.headers.get('X-Frame-Options'),'DENY');
    const text=await r.text();
    assert.ok(!text.includes(admin)&&!text.includes(join)&&!text.includes('Ahmed'),'no secrets or data in static assets');
  }
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function/.test(DASHBOARD_JS),'no HTML injection sinks');
  assert.ok(!/<script>[^<]/.test(DASHBOARD_HTML),'no inline script');
  assert.ok(DASHBOARD_CSS.includes('[hidden]{display:none!important}'),'signed-out header buttons stay hidden');
  assert.equal((await s.request('/admin','POST')).status,404);
});

// Review endpoints against real SQLite; GitHub is a stub that records writes.
function reviewBackend(s, items) {
  const pr = {number:7,url,submitted_at:100,head_sha:'h7',proposed:items.map(i=>i.name),already_approved:[],outside:[]};
  Object.assign(s.backend, {approved:[], closed:[],
    async reviewQueue() { return {library_commit:'main',more:false,prs:[pr],items}; },
    async reviewOne(n) { return n===7 ? {pr,items} : null; },
    async approveSkill(item,category) { if (this.failNext) { this.failNext=false; throw new Error('boom'); } this.approved.push([item.name,category]); return 'c'+this.approved.length; },
    async closeIntake(n,summary) { this.closed.push([n,summary]); }});
  return s.backend;
}
const pending = (name,extra={}) => ({pr:7,pr_url:url,head_sha:'h7',submitted_at:100,name,category:'autocad',key:'k-'+name,approved_key:'none',
  status:'new',stale:false,folder:'autocad/'+name,approved_folder:null,head_files:{'SKILL.md':'s'},files:[],checks:{blocked:[],flags:[]},...extra});
const decide = (s,u,decision,extra={}) => s.request('/admin/api/reviews/decide','POST',admin,{pr:u.pr,skill:u.name,decision,head_sha:u.head_sha,key:u.key,approved_key:u.approved_key,category:u.category,...extra});

test('review queue groups uploads by category and names the sender, never the email',async t=>{
  const s=setup(t),d=await joinAs(s);
  assert.equal((await s.request('/v1/submissions','POST',d.device_token,body)).status,200);
  reviewBackend(s,[pending('acad-x'),pending('revit-y',{category:'revit'}),pending('loose',{category:'uncategorized'})]);
  assert.equal((await s.request('/admin/api/reviews','GET',d.device_token)).status,403);
  const r=await s.request('/admin/api/reviews','GET',admin);
  assert.equal(r.status,200);
  const q=await r.json();
  assert.deepEqual(q.categories.map(c=>c.category),['revit','autocad','uncategorized']);
  assert.equal(q.categories[1].skills[0].uploads[0].sender.name,'Ahmed Ali');
  assert.equal(q.prs[0].sender.name,'Ahmed Ali');
  assert.deepEqual(q.prs[0].undecided,['acad-x','revit-y','loose']);
  assert.ok(!JSON.stringify(q).toLowerCase().includes('ahmed.ali@example.com'),'email is not sent to the page');
  assert.ok(!q.categories_available.includes('uncategorized'));
  assert.equal(q.pending,3);
});

test('each skill is approved or rejected on its own; the upload closes once all are decided',async t=>{
  const s=setup(t);
  const flagged=pending('flagged',{checks:{blocked:[],flags:[{kind:'secret',path:'SKILL.md',line:3,text:'api_key'}]}});
  const items=[pending('acad-x'),pending('revit-y',{category:'revit'}),flagged,pending('broken',{checks:{blocked:['bad'],flags:[]}})];
  const gh=reviewBackend(s,items);
  assert.equal((await decide(s,items[0],'approve',{head_sha:'old'})).status,409,'a changed upload must be reviewed again');
  assert.equal((await decide(s,items[0],'approve',{category:'uncategorized'})).status,422,'approval needs a real category');
  assert.equal((await decide(s,flagged,'approve')).status,422,'flagged lines need the owner\'s acknowledgement');
  assert.equal((await decide(s,items[3],'approve')).status,422,'a failed required check blocks approval');
  assert.equal((await s.request('/admin/api/reviews/decide','POST',join,{})).status,403);
  gh.failNext=true;
  assert.equal((await decide(s,items[0],'approve')).status,502);
  let r=await decide(s,items[0],'approve',{category:'general'});
  assert.equal(r.status,200,'a failed GitHub write releases the decision for retry');
  assert.deepEqual(await r.json(),{pr:7,skill:'acad-x',decision:'approve',commit:'c1',closed:false});
  assert.deepEqual(gh.approved,[['acad-x','general']],'only the one skill is written, in the chosen category');
  assert.equal((await decide(s,items[0],'approve')).status,409,'decided once only');
  assert.equal((await decide(s,items[1],'reject')).status,200);
  assert.equal((await decide(s,flagged,'approve',{accept_flags:true})).status,200);
  assert.equal((await s.request('/admin/api/reviews/close','POST',admin,{pr:7})).status,409,'cannot close while a skill waits');
  r=await decide(s,items[3],'reject');
  assert.equal((await r.json()).closed,true);
  assert.deepEqual(gh.approved.map(a=>a[0]),['acad-x','flagged'],'rejected skills never reach main');
  assert.equal(gh.closed.length,1);
  assert.match(gh.closed[0][1],/`revit-y`: rejected/);
  assert.match(gh.closed[0][1],/`acad-x`: approved into `general`/);
  const q=await (await s.request('/admin/api/reviews','GET',admin)).json();
  assert.equal(q.pending,0);
  assert.deepEqual(s.sqlite.prepare('SELECT skill,decision,commit_sha FROM review_decisions ORDER BY skill').all().map(r=>({...r})),
    [{skill:'acad-x',decision:'approve',commit_sha:'c1'},{skill:'broken',decision:'reject',commit_sha:null},{skill:'flagged',decision:'approve',commit_sha:'c2'},{skill:'revit-y',decision:'reject',commit_sha:null}]);
});

test('content rejected before stays hidden in later uploads, and such an upload can be closed',async t=>{
  const s=setup(t);
  const gh=reviewBackend(s,[pending('revit-y')]);
  assert.equal((await decide(s,pending('revit-y'),'reject')).status,200);
  assert.equal(gh.closed.length,1);
  // The same content arrives again in a later upload.
  const later={...pending('revit-y'),pr:8,pr_url:url.replace('/7','/8')};
  s.backend.reviewQueue=async()=>({library_commit:'main',more:false,prs:[{number:8,url:later.pr_url,submitted_at:200,head_sha:'h7',proposed:['revit-y'],already_approved:[],outside:[]}],items:[later]});
  s.backend.reviewOne=async n=>n===8?{pr:{number:8},items:[later]}:null;
  const q=await (await s.request('/admin/api/reviews','GET',admin)).json();
  assert.equal(q.pending,0);assert.equal(q.hidden_rejected,1);
  assert.deepEqual(q.prs[0].undecided,[]);
  assert.equal((await s.request('/admin/api/reviews/close','POST',admin,{pr:8})).status,200);
  assert.match(gh.closed[1][1],/rejected earlier with the same content/);
  assert.equal((await s.request('/admin/api/reviews/close','POST',admin,{pr:99})).status,409,'only open intake PRs can be closed here');
});
