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
    */adjudication.schema/invalid/pass-cross-check-missing-entry.json) return 0 ;;
    */adjudication.schema/invalid/pass-cross-check-extra-entry.json) return 0 ;;
    */adjudication.schema/invalid/pass-cross-check-reviewer-priority-drift.json) return 0 ;;
    */adjudication.schema/invalid/pass-cross-check-head-mismatch.json) return 0 ;;
    */adjudication.schema/invalid/known-adjudicated-collision.json) return 0 ;;
    */run.schema/invalid/settlement-of-fixed-finding.json) return 0 ;;
    */run.schema/invalid/settlement-of-unknown-finding.json) return 0 ;;
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
  for (const name of schema.required ?? []) {
    required.add(JSON.stringify({ parent: currentPath, name }))
  }
  for (const [key, child] of Object.entries(schema.properties ?? {})) {
    const childPath = `${currentPath}.${key}`
    if (Array.isArray(child.enum) && child.enum.some((v) => v !== null)) {
      enums.add(childPath)
    }
    collect(root, child, childPath, required, enums, seen)
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
