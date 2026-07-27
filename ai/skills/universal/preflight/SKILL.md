---
name: preflight
description: >-
  Pre-implementation sanity check — verify the latest state of the target
  issue, related PRs, and recent merges against the live repo, surface
  blockers, then claim the issue (assign, label, comment). Invoke as
  /preflight [issue #].
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git fetch:*), Bash(git status:*), Bash(git log:*), Bash(git remote:*), Bash(git branch:*), Bash(git symbolic-ref:*), Bash(task --list-all:*), Bash(task status:*), Bash(gh issue view:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh pr checks:*), Bash(gh label list:*), Bash(gh repo view:*)
---

# Preflight

**Arguments:** $ARGUMENTS

Only read commands are pre-approved for this skill; the claim writes in
step 5 intentionally go through the normal permission prompt, so untrusted
issue content can never trigger a mutation silently.

Run this right before starting implementation. It is the lightweight
interactive sibling of harmon-init's `foreman-preflight` agent and uses the
same severity vocabulary. Everything is read-only except the final
issue-claiming step.

## 1. Target

Take the issue number from the arguments; otherwise infer it from the current
branch or conversation. If it is ambiguous, confirm with the user before
proceeding.

## 2. Refresh state (read-only)

- Pick the authoritative remote, fetch **it**, and bind the GitHub repo
  identity to it up front — in a multi-remote checkout `gh`'s default repo
  can be a different repository, so every `gh` command in this skill (reads
  and writes alike) must pass `--repo "$repo"`:
  `remote="$(git remote | grep -qx upstream && echo upstream || echo origin)"`,
  `git fetch --prune "$remote"`,
  `repo="$(gh repo view "$(git remote get-url "$remote")" --json nameWithOwner -q .nameWithOwner)"`.
- Repo status: `task status:git` and `task status:gh` if **both** targets
  exist (probe each with `task --list-all 2>/dev/null | grep -q '<target>'`);
  otherwise `git status -sb` and `gh pr list --state open`. Caution: `task`
  executes the checked-out Taskfile; on an untrusted branch use the raw
  commands.
- The issue itself: `gh issue view <n> --comments`, plus its linked work —
  `gh issue view <n> --json state,assignees,closedByPullRequestsReferences` —
  so a PR already fixing the issue is caught even if no comment mentions it.
- Each related PR:
  `gh pr view <pr> --json state,mergeStateStatus,reviewDecision,title,url`
  and `gh pr checks <pr>`.
- Recent history against the **fetched** default branch (local `main` may be
  stale, and the default branch is not always named `main`). Using the
  `$remote` fetched above, refresh its cached default-branch ref
  (`git remote set-head "$remote" --auto`), then
  `default="$(git symbolic-ref --short "refs/remotes/$remote/HEAD")"`,
  `git log --oneline "$default"..HEAD`, and `git log --oneline -10 "$default"`
  for merges that may have changed the ground under the issue.

## 3. Sanity analysis

Verify claims against the code — do not speculate. First, the issue's own
state: if it is **closed**, **assigned to someone else**, or has an open
linked PR already implementing it, that is a `blocker` — do not claim without
explicit confirmation from the user. Then look for:

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

The only writes this skill makes; all target `--repo "$repo"` from step 2.
Immediately before the first write, re-fetch
`gh issue view <n> --repo "$repo" --json state,assignees,closedByPullRequestsReferences`
— the ground can shift during the analysis, and a now-closed, newly-assigned,
or newly-implemented issue is a `blocker` again. Show the commands before
running them, and if `gh` is unauthenticated or lacks write access, report
the commands for the user to run instead of failing the flow:

- `gh issue edit <n> --add-assignee @me`
- Label only if the label exists (`--limit` matters — the default returns
  only 30 labels):
  `gh label list --limit 1000 --json name -q '.[].name' | grep -qx in-progress && gh issue edit <n> --add-label in-progress`
- Comment via stdin with a quoted heredoc so the branch/session values are
  never re-evaluated by the shell (a branch name can contain `$(…)`):

  ```sh
  gh issue comment <n> --body-file - <<'EOF'
  Claiming — starting implementation on branch <branch> (session <name>).
  EOF
  ```

After claiming, re-fetch the assignees (`gh issue view <n> --json assignees`):
`--add-assignee` accumulates rather than arbitrates, so if someone else
claimed concurrently, surface it and coordinate before implementing.

## 6. Hand off

One line — "clear to implement" (or not) — plus the corrections from the
findings that should be folded into the work.
