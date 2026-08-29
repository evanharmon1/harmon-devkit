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
run`). **`kind: envelope` is a convenience for "I don't already know the
role," not a payload-blind mode** — it runs steps 2 and 3 (and every receipt
check the role-named `kind` would) by reading `role` off the instance itself;
the only thing `kind: implementer/reviewer/integrator` adds on top is
asserting the caller's expectation actually matches the instance's own
`role`. A round-1 challenge-review fixture
(`result.envelope.schema/invalid/empty-payload-for-role.json`) exists
specifically because an earlier version of this validator DID skip payload
dispatch under `kind: envelope`, silently accepting an envelope with an
empty `payload` as long as its own shape was fine — the bug is now a
regression fixture, not just a comment.

It exists because [`scripts/lib/json-schema-subset.mjs`](../../scripts/lib/json-schema-subset.mjs) —
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
- **Adjudication ↔ source pass agreement (`--pass <envelope.json>`,
  repeatable)** — an adjudication document claims to adjudicate one round's
  reviewer pass(es), but nothing in its own shape proves that: the pass's
  findings are a different document, and a round can be more than one pass
  (spec § Configuration: "a logical round is one result per configured
  finder at the same `reviewed_head`"). `--pass` may be given once per
  finder in that round; the validator first checks every supplied pass
  agrees with every other on `run_id`/`stage`/`round`/`reviewed_head`
  (naming the offending `--pass` file if not), then cross-checks the
  document against the UNION of their findings: completeness (every finding
  across every pass has exactly one adjudication entry, and no entry names
  an id absent from every pass), that each entry's `reviewer_priority`
  still matches its finding's own `priority` in whichever pass returned it
  (a copy that has drifted from its source is worse than no copy), and that
  the document's own `run_id`/`stage`/`round`/`reviewed_head` agree with the
  passes'. Every supplied pass's own `payload.finder` must also be distinct
  — a round is one pass **per finder** (same spec line), so two `--pass`
  files repeating one finder are never a legitimate multi-finder round; a
  retry replaces that finder's pass, it does not join a second one at its
  side, so the repeat is rejected naming the finder. A `--pass` file whose
  own `status` is `blocked` is rejected as context too, even though it is
  a perfectly valid standalone reviewer result on its own: a blocked
  finder contributes no findings at all (the orchestrator retries it once,
  spec § Configuration), so there is nothing real to cross-check an
  adjudication against. Without `--pass` an adjudication document is still
  checked for internal self-consistency (`checkAdjudicationEntries`,
  `checkAdjudicationIdAttribution`) — it just isn't cross-checked against
  anything external.
- **Adjudication uniqueness across the run (`--known-adjudicated
  <ids.json>`)** — a finding is adjudicated in exactly one round document,
  ever (see `adjudication.schema.json`'s own `$comment` for the full
  three-part story: within-document, id-grammar, and this one). Given the
  ids an earlier round's document already adjudicated, this rejects any
  entry in the current document naming one of them — mirroring
  `--known-ids`' collision check on the reviewer side exactly, including
  failing closed (see below) rather than silently skipping when the file
  isn't shaped right.
- **Settlement ↔ adjudication agreement (`--adjudication <file.json>`,
  repeatable)** — `run.schema.json`'s `settlements[]` terminalizes a
  `defer` disposition, but nothing in the run record itself proves the
  finding it names was ever actually deferred (that fact lives in an
  adjudication document, a different document entirely — spec § Results:
  "there it is settled to `fix`, `decline`, or `file`" describes exactly
  this transition). Each supplied `--adjudication` document's own `run_id`
  must first equal the run record's `run_id` — finding ids are unique
  *within a run*, not globally, so a foreign run's document could otherwise
  settle a finding_id that only coincidentally collides with one from this
  run. With one or more `--adjudication` files, every
  settlement's `finding_id` must be adjudicated **exactly once** across the
  union of the supplied documents, with disposition `defer` — zero matches
  or more than one are both rejected (naming which documents disagree, in
  the more-than-one case), and a match whose disposition isn't `defer`
  (the finding was already resolved at adjudication time, never deferred)
  is rejected too. The converse also holds, but only once the run claims
  to be done: when `outcome` is `"ready-for-review"`, every finding the
  supplied documents deferred must have a settlement — a promoted run
  cannot leave a deferred finding unresolved (a run still short of
  ready-for-review may legitimately have deferrals still in flight,
  so this half of the check does not apply there). Without
  `--adjudication`, unchanged: settlements are still checked for an
  internal duplicate `finding_id` (`checkSettlements`), just not against
  any adjudication.
- **Evidence marker `run_id` agreement** — `run.schema.json`'s
  `evidence_comments[].marker.run_id` must equal the run record's own
  `run_id`. Unlike the checks above this one needs no external context (both
  values live in the one `run.schema.json` document), so it always runs, not
  only when extra CLI context is supplied.
- **Adjudication override required when priorities differ** — each
  `adjudications[]` entry carries its own `reviewer_priority` (a copy of the
  finding's reviewer-asserted priority — see "Why `reviewer_priority` is
  duplicated" below) alongside `adjudicated_priority`; the two are sibling
  values in one entry, but JSON Schema's `if`/`then` can only assert a
  property's own value against a fixed schema (`const`, `enum`, pattern), it
  cannot express "these two properties disagree" as a structural condition
  the way it can express "this property equals X" — there is no `notEqual`
  or field-to-field comparison keyword in JSON Schema at all, so this is a
  semantic check regardless of schema richness. The same reasoning is why
  `run.schema.json`'s `promotion` ⇔ `outcome: "ready-for-review"` check
  (below) and `settlements[].reference.type` ⇔ `disposition` check (below)
  are semantic too, even though every value either reads is a sibling field
  in the same document — the CONDITION in each case is an inequality or a
  paired-values-must-agree rule, not a fixed value a property can be
  checked against.

Two structurally-adjacent checks are worth naming because they are **not**
receipt validation, precisely because both values already live in the one
instance being validated:

- **Duplicate finding id within one pass** — `findings[]` is one array in
  one payload instance; the check is a same-document scan, always run.
- **`counts` vs. actual findings tally** — the validator additionally
  cross-checks each pass's declared `counts.P0..P3` against the true
  per-priority count in that same pass's `findings[]`, catching a pass whose
  bookkeeping and content disagree.
- **A `clean` integrator verdict is a claim about the whole payload** —
  `checkIntegratorCleanVerdict` reads `verdict` and, when it is `clean`,
  requires every sibling field to actually be clean too: `checks` is
  **non-empty** (AGENTS.md's readiness gate: an empty check list is
  indeterminate, not a pass) and every entry's `bucket` is `pass` or
  `skipping`, `unanswered_thread_roots` is empty, `codex_cycle` is `null`
  or has `exit_code: 0` with `accepted` present (never `10`/findings — a
  clean verdict cannot rest on an unresolved Codex cycle), every
  `findings[].id` has a matching `applied_dispositions[]` entry, and no
  applied disposition is `defer` (a deferred finding is carried forward,
  not clean). All same-document; the check runs unconditionally for role
  `integrator`.
- **A blocked integrator cannot report a clean verdict**
  (`checkIntegratorBlockedStatus`) — envelope `status: blocked` means the
  integrator did not complete its evidence-gathering pass, so
  `payload.verdict` can be `pending`, `escalate`, or `findings` (whatever
  it actually observed before being cut short) but never `clean`, which is
  specifically a claim of completion. Cross-field (envelope `status` vs.
  payload `verdict`), so this lives at the envelope level like
  `checkImplementerStatus`.
- **`applied_dispositions[].finding_id` is unique** — checked separately
  from, and unconditionally on, the clean-verdict rule above
  (`checkAppliedDispositionsUnique`): a duplicate is two different claims
  about the same finding's disposition, and rejecting it outright is the
  point — building a keep-last `Map` instead would silently discard
  whichever claim came first.
- **`run.schema.json`'s `promotion` ⇔ `outcome: "ready-for-review"`, both
  directions, and both additionally require a non-null `pr`** — a non-null
  `promotion` with any other outcome, or an outcome of
  `"ready-for-review"` with a null `promotion`, are both inconsistent
  documents; so is either of those states with `pr: null`, since reaching
  ready-for-review always means a PR exists — there is no promotion
  without one (`checkRunPromotionOutcome`).
- **`run.schema.json`'s `settlements[].reference.type` must match
  `disposition`** — `fix → sha` (a 40-hex value), `file → issue_number`
  (`^[1-9][0-9]*$`), `decline → comment_id` (non-empty) — the evidence a
  human or CI can actually follow has to be shaped for what it claims to be
  (`checkSettlementReferenceType`).
- **`run.schema.json`'s `evidence_comments[]` uniqueness** — `id` is unique
  (it is the harvester's own lookup key), and the `(marker.run_id,
  marker.stage, marker.sequence)` triple is unique (that triple **is** the
  deterministic marker the spec describes; two comments cannot legitimately
  share one) — `checkEvidenceCommentsUniqueness`.
- **Finding id round attribution without `--pass`**
  (`checkAdjudicationIdAttribution`) — a finding id's own
  `<stage>-r<round>` segments are part of its grammar, so they must equal
  the adjudication document's own `stage`/`round` with no external context
  at all; this runs unconditionally, and is what stops a finding from being
  silently re-adjudicated under a different round's claimed stage/round
  even before `--pass` or `--known-adjudicated` are considered.

### Context files are validated before they are trusted

`--pass` and `--adjudication` name other documents this family already has
a validator for, so each one is validated in full — `--pass` as a complete
reviewer envelope (envelope schema + reviewer payload + that payload's own
receipt checks, with no run context of its own — no `--known-ids` is
implied or inherited), `--adjudication` as a complete adjudication document
— **before** the primary document's cross-checks against it ever run. An
invalid context file fails immediately, naming that file, rather than
producing a confusing cross-check failure against garbage. `--known-ids`
and `--known-adjudicated` get the lighter version of the same discipline:
each must be a JSON array of strings or the run fails closed with a clear
error — a malformed file disables the very check it was meant to feed if
this isn't enforced, which is worse than not being able to run the check at
all, since it fails silently instead of loudly.

`--run-id` and `--initiated-by` are one pair, not two independent flags:
giving one without the other is a usage error (exit 2), not a check that
happens to always fail, since `initiated_by` is a required enum that is
never legitimately absent for a real run.

### Why `status`-conditional requirements are a semantic check, not `if`/`then`

`result.implementer.schema.json`'s `summary`/`handoff`/`ac_test_map` are
required (non-empty) when the envelope's status is completed, and ignored
(not forbidden — Foreman v1's `read_result()` tolerates the extra fields,
and forbidding them would break a v1 producer that always sends the full
shape) when blocked; `blocked_question` is required (non-null) when
blocked, ignored when completed. The deciding field, `status`, lives on the
**envelope**;
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
- **`human_tasks` is optional at every status**, matching Foreman v1
  exactly (`read_result()` does `data.get('human_tasks', [])`) — a v1
  blocked result in particular can carry only `schema`/`status`/
  `blocked_question` with no `human_tasks` key at all
  (`result.implementer.schema/valid/blocked-minimal.json`). When present it
  is still constrained to an array of strings.
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
- **`run.schema.json`'s `stage_transitions[].stage` enum holds only the
  stages within a run's own defined span**: `kickoff`, `claim`, `explore`,
  `plan`, `implement`, `verify`, `challenge`, `review`, `security`,
  `integration` — never `merge`, `deployment`, `release`, `smoke`, `retro`,
  or `wrap`. `docs/product/domain.md`'s Concepts table scopes a "run" to
  "from kickoff until ready-for-review or until it ends earlier", the same
  boundary the spec draws when it says everything after ready-for-review
  "is derived at read time ... never written by an actor" (§ Results).
  `merge`/`deployment`/`release`/`smoke` are the spec's own named examples
  of that derivation (from the PR timeline and repository-wide workflow/
  release signals); `retro` and `wrap` are excluded for the identical
  structural reason — domain.md's own lifecycle table places both after
  `merge` too, so they fall outside the run's defined span exactly like the
  four the spec names, even though the spec's § Results prose does not
  enumerate them individually. See the enum's own `$comment` for the full
  citation trail.
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
  spec's own examples. **The pattern alone only proves the shape, never the
  calendar** — `2026-02-30T10:00:00Z` matches it and names a day that does
  not exist. `scripts/validate-result-schemas.mjs`'s `checkTimestampRealness`
  is one generic walk over the whole instance (any object key equal to `at`
  or ending in `_at`, whatever schema it belongs to) that round-trips each
  value through `Date` parsing and confirms it re-renders to the same
  Y-M-D h:m:s (fractional seconds excluded from the comparison, since
  "no fraction" and `.000` spell the same instant) — an impossible date
  rolls over to a different one and is rejected. A single generic walk was
  chosen over a per-schema keyword because every schema in this family uses
  the identical timestamp shape, so a per-schema version would just be the
  same check copied six times.
- **`producer.tier`** excludes `adaptive`: that value is a `.devflow.toml`
  resolution *input*, never a fact about a run that already executed.
- **A terminal Codex cycle result must carry `accepted`.**
  `result.integrator.schema.json`'s `codex_cycle` has a nested
  `if: {exit_code: [0, 10]} then: {required: [accepted]}` — a clean (0) or
  findings (10) result is, per AGENTS.md's shepherd contract, always backed
  by a real surface (a review, comment, or reaction) carrying the evidence;
  the pending/retry/escalate/indeterminate/PR-closed codes (11/12/13/2/14)
  have no accepted evidence yet, so `accepted` stays optional for those.
  This is nested (inside a property's own schema, not at the payload root)
  precisely to prove `if`/`then` is not root-only in this engine — see the
  "nested if/then" unit tests beside the root-level ones in
  `scripts/test-result-schemas.sh`. "Optional for non-terminal codes" is
  the schema's own limit — `if`/`then` can express "required when", never
  "forbidden otherwise" — so `checkCodexCycleAcceptedScope` closes the gap
  in the validator: `accepted` present alongside any exit_code other than
  0/10 is rejected, since its presence is itself a claim of a terminal
  result.

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
Several fixtures additionally need a same-named sidecar because the
invariant they exercise needs context no single document carries (see
"Receipt validation" above): `result.reviewer.schema/invalid/duplicate-id-across-passes.json`
ships a `.known-ids.json` sidecar (a JSON array, passed as the validator's
`--known-ids`); the four `adjudication.schema/invalid/pass-cross-check-*.json`
fixtures share one `.pass.json` sidecar (a reviewer envelope, passed as
`--pass`); `adjudication.schema/invalid/known-adjudicated-collision.json`
ships a `.known-adjudicated.json` sidecar; `run.schema/invalid/settlement-of-*-finding.json`
and `run.schema/valid/settlement-of-deferred.json` share one
`.adjudication.json` sidecar (an adjudication document, passed as
`--adjudication`); `adjudication.schema/valid/two-finder-union-adjudication.json`
(itself schema-valid and receipt-valid on its own, and so lives in the
generic corpus as an ordinary valid fixture) is additionally exercised
against two `.pass.json` sidecars together (accepted — a genuine two-finder
round) and against only one of them (rejected, in the named cases); and the
run-mismatch case (`result.envelope.schema/invalid/run-mismatch.json`) is
exercised with a hardcoded `--run-id`/`--initiated-by` pair in
`scripts/test-result-schemas.sh` rather than a sidecar, since those are two
plain strings, not a document. All sidecars, and every fixture whose
invalid-ness depends entirely on a flag the generic loop never passes, are
excluded from both the valid and invalid per-directory loops
(`is_context_only_fixture` in `scripts/test-result-schemas.sh`) and
exercised only by name.

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
  [--known-ids <ids.json>] [--run-id <id> --initiated-by <human|foreman>] \
  [--pass <reviewer-envelope.json> ...] [--known-adjudicated <ids.json>] \
  [--adjudication <file.json> ...]
```

`--pass` and `--adjudication` are repeatable (a round can be more than one
finder's pass; a run's settlements can be checked against more than one
round's adjudication document). `--run-id` and `--initiated-by` must be
given together. Exit 0 and a one-line summary when valid; exit 1 and every
violation (one per line) otherwise; exit 2 for a usage error (bad `kind`,
missing file, `--run-id`/`--initiated-by` given alone). `scripts/test-result-schemas.sh`
(wired into `task test:result-schemas`, run from `task verify`) runs the
whole fixture corpus through this validator, every run-context regression
case above, and a coverage check that every `required` field and every
`enum` declared anywhere in each schema has at least one invalid fixture
exercising it.

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
