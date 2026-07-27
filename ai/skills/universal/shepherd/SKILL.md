---
name: shepherd
description: >-
  Shepherd an open PR to green — watch CI and incoming bot/human reviews,
  treat findings as hypotheses (verify, fix only what's confirmed, explain
  rejections in per-thread replies), push, and re-watch, for at most 4
  rounds. Invoke as /shepherd [PR # or URL].
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(git branch --show-current), Bash(git remote), Bash(git remote get-url:*), Bash(gh pr view:*), Bash(gh pr checks:*), Bash(gh pr list:*), Bash(gh run view:*), Bash(gh run list:*)
---

# Shepherd

**Arguments:** $ARGUMENTS

Opening a PR is not the end. Shepherd it: watch CI and incoming bot/human
reviews, adjudicate what lands, fix what's confirmed, and re-watch — for at
most **4 rounds**. This cap is independent of any other loop caps used
earlier in the dev flow.

Only write-incapable reads are pre-approved (`git log`/`diff`/`show` accept
`--output=<file>`, `git fetch` accepts `--upload-pack=<cmd>`, and
`gh api` can mutate — all of those prompt). Pushes, PR comments, and gate
runs always go through the normal permission prompt.

## 1. Target

Take the PR number or URL from the arguments; otherwise infer it from the
current branch (`gh pr view --json number,url,title`). A URL pins the
repository; otherwise derive it from the branch's remote. Pass
`--repo "$repo"` on every `gh` command — never rely on `gh`'s default repo.
If the target is ambiguous, ask the user.

## 2. Watch

- Checks: `gh pr checks <n> --repo "$repo" --watch` (fall back to polling
  `gh pr checks` if a long watch is impractical). Treat `skipping` jobs as
  neutral, not failures.
- Reviews and inline comments:
  `gh pr view <n> --repo "$repo" --json reviews,comments` plus
  `gh api repos/{owner}/{repo}/pulls/<n>/comments` (read-only; will prompt)
  for inline threads. Distinguish bot reviewers (Codex, CodeRabbit, …) from
  humans, but adjudicate both the same way.
- Bot-reaction semantics where the Codex cloud connector is installed: a
  bare 👍 reaction from the bot is its clean pass; a lone 👀 that never
  resolves means the cloud run failed (re-trigger or note it — it is not a
  finding).
- A round begins when a check fails or a review lands material findings.
  All checks green and no unresolved material findings → **stop at green**:
  report that checks pass and any review verdicts, then stop. Never merge —
  merging is always the maintainer's decision.

## 3. Adjudicate findings (hypotheses, not authority)

For every failing check and every review finding:

1. Verify it against the actual code, CI logs (`gh run view --log-failed`),
   requirements, and tests — reproduce locally when feasible. Do not fix
   what you cannot confirm; do not dismiss what you cannot refute.
2. Classify: **confirmed**, **plausible but unproven**, or
   **false positive**.
3. Fix only confirmed findings; add or improve regression tests where
   appropriate. Never weaken or bypass a gate to get past a finding.
4. For rejected findings, state the evidence for the rejection — a claim
   about a command or platform behavior is cheap to verify empirically
   before rejecting.

## 4. Reply in-thread

Reply to **every** inline review comment in its own thread — fixes ("fixed
in `<sha>`") and rejections (with evidence) alike:

```sh
gh api repos/{owner}/{repo}/pulls/<n>/comments/<comment-id>/replies -f body='…'
```

(comment IDs come from `gh api …/pulls/<n>/comments`). A rollup summary
comment is optional in addition, never a substitute for per-thread replies.

## 5. Fix, gate, push, re-watch

- Every shepherd-round fix must pass the repo's definition-of-done gate
  (`task verify` here) **before** each push. Never `--no-verify`.
- Do **not** re-enter the local challenge/review loops — the post-push
  cloud/bot review is the second-model check at this stage.
- Push the fix commit (conventional message), then return to step 2. That
  completes one round.

## 6. The cap

If checks still fail or material findings remain after **4 rounds**, stop.
Post a summary comment on the PR for the maintainer: what was fixed, what
remains unresolved and why (including findings you dispute, with evidence),
and what you recommend. Then end — do not keep iterating past the cap.
