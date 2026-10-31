// Owner review of uploaded skills: grouping, comparison, checks, diff, and the GitHub writes approval makes.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { GitHub } from '../src/github.mjs';
import { compareSkill, groupReviews, lineDiff, reviewChecks, reviewSummary, undecided } from '../src/review.mjs';

const manifest = (name, extra = '') => `---\nname: ${name}\ndescription: Does a thing.\n${extra}---\nSteps.`;
const item = (pr, name, category, extra = {}) => ({pr, pr_url:`https://github.com/owner/repo/pull/${pr}`, name, category, key:'k-'+name, submitted_at:pr*10, ...extra});

test('pending uploads group by category in library order, then by skill, oldest upload first',()=>{
  const items = [item(5,'zeta-tool','general'), item(3,'revit-b','revit'), item(2,'revit-a','revit'), item(4,'revit-a','revit'),
    item(6,'odd','not-a-category'), item(2,'acad-x','autocad'), item(7,'done','general'), item(8,'again','general',{key:'bad'})];
  const senders = {'https://github.com/owner/repo/pull/2':{name:'Ahmed Ali',also:[]}};
  const r = groupReviews(items, {decisions:new Set(['7/done']), rejected:new Set(['again/bad']), senders});
  assert.deepEqual(r.categories.map(c=>c.category), ['revit','autocad','general','uncategorized']);
  assert.deepEqual(r.categories[0].skills.map(s=>s.name), ['revit-a','revit-b']);
  assert.deepEqual(r.categories[0].skills[0].uploads.map(u=>u.pr), [2,4], 'two people sent the same skill: both shown, oldest first');
  assert.equal(r.categories[0].skills[0].uploads[0].sender.name, 'Ahmed Ali');
  assert.equal(r.categories[0].skills[0].uploads[1].sender.name, 'Unknown sender');
  assert.equal(r.categories[3].skills[0].name, 'odd', 'an unknown folder needs a category');
  assert.equal(r.pending, 6);
  assert.equal(r.hidden_rejected, 1, 'content rejected before is hidden, not shown again');
  assert.deepEqual(undecided(items, 7, new Set(['7/done']), new Set()), []);
  assert.deepEqual(undecided(items, 2, new Set(['2/acad-x']), new Set()), ['revit-a']);
  assert.deepEqual(undecided(items, 8, new Set(), new Set(['again/bad'])), []);
});

test('summary comment lists every decision and never claims a merge',()=>{
  const text = reviewSummary([{skill:'a',decision:'approve',category:'autocad'},{skill:'b',decision:'reject',category:null}], ['c']);
  assert.match(text, /`a`: approved into `autocad`/);
  assert.match(text, /`b`: rejected/);
  assert.match(text, /`c`: rejected earlier with the same content/);
  assert.match(text, /closed without merging/);
});

const sha = text => 'sha-'+Buffer.from(text).toString('hex').slice(0,24)+text.length;
const folder = (folderPath, files, category = folderPath.split('/')[0]) =>
  ({folder:folderPath, category, files:Object.fromEntries(Object.entries(files).map(([p,t])=>[p,{sha:sha(t),mode:'100644'}]))});
const texts = (...maps) => Object.fromEntries(maps.flatMap(m=>Object.values(m)).map(t=>[sha(t),t]));

test('a skill is new, changed, moved or unchanged versus the approved copy, with file-level status',()=>{
  const approved = {'SKILL.md':manifest('acad-x'), 'refs/old.md':'old', 'refs/keep.md':'keep'};
  const uploaded = {'SKILL.md':manifest('acad-x')+'\nMore.', 'refs/keep.md':'keep', 'refs/new.md':'new'};
  const r = compareSkill('acad-x', folder('autocad/acad-x', uploaded), folder('autocad/acad-x', approved), texts(uploaded), approved);
  assert.equal(r.status, 'changed');
  assert.deepEqual(r.files.map(f=>[f.path,f.status]), [['SKILL.md','modified'],['refs/keep.md','unchanged'],['refs/new.md','added'],['refs/old.md','removed']]);
  assert.equal(r.files[0].before, approved['SKILL.md']);
  assert.equal(r.files[0].after, uploaded['SKILL.md']);
  assert.deepEqual(r.checks, {blocked:[], flags:[]});
  assert.equal(compareSkill('acad-x', folder('autocad/acad-x', approved), null, texts(approved)).status, 'new');
  assert.equal(compareSkill('acad-x', folder('general/acad-x', approved), folder('autocad/acad-x', approved), texts(approved), approved).status, 'moved');
  assert.equal(compareSkill('acad-x', folder('autocad/acad-x', approved), folder('autocad/acad-x', approved), texts(approved), approved).status, 'unchanged');
});

