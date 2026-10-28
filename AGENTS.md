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

Repo: https://github.com/evanharmon1/harmon-devkit — see [docs/index.md](docs/index.md) for the
documentation map, [docs/architecture/index.md](docs/architecture/index.md)
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
- `ai/` — AI assets by type: `skills/`, `agents/`, `schemas/`, `prompts/`,
  `rules/`, `evals/`, `tools/`, `workflows/`, `mcp/`, `knowledge/`,
  `memories/`. `skills/` is the populated one (Agent Skills convention — a
  `SKILL.md` with `name`/`description` frontmatter); the standouts are `repo/standardize-repo`
  (applies harmon-init's conventions to a repo), the `design/` suite, and the
  `universal/` dev-workflow session suite (`/kickoff`, `/breakdown`,
  `/claim`, `/implement`, `/review`, `/integrate`, `/retro`, `/wrap`). `agents/` holds shared
  subagents — one flat `<name>.md` each, thin by design and deferring to the
  skills above; see [ai/agents/README.md](ai/agents/README.md) for the layout
  and the portability contract. `schemas/` holds shared JSON Schemas for
  dev-flow v2 agent results, with a conformance fixture corpus under
  `ai/schemas/fixtures/`.
- `snippets/` — small reusable code snippets (placeholder).
- `docs/` — project docs (see [docs/index.md](docs/index.md)); the
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
- **Never terminate a process without explicit user approval.** `kill`,
  `pkill`, `killall`, and `xkill` can destroy work owned by another session or
  user; process names and PIDs do not prove ownership, and no session-owned PID
  field is authoritative here. Only direct `kill -l` and `kill -0 <PID>` probe
  segments are exempt.
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
task ci          # full CI mirror — on demand when CI is red and you want to iterate locally
task fix         # auto-format then lint
task test        # tests
task security    # Semgrep CE + gitleaks + dependency audit
task challenge   # adversarial Codex second-model review — advisory, not in verify/ci
task review      # Codex verification checkpoint
task foreman:plan -- --milestone <n>  # foreman: dry-run the dispatch graph
```

**Foreman** (`task foreman:*`) is the deterministic supervisor that dispatches
armed issues to headless agents, verifies their output, opens draft PRs, and
integrates them under the Dev Loop merge queue — merging is always a human decision.
Foreman's own PRs follow the same draft-first lifecycle as the Dev Loop
below: it opens draft PRs (labelled `foreman:dispatched`) under its own
verify gate and promotes only the merge-queue head through the handoff check —
required checks green, every thread settled, and the `[reviewer]` current-head Codex gate
configured in `.foreman.toml` (the same `@codex review` contract the
integration stage uses — fail-closed, bounded attempts) — to
`foreman:ready-for-review`, alongside `merge-ready` at the queue head.
The CLI is pinned in `taskfiles/foreman.yml` and fetched via `uvx`;
configuration is `.foreman.toml`. See
https://github.com/ponderousdev/foreman.

`check` is deliberately kept fast (lint) so editors, git hooks, and
AI agents can run it on every change without getting bogged down. `verify` is
the definition-of-done gate — check + validate + test plus the quick
Taskfile/hook guards (the Foreman v2 vocabulary: verify = check + build +
test). `ci` mirrors the CI pipeline locally (`verify`, `security`, the
devcontainer permission assert; `verify:skills` is omitted because harmon-devkit
is the skills source and its dogfood links refuse self-vendoring) — use it on demand when
CI is red and you want to iterate locally instead of waiting on each PR push.
Keep it that way: a check the build workflow **gates on** and that can run
locally belongs in `ci` too, or the "mirror" quietly stops being one. The one
carve-out: a check that needs **CI-only infrastructure** (a browser install, a
service container, credentials that only exist on a runner) stays out of `ci`
and is documented as an exception here rather than being faked locally.

## Dev Loop

Bias toward shipping: drive every change to a PR instead of stopping at a green
local diff. Work in PR-sized units; a PR handed to a human is the deliverable.

**The loop is the stage skills; this section is the policy they run under.**
`/orchestrate` is the session's standing operating mode; it dispatches
`/implement` (claimed issue → gates → draft PR), `/review` (both confidence
stages), and `/integrate` (draft → handoff check → merge queue). `/claim` comes first —
the primary session or orchestrator can invoke `/claim` when appropriate without
asking for confirmation (or it can be user-invoked) to ensure the issue is verified
and claimed before implementation begins (preserving `/claim`'s own preflight and
target-confirmation boundaries; subagents never claim); `/claim` owns the claim
writes, and `/implement` never claims directly. There is **no `dev-loop` skill** — those stages *are* the loop;
retired names map on (`gauntlet` → `review`, `shepherd` → `integrate`), and a
pin still shipping a predecessor runs it under this policy.
The skills carry the procedure — round mechanics, adjudication records, review
polling, the PR-open ritual — entered by reading their `SKILL.md`. In this
repository, active stage skills omit `disable-model-invocation: true` and
are model-invocable as described in `ai/skills/README.md`. Where none is vendored,
this section is the whole contract and its invariants are owed anyway; where a
**vendored** skill states a different cap, floor, or exit condition, **this file wins**.

```text
/claim → /implement [ code → task verify → challenge → review → task security → DRAFT PR ]
  → /integrate [ CI → deferred findings → reviewers → handoff check ]
  → merge queue [ parked drafts → queue head: promote + merge-ready ] → human merge
```

### PR states and labels

Use the [harmon-devkit glossary](https://github.com/evanharmon1/harmon-devkit/blob/main/docs/glossary.md)
for **Draft**, **Promoted**, **Merged**, **Closed**, **Working** (`claim:*`),
**Needs review** (`needs-review`), **Parked** (`parked`), **Blocked** (`blocked`),
**Merge-ready** (`merge-ready`), **handoff**, and **handoff check**. These are the
shared terms; promotion alone is never evidence that a PR is merge-ready now.
Merged and Closed remain human decisions. Agents may promote and demote.

Creating a draft is a phase transition. Publish the lane's result as a draft;
the orchestrator owns integration and the merge queue. Report an incomplete
check as blocked, and a passed PR waiting its turn as parked. A rejected
`--draft` is reported, never dropped.

### Policy invariants

Binding on every stage, skill, and harness, whatever rigor resolved:

- **Draft-first.** Commit and push whatever the rounds have not already pushed,
  publish with `gh pr create --draft`, then fetch `headRefOid,isDraft` and
  require both the SHA you pushed and `isDraft == true`. Only a passing handoff
  check promotes the queue head with `gh pr ready`; then confirm
  `isDraft == false` on that same head. Re-run the live check before applying
  `merge-ready` and before reporting it. Human approval is deliberately *not*
  a precondition for promotion; merging remains a separate human decision.
- **Never merge, never cut a release, never rewrite pushed history.** Merging
  and releasing are the maintainer's decisions, and nothing already pushed is
  amended, rebased, or force-pushed, at any stage.
- **Never bypass a gate** — not the git hooks, not a stop-gate BLOCK, not a
  failed *or indeterminate* handoff-check condition. Fix the cause, or escalate.
- **Every push you author passes its round gate, then a secret scan** — `.devflow.toml`'s
  `[gates]` names them (`verify` for a code push, `check` for a docs-only one,
  `security:secrets` always, `security` before the draft PR); the `pre-push`
  hook runs what it can, otherwise run them yourself. `task ci` stays on demand.
  A head move GitHub makes at your request (the catch-up below) authors no
  bytes; the handoff check's CI condition on the new head governs it instead.
- **Catch a behind PR up on the server, at the gate.** When the base merges
  without conflicts, first re-read `baseRefName`: if it no longer matches the
  base the gate captured, stop, because `base-retargeted` applies and no call is
  made. Otherwise request GitHub update-branch in merge mode with the captured
  head as `expected_head_sha` (REST `PUT …/pulls/<n>/update-branch`;
  `gh pr update-branch` takes no such flag), never `--rebase`, which rewrites
  pushed history. Where available, use the integrate skill's
  `assets/update-branch.sh` helper. The new head is the catch-up only if its
  parents are exactly the captured head, then the base tip the gate read,
  its committer is `GitHub <noreply@github.com>`, and its web-flow signature
  verifies. Any other head (a concurrent push, an `expected_head_sha`
  refusal) is not a catch-up but a newer push under the handoff check's "no
  newer push" condition; a head still unmoved when a bounded wait ends is
  indeterminate, so stop and report rather than request again. Then
  fetch the PR's head repository and branch explicitly in every local checkout,
  fast-forward to the recorded catch-up OID (`git merge --ff-only <catch-up OID>`),
  and confirm `HEAD` equals it before committing again. Let CI run on the
  new head. Where Codex cloud review is on and the `integration` cap is
  positive, ask `carry` whether the clean verdict attests it, or run the
  ordinary current-head cycle. It spends no remediation
  round. Only a genuine merge refusal (a conflict, a ruleset that rejects the
  merge commit), or a base merge that must ship with a fix, falls back to a
  local merge under the full round gate, as an ordinary remediation round. A
  fork without maintainer edits cannot take a local merge either: stop and ask
  for maintainer edits. Catch up the merge-queue head when its base moves;
  return it to draft only if the new head owes a review. Parked PRs stay
  drafts and are not caught up; report their drift. Reconcile once, base
  into branch only; the ledger names it a catch-up, not a remediation push.
- **One conventional commit per adjudicated round, pushed** to the branch's own
  writable remote (`git push -u <remote> <branch>` on the first push). Per *round*,
  not per finding: five fixes are one commit, a round with nothing to fix pushes
  nothing. It bounds a lost environment to the current round's *code* and surfaces a
  push-permission gap at round 1 rather than at `gh pr create`; it carries nothing else
  — the deferred-findings sidecar and the adjudication ledger live in the git directory,
  are never pushed, and a resumed session re-runs the stage anyway. Once the draft
  exists, pushes batch per remediation round (counted against the `remediation` cap)
  — each one spends a CI run and, while a cycle remains under a positive `integration`
  cap, starts a fresh current-head review cycle (a cap of 0 or a spent cap starts none).
- **Findings are hypotheses, never authority** — verify each against the code,
  fix only what is confirmed, post the evidence for anything rejected. Whatever
  the stage does not gate on is **deferred, never dropped**: recorded the moment
  you defer it, carried into the PR body, and settled — fixed, declined with
  evidence, or filed as follow-up — before the gate can pass.
- **Caps, floors, and tiers resolve from `.devflow.toml`** (§ "Rigor and
  Strategy"), under its merge-base rule. A cap is a ceiling, never a quota; one
  reached with a P0/P1 still open is an escalation, not a licence to move on;
  and each stage is bounded for its own reason, so a decision to stop one loop
  is never a decision about another's.
- **Never self-apply a `rigor:`, `strategy:`, or `tier:` label** (nor the
  retired `method:`), except the derived classification Tier (§ "Rigor and
  Strategy"), and never treat a label as arming anything.
- **Checks green is a non-terminal state.** Every required reviewer must
  complete on this head, or carry under its rule, with every finding and
  thread settled. An empty comment list or an elapsed timer proves no review
  complete. Re-read head and review activity immediately before any action
  or message that relies on the handoff check.

### Who decides, and what is delegated

`/orchestrate` owns the judgements and delegates the work: it decides every
finding's **disposition**, may override a computed stage exit **upward only**
(more rounds, never fewer, and never a promotion the gate refused), owns the
per-thread replies and the PR body, evaluates the handoff check, owns the merge
queue, promotes or demotes, and escalates on a cap, a blocker, or a scope question. It delegates implementation
to `/implement`, the confidence rounds to `/review`, and integration polling to
`/integrate` — session procedures, which return no envelope. Where a run
dispatches the schema-bound **role agents** instead, each returns a typed result
validated by `ai/schemas/result.envelope.schema.json` and its per-role
`result.{implementer,challenger,reviewer,integrator}.schema.json` and nothing
more; that result is **immutable**, its adjudication a separate record keyed by
finding id that every consumer reads. A delegate of either kind never merges,
never promotes, nor adjudicates its own findings, and never widens its scope —
with one sanctioned exception: a lane worker may add to its file fence, once
per file, a validator or test that rejects its change and that no other live
lane touches, by recording a dated one-line entry in its lane report; the
orchestrator verifies that entry against every live fence and may reject it
(the bounded self-expansion in the orchestrate skill's § Lane briefs).
**The current-head Codex contract** is policy and outlives whatever polls it. A
result is terminal for the head you captured only when it is a clean review or
top-level comment by GitHub actor ID `199175422` (`chatgpt-codex-connector[bot]`,
type `Bot`) whose `Reviewed commit:` names that head; a fresh 👍 from that bot on
that exact trigger comment, created after both the head push and the review
request; or findings by that bot naming that head, adjudicated before the cycle
is clean. Earlier activity never counts for a newer head, and a 👀 is pending, not
success. Immediately before accepting a result or promoting, re-check the
**cycle** as well as `headRefOid`: a same-head finding can land after a clean
one. § "Second-Model Review" carries the trigger cadence and both procedures.

The Codex checker implements byte-identical carry for a base catch-up merge
(evanharmon1/harmon-init#752), using the shared proof under § "Reviewers and carry".
This belongs to the integration stage and takes effect only where that stage
implements it. Every surface that drives or checks the cycle has to carry it,
and all of them arrive through the skills pin: the checker and handoff check
under `.claude/skills/`, the integrator agent under `.claude/agents/` that drives
the cycle (without it the loop never calls `carry` and re-reviews every head),
and the `dev-flow-support` package vendored beside them, whose result schemas
and validator the gate uses (so they accept a result naming a reviewed commit
that is not the gated head). harmon-devkit `v0.47.0` is the first release that
carries all of them. At an older pin, every head is reviewed on its own and no
verdict is carried.

### Handoff check

The [handoff check](https://github.com/evanharmon1/harmon-devkit/blob/main/docs/glossary.md)
is one live predicate used by integration and Foreman. Re-run it before promotion,
before applying `merge-ready`, and before any message calling a PR ready.
Never reuse an earlier result. All of these must hold:

- **Current with the base.** Read `compare/<base>...<head>` live and require
  `behind_by == 0`. Do not use `mergeStateStatus`. Catch up the queue head
  through update-branch (§ "Policy invariants"), never a rebase.
- **Required CI green on the exact head.** The latest run of each required
  check concluded successfully; skipped is neutral. Pending, missing, or an
  empty check list is indeterminate. Report failing non-required checks to
  the maintainer; they do not block.
- **Required reviews complete on this head.** Every reviewer `.devflow.toml`
  requires on this PR was requested on this head, or its verdict legitimately
  carries to it. Require each reviewer's own completion signal, never a timer,
  and settle every finding: fixed, declined with evidence, or filed.
- **Automation runs before promotion.** Every required workflow and review app
  ran on the draft, or was explicitly dispatched and settled on this head.
  Automation available only through `pull_request.ready_for_review` is a
  configuration blocker: promotion can notify CODEOWNERS before its result exists.
- **Every thread settled.** Each has the agent's reply, and either the agent
  has the last word or the thread is resolved. A reviewer's acknowledgement
  followed by resolving the thread settles it.
- **PR body and run record complete.** Tick every `## Deferred findings`
  entry with its disposition, include the disclosures, and verify the closing
  keyword. `reviewDecision` must not be `CHANGES_REQUESTED`.
- **Nothing moved.** Re-read `headRefOid` and review activity immediately
  before the action or message; any change invalidates the earlier result.

For Codex, the terminal current-head contract above applies, including `settle`
or the recorded-comment equivalent where the checker is absent. When the
resolved integration cap is 0, the Codex condition drops out; all other
conditions still apply. A P2-only clean cycle whose findings are declined or
filed needs no second cycle. After two consecutive clean cycles, settle P2s
without another remediation push; a confirmed P0/P1 from any reviewer breaks
that streak and is fixed within the remaining `remediation` cap.

A failed or indeterminate condition never passes. Keep a draft draft, remove
`merge-ready` from a promoted PR, and report the unresolved condition. A check
that never ran, a failed fetch, and a reviewer that never finished are
indeterminate. Promotion notifies reviewers, so prove the check before acting.

### Merge queue and ownership

The orchestrator keeps an ordered queue of PRs that passed the handoff check,
ordered to minimize conflicts, catch-ups, and re-reviews: file overlaps go
first-to-merge, and small independent units may go ahead.

- Only the queue head is promoted, kept current, and labelled `merge-ready`,
  after the live handoff check passes.
- Every other passed PR remains a draft labelled `parked`, is not caught up,
  and is reported as parked.
- When the head merges, catch up the next PR once, re-check it, promote it,
  and apply `merge-ready` after the live check passes.

The orchestrator owns each PR until it merges or closes and watches for as long
as it is open; there is no fixed post-promotion watch window. Lanes retire at
handoff. A lane's draft-publication signal is `DRAFT-PUBLISHED-`, the queue-head
report is the merge-ready report, and the PR body section is `Deferred findings`.

If anything changes on a promoted PR — a late review, red required CI, or the
base moving — remove `merge-ready` and act. Lead any message withdrawing an
earlier merge-ready report with that withdrawal. **A late finding needing a
code change sends the PR back to draft by default.** Settle a finding needing
no code change (declined or filed) in place. A base move gets a catch-up; return
to draft only if the new head owes a review. Work may restart on a promoted
PR, and the claim label is re-added whenever work resumes.

### Reviewers and carry

Each integration reviewer is a finder in `.devflow.toml [stage.integration]`
with trigger text, per-PR budget, covered rounds, completion signal, gating
status, and carry behaviour. Repository and per-PR overrides select the
applicable requirements. No reviewer is complete merely because its time
window elapsed. Apply each reviewer's carry rule:

- A byte-identical PR diff, proved by the canonical diff digest, owes nothing.
- An offsets-only move owes the next budgeted incremental review where that
  reviewer has one, and nothing otherwise.
- A real change owes a fresh round within each reviewer's budget.

The shared proof applies to every reviewer. Where the PR's three-dot diff (`base...head`) has the
same identity at the previously reviewed head and at this one — a digest of
that diff's own text, computed from immutable commit SHAs in the local
checkout, never reconstructed from the API, and generated under fixed,
non-normalizing options (no textconv or external diff driver, no rename
detection, submodule changes never ignored, full object IDs and gitlinks, and
pinned context, algorithm, prefixes, and file order) so no checkout's
configuration can hide a change or make two different diffs digest alike; this is the *canonical diff digest* the guides and
`.devflow.toml` refer to — the prior **clean** verdict
carries to this head and no cycle is triggered. Equality of that one value is
the whole argument: the reviewed artifact is the diff, and two heads whose
diffs are identical are the same change.

The identity is deliberately **not** `git patch-id`, which ignores hunk
offsets: a reviewed edit relocated between two identically-surrounded regions
— what a conflict resolution can produce — yields two different trees and one
patch id, so a verdict would carry across a change that really moved. Digesting
the diff text keeps the `@@` headers that distinguish them.

Never assume byte identity when the proof cannot be established — for
example, a base the verdict was never corroborated against, missing commits,
history overridden by grafts, or a verdict with unsettled
findings. The proof disables `refs/replace` in every Git command, so those
refs are ignored; an `info/grafts` file is refused because no flag disables it. A changed diff follows the reviewer's offsets-only or real-change
rule (§ "Reviewers and carry"); it does not automatically require a full review.

Three things never move with the carry. **CI re-runs on the new head in full,
always**, because what a base merge can change is everything *outside* the diff
and that is CI's to catch. **The review cycle itself does not move**: a carry
records that an existing cycle's verdict also attests a later head, and changes
nothing else — so the ordinary evidence scan keeps running against the commit a
reviewer actually read, a finding landing there after the carry still blocks,
and it is still answered the ordinary way. What a carry removes is the second
*review*, never the second *look*. And the proof is **re-derived** each time
rather than read back from the record, so a resumed session trusts nothing a
previous process wrote.

### Flake policy

A failure in a file the PR does not touch may be re-run once; record the re-run.
On the second sighting, file and fix the flake, never re-run it again. The bot
reads check runs through a GitHub App installation token so the handoff check
can see them through the Checks API.

## Stage Ledger

**Post a visible stage ledger whenever the change passes through two or more
stages** of the Dev Loop — a short table in the agent's **own commentary** (tool
output is collapsed and does not count), always in this shape:

