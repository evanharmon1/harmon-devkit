#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

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

const supportedSchemaKeywords = new Set([
  '$schema',
  '$id',
  '$defs',
  '$ref',
  'title',
  'description',
  '$comment',
  'type',
  'const',
  'enum',
  'minLength',
  'pattern',
  'minItems',
  'uniqueItems',
  'items',
  'required',
  'properties',
  'additionalProperties'
])

const supportedInstanceTypes = new Set([
  'array',
  'boolean',
  'integer',
  'null',
  'number',
  'object',
  'string'
])

function schemaError(location, keyword, expectation) {
  throw new Error(`${location}.${keyword}: ${expectation}`)
}

function isSchemaObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function assertSchemaKeywordValues(rule, location) {
  for (const keyword of ['$schema', '$id', '$ref', 'title', 'description', '$comment']) {
    if (Object.hasOwn(rule, keyword) && typeof rule[keyword] !== 'string') {
      schemaError(location, keyword, 'must be a string')
    }
  }
  for (const keyword of ['$schema', '$id', '$ref']) {
    if (Object.hasOwn(rule, keyword) && rule[keyword].length === 0) {
      schemaError(location, keyword, 'must not be empty')
    }
  }

  if (Object.hasOwn(rule, 'type')) {
    const types = Array.isArray(rule.type) ? rule.type : [rule.type]
    if (
      types.length === 0 ||
      types.some((type) => typeof type !== 'string' || !supportedInstanceTypes.has(type)) ||
      new Set(types).size !== types.length
    ) {
      schemaError(location, 'type', 'must name one or more unique supported instance types')
    }
  }

  if (Object.hasOwn(rule, 'enum')) {
    if (!Array.isArray(rule.enum) || rule.enum.length === 0) {
      schemaError(location, 'enum', 'must be a non-empty array')
    }
    if (
      rule.enum.some((candidate, index) =>
        rule.enum.slice(0, index).some((earlier) => jsonEqual(candidate, earlier))
      )
    ) {
      schemaError(location, 'enum', 'must contain unique values')
    }
  }

  for (const keyword of ['minLength', 'minItems']) {
    if (Object.hasOwn(rule, keyword) && (!Number.isInteger(rule[keyword]) || rule[keyword] < 0)) {
      schemaError(location, keyword, 'must be a non-negative integer')
    }
  }

  if (Object.hasOwn(rule, 'pattern')) {
    if (typeof rule.pattern !== 'string') schemaError(location, 'pattern', 'must be a string')
    try {
      new RegExp(rule.pattern, 'u')
    } catch {
      schemaError(location, 'pattern', 'must be a valid regular expression')
    }
  }

  if (Object.hasOwn(rule, 'uniqueItems') && typeof rule.uniqueItems !== 'boolean') {
    schemaError(location, 'uniqueItems', 'must be a boolean')
  }
  if (Object.hasOwn(rule, 'required')) {
    if (
      !Array.isArray(rule.required) ||
      rule.required.some((name) => typeof name !== 'string') ||
      new Set(rule.required).size !== rule.required.length
    ) {
      schemaError(location, 'required', 'must be an array of unique strings')
    }
  }
  for (const keyword of ['$defs', 'properties']) {
    if (
      Object.hasOwn(rule, keyword) &&
      (rule[keyword] === null || typeof rule[keyword] !== 'object' || Array.isArray(rule[keyword]))
    ) {
      schemaError(location, keyword, 'must be an object')
    }
  }
  if (
    Object.hasOwn(rule, 'additionalProperties') &&
    typeof rule.additionalProperties !== 'boolean'
  ) {
    schemaError(location, 'additionalProperties', 'must be a boolean')
  }
}

function assertSupportedSchema(
  rule,
  location = '$schema',
  audit = { active: new Set(), complete: new Set() }
) {
  if (rule === null || typeof rule !== 'object' || Array.isArray(rule)) {
    throw new Error(`${location}: boolean and non-object schemas are not supported`)
  }
  if (audit.active.has(rule)) {
    throw new Error(`${location}: cyclic schema references are not supported`)
  }
  if (audit.complete.has(rule)) return

  audit.active.add(rule)
  for (const keyword of Object.keys(rule)) {
    if (!supportedSchemaKeywords.has(keyword)) {
      throw new Error(`${location}: unsupported schema keyword ${keyword}`)
    }
  }
  assertSchemaKeywordValues(rule, location)
  if (Object.hasOwn(rule, '$ref') && Object.keys(rule).some((keyword) => keyword !== '$ref')) {
    throw new Error(`${location}: schema keywords alongside $ref are not supported`)
  }
  if (Object.hasOwn(rule, '$ref')) {
    const target = resolveRef(rule.$ref)
    if (!isSchemaObject(target)) {
      throw new Error(
        `${location}: schema reference ${rule.$ref} does not resolve to an object schema`
      )
    }
    assertSupportedSchema(target, `${location}.$ref(${rule.$ref})`, audit)
  }
  for (const [name, child] of Object.entries(rule.$defs ?? {})) {
    assertSupportedSchema(child, `${location}.$defs.${name}`, audit)
  }
  for (const [name, child] of Object.entries(rule.properties ?? {})) {
    assertSupportedSchema(child, `${location}.properties.${name}`, audit)
  }
  if (Object.hasOwn(rule, 'items')) assertSupportedSchema(rule.items, `${location}.items`, audit)
  audit.active.delete(rule)
  audit.complete.add(rule)
}

