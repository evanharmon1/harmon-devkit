# AGENTS.md

Guidance for AI coding agents (Claude Code, Gemini CLI, GitHub Copilot, Codex,
...) working in Harmon DevKit. `CLAUDE.md`, `GEMINI.md`, and
`.github/copilot-instructions.md` are symlinks to this file — edit only
`AGENTS.md`.

## Project Overview

Harmon DevKit — my personal developer kit of reusable templates and boilerplates
(Docker Compose, Ansible, shell scripts, serverless functions, and more),
standalone scripts, and AI assets (skills, prompts, agents). This is **not** a
monorepo and has no application code of its own — it is a flat collection of
independent, copy-paste assets organized by category under `templates/`,
`scripts/`, and `ai/`.

Repo: https://github.com/evanharmon1/harmon-devkit — see [docs/README.md](docs/README.md) for the
documentation map, [docs/architecture/README.md](docs/architecture/README.md)
for the architecture, and [DESIGN.md](DESIGN.md) for design/UX intent.

## harmon-platform

One of four repos in **harmon-platform** (Evan's developer & DevOps platform + homelab):
[harmon-init](https://github.com/evanharmon1/harmon-init) (the Copier repo template),
[**harmon-devkit**](https://github.com/evanharmon1/harmon-devkit) (this repo — boilerplates/scripts/AI assets),
[harmon-dotfiles](https://github.com/evanharmon1/harmon-dotfiles) (chezmoi dotfiles),
[harmon-infra](https://github.com/harmonops/harmon-infra) (homelab IaC). See the README for the full table.

## Repository Layout

- `templates/` — copy-paste boilerplates by category: `ansible.md`, `docker/`
  (genericStack, n8n-compose), `scriptTemplates/` (Go, Python, Shell),
  `serverlessFunctionTemplates/` (AWS Lambda, GCP, Netlify), `webTemplates/`.
  Each category has a README; the root README has the full template index.
- `scripts/` — standalone scripts and utilities: `appleScripts/`
  (AppleScript/Automator apps), plus the harmon-init helper scripts
  (`status.sh`, `lint-hygiene.sh`, `test-*.sh`, …) that back the Taskfile.
- `ai/` — AI assets by type: `skills/`, `agents/`, `prompts/`, `rules/`,
  `evals/`, `tools/`, `workflows/`, `mcp/`, `knowledge/`, `memories/`. `skills/`
  is the populated one (Agent Skills convention — a `SKILL.md` with
  `name`/`description` frontmatter); the standouts are `repo/standardize-repo`
  (applies harmon-init's conventions to a repo), the `design/` suite, and the
  `universal/` dev-workflow session suite (`/kickoff`, `/breakdown`,
  `/claim`, `/implement`, `/shepherd`, `/retro`, `/wrap`). `agents/` holds shared
  subagents — one flat `<name>.md` each, thin by design and deferring to the
  skills above; see [ai/agents/README.md](ai/agents/README.md) for the layout
  and the portability contract.
- `snippets/` — small reusable code snippets (placeholder).
- `docs/` — project docs (see [docs/README.md](docs/README.md)); the
  new-project [checklist](docs/CHECKLIST.md) lives here.

## Hard Rules

Non-negotiable, regardless of any autonomy granted elsewhere in this file:

- **Never write to a password manager or credential store unprompted.** Do not
  create, modify, archive, or delete anything in 1Password (items, fields,
  vaults — via the `op` CLI or any other means), OS keychains, or any other
  secret store unless the user explicitly requested that specific write in the
  current conversation. Even when asked, restate exactly what will be written
  and get confirmation before executing — announcing intent and proceeding in
  the same turn is not consent. Read operations (`op read`, `op item list`,
  `op inject` over existing references) are fine.
- **Never reference harmon-dotfiles in shipped output.** harmon-init,
  harmon-devkit, and harmon-infra are independent of the personal dotfiles
  repo: nothing they ship may name it, hardcode a path into somebody's
  dotfiles checkout (`~/.dotfiles/…` leaks the same setup without naming the
  repo), or require dotfiles to be installed, present, or accommodated. A
  consumer cannot read that repo, so rationale belongs here rather than cited
  offsite, and content this repo owns is never described as kept "in sync"
  with it. The permitted coupling is one-way and optional: harmon-dotfiles may
  pull from these repos at a pinned tag; they never point back. Shipped output
  here is `ai/`, `templates/`, `scripts/`, and `snippets/` — the vendored
  skills and agents reach every repo harmon-init generates. Root-only mentions
  ship to nobody and create no dependency (the sibling-repo lists, the
  "related repos" tables, `.claude/settings.json` grants,
  `.devcontainer/related-repos.txt`), which is why `validate:independence`, the
  guard that enforces this (unit-tested by `test:independence`), scans those
  four directories and not the whole
  repo. The enforcement pair — that guard and its unit test — is the only
  carve-out: enforcement has to spell out the string it forbids, exactly as
  this rule's prose does, and a test that cannot write a violation cannot prove
  the guard catches one. The rule text is out of scope because it sits at the
  root, those two files are out of scope by name, and nothing else under the
  four trees is exempt. **chezmoi as a technique is not covered**: `standardize-repo` carries
  real chezmoi guidance because one of the repos it may be pointed at *is* a
  chezmoi source. What must never ship is the personal repo's name and
  rationale that exists only there — not the technique.

## Commands

All commands go through the Taskfile (single source of truth — CI, git hooks,
and humans run the same targets):

```bash
task check       # FAST gate (<~1 min) — run constantly; safe for hooks/agents
task verify      # definition-of-done gate — check + validate + test; run before finishing
task ci          # FULL CI mirror — run before/instead of opening a PR
task fix         # auto-format then lint
task test        # tests
task security    # Semgrep CE + gitleaks + dependency audit
task challenge   # adversarial Codex second-model review — advisory, not in verify/ci
task review      # Codex verification checkpoint before task ci
```

**Foreman** (`task foreman:*`) is the deterministic supervisor that dispatches
armed issues to headless agents, verifies their output, opens draft PRs, and
shepherds them to ready-for-review — merging is always a human decision.
Foreman's own PRs follow the same draft-first lifecycle as the Dev Loop
below: it opens draft PRs (labelled `foreman:dispatched`) under its own
verify gate and promotes them only through its readiness gate — checks
green, review threads resolved, and the `[reviewer]` current-head Codex gate
configured in `.foreman.toml` (the same `@codex review` contract the
shepherd stage uses — fail-closed, bounded attempts) — to
`foreman:ready-for-review`, the hand-off to human review.
The CLI is pinned in `taskfiles/foreman.yml` and fetched via `uvx`;
configuration is `.foreman.toml`. See
https://github.com/ponderousdev/foreman.

`check` is deliberately kept fast (lint) so editors, git hooks, and
AI agents can run it on every change without getting bogged down. `verify` is
the definition-of-done gate — check + validate + test plus the quick
Taskfile/hook guards (the Foreman v2 vocabulary: verify = check + build +
test). `ci` mirrors the CI pipeline locally (`verify`, `security`, the devcontainer permission assert) — so you can
reproduce a CI run on demand instead of waiting on a PR. Keep it that way: a
check the build workflow **gates on** and that can run locally belongs in `ci`
too, or the "mirror" quietly stops being one. The one carve-out: a check that
needs **CI-only infrastructure** (a browser install, a service container,
credentials that only exist on a runner) stays out of `ci` and is documented as
an exception here rather than being faked locally.

## Dev Loop

Bias toward shipping: drive every change to a PR instead of stopping at a green
local diff. Work in small, PR-sized units, and move to the next stage on your
own — a PR handed to a human is the default deliverable, not something to ask
permission for.

**The draft PR is the workbench.** GitHub reports drafts and non-drafts alike as
`OPEN`, so "open PR" says nothing about whose turn it is. These three states do:

- **Draft PR** — the agent's workbench. Implementation, CI, bot review, and
  shepherd fixes are still in progress. Nobody is waiting on a human.
- **Ready-for-review PR** — non-draft. The automated lifecycle is complete and
  the change is handed to a human. Reaching it is a gate, not a judgement call.
- **Merged PR** — always a separate human decision. Agents never merge.

```text
implement → task verify → task challenge → task review → task ci
  → create DRAFT PR → shepherd the draft (CI, deferred findings, reviewers)
  → readiness gate → mark ready for review → human review → human merge
```

Creating the draft is a phase transition, not a terminal state, and every stop
short of the readiness gate leaves the PR **draft** with a blocker report — a
non-draft PR must always mean the automated work is done.

**Draft state is not guaranteed stable.** A known external actor promotes
drafts outside the readiness gate: the ChatGPT Codex Connector holds a
user-to-server authorization on the maintainer's account, so its writes carry
the maintainer's own login, and the observed signature is a flip landing
minutes after Codex review activity on an actively-worked PR
(harmon-devkit#276). Three consequences. `isDraft == false` is never by itself
evidence that the automated lifecycle completed or that a human acted — read it
as a claim to audit, not a state to trust. A shepherd that finds its draft
promoted follows the vendored shepherd skill's unexplained-promotion
procedure — reconcile the head if it independently passes the full gate,
otherwise a single `gh pr ready --undo`, never an undo loop; that "single" is
per PR *across sessions*, bounded by the PR's own timeline (a prior
`convert_to_draft` event blocks a second undo) rather than by any one
session's memory — and when that bound blocks a second undo, the stop leaves
the PR ready with a blocker report, the one sanctioned exception to stops
staying draft. And the actor
field cannot distinguish these events from the maintainer's own clicks, so
attributing one means comparing its timestamp against the session's own command
log rather than reading `actor.login`.

This assumes the repository *can* open drafts: GitHub restricts draft PRs on
private repositories to paid plans (docs/CHECKLIST.md). If `gh pr create
--draft` is rejected, stop and report it — dropping `--draft` to get past the
error silently reverts the lifecycle rather than fixing anything.

**Round caps are resolved, not stated here.** The stages below are each
capped, but this file names no numbers: the caps live in
[`.devflow.toml`](.devflow.toml) as `rigor` tiers, so there is one place to
change them and one place to read them. Resolve in this order — an explicit
instruction in this session, then a `rigor:*` label on the issue, then `default_rigor`,
then a built-in 4 / 4 / 4 if the file is absent. When the change under review
**edits `.devflow.toml` itself**, resolve its caps from the **merge-base** copy
rather than the branch copy: otherwise a branch can lower the very gate it is
changing, and dropping every tier together evades the below-default disclosure
because nothing is left to be below. An explicit human instruction still
overrides.
Labels are multi-select and nothing stops an issue carrying two, so resolution
is **per stage, taking the highest cap present**: a conflict can then only ever
buy more review, never less, and no ranking of the tier names has to be agreed
on anywhere. `min_rounds` resolves under the same principle — the highest
floor present wins. Because that is per stage, two retuned tiers can yield caps
belonging to no single tier — so what you announce is the **caps**, naming a
tier only when one supplied all of them, and the disclosure below compares caps
rather than tier names. A `rigor:` value naming no tier in the file is ignored
rather than guessed at. Treat the label as advisory: it is applied by people and
verified by nothing, and GitHub's **triage** role can label an issue with no
push access at all — so a budget can be retuned by someone who could not edit
`.devflow.toml`. An agent never applies one to itself, and **says so in the
announcement and in the PR body whenever any resolved cap or floor is below what
`default_rigor` would give**, so a reduced budget is visible to the human
reviewer instead of silent.
**Announce the resolved caps on entering the loop** — "rigor:
`<tier>` (`<source>`) → challenge ≤`<n>`, review ≤`<n>`, shepherd `<n>`", filled in
by reading the file rather than from memory — and carry it into the PR body, so
a later round or a different session can see which budget it is spending
instead of inferring one. Everything else about these stages is policy rather
than a parameter and does not vary by tier: the exit condition, the escalation
rule, the round-2 scaffolding checkpoint, the deferred-P2 sidecar, and the
readiness gate all hold identically at every rigor. A cap is a ceiling, never a
quota — a stage that meets its exit condition on round 1 is done, whatever the
tier allowed.

- **Branch** — feature branch off `main`; never commit directly to `main`. For
  parallel or isolated work, take the branch in its own worktree via
  **`task worktree:new -- <name>`** (and `task worktree:rm -- <name>` when
  done) rather than a hand-rolled `git worktree add` — it installs that tree's
  dependencies and proves the hooks fire in it. See
  [docs/conventions.md](docs/conventions.md) § Worktrees, including why
  `-c core.hooksPath=.git/hooks` must never be passed inside one.
- **Edit + `task check`** — the fast inner loop; run it constantly and fix
  lint immediately.
- **`task verify`** — when the change feels done, loop edit → verify until
  green; verify is the definition-of-done gate.
- **`task challenge`** — adversarial second-model review. Adjudicate per
  "Second-Model Review" below, fix confirmed findings, re-run `task verify`,
  then **re-run `task challenge`**. The stage ends when **two consecutive
  rounds adjudicate to zero P0 and zero P1 findings** — whether those rounds
  came back empty, all-P2 as labeled, or P1-labeled and adjudicated down to
  P2. Severity is read off the **adjudicated** column of your adjudication
  table, not off the reviewer's label, and nothing further is owed after the
  second such round: the second round *is* the confirmation, so there is no
  extra clean run to buy. A round that returns **no findings at all** ends
  the stage on its own **once the tier's `min_rounds` floor is met** (1
  wherever a tier does not set it) — an empty round is the old rule's clean
  re-run, so neither a trivial change nor a clean post-fix re-run pays for a
  confirmation pass, and the other two exits satisfy any floor ≤ 2 by
  construction. Fixing the findings is still not the exit
  condition; adjudicated-clean rounds are. The exit carries one
  precondition: every P2 you deferred during the stage must already be in the
  deferred-findings sidecar (see "Deferring P2s" below) — an exit that drops
  a P2 is not an exit, because nothing downstream will ever see it again.
  **P2s do not gate this stage**: carry
  them to the PR (see "Deferring P2s" below). This loop is
  **self-referential** — the fixes you make in response to a round become the
  next round's input, so it can generate its own work indefinitely — and that
  is what the cap defends against: the resolved **challenge cap** bounds the
  challenge → fix → re-challenge rounds; if P0/P1 findings persist at it, stop
  and escalate to the maintainer. A
  capped final round that adjudicates to zero P0/P1 ends the stage by itself — its
  confirmation would be a run the cap forbids, and a clean last round is
  convergence, not the persisting disagreement escalation exists for.
  "Between rounds, check what the findings are about" below is how you catch
  the loop feeding on itself before the cap does, and round 2 is where that
  check is owed rather than optional.
  A `task challenge` round is long — 5–15 minutes is ordinary, past most
  agents' tool-call timeouts — so **run it in the background and poll**
  instead of blocking one call on it. Growing output means running, not hung;
  relaunching a live run only doubles the cost. Re-challenge with a bare
  `task challenge` — it covers the branch's commits *and* the working tree,
  so an uncommitted fix cannot narrow the re-run to itself; an explicit
  `--base`/`--uncommitted` reviews one half only. Committing each round's
  fixes first is still tidier, not load-bearing. Details:
  [docs/guides/codex-review.md](docs/guides/codex-review.md) ("Duration and
  backgrounding").
- **`task review`** — verification-checkpoint review; same adjudication, the
  same two-consecutive-adjudicated-clean exit condition counted over its own
  rounds, the same self-referential shape and so the
  same reason for a cap, and the same background-and-poll handling, under
  its own resolved **review cap**. The two stages are counted separately — and
  capped separately, even where the tier gives them equal numbers: a converged
  challenge says nothing about review.
- **`task ci`** — the full CI mirror; fix anything it catches.
- **Open the draft PR** — conventional commit, push the branch,
  **`gh pr create --draft`** with a clear what/why/verification summary. Then
  fetch `headRefOid,isDraft` and require both the SHA you pushed and
  `isDraft == true`: a non-draft result is not the normal publication path, so
  reconcile it before going further.
- **Git transport** — pushes authenticate over HTTPS via `gh`. Provisioned hosts
  and the devcontainers rewrite GitHub SSH URLs to HTTPS via `url.insteadOf` so
  that git never needs an SSH agent: a headless container has none, forwarding
  one into an interactive container is lockout-prone, and `gh` already holds an
  HTTPS credential that works for both. Never work around an SSH failure by
  pushing to a raw `https://…` URL — a URL push bypasses the named remote and
  leaves stale tracking refs. On an unprovisioned host, force the helper
  and the rewrite against the *named* remote:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' -c url."https://github.com/".insteadOf="git@github.com:" -c url."https://github.com/".insteadOf="ssh://git@github.com/" -c url."https://github.com/".insteadOf="ssh://git@ssh.github.com:443/" -c url."https://github.com/".insteadOf="ssh://git@ssh.github.com/" push`
  (a credential helper only applies to HTTPS, and `insteadOf` is prefix
  matching — every SSH form needs its own mapping, hence all four).
- **Shepherd the draft to ready for review (`/shepherd`, under the resolved
  shepherd cap).**
  `gh pr create --draft` returning is
  the trigger for this stage, not the end of the work — enter it deliberately
  instead of judging for yourself when the PR is finished. The PR stays draft
  for the whole stage; only the readiness gate below may promote it.
  Where the optional
  `/shepherd` skill is vendored it is the procedure, and it is **user-invocable
  only** (`disable-model-invocation: true`): an agent enters the stage by
  reading `.agents/skills/shepherd/SKILL.md` and following it, not by calling a
  slash command it cannot call. Where it is not vendored, this bullet is the
  procedure. Start by
  re-reading any **unsettled** findings the PR description defers to this
  stage — they are open work, not a changelog; mark each one off in the body
  as you settle it. Then watch CI
  (`gh pr checks <n> --watch`) and incoming bot/human reviews. When a check
  fails or a review lands findings, treat the findings as hypotheses: verify
  them against the code, fix only what's confirmed, explain rejections in a
  PR comment, push the fix commit, and watch again. **This is where
  lower-priority findings are settled** — those the PR description defers
  here plus anything the PR reviewers raise: fix, decline with reasoning, or
  file as a follow-up issue, but do not leave them unaddressed.
  Shepherd-round fixes must pass `task verify` before each push; the local
  challenge/review loops are not re-entered — the post-push cloud/bot review
  is the second-model check at this stage.
  **Require a current-head Codex result.** On initial shepherd entry and
  immediately after every fix push, capture the PR's current `headRefOid` and
  the head's push time.
  **Do not hand-roll the polling where a checker is available.** If
  `.claude/skills/shepherd/assets/check-codex-cloud-review.sh` is present —
  the skills sync vendors it with the shepherd skill — run it, in its order:
  `reserve` a cycle against the captured head **before** posting the
  trigger — the durable state must exist before the GitHub write, or an
  interruption between the two leaves an untracked trigger a resumed session
  can double-spend — then post `@codex review`, `attach` the comment ID
  returned for that trigger, and `check`, acting on the exit code it returns
  (0 clean, 10 findings, 11 pending, 12 retry, 13 escalate,
  2 indeterminate). It never
  writes to GitHub, so posting the trigger comment stays yours. Where the
  checker is absent, post `@codex review` and record the request time and the
  comment ID returned for that trigger yourself. Only where that file
  does not exist do you poll the four surfaces yourself — PR reactions,
  top-level comments, reviews, and inline review comments, fetching trigger
  reactions by that exact comment ID — and then watch the surface hand-rolled
  pollers reliably forget: a clean verdict often lands as a **top-level
  comment**, not a review, and missing it reports a finished cycle as
  incomplete.
  The contract below is normative whatever runs it — it is what "terminal"
  means, and the checker is an implementation of it, not a substitute
  definition. A Codex result is terminal for that captured head only
  when it is either: a clean review or top-level comment authored by GitHub
  actor ID `199175422` (`chatgpt-codex-connector[bot]`, type `Bot`) whose
  `Reviewed commit:` identifies that head; a fresh 👍 from that bot on that
  exact trigger comment, created after both the head push and the review
  request, with no newer contradictory bot result; or review findings authored
  by that bot which identify that head and must be adjudicated before the
  cycle can become clean. Earlier comments, reviews,
  inline findings, and reactions never count for a newer head. A 👀 is pending,
  not success; if it disappears without a terminal result, the attempt is
  incomplete.
  Give each attempt a full 10–15 minute window. An attempt is **incomplete**
  when its window elapses with no terminal result for the captured head —
  with the checker, that is exit 12; without it, elapsed time plus the
  absence of terminal evidence is itself the signal. After an incomplete
  first attempt, run attempt 2 the same way as attempt 1: with the checker,
  repeat the reserve-first sequence — `reserve --attempt 2` against the same
  head, then post `@codex review` once more, then `attach` the comment ID
  returned for that trigger — and without it, post the trigger and record the
  request time and the comment ID returned for that trigger yourself; either
  way run one more full window. If both attempts
  are incomplete, stop and escalate without reporting green (with the
  checker, exit 13). Waiting and the
  one allowed re-trigger do not consume a shepherd fix round. Immediately
  before accepting the result or reporting green, re-check the cycle and
  re-read `headRefOid`; a changed head invalidates the result and starts
  a new current-head cycle.
  A badged finding stated **outside an inline thread** — in a top-level
  comment or in a review's own body — has no reply linkage, so the
  reply-based adjudication path cannot reach it and findings outrank a later
  clean result on the same head. The checker's `settle` subcommand records the
  disposition instead; its exact invocation lives with the recipe in
  `ai/skills/universal/shepherd/SKILL.md`, which this file deliberately does
  not restate — the same reason it routes you to the checker rather than
  describing how to poll.
  What belongs here is when it applies. Answer the finding on the PR as usual,
  and note that only two of the three answers end with `settle`: **fixing** it
  means a push, which moves the head and starts a fresh cycle that reviews the
  fix on its own merits, and `settle` neither applies nor accepts that
  disposition. It records the two answers that leave the code alone —
  declining with evidence, or filing it as follow-up work — and requires a
  note for exactly that reason: the record is a human's adjudication, not a
  suppression. It is head-bound and fingerprinted against the body it settled,
  so a finding Codex edits afterwards blocks again while the superseded entry
  survives as the record of what was decided about the earlier text. Once
  every non-thread finding on the head carries one, `check` reports clean with
  a detail naming the disposition applied.
  Shepherd is **externally driven** — CI results and other people's comments
  are its input, so it cannot manufacture a round on its own. A round is one
  fix push, or one no-change cycle where everything is answered and nothing
  needs fixing; waiting on CI or a reviewer is never a round, and this cap is
  independent of any other stage's. What it bounds is other people's findings,
  not self-generated work. It is not wholly immune, though — a reviewer can
  flag the fix your *last* round pushed, so if the rounds start circling your
  own patches, step back and ask whether the findings are about the change you
  set out to make or about a previous round's fix. Whether anything more has
  landed is settled by "Checks green is a non-terminal state" below, not by
  the absence of an immediate reply. Stopping one stage's loop is never a
  decision about another's:
  **a decision to stop one loop does not transfer to another**,
  because each is bounded for its own reason. "We have looped enough" is a
  judgement about one loop's self-generated work, and carrying it here skips
  this stage instead of bounding it, leaving the PR with reviews unanswered.
  The converse also holds: stopping to **escalate** something you cannot
  resolve halts the whole change rather than one loop, so it is not a licence
  to move on to the next stage either — escalate and wait, do not open the PR
  anyway.
  If checks still fail or findings remain at the shepherd cap,
  stop and summarize what's unresolved on the PR for the maintainer. That cap
  does not vary by rigor tier — it bounds other people's findings, not your
  own work, so lowering it would abandon unanswered reviews rather than save
  effort. Where a
  **vendored** skill (`/shepherd`) states a different cap or exit condition,
  **this file wins** — vendored skills are synced on their own release
  cadence and can lag a policy change made here.
- **Checks green is a non-terminal state.** Reporting "all checks pass"
  without having polled reviews and inline comments is not a handoff — it is
  the middle of the shepherd stage. Bot and human reviews land *after* checks
  settle, so `gh pr checks --watch` returns at exactly the moment the review
  has not run yet: an empty comment list read at that instant means "not
  reviewed yet", not "nothing to answer".
  Wait for **both** signals: every check must conclude, and the required
  current-head Codex cycle above must reach a terminal result. Green CI while
  that cycle is pending or incomplete is still non-terminal.
- **Stop at ready-for-review.** When the readiness gate below passes, promote
  the draft **exactly once** with `gh pr ready <n>`, confirm `isDraft == false`
  on the same head, report, and stop. Human approval is deliberately *not* a
  precondition: ready-for-review is the request for that review, not permission
  to merge. Merging is always a human decision.

### Readiness gate

The single definition of "the automated lifecycle is complete", used by
interactive shepherding alike. A
draft may be marked ready for review only when **all** of the following hold for
its current `headRefOid`:

- Required CI checks have concluded successfully. An empty check list is
  *indeterminate*, not a pass — GitHub populates it asynchronously, so a read
  taken moments after the push reports nothing having run rather than nothing
  to run.
- The current-head Codex cycle above is terminal and clean — including clean
  by way of dispositions recorded with `settle`, or the recorded-comment
  equivalent where the checker is absent.
- Every review finding is fixed, declined with evidence, or filed as follow-up
  work.
- Every inline review comment has its required per-thread reply.
- Every finding the PR body defers to this stage is ticked with its
  disposition.
- `reviewDecision` is not `CHANGES_REQUESTED`.
- `mergeStateStatus` is none of `DIRTY`, `BEHIND`, `UNKNOWN`.
- Every required workflow and review app ran on the draft, or was explicitly
  dispatched and settled on this head. Automation available only through
  `pull_request.ready_for_review` is a configuration blocker, because
  promotion can notify CODEOWNERS before its result exists.
- No newer push invalidated any result the gate relied on — re-read
  `headRefOid` immediately before promoting and compare.

Then run `gh pr ready`, confirm the PR is no longer draft and the head did not
change, and hand it to the human reviewer. Treat promotion as a reconciled
transition: fingerprint the PR body, reviews, top-level and inline comments,
and thread resolution immediately before and after promotion (the vendored
shepherd skill's `readiness-gate.sh` is the one implementation of that
snapshot — `check` prints the fingerprint and `fingerprint` recomputes it
for the post-promotion compare); any content change invalidates the gate. Even when the command or
the confirmation fails, bounded-fetch the remote state and reconcile it: if
the open PR is ready on any unverified head or content snapshot, return it to
draft with `gh pr ready --undo` and confirm draft state before resuming or
stopping — a promotion whose gate was never validated must not stand.

A failed **or indeterminate** condition is not a pass: leave the PR draft, post
a blocker report naming what is unresolved, and stop. "The check never ran",
"the fetch errored", and "the reviewer never answered" are all indeterminate.
Promotion is the one-way door in this lifecycle — it notifies CODEOWNERS and
requested reviewers, and `gh pr ready --undo` cannot unsend that — so an
unproven condition means stay draft, not promote and watch.

## Definition of Done

- `task verify` passes.
- Conventional commit message (types: build, chore, ci, docs, feat, fix, perf,
  refactor, revert, style, test).
- Never bypass git hooks (`--no-verify` is forbidden); fix the underlying issue.
- Work on a feature branch; direct commits to `main` are blocked.
- **Never merge to main yourself** — no `gh pr merge`, `git merge`, or push to
  `main` without the maintainer's explicit, per-merge approval, even when CI is
  green and the ruleset would allow it. Open the draft PR and shepherd it —
  checks green with reviews unpolled is not the stopping point — then promote
  it through the readiness gate, report, and stop; merging is always a human
  decision. `gh pr ready` is *not* a merge and you may run it — but only out of
  a passing readiness gate, never to signal "I think this looks done".
- **Reply to every inline PR review comment in its own thread** — bot
  reviewers and humans alike. Treat findings as
  hypotheses: verify each against the code, fix what's confirmed, and post the
  rejection reasoning with evidence otherwise. Post replies with
  `gh api repos/{owner}/{repo}/pulls/<n>/comments/<comment-id>/replies -f body=…`
  (comment IDs from `gh api …/pulls/<n>/comments`). A rollup summary comment
  on the PR is optional in addition, never a substitute for per-thread
  replies.
- Releases are intentional: release-please keeps a rolling release PR from
  conventional commits; merging it cuts the tag/release. Nothing bumps on a
  normal merge. `task release:*` remains as a manual override.
- **A PR that changes `ai/skills ai/agents templates scripts` must use a
  `fix:`/`feat:` (or breaking) PR title.** Squash-merge feeds the PR title to release-please,
  which tags only feat/fix/breaking — so a `chore:`/`docs:` title over these
  paths would merge without cutting a release, and consumers pinning a released
  tag would never receive the change. The `release-content-guard.yml` check
  enforces this; retitle rather than bypass. Other changes keep their normal type.
  Pre-flight it locally with your intended title:
  `PR_TITLE="<title>" BASE_SHA=main task guard:release-title`.

## Second-Model Review (Codex)

A second AI model (the OpenAI Codex CLI) reviews changes on demand. Local and
advisory only: nothing runs in CI, and no `verify`/`ci` step depends on Codex.
Setup and mechanics: [docs/guides/codex-review.md](docs/guides/codex-review.md).

- `task challenge` (→ `challenge:codex`) — adversarial review: challenges the
  architecture and approach; hunts authorization bypasses, data-loss paths,
  unsafe rollback, races, hidden coupling, operational failure modes, and
  needless complexity. Steer it with e.g.
  `task challenge -- --base main focus on the migration path`.
- `task review` (→ `review:codex`) — verification checkpoint: double-checks
  the implementation, consistency, and test coverage before `task ci`.
- `task codex:gate:enable` / `:disable` / `:status` — the automatic
  Claude Code → Codex stop-gate (the codex plugin's Stop hook reviews each
  editing turn and blocks completion on material findings). Per-repo,
  per-machine state; defaults off. Inside Claude Code the equivalents are
  `/codex:review`, `/codex:adversarial-review`, and `/codex:setup`. The
  toggles are approval-gated (`permissions.ask`), `disable` refuses
  non-interactive shells, and agents must **never disable the gate to get
  past a BLOCK** — adjudicate the finding or escalate to the maintainer instead.

These tasks slot into the **Dev Loop** above: after `task verify` goes green,
before `task ci`.
Codex cloud review is also connected to the repo; it reviews PRs too and posts
inline comments only for high-priority findings.
During shepherding, accept its clean comments, reviews, or reactions only under
the current-head cycle above: stale activity is not evidence for the current
commit, and a lone 👀 that disappears or never resolves is an incomplete
attempt.

**Codex Automatic reviews must stay disabled.** Codex triggers a cloud review
on three events: opening a PR for review, marking a draft ready, and an
explicit `@codex review`. The first two fire too late to inform a draft
workbench, and the second is actively harmful here — `gh pr ready` would kick
off a fresh asynchronous review *after* the gate that was supposed to complete
the automated work, so non-draft would stop meaning "ready for a human". The
lifecycle therefore uses explicit `@codex review` requests while the PR is
draft, per the current-head cycle above.

**They are disabled, platform-wide.** Personal Auto review is off; this
repository's Auto code review preference and its review **Trigger** are both on
**Follow personal**. The maintainer confirmed that on 2026-08-13 and recorded
it under the *[human-only] Disable Codex Automatic reviews* item in
[docs/CHECKLIST.md](docs/CHECKLIST.md), which is where the knob-flipping how-to
lives and stays. Nothing in the lifecycle gates on it.

One thing is worth telling the maintainer: if a Codex cloud review ever fires
**unsolicited** — after a push or a promotion that no `@codex review` comment
triggered — say so. That is the 2026-08-10 drift signature, when a repo-level
"On every push" trigger sitting dormant behind the personal toggle armed across
every Follow-personal repo at once. Reporting an anomaly you happened to
observe is not a check to run, and nothing waits on it.

**Treat Codex findings as hypotheses, not authority.** For every finding:

1. Verify it against the actual implementation, surrounding code,
   requirements, and tests.
2. Classify it: confirmed, plausible but unproven, or false positive.
3. Fix only confirmed findings; add or improve regression tests where
   appropriate.
4. Explain why any rejected finding is incorrect or irrelevant.
5. Re-run `task verify` (and the other relevant gates) after fixes.
6. Finish with a concise adjudication table: finding → priority →
   classification → evidence → action taken.

**Between rounds, check what the findings are about.** Those six steps are all
*per-finding*, so a reviewer can be right every round while the loop as a whole
diverges: each fix adds surface, the next round attacks that surface, and the
findings stay individually defensible right up to the cap. Before starting a
round's fixes, ask where they *live* — in the change you set out to make, or in
code that exists only because an earlier round asked for it. **A round whose
findings are all about the previous round's fix is the tell**, and it is
visible in round 2 — the first round that can show it. Do not wait for the
pattern to be unmistakable in round 3, by which point only one round is left.

**Round 2 is the checkpoint, not a suggestion.** Under the two-consecutive
exit the cap is no longer the only thing standing between you and a loop that
feeds on itself, so the check has to happen where it first can. At round 2,
for every finding, say on the adjudication table whether its subject exists
only because an **earlier round of this same stage** added it. A finding that
does gets adjudicated with one of three dispositions written out: **delete**
the scaffolding (which moots the finding — see below), **restructure it to
invariants** (deletion by abstraction — see below), or state that it is in
scope and why the change genuinely needs it. What is not allowed is hardening
round-1's scaffolding by reflex and letting round 3 attack the result.

**Deleting the added code is a legitimate way to converge.** When a
round's findings are about scaffolding rather than the change, weigh removing
that scaffolding against hardening it once more — a remediation can be correct
in the abstract and wrong for the artifact. A documentation guide that has
grown a hand-rolled process supervisor earns real, defensible P1s about per-run
state, process-group supervision, and PID reuse; every one of them becomes moot
when the recipe is deleted instead of hardened. That is not giving up on the
findings — and it is not a way to re-score the round that raised them. A
confirmed P0/P1 keeps its adjudicated priority for its own round whether the
remedy is a fix or a deletion; the remedy either way is input to the **next**
round, and only that later round's review of the changed tree counts toward
convergence. What deletion buys is that the next round finds nothing left to
re-raise. Name the mooted findings
in the adjudication table *and* in the message of the commit that removes the
code — the table is scrollback, but the commit is why the code is gone, and it
is the record a later round or a different session can still find.

**Restructuring to invariants is the same move where deletion is unavailable**
— deletion by abstraction. When the artifact is a spec or document whose
accreted procedure-prose cannot simply be dropped because earlier rounds
legitimately demanded it, replace the attackable procedure with the
universally-quantified property it was approximating, delegate the mechanism
to the implementation surface that can be tested, and carry the review's
attack scenarios over as required test cases. The next round finds no wording
seam to attack, and the obligation is preserved rather than dropped. Name it
on the table and in the commit message exactly as a deletion is named.

One endpoint is worth knowing: if the deletion empties the change *entirely*,
there is no round to converge on — `codex-review.sh` refuses an empty scope
non-zero by design, so the stage cannot pass and re-running will not change
that. Treat it as the answer rather than a failure to work around: a change
that has become empty is abandoned, not reviewed clean.

**Severity gating.** Both tasks ask Codex to label every finding `P0`
(breaks correctness, security, or data integrity in ordinary use, or breaks
an existing contract), `P1` (a real defect or materially wrong design
decision with a plausible trigger), or `P2` (worth knowing, not
merge-blocking: hardening, unlikely edge cases, maintainability, non-critical
test gaps). The scale is defined in `scripts/codex-review.sh`, not inherited
from the Codex CLI's own labels, so the gate keeps its meaning if Codex
changes its output. **Only P0 and P1 gate the local loops.** Adjudicate P2s
too — never suppress or ignore one — but carry them to the PR-shepherd stage
rather than spending a local round on them. A P2 you judge worth fixing
immediately may of course be fixed in place; it just does not hold the stage
open.

**Deferring P2s.** The handoff is the **PR description**: list every deferred
P2 under a `## Deferred findings` heading as an unchecked task-list item —
`- [ ] <file:line> — <finding>` — with enough detail to adjudicate it later.
This is not bookkeeping: `task challenge` and `task review` run locally and
their output is ephemeral, and the cloud reviewer reposts only high-priority
findings, so a P2 that is not written into the PR body is simply lost.

Record each one **the moment you defer it**. Challenge and review both run
before `gh pr create`, so there is usually no PR body to write to yet: append
it to the file
`git rev-parse --git-path "deferred-findings/$(git branch --show-current)"`
names (`mkdir -p` its directory first) — but only if that finding is not
already listed. A P2 you leave open is reported again by design — it is
unchanged code, so every remaining round of the stage and the next stage after
it will raise it; appending blindly would hand the shepherd four copies
of one finding to settle. Match on location plus substance, not exact
wording — the same finding rarely comes back phrased identically. Then
move the list into the description when you open the PR (then delete the
file). Terminal scrollback is not a record — a context reset between
`task challenge` and `gh pr create` would take the findings with it.

**Sweep for orphans when you open the PR.** List the whole tree —
`ls -R "$(git rev-parse --git-path deferred-findings)"` — and account for
every file it holds, not just your branch's. Renaming a branch (`git branch
-m`) or deleting one strands its notes under the old name, where nothing will
ever look for them again; a rename mid-change is exactly when that happens.
Adopt an orphan into this PR if it belongs to this work, otherwise leave it
and say it is there. Listing costs one command; migration logic would cost a
mechanism that then needs its own correctness argument.

That path is not arbitrary. It sits in the **git directory**, so it is
deterministic (any later session in this checkout finds it the same way, and
`git rev-parse` resolves it correctly inside a linked worktree) and invisible
to `git status`. It is keyed by **branch** because an ordinary clone switches
branches in place: with one shared file, opening branch B's PR would sweep up
branch A's findings and then delete A's only copy of them. The branch name
becomes a *path*, verbatim and without a suffix — folding `/` to `-` would
collide `feat/x` with `feat-x` and reintroduce exactly that loss, and adding
an extension would make `foo` (a file) block `foo.md/bar` (needing a
directory). Used as-is, the mapping is git's own ref namespace, and git
already forbids one live branch from being a path prefix of another. A note in the *worktree* would be worse than none:
`codex-review.sh` puts uncommitted files in scope whenever the tree is dirty,
so the note would be handed to the next bare `task challenge` as part of the
change under review — a file of open findings, presented to the reviewer as
work to adjudicate.

The shepherd stage settles every entry and **edits the PR body to tick it**
(`- [x] … — fixed in <sha>` / `declined: <reason>` / `filed as #<n>`) in the
same round. The checkbox is the resolution state: an entry left unchecked is
open work, so a later round — or a different session — can tell at a glance
what it still owes without re-adjudicating what is done. That obligation is
stated here and in the Dev Loop above, and holds whether or not the optional
`/shepherd` skill is installed to automate it.

**Loop cap and exit:** a stage — challenge and review counted separately —
ends when **two consecutive rounds adjudicate to zero P0 and zero P1
findings**, and never on "findings fixed" alone. Those rounds may be empty,
all-P2 as labeled, or P1-labeled and adjudicated down to P2; what counts is
the **adjudicated** column of the table, not the reviewer's label, and the
second such round is itself the confirmation, so no further run is owed. Two
exits are faster still. A round with **no findings at all** ends the stage by
itself **once the tier's `min_rounds` floor is met** (1 wherever a tier does
not set it) — an empty round is exactly the old rule's clean re-run, so
neither a trivial change nor a clean post-fix re-run pays for a confirmation
pass; the two-consecutive and capped-clean exits satisfy any floor ≤ 2 by
construction, so the floor binds the empty-round path alone. And a **capped final round** that adjudicates to zero
P0/P1 also ends the stage by itself: the confirmation it would otherwise owe
is a run the cap forbids, and a rule that strands a stage holding a clean
last round and no valid exit would be wrong — the cap bounds work, it does
not manufacture escalation. What the rule spends is bounded the other way
too: a stage pays at most one round confirming convergence, where the old
practice could spend every remaining round re-proving a change nobody still
disputed. Two things ride along with the exit: every P2
deferred during the stage must already be recorded in the sidecar (an exit
that drops a P2 is not an exit), and round 2 owes the scaffolding checkpoint
above. Each stage's cap is the one resolved from `.devflow.toml` per "Round
caps are resolved, not stated here" in the Dev Loop above (challenge → fix →
re-challenge, and likewise for review), counted separately per stage; if
P0/P1 disagreement persists at the cap, stop and surface it to the maintainer
instead of iterating further — escalation at the cap is for P0/P1 that
**persist**, nothing else. The maintainer may always ask for more rounds —
convergence is a floor on when you may stop, not a ceiling on what they can
order.

One caveat on the automatic stop-gate: the codex plugin's Stop hook applies
its **own** notion of a material finding and may BLOCK on something you have
classified P2. Adjudicate it (fix it, or state the reasoning) — **never**
disable the gate to get past a BLOCK. A BLOCK is settled on its own terms and
against the hook, not against this rule: it neither reopens a stage that has
already converged nor counts as one of that stage's rounds.

## Conventions

Full reference: [docs/conventions.md](docs/conventions.md). Highlights:

- Conventional Commits; `group:action` Taskfile naming (e.g. `lint:shell`, not
  `shell:lint`); pin actions by SHA + `# vX.Y.Z`.
- Git hooks are managed by lefthook (`lefthook.yml`) and delegate to Taskfile
  targets — don't duplicate logic in hooks or workflows.
- Keep Taskfile `cmds:` trivial — inline strings aren't linted (`lint:shell`
  only covers `scripts/*.sh`). Put any pipeline/conditional/loop/`curl | bash`
  in a `scripts/*.sh` the task calls. `task test:tasks` checks the Taskfile
  compiles and setup tasks are safe no-ops.
- Indentation: 2 spaces default, 4 for Python/Terraform/Shell (`.editorconfig`).
- Secrets never go in git; local env via 1Password (`op run` / `op inject`).
- When generating or rotating secrets, keep secret values on stdin and use the
  destination-only helpers:
  `task secret:set:1p VAULT=... ITEM=... FIELD=... [SECTION=...]` for existing
  1Password fields and `task secret:set:gh NAME=... REPO=owner/repo` for GitHub
  repo secrets. Never pass secret values as command arguments, `--body` values,
  exported env vars, or Taskfile vars. The hard rule above still applies:
  agents must not run `secret:set:1p` or otherwise write to a password manager
  without explicit user confirmation for that exact write.