| 📍 Ledger | |
|---|---|
| **Stage** | ⚔️ challenge · **round 2/4** · local (`task challenge`) |
| **Round** | 🔴 1 P1 open · 🟡 2 P2 deferred · ⚪ 1 P3 noted · ✅ verify green |
| **Next** | fix P1 → `task verify` → ⚔️ challenge round 3 |

Stage glyphs: 🔨 implement · 🧪 verify · ⚔️ challenge · 🔍 review · 🛡️ security ·
🏗️ ci · 🚢 integrate. Status glyphs: ✅ clean/green · 🔴 P0/P1 open · 🟡 P2 deferred ·
⚪ P3 noted · ⏳ waiting on CI or a reviewer · ⛔ blocked/escalating · 🏁 stage
converged — one glyph, one meaning, so a reader can tell the state at a glance
without parsing prose. `Stage` names the stage and, for a capped one, its round
as **`round n/cap`** against the `.devflow.toml` cap that bounds *that* work —
challenge, review, integration (Codex re-review cycles), and remediation
(integration-stage fix pushes) are counted and capped separately and never
combined, so name the counter whenever the stage has more than one. Integration
heads not charged to `integration` are named beside the count, never folded
into it: `round n/cap (+m exempt, +k carried)`. `m` counts exempt cycles, which
still run a review and spend the separate `integration_exempt` ceiling; `k`
counts heads carried forward without a review, which spend neither — so a head
attested without a reviewer reading it stays visible. `Next` names the next
concrete gate or action, including the `task verify` a fix owes before the next
round. Post it at every stage transition, at each round boundary, as the concise
tick during a long wait (no re-dumping unchanged command output), and
**immediately after a maintainer changes the requested workflow** — the latest
instruction overrides the default transition at once, and silently returning to
the default sequence is forbidden. An override is an attributable human decision
and is followed, but it redirects the loop rather than erasing findings: any
P0/P1 still open in the stage it ends is carried, **unchecked**, into the PR
body's deferred findings with the override recorded as the reason it was carried
— not as a disposition, so the integration stage still owes it a normal fix /
decline-with-evidence / file-as-follow-up. A one-step task that touches a single
stage owes no ledger.

