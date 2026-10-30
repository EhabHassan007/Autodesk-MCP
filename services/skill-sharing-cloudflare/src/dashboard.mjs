// Static admin dashboard. It holds no data or secrets: the browser asks for the
// admin token, keeps it for the tab session only, and fetches /admin/api/overview.
// Every value from the database is inserted as text, never as HTML, because
// names and emails are typed by team members.

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
`;

export const DASHBOARD_JS = `'use strict';
(() => {
  const KEY = 'autodeskSkillAdmin';
  const $ = id => document.getElementById(id);
  let data = null;
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

  async function api(path, method) {
    const r = await fetch(path, {method: method || 'GET', headers: {Authorization: 'Bearer ' + token}, cache: 'no-store'});
    if (r.status === 401 || r.status === 403) { signOut('That admin token was not accepted.'); throw new Error('denied'); }
    if (!r.ok) { let m = 'Request failed (HTTP ' + r.status + ').'; try { m = (await r.json()).detail || m; } catch {} throw new Error(m); }
    return r.json();
  }

  function signOut(message) {
    token = ''; store.clear(); data = null;
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
        el('p', {class: 'muted small'}, 'Device ID: ' + d.id + ' · joined ' + when(d.created_at) + (d.enroll_ip ? ' from ' + d.enroll_ip : ''))));
  }

  async function setActive(d, active) {
    const who = d.person_name || d.label;
    if (!confirm((active ? 'Unblock ' : 'Block ') + who + '?' + (active ? '' : ' Their PC will stop sharing and downloading skills until unblocked.'))) return;
    try { await api('/admin/devices/' + d.id + '/' + (active ? 'unblock' : 'block'), 'POST'); await load(); }
    catch (e) { if (e.message !== 'denied') alert(e.message); }
  }

  document.addEventListener('DOMContentLoaded', () => {
    $('open').addEventListener('click', () => { token = $('token').value.trim(); if (!token) return; store.set(token); load(); });
    $('token').addEventListener('keydown', e => { if (e.key === 'Enter') $('open').click(); });
    $('refresh').addEventListener('click', load);
    $('signout').addEventListener('click', () => signOut(''));
    $('filter').addEventListener('input', () => data && renderPeople());
    if (token) load(); else $('token').focus();
  });
})();
`;
