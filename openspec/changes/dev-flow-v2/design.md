## Context

See `proposal.md` for motivation and the six capability specs for normative
behavior. The current workflow combines approximately 470 lines of steering
prose with two large skills, while convergence, disposition, evidence transfer,
and long-running PR polling depend on the originating session's memory. The
repository already has partial building blocks—result schemas, fixtures,
Taskfile gates, Codex-cycle scripts, a registry, and a readiness gate—but no
versioned contract joins them.

This design reconciles three source layers in precedence order:

1. the live 2026-08-31 decision comment on `evanharmon1/harmon-init#1081` and
   its full draft `.devflow.toml`;
2. the live Dev flow v2 milestone and its thirteen open implementation issues;
3. the 2026-08-29 anchor `specs/dev-flow-v2.md` where not superseded.

The latest decision deliberately changes older anchor language: `[caps.*]`
becomes `[rounds.*]`, `[budget.*]` becomes `[breadth.*]`, the ladder becomes
`cursory` through `forensic`, challenger splits from reviewer, model-tier
tables move to the registry, and parallel implementers move into scope.

## Goals / Non-Goals

**Goals:**

- Make every confidence-stage exit and readiness input reproducible from
  schema-valid evidence and policy.
- Give interactive sessions, headless sessions, Foreman, and later harnesses
  one portable role, result, policy, and evidence contract.
- Keep authority narrow: roles return evidence, the session adjudicates, and
  humans retain merge and product/safety decisions.
- Support bounded parallel implementation and continuous orchestration without
  making lane count or a specific multiplexer part of the contract.
- Retain enough authenticated evidence to measure unattended success, replay
  policies, and run evidence-based retrospectives.

**Non-Goals:**

- Creating an orchestrator agent or moving adjudication into reviewer roles.
- Implementing Foreman's supervision loop in DevKit; Foreman consumes the
  shared contracts in its own Python.
- Adding a dedicated fixer role, new review-product integrations, or a
  harness-specific transport contract.
- Weakening the readiness gate. The existing cap-zero Codex exception remains;
  every human, CI, head, content, and thread condition still applies.
- Automating merge, release, or any other human-owned irreversible transition.

## Decisions

### 1. The session remains the orchestrator

The originating session—interactive or headless—resolves policy, dispatches
roles, writes adjudications, and owns stage transitions. An agent result is an
immutable observation, not an authority grant. Exit overrides are upward only
and recorded.

This preserves one accountable writer for mutable run state and avoids a second
agent whose result would itself need orchestration. A schema-bound brief was
rejected: downward messages contain open-ended context and decisions, while the
upward result is the stable interoperability seam.

### 2. Configuration separates rounds, breadth, and spend

`.devflow.toml` v2 separates three axes that older `[caps]` and `[budget]`
names conflated:

- `[rounds.*]` is vertical appetite: challenge, review, integration cycles,
  remediation pushes, minimum rounds, and wall-clock ceiling.
- `[breadth.*]` is horizontal scale: total agent runs and concurrency.
- `[spend.*]` is measurable cost only. It is schema-defined but omitted from
  shipped profiles until a runtime can enforce it.

The profile ladder is `cursory`, `light`, `standard`, `thorough`, `deep`, and
`forensic`, with one-to-one rounds and breadth tables. `forensic` has a
two-round floor; an all-zero custom policy remains valid even though no shipped
profile uses one.

The alternative—keep `caps` plus a miscellaneous budget—was rejected because
"no caps" reads as unlimited, wall clock and parallelism constrain different
failure modes, and an unenforceable cost ceiling must never look enforced.

### 3. Gates are Taskfile target slugs, not commands

`[gates]` stores bare existing Taskfile target names. Consumers compose
`task <target>` only after validation; the diff-aware push broker reclassifies
the merge-base diff using the sole `docs_only_paths` allowlist. Secret scanning
remains unconditional.

This lets repositories select their own gates without making config an
arbitrary command-execution surface. Duplicating an allowlist in the skill and
broker was rejected because they would drift.

### 4. Roles select; stages require