test('required checks block approval; secrets, personal paths and client data are flagged only on added lines',()=>{
  const before = {'SKILL.md':manifest('acad-x')+'\nContact owner@example.com'};
  const after = {'SKILL.md':before['SKILL.md']+'\napi_key = abc\nOpen C:\\Users\\ahmed\\Desktop\nLink acc://project/1\nShare \\\\server\\jobs'};
  const r = reviewChecks('acad-x', 'autocad', after, before);
  assert.deepEqual(r.blocked, []);
  assert.deepEqual(r.flags.map(f=>[f.kind,f.line]), [['secret',7],['personal-path',8],['client-data',9],['personal-path',10]], 'the approved email line is not flagged again');
  // Double-encoded UTF-8 as seen in intake PR #24: an em dash arriving as mojibake. Real non-ASCII text is not flagged.
  const twice = Buffer.from(Buffer.from('—','utf8').toString('latin1'),'utf8').toString('latin1');
  const encoded = reviewChecks('acad-x','autocad',{'SKILL.md':manifest('acad-x')+'\nStep one '+twice+' read.\nAlso â€” here.\nArabic مرحبا, café — fine.'});
  assert.deepEqual(encoded.flags.map(f=>[f.kind,f.line]), [['encoding',6],['encoding',7]]);
  assert.match(reviewChecks('acad-x','autocad',{'SKILL.md':'---\nname: other\ndescription: x\n---'}).blocked[0], /structure check/);
  assert.ok(reviewChecks('acad-x','autocad',{'SKILL.md':'---\nname: acad-x\n---'}).blocked.some(b=>/description/.test(b)));
  assert.ok(reviewChecks('acad-x','autocad',{'SKILL.md':manifest('acad-x','category: revit\n')}).blocked.some(b=>/category "revit"/.test(b)));
  assert.ok(reviewChecks('acad-x','autocad',{'SKILL.md':manifest('acad-x'),'tool.exe':'x'}).blocked.length, 'unsupported file types fail closed');
  const binary = compareSkill('acad-x', {folder:'autocad/acad-x',category:'autocad',files:{'SKILL.md':{sha:'s1',mode:'100644'},'pic.md':{sha:'s2',mode:'120000'}}}, null, {s1:manifest('acad-x'), s2:null});
  assert.ok(binary.checks.blocked.some(b=>/link/.test(b)) && binary.checks.blocked.some(b=>/binary/.test(b)));
});

test('line diff keeps order, marks additions and removals, and stays bounded on huge files',()=>{
  const d = lineDiff('a\nb\nc\nd', 'a\nc\nx\nd');
  assert.deepEqual(d, [[' ','a'],['-','b'],[' ','c'],['+','x'],[' ','d']]);
  assert.equal(d.filter(r=>r[0]!=='+').map(r=>r[1]).join('\n'), 'a\nb\nc\nd');
  assert.deepEqual(lineDiff(null, 'new'), [['+','new']]);
  const big = Array.from({length:3000}, (_,i)=>'line '+i).join('\n');
  const huge = lineDiff(big, big.replaceAll('line','LINE'));
  assert.equal(huge.length, 6000);
  // The browser receives this function's source, so it must not depend on module scope.
  assert.deepEqual(new Function('return ('+lineDiff.toString()+')')()('x', 'y'), [['-','x'],['+','y']]);
});

