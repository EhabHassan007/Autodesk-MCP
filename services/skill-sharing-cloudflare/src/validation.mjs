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

// Team joining: the person types name and email, setup supplies the rest.
const plain = (value, max) => typeof value === 'string' && value.isWellFormed() && value.trim() === value && value.length >= 1 && value.length <= max && !/[\x00-\x1f\x7f<>]/.test(value);
export const VERSION = /^[0-9A-Za-z.+-]{1,40}$/;
export function validateProfile(data) {
  const fail = message => { throw new Error(message); };
  const keys = ['name', 'email', 'pc_name', 'windows_user', 'connector_version'];
  if (!object(data) || Object.keys(data).some(k => !keys.includes(k))) fail('Unexpected fields.');
  if (!plain(data.name, 80)) fail('Enter your name (up to 80 characters).');
  if (!plain(data.email, 254) || !/^[^\s@"]+@[^\s@"]+\.[^\s@"]{2,}$/.test(data.email)) fail('Enter a valid email address.');
  if (typeof data.pc_name !== 'string' || !/^[A-Za-z0-9._-]{1,63}$/.test(data.pc_name)) fail('Invalid PC name.');
  if (!plain(data.windows_user, 64) || /[\\/:*?"|]/.test(data.windows_user)) fail('Invalid Windows user name.');
  if (data.connector_version !== undefined && (typeof data.connector_version !== 'string' || !VERSION.test(data.connector_version))) fail('Invalid connector version.');
  return {name: data.name, email: data.email.toLowerCase(), pc_name: data.pc_name, windows_user: data.windows_user, connector_version: data.connector_version ?? null};
}

// Usage arrives pre-aggregated per day: names only, never arguments or content.
export const MAX_USAGE_EVENTS = 500;
export function validateUsage(data, today) {
  if (!exactKeys(data, ['events']) || !Array.isArray(data.events) || !data.events.length || data.events.length > MAX_USAGE_EVENTS) throw new Error('Send 1 to 500 usage events.');
  const earliest = new Date(Date.parse(today) - 60 * 86400000).toISOString().slice(0, 10);
  const tomorrow = new Date(Date.parse(today) + 86400000).toISOString().slice(0, 10);
  return data.events.map(event => {
    if (!exactKeys(event, ['kind', 'name', 'day', 'count'])) throw new Error('Invalid usage event.');
    const {kind, name, day, count} = event;
    if (!['skill', 'tool'].includes(kind) || typeof name !== 'string' || !/^[A-Za-z0-9_.:-]{1,100}$/.test(name)) throw new Error('Invalid usage event.');
    if (typeof day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(day) || Number.isNaN(Date.parse(day)) || day < earliest || day > tomorrow) throw new Error('Usage day out of range.');
    if (!Number.isInteger(count) || count < 1 || count > 10000) throw new Error('Invalid usage count.');
    return {kind, name, day, count};
  });
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
