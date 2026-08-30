#!/usr/bin/env bash
# test-result-schemas.sh — schema-check the dev-flow-v2 result/record fixture
# corpus (ai/schemas/fixtures/) and exercise the receipt-validation semantic
# checks scripts/validate-result-schemas.mjs layers on top of raw schema
# validation.
#
# Fixture corpus conventions (see ai/schemas/README.md):
#   ai/schemas/fixtures/<schema-dir>/valid/*.json     — must validate (exit 0)
#   ai/schemas/fixtures/<schema-dir>/invalid/*.json   — must be rejected
#   ai/schemas/fixtures/<schema-dir>/invalid/*.reason — sibling plain-text
#     file (one line) naming a substring the validator's rejection MUST
#     contain, so "rejected" is checked for the expected reason, not just
#     rejected at all. Every invalid fixture requires one.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

validator="scripts/validate-result-schemas.mjs"
schemas_dir="ai/schemas"
fixtures_dir="ai/schemas/fixtures"

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

command -v node >/dev/null 2>&1 || fail "node is required to validate the result schemas"
[ -f "$validator" ] || fail "missing required asset: $validator"

# is_context_only_fixture PATH — true for a fixture the generic per-directory
# valid/invalid loops below must not validate directly (checked in BOTH —
# a sidecar or a flag-dependent document can live under either, e.g. a
# --pass sidecar naming a real reviewer envelope belongs beside the valid
# adjudication document it supports). Three kinds:
#   - a *.known-ids.json / *.pass.json / *.known-adjudicated.json /
#     *.adjudication.json sidecar: matches the *.json glob (it IS a .json
#     file) but is never itself passed to the validator as a document to
#     validate — only as the argument to another fixture's --known-ids /
#     --pass / --known-adjudicated / --adjudication.
#   - a fixture whose invalid-ness depends ENTIRELY on a run-context flag
#     (--known-ids, --run-id/--initiated-by, --pass, --known-adjudicated,
#     --adjudication) the generic loop never passes. By construction these
#     are schema-valid and receipt-valid on their own — that is what makes
#     the flagged case meaningful to test — so the generic loop's flagless
#     invocation would otherwise accept them, contradicting "every
#     invalid/*.json is rejected". They are exercised instead by the named
#     run-context regression cases below, which pass the exact flag each
#     one needs.
is_context_only_fixture() {
    case "$1" in
    *.known-ids.json | *.pass.json | *.known-adjudicated.json | *.adjudication.json) return 0 ;;
    */result.envelope.schema/invalid/run-mismatch.json) return 0 ;;
    */result.reviewer.schema/invalid/duplicate-id-across-passes.json) return 0 ;;
    */result.integrator.schema/invalid/known-ids-collision.json) return 0 ;;
    */result.integrator.schema/invalid/applied-dispositions-unknown-finding-id.json) return 0 ;;
    */adjudication.schema/invalid/pass-cross-check-missing-entry.json) return 0 ;;
    */adjudication.schema/invalid/pass-cross-check-extra-entry.json) return 0 ;;
    */adjudication.schema/invalid/pass-cross-check-reviewer-priority-drift.json) return 0 ;;
    */adjudication.schema/invalid/pass-cross-check-head-mismatch.json) return 0 ;;
    */adjudication.schema/invalid/integration-head-mismatch.json) return 0 ;;
    */adjudication.schema/invalid/integration-round-mismatch.json) return 0 ;;
    */adjudication.schema/invalid/known-adjudicated-collision.json) return 0 ;;
    */run.schema/invalid/settlement-of-fixed-finding.json) return 0 ;;
    */run.schema/invalid/settlement-of-unknown-finding.json) return 0 ;;
    */run.schema/invalid/ready-with-unsettled-deferral.json) return 0 ;;
    *) return 1 ;;
    esac
}

# kind_for_dir DIR — map a fixtures/<dir> basename to the validator's <kind>
# positional argument.
kind_for_dir() {
    case "$1" in
    result.envelope.schema) echo "envelope" ;;
    result.implementer.schema) echo "implementer" ;;
    result.reviewer.schema) echo "reviewer" ;;
    result.integrator.schema) echo "integrator" ;;
    adjudication.schema) echo "adjudication" ;;
    run.schema) echo "run" ;;
    *) fail "fixtures directory does not map to a known schema kind: $1" ;;
    esac
}

schema_file_for_dir() {
    case "$1" in
    result.envelope.schema) echo "result.envelope.schema.json" ;;
    result.implementer.schema) echo "result.implementer.schema.json" ;;
    result.reviewer.schema) echo "result.reviewer.schema.json" ;;
    result.integrator.schema) echo "result.integrator.schema.json" ;;
    adjudication.schema) echo "adjudication.schema.json" ;;
    run.schema) echo "run.schema.json" ;;
    *) fail "fixtures directory does not map to a known schema file: $1" ;;
    esac
}

[ -d "$fixtures_dir" ] || fail "missing fixtures directory: $fixtures_dir"

fixture_dirs_found=0
valid_count=0
invalid_count=0

