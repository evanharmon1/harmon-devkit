---
name: kickoff
description: >-
  Start-of-session ritual — get oriented in the repo (branch, working tree, open
  PRs/issues) and compose a descriptive session name, emitting a
  copy-pasteable /rename command for the user. Invoke as /kickoff [topic or issue #].
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(git branch --show-current), Bash(task --list-all:*), Bash(task status:*), Bash(gh pr list:*), Bash(gh issue list:*)
---

# Kickoff Session

Formerly `/orient`.

**Arguments:** $ARGUMENTS

Orient at the start of a working session and give it a descriptive name so it
is easy to identify later in the session picker and the Claude mobile app.

## 1. Get oriented

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

**Sweep for stale claims.** The claim `/claim` makes has no owner once its
session ends: `/shepherd` stops before the merge, `/wrap` leaves an open PR
alone, and a personal-account board has no automation — so when the maintainer
merges later, the assignee, `claim:*` label, and card status all
survive with nobody left to clear them. Session start is where that gets
caught, because it is the one step that runs without depending on the session
that made the claim:

```sh
gh issue list --repo <owner/repo> --assignee @me --state all --limit 200 \
  --json number,title,state,labels,url
# ...and by marker, because a claim can outlive its assignee. Query BOTH
# live-claim families during the rolling transition — `claim:*` is the current
# marker, `agent:*` is the legacy fallback a not-yet-provisioned repo still
# applies (run the query once per label):
gh issue list --repo <owner/repo> --label claim:claude --state all --limit 200 \
  --json number,title,state,assignees,url
gh issue list --repo <owner/repo> --label agent:claude-code --state all --limit 200 \
  --json number,title,state,assignees,url
```

**Query both, and union the results.** `/wrap` runs its cleanup as separate
commands on purpose — a combined `gh issue edit` fails wholesale when the repo
lacks the label — so a partial cleanup that removes the assignee and then fails
on the label or `Status` is an expected outcome. An assignee-only
query can never see exactly that leftover, which is the case this sweep is
supposed to recover.

`--state all`, not `open`: the motivating case is a *closing* PR merged after
the session ended, which auto-closes the issue — so `--state open` filters out
exactly the stale claims this sweep exists to find. The explicit `--limit`
matters too; the default returns 30.

**Assignment alone is not a claim.** Plenty of people assign themselves planned
backlog work. Flag an issue only when a claim marker corroborates it — an
`claim:*` label (or a legacy `agent:*` one), a card at `In Progress`, or a
`/claim` claim comment — and then only if its work has finished or stalled.

**A claim comment is history, not state.** Comments are never deleted, so the
claim comment survives its own release — and where the issue was already
assigned to you, `/wrap` correctly leaves that assignment in place too. Both
markers then persist forever, and treating the comment alone as current would
make every future `/kickoff` re-report the same long-released claim. So the
comment counts only when **no later `Claim released —` comment supersedes it**.
Prefer the live markers (`claim:*` label, card at `In Progress`); fall back to
the comment only after checking what follows it.

Report what survives that test as loose ends and point at `/wrap` for the
release commands. Do not clear anything here: this step orients, it does not
mutate.

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
`dev-workflow-skills-138`" — so `/wrap` can recover it from conversation
context even after compaction.

## 5. Summarize

Finish with 3–5 orientation bullets: current branch, clean/dirty tree,
notable open PRs or issues, and the suggested next step. If implementation
work is coming, suggest `/claim` next — it sanity-checks the issue and
claims it, and `/implement` expects that claim to already exist.