`[role.*]` carries tier baselines and ordered `families[]` and `harnesses[]`
preferences. Resolution selects the first configured family, then the first
compatible harness within that family, falling across families only when the
current family cannot be served. `[stage.*]` carries monomorphic registry-slug
arrays: all-of `finders`, ordered `finder_fallbacks`, and optional allowlist
`pool`.

Preference, all-of, allowlist, chain, and ranking semantics remain distinct and
documented for every array. Generic object entries with per-item mode fields
were rejected because they make validation and operator reading harder while
allowing mixed semantics in one array.

### 5. Challenger is distinct from reviewer

Challenge and review share a finding core but have separate role contracts.
The challenger attacks design, seeks failure scenarios, and recommends
de-scaffolding; the reviewer verifies consistency, correctness evidence, and
test coverage. `/review` drives both stages and dispatches the role appropriate
to the stage.

A single reviewer role with a mode flag was rejected because it blurs role
tiering, instructions, registry permissions, and conformance fixtures. Neither
role writes externally, fixes code, adjudicates, or decides exit.

### 6. Model strata and executable inventory live in the registry

Concrete models, their family and tier, defaults within a family-tier pair,
harness support, role support, finder surface, invocation, and trusted actor ID
belong in `agent-registry.json`. `.devflow.toml` retains only `tier_order` and
role/profile choices. Escalation moves one rung while retaining family; family
fallback is a separate horizontal choice.

The old `[tier.*]` family-to-model tables were rejected because they duplicated
registry inventory and required every new model to be edited in two files. Both
policy and registry use merge-base copies when either is self-modified.

### 7. Parallel implementers are a first-class milestone goal

The implement stage may select multiple eligible harnesses within resolved
breadth and strategy. Orchestrate uses lead-and-worker topology; council uses
independent proposals and distinct families where possible. The orchestrator
records lane ownership, paths, dependencies, environment, and run identity,
maintains a persistent event monitor, and continuously recomputes a stage-costed
merge queue from actual branch/PR files.

Each parallel lane writes only its isolated lane branch; the feature branch has
exactly one writer. The orchestrator selects lane outputs, integrates exactly
those outputs through the feature branch's single-writer path, and records an
assembly transition naming the integrated and discarded lanes plus the resulting
canonical SHA. Confidence stages review only that exact assembled head. The
monitor persists terminal-event identities and atomically records each action
receipt before advancing its cursor, so re-arming cannot replay a completed
action.

Unbounded fan-out was rejected. Parallelism is safe only when ownership,
overlap, concurrency, and invalidation costs are explicit. Product, scope, and
safety questions still stop for humans; lane scheduling and merge-order advice
belong to the orchestrator and are disclosed.

### 8. Results use envelopes plus separate mutable and immutable records

Every role result uses one versioned envelope with producer, run, status, and
head identity around a role payload. Raw passes and adjudications are immutable.
`run.json` is the only mutable trajectory record. Deferred-finding settlements
append by finding ID rather than editing the evidence comment they settle.

Receipt validation joins the active run pointer, envelope, payload, prior IDs,
adjudications, policy, and history before interpretation. This prevents stale
retries, head disagreement, duplicate finding IDs, incomplete multi-finder
rounds, and cap-inconsistent trajectories.

### 9. Exit computation is a deterministic precedence machine

The evaluator applies `capped → diverging → converged → continue` over
adjudicated P0/P1 findings. It verifies provenance and fingerprint assertions
against repository evidence, records corrections, and fails closed without
letting unverified provenance manufacture a provenance-dependent predicate.
Only current-head rounds can certify clean exit; ancestor rounds remain useful
for trajectory predicates.

Finder passes aggregate into one logical round at a shared head. Every configured
primary slot is all-of: its primary receives one retry, then its configured
`finder_fallbacks` chain is attempted in order. Each substitution is a recorded,
disclosed pass that preserves one pass for that primary slot;
`finder_unavailable` applies only after the retry and fallback chain are
exhausted. DevKit and Foreman evaluate a shared conformance corpus.

### 10. Rendering is a projection, never another source of truth

One adjudication record renders the in-session table, PR body, deferred task
list, thread-reply plan, budget disclosure, and blocker report. The renderer is
byte-stable and golden-tested. Readiness reads JSON and append-only settlements,
not human Markdown.