At integration exit, the ledger names which exit ended the stage — settled clean cycle, P2 fixing
ceiling, tell, or cap — and its qualifying cycles. Preserve separate cycle/remediation counters
and exempt/carried counts; unresolved gating work is ⛔ blocked/escalating,
never 🏁 converged.

## Rigor and Strategy

**Rigor and strategy are resolved from `.devflow.toml`, not restated here.**
Rigor selects a `[rigor.<level>]` profile, which points to a `[rounds.*]`
policy and `[breadth.*]` envelope and supplies all five role-tier choices.
Strategy selects a `[strategy.*]` topology. Resolve explicit operator input,
then trusted issue labels, then `default_rigor` / `default_strategy`;
use the reader's built-in fallback only when the policy file is absent. Read
caps, floors, wall-clock limits, breadth, stage actors, gate targets, and tier
choices from the selected tables in the file. The portable shape is
[`.devflow.schema.json`](.devflow.schema.json).

**Vendored stage-skill compatibility is part of the topology check.** For a
`schema_version = 2` policy, a gauntlet or shepherd skill is compatible only
when its config-shape section explicitly supports `[rounds.*]` and
`[breadth.*]`. A lagging skill that recognizes only `[review.*]` pointers or
direct per-rigor caps must not reinterpret v2 as either older shape: use this
file's fallback procedure and the selected v2 tables instead. Assets this file
requires directly, such as the current-head Codex checker, remain usable; only
the incompatible skill-level policy reader is bypassed.

