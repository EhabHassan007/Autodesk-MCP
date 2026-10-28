import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { generateKeyPairSync, verify } from 'node:crypto';
import { handle } from '../src/index.mjs';
import { appJWT, GitHub } from '../src/github.mjs';
import { canonical, hash, MAX_BODY, validateSkills } from '../src/validation.mjs';

const admin = 'test-only-admin-token-at-least-32-characters';
const skill = {name:'revit-check',files:{'SKILL.md':'---\nname: revit-check\n---\nRead document information.'}};
const body = {skills:[skill]};
const url = 'https://github.com/owner/repo/pull/7';
test('batch digest matches existing Python service canonical format',async()=>{
  assert.equal(await hash(canonical(validateSkills(body))),'31360d69c755e6a6b2a6ed4c832c9b4a038f096465cac1ad330e3a79785815fc');
  assert.equal(canonical({'𐀀':1,'\uE000':2}),'{"\uE000":2,"𐀀":1}');
});
function setup(t) {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(readFileSync(new URL('../migrations/0001_initial.sql',import.meta.url),'utf8'));
  t.after(()=>sqlite.close());
  const DB = {prepare(sql) {
    const stmt = sqlite.prepare(sql);
    const wrapper = params => ({bind(...values) { return wrapper(values); },async first() { return stmt.get(...params) || null; },async run() { return stmt.run(...params); }});
    return wrapper([]);
  }};
  const env = {DB,ADMIN_TOKEN:admin,GITHUB_PRIVATE_KEY:'fake-test-key',GITHUB_APP_ID:'1',GITHUB_INSTALLATION_ID:'2',GITHUB_REPOSITORY:'owner/repo'};
  const backend = {calls:0, async submit() { this.calls++; return url; }, async library() { return {skills:{[skill.name]:skill.files},commit:'approved-main-commit'}; }};
  const request = (path,method='GET',token,content) => handle(new Request('https://test.local'+path,{method,headers:token?{Authorization:'Bearer '+token}:{},body:content===undefined?undefined:JSON.stringify(content)}),env,backend);
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
