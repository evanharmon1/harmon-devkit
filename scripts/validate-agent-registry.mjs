#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { createSchemaValidator } from './lib/json-schema-subset.mjs'

const registryPath = path.resolve(process.argv[2] ?? 'agent-registry.json')
const schemaPath = path.resolve(
  process.argv[3] ?? path.join(path.dirname(registryPath), 'agent-registry.schema.json')
)

function loadJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    console.error(`agent registry: cannot read valid JSON from ${file}: ${error.message}`)
    process.exit(1)
  }
}

const registry = loadJson(registryPath)
const schema = loadJson(schemaPath)
const errors = []
const engine = createSchemaValidator(schema)

try {
  engine.assertSupportedSchema(schema)
} catch (error) {
  console.error(`agent registry: invalid or unsupported schema: ${error.message}`)
  process.exit(1)
}

function duplicateSlugs(rows) {
  const seen = new Set()
  return rows.map((row) => row.slug).filter((slug) => seen.has(slug) || !seen.add(slug))
}

function semanticError(message) {
  errors.push(`registry: ${message}`)
}

errors.push(...engine.validate(registry, schema, '$registry'))

// Cross-record constraints cannot be expressed by the structural schema alone.
if (errors.length === 0) {
  const familySlugs = new Set(registry.families.map((family) => family.slug))
  const harnessSlugs = new Set(registry.harnesses.map((harness) => harness.slug))

  for (const slug of duplicateSlugs(registry.families))
    semanticError(`duplicate family slug: ${slug}`)
  for (const slug of duplicateSlugs(registry.harnesses))
    semanticError(`duplicate harness slug: ${slug}`)
  const legacyClaimOwners = new Map()
  for (const family of registry.families) {
    for (const label of family.legacy_claim_labels ?? []) {
      const owner = legacyClaimOwners.get(label)
      if (owner) {
        semanticError(
          `legacy claim label ${label} is shared by families ${owner} and ${family.slug}`
        )
      } else {
        legacyClaimOwners.set(label, family.slug)
      }
    }
  }
  for (const slug of duplicateSlugs(registry.foreman_adapters)) {
    semanticError(`duplicate Foreman adapter slug: ${slug}`)
  }

  for (const family of registry.families) {
    for (const slug of duplicateSlugs(family.models)) {
      semanticError(`family ${family.slug} has duplicate model slug: ${slug}`)
    }
    if (harnessSlugs.has(family.slug)) {
      semanticError(`slug ${family.slug} is both a model family and a harness`)
    }
  }

  for (const [name, namespace] of Object.entries(registry.labels)) {
    if (namespace.prefix !== name) semanticError(`${name} label prefix must be ${name}`)
    if (namespace.axis !== 'model') semanticError(`${name} labels must use the model axis`)
    if (!namespace.scopes.includes('family') || !namespace.scopes.includes('model')) {
      semanticError(`${name} labels must support family-level and optional model-level forms`)
    }
    if (namespace.arming !== false) semanticError(`${name} labels must never arm dispatch`)
  }

  for (const harness of registry.harnesses) {
    const constraint = harness.family_constraint
    if (constraint.kind === 'fixed') {
      if (!constraint.family) {
        semanticError(`harness ${harness.slug} has a fixed family constraint without a family`)
      } else if (!familySlugs.has(constraint.family)) {
        semanticError(`harness ${harness.slug} references unknown family ${constraint.family}`)
      }
      if (Object.hasOwn(constraint, 'default_family')) {
        semanticError(
          `harness ${harness.slug} has a default_family on a fixed constraint — fixed constraints use family, not default_family`
        )
      }
    } else if (constraint.kind === 'broker') {
      if (Object.hasOwn(constraint, 'family')) {
        semanticError(
          `harness ${harness.slug} has family ${constraint.family} on a broker constraint — did you mean default_family?`
        )
      }
      if (
        Object.hasOwn(constraint, 'default_family') &&
        !familySlugs.has(constraint.default_family)
      ) {
        semanticError(
          `harness ${harness.slug} broker default_family references unknown family ${constraint.default_family}`
        )
      }
    }

    // Provider-rewired harnesses are named claude-code-<fixed-family>, optionally
    // with a -local suffix for a local-endpoint variant of the same family (ADR
    // 0005 D9 amendment) — claude-code-qwen-local stays fixed to family "qwen",
    // not a separate "qwen-local" family.
    if (harness.provider_rewired) {
      const expected = constraint.kind === 'fixed' ? `claude-code-${constraint.family}` : null
      if (
        constraint.kind !== 'fixed' ||
        (harness.slug !== expected && harness.slug !== `${expected}-local`)
      ) {
        semanticError(
          `provider-rewired harness ${harness.slug} must be named claude-code-<fixed-family> or claude-code-<fixed-family>-local`
        )
      }
      if (harness.model_resolution.owner !== 'provider-wrapper') {
        semanticError(
          `provider-rewired harness ${harness.slug} must delegate model resolution to provider-wrapper`
        )
      }
    } else if (harness.model_resolution.owner === 'provider-wrapper') {
      semanticError(
        `non-rewired harness ${harness.slug} cannot delegate model resolution to provider-wrapper`
      )
    }
  }

  for (const adapter of registry.foreman_adapters) {
    if (adapter.harness !== null && !harnessSlugs.has(adapter.harness)) {
      semanticError(`Foreman adapter ${adapter.slug} maps unknown harness ${adapter.harness}`)
    }
    if (adapter.production_dispatchable) {
      if (adapter.classification !== 'production' || adapter.harness === null) {
        semanticError(
          `production-dispatchable Foreman adapter ${adapter.slug} needs a production harness mapping`
        )
      }
      if (!adapter.provision_label) {
        semanticError(
          `production-dispatchable Foreman adapter ${adapter.slug} must provision its selector label`
        )
      }
    }
    if (adapter.classification === 'test-only') {
      if (adapter.production_dispatchable || adapter.provision_label) {
        semanticError(
          `test-only Foreman adapter ${adapter.slug} cannot dispatch or provision a public label`
        )
      }
    }
    if (adapter.provision_label && !adapter.production_dispatchable) {
      semanticError(
        `Foreman adapter ${adapter.slug} cannot provision a label unless it is production-dispatchable`
      )
    }
  }

  const mock = registry.foreman_adapters.find((adapter) => adapter.slug === 'mock')
  if (
    !mock ||
    mock.source_file !== 'mock.sh' ||
    mock.classification !== 'test-only' ||
    mock.harness !== null ||
    mock.production_dispatchable ||
    mock.provision_label
  ) {
    semanticError('mock must be a mapped file-only, test-only, non-provisionable Foreman adapter')
  }

  const claude = registry.foreman_adapters.find((adapter) => adapter.slug === 'claude')
  if (!claude || claude.harness !== 'claude-code' || claude.source_file !== 'claude.sh') {
    semanticError('legacy Foreman adapter claude must map claude.sh to harness claude-code')
  }
  if (
    !claude ||
    claude.classification !== 'production' ||
    !claude.production_dispatchable ||
    !claude.provision_label
  ) {
    semanticError('legacy Foreman adapter claude must be production-dispatchable and provisionable')
  }

  const minimax = registry.harnesses.find((harness) => harness.slug === 'claude-code-minimax')
  if (
    !familySlugs.has('minimax') ||
    !minimax ||
    minimax.family_constraint.kind !== 'fixed' ||
    minimax.family_constraint.family !== 'minimax' ||
    !minimax.provider_rewired
  ) {
    semanticError(
      'MiniMax must use family minimax and provider-rewired harness claude-code-minimax'
    )
  }
}

if (errors.length > 0) {
  for (const error of errors) console.error(`FAIL: ${error}`)
  process.exit(1)
}

console.log(
  `agent registry OK: ${registry.families.length} families, ${registry.harnesses.length} harnesses, ${registry.foreman_adapters.length} Foreman adapters`
)
