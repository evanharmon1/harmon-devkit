#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { createSchemaValidator } from './lib/json-schema-subset.mjs'

// REPO_ROOT — resolved from this script's own location, not the caller's cwd,
// so a role/finder's repo-relative result_schema path (e.g.
// "ai/schemas/result.challenger.schema.json") checks against the real schema
// tree even when the registry document under validation lives in a tmpdir
// copy (scripts/test-agent-registry.sh's mutation tests) or an unrelated cwd.
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

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

  // ── roles[] (specs/dev-flow-v2.md 'Roles and authority', #635) ──────────
  const WRITE_RESTRICTED_ROLES = new Set(['challenger', 'reviewer', 'integrator'])
  const REQUIRED_ROLE_SLUGS = ['orchestrator', 'implementer', 'challenger', 'reviewer', 'integrator']
  const roleBySlug = new Map(registry.roles.map((role) => [role.slug, role]))

  for (const required of REQUIRED_ROLE_SLUGS) {
    if (!roleBySlug.has(required)) semanticError(`roles[] is missing required role ${required}`)
  }
  for (const slug of duplicateSlugs(registry.roles)) {
    semanticError(`duplicate role slug: ${slug}`)
  }
  for (const role of registry.roles) {
    if (role.slug === 'orchestrator') {
      if (role.result_schema !== null) {
        semanticError('role orchestrator returns no result and must have result_schema: null')
      }
    } else {
      // Bound to the role's OWN slug, not merely "non-null and some existing
      // file" — the latter would accept e.g. challenger.result_schema
      // pointing at result.implementer.schema.json, letting a payload with
      // no finding core satisfy the challenge stage's own role contract.
      const expected = `ai/schemas/result.${role.slug}.schema.json`
      if (role.result_schema !== expected) {
        semanticError(`role ${role.slug} must name its own result schema (${expected}), found ${role.result_schema}`)
      } else if (!fs.existsSync(path.join(REPO_ROOT, role.result_schema))) {
        // Defense in depth, not reachable via a registry-only mutation now
        // that the branch above pins the value to the role's own slug: every
        // enum member IS one of today's real files by construction, so this
        // only fires if a future change deletes/renames that file on disk
        // without updating the registry to match.
        semanticError(`role ${role.slug} names result_schema ${role.result_schema}, which does not exist`)
      }
    }
    // challenger and reviewer write nothing outside their own result:
    // writes must be empty. integrator is ALSO write-restricted (no ambient
    // writes) but not "no writes at all" — it is limited to its two brokered
    // actions, so its writes must be non-empty, same as orchestrator and
    // implementer's real, unrestricted write boundaries.
    const mustBeEmpty = role.slug === 'challenger' || role.slug === 'reviewer'
    if (mustBeEmpty && role.writes.length !== 0) {
      semanticError(`role ${role.slug} must declare no external writes (writes: [])`)
    }
    if (!mustBeEmpty && role.writes.length === 0) {
      semanticError(`role ${role.slug} must declare its permitted external writes (writes must be non-empty)`)
    }
  }

  // ── finders[] (docs/glossary.md 'finder', #635) ──────────────────────────
  const PRE_PR_STAGES = new Set(['challenge', 'review'])
  const ROLE_STAGE_AFFINITY = { challenger: 'challenge', reviewer: 'review', integrator: 'integration' }

  for (const slug of duplicateSlugs(registry.finders)) {
    semanticError(`duplicate finder slug: ${slug}`)
  }
  for (const finder of registry.finders) {
    if (finder.surface === 'pr-cloud') {
      if (finder.stages.some((stage) => PRE_PR_STAGES.has(stage))) {
        semanticError(
          `finder ${finder.slug} has surface pr-cloud but is configured for a pre-PR stage (${finder.stages.filter((s) => PRE_PR_STAGES.has(s)).join(', ')}) — a PR-only finder cannot serve a stage that runs before a PR exists`
        )
      }
      if (finder.invocation !== null) {
        semanticError(`finder ${finder.slug} has surface pr-cloud but declares an invocation — pr-cloud finders are collected, never invoked`)
      }
      if (finder.collection === null) {
        semanticError(`finder ${finder.slug} has surface pr-cloud but no collection protocol`)
      }
      if (finder.trusted_actor_id === null) {
        semanticError(`finder ${finder.slug} has surface pr-cloud but no trusted_actor_id — a collected finder needs an immutable actor identity`)
      }
    } else if (finder.surface === 'local-cli') {
      if (finder.collection !== null) {
        semanticError(`finder ${finder.slug} has surface local-cli but declares a collection protocol — local-cli finders are invoked, never collected`)
      }
      if (finder.invocation === null) {
        semanticError(`finder ${finder.slug} has surface local-cli but no invocation`)
      }
      if (finder.trusted_actor_id !== null) {
        semanticError(`finder ${finder.slug} has surface local-cli but declares trusted_actor_id — a local-cli finder's output is the direct return of a locally-run harness, not a scraped remote identity`)
      }
    }
    if ((finder.trusted_actor_id === null) !== (finder.trusted_actor_login === null)) {
      semanticError(`finder ${finder.slug} must set trusted_actor_id and trusted_actor_login together (both null or both present)`)
    }
    // Digits-only shape, checked here rather than a schema `pattern`: the
    // breakdown skill's independent, more restrictive schema-subset engine
    // (for validating a fetched remote repo's registry) only permits a fixed,
    // pre-vetted allowlist of pattern strings, and a GitHub actor id has no
    // fixed enum to fall back on the way result_schema/role do.
    if (typeof finder.trusted_actor_id === 'string' && !/^[1-9][0-9]*$/.test(finder.trusted_actor_id)) {
      semanticError(`finder ${finder.slug} trusted_actor_id must be a digits-only GitHub actor id: ${finder.trusted_actor_id}`)
    }
    if (finder.role !== null) {
      const role = roleBySlug.get(finder.role)
      if (!role) {
        semanticError(`finder ${finder.slug} names unknown role ${finder.role}`)
      } else {
        if (finder.result_schema !== role.result_schema) {
          semanticError(
            `finder ${finder.slug} declares role ${finder.role} but result_schema ${finder.result_schema} does not match that role's own result_schema ${role.result_schema}`
          )
        }
        const requiredStage = ROLE_STAGE_AFFINITY[finder.role]
        if (requiredStage && finder.stages.some((stage) => stage !== requiredStage)) {
          semanticError(
            `finder ${finder.slug} declares role ${finder.role} but is configured for a stage outside that role's own affinity (${finder.stages.join(', ')}, expected only ${requiredStage})`
          )
        }
      }
    }
  }

  // ── model tiers (specs/dev-flow-v2.md 'Model strata live in registry
  // inventory', #635) — group every model by (family, tier); a rung with more
  // than one model needs exactly one default, a singleton rung needs none. ──
  for (const family of registry.families) {
    const rungs = new Map()
    for (const model of family.models) {
      const key = model.tier
      const rung = rungs.get(key) ?? []
      rung.push(model)
      rungs.set(key, rung)
    }
    for (const [tier, models] of rungs) {
      const defaults = models.filter((model) => model.default === true)
      if (models.length > 1 && defaults.length === 0) {
        semanticError(
          `family ${family.slug} has ${models.length} models at tier ${tier} (${models.map((m) => m.slug).join(', ')}) and none is marked default`
        )
      } else if (defaults.length > 1) {
        semanticError(
          `family ${family.slug} has ${defaults.length} default models at tier ${tier} (${defaults.map((m) => m.slug).join(', ')}) — at most one may be default`
        )
      }
    }
  }

  // ── harness write-restriction (specs/dev-flow-v2.md 'Write boundaries are
  // enforced capabilities', #635): a harness cannot be trusted to dispatch a
  // write-restricted role unless it can deny ambient writes. ──────────────
  for (const harness of registry.harnesses) {
    if (!harness.can_restrict_writes) {
      const restricted = harness.roles.filter((role) => WRITE_RESTRICTED_ROLES.has(role))
      if (restricted.length > 0) {
        semanticError(
          `harness ${harness.slug} declares role(s) ${restricted.join(', ')} but can_restrict_writes is false — a harness that cannot deny ambient writes must not dispatch a write-restricted role`
        )
      }
    }
  }
}

if (errors.length > 0) {
  for (const error of errors) console.error(`FAIL: ${error}`)
  process.exit(1)
}

console.log(
  `agent registry OK: ${registry.families.length} families, ${registry.harnesses.length} harnesses, ${registry.foreman_adapters.length} Foreman adapters`
)