try {
  assertSupportedSchema(schema)
} catch (error) {
  console.error(`agent registry: invalid or unsupported schema: ${error.message}`)
  process.exit(1)
}

function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`

  return `{${Object.keys(value)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
    .join(',')}}`
}

function jsonEqual(left, right) {
  return canonicalJson(left) === canonicalJson(right)
}

function satisfiesMinLength(value, minimum) {
  let length = 0
  const codePoints = value[Symbol.iterator]()
  while (length < minimum && !codePoints.next().done) {
    length += 1
  }
  return length >= minimum
}

function instanceType(value) {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  if (Number.isInteger(value)) return 'integer'
  return typeof value
}

function resolveRef(ref) {
  if (!ref.startsWith('#/')) throw new Error(`unsupported schema reference: ${ref}`)
  return ref
    .slice(2)
    .split('/')
    .map((part) => part.replaceAll('~1', '/').replaceAll('~0', '~'))
    .reduce((node, part) => {
      if (node === null || typeof node !== 'object' || !Object.hasOwn(node, part)) {
        return undefined
      }
      return node[part]
    }, schema)
}

function validateSchema(value, rule, location) {
  if (Object.hasOwn(rule, '$ref')) {
    const target = resolveRef(rule.$ref)
    if (!isSchemaObject(target)) {
      errors.push(`${location}: schema reference ${rule.$ref} does not resolve to an object schema`)
      return
    }
    validateSchema(value, target, location)
    return
  }

  if (Object.hasOwn(rule, 'const') && !jsonEqual(value, rule.const)) {
    errors.push(`${location}: must equal ${JSON.stringify(rule.const)}`)
  }
  if (rule.enum && !rule.enum.some((candidate) => jsonEqual(value, candidate))) {
    errors.push(`${location}: must be one of ${rule.enum.map(JSON.stringify).join(', ')}`)
  }

  if (rule.type) {
    const allowed = Array.isArray(rule.type) ? rule.type : [rule.type]
    const actual = instanceType(value)
    const integerSatisfiesNumber = actual === 'integer' && allowed.includes('number')
    if (!allowed.includes(actual) && !integerSatisfiesNumber) {
      errors.push(`${location}: expected ${allowed.join(' or ')}, found ${actual}`)
      return
    }
  }

  if (typeof value === 'string') {
    if (rule.minLength !== undefined && !satisfiesMinLength(value, rule.minLength)) {
      errors.push(`${location}: must contain at least ${rule.minLength} character(s)`)
    }
    if (rule.pattern && !new RegExp(rule.pattern, 'u').test(value)) {
      errors.push(`${location}: does not match ${rule.pattern}`)
    }
  }

  if (Array.isArray(value)) {
    if (rule.minItems !== undefined && value.length < rule.minItems) {
      errors.push(`${location}: must contain at least ${rule.minItems} item(s)`)
    }
    if (rule.uniqueItems) {
      const canonicalItems = value.map(canonicalJson)
      if (new Set(canonicalItems).size !== canonicalItems.length) {
        errors.push(`${location}: items must be unique`)
      }
    }
    if (rule.items) {
      value.forEach((item, index) => validateSchema(item, rule.items, `${location}[${index}]`))
    }
  }

  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    for (const required of rule.required ?? []) {
      if (!Object.hasOwn(value, required))
        errors.push(`${location}: missing required property ${required}`)
    }
    if (rule.additionalProperties === false) {
      for (const key of Object.keys(value)) {
        if (!Object.hasOwn(rule.properties ?? {}, key)) {
          errors.push(`${location}: unexpected property ${key}`)
        }
      }
    }
    for (const [key, childRule] of Object.entries(rule.properties ?? {})) {
      if (Object.hasOwn(value, key)) validateSchema(value[key], childRule, `${location}.${key}`)
    }
  }
}

function duplicateSlugs(rows) {
  const seen = new Set()
  return rows.map((row) => row.slug).filter((slug) => seen.has(slug) || !seen.add(slug))
}

function semanticError(message) {
  errors.push(`registry: ${message}`)
}

validateSchema(registry, schema, '$registry')

// Cross-record constraints cannot be expressed by the structural schema alone.
if (errors.length === 0) {
  const familySlugs = new Set(registry.families.map((family) => family.slug))
  const harnessSlugs = new Set(registry.harnesses.map((harness) => harness.slug))

  for (const slug of duplicateSlugs(registry.families))
    semanticError(`duplicate family slug: ${slug}`)
  for (const slug of duplicateSlugs(registry.harnesses))
    semanticError(`duplicate harness slug: ${slug}`)
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
    } else if (Object.hasOwn(constraint, 'family')) {
      semanticError(
        `harness ${harness.slug} has family ${constraint.family} with a none constraint`
      )
    }

    if (harness.provider_rewired) {
      if (constraint.kind !== 'fixed' || harness.slug !== `claude-code-${constraint.family}`) {
        semanticError(
          `provider-rewired harness ${harness.slug} must be named claude-code-<fixed-family>`
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
