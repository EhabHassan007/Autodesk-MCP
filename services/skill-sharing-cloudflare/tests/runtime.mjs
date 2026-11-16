// Executes the production bundle under workerd, with real local D1 and fake
// GitHub network responses. No live account, GitHub key, or token is used.
import assert from 'node:assert/strict';
import { readFile, readdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { generateKeyPairSync, verify } from 'node:crypto';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const {privateKey,publicKey}=generateKeyPairSync('rsa',{modulusLength:2048});
const directory=await mkdtemp(join(tmpdir(),'autodesk-d1-test-'));
const admin='local-test-administrator-token-32-characters';
const joinCode='local-test-team-join-code-at-least-32-chars';
const content='---\nname: revit-check\n---\nRead document information.';
let tokenChecks=0, draftPRs=0;
const options={
  modules:true,scriptPath:'.wrangler/check/index.js',compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  d1Databases:{DB:'test-database'},d1Persist:directory,
  bindings:{ADMIN_TOKEN:admin,JOIN_CODE:joinCode,GITHUB_PRIVATE_KEY:privateKey.export({type:'pkcs1',format:'pem'}),GITHUB_APP_ID:'5506370',GITHUB_INSTALLATION_ID:'176074887',GITHUB_REPOSITORY:'owner/repo',GITHUB_BASE_BRANCH:'main'},
  async outboundService(request) {
    const u=new URL(request.url),p=u.pathname;
    assert.equal(u.origin,'https://api.github.com');
    const reply=(body,status=200)=>Response.json(body,{status});
    if(p==='/app/installations/176074887/access_tokens') {
      const [head,claims,sig]=request.headers.get('Authorization').slice(7).split('.');
      assert.ok(verify('RSA-SHA256',Buffer.from(head+'.'+claims),publicKey,Buffer.from(sig,'base64url')));
      assert.equal(JSON.parse(Buffer.from(claims,'base64url')).iss,'5506370');
      const data=await request.json();
      assert.deepEqual(data.repositories,['repo']);
      tokenChecks++;
      return reply({token:'fake-installation-token',expires_at:new Date(Date.now()+3600000).toISOString()},201);
    }
    assert.equal(request.headers.get('Authorization'),'Bearer fake-installation-token');
    if(p.endsWith('/git/ref/heads/main'))return reply({object:{sha:'head'}});
    if(p.endsWith('/git/commits/head'))return reply({tree:{sha:'tree'}});
    if(p.endsWith('/git/trees/tree'))return reply({tree:[{path:'.agents/skills/revit-check/SKILL.md',type:'blob',mode:'100644',sha:'blob',size:Buffer.byteLength(content)}]});
    if(p==='/graphql')return reply({data:{repository:{b0:{text:content,isBinary:false,byteSize:Buffer.byteLength(content)}}}});
    if(p.endsWith('/pulls') && request.method==='GET')return reply([]);
    if(p.includes('/git/ref/heads/skill-intake/'))return reply({message:'Not Found'},404);
    if(p.endsWith('/git/trees'))return reply({sha:'proposed-tree'},201);
    if(p.endsWith('/git/commits'))return reply({sha:'proposed-commit'},201);
    if(p.endsWith('/git/refs')) {
      assert.match((await request.json()).ref,/^refs\/heads\/skill-intake\/central-/);
      return reply({},201);
    }
    if(p.endsWith('/pulls') && request.method==='POST') {
      const data=await request.json();assert.equal(data.draft,true);assert.equal(data.base,'main');
      draftPRs++;
      return reply({html_url:'https://github.com/owner/repo/pull/7'},201);
    }
    throw new Error('Unexpected upstream endpoint: '+p);
  }
};
let mf;
try {
  mf=new Miniflare({...convertV4MiniflareOptions(options),resourcePersistencePath:directory});
  const db=await mf.getD1Database('DB');
  // D1 exec accepts one statement per line. Production migrations use Wrangler.
  for (const file of (await readdir(new URL('../migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort()) {
    const schema=await readFile(new URL('../migrations/'+file,import.meta.url),'utf8');
    await db.batch(schema.split(';').filter(s=>s.trim()).map(s=>db.prepare(s)));
  }
  const call=(path,method='GET',token,body,extra={})=>mf.dispatchFetch('https://worker.test'+path,{method,headers:{...(token?{Authorization:'Bearer '+token}:{}),...extra},body:body===undefined?undefined:JSON.stringify(body)});
  assert.equal((await call('/health')).status,200);
  const enrolled=await call('/admin/devices','POST',admin,{label:'Test PC'});
  assert.equal(enrolled.status,200);
  const device=await enrolled.json();
  const library=await call('/v1/library','GET',device.device_token);
  assert.equal(library.status,200,await library.clone().text());
  assert.equal((await library.json()).skills[0].files['SKILL.md'],content);
  const submission={skills:[{name:'new-skill',files:{'SKILL.md':'---\nname: new-skill\n---\nA harmless test.'}}]};
  const sent=await call('/v1/submissions','POST',device.device_token,submission);
  assert.equal(sent.status,200,await sent.clone().text());
  assert.equal((await sent.json()).status,'submitted_for_approval');
  await mf.dispose();
  mf=new Miniflare({...convertV4MiniflareOptions(options),resourcePersistencePath:directory});
  // A fresh isolate has no token/library cache. D1 credentials and ledger survive.
  const duplicate=await call('/v1/submissions','POST',device.device_token,submission);
  assert.equal(duplicate.status,200);
  assert.equal((await duplicate.json()).status,'already_submitted');
  assert.equal((await call('/v1/library','GET',device.device_token)).status,200);
  assert.equal(draftPRs,1);assert.equal(tokenChecks,2);
  assert.equal((await call('/admin/devices/'+device.device_id,'DELETE',admin)).status,200);
  assert.equal((await call('/v1/library','GET',device.device_token)).status,401);
  // Team join, usage report and dashboard overview against real D1 (batch upsert included).
  const joined=await call('/v1/enroll','POST',joinCode,{name:'Test Person',email:'test@example.com',pc_name:'TEST-PC',windows_user:'tester',connector_version:'1.0.0-beta.17'},{'CF-Connecting-IP':'203.0.113.5'});
  assert.equal(joined.status,200,await joined.clone().text());
  const member=await joined.json();
  const today=new Date().toISOString().slice(0,10);
  const usage=await call('/v1/usage','POST',member.device_token,{events:[{kind:'skill',name:'revit-check',day:today,count:2},{kind:'tool',name:'list_levels',day:today,count:1}]});
  assert.equal(usage.status,200,await usage.clone().text());
  await call('/v1/usage','POST',member.device_token,{events:[{kind:'skill',name:'revit-check',day:today,count:3}]});
  // Connector error report: cleaned again on the service (this PC's names included) and keyed in real D1.
  const failure={tool:'drawing_info',product:'autocad',code:'error',message:'Could not open C:\\Users\\tester\\Tower.dwg on TEST-PC',outcome:'failed',day:today,count:2};
  const reported=await call('/v1/failures','POST',member.device_token,{events:[failure,{...failure,outcome:'recovered',count:1}]},{'X-Connector-Version':'1.2.0'});
  assert.equal(reported.status,200,await reported.clone().text());
  const overview=await (await call('/admin/api/overview','GET',admin)).json();
  assert.deepEqual(overview.failures.map(f=>[f.message,f.failed,f.recovered,f.versions.join()]),[['Could not open <path> on <pc>',2,1,'1.2.0']]);
  const person=overview.devices.find(d=>d.id===member.device_id);
  assert.equal(person.person_name,'Test Person');assert.equal(person.enroll_ip,'203.0.113.5');
  assert.equal(overview.usage.find(u=>u.device===member.device_id&&u.name==='revit-check').last7,5);
  assert.equal((await call('/admin')).headers.get('Content-Type'),'text/html; charset=utf-8');
  // Review queue against real D1 (review_decisions migration) with no open uploads.
  const reviews=await call('/admin/api/reviews','GET',admin);
  assert.equal(reviews.status,200,await reviews.clone().text());
  assert.equal((await reviews.json()).pending,0);
  assert.equal((await call('/admin/devices/'+member.device_id+'/block','POST',admin)).status,200);
  assert.equal((await call('/v1/library','GET',member.device_token)).status,401);
  console.log('PASS: workerd + D1 enrollment, PKCS#1 signing, approved library, draft-only submission, restart persistence, deduplication, revocation, team join, usage, error reports, admin overview and skill review queue. GitHub mocked.');
} finally {
  await mf?.dispose();
  await rm(directory,{recursive:true,force:true});
}
