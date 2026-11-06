---
name: squeeze
description: Shrinks long command output before you read it, to save context and tokens. Use whenever a shell command is likely to print a lot — builds, installs, test suites, logs, git log, recursive listings, large JSON from APIs or tools — or when reading a big log or JSON file just to find what matters in it.
category: uncategorized
---

# squeeze

`squeeze` collapses repeated and near-identical lines, condenses large JSON (long arrays become
first 3 + last 1 items with a count), and for very long output keeps the head, the tail and every
error/warning line it can fit. Output under 6,000 characters passes through unchanged. When it
does shrink something it saves the full original and prints its path in a final
`[squeeze: … Full output: <path>]` line.

## How to call it

Bash:

```bash
npm run build 2>&1 | node ~/.claude/squeeze/squeeze.js; echo "exit: ${PIPESTATUS[0]}"
node ~/.claude/squeeze/squeeze.js path/to/app.log
```

PowerShell (pipe through a file so Unicode survives Windows PowerShell 5.1):

```powershell
npm run build *> "$env:TEMP\out.txt"; $code = $LASTEXITCODE; node "$HOME\.claude\squeeze\squeeze.js" "$env:TEMP\out.txt"; "exit: $code"
```

Options: `--max N` changes the size limit (characters). `--stats` shows how much has been saved.

## When to use it — and when not

Use it for output you need to scan, not copy: build and install logs, test runs, linters,
`git log`, long directory listings, server logs, API responses, large tool or MCP JSON.

Don't use it when you need the exact full text — content you will edit, quote, diff or paste
somewhere — or for commands with short output. Always report the real exit code, not squeeze's.

## If something looks missing

Lines marked `… (+N similar lines) …` or `… [N lines omitted] …` were removed from what you see,
not from disk. If the answer might be in there, search the saved full output (Grep, or
`Select-String` / `grep` on the path from the footer) instead of re-running the command.
Saved originals are kept 7 days.
