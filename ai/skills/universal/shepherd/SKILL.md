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

Opening a PR is not the end. Shepherd it: watch CI **and** incoming
bot/human reviews, adjudicate what lands, fix what's confirmed, and re-watch
— for at most **4 rounds**. Both signals matter and both must end green: a
PR is not done until CI/CD workflows pass *and* no material review findings
remain. This cap is independent of any other loop caps used earlier in the
dev flow.

**Round accounting (read this first):** one round = one fix push, **or**
one no-change adjudication cycle (everything rejected/external — replies
posted, nothing to fix — then back to watching). Count rounds explicitly
(say "round 2 of 4") — the counter only ever increases, every wait below is
bounded, and every path ends in one of the stop conditions in step 6, so
the loop cannot run forever.

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

Then verify the checkout **is** the PR before touching anything: fetch
`gh pr view <n> --repo "$repo" --json headRepositoryOwner,headRepository,headRefName,headRefOid`
and compare against the local branch and HEAD. If the working tree is on a
different branch, repo, or fork than the PR head, stop and switch to (or
ask for) the matching clean checkout first — inspecting, gating, or pushing
from an unrelated checkout is how the wrong code gets "fixed".

## 2. Watch

- Checks: `gh pr checks <n> --repo "$repo" --watch` (fall back to polling
  `gh pr checks` if a long watch is impractical). Treat `skipping` jobs as
  neutral, not failures.
- Reviews and inline comments:
  `gh pr view <n> --repo "$repo" --json reviews,reviewDecision,mergeStateStatus`
  plus `gh api --paginate repos/{owner}/{repo}/pulls/<n>/comments`
  (read-only; will prompt) — `--paginate` matters, or findings past the
  first page are silently never adjudicated. Thread resolution is not in
  the REST payload; check it with the paginated GraphQL `reviewThreads`
  query (`pageInfo{hasNextPage endCursor}`, `nodes{isResolved}`).
  Distinguish bot reviewers (Codex, CodeRabbit, …) from humans, but
  adjudicate both the same way.
- Bot-reaction semantics where the Codex cloud connector is installed: read
  the PR-level reactions explicitly —
  `gh api repos/{owner}/{repo}/issues/<n>/reactions` (they are not in the
  `gh pr view` fields). A bare 👍 from the bot is its clean pass; a lone 👀
  that never resolves means the cloud run failed (re-trigger or note it —
  it is not a finding).
- Wait for **both** signals before deciding anything: let every check
  conclude (bounded — if a check hangs past ~30 minutes, treat it as a
  failure to diagnose, not something to wait on forever), and give the
  reviewer a chance to post on the current head commit (a bounded wait,
  ~10–15 minutes after checks conclude, is enough; if no review lands in
  that window, proceed on CI alone and say so).
- A round begins when a check fails or a review lands material findings.
  All workflows green and no unresolved material findings → **stop at
  green**: report that checks pass and any review verdicts, then stop.
  Never merge — merging is always the maintainer's decision.

## 3. Adjudicate findings (hypotheses, not authority)

Failing CI/CD workflows are findings too — first-class ones, not background
noise behind the reviewer:

- Diagnose every failed workflow from its logs. Resolve the run ID
  explicitly first —
  `gh run list --repo "$repo" --commit <headRefOid> --json databaseId,name,conclusion`
  (or the run URL from `gh pr checks`) — then
  `gh run view <run-id> --repo "$repo" --log-failed`; without an explicit
  ID, `gh run view` opens an interactive selector and may show an
  unrelated run. Reproduce locally where the repo mirrors CI (here,
  `task ci` runs the same targets). If there is a reasonable fix — a real lint/test/build issue,
  a missing wiring step, a broken workflow file — fix it in this round.
- Distinguish unfixable failures: external-service quotas, runner or
  infra outages, and permissions/secrets only the maintainer controls are
  **not** yours to fix and must not consume rounds — one re-run for a
  plainly transient infra failure is fine, then report it as external and
  move on.

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

- Every shepherd-round fix must **pass** the repo's definition-of-done gate
  (`task verify` here) before each push — actually run it and confirm exit
  0, not just intend to; a fix that can't pass verify doesn't get pushed.
  Never `--no-verify`, never weaken a gate to get through it.
- Do **not** re-enter the local challenge/review loops — the post-push
  cloud/bot review is the second-model check at this stage.
- Push the fix commit (conventional message) — this increments the round
  counter — then **return to step 2 and watch again**: the push starts new
  workflow runs and gives the reviewer a fresh head to comment on. Skipping
  the re-watch and declaring victory after a push is the classic failure
  mode this skill exists to prevent.

## 6. Stop conditions

Every shepherd session ends at exactly one of these — there is no path that
loops indefinitely:

1. **Green** — all workflows pass, `reviewDecision` is not
   `CHANGES_REQUESTED`, and no material findings remain. Report the state
   honestly: unresolved threads you answered with rejections stay
   unresolved until the maintainer resolves them, so list them rather than
   claiming a clean slate. Then stop.
2. **Cap reached** — checks still fail or material findings remain after
   4 rounds: stop.
3. **No progress** — the same failure signature or finding survives two
   consecutive rounds unchanged: stop early; burning the remaining rounds
   on it won't help.
4. **Blocked on the maintainer** — the remaining failure needs secrets,
   permissions, external-service action, or a decision only the maintainer
   can make: stop immediately, whatever the round count.

For every stop except Green, post a summary comment on the PR for the
maintainer: what was fixed, what remains unresolved and why (including
findings you dispute, with evidence), and what you recommend. Then end — do
not keep iterating past a stop condition.
