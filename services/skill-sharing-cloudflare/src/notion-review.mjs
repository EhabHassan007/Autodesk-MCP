// Skill review in Notion. The Worker stays the only thing that can write to main: Notion is a control surface.
//  1. Decisions typed into the "Skill review" database are applied through the same function the dashboard uses, but only when
//     the person who made the edit is on the reviewer list (NOTION_REVIEWERS, Notion user IDs). No list, no decisions.
//  2. Each decision applies to the values the service stored for that page in D1 (notion_review), never to what the page says
//     now, and the live upload is re-checked against them exactly as in the dashboard (the upload or the approved copy changed: refused).
//  3. Skills waiting for review are written as rows. Flagged text is never copied to Notion, only where it is.
import { BUDGET_CALLS, fromProp, norm, NotionError, notionClient, text, toProp } from './notion.mjs';
import { CATEGORIES } from './validation.mjs';

const COST_DECIDE = 15;   // GitHub requests one decision can make (re-read, blobs, tree, commit, ref, comment, close).
const COST_QUEUE = 22;    // GitHub requests reading the review queue for REVIEW_PRS pull requests.
const REVIEW_PRS = 4;
const isoTime = seconds => seconds ? new Date(seconds*1000).toISOString() : null;

export const REVIEW = {Name:'title',Status:'select',Decision:'select',Category:'select','Flagged lines checked':'checkbox',Change:'select',
  Description:'rich_text',Sender:'rich_text',Uploaded:'date','Pull request':'url',Files:'rich_text',Blocked:'rich_text',Flags:'rich_text',
  Result:'rich_text',Reference:'rich_text'};
const FINAL = new Set(['Approved','Rejected','Closed']);   // Rows in these states are never acted on again.

const cap = (word) => word ? word[0].toUpperCase()+word.slice(1) : null;
const reference = item => `${item.pr}/${item.name}/${String(item.head_sha).slice(0,12)}`;

function descriptionOf(item) {
  const manifest = item.files?.find(f=>f.path === 'SKILL.md')?.after ?? '';
  return /^description:\s*(.+)$/m.exec(manifest)?.[1].trim().slice(0,300) ?? '';
}
function filesOf(item) {
  const by = {};
  for (const f of item.files ?? []) if (f.status !== 'unchanged') (by[f.status] ??= []).push(f.path);
  return Object.entries(by).map(([status,paths]) => `${status}: ${paths.slice(0,8).join(', ')}${paths.length > 8 ? ` (+${paths.length-8})` : ''}`).join('; ');
}
// Where the lines are, never what they say: a flagged line may be a secret.
function flagsOf(item) {
  const flags = item.checks?.flags ?? [];
  return flags.slice(0,8).map(f=>`${f.kind} in ${f.path} line ${f.line}`).join('; ')+(flags.length > 8 ? ` (+${flags.length-8} more)` : '');
}

function rowValues(item, sender) {
  const proposed = CATEGORIES.has(item.category) && item.category !== 'uncategorized' ? item.category : null;
  return {Name:item.name,Status:'Pending',Decision:null,Category:proposed,'Flagged lines checked':false,Change:cap(item.status),
    Description:descriptionOf(item),Sender:sender ? [sender.name,...(sender.also ?? [])].join(', ') : 'Unknown sender',Uploaded:isoTime(item.submitted_at),
    'Pull request':item.pr_url+'/files',Files:filesOf(item),Blocked:(item.checks?.blocked ?? []).join(' | '),Flags:flagsOf(item),Result:'',Reference:reference(item)};
}

const props = values => Object.fromEntries(Object.entries(values).map(([name,v]) => [name,toProp(REVIEW[name],v)]));
const read = (page, name) => fromProp(REVIEW[name],page.properties?.[name]);

