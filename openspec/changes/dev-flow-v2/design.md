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

The round-push broker and the secret scanner live at stable repository-owned
script paths (`scripts/round-push.sh`; `scripts/gitleaks-scan.sh` with its
`.gitleaks.toml`, which the `security:secrets` target already wraps) rather
than inside a skill's assets: the merge-base rule materializes them with
`git show <merge-base>:<path>`, which needs a path that survives skill renames,
and stage skills reference the broker by path instead of vendoring a copy that
would drift. Keeping the broker as a skill asset was rejected because #638
renames the skill that carried it and the merge-base extraction would then
point at a path that no longer exists.

The trusted unit is the broker's closure, not its entrypoint. Because the
broker consumes the policy reader and the secret scan consumes the
scanner's configuration, a branch that edits only one of those transitive
files would otherwise steer a merge-base entrypoint from the worktree. The
merge-base materialization therefore covers the control plane: the broker,
the policy reader, the secret scanner and its configuration, and their
control and configuration dependencies, extracted together into one tree
outside the worktree, with the extracted broker taking its policy, registry,
and scan inputs as explicit paths into that tree rather than resolving
anything relative to the worktree. The configured round gate (`task verify`
or `task check`) is deliberately outside that closure: the merge-base broker
decides which gate is required and whether the marker is valid, then runs
that gate from the feature worktree, because a branch that changes a gate
script must exercise its own version and that result is branch-attested
rather than authoritative. Extracting only the two entrypoints was rejected
because it left the policy reader and scanner config branch-controlled;
sweeping the round gate into the closure was rejected because it would
contradict the branch-attested rule.

One bootstrap exception is explicit and tested: the change that first creates
`scripts/round-push.sh` (task 2.2) has no merge-base copy at that path, so
for that relocation change only, the merge-base broker is the skill asset it
relocates (`ai/skills/universal/gauntlet/assets/push-round.sh`), materialized
the same way. Every later change extracts the stable path; a merge base that
has neither copy refuses the push rather than trusting the branch broker,
mirroring the reader-before-policy rule in decision 13.

Merge-base resolution protects the policy that selects target slugs,
allowlists, and thresholds; it does not attest the feature branch's Taskfile
recipes, scripts, or push-broker implementation. Evidence produced by those
local implementations is branch-attested. Readiness therefore combines the
merge-base-resolved policy with concluded required CI checks on the PR and
never substitutes a local marker for a required check conclusion.

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

The challenger result schema ships with the registry roles rather than with the
stage skills: a registry role names its result schema, and the exit script
validates challenger passes before any `/review` skill exists. Shipping it with
the skills would leave the registry naming a schema that does not exist and the
exit script validating against a placeholder.

### 6. Model strata and executable inventory live in the registry

Concrete models, their family and tier, defaults within a family-tier pair,
harness support, role support, finder surface, invocation, and trusted actor ID
belong in `agent-registry.json`. `.devflow.toml` retains only `tier_order` and
role/profile choices. Escalation moves one rung while retaining family; family
fallback is a separate horizontal choice.

A family-tier rung with several models requires exactly one explicit default;
a singleton rung is unambiguous without a flag. Execution-control labels remain
advisory: interactive off-default choices require attributable operator
confirmation, while unattended consumers re-read trusted-actor configuration
immediately before acting and otherwise fall back to defaults with a warning.

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
monitor persists terminal-event identities and reserves durable intent before
an external merge, push, or comment. It advances its cursor only after
reconciling the expected external postcondition. Re-arming adopts a landed
action, re-executes only one proven absent, and blocks on an indeterminate
postcondition, so interruption cannot turn a reservation into either a skipped
or duplicated write.

Unbounded fan-out was rejected. Parallelism is safe only when ownership,
overlap, concurrency, and invalidation costs are explicit. Product, scope, and
safety questions still stop for humans; lane scheduling and merge-order advice
belong to the orchestrator and are disclosed.

### 8. Results use envelopes plus separate mutable and immutable records

Every role result uses one versioned envelope with producer, run, status, and
head identity around a role payload. Raw passes and adjudications are immutable.
`run.json` grows through digest-chained, append-only transitions, interventions,
terminal outcomes, and deferred-finding settlements rather than editing prior
history or the evidence comments those entries settle.

Receipt validation joins the active run pointer, envelope, payload, prior IDs,
adjudications, policy, and history before interpretation. This prevents stale
retries, head disagreement, duplicate finding IDs, incomplete multi-finder
rounds, cap-inconsistent trajectories, results predating their stage, out-of-
order transitions, and reuse of an earlier-stage pass at the same head.

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
head and draft PR, and merge only marked generated sections into the latest
body without changing the non-generated content in that read. GitHub has no
conditional PR-body write, so the remaining read-modify-write race is documented
rather than disguised as compare-and-swap. The writer re-reads and fingerprints
the body after every write, repairs mismatches from a fresh read within a bounded
retry limit, blocks on exhaustion, and retires local transfer records only after
the remote postcondition is proven.

### 11. Evidence starts at kickoff and is authenticated at read time

Run identity and its comment reservation are created on the issue before a
branch exists. Local working state lives in the common git directory by run ID;
the branch stores only a pointer. Every adjudicated round is posted promptly to
the issue. PR stage projections link those round comments, and failed no-PR
runs leave the same evidence on the issue.

Writes are reserve-first and secret-scanned. A detected secret produces a
stable redacted public projection while preserving unredacted local evidence.
Run records store immutable actor IDs and SHA-256 digests; their historical
entries extend a sequence-and-digest chain. Harvesters reject edited, deleted,
forged, or incomplete evidence, and `--as-of` reconstructs only validated entries
at or before its cutoff instead of trusting a latest-body summary.