PR publication is a transaction: validate local sources, bind the exact pushed
head and draft PR, idempotently upsert, re-read and fingerprint, then retire
local transfer records only after the remote postcondition is proven.

### 11. Evidence starts at kickoff and is authenticated at read time

Run identity and its comment reservation are created on the issue before a
branch exists. Local working state lives in the common git directory by run ID;
the branch stores only a pointer. Every adjudicated round is posted promptly to
the issue. PR stage projections link those round comments, and failed no-PR
runs leave the same evidence on the issue.

Writes are reserve-first and secret-scanned. A detected secret produces a
stable redacted public projection while preserving unredacted local evidence.
Run records store immutable actor IDs and SHA-256 digests; harvesters reject
edited, deleted, forged, or incomplete segmented evidence.

This supports a closed-cohort success metric, immutable `--as-of` scoring,
per-run inspection, convergence replay, and retros that start from retained
facts rather than conversation memory.

### 12. Stage names, skill names, and write ownership are explicit

Lifecycle stages use nouns; invocable skills use verbs (`/implement`,
`/review`, `/integrate`). `/orchestrator` is a standing mode. Implementers own
one conventional commit and brokered push per fix round. Integrators own only
the reserve/trigger/attach/poll protocol and exact supplied thread replies. The
session owns dispositions, publication, readiness, and promotion. `gauntlet`
and `shepherd` are removed after v2 migration.

## Risks / Trade-offs

- **[Cross-repository contract drift]** DevKit, Harmon Init, and Foreman can
  update on different cadences. → Version schemas, publish fixtures, pin
  consumers, and refuse unknown/legacy shapes with actionable messages.
- **[Evidence can contain secrets]** Reviewer prose may quote credentials. →
  Scan every post projection and publish stable redactions rather than dropping
  durability or exposing the value.
- **[Public comments are mutable or forgeable]** Login names and markers alone
  are insufficient. → Authenticate immutable actor IDs, run-record references,
  sequence markers, and content digests at harvest time.
- **[Determinism can encode a bad policy]** A repeatable exit can still be too
  strict or loose. → Retain trajectories, replay candidate policies, permit
  tighten-only rigor overrides, and require explicit human edits for loosening.
- **[Parallelism multiplies conflicts and machine load]** More lanes can create
  repeated terminal-stage work. → Enforce breadth, detect overlap at dispatch,
  bound heavy-stage concurrency, persist supervision, and schedule by
  invalidation cost.
- **[No dual-shape compatibility window inside v2]** Consumers cannot upgrade
  skills before config. → Sequence releases and copier updates; v1 continues
  to run until migration, while v2 fails closed instead of guessing.
- **[GitHub comments have size and availability limits]** A large run may need
  multiple posts or experience partial outages. → Segment with deterministic
  markers, reserve before writes, retain local sources until verified, and
  treat missing segments as indeterminate.

## Migration Plan

1. Reconcile the anchor spec and decision record to the 2026-08-31 vocabulary,
   then finish single-document schema residue and fixtures.
2. Extend the registry with roles, finders, model tiers, harness support, and
   write boundaries; publish versioned conformance fixtures.
3. Ship Harmon Init's v2 config template, schema, gate-slug validation, label
   vocabulary, and generated-repository migration.
4. Implement trajectory receipt and exit computation, deterministic rendering,
   and the diff-aware round-push gate.
5. Replace gauntlet/shepherd with role-scoped reviewer/challenger, orchestrator,
   and integrator workflows; add evidence posting, harvesting, metrics, and
   retro consumption.
6. Update Foreman to accept envelope v2 and recompute terminal exits from the
   same fixtures and policy.
7. Run copier updates across consumers, validate each rendered repository, and
   only then remove every older-shape branch and enable v2-only refusal.

Rollback is versioned rather than interpretive: consumers that have not
migrated remain on their pinned v1 assets. A v2 consumer encountering v1 stops
with a migration message; it never silently falls back. No migration step
rewrites pushed history, promotes a draft, merges, or releases automatically.