// A fake GitHub repository: main, one intake PR based on an older main, and unrelated PRs.
function fakeRepo() {
  const blob = (path, text) => ({path, type:'blob', mode:'100644', sha:sha(text), size:Buffer.byteLength(text), text});
  const v = {
    acad:manifest('acad-x'), acad2:manifest('acad-x')+'\nImproved.',
    stale1:manifest('revit-e'), stale2:manifest('revit-e')+'\nApproved later.', stale3:manifest('revit-e')+'\nUploader edit.',
    same:manifest('revit-same'), fresh:manifest('quote-maker'), moved:manifest('brand-kit'), untouched:manifest('revit-old')
  };
  const base = [blob('.agents/skills/autocad/acad-x/SKILL.md',v.acad), blob('.agents/skills/revit/revit-e/SKILL.md',v.stale1),
    blob('.agents/skills/revit/revit-old/SKILL.md',v.untouched), blob('.agents/skills/general/brand-kit/SKILL.md',v.moved), blob('README.md','readme')];
  const main = [blob('.agents/skills/autocad/acad-x/SKILL.md',v.acad), blob('.agents/skills/revit/revit-e/SKILL.md',v.stale2),
    blob('.agents/skills/revit/revit-old/SKILL.md',v.untouched), blob('.agents/skills/general/brand-kit/SKILL.md',v.moved),
    blob('.agents/skills/revit/revit-same/SKILL.md',v.same), blob('README.md','readme')];
  const head = [blob('.agents/skills/autocad/acad-x/SKILL.md',v.acad2), blob('.agents/skills/revit/revit-e/SKILL.md',v.stale3),
    blob('.agents/skills/revit/revit-old/SKILL.md',v.untouched), blob('.agents/skills/branding-ci/brand-kit/SKILL.md',v.moved),
    blob('.agents/skills/revit/revit-same/SKILL.md',v.same), blob('.agents/skills/uncategorized/quote-maker/SKILL.md',v.fresh), blob('README.md','readme')];
  const all = [...base, ...main, ...head];
  const intake = {number:9, state:'open', title:'Saved skill review', created_at:'2026-10-30T08:00:00Z', head:{ref:'skill-intake/central-abc', sha:'head-commit', repo:{full_name:'owner/repo'}}, base:{ref:'main'}};
  const calls = [];
  const request = async (method, path, body) => {
    calls.push({method, path, body});
    if (path.endsWith('/git/ref/heads/main')) return {object:{sha:'main-commit'}};
    if (path.endsWith('/git/commits/main-commit')) return {tree:{sha:'main-tree'}};
    if (path.endsWith('/git/commits/head-commit')) return {tree:{sha:'head-tree'}, parents:[{sha:'base-commit'}]};
    if (path.includes('/git/trees/main-tree')) return {tree:main};
    if (path.includes('/git/trees/head-tree')) return {tree:head};
    if (path.includes('/git/trees/base-commit')) return {tree:base};
    if (path.includes('/pulls?state=open')) return [intake,
      {...intake, number:10, head:{...intake.head, ref:'feature/x'}},
      {...intake, number:11, head:{...intake.head, repo:{full_name:'someone/fork'}}}];
    if (path.endsWith('/pulls/9')) return intake;
    if (path === '/graphql') {
      const ids = [...body.query.matchAll(/b(\d+): object\(oid:"([^"]+)"\)/g)];
      return {data:{repository:Object.fromEntries(ids.map(([,i,s])=>{const b=all.find(x=>x.sha===s);return [`b${i}`,{text:b.text,isBinary:false,byteSize:b.size}];}))}};
    }
    if (method === 'POST' && path.endsWith('/git/trees')) return {sha:'approved-tree'};
    if (method === 'POST' && path.endsWith('/git/commits')) return {sha:'approved-commit'};
    if (method === 'PATCH') return {};
    if (method === 'POST' && path.endsWith('/comments')) return {};
    throw new Error('unexpected '+method+' '+path);
  };
  const gh = new GitHub({GITHUB_REPOSITORY:'owner/repo'});
  gh.request = request;
  return {gh, calls, v};
}

test('review queue reads only open intake PRs and lists what each proposes against main',async()=>{
  const {gh, calls, v} = fakeRepo();
  const q = await gh.reviewQueue();
  assert.equal(q.prs.length, 1, 'feature branches and forks are not intake');
  const pr = q.prs[0];
  assert.deepEqual(pr.proposed.sort(), ['acad-x','brand-kit','quote-maker','revit-e']);
  assert.deepEqual(pr.already_approved, ['revit-same'], 'already on main: nothing to decide');
  assert.deepEqual(pr.outside, []);
  const by = Object.fromEntries(q.items.map(i=>[i.name,i]));
  assert.ok(!by['revit-old'], 'a skill the upload did not touch is not proposed');
  assert.equal(by['acad-x'].status, 'changed');
  assert.equal(by['quote-maker'].status, 'new');
  assert.equal(by['quote-maker'].category, 'uncategorized');
  assert.equal(by['brand-kit'].status, 'moved');
  assert.equal(by['brand-kit'].approved_folder, 'general/brand-kit');
  assert.equal(by['revit-e'].stale, true, 'main changed after the upload: shown against today\'s approved copy');
  assert.equal(by['revit-e'].files[0].before, v.stale2);
  assert.equal(by['acad-x'].stale, false);
  assert.equal(by['acad-x'].pr_url, 'https://github.com/owner/repo/pull/9');
  assert.equal(by['acad-x'].submitted_at, Date.parse('2026-10-30T08:00:00Z')/1000);
  const graphql = calls.filter(c=>c.path==='/graphql');
  assert.equal(graphql.length, 2, 'one batch for main, one for the changed upload files');
  assert.equal([...graphql[1].body.query.matchAll(/object\(oid/g)].length, 3, 'the moved, unchanged-content file is not downloaded');
  assert.ok(calls.every(c=>c.method==='GET' || c.path==='/graphql'), 'reading the queue never writes');
});

test('approving writes exactly the reviewed blobs for one skill to main, without force',async()=>{
  const {gh, calls} = fakeRepo();
  const {items} = await gh.reviewOne(9);
  const brand = items.find(i=>i.name==='brand-kit');
  assert.equal(await gh.approveSkill(brand, 'branding-ci'), 'approved-commit');
  const tree = calls.find(c=>c.method==='POST' && c.path.endsWith('/git/trees')).body;
  assert.equal(tree.base_tree, 'main-tree');
  assert.deepEqual(tree.tree.map(e=>[e.path, e.sha===null ? 'delete' : 'write']).sort(),
    [['.agents/skills/branding-ci/brand-kit/SKILL.md','write'],['.agents/skills/general/brand-kit/SKILL.md','delete']]);
  assert.equal(tree.tree.find(e=>e.sha!==null).sha, brand.head_files['SKILL.md'], 'uses the uploaded blob, not re-sent text');
  assert.ok(tree.tree.every(e=>e.content===undefined));
  assert.deepEqual(calls.find(c=>c.method==='POST' && c.path.endsWith('/git/commits')).body.parents, ['main-commit']);
  const ref = calls.find(c=>c.method==='PATCH');
  assert.match(ref.path, /\/git\/refs\/heads\/main$/);
  assert.equal(ref.body.force, false);
  assert.ok(calls.every(c=>!/\/merge|\/releases/.test(c.path)), 'never merges the intake PR or publishes');
  // Main moved between review and approval: the non-forced ref update fails and nothing is overwritten.
  const normal = gh.request;
  gh.request = (method, path, body) => method==='PATCH' ? Promise.reject(new Error('GitHub rejected repository access (HTTP 422).')) : normal(method, path, body);
  await assert.rejects(gh.approveSkill(items.find(i=>i.name==='acad-x'), 'autocad'), /Main changed while approving/);
  assert.equal(gh.cached, null, 'a failed approval re-reads main next time');
});

test('closing an upload comments and closes the PR; it never merges',async()=>{
  const {gh, calls} = fakeRepo();
  await gh.closeIntake(9, 'summary');
  assert.deepEqual(calls.map(c=>[c.method,c.path]), [['POST','/repos/owner/repo/issues/9/comments'],['PATCH','/repos/owner/repo/pulls/9']]);
  assert.deepEqual(calls[1].body, {state:'closed'});
});