for dir in "$fixtures_dir"/*/; do
    [ -d "$dir" ] || continue
    base="$(basename "${dir%/}")"
    kind="$(kind_for_dir "$base")"
    fixture_dirs_found=$((fixture_dirs_found + 1))

    if [ -d "${dir}valid" ]; then
        for f in "${dir}valid"/*.json; do
            [ -f "$f" ] || continue
            is_context_only_fixture "$f" && continue
            valid_count=$((valid_count + 1))
            if ! out="$(node "$validator" "$kind" "$f" 2>&1)"; then
                fail "valid fixture rejected: $f -> $out"
            fi
        done
    fi
    echo "PASS: every valid $base fixture validates"

    if [ -d "${dir}invalid" ]; then
        for f in "${dir}invalid"/*.json; do
            [ -f "$f" ] || continue
            is_context_only_fixture "$f" && continue
            reason_file="${f%.json}.reason"
            [ -f "$reason_file" ] ||
                fail "invalid fixture $f has no sibling .reason file naming the expected rejection"
            expected="$(cat "$reason_file")"
            [ -n "$expected" ] || fail "$reason_file is empty"
            invalid_count=$((invalid_count + 1))
            if out="$(node "$validator" "$kind" "$f" 2>&1)"; then
                fail "invalid fixture accepted (should have been rejected): $f"
            fi
            case "$out" in
            *"$expected"*) ;;
            *) fail "$f rejected for the wrong reason — expected substring '$expected', got: $out" ;;
            esac
        done
    fi
    echo "PASS: every invalid $base fixture is rejected for its documented reason"
done

[ "$fixture_dirs_found" -gt 0 ] || fail "no fixture directories found under $fixtures_dir"
echo "PASS: fixture corpus OK ($valid_count valid, $invalid_count invalid, $fixture_dirs_found schema(s))"

# --- Native harness composition (result.schema.json) -----------------------
# result.schema.json is a self-contained composition (envelope properties +
# $defs.<role> + allOf role dispatch) a native JSON-Schema validator can use
# with no separate dispatch script. Two properties to prove: (a) it accepts
# every valid role fixture and rejects every invalid one whose violation is
# schema-level (a receipt/context-only violation — one that needs a sibling
# envelope field, another document, or run context this composed schema
# cannot see — is correctly NOT caught here; that is
# scripts/validate-result-schemas.mjs's job, and SEMANTIC_ONLY below is the
# explicit, auditable list of which fixtures those are); (b) $defs.<role>
# never drifts from the standalone result.<role>.schema.json it was copied
# from.
node --input-type=module - "$schemas_dir" "$fixtures_dir" <<'NODE'
import { createSchemaValidator, canonicalJson } from './scripts/lib/json-schema-subset.mjs'
import { readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'

const [schemasDir, fixturesDir] = process.argv.slice(2)

const composed = JSON.parse(readFileSync(path.join(schemasDir, 'result.schema.json'), 'utf8'))
const engine = createSchemaValidator(composed)
engine.assertSupportedSchema(composed)

const ROLE_DIRS = {
  implementer: 'result.implementer.schema',
  reviewer: 'result.reviewer.schema',
  integrator: 'result.integrator.schema'
}

// Fixtures whose invalid-ness needs a receipt-validation / run-context check
// this composed schema alone cannot express (ai/schemas/README.md's
// "Composition" / "Receipt validation" sections name every one of these
// checks). result.schema.json correctly ACCEPTS these fixtures on their
// own; scripts/validate-result-schemas.mjs is what rejects them.
const SEMANTIC_ONLY = new Set([
  // The "missing-*" implementer status-conditional fixtures moved OFF this
  // list once result.schema.json's allOf gained the completed/blocked
  // requiredness branches (role+status are both envelope-level, visible to
  // the composed document unlike the standalone payload-only schema) — see
  // ai/schemas/result.schema.json's own $comment. Only the "empty"/"null"
  // variants stay here: plain `required` proves a key is PRESENT, never
  // that its value is non-empty/non-null, so those still need the
  // validator's checkImplementerStatus.
  'result.implementer.schema/invalid/empty-ac_test_map-when-completed.json',
  'result.implementer.schema/invalid/null-blocked_question-when-blocked.json',
  'result.implementer.schema/invalid/empty-summary-when-completed.json',
  'result.implementer.schema/invalid/empty-handoff-when-completed.json',
  'result.reviewer.schema/invalid/counts-mismatch-tally.json',
  'result.reviewer.schema/invalid/duplicate-finding-id-within-pass.json',
  'result.reviewer.schema/invalid/duplicate-id-across-passes.json',
  'result.reviewer.schema/invalid/finding-id-finder-mismatch.json',
  'result.reviewer.schema/invalid/finding-id-round-mismatch.json',
  'result.reviewer.schema/invalid/finding-id-stage-mismatch.json',
  'result.reviewer.schema/invalid/head-mismatch.json',
  'result.reviewer.schema/invalid/blocked-with-findings.json',
  'result.integrator.schema/invalid/accepted-reviewed_commit-mismatch.json',
  'result.integrator.schema/invalid/applied-dispositions-duplicate-finding-id.json',
  'result.integrator.schema/invalid/blocked-with-clean-verdict.json',
  'result.integrator.schema/invalid/clean-with-empty-checks.json',
  'result.integrator.schema/invalid/clean-with-failing-check.json',
  'result.integrator.schema/invalid/clean-with-pending-cycle.json',
  'result.integrator.schema/invalid/clean-with-required-check-skipping.json',
  'result.integrator.schema/invalid/clean-with-unanswered-thread.json',
  'result.integrator.schema/invalid/clean-with-unapplied-finding.json',
  'result.integrator.schema/invalid/codex-cycle-nonterminal-with-accepted.json',
  'result.integrator.schema/invalid/head-mismatch.json',
  'result.integrator.schema/invalid/findings-duplicate-id.json',
  'result.integrator.schema/invalid/findings-wrong-cycle.json',
  'result.integrator.schema/invalid/known-ids-collision.json',
  'result.integrator.schema/invalid/clean-with-fix-disposition.json',
  'result.integrator.schema/invalid/applied-dispositions-unknown-finding-id.json',
  'result.integrator.schema/invalid/exit-code-13-with-pending.json',
  'result.integrator.schema/invalid/exit-code-14-with-clean.json',
  'result.integrator.schema/invalid/exit-code-10-with-pending.json'
])

let failures = 0
let validChecked = 0
let invalidChecked = 0
const semanticOnlySeen = new Set()

for (const dir of Object.values(ROLE_DIRS)) {
  const validDir = path.join(fixturesDir, dir, 'valid')
  for (const entry of readdirSync(validDir)) {
    if (!entry.endsWith('.json')) continue
    const file = path.join(validDir, entry)
    const instance = JSON.parse(readFileSync(file, 'utf8'))
    const errors = engine.validate(instance, composed, '$result')
    validChecked += 1
    if (errors.length > 0) {
      console.error(`FAIL: valid fixture rejected by result.schema.json: ${file} -> ${errors.join('; ')}`)
      failures += 1
    }
  }
  const invalidDir = path.join(fixturesDir, dir, 'invalid')
  for (const entry of readdirSync(invalidDir)) {
    if (!entry.endsWith('.json') || entry.includes('.known-ids.')) continue
    const relKey = `${dir}/invalid/${entry}`
    const file = path.join(invalidDir, entry)
    if (SEMANTIC_ONLY.has(relKey)) {
      semanticOnlySeen.add(relKey)
      continue
    }
    const instance = JSON.parse(readFileSync(file, 'utf8'))
    const errors = engine.validate(instance, composed, '$result')
    invalidChecked += 1
    if (errors.length === 0) {
      console.error(
        `FAIL: invalid fixture accepted by result.schema.json alone, expected a schema-level rejection: ${file}`
      )
      failures += 1
    }
  }
}
for (const key of SEMANTIC_ONLY) {
  if (!semanticOnlySeen.has(key)) {
    console.error(`FAIL: SEMANTIC_ONLY names a fixture that no longer exists: ${key}`)
    failures += 1
  }
}
if (failures === 0) {
  console.log(
    `PASS: result.schema.json accepts ${validChecked} valid role fixtures and rejects ${invalidChecked} schema-level invalid ones (${semanticOnlySeen.size} left to the validator script)`
  )
}

// $defs.<role> must never drift from the standalone result.<role>.schema.json
function stripDocMeta(doc) {
  const { $schema, $id, title, $comment, ...rest } = doc
  return rest
}
// The one necessary edit when nesting reviewer's own $defs.finding under
// this file's $defs.reviewer: its internal #/$defs/finding reference
// becomes #/$defs/reviewer/$defs/finding so it still resolves. Normalize
// exactly that rewrite back before comparing — nothing else should differ.
function normalizeReviewerRefs(fragment) {
  return JSON.parse(JSON.stringify(fragment).replaceAll('#/$defs/reviewer/$defs/finding', '#/$defs/finding'))
}

for (const role of Object.keys(ROLE_DIRS)) {
  const standalone = stripDocMeta(
    JSON.parse(readFileSync(path.join(schemasDir, `result.${role}.schema.json`), 'utf8'))
  )
  let composedDef = composed.$defs[role]
  if (role === 'reviewer') composedDef = normalizeReviewerRefs(composedDef)
  if (canonicalJson(standalone) !== canonicalJson(composedDef)) {
    console.error(
      `FAIL: result.schema.json's \$defs.${role} has drifted from result.${role}.schema.json (compared minus $schema/$id/title/$comment)`
    )
    failures += 1
  } else {
    console.log(`PASS: result.schema.json's \$defs.${role} matches result.${role}.schema.json`)
  }
}

process.exit(failures === 0 ? 0 : 1)
NODE

# --- Engine-level keyword tests (scripts/lib/json-schema-subset.mjs) -------
# minimum/maximum and if/then/else were added to the shared subset engine
# for this schema family (agent-registry.schema.json never needed them).
# The fixture corpus exercises both in situ (round/line/attempt/sequence
# lower bounds; the integrator's clean-verdict conditional), but the engine
# itself is shared with scripts/validate-agent-registry.mjs, so it earns
# direct, schema-agnostic tests of its own, isolated from any one schema's
# semantics — mirroring how test-agent-registry.sh unit-tests the rest of
# the engine's keywords via tiny inline schema/instance pairs.
node --input-type=module - <<'NODE'
import { createSchemaValidator } from './scripts/lib/json-schema-subset.mjs'

let failures = 0
function expect(description, condition) {
  if (!condition) {
    console.error(`FAIL: ${description}`)
    failures += 1
  } else {
    console.log(`PASS: ${description}`)
  }
}

// minimum / maximum
{
  const schema = { type: 'integer', minimum: 1, maximum: 3 }
  const engine = createSchemaValidator(schema)
  expect('minimum: rejects a value below it', engine.validate(0, schema, '$x').length > 0)
  expect('minimum: accepts the boundary value', engine.validate(1, schema, '$x').length === 0)
  expect('maximum: rejects a value above it', engine.validate(4, schema, '$x').length > 0)
  expect('maximum: accepts the boundary value', engine.validate(3, schema, '$x').length === 0)
  expect(
    'minimum/maximum: error message names the bound',
    engine.validate(0, schema, '$x').some((e) => e.includes('>= 1'))
  )
}

// if / then / else
{
  const schema = {
    type: 'object',
    properties: { status: { enum: ['completed', 'blocked'] }, summary: { type: 'string' } },
    if: { properties: { status: { const: 'completed' } }, required: ['status'] },
    then: { required: ['summary'] },
    else: { required: ['reason'] }
  }
  const engine = createSchemaValidator(schema)
  expect(
    'if/then: the then-branch requirement applies when if matches',
    engine.validate({ status: 'completed' }, schema, '$x').some((e) => e.includes('summary'))
  )
  expect(
    'if/then: the then-branch requirement is satisfied, no false positive',
    engine.validate({ status: 'completed', summary: 'ok' }, schema, '$x').length === 0
  )
  expect(
    'if/then/else: the else-branch requirement applies when if does not match',
    engine.validate({ status: 'blocked' }, schema, '$x').some((e) => e.includes('reason'))
  )
  expect(
    'if/then/else: a non-matching if never triggers the then-branch requirement',
    !engine.validate({ status: 'blocked', reason: 'why' }, schema, '$x').some((e) => e.includes('summary'))
  )
}

// if / then nested at a non-root property (result.integrator.schema.json's
// codex_cycle: exit_code 0/10 requires accepted) — proves the engine
// evaluates if/then wherever it appears in the schema tree, not only when
// the whole instance is the thing being conditioned.
{
  const schema = {
    type: 'object',
    properties: {
      cycle: {
        type: ['object', 'null'],
        properties: { exit_code: { enum: [0, 10, 11] }, accepted: { type: 'object' } },
        if: { properties: { exit_code: { enum: [0, 10] } }, required: ['exit_code'] },
        then: { required: ['accepted'] }
      }
    }
  }
  const engine = createSchemaValidator(schema)
  expect(
    'nested if/then: fires for a matching child object',
    engine
      .validate({ cycle: { exit_code: 0 } }, schema, '$x')
      .some((e) => e.includes('cycle') && e.includes('accepted'))
  )
  expect(
    'nested if/then: satisfied requirement produces no false positive',
    engine.validate({ cycle: { exit_code: 0, accepted: {} } }, schema, '$x').length === 0
  )
  expect(
    'nested if/then: a non-matching exit_code never requires accepted',
    engine.validate({ cycle: { exit_code: 11 } }, schema, '$x').length === 0
  )
  expect(
    'nested if/then: a null child is untouched by a condition scoped to it',
    engine.validate({ cycle: null }, schema, '$x').length === 0
  )
}

// allOf — unconditional composition (result.schema.json's role dispatch:
// one {if, then} member per role, ALL of them always evaluated against the
// whole instance).
{
  const schema = {
    type: 'object',
    properties: { role: { enum: ['a', 'b'] } },
    allOf: [
      { if: { properties: { role: { const: 'a' } }, required: ['role'] }, then: { required: ['x'] } },
      { if: { properties: { role: { const: 'b' } }, required: ['role'] }, then: { required: ['y'] } }
    ]
  }
  const engine = createSchemaValidator(schema)
  expect(
    'allOf: the matching member\'s then-branch fires',
    engine.validate({ role: 'a' }, schema, '$x').some((e) => e.includes('missing required property x'))
  )
  expect(
    'allOf: a non-matching member\'s then-branch never fires',
    !engine.validate({ role: 'a', x: 1 }, schema, '$x').some((e) => e.includes('missing required property y'))
  )
  expect(
    'allOf: every member is evaluated (not just the first)',
    engine.validate({ role: 'b' }, schema, '$x').some((e) => e.includes('missing required property y'))
  )
  expect(
    'allOf: satisfying every member\'s requirement produces no false positive',
    engine.validate({ role: 'a', x: 1 }, schema, '$x').length === 0
  )
}

process.exit(failures === 0 ? 0 : 1)
NODE
echo "PASS: engine-level minimum/maximum and if/then/else keyword tests"

# --- Receipt-validation regression tests requiring run context -------------
# These need an argument no single fixture file can carry on its own (a set
# of prior finding ids, or the run the envelope is checked against), so they
# are explicit named cases rather than entries in the generic corpus loop
# above. Each still lives beside a real fixture file under the corpus so
# Foreman's Python conformance run also has it to replay structurally (the
# extra CLI context is this script's concern, not the fixture's).

run_context_case() {
    local description="$1" kind="$2" file="$3" expected="$4"
    shift 4
    local out
    if out="$(node "$validator" "$kind" "$file" "$@" 2>&1)"; then
        fail "$description: expected rejection, validator accepted $file"
    fi
    case "$out" in
    *"$expected"*) ;;
    *) fail "$description failed for the wrong reason: $out" ;;
    esac
    echo "PASS: $description"
}

run_context_case \
    "duplicate finding id across passes in the same run is rejected" \
    reviewer \
    "$fixtures_dir/result.reviewer.schema/invalid/duplicate-id-across-passes.json" \
    "collides with a finding already in the run" \
    --known-ids "$fixtures_dir/result.reviewer.schema/invalid/duplicate-id-across-passes.known-ids.json"

run_context_case \
    "a run that is not the active run is rejected" \
    implementer \
    "$fixtures_dir/result.envelope.schema/invalid/run-mismatch.json" \
    "is not the active run" \
    --run-id "run-0001-active" --initiated-by human

adjudication_pass_dir="$fixtures_dir/adjudication.schema/invalid"

run_context_case \
    "an adjudication missing an entry for a pass finding is rejected" \
    adjudication \
    "$adjudication_pass_dir/pass-cross-check-missing-entry.json" \
    "has no adjudication entry" \
    --pass "$adjudication_pass_dir/pass-cross-check.pass.json"

run_context_case \
    "a blocked pass is rejected as --pass context" \
    adjudication \
    "$adjudication_pass_dir/pass-cross-check-missing-entry.json" \
    "a blocked pass contributes no findings and cannot be used as --pass context" \
    --pass "$adjudication_pass_dir/pass-cross-check-blocked-pass.pass.json"

run_context_case \
    "a blocked INTEGRATOR pass with no findings is still rejected as --pass context" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/integration-adjudication.json" \
    "a blocked pass contributes no findings and cannot be used as --pass context" \
    --pass "$fixtures_dir/adjudication.schema/invalid/integration-blocked-pass-no-findings.pass.json"

run_context_case \
    "an adjudication entry naming an id absent from the pass is rejected" \
    adjudication \
    "$adjudication_pass_dir/pass-cross-check-extra-entry.json" \
    "names a finding id absent from every --pass" \
    --pass "$adjudication_pass_dir/pass-cross-check.pass.json"

run_context_case \
    "an adjudication entry's reviewer_priority drifting from the pass finding's priority is rejected" \
    adjudication \
    "$adjudication_pass_dir/pass-cross-check-reviewer-priority-drift.json" \
    "does not match the pass finding's own priority" \
    --pass "$adjudication_pass_dir/pass-cross-check.pass.json"

run_context_case \
    "an adjudication document naming a reviewed_head that disagrees with the pass is rejected" \
    adjudication \
    "$adjudication_pass_dir/pass-cross-check-head-mismatch.json" \
    "does not match the pass payload's reviewed_head" \
    --pass "$adjudication_pass_dir/pass-cross-check.pass.json"

two_finder_dir="$fixtures_dir/adjudication.schema/valid"

run_context_case \
    "a union adjudication checked against only one of its two passes is rejected" \
    adjudication \
    "$two_finder_dir/two-finder-union-adjudication.json" \
    "names a finding id absent from every --pass" \
    --pass "$two_finder_dir/two-finder-a.pass.json"

run_context_case \
    "two --pass files repeating the same finder are rejected" \
    adjudication \
    "$two_finder_dir/two-finder-union-adjudication.json" \
    "repeats finder codex-cli" \
    --pass "$two_finder_dir/two-finder-a.pass.json" \
    --pass "$two_finder_dir/two-finder-a.pass.json"

# --pass agreement covers the full run identity (run_id AND initiated_by),
# not just run_id -- a --pass file with a foreign initiated_by is otherwise
# schema-valid on its own, so this is context-only (needs the OTHER pass to
# disagree with).
sed 's/"initiated_by": "human"/"initiated_by": "foreman"/' "$two_finder_dir/two-finder-b.pass.json" \
    >"$test_tmp/two-finder-b-foreign-initiated-by.pass.json"
run_context_case \
    "two --pass files disagreeing on initiated_by (same run_id) are rejected" \
    adjudication \
    "$two_finder_dir/two-finder-union-adjudication.json" \
    "disagreeing with" \
    --pass "$two_finder_dir/two-finder-a.pass.json" \
    --pass "$test_tmp/two-finder-b-foreign-initiated-by.pass.json"

run_context_case \
    "a --pass file whose run identity disagrees with the given --run-id/--initiated-by is rejected" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/omator-397-challenge-r1-adjudication.json" \
    "is not the active run" \
    --pass "$fixtures_dir/result.reviewer.schema/valid/omator-397-challenge-r1.json" \
    --run-id "wrong-run-id" --initiated-by human

run_context_case \
    "an adjudication entry already adjudicated by an earlier round document is rejected" \
    adjudication \
    "$adjudication_pass_dir/known-adjudicated-collision.json" \
    "already adjudicated in an earlier round document of this run" \
    --known-adjudicated "$adjudication_pass_dir/known-adjudicated-collision.known-adjudicated.json"

settlement_cross_check_adjudication="$fixtures_dir/run.schema/invalid/settlement-cross-check.adjudication.json"

run_context_case \
    "a settlement of a finding adjudicated fix (not deferred) is rejected" \
    run \
    "$fixtures_dir/run.schema/invalid/settlement-of-fixed-finding.json" \
    "was adjudicated fix, not defer" \
    --adjudication "$settlement_cross_check_adjudication"

run_context_case \
    "a settlement of a finding absent from every supplied adjudication document is rejected" \
    run \
    "$fixtures_dir/run.schema/invalid/settlement-of-unknown-finding.json" \
    "is not adjudicated in any supplied --adjudication document" \
    --adjudication "$settlement_cross_check_adjudication"

run_context_case \
    "an --adjudication document belonging to a foreign run is rejected" \
    run \
    "$fixtures_dir/run.schema/valid/fresh-kickoff.json" \
    "not this run's own run_id" \
    --adjudication "$settlement_cross_check_adjudication"

run_context_case \
    "an --adjudication document naming a stage this run's stage_transitions never visited is rejected" \
    run \
    "$fixtures_dir/run.schema/valid/fresh-kickoff.json" \
    "never appears in this run's stage_transitions" \
    --adjudication "$fixtures_dir/run.schema/invalid/stage-not-visited.adjudication.json"

run_context_case \
    "the same --adjudication document supplied twice is rejected: a finding cannot be adjudicated more than once" \
    run \
    "$fixtures_dir/run.schema/valid/settlement-of-deferred.json" \
    "is adjudicated more than once across the supplied --adjudication documents" \
    --adjudication "$settlement_cross_check_adjudication" \
    --adjudication "$settlement_cross_check_adjudication"

run_context_case \
    "a ready-for-review run with an unsettled deferred finding is rejected" \
    run \
    "$fixtures_dir/run.schema/invalid/ready-with-unsettled-deferral.json" \
    "has no settlement, required when outcome is ready-for-review" \
    --adjudication "$settlement_cross_check_adjudication"

# Accepting cases for the same flags, so a false-positive rejection (the flag
# firing when it should not) is caught too.
accept_context_case() {
    local description="$1" kind="$2" file="$3"
    shift 3
    local out
    if ! out="$(node "$validator" "$kind" "$file" "$@" 2>&1)"; then
        fail "$description: expected acceptance, validator rejected $file -> $out"
    fi
    echo "PASS: $description"
}

accept_context_case \
    "a --pass file matching the given --run-id/--initiated-by is accepted" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/omator-397-challenge-r1-adjudication.json" \
    --pass "$fixtures_dir/result.reviewer.schema/valid/omator-397-challenge-r1.json" \
    --run-id "omator-397" --initiated-by human

accept_context_case \
    "a run matching the active run is accepted" \
    implementer \
    "$fixtures_dir/result.implementer.schema/valid/completed.json" \
    --run-id "run-0397-omator" --initiated-by human

accept_context_case \
    "a finding id absent from known-ids is accepted" \
    reviewer \
    "$fixtures_dir/result.reviewer.schema/valid/single-finding-null-line.json" \
    --known-ids "$fixtures_dir/result.reviewer.schema/invalid/duplicate-id-across-passes.known-ids.json"

accept_context_case \
    "a genuine adjudication of its own pass is accepted (omator-397 challenge round 1)" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/omator-397-challenge-r1-adjudication.json" \
    --pass "$fixtures_dir/result.reviewer.schema/valid/omator-397-challenge-r1.json"

accept_context_case \
    "an integration-stage adjudication is checked against an INTEGRATOR --pass envelope, priority fidelity skipped" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/integration-adjudication.json" \
    --pass "$fixtures_dir/adjudication.schema/valid/integration-adjudication.pass.json"

accept_context_case \
    "a blocked INTEGRATOR pass with non-empty findings is accepted as --pass context" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/integration-blocked-adjudication.json" \
    --pass "$fixtures_dir/adjudication.schema/valid/integration-blocked-pass-with-findings.pass.json"

run_context_case \
    "an integration-stage adjudication naming a reviewed_head that disagrees with the --pass envelope's head is rejected" \
    adjudication \
    "$fixtures_dir/adjudication.schema/invalid/integration-head-mismatch.json" \
    "does not match the pass envelope's head" \
    --pass "$fixtures_dir/adjudication.schema/valid/integration-adjudication.pass.json"

run_context_case \
    "an integration-stage adjudication naming a round that disagrees with the --pass envelope's codex_cycle.cycle is rejected" \
    adjudication \
    "$fixtures_dir/adjudication.schema/invalid/integration-round-mismatch.json" \
    "does not match the pass envelope's codex_cycle.cycle" \
    --pass "$fixtures_dir/adjudication.schema/invalid/integration-round-mismatch.pass.json"

run_context_case \
    "a second --pass for an integration-stage adjudication is rejected, naming the extra file" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/integration-adjudication.json" \
    "stage integration accepts at most one --pass" \
    --pass "$fixtures_dir/adjudication.schema/valid/integration-adjudication.pass.json" \
    --pass "$fixtures_dir/adjudication.schema/valid/integration-adjudication.pass.json"

accept_context_case \
    "a union adjudication checked against both of a two-finder round's passes is accepted" \
    adjudication \
    "$two_finder_dir/two-finder-union-adjudication.json" \
    --pass "$two_finder_dir/two-finder-a.pass.json" \
    --pass "$two_finder_dir/two-finder-b.pass.json"

accept_context_case \
    "a settlement of a genuinely deferred finding is accepted" \
    run \
    "$fixtures_dir/run.schema/valid/settlement-of-deferred.json" \
    --adjudication "$settlement_cross_check_adjudication"

accept_context_case \
    "a ready-for-review run whose deferred finding IS settled is accepted" \
    run \
    "$fixtures_dir/run.schema/valid/ready-with-settled-deferral.json" \
    --adjudication "$settlement_cross_check_adjudication"

# --- Argument validation: fail closed, never silently skip a check --------

# A malformed --known-ids / --known-adjudicated file (valid JSON, but not an
# array of strings) must abort validation entirely rather than silently
# disable the check it was meant to feed — reuse any existing object-shaped
# fixture as "not an array".
not_an_array_file="$fixtures_dir/adjudication.schema/valid/omator-397-challenge-r1-adjudication.json"

fail_closed_case() {
    local description="$1" kind="$2" file="$3" flag="$4" bad_file="$5" expected="$6"
    local out status=0
    out="$(node "$validator" "$kind" "$file" "$flag" "$bad_file" 2>&1)" || status=$?
    if [ "$status" -ne 1 ]; then
        fail "$description: expected exit 1, got $status: $out"
    fi
    case "$out" in
    *"$expected"*) ;;
    *) fail "$description failed for the wrong reason: $out" ;;
    esac
    echo "PASS: $description"
}

fail_closed_case \
    "a --known-ids file that is not a JSON array of strings fails closed" \
    reviewer \
    "$fixtures_dir/result.reviewer.schema/valid/single-finding-null-line.json" \
    --known-ids "$not_an_array_file" \
    "must be a JSON array of strings"

fail_closed_case \
    "a --known-adjudicated file that is not a JSON array of strings fails closed" \
    adjudication \
    "$adjudication_pass_dir/known-adjudicated-collision.json" \
    --known-adjudicated "$not_an_array_file" \
    "must be a JSON array of strings"

# --run-id and --initiated-by are a pair: one without the other is a usage
# error (exit 2), not a guaranteed (and misleading) mismatch rejection.
usage_error_case() {
    local description="$1"
    shift
    local out status=0
    out="$(node "$validator" "$@" 2>&1)" || status=$?
    if [ "$status" -ne 2 ]; then
        fail "$description: expected exit 2 (usage error), got $status: $out"
    fi
    echo "PASS: $description"
}

usage_error_case \
    "--run-id without --initiated-by is a usage error" \
    implementer "$fixtures_dir/result.implementer.schema/valid/completed.json" --run-id "run-0397-omator"

usage_error_case \
    "--initiated-by without --run-id is a usage error" \
    implementer "$fixtures_dir/result.implementer.schema/valid/completed.json" --initiated-by human

# A malformed --pass file must fail immediately, naming the --pass file
# itself, before the primary document's own cross-checks ever run.
printf '%s' '{"payload":{"findings":[]}}' >"$test_tmp/malformed-pass.json"
if out="$(node "$validator" adjudication "$adjudication_pass_dir/pass-cross-check-missing-entry.json" \
    --pass "$test_tmp/malformed-pass.json" 2>&1)"; then
    fail "a malformed --pass file: expected rejection, validator accepted it"
fi
case "$out" in
*"--pass file $test_tmp/malformed-pass.json is invalid"*) ;;
*) fail "a malformed --pass file failed for the wrong reason: $out" ;;
esac
echo "PASS: a malformed --pass file fails immediately, naming the file"

# Same contract for --adjudication (run kind's own context flag).
printf '%s' '{"stage":"challenge"}' >"$test_tmp/malformed-adjudication.json"
if out="$(node "$validator" run "$fixtures_dir/run.schema/valid/settlement-of-deferred.json" \
    --adjudication "$test_tmp/malformed-adjudication.json" 2>&1)"; then
    fail "a malformed --adjudication file: expected rejection, validator accepted it"
fi
case "$out" in
*"--adjudication file $test_tmp/malformed-adjudication.json is invalid"*) ;;
*) fail "a malformed --adjudication file failed for the wrong reason: $out" ;;
esac
echo "PASS: a malformed --adjudication file fails immediately, naming the file"

# --integration-cap: only meaningful combined with a clean verdict whose
# codex_cycle is null — context-only, so both sides reuse an existing
# fixture with the flag rather than needing new committed files.
run_context_case \
    "a positive --integration-cap rejects a clean verdict with codex_cycle null" \
    integrator \
    "$fixtures_dir/result.integrator.schema/valid/codex-cycle-null.json" \
    "must not be null when verdict is clean and the integration cap is 4" \
    --integration-cap 4

accept_context_case \
    "--integration-cap 0 still permits codex_cycle null on a clean verdict" \
    integrator \
    "$fixtures_dir/result.integrator.schema/valid/codex-cycle-null.json" \
    --integration-cap 0

usage_error_case \
    "a non-numeric --integration-cap is a usage error" \
    integrator "$fixtures_dir/result.integrator.schema/valid/codex-cycle-null.json" --integration-cap not-a-number

# The validator must find its own schemas by its OWN location, not the
# caller's cwd — run each of these from $test_tmp, a directory with no
# ai/schemas of its own, using absolute paths for the validator and fixture.
if ! out="$(cd "$test_tmp" && node "$repo/$validator" implementer \
    "$repo/$fixtures_dir/result.implementer.schema/valid/completed.json" \
    --run-id "run-0397-omator" --initiated-by human 2>&1)"; then
    fail "default schemas dir from a different cwd: expected acceptance, got -> $out"
fi
echo "PASS: the validator resolves its schemas script-relatively, independent of the caller's cwd"

if ! out="$(cd "$test_tmp" && RESULT_SCHEMAS_DIR="$repo/$schemas_dir" node "$repo/$validator" implementer \
    "$repo/$fixtures_dir/result.implementer.schema/valid/completed.json" \
    --run-id "run-0397-omator" --initiated-by human 2>&1)"; then
    fail "RESULT_SCHEMAS_DIR override: expected acceptance, got -> $out"
fi
echo "PASS: RESULT_SCHEMAS_DIR overrides the default schemas directory"

if ! out="$(cd "$test_tmp" && node "$repo/$validator" implementer \
    "$repo/$fixtures_dir/result.implementer.schema/valid/completed.json" \
    --run-id "run-0397-omator" --initiated-by human --schemas-dir "$repo/$schemas_dir" 2>&1)"; then
    fail "--schemas-dir override: expected acceptance, got -> $out"
fi
echo "PASS: --schemas-dir overrides the default schemas directory"

if ! out="$(cd "$test_tmp" && RESULT_SCHEMAS_DIR="/nonexistent-dir-xyz" node "$repo/$validator" implementer \
    "$repo/$fixtures_dir/result.implementer.schema/valid/completed.json" \
    --schemas-dir "$repo/$schemas_dir" 2>&1)"; then
    fail "--schemas-dir should win over a conflicting RESULT_SCHEMAS_DIR: got -> $out"
fi
echo "PASS: --schemas-dir wins over a conflicting RESULT_SCHEMAS_DIR"

# --receipt: without it, an omitted context flag simply skips the checks it
# would have fed, and the success message says so; with it, every context
# flag applicable to <kind> is required, naming each missing one.
reviewer_receipt_fixture="$fixtures_dir/result.reviewer.schema/valid/single-finding-null-line.json"
reviewer_receipt_run_id="run-2150-single-finding-null-line"
empty_ids_file="$test_tmp/empty-ids.json"
printf '[]' >"$empty_ids_file"

out="$(node "$validator" reviewer "$reviewer_receipt_fixture" 2>&1)" || fail "reviewer with no context flags should still be accepted: $out"
case "$out" in
*"context skipped: --known-ids, --run-id"*) ;;
*) fail "the success message should name every applicable flag that was skipped, got: $out" ;;
esac
echo "PASS: the success message names every applicable context flag left unsupplied"

out="$(node "$validator" reviewer "$reviewer_receipt_fixture" \
    --run-id "$reviewer_receipt_run_id" --initiated-by human --known-ids "$empty_ids_file" 2>&1)" ||
    fail "reviewer with every applicable flag supplied should be accepted: $out"
case "$out" in
*"context skipped"*) fail "no context was actually skipped, the message should not claim otherwise: $out" ;;
esac
echo "PASS: the success message omits 'context skipped' once every applicable flag is supplied"

receipt_status=0
out="$(node "$validator" reviewer "$reviewer_receipt_fixture" --receipt 2>&1)" || receipt_status=$?
[ "$receipt_status" -eq 2 ] || fail "--receipt with no context flags: expected exit 2 (usage error), got $receipt_status: $out"
case "$out" in
*"--receipt requires --known-ids"*"--receipt requires --run-id"*) ;;
*) fail "--receipt's usage error should name every missing applicable flag, got: $out" ;;
esac
echo "PASS: --receipt's usage error names every missing applicable flag"

accept_context_case \
    "--receipt is satisfied once every applicable reviewer flag is supplied" \
    reviewer "$reviewer_receipt_fixture" \
    --receipt --run-id "$reviewer_receipt_run_id" --initiated-by human --known-ids "$empty_ids_file"

usage_error_case \
    "--receipt on an adjudication with none of --pass, --known-adjudicated, or --run-id is a usage error" \
    adjudication "$fixtures_dir/adjudication.schema/valid/omator-397-challenge-r1-adjudication.json" --receipt

run_context_case \
    "an adjudication document naming a run_id other than the given --run-id is rejected" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/omator-397-challenge-r1-adjudication.json" \
    "is not the active run" \
    --run-id "wrong-run-id" --initiated-by human

accept_context_case \
    "an adjudication document naming the given --run-id is accepted" \
    adjudication \
    "$fixtures_dir/adjudication.schema/valid/omator-397-challenge-r1-adjudication.json" \
    --run-id "omator-397" --initiated-by human

usage_error_case \
    "--receipt on a run record without --adjudication is a usage error" \
    run "$fixtures_dir/run.schema/valid/fresh-kickoff.json" --receipt

usage_error_case \
    "--receipt on an integrator result without --integration-cap, --known-ids, or --run-id is a usage error" \
    integrator "$fixtures_dir/result.integrator.schema/valid/verdict-clean.json" --receipt

run_context_case \
    "an integrator finding id colliding with --known-ids is rejected" \
    integrator \
    "$fixtures_dir/result.integrator.schema/invalid/known-ids-collision.json" \
    "collides with a finding already in the run" \
    --known-ids "$fixtures_dir/result.integrator.schema/invalid/known-ids-collision.known-ids.json"

accept_context_case \
    "an integrator finding id absent from --known-ids is accepted" \
    integrator \
    "$fixtures_dir/result.integrator.schema/invalid/known-ids-collision.json" \
    --known-ids "$empty_ids_file"

run_context_case \
    "an applied_dispositions finding_id absent from both current findings and --known-ids is rejected" \
    integrator \
    "$fixtures_dir/result.integrator.schema/invalid/applied-dispositions-unknown-finding-id.json" \
    "is neither one of this payload's own findings nor in --known-ids" \
    --known-ids "$empty_ids_file"

accept_context_case \
    "an applied_dispositions finding_id present in --known-ids (an earlier cycle's finding) is accepted" \
    integrator \
    "$fixtures_dir/result.integrator.schema/invalid/applied-dispositions-unknown-finding-id.json" \
    --known-ids "$fixtures_dir/result.integrator.schema/invalid/applied-dispositions-unknown-finding-id.known-ids.json"

usage_error_case \
    "--no-adjudications and --adjudication together are a usage error" \
    run "$fixtures_dir/run.schema/valid/fresh-kickoff.json" \
    --no-adjudications --adjudication "$settlement_cross_check_adjudication"

accept_context_case \
    "--receipt is satisfied for a fresh kickoff run by --no-adjudications" \
    run "$fixtures_dir/run.schema/valid/fresh-kickoff.json" --receipt --no-adjudications

accept_context_case \
    "--receipt is satisfied for a ready-for-review run that never adjudicated anything" \
    run "$fixtures_dir/run.schema/valid/ready-with-no-adjudications.json" --receipt --no-adjudications

run_context_case \
    "--no-adjudications rejects any existing settlement, since nothing can have adjudicated it" \
    run \
    "$fixtures_dir/run.schema/valid/ready-with-settled-deferral.json" \
    "is not adjudicated in any supplied --adjudication document" \
    --no-adjudications

# --- Coverage: every required field and every enum has an invalid fixture --
# Walks each schema file's own required[]/enum[] declarations (following
# properties/items/$ref/$defs — the only containers this family's schemas
# use) and cross-checks that the schema's invalid/*.reason corpus names each
# one, so "mutation tests per required field and per enum" is verified
# rather than merely hand-curated. Each requirement/enum is keyed by its
# FULL schema path (e.g. "adjudications[].override.reason"), matching the
# validator's own error-location format, not by its bare property name —
# two different properties sharing a name at different paths in the same
# schema (adjudication.schema.json has a bare `reason` on every entry AND
# a nested `override.reason`) must not let one satisfy coverage for the
# other. The path is turned into a regex ([] -> \[\d+\] for array items) and
# matched against the actual "$loc: missing required property X" / "$loc:
# must be one of" text the validator prints — i.e. this checks that the
# .reason corpus quotes an error at THIS path, not merely that the words
# appear somewhere in the corpus.
node --input-type=module - "$schemas_dir" "$fixtures_dir" <<'NODE'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import path from 'node:path'

const [schemasDir, fixturesDir] = process.argv.slice(2)

const DIR_TO_SCHEMA = {
  'result.envelope.schema': ['result.envelope.schema.json', '$result'],
  'result.implementer.schema': ['result.implementer.schema.json', '$result.payload'],
  'result.reviewer.schema': ['result.reviewer.schema.json', '$result.payload'],
  'result.integrator.schema': ['result.integrator.schema.json', '$result.payload'],
  'adjudication.schema': ['adjudication.schema.json', '$adjudication'],
  'run.schema': ['run.schema.json', '$run']
}

function resolveRef(root, ref) {
  if (typeof ref !== 'string' || !ref.startsWith('#/')) return undefined
  return ref
    .slice(2)
    .split('/')
    .reduce((node, part) => (node && typeof node === 'object' ? node[part] : undefined), root)
}

// collect ROOT SCHEMA CURRENT_PATH — CURRENT_PATH is the location of the
// object SCHEMA itself describes (starts at the schema's own root
// location, e.g. "$adjudication" or "$result.payload").
function collect(root, schema, currentPath, required, enums, seen) {
  if (schema === null || typeof schema !== 'object' || Array.isArray(schema)) return
  if (schema.$ref) {
    const target = resolveRef(root, schema.$ref)
    if (target) collect(root, target, currentPath, required, enums, seen)
    return
  }
  if (seen.has(schema)) return
  seen.add(schema)
  // Self-check at CURRENT_PATH, not just from the parent's properties loop:
  // a type-conditional field (e.g. adjudication.schema.json's
  // reviewer_priority, {type: [string,null], if: {type: string}, then:
  // {enum: [...]}}) puts its enum inside `then`, still describing the SAME
  // location — if/then/else recurse at the SAME currentPath below for
  // exactly this reason, so the enum must be attributed there too, not
  // only when a schema node is reached directly as a named property.
  if (Array.isArray(schema.enum) && schema.enum.some((v) => v !== null)) {
    enums.add(currentPath)
  }
  for (const name of schema.required ?? []) {
    required.add(JSON.stringify({ parent: currentPath, name }))
  }
  for (const [key, child] of Object.entries(schema.properties ?? {})) {
    collect(root, child, `${currentPath}.${key}`, required, enums, seen)
  }
  if (schema.items) collect(root, schema.items, `${currentPath}[]`, required, enums, seen)
  for (const key of ['if', 'then', 'else']) {
    if (schema[key]) collect(root, schema[key], currentPath, required, enums, seen)
  }
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

// pathRegexFragment PATH — PATH with literal regex metacharacters escaped
// and every "[]" (an array item, index unknown at schema-walk time) turned
// into a digit wildcard, so it matches the validator's real "[N]" location
// segment for whatever N a fixture's violating item happens to sit at.
function pathRegexFragment(p) {
  return p
    .split(/(\[\])/g)
    .map((part) => (part === '[]' ? '\\[\\d+\\]' : escapeRegExp(part)))
    .join('')
}

// checkCoverage — pure function of the collected requirement/enum sets and
// the corpus's .reason text; returns one failure message per uncovered
// item. Kept separate from disk I/O so the self-test below can call it
// directly against a synthetic (fixture-free) reasons string.
function checkCoverage(schemaFile, required, enums, reasonsText) {
  const failures = []
  for (const raw of required) {
    const { parent, name } = JSON.parse(raw)
    const re = new RegExp(`${pathRegexFragment(parent)}: missing required property ${escapeRegExp(name)}\\b`)
    if (!re.test(reasonsText)) {
      failures.push(`${schemaFile}: no invalid fixture covers missing required property '${name}' at '${parent}'`)
    }
  }
  for (const fullPath of enums) {
    const re = new RegExp(`${pathRegexFragment(fullPath)}: must be one of`)
    if (!re.test(reasonsText)) {
      failures.push(`${schemaFile}: no invalid fixture covers an enum violation at '${fullPath}'`)
    }
  }
  return failures
}

function reasonsTextFor(dir) {
  const invalidDir = path.join(fixturesDir, dir, 'invalid')
  let reasons = ''
  if (existsSync(invalidDir)) {
    for (const entry of readdirSync(invalidDir)) {
      if (entry.endsWith('.reason')) reasons += `${readFileSync(path.join(invalidDir, entry), 'utf8')}\n`
    }
  }
  return reasons
}

// Negative self-test FIRST: prove checkCoverage actually fails when
// coverage is missing, against a REAL schema's REAL requirement/enum set,
// before trusting it to pass the real corpus below. Without this, a
// checker that always reports "complete" (the exact bug this replaces —
// the old version split each entry into individual characters and matched
// on the first one, which was satisfied by nearly anything) would go
// uncaught by its own test suite.
{
  const [schemaFile] = DIR_TO_SCHEMA['adjudication.schema']
  const schema = JSON.parse(readFileSync(path.join(schemasDir, schemaFile), 'utf8'))
  const required = new Set()
  const enums = new Set()
  collect(schema, schema, '$adjudication', required, enums, new Set())
  if (required.size === 0 || enums.size === 0) {
    console.error('FAIL: self-test: adjudication.schema.json unexpectedly has no required fields or enums to test with')
    process.exit(1)
  }
  const emptyCorpusFailures = checkCoverage(schemaFile, required, enums, '')
  if (emptyCorpusFailures.length !== required.size + enums.size) {
    console.error(
      `FAIL: self-test: checkCoverage against an EMPTY fixture corpus should report all ${required.size + enums.size} items uncovered, reported ${emptyCorpusFailures.length} — the checker is not actually checking anything`
    )
    process.exit(1)
  }
  // And the inverse: the REAL corpus must not ALSO fail against this same
  // schema's requirements — proves the self-test's "empty" case and the
  // real case actually exercise the same code path with different inputs,
  // not two independently-broken checks that coincidentally agree.
  const realFailures = checkCoverage(schemaFile, required, enums, reasonsTextFor('adjudication.schema'))
  if (realFailures.length >= emptyCorpusFailures.length) {
    console.error(
      'FAIL: self-test: the real fixture corpus covers no more than an empty corpus would — checkCoverage is not path-sensitive'
    )
    process.exit(1)
  }
  console.log(
    `PASS: coverage self-test (empty corpus: ${emptyCorpusFailures.length}/${emptyCorpusFailures.length} uncovered, real corpus: ${realFailures.length} uncovered)`
  )
}

let failures = 0
for (const [dir, [schemaFile, rootLocation]] of Object.entries(DIR_TO_SCHEMA)) {
  const schema = JSON.parse(readFileSync(path.join(schemasDir, schemaFile), 'utf8'))
  const required = new Set()
  const enums = new Set()
  collect(schema, schema, rootLocation, required, enums, new Set())

  const schemaFailures = checkCoverage(schemaFile, required, enums, reasonsTextFor(dir))
  for (const message of schemaFailures) console.error(`FAIL: ${message}`)
  failures += schemaFailures.length
  if (schemaFailures.length === 0) console.log(`PASS: ${schemaFile} required/enum coverage complete`)
}
process.exit(failures === 0 ? 0 : 1)
NODE

echo "result schemas conformance OK"
