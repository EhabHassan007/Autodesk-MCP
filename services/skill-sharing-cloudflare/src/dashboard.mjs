// Static admin dashboard. It holds no data or secrets: the browser asks for the
// admin token, keeps it for the tab session only, and fetches /admin/api/overview.
// Every value from the database is inserted as text, never as HTML, because
// names and emails are typed by team members, and uploaded skill content is untrusted.
import { lineDiff } from './review.mjs';

export const DASHBOARD_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Skill Sharing Admin</title>
<link rel="stylesheet" href="/admin/app.css">
<script src="/admin/app.js" defer></script>
</head>
<body>
<header class="bar">
  <h1>Autodesk MCP skill sharing</h1>
  <div class="bar-actions" id="actions" hidden>
    <span class="muted" id="updated"></span>
    <button type="button" id="refresh">Refresh</button>
    <button type="button" id="signout" class="ghost">Sign out</button>
  </div>
</header>
<main>
  <section id="signin" class="card narrow">
    <h2>Administrator sign-in</h2>
    <p class="muted">Paste the ADMIN_TOKEN from your password file. It stays in this browser tab only and is cleared when you close it.</p>
    <label for="token">Admin token</label>
    <input id="token" type="password" autocomplete="off" spellcheck="false">
    <button type="button" id="open">Open dashboard</button>
    <p class="error" id="signin-error" role="alert"></p>
  </section>
  <section id="app" hidden>
    <nav class="tabs" aria-label="Dashboard views">
      <button type="button" class="tab" id="tab-team" aria-pressed="true">Team</button>
      <button type="button" class="tab" id="tab-review" aria-pressed="false">Skill review</button>
    </nav>
    <div id="review-view" hidden>
      <p class="muted">Uploaded skills that differ from the approved library, grouped by category. Content is shown as text only and is never run. Approve adds one skill to <b>main</b>, which the team library serves; reject keeps it out. An upload closes on GitHub, unmerged, once every skill in it is decided.</p>
      <div class="tiles" id="review-tiles"></div>
      <p class="error" id="review-error" role="alert"></p>
      <div id="review-list"></div>
      <div class="card" id="review-prs-card">
        <h2>Uploads (pull requests)</h2>
        <ul id="review-prs" class="plain"></ul>
      </div>
    </div>
    <div id="team-view">
    <div class="tiles" id="tiles"></div>
    <div class="grid">
      <div class="card">
        <div class="card-head">
          <h2>People and PCs</h2>
          <input id="filter" type="search" placeholder="Filter by name, email, PC or IP" aria-label="Filter people">
        </div>
        <div class="table-wrap"><table id="people">
          <thead><tr><th>Person</th><th>PC / Windows user</th><th>IP address</th><th>Joined</th><th>Last seen</th><th>Skills used (7 days)</th><th>Submitted</th><th>Status</th><th></th></tr></thead>
          <tbody></tbody>
        </table></div>
        <p class="muted small">Skill and tool usage covers what is opened through the Autodesk MCP Connector only. IP is the public address the service sees; an office usually shares one.</p>
      </div>
      <div class="card side">
        <h2>Most used skills (7 days)</h2>
        <ol id="top-skills" class="ranked"></ol>
        <h2>Recent submissions</h2>
        <ul id="recent" class="plain"></ul>
      </div>
    </div>
    </div>
  </section>