This supports a closed-cohort success metric, immutable `--as-of` scoring,
per-run inspection, convergence replay, and retros that start from retained
facts rather than conversation memory.

### 13. One policy reader serves every DevKit consumer

DevKit ships a single v2 policy reader that every script and stage skill uses
to load `.devflow.toml`: it detects the shape from its controlling markers,
refuses legacy and v1 shapes with a migration message, resolves rigor into
rounds, breadth, gates, convergence, role, and stage values, and applies the
merge-base rule when the change under review edits the policy, the registry,
or any file in the reader's own trusted closure (the reader, its defaults,
the historical decoder).
The exit script is its first consumer and carries it; the push broker,
integrator, and stage skills consume it rather than parsing TOML themselves.

Refusal applies to the policy a consumer operates under, never to a
merge-base copy. The anchor requires a historical merge-base policy to be
interpreted under its own declared schema (v1 by v1 rules, legacy by legacy
rules), which is what lets a v1-to-v2 migration branch resolve the gates,
caps, and floor it is protected by. The reader therefore carries one
bounded historical decoder used only on the merge-base path when the change
under review migrates the policy shape: it reads the legacy `[rigor.<level>]`
caps (`shepherd` decoded as `integration = N`, `remediation = N`, and a
decoder-only shared-budget marker under which the integration stage charges
one legacy round per fix push or per no-change cycle, never a finding cycle
and its answering push separately, because that is how the legacy cap
counted; `min_rounds` as the floor)
or the v1 `[review.*]` policy the rigor pointer names (whose `shepherd` cap
receives the same shared-budget marker, since it counted the same way), maps
them onto the v2 `rounds` values, decodes every other value the older shape
does declare under that shape's own rules (v1 `[budget.*]` onto `breadth`,
v1 per-role tiers on the rigor profile, v1 `default_strategy` and
`[strategy.*]`; legacy `default_tier` and `default_method`), and supplies the
built-in gate defaults (`verify`, `check`, `security:secrets`, `security`
with the shipped `docs_only_paths`) because neither older shape declares
`[gates]`. That decoder is not an operating-mode
fallback: an active v1 or legacy file is still refused, and the decoder is
exercised only from the merge-base resolution path with fixtures for both
migrations. Keeping the two paths distinct is what reconciles "no fallback
interpreter" with the anchor's merge-base rule.

The decoder's scope is an invariant rather than a field list: on a
migration branch, every value the merge-base rule protects (defaults,
rounds, breadth, convergence, gates, roles, stages, strategy, registry
mappings, trusted actors) resolves either from the older copy's own
effective semantics or from the consumer's built-in defaults, and never from
the branch copy. Registry-owned values (finders, roles, write boundaries,
trusted actor IDs, model tiers) come from the merge-base
`agent-registry.json`, which exists independently of the policy shape. The
built-in default is admissible only for a value absent from both the older
policy copy and the merge-base registry (legacy breadth, and convergence
predicates under either older shape), because a built-in cannot be edited by
the branch. Built-in defaults are part of the reader, and the reader is
part of the gate's trusted closure (decision 3), so the self-modification
boundary covers it: a change that edits the reader, its defaults, or the
decoder resolves policy by executing the merge-base reader from the
materialized closure, never the worktree copy. The fixture for each
migration asserts the invariant by mutating every protected value in the
branch policy copy and in the branch reader's defaults, and proving the
resolved policy is unchanged.

Its tests evaluate fixture policies only. DevKit's own `.devflow.toml` is a
rendered Harmon Init artifact and stays on its current shape until the copier
update lands, so no verify-gate target may run a v2 consumer against the live
file: doing so would make the repository's own gate fail by design until the
sibling milestone ships. Per-script TOML parsing was rejected because shape
refusal and resolution would drift between consumers, defeating the
determinism the milestone exists for.

Sequencing follows from that boundary: the reader must exist at the merge
base before a policy migration can be reviewed, so the reader lands in its
own change (for DevKit, task 2.3; for generated repositories, the skills
sync) and the policy migration is a later change. A migration whose merge
base has no reader is refused rather than bootstrapped from the branch,
because a branch-supplied reader is exactly what the boundary excludes. A
pinned external bootstrap copy was rejected as a second trust root that
would need its own provenance rules.

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
   write boundaries, and ship the challenger result schema; publish versioned
   conformance fixtures. In parallel, implement the policy reader, trajectory
   receipt and exit computation, and deterministic rendering against fixture
   policies, then the repository-owned diff-aware round-push broker.
3. Ship Harmon Init's v2 config template, schema, gate-slug validation, label
   vocabulary, and generated-repository migration, using the registry tiers
   and the pinned predicate names from step 2.
4. (Merged into step 2.)
5. Publish the role-scoped reviewer/challenger, orchestrator, and integrator
   successor skills as v2-only from their first release; add evidence posting,
   harvesting, metrics, and retro consumption.
6. Update Foreman to accept envelope v2 and recompute terminal exits from the
   same fixtures and policy.
7. Keep each unmigrated consumer pinned to the last pre-v2 skill release; after
   its `.devflow.toml` migrates, advance its skills-sync pin to the v2-only
   release and validate the rendered repository.

Rollback is versioned rather than interpretive: consumers that have not
migrated remain on their pinned v1 assets. A v2 consumer encountering v1 stops
with a migration message; it never silently falls back. No migration step
rewrites pushed history, promotes a draft, merges, or releases automatically.
