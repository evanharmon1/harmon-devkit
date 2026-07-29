---
name: implement
description: >-
  Drive a claimed issue from branch to open PR — read the issue as a spec,
  work the repo's own dev loop (inner lint gate, definition-of-done gate,
  second-model review, CI mirror), tick acceptance criteria as they are
  verified, and open the PR. Never claims, never merges. Invoke as
  /implement [issue # or URL].
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Edit, Write, Bash(git status:*), Bash(git branch --show-current), Bash(git rev-parse:*), Bash(task --list-all:*), Bash(task status:*), Bash(gh issue view:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh repo view:*), Bash(gh label list:*)
---

# Implement

**Arguments:** $ARGUMENTS

Turn a claimed issue into an open PR. This is the middle of the session
lifecycle — `/preflight` verified and claimed the issue, `/shepherd` takes the
PR from `gh pr create` to green — and it owns exactly the span between them.

**The repository's own policy outranks this file.** Where its `AGENTS.md`
states different gates, loop caps, commit conventions, or PR-title rules,
follow `AGENTS.md` — it is the policy, this skill is the procedure. Read what
that file actually says rather than assuming the shape below; a repo with no
second-model review or no `task ci` is not a repo that is doing it wrong.

**Two things this skill never does.** It never **claims** — `/preflight` owns
the claim, and its claim comment is the single record `/close` reads to undo
exactly what was added. A second writer would make that record a guess. And it
never **merges**: the PR is the deliverable, merging is the maintainer's
decision.

Writes — commits, pushes, `gh pr create`, gate runs — always go through the
normal permission prompt.

## 1. Target and claim

Take the issue number or URL from the arguments; otherwise infer it from the
current branch or the conversation. A URL pins the repository as well as the
number — prefer it. Bind `$repo` from the target and pass `--repo "$repo"` on
every `gh` command; a bare `#123` means *this* repo and nothing else
(`track-work` §1). If the target is ambiguous, ask.

Then confirm the claim exists — **read it, do not write it**:

```sh
gh issue view <n> --repo "$repo" \
  --json state,assignees,labels,comments,closedByPullRequestsReferences
```

`closedByPullRequestsReferences` is in that read deliberately — the refusals
below evaluate it, and a field you never fetched refuses nothing.

Read the outcomes **in this order**, and stop at the first that matches. The
order is the whole point: markers are set independently and go stale
independently, so an issue can carry a live `agent:claude-code` label *and* an
assignee who is not you. Asking "is it mine?" first answers yes on exactly that
issue, and two agents start implementing.

1. **Claimed by someone else** — a different assignee, or an `agent:*` label
   naming another agent. Stop and ask; two agents on one issue is a merge
   conflict with extra steps. This is first because it is the only outcome that
   *disqualifies* markers the later ones would accept.
2. **Already implemented** — an open PR linked by a closing keyword
   (`closedByPullRequestsReferences`), or a **closed** issue. Stop unless the
   user explicitly says to continue.
3. **Claimed by you** — a marker identifying *you* specifically: an `agent:*`
   label for this agent, a card at `In Progress`, or a claim comment not
   superseded by a later `Claim released —`, with no foreign owner from step 1.
   Proceed.
4. **Unclaimed** — stop and offer `/preflight`. It is not ceremony: preflight
   verifies the issue's claims against the live tree, and its findings are
   corrections to fold into the work. Implementing an issue nobody sanity-checked
   is how a fix lands against a file that moved three releases ago.

## 2. Read the issue as a spec

Re-read the issue body and every comment now, at implementation time — not
from what preflight reported. Comments carry scope changes, and a summary is
not the spec.

Extract the **acceptance criteria**. If the issue has none, do not invent
them: state the shape you are implementing to, in one short list, and get the
user's agreement before writing code. Ambiguity resolved silently at this step
becomes a PR that satisfies nobody.

Map each criterion to how it will be **verified** — a test, a gate, a manual
check. A criterion with no verification is either not a criterion or not done;
say which.

## 3. Branch

Feature branch off the default branch, never a commit on `main` directly.
Fetch first — the working tree can be behind, and `Read`/`Grep` only see the
working tree. Name it after the work (`feat/<topic>`, `fix/<topic>`), matching
whatever convention the repo's history already shows.

If the checkout is dirty, park the existing edits before starting; unrelated
work riding into this change is how a PR grows a diff nobody reviewed.

## 4. Inner loop

Small units, fast feedback. Run the repo's fast lint gate — `task check` where
it exists — constantly, and fix what it reports immediately rather than
batching it to the end.

Two obligations that are easy to defer and expensive to defer:

- **Twin files.** Where the repo maintains parallel copies (harmon-init's
  root ↔ `template/` dogfood parity is the canonical case), edit both in the
  same change. A gate that catches this catches it late; the cheap moment is
  now.
- **Tick acceptance criteria as you verify them**, not at PR time — that is
  `track-work` §2 *Tick as you go*, and its `assets/tick-criteria.sh` does the
  edit safely. Ticking at the end means ticking from memory, and a criterion you
  never actually checked ticks just as easily as one you did.

## 5. Definition-of-done gate

When the change feels complete, run the repo's definition-of-done gate —
`task verify` where it exists — and loop edit → verify until it is green.
Actually run it and read the exit code; "should pass" is not a result.

Never `--no-verify`, never weaken or disable a gate, hook, linter, or test to
get a change through. If a gate is wrong, fix the gate as part of the work and
say so.

## 6. Second-model review

Where the repo runs one (harmon-init and harmon-devkit: `task challenge`, then
`task review`), it belongs here — after `verify` is green, before the CI
mirror. Follow the repo's own adjudication contract; the shape it is usually in:

- Treat every finding as a **hypothesis**. Verify it against the code, classify
  it confirmed / plausible-but-unproven / false positive, fix only what is
  confirmed, and state the evidence for anything rejected.
- A stage exits on a **clean re-run**, never on "findings fixed" — commit each
  round's fixes first, or the re-run scopes to the fix rather than the change.
- Respect the round cap and escalate rather than iterate past it.
- These runs are **long** (5–15 minutes is ordinary, past most agent tool-call
  timeouts). Background them and poll; growing output means running, not hung,
  and relaunching a live run only doubles the cost.
- Findings the loop does not gate on (in a P0/P1-gating repo, the P2s) are
  **deferred, not dropped**. Record each one the moment you defer it, in the
  location the repo's `AGENTS.md` specifies — harmon-init uses a branch-keyed
  file under the git directory, because these loops run before there is a PR
  body to write to and their output is otherwise ephemeral. Where the repo
  names no location, keep your own note and carry it into the PR body all the
  same; terminal scrollback is not a record, and a context reset between the
  review and `gh pr create` takes the findings with it. Match on location plus
  substance so a re-reported finding is not recorded twice — a stage exits on a
  clean re-run, so an unchanged deferred finding is reported again by design.

## 7. CI mirror

Run the full local mirror (`task ci` where it exists) and fix what it catches.
This is the last cheap failure; everything after it costs a round on the PR.

## 8. Open the PR

**Re-read the issue immediately before `gh pr create`** — the same fields
step 1 read, including `closedByPullRequestsReferences`. Implementation takes
time, and a claim is a signal, not a lock (`preflight` §5): another session on
the same account converges on identical markers and is invisible in all of
them. If someone took ownership or opened a linked PR while you worked, a
second PR is the expensive way to find out.

- Conventional-commit message and PR title, per the repo's commitlint config.
  Watch for repo-specific title rules that gate a release — harmon-init
  requires a `fix:`/`feat:` title on any PR touching `template/`, and its
  `guard:release-title` task pre-flights that locally before you open the PR.
- **`Closes` vs `Refs` is a decision, not a formality** (`track-work` §2).
  `Closes` hands GitHub permission to delete the issue from the backlog at
  merge — correct only when this PR finishes *every* acceptance criterion.
  Anything partial is `Refs`, and an umbrella issue is almost always `Refs`.
- Body says **what, why, and how it was verified** — name the gates you
  actually ran.
- Move the deferred findings from step 6 into the body under a
  `## Deferred findings` heading, one unchecked task-list item each
  (`- [ ] <file:line> — <finding>`), with enough detail to adjudicate later.
  Then delete the scratch file. Before opening the PR, list the whole
  deferred-findings directory and account for **every** file it holds, not just
  this branch's — a branch renamed mid-change strands its notes under the old
  name where nothing will look for them again.
- Push the branch and `gh pr create`.

## 9. Hand off to shepherd

`gh pr create` returning is the trigger for the next stage, **not the end of
this skill's work**. Continue into the shepherd stage — watch CI *and* incoming
bot/human reviews, settle the deferred findings, reply per thread — and stop
only when shepherd reaches one of its own terminal conditions. Where the repo's
`AGENTS.md` mandates that stage (harmon-init does, and it is user-invocable
only), entering it means **reading `/shepherd`'s `SKILL.md` and following it**,
not calling a slash command an agent cannot call.

Do not treat "PR opened" as a stopping point. An open PR with unpolled checks
is the middle of the work, and the deferred findings from step 6 are still
open — nothing else in the lifecycle settles them.

"All checks pass" is not a stopping point either. Reviews land *after* checks
settle, so an empty comment list read the moment `gh pr checks` returns means
"not reviewed yet", not "nothing to answer".

The one thing that is never yours: **merging**. Report the PR URL, the gates
that passed, and how each deferred finding was settled — then stop at green and
let the maintainer merge.
