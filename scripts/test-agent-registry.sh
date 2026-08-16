#!/usr/bin/env bash
# test-agent-registry.sh — schema-check the registry and exercise semantic guards.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

registry="${1:-agent-registry.json}"
schema="${2:-agent-registry.schema.json}"
validator="scripts/validate-agent-registry.mjs"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

for required in "$registry" "$schema" "$validator"; do
    [ -f "$required" ] || fail "missing required registry asset: $required"
done
command -v node >/dev/null 2>&1 || fail "node is required to validate the agent registry"

node "$validator" "$registry" "$schema"

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
mutated="${test_tmp}/agent-registry.json"
mutated_schema="${test_tmp}/agent-registry.schema.json"

rejects() {
    local description="$1"
    local mutation="$2"
    local expected="$3"
    local output

    if ! node --input-type=module - "$registry" "$mutated" "$mutation" <<'NODE'; then
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath, mutation] = process.argv.slice(2)
const registry = JSON.parse(await readFile(inputPath, 'utf8'))
const adapter = (slug) => registry.foreman_adapters.find((entry) => entry.slug === slug)
const harness = (slug) => registry.harnesses.find((entry) => entry.slug === slug)

switch (mutation) {
  case 'duplicate-family':
    registry.families.push(structuredClone(registry.families[0]))
    break
  case 'duplicate-harness':
    registry.harnesses.push(structuredClone(registry.harnesses[0]))
    break
  case 'missing-model-owner':
    delete registry.harnesses[0].model_resolution.owner
    break
  case 'unknown-fixed-family':
    registry.harnesses[0].family_constraint.family = 'unknown'
    break
  case 'family-on-broker':
    for (const entry of registry.harnesses) {
      if (entry.family_constraint.kind === 'broker') entry.family_constraint.family = 'claude'
    }
    break
  case 'unknown-default-family':
    for (const entry of registry.harnesses) {
      if (entry.family_constraint.kind === 'broker') {
        entry.family_constraint.default_family = 'unknown'
        break
      }
    }
    break
  case 'default-family-on-fixed':
    registry.harnesses[0].family_constraint.default_family = 'claude'
    break
  case 'bad-local-suffix':
    harness('claude-code-minimax').slug = 'claude-code-minimax-local-extra'
    break
  case 'production-without-harness':
    adapter('claude').harness = null
    break
  case 'harness-axis':
    registry.labels.suggest.axis = 'harness'
    break
  case 'public-mock':
    adapter('mock').provision_label = true
    break
  case 'bad-minimax-slug':
    harness('claude-code-minimax').slug = 'claude-code-mini'
    break
  case 'bad-claude-harness':
    adapter('claude').harness = 'qwen-code'
    break
  case 'non-production-claude':
    Object.assign(adapter('claude'), {
      classification: 'test-only',
      production_dispatchable: false,
      provision_label: false
    })
    break
  case 'overlong-display-name':
    // 65 chars: one over the family bound (64, from the longest description
    // wrapper) — the schema's maxLength must reject it declaratively (#680).
    registry.families[0].display_name = 'X'.repeat(65)
    break
  case 'overlong-adapter-display-name':
    // 48 chars: inside the shared 50 cap but over the adapter-specific 47 —
    // the foreman description wrapper is the longest, so the adapter bound is
    // tighter and needs its own declarative limit.
    adapter('claude').display_name = 'X'.repeat(48)
    break
  default:
    throw new Error(`unknown mutation: ${mutation}`)
}

await writeFile(outputPath, `${JSON.stringify(registry, null, 2)}\n`)
NODE
        fail "could not build mutation: $description"
    fi
    if output="$(node "$validator" "$mutated" "$schema" 2>&1)"; then
        fail "validator accepted mutation: $description"
    fi
    case "$output" in
    *"$expected"*) ;;
    *) fail "$description failed for the wrong reason: $output" ;;
    esac
    echo "PASS: rejects $description"
}

build_schema_case() {
    local mutation="$1"

    node --input-type=module - \
        "$registry" "$schema" "$mutated" "$mutated_schema" "$mutation" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [registryInput, schemaInput, registryOutput, schemaOutput, mutation] =
  process.argv.slice(2)
const registry = JSON.parse(await readFile(registryInput, 'utf8'))
const schema = JSON.parse(await readFile(schemaInput, 'utf8'))
const instanceObject = { alpha: 1, beta: 2 }
const reorderedObject = { beta: 2, alpha: 1 }

switch (mutation) {
  case 'reordered-const':
    registry.schema_version = instanceObject
    schema.properties.schema_version = { const: reorderedObject }
    break
  case 'reordered-enum':
    registry.schema_version = instanceObject
    schema.properties.schema_version = { enum: [reorderedObject] }
    break
  case 'reordered-enum-duplicates':
    schema.properties.schema_version = { enum: [instanceObject, reorderedObject] }
    break
  case 'reordered-unique-items':
    registry.schema_version = [instanceObject, reorderedObject]
    schema.properties.schema_version = { type: 'array', uniqueItems: true }
    break
  case 'distinct-unique-items':
    registry.schema_version = [{ value: 1 }, { value: '1' }]
    schema.properties.schema_version = { type: 'array', uniqueItems: true }
    break
  case 'unicode-min-length':
    registry.schema_version = '😀'
    schema.properties.schema_version = { type: 'string', minLength: 2 }
    break
  case 'unicode-min-length-exact':
    registry.schema_version = '😀x'
    schema.properties.schema_version = { type: 'string', minLength: 2 }
    break
  default:
    throw new Error(`unknown schema mutation: ${mutation}`)
}

await writeFile(registryOutput, `${JSON.stringify(registry, null, 2)}\n`)
await writeFile(schemaOutput, `${JSON.stringify(schema, null, 2)}\n`)
NODE
}

