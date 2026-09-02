## Why

The current Dev Loop leaves convergence, finding disposition, and evidence
handoff to the orchestrating session's judgment and memory, producing expensive
self-reinforcing review loops that cannot be replayed or measured. Dev flow v2
makes every exit a deterministic computation over schema-validated role results
and durable evidence, while preserving the session as the sole orchestrator and
human control over merge.

## What Changes

- **BREAKING** Replace legacy and v1 `.devflow.toml` policy shapes with
  `schema_version = 2`: separate vertical `[rounds.*]`, horizontal
  `[breadth.*]`, optional `[spend.*]`, Taskfile-backed `[gates]`,
  `[convergence]`, per-role preferences, stage actor declarations, and the
  `cursory` through `forensic` rigor ladder. An active older shape is refused
  with a migration hint rather than interpreted; the one exception is the
  merge-base copy of a change that migrates the policy, which is decoded
  under its own shape so the migration run keeps the budget it is protected
  by.
- **BREAKING** Move model-tier inventory out of `.devflow.toml` and into
  `agent-registry.json`; add explicit orchestrator, implementer, challenger,
  reviewer, and integrator roles plus finder and harness contracts.
- Introduce schema-bound result envelopes, adjudication and run records,
  receipt validation, and conformance fixtures shared with Foreman.
- Compute confidence-stage outcomes (`continue`, `converged`, `diverging`, or
  `capped`) from validated passes, adjudications, current-head ancestry, and
  resolved policy; verify provenance and repeat claims rather than trusting
  reviewer assertions.
- Render deferred findings, adjudication tables, budget disclosures, thread
  reply plans, and blocker reports deterministically from the validated record.
- **BREAKING** Retire `gauntlet` and `shepherd` as workflow names. Stage skills
  become `/review` and `/integrate`, with `/orchestrator` as a standing mode;
  challenger and reviewer are distinct roles, and parallel implementers are
  supported through stage pools, strategies, and breadth ceilings.
- Persist reserve-first, secret-scanned, authenticated run and round evidence
  on issues and PRs so failed runs remain measurable; add trajectory replay,
  success metrics, and run-record-driven retrospectives.

## Capabilities

### New Capabilities

- `config`: Versioned Dev flow v2 execution policy, validation, policy
  resolution, gate slugs, and the rounds/breadth/spend separation.
- `registry`: Role, finder, harness, family, and model-tier inventory with
  enforced write boundaries and cross-file references.
- `exit-computation`: Deterministic receipt validation, provenance checking,
  and confidence-stage outcome computation.
- `renderer`: Byte-stable human and machine projections from adjudication and
  result records.
- `stage-skills`: Orchestrator, challenge/review, integration, and implementer
  dispatch behavior, including scoped tools and parallel implementation.
- `evidence`: Durable run/round posting, authentication, harvesting, metrics,
  replay, and retrospective consumption.

### Modified Capabilities

None. The repository has no existing OpenSpec capability specs; the root
`specs/dev-flow-v2.md` document is source material for these new contracts.

## Impact

- Harmon DevKit surfaces: `agent-registry.json` and its schema, `ai/schemas/`
  and fixtures, `ai/agents/`, `ai/skills/universal/`, `scripts/`, Taskfile
  targets, lifecycle docs, the anchor spec, and the retro skill.
- Harmon Init owns the rendered `.devflow.toml` v2 template, schema,
  conformance corpus, label vocabulary, and generated-repository migration.
- Foreman consumes the shared envelopes, policy, run records, and fixtures in
  its own implementation; it does not wrap DevKit stage skills.
- Existing consumers must migrate before v2-only skills run. No stage or label
  arms execution by itself, and merge remains an explicit human action.
