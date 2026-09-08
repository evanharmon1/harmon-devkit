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
- `ai/` — AI assets by type: `skills/`, `agents/`, `schemas/`, `prompts/`,
  `rules/`, `evals/`, `tools/`, `workflows/`, `mcp/`, `knowledge/`,
  `memories/`. `skills/` is the populated one (Agent Skills convention — a
  `SKILL.md` with `name`/`description` frontmatter); the standouts are `repo/standardize-repo`
  (applies harmon-init's conventions to a repo), the `design/` suite, and the
  `universal/` dev-workflow session suite (`/kickoff`, `/breakdown`,
  `/claim`, `/implement`, `/gauntlet`, `/shepherd`, `/retro`, `/wrap`). `agents/` holds shared
  subagents — one flat `<name>.md` each, thin by design and deferring to the
  skills above; see [ai/agents/README.md](ai/agents/README.md) for the layout
  and the portability contract. `schemas/` holds shared JSON Schemas for
  dev-flow v2 agent results, with a conformance fixture corpus under
  `ai/schemas/fixtures/`.
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
shepherds them to ready-for-review — merging is always a human decision.
Foreman's own PRs follow the same draft-first lifecycle as the Dev Loop
below: it opens draft PRs (labelled `foreman:dispatched`) under its own
verify gate and promotes them only through its readiness gate — checks
green, review threads resolved, and the `[reviewer]` current-head Codex gate
configured in `.foreman.toml` (the same `@codex review` contract the
integration stage uses — fail-closed, bounded attempts) — to
`foreman:ready-for-review`, the hand-off to human review.
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
`/orchestrator` is the session's standing operating mode; it dispatches
`/implement` (claimed issue → gates → draft PR), `/review` (both confidence
stages), and `/integrate` (draft → ready for review). `/claim` comes first but
is **user-invoked** — the user typing it authorizes its issue writes — and
`/implement` never claims. There is **no `dev-loop` skill** — those stages *are*
the loop; retired names map on (`gauntlet` → `review`, `shepherd` →
`integrate`), and a pin still shipping a predecessor runs it under this policy.
The skills carry the procedure — round mechanics, adjudication records, review
polling, the PR-open ritual — entered by reading their `SKILL.md`. In this
repository, active stage skills omit `disable-model-invocation: true` and
are model-invocable as described in `ai/skills/README.md`. Where none is vendored,
this section is the whole contract and its invariants are owed anyway; where a
**vendored** skill states a different cap, floor, or exit condition, **this file wins**.

```text
/claim (user) → /implement [ code → task verify → challenge → review → task security → DRAFT PR ]
  → /integrate [ CI → deferred findings → reviewers → readiness gate ]
  → ready for review → human review → human merge
```

**The draft PR is the workbench.** GitHub reports drafts and non-drafts alike as
`OPEN`, so "open PR" says nothing about whose turn it is. These three states do:

- **Draft PR** — the agent's workbench. Implementation, CI, bot review, and
  integration fixes are still in progress. Nobody is waiting on a human.
- **Ready-for-review PR** — non-draft. The automated lifecycle is complete and
  the change is handed to a human. Reaching it is a gate, not a judgement call.
- **Merged PR** — always a separate human decision. Agents never merge.

Creating the draft is a phase transition, not a terminal state: every stop short
of the readiness gate leaves the PR **draft** with a blocker report. That assumes
the repo *can* open drafts (GitHub restricts them on private repositories to
paid plans — docs/CHECKLIST.md); a rejected `--draft` is reported, never dropped.

### Policy invariants

Binding on every stage, skill, and harness, whatever rigor resolved:

- **Draft-first.** Commit and push whatever the rounds have not already pushed,
  publish with `gh pr create --draft`, then fetch `headRefOid,isDraft` and
  require both the SHA you pushed and `isDraft == true`. Only a passing readiness
  gate promotes; `gh pr ready` runs exactly once out of it — never as a judgement
  that the change looks done — and you then confirm `isDraft == false` on that
  same head before reporting. Human approval is deliberately *not* a
  precondition: ready-for-review requests that review, never permission to merge.
- **Never merge, never cut a release, never rewrite pushed history.** Merging
  and releasing are the maintainer's decisions, and nothing already pushed is
  amended, rebased, or force-pushed, at any stage.
- **Never bypass a gate** — not the git hooks, not a stop-gate BLOCK, not a
  failed *or indeterminate* readiness condition. Fix the cause, or escalate.
- **Every push passes its round gate, then a secret scan** — `.devflow.toml`'s
  `[gates]` names them (`verify` for a code push, `check` for a docs-only one,
  `security:secrets` always, `security` before the draft PR); the `pre-push`
  hook runs what it can, otherwise run them yourself. `task ci` stays on demand.
- **One conventional commit per adjudicated round, pushed** to the branch's own
  writable remote (`git push -u <remote> <branch>` on the first push). Per
  *round*, not per finding: five fixes are one commit, a round with nothing to
  fix pushes nothing. It bounds a lost environment to the current round's *code*
  and surfaces a push-permission gap at round 1 rather than at `gh pr create`;
  it carries nothing else — the deferred-findings sidecar and the adjudication
  ledger live in the git directory, are never pushed, and a resumed session
  re-runs the stage anyway. Once the draft exists, pushes batch per integration
  round — each one spends a CI run and starts a fresh current-head review cycle.
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
  retired `method:`), and never treat a label as arming anything.
