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

The reference reader is `scripts/devflow-policy.mjs`. It parses TOML, accepts
an already-authorized rigor/strategy request, resolves the selected profile,
and cross-validates registry and Taskfile references. It deliberately does not
authenticate GitHub actors, read labels, reconcile label conflicts, or arm a
workflow; those are consumer trust boundaries. A consumer applies the
precedence below and passes the resulting rigor/strategy request to the reader.
Role-tier overrides remain consumer inputs applied to the resolved five-role
profile, not raw label parsing performed by this config reader.
`scripts/test-devflow-config.sh` checks both dogfood copies and exercises the
reader. Generated repositories receive the declarative policy and schema; the
reader is distributed separately at a pinned harmon-devkit release.

## Resolution

Resolve rigor and strategy in this order:

1. explicit, attributable operator instruction;
2. trusted `rigor:*` or `strategy:*` issue labels;
3. `default_rigor` or `default_strategy`;
4. the reader's built-in fallback, only if the policy file is absent.

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
reader. An unqualified `tier:<value>` override targets the implementer. A
scoped `tier:<role>:<value>` override targets exactly one of the five roles.
Every off-profile role choice is visible in the PR body.

## Rounds and convergence

The selected `[rounds.*]` table supplies separate ceilings for:

- `challenge`: adversarial confidence passes;
- `review`: verification confidence passes;
- `integration`: current-head cloud-review cycles;
- `remediation`: integration-stage fix pushes.

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
envelopes. `scripts/validate-result-schemas.mjs` provides the receipt and
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
