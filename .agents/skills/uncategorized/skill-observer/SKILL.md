---
name: skill-observer
description: Runs quietly alongside every session to improve the user's skills. Logs corrections, stated preferences and gaps that a skill should have handled, spots repeated manual work that could become a new skill, and on request reviews the log and proposes skill updates for approval. Use at the start of every session, and when the user asks "any observations?", "review skill observations" or wants to improve or create skills from past work.
---

# skill-observer

You keep a running log of evidence about how the user's skills perform, so they get better over
time instead of staying frozen. You observe during normal work and only change skills during a
review the user asks for.

Storage (create folders on first use):

- `~/.claude/skill-observations/log/` — one small markdown file per observation
- `~/.claude/skill-observations/principles.md` — lessons that apply across many skills
- `~/.claude/skill-observations/backups/` — copies of skills taken before any edit
- `~/.claude/skill-observations/proposals/` — proposed changes for skills you cannot edit directly

## 1. Observe (every session, silently)

Keep working on the user's task; observing must never slow it down or change its result. Log an
observation when one of these happens:

| Type | Signal |
|---|---|
| `correction` | The user fixes, undoes or redirects output produced while a skill was guiding the work ("no, use the DM layer", "don't ungroup that"). |
| `preference` | The user states how they want something done that a skill should know next time. |
| `gap` | A skill was used but lacked a step, check, value or edge case, so you had to work it out. |
| `new-skill` | The user (or you, for them) does the same multi-step work by hand for the second time or more, and no skill covers it. |
| `trigger` | A skill should have loaded but didn't, or loaded when it shouldn't have. |
| `self` | This observer missed something, logged noise, or its format was unclear. |

Do not log one-off task details, facts that only matter to this project (that belongs in project
memory), or anything the user said not to keep. Never copy secrets, passwords, personal data or
client-confidential content into the log: paraphrase.

Write the observation at the moment you notice it, not at the end, so it survives an interrupted
session. File name: `YYYY-MM-DD-HHMM-<skill-or-topic>-<short-slug>.md`. Content:

```markdown
---
skill: <skill name, or "new" for a new-skill candidate>
type: correction | preference | gap | new-skill | trigger | self
status: open
date: YYYY-MM-DD
project: <folder or project name>
---
**What happened:** one or two sentences, paraphrased.
**Why it matters:** what would go wrong again without a change.
**Suggested change:** the specific edit — which section of the skill, what to add, remove or reword.
```

Before writing, check the log for an open observation on the same point; if there is one, add a
`**Seen again:** <date> — <note>` line to it instead of creating a duplicate. Repeats are the
strongest signal.

Mention logging in at most one short line at the end of your reply (for example
"Logged 1 skill observation (revit-dm-view-sheet-workflow)."). Don't interrupt the work for it.

If the correction is a Revit model standard and the `propose_revit_rule` tool exists, use that
for the rule itself and log here only if a skill also needs to change.

## 2. "Any observations?" (end of session)

When the user asks, look back over the whole session for anything you didn't log yet, log it,
then list everything logged this session in a few lines.

## 3. Review (only when the user asks)

Triggered by "review skill observations", "apply observations", or similar.

1. Read every `status: open` observation and `principles.md`. Group them by skill.
2. For each skill, read its current `SKILL.md` (and the files it references), then propose one
   consolidated change: show the exact text you would add or replace and the observations it
   resolves. For a `new-skill` group, outline the proposed skill (name, description, steps).
3. Ask the user to approve, adjust or reject each skill's change. Never apply a change without
   approval.
4. On approval: copy the skill's folder to `backups/<skill>-<YYYYMMDD-HHMM>/`, then edit it. For a
   new skill, create it under `~/.claude/skills/<name>/` (use the skill-creator skill if
   available). Skills you cannot edit (plugin or built-in skills, anything outside
   `~/.claude/skills/` or a project's `.claude/skills/`) get a file in `proposals/` instead.
5. Set each observation's `status:` to `applied`, `rejected` or `deferred`, adding a one-line
   reason. Don't delete observations.
6. If several observations across different skills share one root cause, add it to
   `principles.md` as a short rule with an example, and check new or updated skills against it.

## 4. Watch yourself

If the user says you logged noise, missed something obvious, or interrupted their work, log a
`self` observation with `skill: skill-observer`. These go through the same review, so this skill
improves too.
