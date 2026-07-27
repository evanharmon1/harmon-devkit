---
name: start
description: >-
  Start-of-session ritual — orient in the repo (branch, working tree, open
  PRs/issues) and compose a descriptive session name, emitting a
  copy-pasteable /rename command for the user. Invoke as /start [topic or issue #].
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(git log:*), Bash(git branch --show-current), Bash(task --list-all:*), Bash(task status:*), Bash(gh pr list:*), Bash(gh issue list:*)
---

# Start Session

**Arguments:** $ARGUMENTS

Orient at the start of a working session and give it a descriptive name so it
is easy to identify later in the session picker and the Claude mobile app.

## 1. Orient

Prefer the repo's own status plumbing when it exists; fall back to raw
commands otherwise:

- If **both** targets exist — `task --list-all 2>/dev/null | grep -q 'status:git'`
  and the same check for `status:gh` — run `task status:git` and
  `task status:gh`. Caution: `task` executes the checked-out Taskfile; on an
  untrusted branch (e.g. reviewing a stranger's PR), use the raw fallback
  instead.
- Otherwise run `git status -sb`, `git log --oneline -5`,
  `gh pr list --limit 10`, and `gh issue list --limit 10`.

Keep this bounded — if `gh` hangs or is unauthenticated, note it and move on
rather than blocking the session start.

## 2. Compose the session name

Kebab-case, at most ~40 characters, most-specific-first. Pick the source in
this priority order:

1. The topic or issue number given in the arguments.
2. The issue/PR implied by the current branch or conversation.
3. The branch name.
4. Ask the user.

Pattern: `<topic>` or `<topic>-<issue#>` — e.g. `dev-workflow-skills-138`.
No `done-` prefix and no date (the picker already shows recency).

## 3. Emit the rename

You cannot rename the session yourself — there is no tool or command for the
model to do it. Say so explicitly, and output the command for the user to
paste, on its own line in a fenced block:

```text
/rename dev-workflow-skills-138
```

## 4. Record the name

Restate the chosen name in prose — e.g. "Session name:
`dev-workflow-skills-138`" — so `/close` can recover it from conversation
context even after compaction.

## 5. Summarize

Finish with 3–5 orientation bullets: current branch, clean/dirty tree,
notable open PRs or issues, and the suggested next step. If implementation
work is coming, suggest running `/preflight` first.
