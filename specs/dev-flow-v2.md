# Spec: Dev flow v2

- **Status:** Draft
- **Owner:** Evan Harmon
- **Date:** 2026-08-31
- **Related:** [harmon-devkit milestone "Dev flow v2"](https://github.com/evanharmon1/harmon-devkit/milestone/2)
  (anchor issue [#633](https://github.com/evanharmon1/harmon-devkit/issues/633)),
  [harmon-init milestone "Dev flow v2"](https://github.com/evanharmon1/harmon-init/milestone/4),
  [foreman milestone "Dev flow v2"](https://github.com/ponderousdev/foreman/milestone/5),
  [docs/product/domain.md § Lifecycles](../docs/product/domain.md),
  [docs/glossary.md](../docs/glossary.md),
  [docs/decisions/0002](../docs/decisions/0002-round-evidence-lives-on-the-pr.md),
  [harmon-init decision record 0009](https://github.com/evanharmon1/harmon-init/pull/1114)
  (beside 0006/0007; PR #1114).

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
where the stats script looks. The metric is reported over a **closed
cohort**: issues kicked off inside the reporting window whose runs are all
terminal, plus non-terminal runs with no run-record update for
`[convergence].stale_after` (shipped default 7 days), which the script
**terminalizes as abandoned**. Membership is frozen by an **observation
cutoff** (`--as-of`, default: now): an issue belongs to the cohort by its
first kickoff inside the window, and it is scored on the runs that existed
at the cutoff — a run started after the cutoff neither removes the issue nor
changes its score — so the same window and cutoff always report the same
share. **Reconstruction is a property, not a procedure here either**: four
review rounds of drafting the mechanism directly into this paragraph each
converged on a narrower hole than the round before, the same accretion the
convergence model below names and avoids for the same reason — the fix that
finally held is narrowing the claim to what is actually true, not a fifth
attempt at a stronger one. Within one run there is exactly one writer: the
orchestrating session, appending reserve-first — unlike an evidence
comment, a run-record entry has no comment ID of its own to canonicalize
by, since every entry lives inside the one run-record comment edited in
place. Two byte-identical entries are a harmless duplicate (a resumed
writer's own retry) and are normalized to one *before* chain validation runs
— validating the un-normalized chain first would reject a byte-identical
retry as broken (it necessarily repeats both its sequence and
previous-entry digest), rather than recognize it as the harmless case it
is; two entries that instead fork the chain (claiming the same previous
entry but carrying *different* content) are not a duplicate — `--as-of`
reconstruction SHALL fail closed and report
the run indeterminate rather than silently choosing a branch. Concurrent writers
from more than one orchestrator session are explicitly out of scope, the
same GitHub read-modify-write limitation this spec discloses elsewhere
rather than claims to close. Repeatability is a property of the chain as
**durably observed**, not of an event's own self-reported timestamp: an
entry reserved before a cutoff but not yet landed at read time is simply
not part of any chain a reader can see yet, so a later re-read that then
includes it is a difference in what has durably landed, never a violation
of "the same cutoff over the same materialized chain reports the same
share." The evidence delta spec's append-only,
digest-chained history
([§ Run history is append-only and as-of reconstructable](../openspec/changes/dev-flow-v2/specs/evidence/spec.md))
states this property — and the fork/indeterminate case — in testable form,
and #663 owns the mechanism, its fixtures, and every attack scenario these
rounds raised.
"Reached ready-for-review" means the run record carries the orchestrator's
own promotion entry — the readiness-gate pass fingerprint and the
`gh pr ready` it issued. A ready transition on the PR **without** that entry
is an unexplained promotion (AGENTS.md's known external-actor signature),
is never counted as success, and is reconciled by the existing
unexplained-promotion procedure. An **intervention** is any human action
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
  headless (harmon-init decision record 0009).
- Foreman's supervision loop. Foreman consumes the shared contracts in its own
  Python; it never wraps devkit's skills or scripts.
- Reviewer fan-out beyond the finders declared for a stage
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

`gauntlet` and `shepherd` are retired names. Skills are named with a **verb**
for the stage they run (`/implement`, `/challenge`, `/review`, `/integrate`);
agents for roles (`implementer`, `challenger`, `reviewer`, `integrator`). A
skill's verb need not match its stage's noun letter-for-letter — `/integrate`
names the `integration` stage the same way `/review` names `review` — so
this is the documented naming rule, never a drift between the two vocabularies. `/orchestrator` is the
session's standing operating mode, not a stage. Each stage skill owns its own
procedure and ends by naming the next stage; there is no skill that restates
the walk.

This milestone **builds** implement, verify, challenge, review, security,
integration, `/orchestrator`, and the retro integration
([#664](https://github.com/evanharmon1/harmon-devkit/issues/664)). It
supports parallel implementers through the implement-stage pool, council's
family-diversity constraint, and breadth ceilings. It
**names only** explore, deployment, release, smoke. Kickoff, claim, plan, wrap
are unchanged.

## Roles and authority

A **role** is a contract: the result schema an agent must return and the
external writes it may make, declared in `agent-registry.json` `roles[]`
([#635](https://github.com/evanharmon1/harmon-devkit/issues/635)). An agent
file (`ai/agents/<role>.md`) is one implementation of a role.

| Role | Returns | May write | Never |
|---|---|---|---|
| `implementer` | `result.implementer` | commits on the branch its dispatch names; feature-branch round pushes through `push-round.sh` | push the feature branch from a parallel lane; open PRs, merge, adjudicate |
| `challenger` | `result.challenger` | nothing outside its result | fix, dispose, decide an exit |
| `reviewer` | `result.reviewer` | nothing outside its result | fix, dispose, decide an exit |
| `integrator` | `result.integrator` | the Codex trigger comment; thread replies of **given** text | author reply text, dispose, promote |
| orchestrator (the session) | — | dispositions, adjudication record, `gh pr create --draft`, the PR body, evidence and run-record comments, `gh pr ready` | merge; override an exit downward |

**Invariant:** for any run, no interleaving of writers — parallel lanes,
resumed sessions, or concurrent machines — may land more than one writer's
outputs on the feature branch, and a superseded run's writes are rejected.
The enforcing mechanism belongs to #638's stage skills and #635's broker
contract, not this spec: for each feature-branch write, the broker atomically
binds the expected head to the active run identity and generation. A bare
expected-head compare-and-set is insufficient because a superseded and a
resumed run can present the same head; the two-machines-same-head race and
crashed-writer resumption are required test cases there.

**This spec is the anchor; the implementation issues are reconciled to it.**
[#634](https://github.com/evanharmon1/harmon-devkit/issues/634),
[#635](https://github.com/evanharmon1/harmon-devkit/issues/635),
[#638](https://github.com/evanharmon1/harmon-devkit/issues/638), and
[#639](https://github.com/evanharmon1/harmon-devkit/issues/639) were written
before it and still say `shepherd-watcher`/`result.shepherd`, put adjudication
fields inside `result.reviewer`, and let the reviewer commit and push. Where
an issue's criteria conflict with this table, the spec wins and the issue
body is edited to match — and back-linked here — before the issue is claimed;
that edit is part of closing [#633](https://github.com/evanharmon1/harmon-devkit/issues/633).

**Declared writes are enforced, not trusted.** A role's `writes` list is an
authorization boundary only where something enforces it: the agent file's
tool allowlist (`allowed-tools` frontmatter) denies everything not listed,
and every permitted external write goes through a broker script that
validates its one action (`push-round.sh` for the round push; a thread-reply
helper that posts exactly the text it is given; the Codex-cycle helper's
reserve → post → attach sequence for the `@codex review` trigger, which is
the integrator's one authorized comment). The `challenger`, `reviewer`, and
`integrator` roles **must not run with ambient write credentials**: a harness
that cannot restrict a subagent's tools (a plain subagent inheriting the
orchestrator's shell and `gh` token) may not dispatch those roles, and
`/orchestrator` refuses the dispatch rather than disclosing the gap — a
disclosed bypass is still a bypass. The implementer is the one role that
legitimately pushes, through `push-round.sh`. Foreman's sandbox is the
equivalent scoping for headless runs.

**Briefs are free-form; results are schema-bound.** The orchestrator → agent
brief is prose. The agent → orchestrator result is validated on receipt
against `ai/schemas/` before the orchestrator reads it.

**Whoever holds the dispatched worktree writes its named branch.** In
interactive and sandboxed runs the feature-branch implementer commits and
pushes each round through `push-round.sh`, so a crash never strands a fix on
one machine. Parallel implementers remain confined to their lane branches;
they never share feature-branch write authority. Under Foreman, Foreman pushes.

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
  "producer": {
    "harness": "claude-code",
    "family": "claude",
    "model": "…",
    "tier": "frontier"
  },
  "run": { "run_id": "…", "initiated_by": "human" },
  "payload": { }
}
```

- `implementer` payload keeps every Foreman v1 field (`summary`, `handoff`,
  `ac_test_map`, `human_tasks`, `blocked_question`) so Foreman accepts the
  envelope with a validator widening
  ([foreman#182](https://github.com/ponderousdev/foreman/issues/182)), and adds
  optional `synthesis_of`: the ordered source-proposal identities, present
  exactly when the artifact is synthesized. That schema widening rides
  [#638](https://github.com/evanharmon1/harmon-devkit/issues/638)'s synthesis
  criterion.
- `challenger` payload: one **challenge-stage pass** carrying attack scenarios,
  design-level findings, and de-scaffolding recommendations. It attacks the
  design and approach; it does not perform the reviewer's consistency and
  test-gap check.
- `reviewer` payload: one **review-stage pass** carrying consistency evidence
  and test-gap classes. It verifies the implementation; it does not own the
  challenger's design attack or de-scaffolding recommendations.
- Both confidence-role payloads carry the same stage-keyed pass core — `stage`,
  `round`, `reviewed_head`, `slot` (the configured primary finder), `finder`
  (the finder that ran), optional `substitutes_for` (present only on a
  substitution), and `findings[]`, each with `id`, `path`, `line`, `class`,
  `provenance`, `fingerprint`, `priority` (the producing role's label),
  `recommended_disposition`, and `evidence`. The exit script computes over
  that common finding core according to `stage`; it never hardcodes
  `result.reviewer`. Results are **immutable once returned**. A
  finding `id` is unique within the run by construction —
  `<stage>-r<round>-<finder>-<n>` — and receipt validation **rejects a
  result whose ids collide** with each other or with any finding already in
  the run, so an adjudication or a `repeat-of` reference can never resolve
  to two findings.
- **Heads must agree.** Receipt validation rejects any result whose payload
  names a head (`reviewed_head`, the integrator's reviewed-commit stamp)
  different from the envelope's `head`; a schema-valid result can never carry
  stale evidence under a current-head label.
- The envelope's runtime-attested `producer` names the resolved `family` as
  well as its harness, model, and tier. Retained results therefore prove both
  council `distinct_families` and every disclosed horizontal family fallback.
- `integrator` payload: checks, the Codex cycle (accepted surface, comment id,
  reviewed-commit stamp, checker exit code), findings verbatim, unanswered
  thread roots, `settled_at`, `applied_dispositions`.
- The **adjudication record** is a separate, orchestrator-authored document
  keyed by finding id: adjudicated priority and final disposition
  (`fix | restructure | delete | decline | defer | file`). `defer` is the
  disposition while a finding is carried to the integration stage; there it
  is settled to `fix`, `decline`, or `file` (a follow-up issue) — the three
  terminal answers the readiness gate accepts. The settlement is **appended,
  never edited in**: the evidence comment posted at PR open stays immutable
  under its digest, and each settlement is a new, digest-recorded entry in
  the run record (`settlements[]`, keyed by finding id, one per finding), so
  a finding still has exactly one adjudication and one terminal settlement,
  and neither invalidates the other's digest. Scripts read the
  adjudicated view; the raw challenger/reviewer output is kept so
  confidence-role-vs-orchestrator disagreement can be measured.
- The **run record** (`run.json`) is the only home of mutable run state —
  `interventions[]`, stage transitions, `outcome`, `pr`. An envelope carries
  only the immutable identity (`run_id`, `initiated_by`), so two documents can
  never disagree — and receipt validation **rejects a result whose `run_id`
  and `initiated_by` are not those of the run the branch pointer names**, so a stale result from an
  earlier retry or a concurrent run cannot attach to the wrong trajectory. It is written by whoever kicked the run off — the session or
  Foreman ([foreman#184](https://github.com/ponderousdev/foreman/issues/184)) —
  up to ready-for-review. Everything after that is **derived at read time** by
  `dev-flow-stats.sh`, never written by an actor, because the orchestrator
  stops at ready-for-review and nothing else holds the pen: merge and
  post-ready human commits from the PR's own timeline; deployment, release,
  and smoke from **repository-wide** workflow runs, releases, and the rolling
  release PR, correlated to the run by the **first** delivery whose commit range
  (previous deployment or release SHA, exclusive, to the event SHA) contains
  the merge commit — later deliveries carry the commit too and are not this
  run's.

devkit ships **conformance fixtures** (valid and invalid examples per schema)
beside the schemas. They are the shared contract with Foreman, which tests its
Python against them at a pinned tag.

## Convergence model v0

Finding fields:

- `class ∈ design | correctness | consistency | hardening | nit`
- `provenance ∈ original | round:N` — whether the finding is about the change
  or about round N's fix. Asserted by the challenger or reviewer that produced
  the finding; the exit script
  **verifies** it.
- `fingerprint ∈ new | repeat-of:<id> | supersedes:<id>` — asserted by the
  producing confidence role, which has prior rounds' findings in its brief;
  the exit script **verifies** it.

**Verification is a property, not a procedure.** Two rounds of review of
this spec showed that any concrete mechanism written here (line numbers, then
`git blame` anchors) accretes edge cases — deleted lines, a fix that exposes a
defect in unchanged code, a repeat whose implicated line the fix rewrote — so
this spec states the invariants and delegates the mechanism to the exit
script ([#636](https://github.com/evanharmon1/harmon-devkit/issues/636)),
where it can be tested:

- The script may **downgrade** a producer's `original` to `round:N`, or
  refuse a `repeat-of`/`supersedes`, only with evidence it records alongside
  the finding; it never silently overrides. A case it cannot decide is
  logged `unverified`. An unverified finding **keeps its adjudicated
  priority for gating** — an unverified P1 still blocks `converged` and
  capped-clean, because fail-closed means a defect of unknown origin is still
  a defect — and is **excluded from the provenance-dependent predicates**
  (`provenance_share`, `repeat_after_fix`), whose truth needs the very fact
  that could not be verified — while it still counts toward `count_rising`'s
  totals — that predicate's provenance guard (at least one *verified*
  `round:N` finding in the current round) is still required for it to be
  true, so unverified findings raise the counts but never satisfy the guard
  on their own. So a mistaken assertion cannot force or hide a
  provenance-based divergence, and a self-feeding trajectory still shows in
  the counts.
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
| `continue` | no exit predicate satisfied; cap not reached | dispatch the next round — a fix round when any disposition changes code, otherwise another pass from the stage's confidence role on the unchanged head (a clean round under `min_rounds` changes nothing to fix) |
| `converged` | **zero adjudicated P0/P1 of any class** (a universal precondition, not a predicate), an exit predicate satisfied, and `min_rounds` met | advance; or override **upward** (one more round) with a recorded reason |
| `diverging` | adjudicated P0/P1 findings are feeding on earlier rounds' fixes, and the cap is not reached | dispatch a fix round **only** with a `delete` or `restructure` disposition on the `round:N` findings; otherwise the run stops with a blocker |
| `capped` | cap reached | advance if zero adjudicated P0/P1 remain **and the final round reviewed the current head** (**capped-clean**); otherwise **escalate to a human** — no PR is opened, and no further round is dispatched whatever else holds. A P2 found by the final round is therefore `defer`red to integration rather than fixed pre-PR, since no round remains to review the fix |

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
means editing the script. A rigor level may **tighten** this and never
loosen it, and tightening is defined **structurally**: add an entry to an
`all` list, remove an entry from an `any` list, or raise a numeric
threshold on `converged`; add an entry to any list or lower a threshold on
`diverging`. Anything else is loosening — removing a `converged` `all`
entry included, since `all` with fewer conditions is easier — and is
refused. The reason: `rigor:*` labels are advisory and can be
applied by anyone with triage, so an override that could weaken an exit would
let a label change safety semantics rather than the amount of review. Loosening
is an explicit-instruction edit to the base `[convergence]` table, resolved
from the merge base like every other cap.

```toml
[convergence]
converged = { all = [ { predicate = "no_gating_findings" } ] }
diverging = { any = [
  { predicate = "count_rising",     increases = 2 },
  { predicate = "repeat_after_fix" },
  { predicate = "provenance_share", min = 0.5, exclude_classes = ["design"] },
] }
```

The v0 catalog, defined so two implementations agree. All predicates evaluate
over **adjudicated P0/P1 findings** of the stage's rounds; "current round"
is the latest round whose `reviewed_head` is the current head. Because
`converged` already requires zero P0/P1 in the current round, its predicate
list in v0 is the trivial `no_gating_findings` — the catalog exists so later
policies can add conditions (a minimum share of `nit`-class findings, a
required finder), not because v0 needs them. The interesting predicates are
the **divergence** ones: they read the trajectory *before* the current round
is clean, which is where omator#397 would have been stopped.

- `no_gating_findings()` — true when the current round has zero adjudicated
  P0/P1 findings. (Identical to the universal precondition; listed so the
  `converged` table is never empty.)
- `provenance_share(min, exclude_classes)` — numerator: current-round
  P0/P1 findings with `provenance = round:N` for any N; denominator: all
  current-round P0/P1 findings; both after removing `exclude_classes` and
  `unverified` findings. True when the denominator is non-zero and the ratio
  is ≥ `min` — most of what is still wrong is about earlier fixes.
- `count_rising(increases)` — true when the P0/P1 count has **strictly
  increased `increases` times in a row** ending at the current round (so it
  reads `increases` + 1 rounds and is false with fewer), **and** the current
  round contains at least one verified `round:N` finding — a rising count of
  purely `original` findings is a change that was under-reviewed, not a
  stage feeding on itself. `unverified` findings count toward the totals.
- `repeat_after_fix()` — true when any current-round finding is
  `repeat-of:<id>` (verified, or a script-detected repeat) where `<id>`'s
  adjudicated disposition **changed the code** — `fix`, `restructure`,
  `delete`, or `split` — in an earlier round. (A repeat after `decline` is
  the finding producer disagreeing, not the loop feeding on itself.)

Boundary fixtures for each — empty current round, a single round, a
denominator of zero, a repeat whose original was `decline`d — ship with the
exit script and are part of the conformance set.

### The split strategy

Two named ways to converge a loop feeding on its own fixes are already
above — **delete the scaffolding** and **restructure it to invariants**. A
third exists and, until issue
[#747](https://github.com/evanharmon1/harmon-devkit/issues/747), lived only
as a maintainer's judgement call: **split the mechanism out**.

It applies when successive rounds' gating findings concentrate in **one
mechanism**, most sharply one that an **earlier round of the same stage
added**. It is distinct from the other two on one fact: the mechanism is
still wanted. Deleting it drops work that is genuinely needed; restructuring
it to an invariant is unavailable because it is code, not accreted
procedure-prose. So instead of hardening it again on this change's review
budget, the mechanism leaves the change and gets a budget of its own.

What a split produces, all four parts or it is not a split:

1. the mechanism is **removed from the change under review**;
2. it is **filed as its own issue on the current milestone**, carrying the
   design constraints the rounds established — by the agent that splits it,
   at the moment it splits it, never left to memory;
3. whatever finding the mechanism was **addressing** is restored as a filed
   follow-up, so removing the mechanism does not silently drop the defect it
   existed for;
4. **one deletion round** confirms the removal, and the stage then exits
   through its ordinary conditions — the split buys no exception to them.

The record is two documents, deliberately: the per-finding half is an
`adjudication.schema.json` entry with `disposition: split` and a `reference`
naming the filed issue, and the run-level half is `run.schema.json`'s
`splits[]` naming the mechanism, the issue, its milestone, and the findings
the split answers. Neither proves the other, so a validator holding both
checks that they agree.

**The signal.** So that a session can propose a split at round 2 rather than
after nine rounds, the exit script emits a `split_candidate` projection
alongside every verdict computed from a complete latest round:

| Field | Meaning |
|---|---|
| `mechanism` | the rename-tracked origin path holding the most of this round's adjudicated P0/P1 findings |
| `concentration` | that mechanism's share of them |
| `provenance_share` | the round-wide share of decidable P0/P1 findings whose verified provenance is `round:N` |
| `introduced_by_rounds` | the earlier rounds this mechanism's findings are attributed to |
| `finding_ids`, `consecutive_rounds`, `round` | the evidence a blocker report has to carry |
| `detected`, `reason` | the verdict on the signal, and which test settled it |

`detected` is true when one mechanism holds **every** adjudicated P0/P1
finding of the current round, at least one of them has evidence-backed
`round:N` provenance, and the **immediately preceding** round's own gating
findings were concentrated in that same mechanism.

Two properties of that rule are load-bearing. It is **knob-free**:
concentration is unanimity rather than a fraction, and the trajectory test is
the adjacent round rather than a window, so no per-stage threshold is
configurable and a rigor level cannot tune the signal (the config spec records
this decision). And it is a **diagnostic, not an outcome**: no exit outcome,
exit code, precedence rule, or cap depends on it. A capped stage that would
have said only "cap reached" can now say which mechanism it capped on and
offer the split beside "order more rounds" and "accept as spent"; what it may
not do is decide for the human.

An `unverified` provenance claim leaves `provenance_share`'s numerator and
denominator alike, exactly as the `provenance_share` predicate treats it — a
claim no ledger could decide must neither manufacture nor mask the signal —
while still counting toward `concentration`, which is about where the findings
are rather than where they came from. `exclude_classes` is not applied to this
projection at all: that parameter tunes a gate, and this is evidence.

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
The complete schema-v2 draft and rationale are in the issue's 2026-08-31
decision comment. Schema v2 is incompatible under harmon-init decision record
0008, the versioned-devflow compatibility contract: v1 consumers reject this
file with a migration hint, and v2 consumers refuse both the legacy and v1
shapes rather than carrying multiple interpretations. Shape refusal applies
only to the file a consumer operates under; a historical merge-base copy is
interpreted under its own declared `schema_version` — v1 by v1 rules and legacy
by legacy rules. Per that ADR's own pattern (v1's incompatibility bump shipped
`.devflow-conformance-v1.json`), this v2 bump — carrying the `[review.*]` →
`[caps.*]` → `[rounds.*]` rename among its incompatible changes — ships
`.devflow-conformance-v2.json` as the v2 fixture corpus.
The composed predicate catalog in this spec is normative for `[convergence]`;
the draft's flat keys are illustrative placeholders, superseded by the
predicate names [#636](https://github.com/evanharmon1/harmon-devkit/issues/636)'s
branch (`feat/636-dev-flow-exit`, PR #720, not yet merged) pins and
range-validates — confirmed directly against that branch, matching this
spec's own catalog byte-for-byte. A catalog entry may itself be a nested `{ any = [...] }` /
`{ all = [...] }` node, recursively; a per-rigor `[rigor.<level>.convergence]`
override tightens by the same structural rules above whether an entry is
flat or itself a nested subtree (the reader matches nested entries between
base and override by full structural identity, not by a `.predicate` key):
adding a whole new nested subtree to a `converged` `all` list or a
`diverging` `any` list is exactly as well-defined a tightening move as
adding a flat leaf to either, and refusing it would forbid a case the
general rule above already permits. What has **no** defined direction, and
is refused, is an override that changes the **internal structure** of a
nested subtree the base already carries — whether that sub-formula got
stricter or looser needs recursively evaluating a composed predicate this
rule does not define. One present unchanged in both base and override
contributes nothing to added/removed either way.

`#636`'s branch also carries the one bounded historical decoder the
merge-base rule below requires: on a migration branch, it maps the legacy
`[rigor.<level>]` `shepherd` cap onto v2's `integration`/`remediation` pair
(and a decoder-only `rounds.shared_budget` marker recording that the legacy
cap charged one round per fix push or no-change cycle, never a finding cycle
and its answering push separately — that marker never appears in an actual
v2 file) and decodes the v1 `[review.*]` policy the same way — this part
verified directly against that branch. **Every other axis (`breadth`,
`spend`, `convergence`, `tier_order`, `roles`, `stages`, `strategy`) is filled
from the reader's own built-in defaults, not decoded from the older shape's
declared values, as of the current #636 branch** — narrower than this
decision's own design (`openspec/changes/dev-flow-v2/design.md` decision 13)
describes, and a real gap against the merge-base rule below: a migration
branch that also edits, say, `[tier.*]` or `[budget.*]` on a self-modifying
change resolves those axes from built-ins rather than the merge-base's own
declared values, which the merge-base rule requires. Closing that gap
belongs to #636's own scope, not this lane's; noted here so the anchor
states what is actually true of that branch's reader today, before it
merges, rather than the fuller decode the design intends. Task 2.3's own
fixture requirement now names this precisely: a mutate-and-prove-unchanged
fixture alone cannot force the fuller decode (a built-ins-only decoder
that ignores the merge-base's declared values passes it trivially), so the
task additionally proves a decoded value equals what the merge-base itself
declares whenever that value is non-default.

Every array key declares one of five semantics:

| Kind | Meaning |
|---|---|
| **preference** | ordered any-of; use the first configured and available entry, then fall over on failure or quota and disclose the substitution |
| **chain** | ordered and consumed strictly in sequence |
| **all-of** | unordered; every entry must be satisfied |
| **allowlist** | unordered membership restriction, never a preference order |
| **ranking** | ordered scale definition, not a selection |

The v2 shape is:

- Top level: `schema_version = 2`, `default_rigor`, `default_strategy`, and two
  rankings. `rigor_order` is `cursory → light → standard → thorough → deep →
  forensic`; the old `trivial` and `minimal` levels collapse into `cursory`,
  which still buys a 1/1/1 challenge/review/integration glance. `forensic` is
  the new top level and sets `min_rounds = 2`. A custom all-zero policy remains
  schema-valid, but no shipped level uses one. `tier_order` is
  `local → economy → standard → frontier → apex` and is the only definition
  of one-rung escalation or strongest-wins tier conflicts.

  Resolution precedence is normative: an explicit operator instruction from
  an attributable channel (never repository content) overrides labels, which
  override the rigor profile or configured defaults, which override the
  built-in fallback. An unscoped `tier:*` targets only the implementer role.
  Tier conflicts resolve strongest-wins by `tier_order`, with a concrete tier
  beating `adaptive`. Strategy conflicts are ambiguous: an interactive
  resolver asks, while unattended automation falls back to `default_strategy`
  with a warning. Labels remain advisory and never outrank an explicit
  instruction: an interactive session requires operator confirmation before
  using any off-default label resolution, while unattended automation acts on
  one only after verifying the label's provenance end to end against
  trusted-actor configuration re-read immediately before acting, or falls back
  to defaults with a warning.
  Conflicting `rigor:*` labels resolve to the strongest recognized level in
  `rigor_order`; values absent from that ranking are ignored.
- `[rigor.<level>]` points to one same-named `[rounds.*]` policy and one
  same-named `[breadth.*]` envelope, carries the five role overrides
  (`orchestrator_tier`, `implementer_tier`, `challenger_tier`,
  `reviewer_tier`, `integrator_tier`), and declares boolean `tier_escalation`.
  The shipped baselines are orchestrator `apex`, implementer `standard`,
  challenger `frontier`, reviewer `standard`, and integrator `economy`.
  Orchestrator, challenger, and reviewer are each at least as capable as
  implementer; challenger rides one stratum above reviewer at most levels
  because design attack is the more judgment-heavy contract. Unscoped
  `tier:adaptive` remains a valid implementer refinement: preflight classifies
  that role's tier instead of pinning a rung, using the rigor profile's tier
  provisionally until it answers. A concrete tier label for the same role beats
  adaptive under `tier_order`; scoped `tier:<role>:adaptive` has no registry
  tier and is ignored.
- `[rounds.<policy>]` is the **vertical appetite**: `challenge`, `review`,
  `integration`, `remediation`, `min_rounds`, and `wall_clock_min`. A
  challenge or review value of 0 disables that confidence stage with
  `capped`/`disabled`; otherwise the effective floor is
  `min(min_rounds, cap)`. `integration` bounds Codex re-review cycles only:
  0 waives the readiness gate's Codex condition entirely, never the obligation
  to answer human or CI findings. The post-fix unreviewed-head blocker applies
  only when `integration > 0`: a fix after the last permitted cycle stops with
  a blocker naming that head and leaves the PR draft. The only ways forward
  from there are a maintainer-granted additional cycle or the block standing;
  promotion never substitutes for the missing current-head verdict, whatever
  the cap says. `remediation`
  independently bounds integration-stage fix pushes, including when
  `integration = 0`; at its ceiling, or at the first fix when it is 0, the run
  escalates with unresolved findings rather than abandoning or promoting past
  them. `wall_clock_min` is a ceiling for the **whole run**; reaching it posts
  a blocker report and stops, never trims an unfinished stage to fit. There is
  no round cap for deterministic checks.
- `[breadth.<policy>]` is the **horizontal scale** and contains only
  `max_agent_runs` and `max_parallel_agents`. Review passes spend the rounds
  envelope instead. These ceilings bound orchestrated and council execution,
  including the milestone's parallel implementers. Mandatory fix dispatches
  spend `max_agent_runs` too; if one would exceed it, the run ends `capped` and
  escalates naming the exhausted envelope — never an uncounted dispatch or
  `continue` with no legal action.
- `[spend.<policy>]` defines `max_tokens` and `max_usd`; a
  `[rigor.<level>]` may name `spend = "<policy>"`, and absent that key no spend
  envelope applies. The table is **unshipped**, so spend limits remain
  `UNENFORCED` in shipped profiles until measurable. Tier escalation is not a
  spend key; it belongs to each rigor profile.
- `[gates]` declares `round_code`, `round_docs`, `secret_scan`, and `pre_pr` as
  **bare existing Taskfile target names** — no argv, paths, spaces, or slashes.
  The validator refuses anything else, so config may select a repository
  command but can never mint one; consumers compose `task <target>`. The
  pre-PR target runs after asserting the head carries a round-gate marker, and
  `task ci` remains on demand
  ([harmon-init#1080](https://github.com/evanharmon1/harmon-init/issues/1080)).
  `docs_only_paths[]` is an allowlist and the **only** copy of the docs-only
  classification; the push helper re-derives it from the diff. Foreman's
  `[verify].default` derives from `pre_pr`
  ([foreman#183](https://github.com/ponderousdev/foreman/issues/183)).
- `[convergence]` is the predicate catalog above, with tighten-only
  `[rigor.<level>.convergence]` overrides.
- `[role.<slug>]` declares the role's baseline `tier` and its `families[]` and
  optional `harnesses[]`, both **preference** arrays. `harnesses[]` values must
  resolve against `agent-registry.json` `harnesses[]`; valid examples are
  `claude-code`, `codex-cli`, and `antigravity`. Resolution is family first,
  then harness within that family. When the resolved rigor profile sets
  `tier_escalation = true`, failure, refusal, or operator policy — never cost
  alone — may first attempt vertical escalation by exactly one `tier_order`
  rung within the same family. A family with no model at that higher rung
  simply cannot escalate; that fact alone does not make the family unavailable.
  Horizontal fallback to the next `families[]` entry happens only when the
  current family cannot serve at the resolved (or already-escalated current)
  tier at all, and every fallback is disclosed. Validation requires every role
  × rigor profile to have at least one resolvable family. An absent harness
  preference means any registered harness that serves the family. The
  orchestrator declares both arrays too: they are descriptive when a human has
  already opened the session, and binding when Foreman or another automation
  chooses the harness to open.
- `[strategy.<name>]` carries the v1-shipped strategy contract forward
  unchanged. `topology` selects `single-agent` (one accountable lead and only
  optional helper subagents), `lead-and-workers` (a lead with required
  first-class workers), `independent-proposals` (a coordinator dispatches at
  least two independent proposers and judges them), or `human-directed` (the
  human is accountable). `planning` is `inline` (folded into the first turn),
  `explicit` (a stated plan), `independent` (each proposal plans for itself),
  or `collaborative` (planned with the human). `delegation` is `none`,
  `optional`, or `required`, with the v1 topology constraints; optional
  `coordination = "parallel-when-independent"` governs delegated scheduling.
  Council alone uses `selection = "judge"` and boolean `synthesis`; its
  `min_agents` counts proposers, while orchestrate's counts the lead plus
  workers. `human_gates` may contain only `after-discovery`, `after-plan`,
  `before-delegation`, `before-selection`, `before-synthesis`,
  `before-scope-expansion`, `before-budget-escalation`, `before-publication`,
  `before-ready-for-review`, and `each-phase`. Constitutional approvals remain
  outside strategy and cannot be disabled by it. Under v2's breadth
  accounting, every implementer or lane dispatch and every synthesis dispatch
  consumes one `max_agent_runs`; council judging is write-free and consumes
  none. Challenge and review passes never consume this envelope —
  `[rounds.<policy>]` bounds them on its independent axis.
- `[stage.<stage>]` uses monomorphic arrays whose keys carry the semantics and
  whose values are always registry slugs. `finders` is **all-of**. In the
  confidence stages (`challenge` and `review`), each primary finder defines one
  round slot, and every slot must produce exactly one pass at the same
  `reviewed_head`; the common `stage`/`round`/`slot` pass contract applies only
  there. Integration finders instead contribute checks, cycle, and thread
  evidence inside `result.integrator` and produce no confidence pass.
  `finder_fallbacks` is a **preference** list consumed in listed order after a
  primary is unavailable after its retry.
  Fallback candidates are tried until one can fill the failed slot, but at
  most one substitute binds to that slot for the round. A primary pass has
  `finder == slot` and omits `substitutes_for`; a fallback pass names the
  fallback that ran in `finder`, keeps the configured primary in `slot`, and
  sets `substitutes_for` to that primary. An actor already serving as a primary
  or substitute in the round cannot satisfy a second slot. Every substitution
  is recorded and disclosed. A slot still unavailable when the fallback list
  is exhausted ends the run
  `capped`/`finder_unavailable`, never silently one pass short.

  `pool` is an optional **allowlist** for the implement stage; when absent,
  every implementer-capable registered harness is eligible. Strategy supplies
  the number and topology — including council's `distinct_families` constraint
  — while breadth supplies the ceilings. Before dispatch, strategy, pool,
  breadth, and registry are cross-validated against every strategy's required
  topology. Orchestrate requires `max_agent_runs >= min_agents` and, only under
  parallel coordination, `max_parallel_agents >= min_agents`; sequential
  dispatch needs only the run coverage. A council requiring N distinct families
  likewise requires at least N eligible families in the implement-stage pool
  and `max_agent_runs >= N`, plus `max_parallel_agents >= N` only under parallel
  coordination. A council with `synthesis = true` requires
  `max_agent_runs >= N + 1` for the fresh synthesis dispatch. Judging itself
  consumes no run. Any unsatisfiable strategy-and-breadth pair is reported
  incompatible at resolution time, never allowed to deadlock at dispatch.
  Council judging yields one artifact:
  either a selected proposal or, when `synthesis = true`, the output of one
  fresh implementer dispatch briefed with the source proposals. The judge
  writes no code, confidence roles remain write-free, and no new role is
  introduced: synthesis returns an ordinary lane artifact under the existing
  `result.implementer` contract, with `synthesis_of` naming its ordered source
  proposals. The run record records that judged artifact and every proposal's
  identity and outcome. The judged artifact enters the same serialized
  single-writer apply path; other lane outputs are discarded.

  Validation makes two independent checks. **Role dispatch:** the agent
  dispatched for a stage implements that stage's role (implement →
  implementer, challenge → challenger, review → reviewer, integration →
  integrator). **Finder affinity:** each `finders[]` and `finder_fallbacks[]`
  entry is valid for the stage according to its registry-declared surface and
  permitted stage kinds, never according to the dispatched role. An ineligible
  fallback is excluded at resolution time; a slot left with no eligible
  substitute ends `capped`/`finder_unavailable`. The challenge stage therefore
  receives `result.challenger`, the review stage receives `result.reviewer`,
  and the exit script consumes their shared finding core by stage rather than
  hardcoding one result role.
- There are **no `[tier.*]` tables**. Model-stratum classification belongs to
  `agent-registry.json` `families[].models[].tier`; when a family exposes two
  or more models at one rung, exactly one carries `default: true`
  ([#635](https://github.com/evanharmon1/harmon-devkit/issues/635)). The
  resolved model is the chosen family's registry model at the resolved rung.
  When enabled by the rigor profile, escalation derives as one rung up
  `tier_order` and never switches family; a family with no model at that rung
  simply cannot escalate. That is not, by itself, the unavailable-family case
  and does not trigger horizontal fallback; whether fallback is legal still
  depends on the family's ability to serve at the resolved or current tier.
  Local binding is the registry's `-local` harnesses under ADR 0005. This
  config never names a concrete model. `tier:<role>:*` label values remain
  hand-authored in `label-registry.json`.
- **Self-modified policy is read from the merge base.** When the change edits
  `.devflow.toml` or `agent-registry.json`, every input that can affect policy
  resolution comes from the merge-base copy: defaults and both rankings, the
  rigor profile, `[rounds]`, `[breadth]`, any `[spend]`, `[gates]`
  (`docs_only_paths` included), `[convergence]`, `[role]`, `[stage]`,
  `[strategy]`, and the registry's roles, actors, model classifications, and
  trusted IDs. A branch therefore cannot lower or widen the gate it is
  changing. A v1→v2 migration therefore resolves its budget from the v1
  merge-base by v1 rules while shipping the v2 file. An explicit human
  instruction still overrides.

## Evidence

Round JSONs and the adjudication record live in the git directory while the
branch is worked (the run record too, as a working copy of the issue
comment that is its durable home), **keyed by `run_id`**
(`$(git rev-parse --git-common-dir)/dev-flow/runs/<run_id>/` — the
**common** directory, so every linked worktree sees the same runs and
removing a worktree deletes nothing) with a
`dev-flow/branches/<branch>` pointer naming the current run — worktree-safe,
invisible to `git status`, and immune to a reused branch name or an abandoned
run: a new run gets a new directory, and the exit script only ever reads the
run the pointer names. **Each round's evidence is posted to the issue the
moment the round is adjudicated** — one comment per round, beside the run
record — so a worker that disappears after a round loses at most the round
in flight, and no later process is needed to upload a trajectory. When the
draft PR opens, the orchestrator posts **one comment per confidence stage**
on the PR that carries the stage's rounds so far and links the per-round
issue comments (later rounds append to the issue and are linked from the
PR body) — the run record stays on the issue and is edited there — in a fenced block (continued in
order across further comments only when GitHub's size limit forces it — the
harvester reassembles by marker sequence). A run that **ends without a PR** —
capped with P0/P1, abandoned, escalated — posts the same stage comments on
the **issue**, beside the run record that already lives there, as part of its
blocker report: the failed trajectories are the ones replay most needs, and
they must not exist only in one clone. The run record is updated at every
later transition up to ready-for-review. The renderer
([#637](https://github.com/evanharmon1/harmon-devkit/issues/637)) writes the
human tables into the PR body from the same JSON. Nothing is deleted at PR
open.

Two rules make the posted evidence trustworthy on a public repository:

- **Scanned before posted.** Finding and evidence strings are free text and
  can quote the very credential a reviewer found. Every evidence post runs
  the repo's secret scanner over the JSON first and fails closed; the branch
  scan never sees git-directory files, so this is a separate obligation.
  Failing closed does not mean the round is lost: the renderer
  ([#637](https://github.com/evanharmon1/harmon-devkit/issues/637)) replaces
  each detected span with a stable `[REDACTED:<rule-id>]` placeholder and
  posts that sanitized projection instead of the blocked original, so
  durability survives a real credential without ever disclosing it; the
  unredacted JSON stays in the git directory, never posted.
- **Reserved before posted.** Each evidence comment carries a
  **deterministic** marker — `run_id`, stage, sequence — computable from the
  run record alone, and is reserved in the run directory before the GitHub
  write. Any resume, on any machine, first looks the marker up on the PR or
  issue and adopts the comment it finds **only if that comment's author's
  immutable actor ID is the run's orchestrator (or a trusted actor)** — an untrusted
  comment carrying the marker is reported, ignored, and does not suppress the
  legitimate post; only a marker with no trusted comment is posted — the same reserve-first rule the Codex cycle already follows, and
  recoverable without the clone that made the reservation.
- **Authenticated when read.** The run record stores each evidence comment's
  id, author, and payload digest. The harvester accepts a comment only when
  its id is one the run record names, its author's **immutable actor ID**
  matches the run's orchestrator (or a configured trusted actor — logins are
  stored for display only, since a rename would otherwise turn valid
  evidence into "tampered"), and its current body
  hashes to the recorded digest — so an edited, deleted, or impostor comment
  is reported as tampered evidence, never silently replayed. "The run's
  orchestrator" is never a value the record's own JSON body declares — that
  would let a forged record vouch for its own evidence. Its authority
  derives **solely** from configured trusted-orchestrator actor IDs — the
  registry's trusted actors, declared in `agent-registry.json`, the same
  finder trust IDs already use — matched here rather than re-derived, the
  same source the evidence delta spec names
  ([§ Harvested evidence is authenticated](../openspec/changes/dev-flow-v2/specs/evidence/spec.md)).
  There is no kickoff-event fallback: three earlier drafts of this paragraph
  each tried to define one (matching the kickoff actor's identity; matching
  identity plus a locally-asserted permission claim; naming it "the trusted
  kickoff event" without saying what makes it trusted) and all three were
  broken the same way — a kickoff-shaped event proves nothing about who
  posted it, so an actor able to forge one can equally forge whatever the
  fallback checks inside it. The schema field for the configured list is
  [#741](https://github.com/evanharmon1/harmon-devkit/issues/741)'s to add
  — a dedicated follow-up, after both #634 (result schemas) and #635
  (registry roles/finders) closed without adding it — not a mechanism this
  anchor re-derives. Trust evaluation for a given run is pinned to an
  authoritative registry revision, never the registry's current content:
  trust for each evidence write is evaluated against the registry revision
  current on the default branch at that write's server-side `created_at`
  (the run record's `updated_at` likewise), and a kickoff-time snapshot is a
  permitted implementation only when it resolves to the same revision for
  every write — so an actor added to the list later does not retroactively
  authenticate that run's older evidence, and an actor later removed does
  not invalidate evidence authenticated while they were still trusted. Until a repository configures that
  list, a run record has no authority to validate against and its evidence
  is reported unauthenticated rather than silently accepted on an unproven
  identity.
  The run record comment is subject to the **same author check** against
  that trust root, so a stranger cannot forge a record that vouches
  for their own evidence; an orchestrator that
  rewrites its own record is outside the threat model — it could equally have
  lied in the first place, and the challenger/reviewer raw output on the same
  comments is what the retro compares against.

See [decision 0002](../docs/decisions/0002-round-evidence-lives-on-the-pr.md).

## Sequencing

1. This spec, through at least one challenge round ([#633](https://github.com/evanharmon1/harmon-devkit/issues/633)), with harmon-init decision record 0009.
2. Schemas + fixtures [#634](https://github.com/evanharmon1/harmon-devkit/issues/634) → registry roles/finders [#635](https://github.com/evanharmon1/harmon-devkit/issues/635) → config [harmon-init#1081](https://github.com/evanharmon1/harmon-init/issues/1081).
3. Exit script [#636](https://github.com/evanharmon1/harmon-devkit/issues/636) → renderer [#637](https://github.com/evanharmon1/harmon-devkit/issues/637) → diff-aware gate [#632](https://github.com/evanharmon1/harmon-devkit/issues/632).
4. Implement dispatch draws from the stage pool under strategy and breadth constraints and obeys the single-writer invariant above; council judgment emits the selected or synthesized artifact described above. Then challenger agent + `/challenge`, reviewer agent + `/review` [#638](https://github.com/evanharmon1/harmon-devkit/issues/638) → integrator + `/integrate` [#639](https://github.com/evanharmon1/harmon-devkit/issues/639) → `/orchestrator`.
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
- [ ] `.devflow.toml` has top-level `default_rigor`, `default_strategy`, `rigor_order`, and `tier_order`, plus `[rounds]`, `[breadth]`, `[gates]`, `[convergence]`, `[role]`, `[stage]`, and `[strategy.*]`; `[spend]` is schema-only and shipped absent; both legacy and v1 shapes are refused.
- [ ] Round evidence survives PR open and is harvestable with `gh api`; the evidence protocol ships regression fixtures for: interruption after the post but before the id is recorded (marker adoption, no duplicate); a forged-author comment; an edited payload (digest mismatch → tampered); a secret in finding text (redacted projection posted, unredacted evidence stays local); a stage split across comments (reassembled); a run capped before any PR (stage evidence and run record found on the issue).
- [ ] `dev-flow-stats.sh` prints the success metric and replays policies.
- [ ] AGENTS.md's Dev Loop is the stage table, the constitution rules, and references.
- [ ] Foreman accepts envelope v2, reads `.devflow.toml`, writes run records, and requires, for each confidence stage, either round artifacts whose recomputed exit is a terminal clean outcome (`converged` or capped-clean) or — for a stage whose cap is 0 — the computed `capped`/`disabled` record alone, since a disabled stage runs no round.

## Acceptance criteria (Given / When / Then)

### Scenario: a confidence role cannot end a stage

- **Given** a challenger pass in challenge or a reviewer pass in review returns zero findings
- **When** the orchestrator runs the exit script
- **Then** the outcome is `converged` only if `min_rounds` is met, and the producing role's own recommendation is not consulted

### Scenario: provenance is verified, not trusted

- **Given** a finding asserting `provenance: original` at a line introduced by round 1's fix commit
- **When** the exit script runs
- **Then** the finding is counted as `round:1` and the disagreement is logged

### Scenario: diverging forces de-scaffolding

- **Given** the exit is `diverging`
- **When** the orchestrator dispatches a fix round whose adjudication carries only `fix` dispositions on `round:N` findings
- **Then** the stage skill refuses the dispatch and the run stops with a blocker naming the findings

### Scenario: a capped stage names its split candidate

- **Given** rounds n and n+1 whose every adjudicated P0/P1 finding lives in one mechanism, and round n+1's carry `round:n` provenance the ledger confirms
- **When** the exit script runs at the cap
- **Then** the outcome is still `capped`, and the verdict carries `split_candidate.detected: true` naming that mechanism, the rounds that introduced it, and the findings living in it — which the blocker report renders as "split the mechanism out" beside "order more rounds" and "accept as spent"

### Scenario: a concentrated round with no round provenance is not a split candidate

- **Given** a capped round whose adjudicated P0/P1 findings all sit in one file, every one of them verified `original`
- **When** the exit script runs
- **Then** `split_candidate.detected` is false with reason `no_round_provenance` — an under-reviewed change is not a loop feeding on its own fixes

### Scenario: a split names the issue it was filed as

- **Given** an adjudication entry with `disposition: split`
- **When** it carries no `reference`, or one that is not an `issue_number`
- **Then** the validator rejects the document — a split-off mechanism is filed by the agent that splits it, never left to memory

### Scenario: capped with P0/P1 never opens a PR

- **Given** the challenge cap is reached with one adjudicated P1 remaining
- **When** the orchestrator advances
- **Then** the run escalates to a human, records an intervention, and `gh pr create` is not run

### Scenario: the integration cap cannot abandon a review

- **Given** `integration = 0` and a human review comment on the draft PR
- **When** the readiness gate evaluates
- **Then** it refuses until the comment is answered, with no Codex cycle required

### Scenario: a legacy config cannot be the operating config

- **Given** a legacy `.devflow.toml` with direct `[rigor.*]` caps, or a v1 file with `[review.*]` and `[budget.*]`
- **When** a v2 skill or script attempts to operate under it as the active config
- **Then** it exits non-zero naming the migration, and no default is invented
- **And** for a migration PR, policy resolution instead reads the historical merge-base copy under that copy's own legacy or v1 schema; that required historical read is not operation under the old file

### Scenario: evidence outlives the branch

- **Given** a merged PR whose branch is deleted
- **When** `dev-flow-stats.sh --run <id>` runs
- **Then** the full trajectory is rendered from the PR's stage comments and the issue's run record

### Scenario: a run that never opened a PR is still counted

- **Given** a run whose challenge stage capped with a P1 and escalated, with no branch left
- **When** `dev-flow-stats.sh --repo <owner/repo>` runs
- **Then** the issue counts in the denominator as a failure, and `--run <id>` renders its rounds from the issue's stage comments

### Scenario: the remediation cap escalates

- **Given** `remediation = 2` and a CI check that fails again after each of two fix pushes in the integration stage
- **When** the next finding arrives
- **Then** no third fix push is made; the run records `capped` for integration, posts a blocker report naming the unresolved finding, and the PR stays draft

### Scenario: Foreman and a session agree

- **Given** the devkit conformance fixtures at a pinned tag
- **When** Foreman's Python validator and devkit's validator run over them
- **Then** both accept every valid fixture and reject every invalid one

## Open questions

- None at draft time; the grill session of 2026-08-28 and config session of
  2026-08-31 settled the design.
  Findings from the challenge round go here until adjudicated.

## Notes

Provenance: grill-with-docs sessions, 2026-08-28/29 and 2026-08-31, against the
retro of ponderousdev/omator#397. The constitution's rule 1 (never merge without
per-merge approval) is why `merge` is a human stage and why no exit outcome
can promote past ready-for-review.
