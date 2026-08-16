#!/usr/bin/env node
// validate-label-registry.mjs — schema-check label-registry.json and enforce the
// cross-record invariants the structural schema cannot express. Self-contained
// (no dependencies), mirroring validate-agent-registry.mjs; the schema subset it
// supports adds maxLength so GitHub's 50-char name / 100-char description limits
// are declarative (#680's contract, applied to this registry from day one).

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

const registryPath = path.resolve(process.argv[2] ?? 'label-registry.json')
const schemaPath = path.resolve(
  process.argv[3] ?? path.join(path.dirname(registryPath), 'label-registry.schema.json')
)

function loadJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    console.error(`label registry: cannot read valid JSON from ${file}: ${error.message}`)
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
  'maxLength',
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

  for (const keyword of ['minLength', 'maxLength', 'minItems']) {
    if (Object.hasOwn(rule, keyword) && (!Number.isInteger(rule[keyword]) || rule[keyword] < 0)) {
      schemaError(location, keyword, 'must be a non-negative integer')
    }
  }
  if (
    Object.hasOwn(rule, 'minLength') &&
    Object.hasOwn(rule, 'maxLength') &&
    rule.maxLength < rule.minLength
  ) {
    schemaError(location, 'maxLength', 'must be >= minLength')
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

function codePointLength(value, ceiling) {
  let length = 0
  const codePoints = value[Symbol.iterator]()
  while (length <= ceiling && !codePoints.next().done) {
    length += 1
  }
  return length
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
    if (rule.minLength !== undefined && codePointLength(value, rule.minLength) < rule.minLength) {
      errors.push(`${location}: must contain at least ${rule.minLength} character(s)`)
    }
    if (rule.maxLength !== undefined && codePointLength(value, rule.maxLength) > rule.maxLength) {
      errors.push(`${location}: must contain at most ${rule.maxLength} character(s)`)
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

try {
  assertSupportedSchema(schema)
} catch (error) {
  console.error(`label registry: invalid or unsupported schema: ${error.message}`)
  process.exit(1)
}

function semanticError(message) {
  errors.push(`registry: ${message}`)
}

validateSchema(registry, schema, '$registry')

// Cross-record constraints the structural schema cannot express. GitHub's hard
// limits are GH_LABEL_NAME_MAX / GH_LABEL_DESC_MAX in the renderers; the schema
// carries maxLength on the raw fields, and the composed-name check here closes
// the prefix+value gap between them.
const GH_LABEL_NAME_MAX = 50

// Which agent-registry render feeds which prefix — a suggest family rendering
// claim labels would provision the wrong vocabulary silently.
const REGISTRY_SET_PREFIX = {
  suggest: 'suggest',
  claim: 'claim',
  'foreman-adapters': 'foreman'
}
const VALUE_SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

if (errors.length === 0) {
  const familyIds = new Set()
  const provisionedNames = new Map()

  for (const family of registry.families) {
    const where = `family ${family.family}`
    if (familyIds.has(family.family)) semanticError(`duplicate family id: ${family.family}`)
    familyIds.add(family.family)

    const retired = family.retired === true
    if (retired && family.provision) {
      semanticError(`${where}: retired families are never provisioned — set provision: false`)
    }
    if (!retired && family.writers.length === 0) {
      semanticError(
        `${where}: a live family needs at least one writer (only retired may have none)`
      )
    }

    if (family.source === 'agent-registry') {
      if (!family.registry_set) {
        semanticError(`${where}: source agent-registry requires registry_set`)
      } else if (REGISTRY_SET_PREFIX[family.registry_set] !== family.prefix) {
        semanticError(
          `${where}: registry_set ${family.registry_set} renders ${REGISTRY_SET_PREFIX[family.registry_set]}:* labels but the prefix is ${family.prefix}`
        )
      }
      if (family.values.length > 0) {
        semanticError(
          `${where}: agent-registry families take their values from agent-registry.json — the values array must be empty`
        )
      }
      if (!family.provision && family.retired !== true) {
        semanticError(
          `${where}: agent-registry families exist to be provisioned — set provision: true (retired families are the one exception)`
        )
      }
      if (!family.color && family.retired !== true) {
        semanticError(
          `${where}: agent-registry families need a color — it is what the renderer asserts ` +
            `against the agent-registry records, and without it that drift guard is silently skipped`
        )
      }
    } else if (Object.hasOwn(family, 'registry_set')) {
      semanticError(`${where}: registry_set is only meaningful with source agent-registry`)
    }

    if (family.source === 'tool-owned' && family.provision) {
      semanticError(
        `${where}: tool-owned labels are created on demand by their tool — provisioning must leave them alone (provision: false)`
      )
    }

    if (
      family.source === 'inline' &&
      family.open_values !== true &&
      family.retired !== true &&
      family.values.length === 0
    ) {
      semanticError(
        `${where}: a closed inline family needs values — with none it silently renders nothing (mark it open_values or retired instead)`
      )
    }
    if (family.open_values === true && !family.placeholder) {
      semanticError(`${where}: open_values needs a placeholder for the docs rendering`)
    }
    if (family.source === 'agent-registry' && !family.placeholder) {
      semanticError(`${where}: agent-registry families need a placeholder for the docs rendering`)
    }
    if (family.placeholder && family.open_values !== true && family.source !== 'agent-registry') {
      semanticError(`${where}: placeholder without open_values documents nothing — remove one`)
    }

    const familyArms = family.arming === true
    const valueNames = new Set()
    for (const value of family.values) {
      const name = family.prefix === null ? value.value : `${family.prefix}:${value.value}`
      const at = `${where} value ${JSON.stringify(value.value)}`

      if (valueNames.has(name)) semanticError(`${at}: duplicate value in the family`)
      valueNames.add(name)

      if (/[\n\r|]/.test(name)) {
        semanticError(`${at}: label names must not contain newlines or '|' (the record transport)`)
      }
      if (family.prefix !== null && !VALUE_SLUG.test(value.value)) {
        semanticError(`${at}: prefixed values must be lowercase slugs`)
      }
      if ([...name].length > GH_LABEL_NAME_MAX) {
        semanticError(
          `${at}: composed name '${name}' exceeds GitHub's ${GH_LABEL_NAME_MAX}-char limit`
        )
      }
      if ((value.arming === true || familyArms) && family.prefix !== 'foreman') {
        semanticError(
          `${at}: arming outside the foreman:* namespace — foreman:* is the only arming surface (spec non-goal)`
        )
      }
      if (Object.hasOwn(value, 'writers') && value.writers.length === 0) {
        semanticError(`${at}: a per-value writers override cannot be empty`)
      }

      const provisioned = family.provision && value.provision !== false && value.retired !== true
      if (provisioned) {
        if (!value.description) {
          semanticError(
            `${at}: provisioned labels need a description (GitHub shows it at apply time)`
          )
        }
        if (!value.color && !family.color) {
          semanticError(`${at}: provisioned labels need a color (value override or family default)`)
        }
        if (provisionedNames.has(name)) {
          semanticError(
            `${at}: label '${name}' is already provisioned by family ${provisionedNames.get(name)}`
          )
        }
        provisionedNames.set(name, family.family)
      }
    }
    if (familyArms && family.prefix !== 'foreman' && family.values.length === 0) {
      semanticError(
        `${where}: arming outside the foreman:* namespace — foreman:* is the only arming surface`
      )
    }
  }
}

if (errors.length > 0) {
  for (const error of errors) console.error(`FAIL: ${error}`)
  process.exit(1)
}

const total = registry.families.reduce((sum, family) => sum + family.values.length, 0)
console.log(`label registry OK: ${registry.families.length} families, ${total} inline values`)