</main>
</body>
</html>`;

export const DASHBOARD_CSS = `:root{--bg:#f6f7f9;--card:#fff;--text:#1d2329;--muted:#5f6b77;--line:#e3e7ec;--accent:#0b6bcb;--accent-text:#fff;--good:#1f7a3d;--bad:#b42318;--chip:#eef2f6}
@media (prefers-color-scheme:dark){:root{--bg:#121417;--card:#1b1f24;--text:#e7ebef;--muted:#9aa6b2;--line:#2b3138;--accent:#4c9ee8;--accent-text:#0b1520;--good:#5cc683;--bad:#f1847a;--chip:#252b32}}
*{box-sizing:border-box}
/* Elements toggled with the hidden attribute must stay hidden even when a class sets display. */
[hidden]{display:none!important}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.bar{display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;padding:14px 20px;border-bottom:1px solid var(--line);background:var(--card)}
h1{font-size:17px;margin:0}h2{font-size:15px;margin:0 0 10px}
.bar-actions{display:flex;gap:8px;align-items:center}
main{padding:20px;max-width:1400px;margin:0 auto}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;min-width:0}
.narrow{max-width:420px;margin:40px auto}
.card-head{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;margin-bottom:10px}
.card-head h2{margin:0}
label{display:block;font-weight:600;margin:12px 0 4px}
input{font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:8px 10px;width:100%}
#filter{width:min(320px,100%)}
button{font:inherit;cursor:pointer;border:1px solid var(--accent);background:var(--accent);color:var(--accent-text);border-radius:6px;padding:7px 12px}
#open{margin-top:12px}
button.ghost{background:transparent;color:var(--text);border-color:var(--line)}
button.danger{background:transparent;color:var(--bad);border-color:var(--bad)}
a{color:var(--accent)}
button.link{background:none;border:none;color:var(--accent);padding:0}
.muted{color:var(--muted)}.small{font-size:12px;margin:10px 0 0}
.error{color:var(--bad);min-height:1.2em}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-bottom:16px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.tile b{display:block;font-size:24px;font-variant-numeric:tabular-nums}
.grid{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:16px}
@media (max-width:1000px){.grid{grid-template-columns:1fr}}
.table-wrap{overflow-x:auto}
table{border-collapse:collapse;width:100%;min-width:900px}
th,td{text-align:left;padding:8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:12px;color:var(--muted);font-weight:600;white-space:nowrap}
#people td:first-child{min-width:190px}
td.num{font-variant-numeric:tabular-nums}
.sub{display:block;color:var(--muted);font-size:12px;word-break:break-all}
.chip{display:inline-block;background:var(--chip);border-radius:999px;padding:1px 8px;margin:0 4px 4px 0;font-size:12px;white-space:nowrap}
.status-on{color:var(--good);font-weight:600}.status-off{color:var(--bad);font-weight:600}
tr.detail td{background:var(--bg)}
.detail-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}
.detail-grid table{min-width:0}
.ranked,.plain{margin:0 0 16px;padding-left:20px}.plain{list-style:none;padding:0}
.ranked li,.plain li{margin-bottom:6px}
.tabs{display:flex;gap:6px;margin-bottom:16px;flex-wrap:wrap}
.tab{background:transparent;color:var(--text);border-color:var(--line)}
.tab[aria-pressed="true"]{background:var(--accent);color:var(--accent-text);border-color:var(--accent)}
.category{margin-bottom:16px}
.skill{border-top:1px solid var(--line);padding-top:12px;margin-top:12px}
.skill h3{font-size:15px;margin:0 0 6px;word-break:break-all}
.upload{background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:12px;margin:8px 0}
.upload-head{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:baseline}
.chip.new{color:var(--good)}.chip.changed,.chip.moved{color:var(--accent)}
.checks{margin:8px 0;padding-left:20px}.checks li{margin-bottom:4px;word-break:break-word}
.bad{color:var(--bad)}.ok{color:var(--good)}.warn{color:var(--bad)}
details.file{border:1px solid var(--line);border-radius:6px;margin:6px 0;background:var(--card)}
details.file summary{cursor:pointer;padding:6px 10px;word-break:break-all}
pre.diff{margin:0;padding:6px 0;overflow-x:auto;font:12px/1.5 ui-monospace,Consolas,monospace;border-top:1px solid var(--line)}
pre.diff span{display:block;padding:0 10px;white-space:pre}
pre.diff .add{background:rgba(31,122,61,.14)}pre.diff .del{background:rgba(180,35,24,.12)}pre.diff .gap{color:var(--muted);font-style:italic}
.decide{display:flex;flex-wrap:wrap;gap:8px 12px;align-items:center;margin-top:10px}
.decide select{font:inherit;color:var(--text);background:var(--card);border:1px solid var(--line);border-radius:6px;padding:6px 8px}
.decide label{display:inline-flex;gap:6px;align-items:center;font-weight:400;margin:0}
.decide input[type=checkbox]{width:auto}
button:disabled{opacity:.5;cursor:not-allowed}
`;

export const DASHBOARD_JS = `'use strict';
(() => {
  const KEY = 'autodeskSkillAdmin';
  const $ = id => document.getElementById(id);
  let data = null, reviews = null, view = 'team';
  const store = {
    get() { try { return sessionStorage.getItem(KEY) || ''; } catch { return ''; } },
    set(v) { try { sessionStorage.setItem(KEY, v); } catch {} },
    clear() { try { sessionStorage.removeItem(KEY); } catch {} }
  };
  let token = store.get();

  // Builds DOM nodes; strings always become text nodes, never markup.
  function el(tag, props, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (k === 'class') node.className = v;
      else if (k === 'on') for (const [ev, fn] of Object.entries(v)) node.addEventListener(ev, fn);
      else node.setAttribute(k, v);
    }
    for (const child of children.flat(Infinity)) if (child !== null && child !== undefined && child !== false) node.append(child instanceof Node ? child : String(child));
    return node;
  }
  const when = s => s ? new Date(s * 1000).toLocaleString() : 'never';
  function ago(s) {
    if (!s) return 'never';
    const d = Date.now() / 1000 - s;
    if (d < 120) return 'just now';
    if (d < 7200) return Math.round(d / 60) + ' min ago';
    if (d < 172800) return Math.round(d / 3600) + ' h ago';
    return Math.round(d / 86400) + ' days ago';
  }

  async function api(path, method, body) {
    const headers = {Authorization: 'Bearer ' + token};
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const r = await fetch(path, {method: method || 'GET', headers, cache: 'no-store', body: body === undefined ? undefined : JSON.stringify(body)});
    if (r.status === 401 || r.status === 403) { signOut('That admin token was not accepted.'); throw new Error('denied'); }
    if (!r.ok) { let m = 'Request failed (HTTP ' + r.status + ').'; try { m = (await r.json()).detail || m; } catch {} throw new Error(m); }
    return r.json();
  }

  function signOut(message) {
    token = ''; store.clear(); data = null; reviews = null;
    $('app').hidden = true; $('actions').hidden = true; $('signin').hidden = false;
    $('signin-error').textContent = message || '';
    $('token').value = ''; $('token').focus();
  }

  async function load() {
    try {
      data = await api('/admin/api/overview');
      $('signin').hidden = true; $('app').hidden = false; $('actions').hidden = false;
      $('updated').textContent = 'Updated ' + new Date().toLocaleTimeString();
      render();
      if (view === 'review') loadReviews();
    } catch (e) { if (e.message !== 'denied') alert(e.message); }
  }

  function usageFor(id) { return data.usage.filter(u => u.device === id); }
  function chips(rows, kind) {
    const list = rows.filter(u => u.kind === kind && u.last7 > 0).sort((a, b) => b.last7 - a.last7);
    if (!list.length) return el('span', {class: 'muted'}, '—');
    return [list.slice(0, 4).map(u => el('span', {class: 'chip', title: u.name}, u.name + ' ×' + u.last7)), list.length > 4 ? el('span', {class: 'muted'}, '+' + (list.length - 4) + ' more') : null];
  }

  function render() {
    const week = Date.now() / 1000 - 7 * 86400;
    const opens = data.usage.filter(u => u.kind === 'skill').reduce((n, u) => n + u.last7, 0);
    $('tiles').replaceChildren(
      el('div', {class: 'tile'}, el('b', {}, data.devices.length), 'people / PCs'),
      el('div', {class: 'tile'}, el('b', {}, data.devices.filter(d => d.last_seen >= week).length), 'active in last 7 days'),
      el('div', {class: 'tile'}, el('b', {}, opens), 'skill opens (7 days)'),
      el('div', {class: 'tile'}, el('b', {}, data.devices.filter(d => !d.active).length), 'blocked'));

    const totals = {};
    for (const u of data.usage) if (u.kind === 'skill' && u.last7) totals[u.name] = (totals[u.name] || 0) + u.last7;
    const top = Object.entries(totals).sort((a, b) => b[1] - a[1]).slice(0, 10);
    $('top-skills').replaceChildren(...(top.length ? top.map(([n, c]) => el('li', {}, n + ' — ' + c)) : [el('li', {class: 'muted'}, 'No skill usage reported yet.')]));

    const names = Object.fromEntries(data.devices.map(d => [d.id, d.person_name || d.label]));
    $('recent').replaceChildren(...(data.submissions.length ? data.submissions.slice(0, 8).map(s =>
      el('li', {}, el('b', {}, names[s.device] || 'Unknown'), ' ', el('span', {class: 'muted'}, when(s.at)), el('span', {class: 'sub'}, s.skills.join(', ') + ' · ' + s.status.replaceAll('_', ' ')))) : [el('li', {class: 'muted'}, 'No submissions yet.')]));
    renderPeople();
  }

  function renderPeople() {
    const q = $('filter').value.trim().toLowerCase();
    const rows = [];
    for (const d of data.devices) {
      const hay = [d.person_name, d.email, d.label, d.pc_name, d.windows_user, d.last_ip, d.enroll_ip].join(' ').toLowerCase();
      if (q && !hay.includes(q)) continue;
      const usage = usageFor(d.id);
      const subs = data.submissions.filter(s => s.device === d.id);
      const detail = el('tr', {class: 'detail', hidden: ''}, el('td', {colspan: '9'}, detailView(d, usage, subs)));
      const toggle = el('button', {type: 'button', class: 'link', on: {click() { detail.hidden = !detail.hidden; toggle.textContent = detail.hidden ? 'Details' : 'Hide'; }}}, 'Details');
      const action = el('button', {type: 'button', class: d.active ? 'danger' : 'ghost', on: {click: () => setActive(d, !d.active)}}, d.active ? 'Block' : 'Unblock');
      rows.push(el('tr', {},
        el('td', {}, el('b', {}, d.person_name || d.label), el('span', {class: 'sub'}, d.email || (d.source === 'admin' ? 'added by administrator' : ''))),
        el('td', {}, d.pc_name || '—', el('span', {class: 'sub'}, d.windows_user || '')),
        el('td', {}, d.last_ip || '—', d.enroll_ip && d.enroll_ip !== d.last_ip ? el('span', {class: 'sub'}, 'joined from ' + d.enroll_ip) : null),
        el('td', {}, d.created_at ? new Date(d.created_at * 1000).toLocaleDateString() : '—'),
        el('td', {title: when(d.last_seen)}, ago(d.last_seen), el('span', {class: 'sub'}, d.connector_version ? 'v' + d.connector_version : '')),
        el('td', {}, chips(usage, 'skill')),
        el('td', {class: 'num'}, subs.length),
        el('td', {}, el('span', {class: d.active ? 'status-on' : 'status-off'}, d.active ? 'Active' : 'Blocked')),
        el('td', {}, toggle, ' ', action)), detail);
    }
    $('people').tBodies[0].replaceChildren(...(rows.length ? rows : [el('tr', {}, el('td', {colspan: '9', class: 'muted'}, q ? 'Nobody matches that filter.' : 'Nobody has joined yet.'))]));
  }

  function detailView(d, usage, subs) {
    const table = (head, body) => el('table', {}, el('thead', {}, el('tr', {}, head.map(h => el('th', {}, h)))), el('tbody', {}, body));
    const used = usage.length ? usage.map(u => el('tr', {}, el('td', {}, u.kind), el('td', {}, u.name), el('td', {class: 'num'}, u.last7), el('td', {class: 'num'}, u.last30), el('td', {}, u.last_day))) : [el('tr', {}, el('td', {colspan: '5', class: 'muted'}, 'No usage in the last 30 days.'))];
    const sent = subs.length ? subs.slice(0, 20).map(s => el('tr', {}, el('td', {}, when(s.at)), el('td', {}, s.skills.join(', ')), el('td', {}, s.status.replaceAll('_', ' ')))) : [el('tr', {}, el('td', {colspan: '3', class: 'muted'}, 'No submissions.'))];
    return el('div', {class: 'detail-grid'},
      el('div', {}, el('h2', {}, 'Skills and tools (30 days)'), table(['Type', 'Name', '7 days', '30 days', 'Last used'], used)),
      el('div', {}, el('h2', {}, 'Submissions'), table(['When', 'Skills', 'Result'], sent),
        el('p', {class: 'muted small'}, 'Device ID: ' + d.id + ' · joined ' + when(d.created_at) + (d.enroll_ip ? ' from ' + d.enroll_ip : '') +
          ' · terms accepted: ' + (d.terms_version || (d.source === 'admin' ? 'n/a (added by administrator)' : 'not recorded')))));
  }

  async function setActive(d, active) {
    const who = d.person_name || d.label;
    if (!confirm((active ? 'Unblock ' : 'Block ') + who + '?' + (active ? '' : ' Their PC will stop sharing and downloading skills until unblocked.'))) return;
    try { await api('/admin/devices/' + d.id + '/' + (active ? 'unblock' : 'block'), 'POST'); await load(); }
    catch (e) { if (e.message !== 'denied') alert(e.message); }
  }

  // ---- Skill review: uploaded skills, grouped by category, decided one at a time. ----
  const LABELS = {revit: 'Revit', autocad: 'AutoCAD', '3ds-max': '3ds Max', 'other-software': 'Other software', 'linkedin-marketing': 'LinkedIn marketing', 'branding-ci': 'Branding and CI', general: 'General', uncategorized: 'Needs a category'};
  const FLAG_NAMES = {'secret': 'possible secret', 'personal-path': 'personal path', 'client-data': 'email or client project link'};
  const STATUS_NAMES = {new: 'new skill', changed: 'changed', moved: 'moved to another category'};
  const lineDiff = ${lineDiff.toString()};

  function showView(next) {
    view = next;
    $('tab-team').setAttribute('aria-pressed', String(next === 'team'));
    $('tab-review').setAttribute('aria-pressed', String(next === 'review'));
    $('team-view').hidden = next !== 'team';
    $('review-view').hidden = next !== 'review';
    if (next === 'review' && !reviews) loadReviews();
  }

  async function loadReviews() {
    $('review-error').textContent = '';
    $('review-list').replaceChildren(el('p', {class: 'muted'}, 'Reading uploads from GitHub…'));
    try {
      reviews = await api('/admin/api/reviews');
      $('tab-review').textContent = 'Skill review (' + reviews.pending + ')';
      renderReviews();
    } catch (e) { if (e.message !== 'denied') { $('review-list').replaceChildren(); $('review-error').textContent = e.message; } }
  }

  function renderReviews() {
    const r = reviews;
    const skills = r.categories.reduce((n, c) => n + c.skills.length, 0);
    $('review-tiles').replaceChildren(
      el('div', {class: 'tile'}, el('b', {}, r.pending), 'uploads to decide'),
      el('div', {class: 'tile'}, el('b', {}, skills), 'skills'),
      el('div', {class: 'tile'}, el('b', {}, r.prs.length), 'open upload PRs' + (r.more ? ' (oldest shown)' : '')),
      el('div', {class: 'tile'}, el('b', {}, r.hidden_rejected), 'hidden: same content rejected before'));
    const list = r.categories.map(c => el('section', {class: 'card category'},
      el('h2', {}, (LABELS[c.category] || c.category) + ' — ' + c.skills.length + (c.skills.length === 1 ? ' skill' : ' skills')),
      c.skills.map(s => el('div', {class: 'skill'}, el('h3', {}, s.name), s.uploads.map(u => uploadView(u))))));
    $('review-list').replaceChildren(...(list.length ? list : [el('p', {class: 'card muted'}, 'Nothing to review. Every upload matches the approved library or has been decided.')]),
      ...(r.more ? [el('p', {class: 'muted small'}, 'More uploads are waiting. Decide these first, then refresh to see the next ones.')] : []));
    $('review-prs').replaceChildren(...(r.prs.length ? r.prs.map(prView) : [el('li', {class: 'muted'}, 'No open upload pull requests.')]));
  }

  function prView(pr) {
    const close = el('button', {type: 'button', class: 'ghost', on: {click: () => closePR(pr)}}, 'Close on GitHub');
    return el('li', {},
      el('a', {href: pr.url, target: '_blank', rel: 'noopener noreferrer'}, 'PR #' + pr.number), ' ',
      el('b', {}, pr.sender ? pr.sender.name : 'Unknown sender'), ' ', el('span', {class: 'muted'}, when(pr.submitted_at)),
      el('span', {class: 'sub'}, pr.undecided.length + ' to decide · ' + pr.already_approved.length + ' already approved' + (pr.sender && pr.sender.also.length ? ' · also sent by ' + pr.sender.also.join(', ') : '')),
      pr.error ? el('span', {class: 'sub bad'}, pr.error) : null,
      pr.outside.length ? el('span', {class: 'sub bad'}, 'Also changes files outside the skills folder: ' + pr.outside.join(', ')) : null,
      !pr.error && !pr.undecided.length ? el('div', {}, close) : null);
  }

  function uploadView(u) {
    const sender = u.sender.name + (u.sender.also.length ? ' (also sent by ' + u.sender.also.join(', ') + ')' : '');
    const checks = [];
    for (const b of u.checks.blocked) checks.push(el('li', {class: 'bad'}, 'Blocked: ' + b));
    for (const f of u.checks.flags) checks.push(el('li', {class: 'warn'}, f.path + ' line ' + f.line + ' — ' + (FLAG_NAMES[f.kind] || f.kind) + ': ', el('code', {}, f.text)));
    if (!checks.length) checks.push(el('li', {class: 'ok'}, 'Passed: structure and name, file types and size, secrets, personal paths, client data (lines this upload adds).'));
    const changed = u.files.filter(f => f.status !== 'unchanged');
    const same = u.files.filter(f => f.status === 'unchanged').map(f => f.path);
    return el('div', {class: 'upload'},
      el('div', {class: 'upload-head'}, el('span', {class: 'chip ' + u.status}, STATUS_NAMES[u.status] || u.status),
        el('span', {}, 'Sent by ', el('b', {}, sender)), el('span', {class: 'muted'}, when(u.submitted_at)),
        el('a', {href: u.pr_url, target: '_blank', rel: 'noopener noreferrer'}, 'PR #' + u.pr),
        el('span', {class: 'muted'}, 'uploaded to ' + u.folder + (u.approved_folder && u.approved_folder !== u.folder ? ' · approved copy in ' + u.approved_folder : ''))),
      u.stale ? el('p', {class: 'warn small'}, 'The approved copy changed after this upload was made. The diff is against the approved copy as it is today, so it may undo newer approved edits.') : null,
      el('ul', {class: 'checks'}, checks),
      changed.map(f => fileView(f)),
      same.length ? el('p', {class: 'muted small'}, 'Unchanged: ' + same.join(', ')) : null,
      decideView(u));
  }

  function fileView(f) {
    const names = {added: 'added', modified: 'changed', removed: 'removed'};
    const box = el('details', {class: 'file'}, el('summary', {}, f.path + ' — ' + names[f.status]));
    if (f.path === 'SKILL.md' || f.status === 'removed') box.open = true;
    // Built on first open, so long uploads stay quick to render.
    const fill = () => { if (box.childElementCount === 1) box.append(diffView(f.before, f.after)); };
    box.addEventListener('toggle', fill);
    if (box.open) fill();
    return box;
  }

  function diffView(before, after) {
    if (after === null && before === null) return el('p', {class: 'muted small'}, 'This file cannot be shown as text.');
    const rows = lineDiff(before || '', after || '');
    const keep = rows.map(() => false);
    rows.forEach((row, i) => { if (row[0] !== ' ') for (let k = Math.max(0, i - 3); k <= Math.min(rows.length - 1, i + 3); k++) keep[k] = true; });
    const out = [];
    for (let i = 0; i < rows.length;) {
      if (keep[i]) { const [op, text] = rows[i]; out.push(el('span', {class: op === '+' ? 'add' : op === '-' ? 'del' : 'ctx'}, op + ' ' + text)); i++; continue; }
      let j = i; while (j < rows.length && !keep[j]) j++;
      out.push(el('span', {class: 'gap'}, '… ' + (j - i) + ' unchanged line' + (j - i === 1 ? '' : 's')));
      i = j;
    }
    return el('pre', {class: 'diff'}, out);
  }

  function decideView(u) {
    const select = el('select', {'aria-label': 'Category for ' + u.name},
      el('option', {value: ''}, 'Choose a category…'),
      reviews.categories_available.map(c => el('option', {value: c}, LABELS[c] || c)));
    select.value = u.category === 'uncategorized' ? '' : u.category;
    const ack = u.checks.flags.length ? el('input', {type: 'checkbox'}) : null;
    const approve = el('button', {type: 'button'}, 'Approve');
    const reject = el('button', {type: 'button', class: 'danger'}, 'Reject');
    if (u.checks.blocked.length) { approve.disabled = true; approve.title = 'Fails a required check'; }
    approve.addEventListener('click', () => {
      if (!select.value) { alert('Choose the category for ' + u.name + ' first.'); return; }
      if (ack && !ack.checked) { alert('Tick "I checked the flagged lines" first.'); return; }
      decide(u, 'approve', select.value, !!ack, [approve, reject]);
    });
    reject.addEventListener('click', () => decide(u, 'reject', null, false, [approve, reject]));
    return el('div', {class: 'decide'}, el('label', {}, 'Category ', select), ack ? el('label', {}, ack, 'I checked the flagged lines') : null, approve, reject);
  }

  async function decide(u, decision, category, accept, buttons) {
    const question = decision === 'approve'
      ? 'Approve ' + u.name + ' into ' + (LABELS[category] || category) + '? It is added to main and team members receive it on their next Skills Sync.'
      : 'Reject ' + u.name + ' from PR #' + u.pr + '? It stays out of the team library. The same content will not be shown again.';
    if (!confirm(question)) return;
    buttons.forEach(b => { b.disabled = true; });
    try {
      const result = await api('/admin/api/reviews/decide', 'POST', {pr: u.pr, skill: u.name, decision, category, accept_flags: accept, head_sha: u.head_sha, key: u.key, approved_key: u.approved_key});
      $('review-error').textContent = '';
      if (result.closed) alert('Every skill in PR #' + u.pr + ' is decided. The pull request was closed without merging.');
    } catch (e) { if (e.message !== 'denied') alert(e.message); }
    await loadReviews();
  }

  async function closePR(pr) {
    if (!confirm('Close PR #' + pr.number + ' without merging? Nothing in it is waiting for a decision.')) return;
    try { await api('/admin/api/reviews/close', 'POST', {pr: pr.number}); } catch (e) { if (e.message !== 'denied') alert(e.message); }
    await loadReviews();
  }

  document.addEventListener('DOMContentLoaded', () => {
    $('open').addEventListener('click', () => { token = $('token').value.trim(); if (!token) return; store.set(token); load(); });
    $('token').addEventListener('keydown', e => { if (e.key === 'Enter') $('open').click(); });
    $('refresh').addEventListener('click', load);
    $('signout').addEventListener('click', () => signOut(''));
    $('tab-team').addEventListener('click', () => showView('team'));
    $('tab-review').addEventListener('click', () => showView('review'));
    $('filter').addEventListener('input', () => data && renderPeople());
    if (token) load(); else $('token').focus();
  });
})();
`;
