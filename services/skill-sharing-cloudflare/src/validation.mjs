export const MAX_BODY = 2 * 1024 * 1024;
export const EXTENSIONS = new Set(['md','txt','json','yaml','yml','toml','py','ps1','js','ts','sh','csv','xml']);
const sensitive = /github_pat_|gh[pousr]_[A-Za-z0-9_]+|-----BEGIN .*PRIVATE KEY|(?:password|api[_ -]?key|access[_ -]?token)\s*[:=]\s*\S+|[a-z]:\\users\\|[\w.+-]+@[\w.-]+\.[a-z]{2,}/i;
const encoder = new TextEncoder();
export const bytes = text => encoder.encode(text);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exactKeys = (value, keys) => object(value) && Object.keys(value).sort().join(',') === keys.sort().join(',');
const invalid = () => { throw new Error('Invalid or flagged skill content.'); };

export function validateSkills(data, scan = true) {
  if (!exactKeys(data, ['skills']) || !Array.isArray(data.skills) || !data.skills.length || data.skills.length > 100) invalid();
  const result = Object.create(null);
  let total = 0;
  for (const skill of data.skills) {
    if (!exactKeys(skill, ['name', 'files'])) invalid();
    const {name, files} = skill;
    if (typeof name !== 'string' || name.length > 100 || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name) || Object.hasOwn(result, name)) invalid();
    if (!object(files) || !Object.hasOwn(files, 'SKILL.md') || Object.keys(files).length > 100) invalid();
    const seen = new Set();
    for (const [path, content] of Object.entries(files)) {
      if (typeof content !== 'string' || !content.isWellFormed() || !path.isWellFormed() || path.length > 240 || /[\\:\x00-\x1f\x7f]/.test(path)) invalid();
      if (path.split('/').some(p => !p || p.startsWith('.') || /[. ]$/.test(p) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(p))) invalid();
      const ext = path.includes('.') ? path.split('.').pop().toLowerCase() : '';
      if (!EXTENSIONS.has(ext) || seen.has(path.toLowerCase())) invalid();
      seen.add(path.toLowerCase());
      const size = bytes(content).length;
      total += size;
      if (size > 256 * 1024 || total > MAX_BODY || content.includes('\0') || (scan && sensitive.test(content))) invalid();
    }
    if (!new RegExp(`^name:\\s*${name}\\s*$`, 'm').test(files['SKILL.md'])) invalid();
    result[name] = Object.fromEntries(Object.entries(files).sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0));
  }
  return Object.fromEntries(Object.entries(result).sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0));
}

// Sorting explicitly also covers integer-like filenames, whose JS property order differs.
export function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  const order = (a,b) => {
    const left=Array.from(a), right=Array.from(b);
    for (let i=0;i<Math.min(left.length,right.length);i++) {
      const difference=left[i].codePointAt(0)-right[i].codePointAt(0);
      if (difference) return difference;
    }
    return left.length-right.length;
  };
  return '{' + Object.keys(value).sort(order).map(k => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}';
}
export async function hash(text) {
  const digest = await crypto.subtle.digest('SHA-256', bytes(text));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
}