Rigor label conflicts resolve to the **strongest label present**, by
`.devflow.toml`'s `rigor_order` (weakest to strongest) — a conflict can then
only ever buy more depth and budget, and the whole profile of the stronger
level wins rather than a mix of numbers from both. Strategy label conflicts
are **ambiguous**: unlike rigor's more-or-less continuum, two topologies are
not orderable against each other, so there is no rank to fall back on. Two
`strategy:*` labels on the same issue are a resolution error, not a pick: an
interactive session asks which one applies, and unattended automation falls
back to `default_strategy` with a warning rather than guessing. A
`rigor:`/`strategy:` value that names nothing in the file is ignored rather
than guessed at.

The selected `[rounds.*]` table supplies independent `challenge`, `review`,
`integration`, and `remediation` ceilings plus `min_rounds` and the run's
wall-clock ceiling. Challenge and review bound confidence passes;
`integration` bounds current-head Codex review cycles; `remediation` bounds
integration-stage fix pushes. A zero cap disables only the work it names,
never a deterministic gate, security scan, branch rule, or human approval.
`integration` charges only cycles that review something new: one whose head
differs from the last reviewed head **only** by a base merge that changed
nothing under review re-reads identical code, so it spends the separate,
equal `integration_exempt` ceiling the reader derives instead. A merge that
resolves a conflict, or that touches any file under review, charges normally,
and the ledger names which counter each cycle spent so `round n/cap` stays
honest. A cycle requested before CI concluded, on a head that
CI then fails, is the other exempt case (§ "Second-Model Review"). The accounting
belongs to the integration stage, so the exemption
takes effect only where that stage implements it. Until the vendored pin in
`.claude/skills/` carries it, that skill's single cycle counter governs and no
cycle is exempt. This is the one case where a lagging skill is **not**
overridden by this file: its handoff check enforces the count mechanically,
and a cycle ordinal above `integration` reads there as `codex-cap-mismatch` —
an *indeterminate* gate condition, which leaves the PR draft. Acting on the
exemption before the pin implements it would stall the gate it was meant to
unblock.