- **Checks green is a non-terminal state.** Bot and human reviews land *after*
  checks settle, so an empty comment list read the moment `gh pr checks --watch`
  returns means "not reviewed yet", not "nothing to answer". Wait for **both**
  signals: every check concluded, and a terminal current-head Codex result.
### Who decides, and what is delegated

`/orchestrator` owns the judgements and delegates the work: it decides every
finding's **disposition**, may override a computed stage exit **upward only**
(more rounds, never fewer, and never a promotion the gate refused), owns the
per-thread replies and the PR body, evaluates the readiness gate, promotes, and
escalates on a cap, a blocker, or a scope question. It delegates implementation
to `/implement`, the confidence rounds to `/review`, and integration polling to
`/integrate` — session procedures, which return no envelope. Where a run
dispatches the schema-bound **role agents** instead, each returns a typed result
validated by `ai/schemas/result.envelope.schema.json` and its per-role
`result.{implementer,challenger,reviewer,integrator}.schema.json` and nothing
more; that result is **immutable**, its adjudication a separate record keyed by
finding id that every consumer reads. A delegate of either kind never merges,
never promotes, never widens its scope, nor adjudicates its own findings.
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

### Readiness gate

The single definition of "the automated lifecycle is complete", used by
the integration stage and by Foreman alike. A
draft may be marked ready for review only when **all** of the following hold for
its current `headRefOid`:

- Required CI checks have concluded successfully. An empty check list is
  *indeterminate*, not a pass — GitHub populates it asynchronously, so a read
  taken moments after the push reports nothing having run rather than nothing
  to run.
- The current-head Codex cycle above is terminal and clean — including clean
  by way of dispositions recorded with `settle`, or the recorded-comment
  equivalent where the checker is absent (**or where the resolved integration
  cap is 0** — a cap of 0 leaves no cloud-review cycle to trigger a fresh
  `@codex review` from, so this one condition drops out; every other
  condition on this list still applies unchanged).
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
combined, so name the counter whenever the stage has more than one. `Next` names the next
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

**Role tiers refine the resolved rigor level; they never replace it.** Each
`[rigor.<level>]` profile carries `orchestrator_tier`, `implementer_tier`,
`challenger_tier`, `reviewer_tier`, and `integrator_tier`; `[role.*]` supplies
the role's baseline tier and ordered family/harness preferences. Unqualified
`tier:<value>` input targets the implementer; `tier:<role>:<value>` targets
one of those five roles. Resolve conflicts on `tier_order`, disclose every
off-profile choice, and never silently change model family or vendor.

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
`tier:*` label to itself.
**Any off-default resolution, and any off-profile role tier, is
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
readiness gate all hold identically everywhere. A cap is a ceiling, never a
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
before `task security` and the draft PR. The confidence-stage skill (`/review`,
or the retired `/gauntlet` at an older pin) is the procedure for running them to
convergence where it is vendored **and its supported topology holds (`origin` is
the repository the PR will target) and its config-shape section passes the
compatibility check in § "Rigor and Strategy"**; otherwise this section plus the
Dev Loop's invariants are the procedure. What follows here is the policy it runs
under; where the two disagree, this file wins.
Codex cloud review is also connected to the repo; it reviews PRs too and posts
inline comments only for high-priority findings.
During the integration stage, accept its clean comments, reviews, or reactions only under
the current-head cycle above: stale activity is not evidence for the current
commit, and a lone 👀 that disappears or never resolves is an incomplete
attempt.

**Both procedures for that cycle live here**, because a repo can answer
`use_codex_review` yes and `use_skills_sync` no. Post `@codex review` on entry and after every fix push, keep the
comment ID returned for that trigger, and give each attempt a full 10–15 minute
window, re-triggering once after an incomplete first attempt. If both attempts
are incomplete, stop and escalate without reporting green.
**Where the pinned checker is vendored**
(`.claude/skills/integrate/assets/check-codex-cloud-review.sh`, with
`.claude/skills/shepherd/assets/check-codex-cloud-review.sh` as legacy
fallback), it is the
required implementation — never hand-roll the polling: `reserve` the cycle
against the captured head *before* posting the trigger (the durable state must
exist before the GitHub write), then post `@codex review`, `attach` the comment
ID it returned, and `check`, acting on its exit code (0 clean, 10 findings,
11 pending, 12 retry, 13 escalate, 2 indeterminate). It never writes to GitHub,
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

**Deferring P2s.** The handoff is the **PR description**: list every deferred
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
