# Devflow v2 execution policy

`.devflow.toml` is the portable policy vocabulary behind the Dev Loop in
`AGENTS.md`. It separates two decisions:

- **rigor** selects how much review depth, breadth, time, and model capability
  a run receives;
- **strategy** selects how the implementation work is organized.

The TOML file is the source of truth for values. This guide explains how to
read it without duplicating its tunable numbers.

## Compatibility

The shipped policy declares `schema_version = 2`. Its structural contract is
`.devflow.schema.json`; unknown top-level keys are errors. A v2 consumer must
reject v1 and unversioned input with a migration diagnostic rather than guess
at an interpretation. The frozen `.devflow-conformance-v1.json` remains a v1
compatibility artifact. `.devflow-conformance-v2.json` is the corpus for v2
readers.

The reference reader is `ai/skills/universal/dev-flow-support/assets/devflow-policy.mjs` —
a **vendored skill asset**, not a repository-root script
([#974](https://github.com/evanharmon1/harmon-devkit/issues/974)): `task sync:skills`
ships `ai/skills/` and nothing from `scripts/`, so the whole dev-flow v2 runtime
lives with the skills that call it — shared parts in the `dev-flow-support`
package, single-owner parts in the owning skill's own `assets/`. In a consumer
repository the same file is `.claude/skills/dev-flow-support/assets/devflow-policy.mjs`.
It parses TOML, accepts
an already-authorized rigor/strategy request, resolves the selected profile,
and cross-validates registry and Taskfile references. It deliberately does not
authenticate GitHub actors, read labels, reconcile label conflicts, or arm a
workflow; those are consumer trust boundaries. A consumer applies the
precedence below and passes the resulting request to the reader: the rigor and
strategy, who chose the rigor (`--rigor-source operator|label`, echoed back as
`rigor.chosen_by`, which is null when no rigor is passed), role-tier
overrides already split into operator instructions (`--tier-overrides`) and
authorized `tier:<role>:*` labels (`--tier-labels`), the issue's classification
and stored Tier (`--risk`, `--complexity`, `--stored-tier`), and any pin (`--pinned-tier` with
`--pin-marker-trusted` / `--pin-value-trusted`). The reader owns the order those
resolve in, not the trust decisions behind them.
`scripts/test-devflow-config.sh` checks both dogfood copies and exercises the
reader. Generated repositories receive the declarative policy and schema; the
reader is distributed separately at a pinned harmon-devkit release.

## Resolution

Resolve rigor and strategy in this order:

1. explicit, attributable operator instruction;
2. trusted `rigor:*` or `strategy:*` issue labels;
3. `default_rigor` or `default_strategy`;
4. the reader's built-in fallback when the policy file is absent, or when
   `--merge-base-policy-absent` explicitly declares an absent merge-base policy.

Use `--merge-base-policy-absent` for a branch that adds `.devflow.toml`.
It requires an existing `--policy` file and cannot be combined with
`--merge-base-policy`. The candidate is validated independently; built-in
values govern the run. An empty `--merge-base-policy ""` is a usage error
(exit 2), never permission for the branch policy to govern. Invalid flag
combinations (including `--rigor-source` without `--rigor`) or malformed operator `--tier-overrides` /
`--rigor-source` values exit with usage status 2. Successful resolution exits
0; invalid policy exits 1. Exit 3 means resolved but indeterminate:
cross-validation could not finish (no registry was supplied, or no gate-target
list from `--task-targets` / `--taskfile-dir`), or the derived Tier could not
be computed where it decides the implementer tier.

With no policy file and no requested registry, the built-in fallback is
determinate: resolution exits 0 with no registry indeterminate, provided
the other cross-validation checks complete. A present policy without a
supplied registry still exits 3. An explicitly requested registry file
that cannot be read (`--registry <missing>`) still exits 2. Merge-base
governance is unchanged: `--merge-base-policy-absent` without a governing
`--merge-base-registry` still exits 3.

The **implementer** tier has two more rungs (ADR 2026-09-30 D5). Strongest
first:

1. an operator tier instruction;
2. the pinned Tier;
3. a `tier:implementer:*` label, or the profile of a rigor the operator or a
   `rigor:*` label chose;
4. the derived Tier (see "Issue Tier" below);
5. the `default_rigor` profile.

A tier input refines whatever profile resolved, so an operator *rigor*
instruction selects the profile and a pin still sets its implementer tier; an
operator who means to displace a pin gives a tier instruction. Pass a rigor to
the reader only when the operator or a `rigor:*` label chose it — a rigor that
is merely the default does not outrank the derived Tier. The other four roles
resolve operator tier > label tier > profile.

Rigor conflicts resolve to the strongest known label using `rigor_order`.
Strategy conflicts are ambiguous: interactive runs ask, while unattended
automation warns and uses `default_strategy`. Unknown label values are
ignored. Labels are advisory and arm nothing; Foreman's trusted-actor and
arming policy remains in `.foreman.toml`.

When a change edits `.devflow.toml`, `agent-registry.json`, or the policy
reader, every governing value and the reader itself comes from the merge-base
copies. Branch-controlled policy cannot lower its own review. An explicit
operator instruction may still override that result and must be disclosed.
The trusted broker materializes and invokes that merge-base reader directly;
an option interpreted by the branch reader would run too late, after the
branch-controlled module and its imports had already loaded.

## Rigor profiles

Each `[rigor.<level>]` profile points to:

- one `[rounds.*]` policy;
- one `[breadth.*]` envelope;
- concrete tiers for orchestrator, implementer, challenger, reviewer, and
  integrator;
- whether tier escalation is permitted.

`rigor_order` is the only ranking of rigor names. The five `*_tier` fields use
`tier_order`; role floors and other cross-field invariants are enforced by the
reader. Only an unqualified operator tier instruction targets the implementer;
`tier:<role>:<value>` targets exactly one role. An unqualified `tier:<value>`
label is not a role override — it is the issue's stored Tier (a cache of the
derived Tier, or, with `tier:pinned`, the pinned Tier). Every off-profile role
choice is visible in the PR body.

## Rounds and convergence

The selected `[rounds.*]` table supplies separate ceilings for:

- `challenge`: adversarial confidence passes;
- `review`: verification confidence passes;
- `integration`: current-head cloud-review cycles;
- `remediation`: integration-stage fix pushes.

Only a cycle that reviews something new is charged against `integration`. A
cycle whose head differs from the last reviewed head **only** by a base merge
that changed nothing under review re-reads identical code by construction, so
it is exempt: it runs, and it spends a separate ceiling of the same size —
which the reader exposes as `integration_exempt` — rather than `integration`.
Exempt is not free, and the separate ceiling is why: otherwise a busy base
branch could spend a whole run on re-reviews of code nobody changed. A merge
that resolves a conflict, or that touches any file the change under review
touches, is ordinary work and charges normally. The ceiling is derived, never
authored. On the operating path it equals `integration` — including at 0, where
cloud review is off and there is no cycle of either kind to run. The one
exception is a **historical merge-base decode**: a legacy or v1 policy spends
integration and remediation from a single shared total and knows no exemption,
so the ceiling resolves to 0 there even where `integration` is positive.
Granting exempt cycles on that path would hand a branch budget its merge-base
policy never allowed. A run's ledger names which
counter each cycle spent, so `round n/cap` stays honest.

The reader defines the two ceilings; the integration stage spends them. The
exemption therefore takes effect only once that stage's implementation
accounts for it — until then its single cycle counter governs, no cycle is
exempt, and a cycle ordinal above `integration` is rejected by the readiness
gate as `codex-cap-mismatch`.

A PR that falls behind its base is caught up at the gate in a fixed order:
GitHub **update-branch** first (merge mode, pinned to the captured head with
`expected_head_sha`, never `--rebase`, after re-reading `baseRefName`), then
**CI** on the new head, then, where Codex cloud review is enabled and the
`integration` cap is positive, **`carry`** or the ordinary current-head cycle.
Where available, use the integrate skill's `assets/update-branch.sh` helper.
Before any further local commit, explicitly fetch the PR's head repository and
branch, fast-forward to the recorded catch-up OID, and confirm `HEAD` equals it.
A server-side catch-up authors no bytes, so it runs no local round gate or
secret scan and spends no `remediation` round; the readiness gate's CI
condition gates it. That head counts only if its parents are exactly the
captured head, then the base tip, its committer is `GitHub <noreply@github.com>`,
and its web-flow signature verifies; any other head is a newer push, which
restarts the gate.
A genuine merge refusal, or a base merge that must ship with a fix, falls back
to a local merge, which is an ordinary remediation round.
`AGENTS.md` § "Policy invariants" states the standard path and fallback.

A base catch-up merge is tried for a **carry** before the exemption. When the
change's canonical diff digest against the new base is identical to the one a
clean verdict already covered, that verdict attests the new head too: no review
runs and neither ceiling is spent, though CI still re-runs in full and the
ledger names the head as carried. The exemption covers what a carry cannot
prove. Carry takes effect only once every surface that must recognise it does —
the checker, readiness gate, integrator agent, and the `dev-flow-support`
result schemas and validator, all vendored through the skills pin at
harmon-devkit `v0.47.0` or later — and until then every head is reviewed on its
own.

It also supplies `min_rounds` and the run-wide `wall_clock_min`. A cap is a
ceiling, never a quota. Zero disables only the named heuristic activity; it
does not weaken tests, security, CI, branch protection, or human approval.

`[convergence]` is data, not prose. The composed `converged` predicate and
`diverging` predicate are evaluated from schema-bound round evidence. A rigor
profile may provide a `[rigor.<level>.convergence]` table that replaces one or
both outcomes with a full composed expression, but only where the replacement
tightens the matching catalog value. The permitted predicate names and
parameter keys are closed by the schema and reader.

## Breadth and spend

The selected `[breadth.*]` envelope bounds total agent runs and parallelism.
A strategy whose `min_agents` cannot fit is incompatible; consumers report
the incompatibility rather than substitute another topology or widen the
envelope. Council's distinct-family requirement is checked against the
configured implementation pool, the implementer role's eligible families and
tier, and the registry. Confidence passes spend the rounds envelope rather
than decrementing implementation breadth, but fail-closed validation still
requires the numeric allowance to cover each configured primary finder's one
retry so no shipped rigor begins with an impossible finder contract.

Optional `[spend.*]` tables are declarative ceilings, selected by an optional
`spend` pointer on each `[rigor.*]` profile. A missing pointer or measurement
is reported as unenforced, never represented as observed compliance. Foreman
intersects resolved policy with its own operational ceilings.

## Gates

`[gates]` maps lifecycle events to bare Taskfile target slugs. Values may not
contain spaces or slashes; consumers compose `task <target>`. `docs_only_paths`
is an allowlist used to select the documentation round gate. The policy names
the pre-PR target, but a supervisor may keep a stronger composed gate until a
marker-backed prerequisite proves earlier gates ran for the current head.

## Roles, stages, and the registry

`[role.*]` declares a baseline tier plus ordered model-family and harness
preferences for the five roles. A preference is ordered any-of: consumers use
the first configured and available entry, fall over only under the declared
policy, and disclose substitutions. An omitted harness list means no fixed
harness preference; it is not an empty allowlist.

`[stage.*]` maps stages to actors in `agent-registry.json`:

- `finders` and `finder_fallbacks` reference registry finder slugs;
- `pool` references harness slugs;
- every array is monomorphic and has the semantics documented beside it in
  `.devflow.toml`;
- `[stage.integration].review_trigger`, the one scalar, sets when the
  integration stage requests its PR-side reviews relative to CI on the head:
  `after-ci` (the value when the key is absent), `with-push`, or
  `after-ci-first`. Any other value, or the key on another stage, is refused.
  The reader reports it as `stages.integration.review_trigger` in its JSON and
  on the `stage[integration]` line of its text output. It changes timing only
  — never the readiness gate, which finders run, or the cycles the rounds
  policy requires — and its trade-off and cap note sit beside it in
  `.devflow.toml`.

The registry is authoritative for role result schemas and permitted writes,
finder surfaces and stage eligibility, harness capabilities, and each model's
tier. A configured slug that is present but ineligible for the requested
stage is an error just like an unknown slug.

## Strategy

Each `[strategy.*]` table defines topology, planning, delegation, optional
coordination/selection/synthesis behavior, minimum agents, and human gates.
Constitutional approvals such as merge, release, destructive actions, and
credential-store writes are never configurable strategy gates.

The `distinct_families` setting is meaningful for council selection: the
configured pool must be capable of supplying the requested number of distinct
families. The policy reader validates strategy shape and its compatibility
with the resolved breadth envelope.

## Result contracts

Agent results are wrapped in `ai/schemas/result.envelope.schema.json` and use
the role payload schemas. `ai/schemas/result.schema.json` is the composed
entry point. Orchestrator-owned adjudication batches and mutable run records
use `adjudication.schema.json` and `run.schema.json`; they are not agent result
envelopes. `ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs` provides the receipt and
cross-document checks JSON Schema alone cannot express.

## Consumer checklist

A v2 consumer must:

1. validate schema version and reject legacy input with a migration hint;
2. resolve from one coherent policy/registry/reader revision;
3. apply the precedence and merge-base rules above;
4. validate referenced task, role, harness, family, and finder slugs, including
   finder stage eligibility;
5. compute exits from validated evidence and the selected convergence policy;
6. disclose off-default, off-profile, fallback, and unenforced-spend outcomes;
7. leave arming, credentials, external writes, promotion, and merge to their
   separate authorization boundaries.

For the full design rationale and lifecycle model, see harmon-devkit's
`specs/dev-flow-v2.md`. For local operating mechanics, follow `AGENTS.md` and
the compatible stage skills vendored into the repository. A stage skill whose
config-shape section does not explicitly support v2 `[rounds.*]` and
`[breadth.*]` is not a v2 policy reader; `AGENTS.md` routes that case to its
fallback procedure until a compatible released skill is pinned.