`integration` also stops charging a cycle it never runs (evanharmon1/harmon-init#752). Where the PR's three-dot diff has the same
identity as at the previously reviewed head, the prior clean verdict carries
forward and **no cycle is triggered at all** —
neither ceiling is spent, the cycle ordinal does not advance, and the ledger
names the carried head (`round n/cap (+m exempt, +k carried)`, § "Stage
Ledger") because a head
attested without a reviewer reading it is exactly what a human must be able to
see. The exemption above is the weaker, file-set test and stays for what the
identity cannot prove; the two compose, carry first because it is both stricter
and cheaper. The same carve-out in full, including why CI still re-runs
unconditionally, is under § "Dev Loop" → the current-head Codex contract, and
the same caveat applies: carry needs the vendored assets at harmon-devkit
`v0.47.0` or later, and at an older pin no verdict is carried.

**Role tiers refine the resolved rigor level; they never replace it.** Each
`[rigor.<level>]` profile carries `orchestrator_tier`, `implementer_tier`,
`challenger_tier`, `reviewer_tier`, and `integrator_tier`; `[role.*]` supplies
the role's baseline tier and ordered family/harness preferences. Only an
unqualified operator tier instruction targets the implementer;
`tier:<role>:<value>` targets exactly one role. An unqualified `tier:<value>`
label is not a role override — it is the issue's stored Tier (a cache of the
derived Tier, or, with `tier:pinned`, the pinned Tier). Resolve conflicts on
`tier_order`, disclose every off-profile choice, and never silently change
model family or vendor.

**When the change under review edits `.devflow.toml`, `agent-registry.json`,
or the policy reader itself**, resolve every parameter from the merge-base
copies of all three. A branch may not choose the values or code that govern
its own review. An explicit human instruction still overrides because it is
an attributable decision rather than self-modification. The trusted caller
must materialize and invoke the merge-base reader directly, before loading any
branch reader code; passing a closure path into the branch module cannot create
that boundary because its module and imports have already executed. During the
first adoption, when the merge base predates the reader, the trusted caller
must instead use an operator-pinned reader supplied outside the candidate
branch and feed it only materialized merge-base policy/registry inputs; if no
such external pin exists, resolution is indeterminate and stops. A branch copy
is never a bootstrap trust source.

**Nothing here arms anything.** A `rigor:*`/`strategy:*` label invokes no
model and starts no workflow by existing — the shipped defaults add no
account, trial, or paid-SaaS dependency, and escalation never switches a repo
to a vendor it does not already use. `foreman:*` remains the only arming
surface, and `.foreman.toml` remains authoritative for arming, trusted
actors, runners, and hard operational ceilings; Foreman intersects a resolved
breadth envelope with its own ceilings rather than trusting either source
alone. Treat every label as advisory: it is applied by people and
verified by nothing on its own, and GitHub's **triage** role can apply one
with no push access to `.devflow.toml` at all. An **interactive session**
treats every label that way and requires operator confirmation for **any
off-default resolution** — above or below, since one direction skips
oversight and the other spends money — arising from a label the operator has
not authorized (attribution to *some* actor is not authorization).
**Unattended automation** acts on a label only after verifying its
provenance end-to-end from its own trusted-actor configuration, re-read
immediately before acting, and otherwise falls back to the config default
with a warning. An agent never applies a `rigor:*`, `strategy:*`, or
`tier:*` label to itself — except the derived classification Tier: an
unqualified `tier:<value>` is a cache of Risk × Complexity (ADR 2026-09-30), so
writing it records what the issue is, not how it is run. Choosing an
execution-policy tier for oneself (`tier:<role>:*`, `tier:pinned`) stays
forbidden. **Any off-default resolution, and any off-profile role tier, is
disclosed in the PR body** — both are a visible line for the human reviewer,
never something inferred from behavior.

A strategy whose `min_agents` exceeds the resolved `[breadth.*]` limits is an
incompatibility: report it and stop rather than substituting another topology
or widening the envelope. Council additionally requires distinct model
families when its table says so; the resolver and registry decide whether the
configured pool can satisfy that constraint.

**Announce the resolved profile on entering the loop.** Include rigor and
source; the selected rounds policy's challenge, review, integration,
remediation, floor, and wall-clock values; the breadth envelope; all five
role tiers; and strategy and source. Fill it from the resolved policy, carry
it into the PR body, and use the resolved stage caps as ledger denominators.
Everything else about these stages
is policy rather
than a parameter and does not vary by rigor level or rounds policy: the exit condition, the escalation
rule, the round-2 scaffolding checkpoint, the deferred-P2 sidecar, and the
handoff check all hold identically everywhere. A cap is a ceiling, never a
quota — a stage that meets its exit condition on round 1 is done, whatever the
cap allowed.

## Definition of Done

- `task verify` passes.
- Conventional commit message (types: build, chore, ci, docs, feat, fix, perf,
  refactor, revert, style, test).
- Never bypass git hooks (`--no-verify` is forbidden); fix the underlying issue.
- Work on a feature branch; direct commits to `main` are blocked.
- **Never merge to main yourself** — no `gh pr merge`, `git merge`, or push to
  `main` without the maintainer's explicit, per-merge approval, even when CI is
  green and the ruleset would allow it. Open the draft PR and integrate it —
  checks green with reviews unpolled is not the stopping point — then queue
  it under the handoff check and watch until merge or close; merging is always
  a human decision. (The `git-merge-guard` hook in `.claude/settings.json` backstops
  this: it parses each command and asks before any real or possible
  `git merge`/`git pull` outside a verified feature-branch shape or the one
  default-branch exception: a configured-upstream `--ff-only` sync with an
  unambiguous operand (a merge beside any other git segment must name the full
  `refs/remotes/<remote>/<branch>`). A default-branch pull must omit its source
  or name `refs/heads/<branch>`; a short branch name can resolve to a remote tag
  and asks. Quoted text and heredoc bodies that no shell runs, search patterns and `git merge-base` are data. The project settings ask on pushes to main and
  force-pushes (prefix rules: a backstop, not a boundary) but carry no `gh pr merge` ask: that prompt comes only from
  your own settings on a host and from the dev
  devcontainer's managed-settings drop-in
  (`.devcontainer/config/claude-settings-dev.json`). The hook
  applies on the host and in the dev profile only;
  with `FOREMAN_DEVCONTAINER` set to `bot` or `agent` it makes no merge checks.
  Beside it,
  `.claude/hooks/review-trigger-allow.py` is a PreToolUse(Bash) hook that
  approves without a prompt only a fixed set of review-trigger commands:
  the integrate broker's Codex trigger (where skills sync installs the integrate
  skill), and `gh pr comment` with one of the reviewer bodies listed in
  the hook's docstring, each for the origin repository and a numeric PR (see
  the hook's docstring for the exact accepted forms). It gives no decision for
  anything else, so the normal permissions apply. It too is active on the host and in the
  dev profile only,
  and also makes no decision when `GH_HOST` names a host other than
  github.com. The bot and agent profiles carry no merge guard at all —
  the agent profile explicitly allows `gh pr merge` — and the "Protect Main"
  ruleset (code-owner approval + green checks) is the boundary there.)
  `gh pr ready` is *not* a merge and you may run it — but only out of
  a passing handoff check, never to signal "I think this looks done".
- **Reply to every inline PR review comment in its own thread** — bot
  reviewers and humans alike. Treat findings as
  hypotheses: verify each against the code, fix what's confirmed, and post the
  rejection reasoning with evidence otherwise. Post replies with
  `gh api repos/{owner}/{repo}/pulls/<n>/comments/<comment-id>/replies -f body=…`
  (comment IDs from `gh api …/pulls/<n>/comments`; the agent posture uses
  `/usr/local/bin/gh-api-read …/pulls/<n>/comments` for this read and denies
  raw `gh api`). A rollup summary comment
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
- **Pre-flight `guard:closing-keywords` before opening a PR that closes an
  issue — from the body, the title, or a commit message.** The checker scans
  all three, so a `Closes #N` written only into a commit subject counts and is
  the easy one to forget. A same-repo `Closes #N` while `#N` still has
  unchecked acceptance criteria fails the required `closing-keywords` check,
  and the guard is a
  metadata read — so pay for it locally, in the second before `gh pr create`,
  rather than in a CI round and a fix push. It stays **out of `verify`**
  deliberately: `verify` is offline and this guard calls the GitHub API.
  Pre-flight it with the body you are about to publish:
  `PR_TITLE="<title>" PR_BODY="$(cat body.md)" task guard:closing-keywords`.
  With both variables unset it reads the branch's open PR instead, which is
  the form to re-run after a body edit; `task ci` runs it first for the same
  reason. Fix the issue's criteria — or drop the closing keyword to `Refs` —
  rather than bypassing it.

### Remote environments

On a remote checkout (Claude Code on the web, Codex cloud — anywhere with
no devcontainer), run `task setup:remote` first if preparation has not run.
In a single-repository web session, the repository's remote-only `SessionStart`
hook runs it automatically and prints a summary; if the hook did not run (a
multi-repository session or a platform without the hook), run it once yourself.
It is idempotent — it installs the lefthook git hooks, clones then fetches the
repos in `.devcontainer/related-repos.txt` (when present) beside the checkout,
and installs dependencies from the lockfile. Fetching
updates remote-tracking refs without moving a sibling's checkout or local work.
Those siblings are reference context, not pushable where the platform only
allows pushes to the session's own repository and branch. The pre-push hook is
not a substitute for `task verify`, so run it yourself.

