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

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

command -v node >/dev/null 2>&1 || fail "node is required to validate the result schemas"
[ -f "$validator" ] || fail "missing required asset: $validator"

# is_context_only_fixture PATH — true for a fixture the generic per-directory
# loop below must not validate directly. Two kinds:
#   - a *.known-ids.json sidecar: matches the invalid/*.json glob (it IS a
#     .json file) but is never itself passed to the validator as a document
#     to validate — only as the argument to another fixture's --known-ids.
#   - a fixture whose invalid-ness depends ENTIRELY on a run-context flag
#     (--known-ids, --run-id/--initiated-by) the generic loop never passes.
#     Both of these are, by construction, schema-valid and receipt-valid on
#     their own — that is what makes the flagged case meaningful to test —
#     so the generic loop's flagless invocation would otherwise accept them,
#     contradicting "every invalid/*.json is rejected". They are exercised
#     instead by the named run-context regression cases below, which pass
#     the exact flag each one needs.
is_context_only_fixture() {
    case "$1" in
    *.known-ids.json) return 0 ;;
    */result.envelope.schema/invalid/run-mismatch.json) return 0 ;;
    */result.reviewer.schema/invalid/duplicate-id-across-passes.json) return 0 ;;
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

# --- Coverage: every required field and every enum has an invalid fixture --
# Walks each schema file's own required[]/enum[] declarations (following
# properties/items/$defs — the only containers this family's schemas use)
# and cross-checks that the schema's invalid/*.reason corpus names each one,
# so "mutation tests per required field and per enum" is verified rather
# than merely hand-curated.
node --input-type=module - "$schemas_dir" "$fixtures_dir" <<'NODE'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import path from 'node:path'

const [schemasDir, fixturesDir] = process.argv.slice(2)

const DIR_TO_SCHEMA = {
  'result.envelope.schema': 'result.envelope.schema.json',
  'result.implementer.schema': 'result.implementer.schema.json',
  'result.reviewer.schema': 'result.reviewer.schema.json',
  'result.integrator.schema': 'result.integrator.schema.json',
  'adjudication.schema': 'adjudication.schema.json',
  'run.schema': 'run.schema.json'
}

function collect(schema, required, enums, seen = new Set()) {
  if (schema === null || typeof schema !== 'object' || Array.isArray(schema)) return
  if (seen.has(schema)) return
  seen.add(schema)
  for (const name of schema.required ?? []) required.add(name)
  for (const [key, child] of Object.entries(schema.properties ?? {})) {
    if (Array.isArray(child.enum)) {
      for (const value of child.enum) {
        if (value !== null) enums.add(`${key}${value}`)
      }
    }
    collect(child, required, enums, seen)
  }
  if (schema.items) collect(schema.items, required, enums, seen)
  for (const child of Object.values(schema.$defs ?? {})) collect(child, required, enums, seen)
  for (const key of ['if', 'then', 'else']) {
    if (schema[key]) collect(schema[key], required, enums, seen)
  }
}

let failures = 0
for (const [dir, schemaFile] of Object.entries(DIR_TO_SCHEMA)) {
  const schema = JSON.parse(readFileSync(path.join(schemasDir, schemaFile), 'utf8'))
  const required = new Set()
  const enums = new Set()
  collect(schema, required, enums)

  const invalidDir = path.join(fixturesDir, dir, 'invalid')
  let reasons = ''
  if (existsSync(invalidDir)) {
    for (const entry of readdirSync(invalidDir)) {
      if (entry.endsWith('.reason')) reasons += `${readFileSync(path.join(invalidDir, entry), 'utf8')}\n`
    }
  }

  for (const name of required) {
    if (!reasons.includes(`missing required property ${name}`)) {
      console.error(`FAIL: ${schemaFile}: no invalid fixture covers missing required property '${name}'`)
      failures += 1
    }
  }
  for (const pair of enums) {
    const [key] = pair.split('')
    if (!(reasons.includes('must be one of') && reasons.includes(key))) {
      console.error(`FAIL: ${schemaFile}: no invalid fixture covers an enum violation on '${key}'`)
      failures += 1
    }
  }
  if (failures === 0) console.log(`PASS: ${schemaFile} required/enum coverage complete`)
}
process.exit(failures === 0 ? 0 : 1)
NODE

echo "result schemas conformance OK"
