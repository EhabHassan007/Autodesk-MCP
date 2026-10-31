import { createPrivateKey } from 'node:crypto';
import { bytes, canonical, CATEGORIES, EXTENSIONS, MAX_BODY, SKILL_NAME, validateSkills } from './validation.mjs';

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
  async library() {
    if (this.cached && Date.now()-this.cachedAt < 60000) return this.cached;
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
      const target = Object.fromEntries(Object.entries(skills).map(([name,files])=>[name,
        `.agents/skills/${submissionCategory(name,files['SKILL.md'],library.categories?.[name])}/${name}/`]));
      const previous = name => library.locations?.[name] ? `.agents/skills/${library.locations[name]}/` : `.agents/skills/${name}/`;
      const paths = new Set(Object.entries(skills).flatMap(([name,files])=>Object.keys(files).map(path=>target[name]+path)));
      const edits = library.tree.filter(item=>item.type==='blob' && Object.keys(skills).some(name=>item.path.startsWith(previous(name)) || item.path.startsWith(target[name])) && !paths.has(item.path))
        .map(item=>({path:item.path,mode:item.mode,type:'blob',sha:null}));
      for (const [name,files] of Object.entries(skills)) for (const [path,content] of Object.entries(files)) edits.push({path:target[name]+path,mode:'100644',type:'blob',content});
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
}
