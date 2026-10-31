import { createPrivateKey } from 'node:crypto';
import { bytes, canonical, CATEGORIES, EXTENSIONS, hash, MAX_BODY, SKILL_NAME, validateSkills } from './validation.mjs';
import { compareSkill, folderKey } from './review.mjs';

function base64url(value) { return Buffer.from(value).toString('base64url'); }

// Skills live at .agents/skills/<category>/<name>/... ; flat .agents/skills/<name>/... is still read
// so libraries and intake branches from before categories keep working.
export function locateSkillFile(relative) {
  const parts = relative.split('/');
  if (CATEGORIES.has(parts[0])) {
    if (parts.length >= 3 && SKILL_NAME.test(parts[1])) return {name:parts[1],category:parts[0],folder:`${parts[0]}/${parts[1]}`,path:parts.slice(2).join('/')};
    return null;   // a category README or a stray file
  }
  if (parts.length >= 2 && SKILL_NAME.test(parts[0])) return {name:parts[0],category:null,folder:parts[0],path:parts.slice(1).join('/')};
  return null;
}

// Where a submitted skill goes: its own "category:" line, else where the approved copy already is,
// else a guess from the name, else uncategorized/ for the owner to place during review.
export function submissionCategory(name, skillText = '', approvedCategory = null) {
  const declared = /^category:\s*([a-z0-9-]+)\s*$/m.exec(skillText)?.[1];
  if (declared && CATEGORIES.has(declared)) return declared;
  if (approvedCategory && CATEGORIES.has(approvedCategory)) return approvedCategory;
  if (/^revit-/.test(name)) return 'revit';
  if (/^(autocad|acad)-/.test(name)) return 'autocad';
  if (/^(3ds-?max|max)-/.test(name)) return '3ds-max';
  if (/linkedin/.test(name)) return 'linkedin-marketing';
  if (/brand|identity/.test(name)) return 'branding-ci';
  return 'uncategorized';
}

// Skill folders in a git tree: name → {folder, category, files:{path:{sha,mode}}}. A name found in a
// second folder goes to "duplicates" instead.
export function skillFolders(tree) {
  const prefix = '.agents/skills/', found = Object.create(null), duplicates = new Set();
  for (const item of tree) {
    if (item.type !== 'blob' || !item.path.startsWith(prefix)) continue;
    const located = locateSkillFile(item.path.slice(prefix.length));
    if (!located) continue;
    const {name, category, folder, path} = located;
    if (found[name] && found[name].folder !== folder) { duplicates.add(name); continue; }
    found[name] ??= {folder, category, files:Object.create(null)};
    found[name].files[path] = {sha:item.sha, mode:item.mode};
  }
  return {found, duplicates};
}

// Tree edits that put a skill's files at target and remove what is left at its old or target folder.
// files: path → {content} or {sha} of an existing blob.
export function placeSkill(tree, previous, target, files) {
  const paths = new Set(Object.keys(files).map(path => target+path));
  const edits = tree.filter(item => item.type === 'blob' && (item.path.startsWith(previous) || item.path.startsWith(target)) && !paths.has(item.path))
    .map(item => ({path:item.path, mode:item.mode, type:'blob', sha:null}));
  for (const [path, source] of Object.entries(files)) edits.push({path:target+path, mode:'100644', type:'blob', ...source});
  return edits;
}

export const REVIEW_PR_LIMIT = 8;
export const isIntakeBranch = ref => typeof ref === 'string' && ref.startsWith('skill-intake/');

export class GitHubFailure extends Error {}
export function safeGitHubDetail(error) {
  if (error instanceof GitHubFailure) return error.message;
  const known = new Set(['Approved blob lookup failed.','Approved library exceeds limits.','Approved skill names must be unique across categories.','Approved repository tree is too large.','Approved blob is unavailable or binary.','Invalid or flagged skill content.']);
  return known.has(error?.message) ? error.message : 'GitHub App access could not be verified.';
}

