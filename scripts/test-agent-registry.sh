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
const family = (slug) => registry.families.find((entry) => entry.slug === slug)
const harness = (slug) => registry.harnesses.find((entry) => entry.slug === slug)
const role = (slug) => registry.roles.find((entry) => entry.slug === slug)
const finder = (slug) => registry.finders.find((entry) => entry.slug === slug)
const modelOf = (familySlug, modelSlug) => family(familySlug).models.find((m) => m.slug === modelSlug)

switch (mutation) {
  case 'duplicate-family':
    registry.families.push(structuredClone(registry.families[0]))
    break
  case 'duplicate-harness':
    registry.harnesses.push(structuredClone(registry.harnesses[0]))
    break
  case 'duplicate-legacy-claim-label':
    family('gpt').legacy_claim_labels = ['agent:claude-code']
    break
  case 'overlong-legacy-claim-label':
    family('gpt').legacy_claim_labels = [`agent:${'a'.repeat(45)}`]
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
  // ── roles[] (#635) ─────────────────────────────────────────────────────
  case 'missing-required-role':
    registry.roles = registry.roles.filter((entry) => entry.slug !== 'challenger')
    break
  case 'duplicate-role-slug':
    registry.roles.push(structuredClone(role('reviewer')))
    break
  case 'orchestrator-with-result-schema':
    role('orchestrator').result_schema = 'ai/schemas/result.implementer.schema.json'
    break
  case 'role-missing-result-schema':
    role('implementer').result_schema = null
    break
  case 'role-result-schema-unknown-value':
    role('integrator').result_schema = 'ai/schemas/result.nonexistent.schema.json'
    break
  case 'role-result-schema-wrong-role':
    // A schema-legal value (it is one of the four enum members) that names a
    // DIFFERENT role's own schema — challenge-review#635's own finding: this
    // used to pass because the check only asked "non-null and exists",
    // never "matches this role's own slug".
    role('challenger').result_schema = 'ai/schemas/result.reviewer.schema.json'
    break
  case 'challenger-with-writes':
    role('challenger').writes = ['something it should never write']
    break
  case 'role-empty-writes':
    role('implementer').writes = []
    break
  // ── finders[] (#635) ───────────────────────────────────────────────────
  case 'duplicate-finder-slug':
    registry.finders.push(structuredClone(finder('codex-adversarial')))
    break
  case 'pr-cloud-finder-on-pre-pr-stage':
    finder('codex-cloud').stages = ['challenge', 'integration']
    break
  case 'pr-cloud-finder-with-invocation':
    finder('codex-cloud').invocation = { type: 'taskfile-target', target: 'bogus' }
    break
  case 'local-cli-finder-with-collection':
    finder('codex-adversarial').collection = { type: 'shepherd-checker', protocol: 'x' }
    break
  case 'local-cli-finder-with-trusted-actor':
    finder('codex-adversarial').trusted_actor_id = '1'
    finder('codex-adversarial').trusted_actor_login = 'someone'
    break
  case 'finder-mismatched-trusted-actor-pair':
    finder('codex-cloud').trusted_actor_login = null
    break
  case 'finder-non-numeric-trusted-actor-id':
    finder('codex-cloud').trusted_actor_id = 'chatgpt-codex-connector'
    break
  case 'finder-role-result-schema-mismatch':
    finder('codex-adversarial').result_schema = 'ai/schemas/result.reviewer.schema.json'
    break
  case 'finder-role-stage-affinity-violation':
    finder('codex-adversarial').stages = ['review']
    break
  // ── model tier defaults (#635) ─────────────────────────────────────────
  case 'tier-rung-no-default':
    delete modelOf('qwen', 'coder-plus').default
    break
  case 'tier-rung-multi-default':
    modelOf('qwen', 'coder-next').default = true
    break
  // ── harness write-restriction (#635) ────────────────────────────────────
  case 'harness-write-restricted-without-capability':
    harness('codex-cli').can_restrict_writes = false
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
rejects "legacy claim labels shared by two families" \
    'duplicate-legacy-claim-label' \
    'legacy claim label agent:claude-code is shared by families claude and gpt'
rejects "legacy claim labels over GitHub's limit" \
    'overlong-legacy-claim-label' \
    'must contain at most 50 character(s)'
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
rejects "roles[] missing a required role slug" \
    'missing-required-role' \
    'roles[] is missing required role challenger'
rejects "duplicate role slugs" \
    'duplicate-role-slug' \
    'duplicate role slug'
rejects "orchestrator declaring a result_schema" \
    'orchestrator-with-result-schema' \
    'role orchestrator returns no result and must have result_schema: null'
rejects "a non-orchestrator role with no result_schema" \
    'role-missing-result-schema' \
    'role implementer must name its own result schema'
rejects "a role naming a result_schema value outside the closed enum" \
    'role-result-schema-unknown-value' \
    'must be one of'
rejects "a role naming a different role's own result_schema" \
    'role-result-schema-wrong-role' \
    'must name its own result schema'
rejects "challenger declaring external writes" \
    'challenger-with-writes' \
    'role challenger must declare no external writes'
rejects "a non-write-restricted role with empty writes" \
    'role-empty-writes' \
    'role implementer must declare its permitted external writes'
rejects "duplicate finder slugs" \
    'duplicate-finder-slug' \
    'duplicate finder slug'
rejects "a pr-cloud finder configured for a pre-PR stage" \
    'pr-cloud-finder-on-pre-pr-stage' \
    'cannot serve a stage that runs before a PR exists'
rejects "a pr-cloud finder declaring an invocation" \
    'pr-cloud-finder-with-invocation' \
    'pr-cloud finders are collected, never invoked'
rejects "a local-cli finder declaring a collection protocol" \
    'local-cli-finder-with-collection' \
    'local-cli finders are invoked, never collected'
rejects "a local-cli finder declaring a trusted_actor_id" \
    'local-cli-finder-with-trusted-actor' \
    'not a scraped remote identity'
rejects "a finder with trusted_actor_id/login split (one null, one not)" \
    'finder-mismatched-trusted-actor-pair' \
    'must set trusted_actor_id and trusted_actor_login together'
rejects "a finder trusted_actor_id that is not digits-only" \
    'finder-non-numeric-trusted-actor-id' \
    'must be a digits-only GitHub actor id'
rejects "a finder whose result_schema disagrees with its declared role" \
    'finder-role-result-schema-mismatch' \
    "does not match that role's own result_schema"
rejects "a finder configured outside its declared role's stage affinity" \
    'finder-role-stage-affinity-violation' \
    "outside that role's own affinity"
rejects "a multi-model family-tier rung with no default" \
    'tier-rung-no-default' \
    'and none is marked default'
rejects "a multi-model family-tier rung with two defaults" \
    'tier-rung-multi-default' \
    'at most one may be default'
rejects "a write-restricted role on a harness that cannot restrict writes" \
    'harness-write-restricted-without-capability' \
    'must not dispatch a write-restricted role'

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

# --- Label provenance: tier:<role>:<tier> resolution (#635) ----------------
# specs/dev-flow-v2.md 'Labels resolve role names through the registry':
# resolveRoleTierLabel (scripts/lib/registry-roles.mjs) is imported directly
# rather than invoked as a CLI, so this exercises the exact function the
# orchestrator will later call, not a reimplementation of it.
node --input-type=module - "$registry" <<'NODE'
import { readFile } from 'node:fs/promises'
import { resolveRoleTierLabel, TIER_ORDER } from './scripts/lib/registry-roles.mjs'

const [registryPath] = process.argv.slice(2)
const registry = JSON.parse(await readFile(registryPath, 'utf8'))

let failures = 0
function expect(description, condition) {
  if (condition) {
    console.log(`PASS: ${description}`)
  } else {
    console.error(`FAIL: ${description}`)
    failures += 1
  }
}

const ok = resolveRoleTierLabel('tier:challenger:standard', registry)
expect('resolves a known role and tier', ok.ok === true && ok.role === 'challenger' && ok.tier === 'standard')

const unknownRole = resolveRoleTierLabel('tier:bogus:standard', registry)
expect(
  'rejects an unknown role',
  unknownRole.ok === false && unknownRole.error.includes('unknown role: bogus')
)

const unknownTier = resolveRoleTierLabel('tier:challenger:ultra', registry)
expect(
  'rejects an unknown tier',
  unknownTier.ok === false && unknownTier.error.includes('unknown tier: ultra')
)

const malformed = resolveRoleTierLabel('suggest:claude', registry)
expect('rejects a label that is not tier:<role>:<tier> shaped', malformed.ok === false)

expect(
  'TIER_ORDER excludes adaptive (a config resolution input, never a concrete tier)',
  !TIER_ORDER.includes('adaptive')
)

for (const requiredRole of ['orchestrator', 'implementer', 'challenger', 'reviewer', 'integrator']) {
  const resolved = resolveRoleTierLabel(`tier:${requiredRole}:standard`, registry)
  expect(`resolves every registry role (${requiredRole})`, resolved.ok === true)
}

process.exit(failures === 0 ? 0 : 1)
NODE

echo "agent registry mutation tests OK"