**Second model on a remote lane.** Every remote lane gets a Codex second-model
review on the ChatGPT plan with no human step: ephemeral cloud VMs never hold
Codex credentials, and a persistent environment may hold exactly one Codex login
of its own. On an **ephemeral cloud** the orchestrator runs `task challenge` and
`task review` against the lane's pushed branch from its own local pane, where
Codex is already logged in, and the lane's PR body records that review in its
stage ledger as `reviewed from <host> at <head>` — that orchestrator-side review
is the lane's second model, in the sense § Second-Model Review requires, and
Codex cloud review of the PR covers the integration stage.
A **persistent environment** (the agent devcontainer, Sprites) gets its one
Codex login when the **maintainer** provisions it: the maintainer runs
`codex login` once on that environment, and an agent never does (§ Hard Rules:
a credential write needs the maintainer's explicit request). It then runs Codex
locally; the login stays on that environment and is never copied to another
machine. An ephemeral cloud session does not install the plugins a repository
enables, so the Codex Claude Code plugin runs only where a persistent login
exists. Nothing here sets or asks for an OpenAI API key: the plan, not API
credit, pays for it.

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
  the implementation, consistency, and test coverage before the draft PR.
- `task codex:gate:enable` / `:disable` / `:status` — the automatic
  Claude Code → Codex stop-gate (the codex plugin's Stop hook reviews each
  editing turn and blocks completion on material findings). Per-repo,
  per-machine state; defaults off. Inside Claude Code the equivalents are
  `/codex:review`, `/codex:adversarial-review`, and `/codex:setup`. The
  toggles are approval-gated (`permissions.ask`), `disable` refuses
  non-interactive shells, and agents must **never disable the gate to get
  past a BLOCK** — adjudicate the finding or escalate to the maintainer instead.

These tasks slot into the **Dev Loop** above: after `task verify` goes green,
before `task security` and the draft PR. For an **orchestrated lane** whose
brief carries an active run identity (run id, branch, generation, active-state
path, record directory, policy projection), the confidence-stage skill
(`/review`) is the procedure — it emits the run record and adjudication
evidence that `/retro` harvests. For a **non-orchestrated session**, or where
the `review` skill is not vendored or its supported topology does not hold
(`origin` is not the repository the PR will target) or its config-shape section
fails the compatibility check in § "Rigor and Strategy", this section plus the
Dev Loop's invariants are the procedure (the inline `task challenge` / `task
review` fallback). A consumer at a retired pin (`/gauntlet`) still has the
single-stage skill at that pin. What follows here is the policy the confidence
stages run under; where this file and a skill disagree, this file wins.
Codex cloud review is also connected to the repo; it reviews PRs too and posts
inline comments only for high-priority findings.
During the integration stage, accept its clean comments, reviews, or reactions only under
the current-head cycle above: stale activity is not evidence for the current
commit, and a lone 👀 that disappears or never resolves is an incomplete
attempt.

**Proposed, for the maintainer to reconcile: a fourth terminal-clean form.**
The § "Who decides, and what is delegated" contract names three — a clean
review or top-level comment whose `Reviewed commit:` names the head, a fresh
👍 on the exact trigger, and adjudicated findings naming the head. The
connector now also maintains a rolling **"Codex Review Summary"** comment
whose per-head table row flips from Running to **Completed**, and on some runs
that row is the *only* clean signal it emits: harmon-devkit#710 at head
`fa06c6e` got no 👍, no review and no verdict comment, so attempt 1 burned its
whole window as pending and attempt 2 spent a second trigger on a review that
had already finished clean. The proposed sentence: *a Completed row in that
summary comment, for the exact current head, posted or edited by actor
`199175422` after the trigger, with no findings on any surface, is terminal-clean.*
Every qualifier is load-bearing — a Running row is pending, a Completed row
for another head is stale, a row edited before the trigger belongs to an
earlier cycle, and a badge anywhere in that comment makes it findings.

**This remains a proposal, and it is NOT implemented.** An implementation was
attempted in harmon-devkit#1050 and **split back out** in that change's
challenge round 3: reading a verdict out of the table meant deriving a head by
parsing markdown, and three consecutive review rounds each reproduced a
false-clean or a stuck-head path through it. The work is carried in
harmon-devkit#1117 and must land under head-binding invariants rather than a
parser. Until it does, the three-form contract above is the whole of it — and
a badged comment the checker cannot bind to a head blocks until it is settled
by comment id, rather than being read out of a table.

Two further reply shapes the same change taught the checker, both of which
alter what "no terminal evidence" means rather than adding a clean form:

- A **usage-limit reply** ("You have reached your Codex usage limits for code
  reviews…") is the reviewer *answering that it will not review* — terminal,
  never pending, and never clean or findings. Stop and report the blocker with
  its reset time where the reply carried one; the one bounded re-trigger is
  not spent on it (harmon-devkit#573).
- A **self-fix summary** — an unbadged report from that bot describing a fix
  *it* made, in a thread or as a top-level comment — is informational. It is
  neither a finding to adjudicate nor a reviewer follow-up owed a second reply
  (harmon-devkit#675). A badged follow-up still blocks, unconditionally.

**Both procedures for that cycle live here**, because a repo can answer
`use_codex_review` yes and `use_skills_sync` no. Post `@codex review` on entry and after every fix push, keep the
comment ID returned for that trigger, and give each attempt a full 10–15 minute
window, re-triggering once after an incomplete first attempt. **While that
bot's 👀 is still on the current attempt's trigger, the attempt is not
incomplete** — the window extends to a hard ceiling of 30 minutes from the
trigger, because the window is meant to bound a reviewer that is *not*
working, and re-triggering a live one costs a trigger and then escalates for a
reviewer that was never absent (harmon-devkit#655). A 👀 that has vanished with
no result, or one still sitting there past the ceiling, ends the attempt
exactly as before. If both attempts are incomplete, stop and escalate without
reporting green.

(Where the resolved integration cap is 0, no cloud review is triggered and that
condition drops out of the handoff check; every other gate still applies.)
**Where the pinned checker is vendored**
(`.claude/skills/integrate/assets/check-codex-cloud-review.sh`, with
`.claude/skills/shepherd/assets/check-codex-cloud-review.sh` as legacy
fallback), it is the
required implementation — never hand-roll the polling: `carry` first, on a
head that moved (exit 0 carries the previous clean verdict and there is no
cycle to run; exit 17 is the ordinary "reserve one" answer; exit 14 means the
PR is merged or closed and the stage is over), otherwise
`reserve` the cycle
against the captured head *before* posting the trigger (the durable state must
exist before the GitHub write), then call the broker trigger, which posts or
adopts the comment and attaches it; callers do not attach again. With an
older integrate pin whose broker only posts and prints the id, or only the
legacy shepherd checker, post the trigger and `attach` it as before. Run `check`,
acting on its exit code (0 clean, 10 findings,
11 pending, 12 retry, 13 escalate, 14 PR no longer open, 15 quota exhausted,
16 transient read, 2 indeterminate). `check` is run either way: on a carried
head it re-derives the proof instead of polling, so the gate's one re-check
covers both shapes. It never writes to GitHub,
so posting the trigger stays yours, and its `settle` subcommand records the
disposition of a badged finding stated outside an inline thread.
**Where it is not vendored**, the same contract is satisfied by hand: post the
trigger and record its comment ID and request time yourself, then poll all four
surfaces — PR reactions (fetched by that exact comment ID), top-level comments,
reviews, and inline review comments. The top-level comment is the one
hand-rolled pollers forget, and a clean verdict often lands there rather than as
a review, so missing it reports a finished cycle as incomplete. A non-inline
finding is answered and its disposition recorded on the PR in the ordinary way;
there is no `settle` call to make and none is owed.

**When each of those triggers is posted is a resolved policy value, not this
prose.** `[stage.integration].review_trigger` in `.devflow.toml` — the policy
reader's `stages.integration.review_trigger`, `after-ci` when the key is
absent — times every review the integration stage requests, each
`[stage.integration].finders` entry alike. `after-ci` waits for CI on the head
to conclude green, then posts; `with-push` posts with the push while CI runs
alongside; `after-ci-first` waits for CI on the PR's first head, then posts
with the push after each remediation push. It decides only **when** a review
is requested: it never suppresses a cycle the resolved rounds policy requires
and never adds a request beyond what that policy requires, so the one
legitimate second review cycle on an unchanged head is the one forensic
rigor's `min_rounds = 2` requires. Under every value:

- the handoff check is unchanged — required checks green on the exact head
  and every required review complete or legitimately carried are still required;
- under `with-push` or `after-ci-first`, a cycle whose head's CI then concludes
  failed spends `integration_exempt`, not `integration`. Evidence decides the
  charge — the CI conclusion on that exact head, read when the cycle is
  classified — and an indeterminate CI result charges `integration` normally.
  Its findings are adjudicated as usual, and the fix push still spends a
  `remediation` round;
- when CI fails while a review requested alongside it is pending, the cycle
  still waits for that review's terminal result, or is reported incomplete;
- carry and the base-merge exemption apply exactly as § "Dev Loop" and
  § "Rigor and Strategy" state, whatever the timing;
- re-running a CI-only infrastructure failure never re-requests a review.

Like carry, the timing takes effect only where the vendored integration stage
implements it; at a pin that does not, every request waits for CI, which is
`after-ci`.

**Codex Automatic reviews must stay disabled.** Codex triggers a cloud review
on three events: opening a PR for review, marking a draft ready, and an
explicit `@codex review`. The first two fire too late to inform a draft
workbench, and the second is actively harmful here — `gh pr ready` would kick
off a fresh asynchronous review *after* the gate that was supposed to complete
the automated work, so promotion would launch work after the handoff check. The
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
6. Post the stage ledger for the round (§ "Stage Ledger"), then finish the
   round with an adjudication table — at minimum finding →
   reviewer priority → **adjudicated** priority → classification → evidence →
   action, plus the round-2 provenance column — and record it; where the
   confidence-stage skill is vendored it adds the per-branch adjudication ledger the rows are
   written to.

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
does gets adjudicated with one of four dispositions written out: **delete**
the scaffolding (which moots the finding — see below), **restructure it to
invariants** (deletion by abstraction — see below), **split the mechanism out**
(the mechanism is still wanted, so it leaves the change as its own follow-up
with its own budget — see
[specs/dev-flow-v2.md § "The split strategy"](specs/dev-flow-v2.md#the-split-strategy)),
or state that it is in scope and why the change genuinely needs it. What is not
allowed is hardening round-1's scaffolding by reflex and letting round 3 attack
the result.

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
— deletion by abstraction. When the artifact is a spec or a document whose
accreted procedure-prose *cannot* simply be dropped because earlier rounds
legitimately demanded it, replace the attackable procedure with the
universally-quantified property it was approximating, delegate the mechanism to
the implementation surface that can be tested, and carry the review's attack
scenarios over as required test cases. The next round finds no wording seam to
attack, and the obligation is preserved rather than dropped — which is what
separates this from quietly deleting a requirement. Name it on the table and in
the commit message exactly as a deletion is named.

One endpoint is worth knowing: if the deletion empties the change *entirely*,
there is no round to converge on — `codex-review.sh` refuses an empty scope
non-zero by design, so the stage cannot pass and re-running will not change
that. Treat it as the answer rather than a failure to work around: a change
that has become empty is abandoned, not reviewed clean.

**Severity gating.** Both tasks ask Codex to label every finding `P0`
(breaks correctness, security, or data integrity in ordinary use, or breaks
an existing contract), `P1` (a real defect or materially wrong design
decision with a plausible trigger), `P2` (worth knowing, not
merge-blocking: hardening, unlikely edge cases, maintainability, non-critical
test gaps), or `P3` (cosmetic or informational — reported and adjudicated, never
gating). The scale is defined in
`scripts/codex-review.sh`, not inherited from the Codex CLI's own labels, so
the gate keeps its meaning if Codex changes its output; a finding badged off
that scale, or not badged at all, is adjudicated as **at least a P2**. A label
is a hypothesis and the **adjudicated** severity is the verdict — P3 included,
whatever reviewer produced it. The sidecar records what is *deferred*, so an entry is
owed only for a finding left unresolved and carried forward — one fixed in
place, or adjudicated genuinely cosmetic, leaves nothing to defer. What the
badge may never do is skip the adjudication that decides which it is.
**Only P0 and P1 gate the local loops.** Adjudicate P2s too — never suppress
or ignore one — but carry them to the integration stage rather than spending
a local round on them. A P2 you judge worth fixing
immediately may of course be fixed in place; it just does not hold the stage
open.

**Deferring P2s.** The durable record is the **PR description**: list every deferred
P2 under a `## Deferred findings` heading as an unchecked task-list item —
`- [ ] <file:line> — <finding>` — with enough detail to adjudicate it later.
This is not bookkeeping: `task challenge` and `task review` run locally and
their output is ephemeral, and the cloud reviewer reposts only high-priority
findings, so a P2 that is not written into the PR body is simply lost.

Record each one **the moment you defer it**, and never twice. Challenge and
review both run before `gh pr create`, so there is usually no PR body to write
to yet: it goes to the per-branch sidecar in the git directory, and the sweep
for stray notes happens when you open the PR. The path, the reason it is keyed
by branch and lives outside the worktree, and the append-once matching rule
are the confidence-stage skill's where it is vendored, with the recipe in
[docs/guides/codex-review.md](docs/guides/codex-review.md) either way — this
file states only the obligation, because terminal scrollback is not a record:
a context reset between `task challenge` and `gh pr create` would take the
findings with it.

The integration stage settles every entry and **edits the PR body to tick it**
(`- [x] … — fixed in <sha>` / `declined: <reason>` / `filed as #<n>`) in the
same round. The checkbox is the resolution state: an entry left unchecked is
open work, so a later round — or a different session — can tell at a glance
what it still owes without re-adjudicating what is done. That obligation is
stated here and in the Dev Loop above, and holds whether or not the optional
integration skill (`/integrate`, or the retired `/shepherd` at an older pin) is
installed to automate it.

**Loop cap and exit:** a stage — challenge and review counted separately —
ends when **two consecutive rounds adjudicate to zero P0 and zero P1
findings**, and never on "findings fixed" alone. Those rounds may be empty,
all-P2 as labeled, or P1-labeled and adjudicated down to P2; what counts is
the **adjudicated** column of the table, not the reviewer's label, and the
second such round is itself the confirmation, so no further run is owed. A
stage whose resolved cap is **0 never opens**: zero rounds run, there is
nothing of its own to adjudicate, and none of the three exits below is what
closed it — it was never open, and every deterministic gate and adjudication
obligation elsewhere is unaffected. For any stage whose cap is 1 or more, two
exits are faster still than the two-consecutive rule. A round with **no
findings at all** ends the stage by itself **once the stage has run at least
`min_rounds` rounds** (`0 <= min_rounds <= cap`, resolved from the review
policy in `.devflow.toml`; the built-in fallback if the file is absent uses
1) — an empty round is exactly the old rule's clean re-run, so neither a
trivial change nor a clean post-fix re-run pays for a confirmation pass, and
a floor above 0 only stops that shortcut being taken before the policy's
minimum work has happened. The other two exits need no separate floor check:
the two-consecutive exit runs two rounds by definition regardless of the
floor, and the capped-clean exit runs exactly the cap, which is always
`>= min_rounds` by construction — so `min_rounds` constrains the empty-round
exit alone. And a **capped final round** — including a cap of exactly 1,
where the single round is both the first and the last — that adjudicates to
zero
P0/P1 also ends the stage by itself: the confirmation it would otherwise owe
is a run the cap forbids, and a rule that strands a stage holding a clean
last round and no valid exit would be wrong — the cap bounds work, it does
not manufacture escalation. What the rule spends is bounded the other way
too: a stage pays at most one round confirming convergence, where the old
practice could spend every remaining round re-proving a change nobody still
disputed. Two things ride along with the exit: every P2
deferred during the stage must already be recorded in the sidecar (an exit
that drops a P2 is not an exit), and round 2 owes the scaffolding checkpoint
above. Each stage's cap is the one resolved from `.devflow.toml` per § "Rigor
and Strategy" (challenge → fix →
re-challenge, and likewise for review), counted separately per stage; if
P0/P1 disagreement persists at the cap, stop and surface it to the maintainer
instead of iterating further — escalation at the cap is for P0/P1 that
**persist**, nothing else. The maintainer may always ask for more rounds —
convergence is a floor on when you may stop, not a ceiling on what they can
order.

