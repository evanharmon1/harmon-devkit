# Dev flow v2 result schemas

The JSON Schema family every [dev-flow-v2](../../specs/dev-flow-v2.md) agent
result must satisfy, plus the conformance fixture corpus Foreman's Python
tests against at a pinned tag ([foreman#182](https://github.com/ponderousdev/foreman/issues/182)).
Filenames and field names are a contract on merge — [#635](https://github.com/evanharmon1/harmon-devkit/issues/635)–[#639](https://github.com/evanharmon1/harmon-devkit/issues/639)
reference them.

## The six schemas

| File | Validates | Authored by |
|---|---|---|
| `result.envelope.schema.json` | The common envelope every agent result returns: `schema`, `role`, `status`, `head`, `produced_at`, `producer`, `run`, `payload`. | An agent (implementer/reviewer/integrator role) |
| `result.implementer.schema.json` | The shape of `payload` when `role: implementer`. Backward-compatible with Foreman v1's flat `result.json`. | implementer |
| `result.reviewer.schema.json` | The shape of `payload` when `role: reviewer` — one **pass** (one finder's contribution to a round). | reviewer |
| `result.integrator.schema.json` | The shape of `payload` when `role: integrator` (formerly `result.shepherd`). | integrator |
| `adjudication.schema.json` | The orchestrator's overlay on one round's findings, keyed by finding id. **Standalone** — not wrapped in the envelope. | orchestrator |
| `run.schema.json` | The run record: the only home of mutable run state (stage transitions, interventions, outcome, settlements, promotion). **Standalone.** | orchestrator |

The orchestrator is not a role that returns a result (`agent-registry.json`
`roles[]` has no `orchestrator` entry — see the spec's "Roles and authority"
table), so `adjudication.schema.json` and `run.schema.json` are validated as
complete top-level documents, never as an envelope's `payload`.

## Composition: how envelope and payload fit together

`result.envelope.schema.json` declares `payload: { type: "object" }` —
deliberately untyped. The per-role shape lives in the matching
`result.<role>.schema.json`, and a **validator**, not a schema keyword,
resolves which one applies:

1. Validate the whole instance against `result.envelope.schema.json`.
2. Read `role`.
3. Validate `instance.payload` against `result.<role>.schema.json`'s own root.

This is `scripts/validate-result-schemas.mjs`'s job (`<kind> <file>`, where
`kind` is `envelope | implementer | reviewer | integrator | adjudication |
run`). It exists because [`scripts/lib/json-schema-subset.mjs`](../../scripts/lib/json-schema-subset.mjs) —
the hand-rolled JSON-Schema-subset engine this family shares with
`agent-registry.schema.json`'s validator, factored out so the ~350-line
structural engine isn't duplicated — supports only same-document `#/...`
`$ref`, never a cross-file reference. Keeping each schema file self-contained
and doing the role dispatch in the validator script is what "simple and
implementable in the subset validator" (the guiding constraint) means in
practice: no schema file needs to know another schema file exists.

### Receipt validation: what a schema file cannot check alone

A JSON Schema instance is validated against its own shape; it cannot see a
sibling field on an enclosing document, or a fact that lives outside the
instance entirely (another document in the same run, a run_id the caller
already knows is active). The spec calls this layer **receipt validation**
(§ Results) and it is deliberately a script responsibility, not a schema
keyword, for every one of these:

- **Head agreement** — a reviewer payload's `reviewed_head`, and an
  integrator payload's `codex_cycle.head` / `codex_cycle.accepted.reviewed_commit`,
  must equal the enclosing envelope's `head`. The payload schema validates
  `payload` alone and has no visibility into the envelope; only the script,
  which has both, can compare them.
- **Run matching** — the envelope's `run` must match the run the caller
  considers active (`--run-id`/`--initiated-by`), which is external context
  no single document carries.
- **Duplicate finding ids across passes** — a finding id must be unique
  *within the run*, not just within one pass's `findings[]` array (unique
  *within one pass* **is** structurally checkable and is — see below). Ids
  from earlier passes are run context (`--known-ids`), not part of the
  instance being validated.
- **Finding id / pass metadata agreement** — a finding id's embedded
  `stage`/`round`/`finder` segments must match the pass's own `stage`,
  `round`, and `finder` fields. This is actually a same-document check (the
  id and the pass metadata are both in `payload`), and the validator
  performs it unconditionally, not only when a run context is supplied.
- **Adjudication override required when priorities differ** — each
  `adjudications[]` entry carries its own `reviewer_priority` (a copy of the
  finding's reviewer-asserted priority — see "Why `reviewer_priority` is
  duplicated" below) alongside `adjudicated_priority`; the two are sibling
  values in one entry, but JSON Schema's `if`/`then` can only assert a
  property's own value against a fixed schema (`const`, `enum`, pattern), it
  cannot express "these two properties disagree" as a structural condition
  the way it can express "this property equals X" — there is no `notEqual`
  or field-to-field comparison keyword in JSON Schema at all, so this is a
  semantic check regardless of schema richness.

Two structurally-adjacent checks are worth naming because they are **not**
receipt validation, precisely because both values already live in the one
instance being validated:

- **Duplicate finding id within one pass** — `findings[]` is one array in
  one payload instance; the check is a same-document scan, always run.
- **`counts` vs. actual findings tally** — the validator additionally
  cross-checks each pass's declared `counts.P0..P3` against the true
  per-priority count in that same pass's `findings[]`, catching a pass whose
  bookkeeping and content disagree.

### Why `status`-conditional requirements are a semantic check, not `if`/`then`

`result.implementer.schema.json`'s `summary`/`handoff`/`ac_test_map` are
required only when `status: completed`; `blocked_question` only when
`status: blocked`. The deciding field, `status`, lives on the **envelope**;
the conditioned fields live in **`payload`** — two different instances from
a schema's point of view (`result.implementer.schema.json` validates only
`payload`). `if`/`then` composes conditions *within one instance*; it cannot
reach a sibling field outside it. Duplicating `status` into the payload just
to make the condition local was considered and rejected — it would need its
own "envelope.status must equal payload.status" semantic check to keep the
copy honest, trading one semantic check for another plus a redundant field.
`scripts/validate-result-schemas.mjs`'s `checkImplementerStatus` reads the
envelope and payload together instead.

`result.integrator.schema.json`'s conditional (`applied_dispositions`
required iff `verdict: clean`) **is** expressed as `if`/`then` in the schema
file itself, because both `verdict` and `applied_dispositions` are sibling
properties of the same `payload` instance — no cross-document reach needed.
This is the shipped example of `scripts/lib/json-schema-subset.mjs`'s
`if`/`then`/`else` support (added for this family; `agent-registry.schema.json`
never needed it).

## Field-shape decisions worth knowing

- **`line` is nullable, not omittable.** A finding not anchored to one line
  (a design-level or repo-wide observation) sets `line: null`; the key is
  always required. An explicit typed `null` was chosen over a sentinel
  integer (`0` or `-1`) or letting the key be absent, so "not line-bound" is
  one unambiguous value a consumer cannot forget to check for.
- **`counts` is required, all four priorities always present** (`P0`..`P3`,
  `0` is a valid count), even for a pass with zero findings — a finder that
  failed and returns `status: blocked` still validates against the same
  `result.reviewer.schema.json` shape with `findings: []` and every count
  `0`; there is no separate "blocked reviewer" shape, because every
  `result.reviewer` field is something the orchestrator told the finder to
  use (`stage`/`round`/`reviewed_head`/`finder`), never something the finder
  computes from its own success.
- **`status` enum is `completed | blocked`, and only those two**, matching
  Foreman v1's `RESULT_STATUSES` exactly (`src/foreman/backend.py` at
  `v2.5.0`) — the spec names no third value for any role; a finder that
  fails also reports `blocked` (§ Configuration `[stage.*].finders`), so no
  new value is needed there either.
