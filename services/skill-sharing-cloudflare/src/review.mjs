// Owner review of uploaded skills: pure helpers shared by the service and the dashboard.
// Uploaded content is untrusted. It is compared and scanned as text here, never executed.
import { canonical, CATEGORIES, validateSkills } from './validation.mjs';

// The same groups as scripts/validate-team-skill-intake.ps1, split so the owner sees why a line was flagged,
// plus damaged text encoding, which that script does not check.
export const FLAG_PATTERNS = {
  'secret':/api[_ -]?key|access[_ -]?token|client[_ -]?secret|password\s*[:=]|github_pat_|gh[pousr]_[a-z0-9_]+|begin (?:rsa|openssh|ec) private key|-----begin .*private key/i,
  'personal-path':/[a-z]:\\users\\|\\\\[^\\\s]+\\[^\\\s]+/i,
  'client-data':/autodesk docs:\/\/|bim 360:\/\/|acc:\/\/|\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b/i,
  // UTF-8 decoded as Windows-1252/Latin-1, e.g. a dash arriving as "Ã¢ÂÂ" or "â€”".
  // After a single Latin-1 decode, "—" reads as "â" plus invisible C1 controls (U+0080-U+009F), which real text never holds.
  'encoding':/[ÂÃ][\u0080-¿]|â€|[Â-ô][\u0080-\u009F]/
};
const MAX_FLAGS = 25;

// A folder's identity: its files and their git blob ids, so equal content gives an equal key.
export const folderKey = files => canonical(Object.fromEntries(Object.entries(files).map(([path,f]) => [path, f.sha])));

// "blocked" stops approval; "flags" are heuristic and need the owner's explicit acknowledgement.
export function reviewChecks(name, category, files, before = {}, problems = []) {
  const blocked = [...problems];
  const texts = Object.fromEntries(Object.entries(files).filter(([,text]) => typeof text === 'string'));
  if (Object.keys(texts).length === Object.keys(files).length) {
    try { validateSkills({skills:[{name,files:texts}]}, false); }
    catch { blocked.push('Fails the service structure check: SKILL.md with a matching "name:" line, supported text file types, safe file names and sizes.'); }
  }
  const manifest = texts['SKILL.md'] ?? '';
  if (!/^description:\s*\S.+$/m.test(manifest)) blocked.push('SKILL.md has no "description:" line.');
  const declared = /^category:\s*(\S+)\s*$/m.exec(manifest)?.[1];
  if (declared && category && declared !== category) blocked.push(`SKILL.md says category "${declared}" but the upload is in "${category}".`);
  // The repository's own checks require every approved skill to declare the category of its folder, so a skill
  // without the line would break them the moment it is approved.
  if (!declared) blocked.push('SKILL.md has no "category:" line. Add one that names its folder, for example "category: revit", and send it again; without it the repository checks fail once it is approved.');
  // Scan only lines the upload adds, as the intake workflow does, so approved text is not flagged again.
  const flags = [];
  for (const [path, text] of Object.entries(texts)) {
    const old = new Set((before[path] ?? '').split(/\r?\n/));
    text.split(/\r?\n/).forEach((line, index) => {
      if (old.has(line) || flags.length >= MAX_FLAGS) return;
      for (const [kind, pattern] of Object.entries(FLAG_PATTERNS))
        if (pattern.test(line)) { flags.push({kind, path, line:index+1, text:line.trim().slice(0,160)}); break; }
    });
  }
  return {blocked, flags, ...(declared ? {declared} : {})};
}

// Compares one uploaded skill folder with the approved copy on main.
// head/main: {folder, category, files:{path:{sha,mode}}}; texts: blob sha → text (null when binary or too large);
// approvedTexts: path → text of the approved copy.
export function compareSkill(name, head, main, texts, approvedTexts = {}) {
  const status = !main ? 'new' : folderKey(head.files) === folderKey(main.files) ? (head.folder === main.folder ? 'unchanged' : 'moved') : 'changed';
  const paths = [...new Set([...Object.keys(head.files), ...Object.keys(main?.files ?? {})])].sort();
  const problems = [], after = {};
  const files = paths.map(path => {
    const h = head.files[path], m = main?.files[path];
    if (!h) return {path, status:'removed', before:approvedTexts[path] ?? null, after:null};
    if (!['100644','100755'].includes(h.mode)) problems.push(`${path} is a link or not a regular file.`);
    const text = texts[h.sha];
    if (typeof text !== 'string') problems.push(`${path} is binary, too large or unavailable.`);
    after[path] = typeof text === 'string' ? text : null;
    if (m?.sha === h.sha) return {path, status:'unchanged'};
    return {path, status:m ? 'modified' : 'added', before:m ? approvedTexts[path] ?? null : null, after:after[path]};
  });
  return {status, files, checks:reviewChecks(name, head.category, after, approvedTexts, problems)};
}

