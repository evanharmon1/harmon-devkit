# Spec: Dev flow v2

- **Status:** Draft
- **Owner:** Evan Harmon
- **Date:** 2026-08-29
- **Related:** [harmon-devkit milestone "Dev flow v2"](https://github.com/evanharmon1/harmon-devkit/milestone/2)
  (anchor issue [#633](https://github.com/evanharmon1/harmon-devkit/issues/633)),
  [harmon-init milestone "Dev flow v2"](https://github.com/evanharmon1/harmon-init/milestone/4),
  [foreman milestone "Dev flow v2"](https://github.com/ponderousdev/foreman/milestone/5),
  [docs/product/domain.md § Lifecycles](../docs/product/domain.md),
  [docs/glossary.md](../docs/glossary.md),
  [docs/decisions/0002](../docs/decisions/0002-round-evidence-lives-on-the-pr.md),
  harmon-init decision record 0008 (to be written beside 0006/0007).

## Problem / Why

The dev loop's procedure is ~470 lines of prose in `AGENTS.md` plus two
vendored skills, and its two hardest decisions — *is this review round
converging?* and *is this finding real?* — are made by feel in the
orchestrating session. The retro of
[ponderousdev/omator#397](https://github.com/ponderousdev/omator/pull/397)
shows the cost: 4 challenge + 3 review rounds, 67 findings, both stages capped
with adjudicated P1s every round, 9 of 14 round-2 findings about round-1's own
fixes, and ~40 minutes of unconditional `task verify` on a docs-only diff.
Nothing in that trajectory was recorded in a form a script could have read,
so nothing could have stopped it earlier or be replayed now to tune a policy.

## Goal

Every exit decision in the dev flow is a script output computed from
schema-validated evidence, never a judgement made from feel. Concretely:

1. Agents in the flow fill **roles** and return **schema-bound results**; the
   session that dispatched them (the **orchestrator**) owns dispositions,
   promotion, and the only permitted override of a computed exit.
2. Round exit, provenance verification, rendering, and the readiness gate are
   computed by scripts from round JSON and `.devflow.toml`.
3. Every run leaves a durable record from which the success metric below and
   a per-run retro can be computed without the session that produced it.

### Success metric

The share of kicked-off issues that reach `gh pr ready` with **zero
interventions**. The unit is the **issue**, not the run: an issue may have
several runs (a crash, an abandonment, a retry), and it succeeds only if the
run that reached ready-for-review had zero interventions **and** every earlier
run for the issue ended without a human action — a human re-kicking a failed
run is itself an intervention, while a Foreman automatic retry is not. The
denominator is every kicked-off issue, so abandoned runs count as failures;
that is why the run record is created **at kickoff, on the issue**, as a
comment the orchestrator reserves and then edits in place, before any branch
or PR exists — a run that dies before `gh pr create` still leaves its record
where the stats script looks. An **intervention** is any human action
between kickoff and ready-for-review, except answering an implementer's
`blocked_question`, which is counted separately as *asked*. A human fix after ready-for-review
is a failure of the readiness gate, tracked as a second number. The metric is
computed by `scripts/dev-flow-stats.sh` ([#663](https://github.com/evanharmon1/harmon-devkit/issues/663))
from retained artifacts alone (§ Evidence). Baseline first; a target is set
after roughly ten runs. Foreman cannot dispatch on public repositories, so
Foreman-initiated runs are measured on private repos and a zero Foreman sample
on harmon-devkit is not a signal.

## Non-goals

- An orchestrator *agent*. The orchestrator is the session, interactive or
  headless (harmon-init decision record 0008).
- Foreman's supervision loop. Foreman consumes the shared contracts in its own
  Python; it never wraps devkit's skills or scripts.
- Parallel implementers or reviewer fan-out
  ([#603](https://github.com/evanharmon1/harmon-devkit/issues/603)).
- A dedicated `fixer` role. Fix rounds re-dispatch the implementer; a fixer is
  a later option if that proves weak.
- Changing the readiness gate's *conditions*. This spec changes who evaluates
  them and from what evidence, not what they are.
- New review-product integrations. Finders are declared for what exists.
- Anything in harmon-dotfiles. The constitution (global `CLAUDE.md`) is cited
  where it constrains this design; nothing here references that repo.
- Herdr. Transport for dispatch is an `/orchestrator` preference; the role
  contract is identical over Herdr panes and plain subagents.

## The lifecycle

The stage vocabulary is the table in
[docs/product/domain.md § Lifecycles](../docs/product/domain.md): kickoff →
claim → explore*→ plan → implement → verify → challenge → review → security →
integration → merge → deployment* / release*/ smoke* → retro*→ wrap
(* optional). Two kinds of stage:

- **Checks** — `verify` and `security`. Deterministic, authoritative, gating.
- **Confidence stages** — `challenge` and `review`. A second model poking at
  the change. They raise confidence and produce findings to adjudicate; they
  are never a determinative test, and their exit is computed, not felt.

The orchestrator-driven span is implement → integration; that span is what
"unattended" means in the metric. `merge` is always a human.

`gauntlet` and `shepherd` are retired names. Skills are named for stages
(`/implement`, `/review`, `/integrate`); agents for roles (`implementer`,
`reviewer`, `integrator`). `/orchestrator` is the session's standing operating
mode, not a stage. Each stage skill owns its own procedure and ends by naming
the next stage; there is no skill that restates the walk.

This milestone **builds** implement, verify, challenge, review, security,
integration, `/orchestrator`, and the retro integration
([#664](https://github.com/evanharmon1/harmon-devkit/issues/664)). It
**names only** explore, deployment, release, smoke. Kickoff, claim, plan, wrap
are unchanged.

## Roles and authority

A **role** is a contract: the result schema an agent must return and the
external writes it may make, declared in `agent-registry.json` `roles[]`
([#635](https://github.com/evanharmon1/harmon-devkit/issues/635)). An agent
file (`ai/agents/<role>.md`) is one implementation of a role.

| Role | Returns | May write | Never |
|---|---|---|---|
| `implementer` | `result.implementer` | commits on the branch; the round push via `push-round.sh` | open PRs, merge, adjudicate |
| `reviewer` | `result.reviewer` | nothing outside its result | fix, dispose, decide an exit |
| `integrator` | `result.integrator` | the Codex trigger comment; thread replies of **given** text | author reply text, dispose, promote |
| orchestrator (the session) | — | dispositions, adjudication record, PR body, `gh pr ready` | merge; override an exit downward |

**Declared writes are enforced, not trusted.** A role's `writes` list is an
authorization boundary only where something enforces it: the agent file's
tool allowlist (`allowed-tools` frontmatter) denies everything not listed,
and every permitted external write goes through a broker script that
validates its one action (`push-round.sh` for the round push; a thread-reply
helper that posts exactly the text it is given). The `reviewer` and
`integrator` roles **must not run with ambient write credentials**: a
harness that cannot restrict a subagent's tools (a plain subagent inheriting
the orchestrator's shell and `gh` token) may not dispatch those roles, and
`/orchestrator` refuses the dispatch rather than disclosing the gap — a
disclosed bypass is still a bypass. The implementer is the one role that
legitimately pushes, through `push-round.sh`. Foreman's sandbox is the
equivalent scoping for headless runs.

**Briefs are free-form; results are schema-bound.** The orchestrator → agent
brief is prose. The agent → orchestrator result is validated on receipt
against `ai/schemas/` before the orchestrator reads it.

**Whoever holds the worktree pushes.** In interactive and sandboxed runs the
implementer commits and pushes each round through `push-round.sh`, so a crash
never strands a fix on one machine. Under Foreman, Foreman pushes.

**The orchestrator is interactive or headless with one procedure.** A
Foreman-dispatched session and a human-attended one follow the same stage
skills; the override rule below is the orchestrator's regardless of who that
is, and every override is recorded with a reason so a headless one can be
audited.

## Results

Every result is an **envelope** wrapping a per-role payload
([#634](https://github.com/evanharmon1/harmon-devkit/issues/634)):

```json
{
  "schema": 2,
  "role": "reviewer",
  "status": "completed",
  "head": "<40-hex sha>",
  "produced_at": "2026-08-29T15:04:05Z",
  "producer": { "harness": "claude-code", "model": "…", "tier": "frontier" },
  "run": { "run_id": "…", "initiated_by": "human" },
  "payload": { }
}
```

- `implementer` payload keeps every Foreman v1 field (`summary`, `handoff`,
  `ac_test_map`, `human_tasks`, `blocked_question`) so Foreman accepts the
  envelope with a validator widening ([foreman#182](https://github.com/ponderousdev/foreman/issues/182)).
- `reviewer` payload: one round — `stage`, `round`, `reviewed_head`,
  `finder`, and `findings[]`, each with `id`, `path`, `line`, `class`,
  `provenance`, `fingerprint`, `priority` (the reviewer's label),
  `recommended_disposition`, `evidence`. **Immutable once returned.** A
  finding `id` is unique within the run by construction —
  `<stage>-r<round>-<finder>-<n>` — so an adjudication or a `repeat-of`
  reference can never resolve to a finding from another round.
- **Heads must agree.** Receipt validation rejects any result whose payload
  names a head (`reviewed_head`, the integrator's reviewed-commit stamp)
  different from the envelope's `head`; a schema-valid result can never carry
  stale evidence under a current-head label.
- `integrator` payload: checks, the Codex cycle (accepted surface, comment id,
  reviewed-commit stamp, checker exit code), findings verbatim, unanswered
  thread roots, `settled_at`, `applied_dispositions`.
- The **adjudication record** is a separate, orchestrator-authored document
  keyed by finding id: adjudicated priority and final disposition
  (`fix | restructure | delete | decline | defer`). Scripts read the
  adjudicated view; the raw reviewer output is kept so reviewer-vs-orchestrator
  disagreement can be measured.
- The **run record** (`run.json`) is the only home of mutable run state —
  `interventions[]`, stage transitions, `outcome`, `pr`. An envelope carries
  only the immutable identity (`run_id`, `initiated_by`), so two documents can
  never disagree. It is written by whoever kicked the run off — the session or
  Foreman ([foreman#184](https://github.com/ponderousdev/foreman/issues/184)) —
  up to ready-for-review. Everything after that is **derived at read time** by
  `dev-flow-stats.sh`, never written by an actor, because the orchestrator
  stops at ready-for-review and nothing else holds the pen: merge and
  post-ready human commits from the PR's own timeline; deployment, release,
  and smoke from **repository-wide** workflow runs, releases, and the rolling
  release PR, correlated to the run by the merged commit's presence in the
  default branch at the event's SHA.

devkit ships **conformance fixtures** (valid and invalid examples per schema)
beside the schemas. They are the shared contract with Foreman, which tests its
Python against them at a pinned tag.

## Convergence model v0

Finding fields:

- `class ∈ design | correctness | consistency | hardening | nit`
- `provenance ∈ original | round:N` — whether the finding is about the change
  or about round N's fix. Asserted by the reviewer; the exit script
  **verifies** it.
- `fingerprint ∈ new | repeat-of:<id> | supersedes:<id>` — asserted by the
  reviewer, which has prior rounds' findings in its brief; the exit script
  **verifies** it.

**Verification is a property, not a procedure.** Two rounds of review of
this spec showed that any concrete mechanism written here (line numbers, then
`git blame` anchors) accretes edge cases — deleted lines, a fix that exposes a
defect in unchanged code, a repeat whose implicated line the fix rewrote — so
this spec states the invariants and delegates the mechanism to the exit
script ([#636](https://github.com/evanharmon1/harmon-devkit/issues/636)),
where it can be tested:

- The script may **downgrade** a reviewer's `original` to `round:N`, or
  refuse a `repeat-of`/`supersedes`, only with evidence it records alongside
  the finding; it never silently overrides, and a disagreement it cannot
  decide keeps the reviewer's assertion and is logged as `unverified`.
- A finding's identity is stable across the fix that addresses it: a
  round-2 recurrence of a round-1 finding is detected as a repeat whether or
  not the fix rewrote the implicated lines.
- One fix commit per round, so "round N's fix" is one commit.
- **Required test cases**, carried from these reviews: a finding on a line
  deleted by the fix; a finding on an unchanged helper exposed by a fix; a
  repeat after the fix rewrote the line; a rename between rounds; two
  unrelated findings in one file (must not be a repeat).

Exit outcomes, computed per confidence stage by the exit script
([#636](https://github.com/evanharmon1/harmon-devkit/issues/636)) from the
adjudicated rounds and `[convergence]`:

| Outcome | Meaning | Orchestrator may |
|---|---|---|
| `continue` | no exit predicate satisfied; cap not reached | dispatch the next fix round |
| `converged` | **zero adjudicated P0/P1 of any class** (a universal precondition, not a predicate), an exit predicate satisfied, and `min_rounds` met | advance; or override **upward** (one more round) with a recorded reason |
| `diverging` | adjudicated P0/P1 findings are feeding on earlier rounds' fixes, and the cap is not reached | dispatch a fix round **only** with a `delete` or `restructure` disposition on the `round:N` findings; otherwise the run stops with a blocker |
| `capped` | cap reached | advance if zero adjudicated P0/P1 remain (**capped-clean**); otherwise **escalate to a human** — no PR is opened, and no further round is dispatched whatever else holds |

**Precedence is normative**: the script evaluates `capped`, then
`diverging`, then `converged`, then `continue`, and returns the first that
holds. The cap comes first because it is a ceiling — a final round that is
also diverging must escalate, never buy a round the cap forbids. Divergence
outranks convergence because a stage feeding on its own fixes has not
converged whatever a single round looks like. **Every predicate evaluates
over adjudicated P0/P1 findings only**: a repeated P2 or a rising P3 count is
information for the retro, never a reason to hold a stage open or force
de-scaffolding. Two implementations given the same rounds and policy must
return the same outcome and the same `reason`.

Predicates are a **catalog implemented in the script** and composed in TOML
per outcome with `any`/`all` — the shape is the policy, so tuning never
means editing the script. A rigor level may **tighten** this (add a
`diverging` predicate, raise a `converged` threshold, remove a `converged`
predicate) and never loosen it: `rigor:*` labels are advisory and can be
applied by anyone with triage, so an override that could weaken an exit would
let a label change safety semantics rather than the amount of review. Loosening
is an explicit-instruction edit to the base `[convergence]` table, resolved
from the merge base like every other cap.

```toml
[convergence]
converged = { any = [
  { predicate = "no_gating_findings", classes = ["design", "correctness"] },
  { predicate = "provenance_share",  min = 0.5, exclude_classes = ["design"] },
] }
diverging = { any = [
  { predicate = "count_rising", rounds = 2 },
  { predicate = "repeat_after_fix" },
] }
```

**Only rounds that reviewed the current head can satisfy `converged` or
`capped`-clean.** Rounds on an ancestor head still count toward trajectory
predicates (`count_rising`, `provenance_share`, `repeat_after_fix`) and toward
`min_rounds`, but a clean round on an ancestor is not a clean round on the
code that will ship — any commit after it, a P2 fix included, needs a round of
its own. Rounds whose `reviewed_head` is not an ancestor at all are excluded
(`continue`, reason `invalidated`); incomparable rounds never converge. `dev-flow-stats.sh --replay` scores any candidate policy against
every retained trajectory before it ships; the omator#397 ledger is the first
fixture.

## Configuration (`.devflow.toml`)

Owned by harmon-init ([#1081](https://github.com/evanharmon1/harmon-init/issues/1081)).
The v2 shape, on top of the shipped migrated file:

- `[caps.<policy>]` — renamed from `[review.*]`: `challenge`, `review`,
  `integration` (formerly `shepherd`), `min_rounds`. Each rigor level points at
  one policy via `caps = "<policy>"`. A cap is a ceiling; `min_rounds` is a
  floor per confidence stage below which `converged` cannot fire. There is
  no cap for checks.
- The **integration cap bounds Codex re-review cycles only.** Answering every
  human and CI finding is unconditional; `integration = 0` means "no Codex
  cycle required", never "abandon reviews". That is why a policy may lower it
  (resolves [#624](https://github.com/evanharmon1/harmon-devkit/issues/624)).
  Unconditional is not unbounded: fix pushes in the integration stage are
  counted by `[caps].remediation`, whose terminal action is **escalation
  with the unresolved findings listed** — never abandoning them and never
  promoting past them — so a flaky check or a reviewer who finds something new
  after every push cannot run an unattended session forever.
- `[gates]` — `round_code` (`task verify`), `round_docs` (`task check`),
  `docs_only_paths[]` (the **only** copy of the allowlist;
  [#632](https://github.com/evanharmon1/harmon-devkit/issues/632) reads it),
  `secret_scan` (unconditional), `pre_pr`. The pre-PR gate is: assert the head
  carries a round-gate marker, then `task security`; a head with no marker
  runs the round gate first. `task ci` is on demand
  ([harmon-init#1080](https://github.com/evanharmon1/harmon-init/issues/1080)).
  Foreman's `[verify].default` derives from `[gates].pre_pr`
  ([foreman#183](https://github.com/ponderousdev/foreman/issues/183)).
- `[convergence]` — as above, with `[rigor.<level>.convergence]` overrides.
- `[role.<slug>]` — `tier` baseline (implementer `standard`, reviewer
  `frontier`, integrator `economy`, orchestrator `apex`) and optional
  `family`; a rigor level's `*_tier` keys override it.
- `[stage.<stage>].finders[]` — which registry finders serve each confidence
  stage and integration.
- `tier:<role>:*` label values are hand-added to `label-registry.json`.
- **Self-modified policy is read from the merge base.** When the change
  under review edits `.devflow.toml`, every outcome-affecting v2 field —
  `[caps]`, `[convergence]`, `[gates]` (`docs_only_paths` included),
  `[role]`, `[stage]` — is resolved from the merge-base copy, exactly as
  AGENTS.md already requires for caps, so a branch cannot lower the gate it
  is changing or classify its code as docs-only. An explicit human
  instruction still overrides.
- **The legacy shape is refused** with a migration hint
  ([#604](https://github.com/evanharmon1/harmon-devkit/issues/604)). No skill
  or script carries both shapes.

## Evidence

Round JSONs, the adjudication record, and the run record live in the git
directory while the branch is worked, **keyed by `run_id`**
(`$(git rev-parse --git-path dev-flow/runs/<run_id>/)`) with a
`dev-flow/branches/<branch>` pointer naming the current run — worktree-safe,
invisible to `git status`, and immune to a reused branch name or an abandoned
run: a new run gets a new directory, and the exit script only ever reads the
run the pointer names. When the draft PR opens they are **posted as one PR
comment per confidence stage** in a fenced block, and the run record is
updated at every later transition up to ready-for-review. The renderer
([#637](https://github.com/evanharmon1/harmon-devkit/issues/637)) writes the
human tables into the PR body from the same JSON. Nothing is deleted at PR
open.

Two rules make the posted evidence trustworthy on a public repository:

- **Scanned before posted.** Finding and evidence strings are free text and
  can quote the very credential a reviewer found. Every evidence post runs
  the repo's secret scanner over the JSON first and fails closed; the branch
  scan never sees git-directory files, so this is a separate obligation.
- **Reserved before posted.** Each evidence comment is reserved in the run
  directory (stage, attempt, the marker it will carry) before the GitHub
  write, and the comment body carries that marker. A retry after a timed-out
  response first looks the marker up on the PR and adopts the comment it
  finds; only a marker with no comment is posted again — the same
  reserve-first rule the Codex cycle already follows.
- **Authenticated when read.** The run record stores each evidence comment's
  id, author, and payload digest. The harvester accepts a comment only when
  its id is one the run record names, its author is the run's orchestrator
  login (or the repo's configured trusted actors), and its current body
  hashes to the recorded digest — so an edited, deleted, or impostor comment
  is reported as tampered evidence, never silently replayed.

See [decision 0002](../docs/decisions/0002-round-evidence-lives-on-the-pr.md).

## Sequencing

1. This spec, through at least one challenge round ([#633](https://github.com/evanharmon1/harmon-devkit/issues/633)), with harmon-init decision record 0008.
2. Schemas + fixtures [#634](https://github.com/evanharmon1/harmon-devkit/issues/634) → registry roles/finders [#635](https://github.com/evanharmon1/harmon-devkit/issues/635) → config [harmon-init#1081](https://github.com/evanharmon1/harmon-init/issues/1081).
3. Exit script [#636](https://github.com/evanharmon1/harmon-devkit/issues/636) → renderer [#637](https://github.com/evanharmon1/harmon-devkit/issues/637) → diff-aware gate [#632](https://github.com/evanharmon1/harmon-devkit/issues/632).
4. Reviewer agent + `/review` [#638](https://github.com/evanharmon1/harmon-devkit/issues/638) → integrator + `/integrate` [#639](https://github.com/evanharmon1/harmon-devkit/issues/639) → `/orchestrator`.
5. AGENTS.md shrink [harmon-init#1082](https://github.com/evanharmon1/harmon-init/issues/1082) + pre-PR gate [harmon-init#1080](https://github.com/evanharmon1/harmon-init/issues/1080) → drop legacy [#604](https://github.com/evanharmon1/harmon-devkit/issues/604).
6. Foreman [#182](https://github.com/ponderousdev/foreman/issues/182)–[#185](https://github.com/ponderousdev/foreman/issues/185); stats [#663](https://github.com/evanharmon1/harmon-devkit/issues/663) → retro [#664](https://github.com/evanharmon1/harmon-devkit/issues/664).
7. `copier update` sweep across the generated repos.

[#624](https://github.com/evanharmon1/harmon-devkit/issues/624),
[#593](https://github.com/evanharmon1/harmon-devkit/issues/593),
[#541](https://github.com/evanharmon1/harmon-devkit/issues/541),
[#473](https://github.com/evanharmon1/harmon-devkit/issues/473),
[#425](https://github.com/evanharmon1/harmon-devkit/issues/425),
[#421](https://github.com/evanharmon1/harmon-devkit/issues/421),
[#203](https://github.com/evanharmon1/harmon-devkit/issues/203) close as
absorbed by the issue that carries their criteria;
[#629](https://github.com/evanharmon1/harmon-devkit/issues/629) already has.

## Requirements

- [ ] Roles, results, envelope, run record, and adjudication record exist as JSON schemas with valid/invalid fixtures.
- [ ] The exit script computes `continue | converged | diverging | capped` from adjudicated rounds and `[convergence]`, verifies provenance and fingerprints, and replays omator#397.
- [ ] The readiness gate accepts only a schema-valid `result.integrator` for the current head as evidence of a Codex verdict — necessary, not sufficient: the gate's own pre/post-promotion content fingerprint over body, reviews, and comments (`readiness-gate.sh`) stays, because a human finding can land without moving the head.
- [ ] `.devflow.toml` has `[caps]`, `[gates]`, `[convergence]`, `[role]`, `[stage]`; the legacy shape is refused.
- [ ] Round evidence survives PR open and is harvestable with `gh api`.
- [ ] `dev-flow-stats.sh` prints the success metric and replays policies.
- [ ] AGENTS.md's Dev Loop is the stage table, the constitution rules, and references.
- [ ] Foreman accepts envelope v2, reads `.devflow.toml`, writes run records, and requires converged round artifacts.

## Acceptance criteria (Given / When / Then)

### Scenario: a reviewer cannot end a stage

- **Given** a reviewer round returns zero findings
- **When** the orchestrator runs the exit script
- **Then** the outcome is `converged` only if `min_rounds` is met, and the reviewer's own recommendation is not consulted

### Scenario: provenance is verified, not trusted

- **Given** a finding asserting `provenance: original` at a line introduced by round 1's fix commit
- **When** the exit script runs
- **Then** the finding is counted as `round:1` and the disagreement is logged

### Scenario: diverging forces de-scaffolding

- **Given** the exit is `diverging`
- **When** the orchestrator dispatches a fix round whose adjudication carries only `fix` dispositions on `round:N` findings
- **Then** the stage skill refuses the dispatch and the run stops with a blocker naming the findings

### Scenario: capped with P0/P1 never opens a PR

- **Given** the challenge cap is reached with one adjudicated P1 remaining
- **When** the orchestrator advances
- **Then** the run escalates to a human, records an intervention, and `gh pr create` is not run

### Scenario: the integration cap cannot abandon a review

- **Given** `integration = 0` and a human review comment on the draft PR
- **When** the readiness gate evaluates
- **Then** it refuses until the comment is answered, with no Codex cycle required

### Scenario: a legacy config is refused

- **Given** a `.devflow.toml` with `[rigor.*]` caps and no `[caps]` table
- **When** any v2 skill or script reads it
- **Then** it exits non-zero naming the migration, and no default is invented

### Scenario: evidence outlives the branch

- **Given** a merged PR whose branch is deleted
- **When** `dev-flow-stats.sh --run <id>` runs
- **Then** the full trajectory is rendered from the PR's stage comments and run record

### Scenario: Foreman and a session agree

- **Given** the devkit conformance fixtures at a pinned tag
- **When** Foreman's Python validator and devkit's validator run over them
- **Then** both accept every valid fixture and reject every invalid one

## Open questions

- None at draft time; the grill session of 2026-08-28 settled the design.
  Findings from the challenge round go here until adjudicated.

## Notes

Provenance: grill-with-docs session, 2026-08-28/29, against the retro of
ponderousdev/omator#397. The constitution's rule 1 (never merge without
per-merge approval) is why `merge` is a human stage and why no exit outcome
can promote past ready-for-review.