- **`adjudication.schema.json` is one document per round**, not one per run:
  `{schema, run_id, stage, round, reviewed_head, adjudications[]}`. This
  matches how evidence is posted — [decision 0002](../../docs/decisions/0002-round-evidence-lives-on-the-pr.md):
  "one comment per round, the moment the round is adjudicated" — so a run's
  full adjudicated view is the union of every round's document. A finding
  still has exactly one adjudication because a finding id names exactly one
  round.
- **Why `reviewer_priority` is duplicated inside each adjudication entry.**
  The spec keeps the raw reviewer output around specifically so
  "reviewer-vs-orchestrator disagreement can be measured" (§ Results); a copy
  living in the adjudication entry itself makes that comparison — and the
  override-required check above — computable from the adjudication document
  alone, without also loading the pass that produced the finding.
- **`adjudications[]` and `settlements[]` are arrays of tagged objects, not
  a JSON object keyed by finding id**, even though the spec's prose says
  "keyed by finding id." `scripts/lib/json-schema-subset.mjs` has no
  `patternProperties` and no schema-valued `additionalProperties` (only
  `boolean`, matching `agent-registry.schema.json`'s existing convention), so
  a dynamically-keyed map cannot be validated at all in this subset. An array
  where each entry carries its own `finding_id`/`id` is the same shape
  already used for `findings[]`, `checks[]`, and `ac_test_map[]` throughout
  this family; uniqueness of the key is a validator check
  (`checkAdjudicationEntries`, `checkSettlements`), exactly like the
  duplicate-finding-id checks above.
- **Settlements live in `run.schema.json`, not `adjudication.schema.json`.**
  The spec is explicit that "the run record is the only home of mutable run
  state" (§ Results) and that a settlement is "appended, never edited in" —
  an adjudication, once authored, never changes (a `defer` disposition stays
  `defer` forever in its own document; the settlement that later resolves it
  to `fix | decline | file` is a new entry in the run record instead, so
  neither document is edited to reflect the other).
- **`interventions[].kind` is `asked | other`.** The spec's own success
  metric draws exactly this one distinction — "any human action... except
  answering an implementer's `blocked_question`, counted separately as
  asked" — so the schema states only the two categories that distinction
  needs; finer human-action taxonomy, if ever wanted, belongs to
  `dev-flow-stats.sh` ([#663](https://github.com/evanharmon1/harmon-devkit/issues/663)), not this contract.
- **Every `*_at` timestamp** (`produced_at`, `started_at`, `entered_at`,
  `settled_at`, `promoted_at`, evidence `marker` timestamps) uses the same
  pattern: `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$`
  — UTC only, literal trailing `Z`, no other offset accepted, matching the
  spec's own examples.
- **`producer.tier`** excludes `adaptive`: that value is a `.devflow.toml`
  resolution *input*, never a fact about a run that already executed.

## Fixture layout

```text
ai/schemas/fixtures/
  result.envelope.schema/{valid,invalid}/*.json
  result.implementer.schema/{valid,invalid}/*.json
  result.reviewer.schema/{valid,invalid}/*.json
  result.integrator.schema/{valid,invalid}/*.json
  adjudication.schema/{valid,invalid}/*.json
  run.schema/{valid,invalid}/*.json
```

Each directory name is the schema's own basename (`result.envelope.schema`,
not `result.envelope`) so it reads as "fixtures for
`result.envelope.schema.json`" without a lossy rename. Every `invalid/*.json`
fixture has a sibling `invalid/*.reason` — a one-line plain-text file naming
a substring the validator's rejection message must contain, so a test proves
the fixture is rejected **for the documented reason**, not merely rejected.
Two fixtures additionally need a same-named sidecar because the invariant
they exercise needs context no single document carries (see "Receipt
validation" above): `result.reviewer.schema/invalid/duplicate-id-across-passes.json`
ships a `.known-ids.json` sidecar (a JSON array, passed as the validator's
`--known-ids`), and the run-mismatch case
(`result.envelope.schema/invalid/run-mismatch.json`) is exercised with a
hardcoded `--run-id`/`--initiated-by` pair in `scripts/test-result-schemas.sh`
rather than a sidecar, since those are two plain strings, not a document.

`ai/schemas/fixtures/result.reviewer.schema/valid/omator-397-*.json` and
`ai/schemas/fixtures/adjudication.schema/valid/omator-397-*-adjudication.json`
reconstruct the [ponderousdev/omator#397](https://github.com/ponderousdev/omator/pull/397)
trajectory the spec's Problem/Why section and Convergence model cite: 4
challenge rounds (17, 14, 10, 9 findings) + 3 review rounds (9, 4, 4 findings),
67 findings total, matching the PR's own count. `provenance` is populated
richly from the ledger's "about rN fix" annotations (challenge round 2 has
9 of its 14 findings at `round:1`, the spec's own cited statistic); every
`fingerprint` in the reconstruction is `new`, because the ledger's "about rN
fix" annotations map to *provenance* (which round's fix a finding is about)
and *disposition* (what happened to it), never to a `repeat-of`/`supersedes`
relationship to an earlier, still-open finding — the omator#397 story is
fixes introducing fresh defects, not the same defect surviving unfixed, and
a reconstruction is not the place to invent a relationship the source
material doesn't contain. `result.reviewer.schema/valid/synthetic-repeat-*.json`
is a small, clearly-synthetic two-round trajectory instead, built to exercise
`repeat-of`/`supersedes` and the `repeat_after_fix` convergence predicate's
precondition (a repeat whose original disposition changed code), since the
real trajectory has no genuine instance of it. Heads across every trajectory
fixture are synthesized 40-hex values with no relationship to any real
commit; `finder` is `codex-cli` throughout, matching the ledger.

## Running the validator

```sh
node scripts/validate-result-schemas.mjs <envelope|implementer|reviewer|integrator|adjudication|run> <file> \
  [--known-ids <ids.json>] [--run-id <id> --initiated-by <human|foreman>]
```

Exit 0 and a one-line summary when valid; exit 1 and every violation (one per
line) otherwise. `scripts/test-result-schemas.sh` (wired into `task
test:result-schemas`, run from `task verify`) runs the whole fixture corpus
through this validator, the two run-context regression cases above, and a
coverage check that every `required` field and every `enum` declared
anywhere in each schema has at least one invalid fixture exercising it.

## The Foreman conformance contract

harmon-devkit is the single source of truth for this schema family, vendored
into Foreman's own repository at a pinned tag exactly like
`agent-registry.json` and the shared skills/agents
([foreman#182](https://github.com/ponderousdev/foreman/issues/182)). Foreman
tests its own Python re-implementation of this validation against the exact
fixture files here — same directory layout, same valid/invalid split, same
`.reason` expectations translated into its own test names — so "Foreman and
a session agree" (the spec's own acceptance scenario) means both validators
accept every `valid/` fixture and reject every `invalid/` fixture, at the
same pinned ref, without either implementation reading the other's source.

## The id / head / run invariants, in one place

- A finding id is `<stage>-r<round>-<finder>-<n>`
  (`^(challenge|review)-r[1-9][0-9]*-[a-z0-9-]+-[1-9][0-9]*$`), unique within
  the run by construction, and its stage/round/finder segments must match
  the pass that returned it.
- Every head-shaped field in a payload (`reviewed_head`, `codex_cycle.head`,
  `codex_cycle.accepted.reviewed_commit`) must equal the enclosing envelope's
  `head`.
- An envelope's `run` (`run_id` + `initiated_by`) must match the run the
  caller considers active; nothing in `run` is ever mutated after the fact.
- A finding has exactly one adjudication (one `adjudications[]` entry, in
  the round's own `adjudication.schema.json` document, ever) and at most one
  terminal settlement (`run.schema.json`'s `settlements[]`), and neither
  document is edited to reflect the other.
