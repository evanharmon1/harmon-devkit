---
name: preflight
description: >-
  Pre-implementation sanity check — verify the latest state of the target
  issue, related PRs, and recent merges against the live repo, surface
  blockers, then claim the issue (assign, label, comment). Invoke as
  /preflight [issue #].
disable-model-invocation: true
allowed-tools: Read, Bash, Glob, Grep
---

# Preflight

**Arguments:** $ARGUMENTS

Run this right before starting implementation. It is the lightweight
interactive sibling of harmon-init's `foreman-preflight` agent and uses the
same severity vocabulary. Everything is read-only except the final
issue-claiming step.

## 1. Target

Take the issue number from the arguments; otherwise infer it from the current
branch or conversation. If it is ambiguous, confirm with the user before
proceeding.

## 2. Refresh state (read-only)

- `git fetch --prune`
- Repo status: `task status:git` and `task status:gh` if those targets exist
  (`task --list-all 2>/dev/null | grep -q 'status:git'`); otherwise
  `git status -sb` and `gh pr list --state open`.
- The issue itself: `gh issue view <n> --comments`.
- Each related PR:
  `gh pr view <pr> --json state,mergeStateStatus,reviewDecision,title,url`
  and `gh pr checks <pr>`.
- Recent history against the **fetched** default branch (local `main` may be
  stale, and the default branch is not always named `main`):
  `default="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"`,
  then `git log --oneline "$default"..HEAD` and
  `git log --oneline -10 "$default"` for merges that may have changed the
  ground under the issue.

## 3. Sanity analysis

Verify claims against the code — do not speculate. Look for:

- **Stale references** — files, APIs, or docs the issue mentions that no
  longer match the live tree.
- **Overlap or contradiction** — other open issues or in-flight PRs touching
  the same files or solving the same problem.
- **Ambiguities** — anything that would force you to invent requirements;
  surface these before coding, not during.
- **Human-only steps** — anything needing credentials or access the agent
  does not have.

## 4. Report findings

Numbered findings, each with evidence and a severity: `blocker`,
`correction`, or `note`. If there is any `blocker`: stop, do **not** claim
the issue, and ask the user how to proceed.

## 5. Claim the issue

The only writes this skill makes. Show the commands before running them, and
if `gh` is unauthenticated or lacks write access, report the commands for the
user to run instead of failing the flow:

- `gh issue edit <n> --add-assignee @me`
- Label only if the label exists (`--limit` matters — the default returns
  only 30 labels):
  `gh label list --limit 1000 --json name -q '.[].name' | grep -qx in-progress && gh issue edit <n> --add-label in-progress`
- `gh issue comment <n> --body "Claiming — starting implementation on branch <branch> (session <name>)."`

## 6. Hand off

One line — "clear to implement" (or not) — plus the corrections from the
findings that should be folded into the work.