export async function syncReviews(env, {gh, decide, state, sendersFor, fetcher, sleep, maxDecisions = 2, maxWrites = 15} = {}) {
  const at = Math.floor(Date.now()/1000);
  if (!env.NOTION_TOKEN || !env.NOTION_REVIEW_SOURCE) return {skipped:'not configured',at};
  const reviewers = new Set(String(env.NOTION_REVIEWERS ?? '').split(',').map(v=>v.trim().toLowerCase()).filter(Boolean));
  const summary = {applied:0,not_applied:0,retry:0,created:0,updated:0,closed:0,pending:0,reviewers:reviewers.size,at};
  const client = notionClient(env,{fetcher,sleep});
  const patch = (page, values) => client.call('PATCH',`/pages/${encodeURIComponent(page.id)}`,{properties:props(values)});
  let estimate = 0;
  const settled = new Set();   // Pages this run already wrote a final state to; the page list read above is older than that.
  const used = () => client.calls+estimate;
  try {
    const pages = (await client.readAll(env.NOTION_REVIEW_SOURCE)).filter(p=>!p.archived && !p.in_trash);
    const mappings = new Map((await env.DB.prepare('SELECT page_id,pr,skill,head_sha,content_key,approved_key,flagged FROM notion_review').all()).results.map(r=>[r.page_id,r]));

    // 1. Decisions.
    let decisions = 0;
    for (const page of pages) {
      const decision = read(page,'Decision');
      const status = read(page,'Status') ?? 'Pending';
      if (!decision || FINAL.has(status)) continue;
      const stop = (result, state = 'Not applied') => { settled.add(page.id); return patch(page,{Status:state,Decision:null,Result:result}); };
      const row = mappings.get(page.id);
      if (!row) { await stop('Not applied: the service did not create this row.'); summary.not_applied++; continue; }
      const editor = String(page.last_edited_by?.id ?? '').toLowerCase();
      if (!reviewers.size || !reviewers.has(editor)) {
        await stop(reviewers.size ? `Not applied: this change was made by Notion user ${editor || 'unknown'}, who is not a reviewer. Set the decision again as a reviewer.`
          : `Not applied: no reviewers are configured. Add your Notion user ID (${editor || 'unknown'}) to NOTION_REVIEWERS.`);
        summary.not_applied++;
        continue;
      }
      if (decisions >= maxDecisions || used()+COST_DECIDE > BUDGET_CALLS-2) { summary.retry++; continue; }
      decisions++; estimate += COST_DECIDE;
      const category = read(page,'Category') ?? null;
      try {
        const result = await decide(env,gh,{pr:row.pr,skill:row.skill,decision:decision.toLowerCase(),head_sha:row.head_sha,key:row.content_key,
          approved_key:row.approved_key,category,accept_flags:read(page,'Flagged lines checked') === true});
        settled.add(page.id);
        await patch(page,{Status:result.decision === 'approve' ? 'Approved' : 'Rejected',Decision:null,
          Result:(result.decision === 'approve' ? `Approved into ${category}: commit ${String(result.commit).slice(0,7)}.` : 'Rejected.')+(result.closed ? ' The upload was closed on GitHub.' : '')});
        summary.applied++;
      } catch (error) {
        if (error instanceof NotionError) throw error;
        // A refusal from the service has a safe, readable reason. A GitHub outage (5xx) leaves the row as it is to retry.
        if (error?.status >= 500) { summary.retry++; continue; }
        await stop(`Not applied: ${error?.message ?? 'refused'}`,error?.status === 409 ? 'Changed' : 'Not applied');
        summary.not_applied++;
      }
    }

    // 2. The queue: one row per skill waiting for review.
    if (used()+COST_QUEUE <= BUDGET_CALLS-4) {
      const queue = await gh.reviewQueue(REVIEW_PRS);
      estimate += COST_QUEUE;
      const known = await state(env.DB);
      const items = queue.items.filter(i=>!known.decisions.has(`${i.pr}/${i.name}`) && !known.rejected.has(`${i.name}/${i.key}`));
      const senders = await sendersFor(env.DB,[...new Set(items.map(i=>i.pr_url))]);
      const live = new Map(pages.map(p=>[p.id,p]));
      const byReference = new Map(pages.map(p=>[read(p,'Reference'),p]));
      const mapped = new Map([...mappings.values()].map(r=>[`${r.pr}/${r.skill}`,r]));
      const writes = [];
      const wanted = new Set();
      for (const item of items) {
        wanted.add(`${item.pr}/${item.name}`);
        const values = rowValues(item,senders[item.pr_url]);
        const row = mapped.get(`${item.pr}/${item.name}`);
        const page = row && live.get(row.page_id);
        const entry = {item,values,flagged:item.checks?.flags?.length ? 1 : 0};
        if (page && row.head_sha === item.head_sha && row.content_key === item.key && row.approved_key === item.approved_key) continue;   // nothing new
        if (page) writes.push({...entry,page,kind:'update'});
        else {
          // A page the service made before it could record it (a run that stopped in between) is adopted, not duplicated.
          const orphan = byReference.get(values.Reference);
          writes.push(orphan ? {...entry,page:orphan,kind:'adopt'} : {...entry,kind:'create'});
        }
      }
      // Rows still waiting for a decision whose upload is gone: decided elsewhere, or the pull request was closed.
      for (const [id,row] of mappings) {
        const page = live.get(id);
        if (!page || settled.has(id) || wanted.has(`${row.pr}/${row.skill}`)) continue;
        const status = read(page,'Status') ?? 'Pending';
        if (!FINAL.has(status) && status !== 'Not applied' && status !== 'Changed' && status !== 'Closed')
          writes.push({page,values:{Status:'Closed',Decision:null,Result:'This upload was decided elsewhere or its pull request was closed.'},kind:'close'});
      }
      let done = 0;
      for (const w of writes) {
        if (done >= maxWrites || used()+1 > BUDGET_CALLS) break;
        const values = w.kind === 'adopt' ? {} : w.values;
        if (w.kind === 'create') {
          const created = await client.call('POST','/pages',{parent:{type:'data_source_id',data_source_id:env.NOTION_REVIEW_SOURCE},properties:props(w.values)});
          await env.DB.prepare(`INSERT INTO notion_review(page_id,pr,skill,head_sha,content_key,approved_key,flagged,at) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(pr,skill) DO UPDATE SET page_id=excluded.page_id,head_sha=excluded.head_sha,content_key=excluded.content_key,approved_key=excluded.approved_key,flagged=excluded.flagged,at=excluded.at`)
            .bind(created.id,w.item.pr,w.item.name,w.item.head_sha,w.item.key,w.item.approved_key,w.flagged,at).run();
          summary.created++;
        } else if (w.kind === 'close') {
          await patch(w.page,w.values);
          summary.closed++;
        } else {
          if (w.kind === 'update') await patch(w.page,{...values,Result:'The upload changed after the last version: review it again.'});
          await env.DB.prepare(`INSERT INTO notion_review(page_id,pr,skill,head_sha,content_key,approved_key,flagged,at) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(pr,skill) DO UPDATE SET page_id=excluded.page_id,head_sha=excluded.head_sha,content_key=excluded.content_key,approved_key=excluded.approved_key,flagged=excluded.flagged,at=excluded.at`)
            .bind(w.page.id,w.item.pr,w.item.name,w.item.head_sha,w.item.key,w.item.approved_key,w.flagged,at).run();
          if (w.kind === 'update') summary.updated++;
        }
        done++;
      }
      summary.pending = writes.length-done;
      summary.more_prs = Boolean(queue.more);
    }
    return summary;
  } catch (error) {
    // Only the status code of a Notion failure, never the token or page content.
    return {...summary,error:error instanceof NotionError ? error.message : 'Review sync failed'};
  }
}

export async function saveReviewSync(db, summary) {
  await db.prepare(`INSERT INTO notion_review_sync(id,at,summary) VALUES(1,?,?)
    ON CONFLICT(id) DO UPDATE SET at=excluded.at,summary=excluded.summary`).bind(summary.at,JSON.stringify(summary)).run();
  return summary;
}
export async function lastReviewSync(db) {
  const row = await db.prepare('SELECT summary FROM notion_review_sync WHERE id=1').first();
  return row ? JSON.parse(row.summary) : null;
}
