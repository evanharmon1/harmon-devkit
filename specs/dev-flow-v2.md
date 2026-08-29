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
  [harmon-init decision record 0008](https://github.com/evanharmon1/harmon-init/pull/1114)
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
share.
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
| orchestrator (the session) | — | dispositions, adjudication record, `gh pr create --draft`, the PR body, evidence and run-record comments, `gh pr ready` | merge; override an exit downward |

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
the integrator's one authorized comment). The `reviewer` and
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
  `<stage>-r<round>-<finder>-<n>` — and receipt validation **rejects a
  result whose ids collide** with each other or with any finding already in
  the run, so an adjudication or a `repeat-of` reference can never resolve
  to two findings.
- **Heads must agree.** Receipt validation rejects any result whose payload
  names a head (`reviewed_head`, the integrator's reviewed-commit stamp)
  different from the envelope's `head`; a schema-valid result can never carry
  stale evidence under a current-head label.
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
  adjudicated view; the raw reviewer output is kept so reviewer-vs-orchestrator
  disagreement can be measured.
- The **run record** (`run.json`) is the only home of mutable run state —
  `interventions[]`, stage transitions, `outcome`, `pr`. An envelope carries
  only the immutable identity (`run_id`, `initiated_by`), so two documents can
  never disagree — and receipt validation **rejects a result whose `run_id`
  is not the run the branch pointer names**, so a stale result from an
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
| `continue` | no exit predicate satisfied; cap not reached | dispatch the next round — a fix round when any disposition changes code, otherwise another reviewer pass on the unchanged head (a clean round under `min_rounds` changes nothing to fix) |
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
  adjudicated disposition **changed the code** — `fix`, `restructure`, or
  `delete` — in an earlier round. (A repeat after `decline` is the reviewer
  disagreeing, not the loop feeding on itself.)

Boundary fixtures for each — empty current round, a single round, a
denominator of zero, a repeat whose original was `decline`d — ship with the
exit script and are part of the conformance set.

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
  `integration` (formerly `shepherd`), `remediation`, `min_rounds`. Each
  rigor level points at one policy via `caps = "<policy>"`. A cap is a
  ceiling; `min_rounds` is a floor per confidence stage below which
  `converged` cannot fire. `remediation` bounds fix pushes in the integration
  stage (shipped default 4 at `standard`, scaling with the level like the
  others; its terminal action is escalation, below). There is no cap for
  checks. **A `challenge` or `review` cap of 0 disables that confidence
  stage**: no round runs and the stage advances with exit `capped`, reason
  `disabled` — the one case where capped-clean needs no current-head
  round — exactly as the migrated policy already defines it. The effective
  `min_rounds` for a stage is `min(min_rounds, cap)`, so a mixed policy
  (`challenge = 2`, `review = 0`, `min_rounds = 1`) is valid and the disabled
  stage simply owes nothing. Zero means something different for
  the integration caps, defined next: `integration = 0` waives only the
  Codex cycle, and `remediation = 0` means the first finding that needs a
  fix push escalates.
- The **integration cap bounds Codex re-review cycles only.** Answering every
  human and CI finding is unconditional; `integration = 0` means "no Codex
  cycle required" — and, exactly as AGENTS.md already states for a 0 cap, the
  readiness gate's Codex-verdict condition **drops out** under it while every
  other condition stays; this is the one readiness-gate condition v2 touches,
  and only by inheriting the existing rule — never "abandon reviews". That is
  why a policy may lower it
  (resolves [#624](https://github.com/evanharmon1/harmon-devkit/issues/624)).
  When the last permitted Codex cycle finds something that is then fixed,
  the fix push moves the head and the readiness gate would need a cycle the
  cap forbids: that is `capped` for the integration stage — the run stops,
  posts a blocker report naming the unreviewed head, and the PR stays draft
  for a human to grant a cycle or promote. The verdict is never waived.
  This **deliberately revises** [#633](https://github.com/evanharmon1/harmon-devkit/issues/633)'s
  "rigor may raise it, never lower it" criterion: that rule assumed the cap
  bounded all findings, and once it bounds only Codex cycles, lowering it
  removes nothing a human or CI raised — which is also what harmon-init's
  shipped `review.none`/`driveby` values already do.
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
  stage and integration. With more than one finder, a **logical round** is
  one result per configured finder at the same `reviewed_head`; it is
  complete only when every finder has returned, its findings are the union,
  and caps and `min_rounds` count logical rounds. Vocabulary: each finder's
  `result.reviewer` is a **pass**; the **round** is the aggregate of the
  passes at one head — one pass when one finder is configured. Payload
  cardinality: a round has one or more passes, each naming its finder. A finder that fails returns
  `blocked`; the orchestrator retries that finder **once**, and a second
  failure ends the run with exit `capped`, reason `finder_unavailable`, and
  a blocker naming the finder — never a round silently one finder short, and
  never an unbounded retry.
- `tier:<role>:*` label values are hand-added to `label-registry.json`.
- **Self-modified policy is read from the merge base.** When the change
  under review edits `.devflow.toml`, **every value read during policy
  resolution** — `default_rigor` and `default_strategy`, the rigor level's
  `caps` pointer and tier profile, `[caps]`, `[convergence]`, `[gates]`
  (`docs_only_paths` included), `[role]`, `[stage]`, `[tier]`, `[strategy]`,
  `[budget]` — is resolved from the merge-base copy; and the same rule
  covers **`agent-registry.json`** whenever it is in the diff, since it
  supplies the role write boundaries and the finders' trusted actor IDs a
  branch could otherwise widen for itself — exactly as
  AGENTS.md already requires for caps, so a branch cannot lower the gate it
  is changing or classify its code as docs-only. An explicit human
  instruction still overrides.
- **The legacy shape is refused** with a migration hint
  ([#604](https://github.com/evanharmon1/harmon-devkit/issues/604)). No skill
  or script carries both shapes.

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
  is reported as tampered evidence, never silently replayed. The run record
  comment is subject to the **same author check**, so a stranger cannot
  forge a record that vouches for their own evidence; an orchestrator that
  rewrites its own record is outside the threat model — it could equally have
  lied in the first place, and the reviewer's raw output on the same comments
  is what the retro compares against.

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
- [ ] Round evidence survives PR open and is harvestable with `gh api`; the evidence protocol ships regression fixtures for: interruption after the post but before the id is recorded (marker adoption, no duplicate); a forged-author comment; an edited payload (digest mismatch → tampered); a secret in finding text (post refused); a stage split across comments (reassembled); a run capped before any PR (stage evidence and run record found on the issue).
- [ ] `dev-flow-stats.sh` prints the success metric and replays policies.
- [ ] AGENTS.md's Dev Loop is the stage table, the constitution rules, and references.
- [ ] Foreman accepts envelope v2, reads `.devflow.toml`, writes run records, and requires round artifacts whose recomputed exit is a terminal clean outcome — `converged`, capped-clean, or `capped`/`disabled` — for each confidence stage.

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

- None at draft time; the grill session of 2026-08-28 settled the design.
  Findings from the challenge round go here until adjudicated.

## Notes

Provenance: grill-with-docs session, 2026-08-28/29, against the retro of
ponderousdev/omator#397. The constitution's rule 1 (never merge without
per-merge approval) is why `merge` is a human stage and why no exit outcome
can promote past ready-for-review.