**Integration convergence:** a Codex cycle is **clean** when it adjudicates to
zero P0/P1; P2-only counts as clean. One terminal clean current-head cycle with
every finding settled ends the stage; a P2-only cycle 1 whose findings are
all declined or filed needs no second cycle on that unchanged head.

Enforcement in the exit engine and integrate skill is
[evanharmon1/harmon-devkit#1272](https://github.com/evanharmon1/harmon-devkit/issues/1272).

**Integration fixing ceiling: two consecutive clean Codex cycles.** Once two
consecutive cycles adjudicate clean, no further remediation push is made for
P2 findings; settle them without a push, declined with evidence or filed
together as one follow-up issue. A confirmed P0/P1 from any reviewer, including
a late human review, breaks the clean streak and is fixed within the remaining
`remediation` cap as before. Record each disposition, reply in affected threads,
record non-inline dispositions with `settle` (or the recorded-comment equivalent
where the checker is absent), and tick deferred PR-body entries. The handoff check
accepts that settlement; every other handoff-check condition still applies.

Count completed Codex cycles, including exempt cycles, separately from remediation
pushes; a carry adds no cycle, and an incomplete attempt or retry is not another
completed cycle. Independent `integration`, `integration_exempt`, and
`remediation` caps still apply. At a cap, persistent P0/P1 or an unreviewed head
is an escalation and the PR stays draft; no cap waives a verdict. This policy
adds no `.devflow.toml` key and never bypasses a failed or indeterminate gate.

One caveat on the automatic stop-gate: the codex plugin's Stop hook applies
its **own** notion of a material finding and may BLOCK on something you have
classified P2. Adjudicate it (fix it, or state the reasoning) — **never**
disable the gate to get past a BLOCK. A BLOCK is settled on its own terms and
against the hook, not against this rule: it neither reopens a stage that has
already converged nor counts as one of that stage's rounds.

## Advisory Review (Greptile)

**Greptile is advisory and orchestrator-triggered.** This is the default;
repository and per-PR reviewer overrides govern its gating status. Automatic reviews are off
via `.greptile/config.json`. The integration stage posts the Greptile trigger
comment, `gh pr comment <n> --repo <owner/repo> --body '@greptileai'`,
once per head it reviews, while the PR is a draft and after CI is green,
then waits a bounded 10–15-minute window (the window this file gives a Codex
attempt). Adjudicate what lands like any reviewer:
findings are hypotheses, inline comments receive per-thread replies, and deferred
findings are recorded and settled. Greptile is
by default not a handoff-check condition: silence or a findings-free trial-ended or credit
notice is neither a blocker nor a finding. Report an unsolicited Greptile review
with no trigger comment: it means the config or dashboard has drifted back on.

## Conventions

Full reference: [docs/conventions.md](docs/conventions.md). Highlights:

- Conventional Commits; `group:action` Taskfile naming (e.g. `lint:shell`, not
  `shell:lint`); pin actions by SHA + `# vX.Y.Z`.
- Work on a feature branch off the default branch; never commit directly to it.
  For parallel or isolated work take the branch in its own worktree via
  **`task worktree:new -- <name>`** (and `task worktree:rm -- <name>` when
  done) rather than a hand-rolled `git worktree add` — it installs that tree's
  dependencies and proves the hooks fire in it. See
  [docs/conventions.md](docs/conventions.md) § Worktrees, including why
  `-c core.hooksPath=.git/hooks` must never be passed inside one.
- **Git transport** — pushes authenticate over HTTPS via `gh`. Provisioned
  hosts and the devcontainers rewrite GitHub SSH URLs to HTTPS via
  `url.insteadOf` so git never needs an SSH agent: a headless container has
  none, forwarding one into an interactive container is lockout-prone, and
  `gh` already holds an HTTPS credential that works for both. Never work around
  an SSH failure by pushing to a raw `https://…` URL — a URL push bypasses the
  named remote and leaves stale tracking refs. On an unprovisioned host, force
  the helper and the rewrite against the *named* remote:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' -c url."https://github.com/".insteadOf="git@github.com:" -c url."https://github.com/".insteadOf="ssh://git@github.com/" -c url."https://github.com/".insteadOf="ssh://git@ssh.github.com:443/" -c url."https://github.com/".insteadOf="ssh://git@ssh.github.com/" push`
  (a credential helper only applies to HTTPS, and `insteadOf` is prefix
  matching — every SSH form needs its own mapping, hence all four).
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