const ORDER = [...CATEGORIES];
// Groups pending uploads by category, then skill. Decided uploads and uploads whose exact content
// the owner rejected before are left out. decisions: Set of "pr/skill"; rejected: Set of "skill/key";
// senders: PR URL → {name, also}.
export function groupReviews(items, {decisions = new Set(), rejected = new Set(), senders = {}} = {}) {
  const groups = Object.create(null);
  let hidden = 0;
  for (const item of items) {
    if (decisions.has(`${item.pr}/${item.name}`)) continue;
    if (rejected.has(`${item.name}/${item.key}`)) { hidden++; continue; }
    const category = CATEGORIES.has(item.category) ? item.category : 'uncategorized';
    const skills = groups[category] ??= Object.create(null);
    (skills[item.name] ??= []).push({...item, sender:senders[item.pr_url] ?? {name:'Unknown sender', also:[]}});
  }
  const categories = Object.keys(groups).sort((a,b) => ORDER.indexOf(a) - ORDER.indexOf(b)).map(category => ({
    category,
    skills:Object.keys(groups[category]).sort().map(name => ({name, uploads:groups[category][name].sort((a,b) => a.submitted_at - b.submitted_at || a.pr - b.pr)}))
  }));
  return {categories, pending:categories.reduce((n,c) => n + c.skills.reduce((m,s) => m + s.uploads.length, 0), 0), hidden_rejected:hidden};
}

// Skills in one intake PR the owner still has to decide.
export function undecided(items, pr, decisions, rejected) {
  return items.filter(i => i.pr === pr && !decisions.has(`${pr}/${i.name}`) && !rejected.has(`${i.name}/${i.key}`)).map(i => i.name);
}

// Line diff for the dashboard; its source is also sent to the browser, so it uses no outside names.
// Returns [op, text] pairs: ' ' kept, '-' removed, '+' added.
export function lineDiff(before, after) {
  const a = before ? before.split(/\r?\n/) : [], b = after ? after.split(/\r?\n/) : [];
  let start = 0, endA = a.length, endB = b.length;
  while (start < endA && start < endB && a[start] === b[start]) start++;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
  const out = a.slice(0, start).map(t => [' ', t]);
  const x = a.slice(start, endA), y = b.slice(start, endB), n = x.length, m = y.length;
  if (n * m > 4000000) {
    for (const t of x) out.push(['-', t]);
    for (const t of y) out.push(['+', t]);
  } else {
    // Longest common subsequence table, filled from the end.
    const width = m + 1, table = new Uint32Array((n + 1) * width);
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
      table[i * width + j] = x[i] === y[j] ? table[(i + 1) * width + j + 1] + 1 : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
    let i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && x[i] === y[j]) { out.push([' ', x[i]]); i++; j++; }
      else if (j < m && (i === n || table[i * width + j + 1] > table[(i + 1) * width + j])) { out.push(['+', y[j]]); j++; }
      else { out.push(['-', x[i]]); i++; }
    }
  }
  for (const t of a.slice(endA)) out.push([' ', t]);
  return out;
}

// The comment left on an intake PR when the owner has decided every skill in it.
export function reviewSummary(rows, autoRejected = []) {
  const lines = rows.map(r => `- \`${r.skill}\`: ${r.decision === 'approve' ? `approved into \`${r.category}\`` : 'rejected'}`);
  for (const name of autoRejected) lines.push(`- \`${name}\`: rejected earlier with the same content`);
  return 'Reviewed one skill at a time in the skill-sharing dashboard. Approved skills were added to `main` individually; '
    + 'this pull request is closed without merging.\n\n' + (lines.length ? lines.join('\n') : 'Nothing in this upload differed from the approved library.');
}