accepts_schema_case() {
    local description="$1"
    local mutation="$2"
    local output

    build_schema_case "$mutation"
    if ! output="$(node "$validator" "$mutated" "$mutated_schema" 2>&1)"; then
        fail "validator rejected $description: $output"
    fi
    echo "PASS: accepts $description"
}

rejects_schema_case() {
    local description="$1"
    local mutation="$2"
    local expected="$3"
    local output

    build_schema_case "$mutation"
    if output="$(node "$validator" "$mutated" "$mutated_schema" 2>&1)"; then
        fail "validator accepted $description"
    fi
    case "$output" in
    *"$expected"*) ;;
    *) fail "$description failed for the wrong reason: $output" ;;
    esac
    echo "PASS: rejects $description"
}

rejects "duplicate family slugs" \
    'duplicate-family' \
    'duplicate family slug'
rejects "duplicate harness slugs" \
    'duplicate-harness' \
    'duplicate harness slug'
rejects "missing model-resolution ownership" \
    'missing-model-owner' \
    'missing required property owner'
rejects "unknown fixed-family constraints" \
    'unknown-fixed-family' \
    'references unknown family unknown'
rejects "family values on broker harnesses" \
    'family-on-broker' \
    'did you mean default_family'
rejects "a broker default_family referencing an unknown family" \
    'unknown-default-family' \
    'default_family references unknown family unknown'
rejects "a default_family on a fixed constraint" \
    'default-family-on-fixed' \
    'default_family on a fixed constraint'
rejects "a provider-rewired harness slug with an unsanctioned suffix" \
    'bad-local-suffix' \
    'must be named claude-code-<fixed-family> or claude-code-<fixed-family>-local'
rejects "production adapters without a harness mapping" \
    'production-without-harness' \
    'needs a production harness mapping'
rejects "harness-centric suggestion labels" \
    'harness-axis' \
    'must equal "model"'
rejects "public labels for the test-only mock adapter" \
    'public-mock' \
    'test-only Foreman adapter mock cannot dispatch or provision a public label'
rejects "a non-normalized MiniMax harness slug" \
    'bad-minimax-slug' \
    'must be named claude-code-<fixed-family>'
rejects "a legacy claude adapter mapped to the wrong harness" \
    'bad-claude-harness' \
    'legacy Foreman adapter claude must map claude.sh to harness claude-code'
rejects "a non-production legacy claude adapter" \
    'non-production-claude' \
    'legacy Foreman adapter claude must be production-dispatchable and provisionable'
rejects "a display_name over the schema's declarative length cap" \
    'overlong-display-name' \
    'must contain at most 64 character(s)'
rejects "an adapter display_name over its tighter 47-char cap" \
    'overlong-adapter-display-name' \
    'must contain at most 47 character(s)'

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.minProperties = 99
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted an unsupported schema keyword"
fi
case "$output" in
*'unsupported schema keyword minProperties'*) ;;
*) fail "unsupported schema keyword failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects unsupported schema keywords"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.$defs.model.properties.display_name.minLength = 'one'
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted a malformed minLength value"
fi
case "$output" in
*'minLength: must be a non-negative integer'*) ;;
*) fail "malformed minLength failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects malformed supported schema keyword values"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.$defs.model.properties.display_name = {
  $ref: '#/properties/schema_version/const'
}
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted a reference to a primitive schema node"
fi
case "$output" in
*'does not resolve to an object schema'*) ;;
*) fail "primitive schema reference failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects references to primitive schema nodes"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.$defs.model.properties.display_name = {
  $ref: '#/__proto__'
}
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted an inherited schema reference target"
fi
case "$output" in
*'does not resolve to an object schema'*) ;;
*) fail "inherited schema reference failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects inherited properties while resolving references"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.$defs.model.properties.display_name = {
  $ref: '#/$defs/model/properties'
}
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted a reference to a schema-container object"
fi
case "$output" in
*'unsupported schema keyword slug'*) ;;
*) fail "schema-container reference failed for the wrong reason: $output" ;;
esac
echo "PASS: audits resolved reference targets as schemas"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.$defs.cycle = { $ref: '#/$defs/cycle' }
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted a cyclic schema reference"
fi
case "$output" in
*'cyclic schema references are not supported'*) ;;
*) fail "cyclic schema reference failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects cyclic schema references without recursing forever"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.properties.schema_version = { type: 'number' }
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if ! output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator rejected an integer instance under a number schema: $output"
fi
echo "PASS: accepts integer instances under number schemas"

accepts_schema_case \
    "structurally equal const objects with reordered properties" \
    'reordered-const'
accepts_schema_case \
    "structurally equal enum objects with reordered properties" \
    'reordered-enum'
rejects_schema_case \
    "structurally duplicate enum objects with reordered properties" \
    'reordered-enum-duplicates' \
    'enum: must contain unique values'
rejects_schema_case \
    "structurally duplicate uniqueItems objects with reordered properties" \
    'reordered-unique-items' \
    'items must be unique'
accepts_schema_case \
    "structurally distinct uniqueItems values" \
    'distinct-unique-items'
rejects_schema_case \
    "one Unicode code point under minLength 2" \
    'unicode-min-length' \
    'must contain at least 2 character(s)'
accepts_schema_case \
    "two Unicode code points at minLength 2" \
    'unicode-min-length-exact'

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.properties.families.items = false
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted a boolean items schema"
fi
case "$output" in
*'boolean and non-object schemas are not supported'*) ;;
*) fail "boolean items schema failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects boolean items schemas"

echo "agent registry mutation tests OK"