export async function appJWT(env) {
  // GitHub downloads PKCS#1 PEM; WebCrypto accepts PKCS#8. Never log either.
  let pem = env.GITHUB_PRIVATE_KEY.trim().replace(/^\uFEFF/, '');
  // Accept a pasted JSON string or literal escaped line breaks from secret UIs.
  if (pem.startsWith('"') && pem.endsWith('"')) pem = JSON.parse(pem);
  if (typeof pem !== 'string') throw new Error('Invalid PEM encoding.');
  pem = pem.replace(/\\r\\n|\\n/g, '\n');
  const der = createPrivateKey(pem).export({type:'pkcs8', format:'der'});
  const key = await crypto.subtle.importKey('pkcs8', der, {name:'RSASSA-PKCS1-v1_5', hash:'SHA-256'}, false, ['sign']);
  const now = Math.floor(Date.now() / 1000);
  const unsigned = base64url(JSON.stringify({alg:'RS256',typ:'JWT'})) + '.' + base64url(JSON.stringify({iat:now-60,exp:now+540,iss:env.GITHUB_APP_ID}));
  return unsigned + '.' + base64url(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, bytes(unsigned)));
}

export class GitHub {
  constructor(env, fetcher = (...args) => fetch(...args)) {
    this.env = env;
    this.repo = env.GITHUB_REPOSITORY;
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(this.repo)) throw new Error('Invalid repository configuration.');
    this.base = env.GITHUB_BASE_BRANCH || 'main';
    this.fetcher = fetcher;
    this.token = null;
    this.expires = 0;
  }
  async request(method, path, body, allowed = [200,201], app = false) {
    if (!app && Date.now() >= this.expires) {
      // Share in-flight token refreshes within an isolate.
      if (!this.refreshing) this.refreshing = this.request('POST', `/app/installations/${this.env.GITHUB_INSTALLATION_ID}/access_tokens`, {
        repositories:[this.repo.split('/')[1]], permissions:{contents:'write',pull_requests:'write'}
      }, [201], true).then(data => {
        this.token = data.token;
        this.expires = Math.min(Date.parse(data.expires_at), Date.now()+3000000);
        if (!this.token || !Number.isFinite(this.expires)) throw new Error('Invalid installation token response.');
      }).finally(() => { this.refreshing = null; });
      await this.refreshing;
    }
    let token = this.token;
    if (app) {
      try { token = await appJWT(this.env); }
      catch { throw new GitHubFailure('The GitHub App private key could not be loaded or used for signing.'); }
    }
    const response = await this.fetcher('https://api.github.com'+path, {
      method, redirect:'manual', signal:AbortSignal.timeout(25000),
      headers:{Authorization:`Bearer ${token}`,Accept:'application/vnd.github+json','Content-Type':'application/json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'Autodesk-Skill-Intake'},
      body:body === undefined ? undefined : JSON.stringify(body)
    });
    if (!allowed.includes(response.status)) {
      if (response.status === 401 && !app) this.expires = 0;
      await response.body?.cancel();
      throw new GitHubFailure(`GitHub rejected ${app ? 'installation authentication' : 'repository access'} (HTTP ${response.status}).`);
    }
    if (response.status === 404) { await response.body?.cancel(); return null; }
    return response.status === 204 ? null : response.json();
  }
  // fresh: re-read main's commit even when the cached copy is less than a minute old.
  async library(fresh = false) {
    if (!fresh && this.cached && Date.now()-this.cachedAt < 60000) return this.cached;
    const root = `/repos/${this.repo}`;
    const ref = await this.request('GET', `${root}/git/ref/heads/${encodeURIComponent(this.base)}`);
    if (this.cached?.commit === ref.object.sha) { this.cachedAt = Date.now(); return this.cached; }
    const commit = await this.request('GET', `${root}/git/commits/${ref.object.sha}`);
    const tree = await this.request('GET', `${root}/git/trees/${commit.tree.sha}?recursive=1`);
    if (tree.truncated) throw new Error('Approved repository tree is too large.');
    const prefix = '.agents/skills/';
    const items = tree.tree.filter(item => item.path.startsWith(prefix) && item.type === 'blob' && ['100644','100755'].includes(item.mode)
      && item.path.slice(prefix.length).includes('/') && EXTENSIONS.has(item.path.split('.').pop().toLowerCase()));
    // Batch blob reads through GraphQL: at most 20 calls, within Workers Free's
    // 50 external subrequests even when a submission also creates a draft PR.
    if (items.length > 800 || items.some(i => !Number.isInteger(i.size) || i.size > 256*1024) || items.reduce((n,i)=>n+i.size,0) > MAX_BODY) throw new Error('Approved library exceeds limits.');
    const skills = Object.create(null), categories = Object.create(null), locations = Object.create(null);
    for (let offset=0; offset<items.length; offset+=40) {
      const group = items.slice(offset,offset+40);
      const queries = group.map((item,i) => `b${i}: object(oid:${JSON.stringify(item.sha)}) { ... on Blob { text isBinary byteSize } }`).join('\n');
      const [owner,name] = this.repo.split('/');
      const response = await this.request('POST','/graphql', {query:`query { repository(owner:${JSON.stringify(owner)}, name:${JSON.stringify(name)}) { ${queries} } }`});
      if (response.errors || !response.data?.repository) throw new Error('Approved blob lookup failed.');
      for (let i=0;i<group.length;i++) {
        const blob = response.data.repository[`b${i}`];
        if (!blob || blob.isBinary || typeof blob.text !== 'string' || blob.byteSize !== group[i].size) throw new Error('Approved blob is unavailable or binary.');
        const located = locateSkillFile(group[i].path.slice(prefix.length));
        if (!located) continue;   // e.g. a category README
        const {name, category, folder, path} = located;
        if (locations[name] && locations[name] !== folder) throw new Error('Approved skill names must be unique across categories.');
        locations[name] = folder; categories[name] = category;
        skills[name] ??= Object.create(null);
        skills[name][path] = blob.text.replace(/^\uFEFF/, '');
      }
    }
    const listed = Object.entries(skills).filter(([,files])=>Object.hasOwn(files,'SKILL.md')).map(([name,files])=>({name,files}));
    const approved = listed.length ? validateSkills({skills:listed},false) : {};
    this.cached = {skills:approved,categories,locations,commit:ref.object.sha,treeSha:commit.tree.sha,tree:tree.tree};
    this.cachedAt = Date.now();
    return this.cached;
  }
  async existing(branch) {
    const prs = await this.request('GET', `/repos/${this.repo}/pulls?state=all&head=${encodeURIComponent(this.repo.split('/')[0]+':'+branch)}`);
    return prs[0]?.html_url;
  }
  async submit(skills, digest) {
    const branch = 'skill-intake/central-'+digest.slice(0,32);
    const previous = await this.existing(branch);
    if (previous) return previous;
    const library = await this.library();
    if (Object.entries(skills).every(([n,f])=>canonical(library.skills[n] ?? null)===canonical(f))) return 'already_approved';
    const root = `/repos/${this.repo}`;
    const refPath = `${root}/git/ref/heads/${branch}`;
    if (!await this.request('GET', refPath, undefined, [200,404])) {
      // Each skill goes to .agents/skills/<category>/<name>/; files at its previous location are removed,
      // so a re-categorised or flat legacy skill moves instead of being duplicated.
      const previous = name => library.locations?.[name] ? `.agents/skills/${library.locations[name]}/` : `.agents/skills/${name}/`;
      const edits = Object.entries(skills).flatMap(([name,files])=>placeSkill(library.tree, previous(name),
        `.agents/skills/${submissionCategory(name,files['SKILL.md'],library.categories?.[name])}/${name}/`,
        Object.fromEntries(Object.entries(files).map(([path,content])=>[path,{content}]))));
      const tree = await this.request('POST', `${root}/git/trees`, {base_tree:library.treeSha,tree:edits});
      const commit = await this.request('POST', `${root}/git/commits`, {message:'Propose saved Autodesk workflows for review',tree:tree.sha,parents:[library.commit]});
      try { await this.request('POST', `${root}/git/refs`, {ref:'refs/heads/'+branch,sha:commit.sha}); }
      catch (error) { if (!await this.request('GET',refPath,undefined,[200,404])) throw error; }
    }
    try {
      const pr = await this.request('POST', `${root}/pulls`, {
        title:'Saved skill review: '+Object.keys(skills).join(', ').slice(0,180),head:branch,base:this.base,draft:true,
        body:'Automatically collected workflow candidates. Checks are heuristic: review every file before approval. No automatic merge or release publication.\n\nBatch: `'+digest+'`'
      });
      if (Number.isInteger(pr.number)) {
        try { await this.request('POST', `${root}/pulls/${pr.number}/requested_reviewers`, {reviewers:[this.repo.split('/')[0]]}); }
        catch { /* Draft PR remains available when review assignment is restricted. */ }
      }
      return pr.html_url;
    } catch (error) {
      // A lease may expire or GitHub may accept a request before a disconnect.
      // Deterministic branch + re-read avoids duplicate PRs on retry.
      const existing = await this.existing(branch);
      if (existing) return existing;
      throw error;
    }
  }
  // Text of blobs by sha, 40 per GraphQL call; binary, missing or oversized blobs map to null.
  async texts(shas) {
    const out = Object.create(null), list = [...new Set(shas)], [owner,name] = this.repo.split('/');
    for (let offset=0; offset<list.length; offset+=40) {
      const group = list.slice(offset,offset+40);
      const queries = group.map((sha,i) => `b${i}: object(oid:${JSON.stringify(sha)}) { ... on Blob { text isBinary byteSize } }`).join('\n');
      const response = await this.request('POST','/graphql', {query:`query { repository(owner:${JSON.stringify(owner)}, name:${JSON.stringify(name)}) { ${queries} } }`});
      if (!response?.data?.repository) throw new GitHubFailure('Uploaded files could not be read from GitHub.');
      group.forEach((sha,i) => {
        const blob = response.data.repository[`b${i}`];
        out[sha] = blob && !blob.isBinary && typeof blob.text === 'string' && blob.byteSize <= 256*1024 ? blob.text.replace(/^﻿/, '') : null;
      });
    }
    return out;
  }
  intakePR(pr) {
    return pr?.state === 'open' && isIntakeBranch(pr.head?.ref) && pr.head?.repo?.full_name === this.repo && pr.base?.ref === this.base;
  }
  // Every skill an intake PR proposes that differs from the approved copy on main.
  // The PR's own base decides what it proposes, so a stale branch never "proposes" main's older text.
  async reviewPRs(pulls, library) {
    const root = `/repos/${this.repo}`, approved = skillFolders(library.tree), prs = [], pending = [];
    for (const pull of pulls) {
      const pr = {number:pull.number, url:`https://github.com/${this.repo}/pull/${pull.number}`, title:String(pull.title ?? '').slice(0,200),
        submitted_at:Math.floor(Date.parse(pull.created_at)/1000) || 0, head_sha:pull.head.sha, proposed:[], already_approved:[], outside:[]};
      prs.push(pr);
      try {
        const head = await this.request('GET', `${root}/git/commits/${pull.head.sha}`);
        const base = head.parents?.[0]?.sha;
        const headTree = await this.request('GET', `${root}/git/trees/${head.tree.sha}?recursive=1`);
        const baseTree = base === library.commit ? {tree:library.tree} : await this.request('GET', `${root}/git/trees/${base}?recursive=1`);
        if (!headTree || !baseTree || headTree.truncated || baseTree.truncated) throw new GitHubFailure('The intake branch is too large to review here.');
        const blobs = tree => new Map(tree.filter(i => i.type === 'blob').map(i => [i.path, i.sha+':'+i.mode]));
        const before = blobs(baseTree.tree), after = blobs(headTree.tree);
        pr.outside = [...new Set([...before.keys(), ...after.keys()])].filter(p => !p.startsWith('.agents/skills/') && before.get(p) !== after.get(p)).slice(0,20);
        const proposed = skillFolders(headTree.tree), original = skillFolders(baseTree.tree);
        for (const [name, folder] of Object.entries(proposed.found)) {
          const was = original.found[name];
          if (was && was.folder === folder.folder && folderKey(was.files) === folderKey(folder.files)) continue;   // untouched by this upload
          const main = approved.found[name];
          if (main && main.folder === folder.folder && folderKey(main.files) === folderKey(folder.files)) { pr.already_approved.push(name); continue; }
          pr.proposed.push(name);
          pending.push({pr, name, folder, main, duplicate:proposed.duplicates.has(name), stale:folderKey(was?.files ?? {}) !== folderKey(main?.files ?? {})});
        }
      } catch (error) { pr.error = error instanceof GitHubFailure ? error.message : 'This pull request could not be read.'; }
    }
    // Only files that differ from the approved copy are downloaded.
    const needed = pending.flatMap(p => Object.entries(p.folder.files).filter(([path,f]) => p.main?.files[path]?.sha !== f.sha).map(([,f]) => f.sha));
    const texts = needed.length ? await this.texts(needed) : {};
    const items = [];
    for (const p of pending) {
      const compared = compareSkill(p.name, p.folder, p.main, texts, library.skills[p.name] ?? {});
      if (p.duplicate) compared.checks.blocked.push('The upload has this skill name in more than one folder.');
      items.push({pr:p.pr.number, pr_url:p.pr.url, head_sha:p.pr.head_sha, submitted_at:p.pr.submitted_at, name:p.name,
        category:p.folder.category ?? 'uncategorized', folder:p.folder.folder, approved_folder:p.main?.folder ?? null,
        status:compared.status, stale:p.stale, key:await hash(folderKey(p.folder.files)),
        approved_key:p.main ? await hash(p.main.folder+'|'+folderKey(p.main.files)) : 'none',
        head_files:Object.fromEntries(Object.entries(p.folder.files).map(([path,f]) => [path,f.sha])),
        files:compared.files, checks:compared.checks});
    }
    return {prs, items};
  }
  // Pending uploads across the oldest open intake PRs; "more" says older PRs must be decided first.
  async reviewQueue(limit = REVIEW_PR_LIMIT) {
    const library = await this.library(true);
    const pulls = (await this.request('GET', `/repos/${this.repo}/pulls?state=open&base=${encodeURIComponent(this.base)}&sort=created&direction=asc&per_page=100`))
      .filter(pr => this.intakePR(pr));
    return {library_commit:library.commit, more:pulls.length > limit, ...await this.reviewPRs(pulls.slice(0,limit), library)};
  }
  // One PR, re-read at decision time; null when it is no longer an open intake PR.
  async reviewOne(number) {
    const library = await this.library(true);
    const pull = await this.request('GET', `/repos/${this.repo}/pulls/${number}`, undefined, [200,404]);
    if (!this.intakePR(pull)) return null;
    const {prs, items} = await this.reviewPRs([pull], library);
    return {pr:prs[0], items};
  }
  // Writes one reviewed skill to main: exactly the blobs the owner saw, placed under the chosen category.
  // The ref update is never forced, so a main that moved meanwhile makes this fail instead of overwriting.
  async approveSkill(item, category) {
    const library = await this.library();
    const root = `/repos/${this.repo}`;
    const previous = `.agents/skills/${item.approved_folder ?? item.name}/`, target = `.agents/skills/${category}/${item.name}/`;
    const edits = placeSkill(library.tree, previous, target, Object.fromEntries(Object.entries(item.head_files).map(([path,sha]) => [path,{sha}])));
    const tree = await this.request('POST', `${root}/git/trees`, {base_tree:library.treeSha, tree:edits});
    const commit = await this.request('POST', `${root}/git/commits`, {message:`Approve ${item.name} from skill intake #${item.pr}`, tree:tree.sha, parents:[library.commit]});
    try { await this.request('PATCH', `${root}/git/refs/heads/${encodeURIComponent(this.base)}`, {sha:commit.sha, force:false}); }
    catch (error) {
      this.cached = null;
      if (/HTTP 422/.test(error?.message)) throw new GitHubFailure('Main changed while approving. Refresh and approve again.');
      throw error;
    }
    this.cached = null;
    return commit.sha;
  }
  // Leaves a summary and closes the intake PR without merging it.
  async closeIntake(number, summary) {
    const root = `/repos/${this.repo}`;
    await this.request('POST', `${root}/issues/${number}/comments`, {body:summary});
    await this.request('PATCH', `${root}/pulls/${number}`, {state:'closed'});
  }
}
