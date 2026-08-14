#!/usr/bin/env node
// validate-label-registry.mjs — schema-check label-registry.json and enforce the
// cross-record invariants a structural schema cannot express.
//
// Usage: node scripts/validate-label-registry.mjs [registry-path] [schema-path]
//   Defaults: label-registry.json + label-registry.schema.json beside it.
// Exit 0 = valid; exit 1 = invalid (every failure names the offending family or
// value and the remediation).
//
// This is a deliberate SIBLING of validate-agent-registry.mjs rather than a
// shared library: both files are copier-rendered twins upstream (harmon-init),
// and the agent-registry validator gates `task verify` today. Extracting a
// module would put a working gate behind a new dependency that the upstream
// template does not render yet, for no behavioral gain. The walk below is
// structured to match its sibling function-for-function, so extracting one
// module later is mechanical rather than a rewrite. The one deliberate
// difference is `maxLength`, which BOTH validators now support — the label
// taxonomy caps descriptions at GitHub's 100 characters (harmon-init#680).
//
// Both validators reject unknown schema keywords rather than ignoring them: a
// keyword this walk does not implement would otherwise read as "constraint
// satisfied" when nothing checked it.

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
    rule.minLength > rule.maxLength
  ) {
    schemaError(location, 'maxLength', 'must not be below minLength')
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
  console.error(`label registry: invalid or unsupported schema: ${error.message}`)
  process.exit(1)
}

// String lengths are counted in CODE POINTS, not UTF-16 units, so an emoji
// counts once — matching how GitHub reports a label name's length.
function codePointLength(value) {
  let length = 0
  for (const _ of value) length += 1
  return length
}

function instanceType(value) {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  if (Number.isInteger(value)) return 'integer'
  return typeof value
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
    if (rule.minLength !== undefined && codePointLength(value) < rule.minLength) {
      errors.push(`${location}: must contain at least ${rule.minLength} character(s)`)
    }
    if (rule.maxLength !== undefined && codePointLength(value) > rule.maxLength) {
      errors.push(
        `${location}: must contain at most ${rule.maxLength} character(s), found ${codePointLength(value)}`
      )
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

function semanticError(message) {
  errors.push(`registry: ${message}`)
}

validateSchema(registry, schema, '$registry')

// ── Cross-record invariants ────────────────────────────────────────────────
// GitHub's own limits, re-checked here on the RENDERED name: the schema caps a
// value's own name, but a prefix is joined on afterwards.
const GH_LABEL_NAME_MAX = 50

// Which agent-registry renderer prefix each composition mode can filter. A mode
// paired with the wrong prefix would silently compose zero labels — the family
// would look provisioned and provision nothing.
const REGISTRY_MODE_PREFIXES = {
  'suggest-claim': ['suggest', 'claim'],
  'foreman-adapters': ['foreman']
}

const renderedName = (family, name) =>
  family.prefix === null ? name : `${family.prefix}:${name}`
// GitHub's identity for a label name is CASE-INSENSITIVE — `Task` and `task` are
// one label there — so every uniqueness check below keys on the folded name. On
// the exact spelling both would validate, `gh label create --force` would
// collapse them to whichever ran last, and status would expect two spellings and
// report drift that no provisioning run can clear.
const nameKey = (name) => name.toLowerCase()
const effectiveWriters = (family, value) => value.writers ?? family.writers ?? []
const effectiveColor = (family, value) => value.color ?? family.color
// `null` means "this repo provisions it": neither the value nor its family
// declares another creator.
const effectiveSource = (family, value) =>
  value.source ?? (family.source === 'tool-owned' ? 'tool-owned' : null)

if (errors.length === 0) {
  const seenFamilies = new Set()
  const seenPrefixes = new Map()
  const seenRendered = new Map()
  let workTypeFamilies = 0

  // Every declared prefix, collected BEFORE the per-value walk: a bare value
  // name is checked against all of them, including prefixes declared by families
  // later in the file.
  const declaredPrefixes = registry.families
    .map((family) => family.prefix)
    .filter((prefix) => prefix !== null)

  for (const family of registry.families) {
    const id = family.family

    if (seenFamilies.has(id)) semanticError(`duplicate family id: ${id}`)
    seenFamilies.add(id)

    if (family.prefix !== null) {
      const owner = seenPrefixes.get(family.prefix)
      if (owner !== undefined) {
        semanticError(
          `families ${owner} and ${id} share the prefix '${family.prefix}:' — a prefix must belong to exactly one family or a rendered name has two owners`
        )
      } else {
        seenPrefixes.set(family.prefix, id)
      }
    }

    if (family.axis === 'work-type') {
      workTypeFamilies += 1
      if (family.exclusive !== true) {
        semanticError(
          `family ${id} is the work-type axis but is not exclusive — an issue carries exactly one work type`
        )
      }
    }

    // ── source / values / registry are an either-or set ────────────────────
    const hasValues = Object.hasOwn(family, 'values')
    const hasRegistry = Object.hasOwn(family, 'registry')

    if (family.source === 'agent-registry') {
      if (!hasRegistry) {
        semanticError(
          `family ${id} has source 'agent-registry' but no registry.mode — the renderer would not know which agent-registry-labels.mjs mode composes it`
        )
      }
      if (hasValues) {
        semanticError(
          `family ${id} has source 'agent-registry' and an inline values list — the values come from agent-registry.json and must not be duplicated here`
        )
      }
    } else {
      if (!hasValues) {
        semanticError(`family ${id} has source '${family.source}' but no values list`)
      }
      if (family.source === 'tool-owned' && hasRegistry) {
        semanticError(
          `family ${id} is tool-owned and also declares registry.mode — a tool-owned family is documented, never composed or provisioned`
        )
      }
    }

    if (hasRegistry) {
      const allowed = REGISTRY_MODE_PREFIXES[family.registry.mode] ?? []
      if (family.prefix === null) {
        semanticError(
          `family ${id} composes from agent-registry.json but has no prefix — the renderer filters composed labels by prefix and would keep none`
        )
      } else if (!allowed.includes(family.prefix)) {
        semanticError(
          `family ${id} composes with mode '${family.registry.mode}' but its prefix '${family.prefix}:' is not one that mode emits (${allowed.join(', ')}) — it would compose zero labels`
        )
      }
      // A composed family's records carry agent-registry-labels.mjs's own color,
      // and the renderer refuses to emit them when the manifest disagrees. That
      // check needs something to compare against: with no family color it has
      // nothing to say, so provisioning would quietly keep applying the other
      // renderer's color while every direct manifest reader saw none.
      if (family.color === undefined) {
        semanticError(
          `family ${id} composes from agent-registry.json but declares no color — the composed records carry that renderer's own color, and with nothing here to compare it against the manifest silently stops being the source of truth for it`
        )
      }
    }

    // ── per-value rules ────────────────────────────────────────────────────
    const seenValueNames = new Set()
    for (const value of family.values ?? []) {
      const where = `family ${id} value '${value.name}'`

      if (seenValueNames.has(nameKey(value.name))) {
        semanticError(`${where} is listed twice (GitHub label names are case-insensitive)`)
      }
      seenValueNames.add(nameKey(value.name))

      const rendered = renderedName(family, value.name)
      const owner = seenRendered.get(nameKey(rendered))
      if (owner !== undefined) {
        semanticError(
          `label '${rendered}' is defined by both family ${owner.family} and family ${id}${owner.rendered === rendered ? '' : ` (as '${owner.rendered}' — the two differ only in case, which GitHub treats as one label)`} — a rendered label name must be globally unique`
        )
      } else {
        seenRendered.set(nameKey(rendered), { family: id, rendered })
      }
      if (codePointLength(rendered) > GH_LABEL_NAME_MAX) {
        semanticError(
          `${where} renders '${rendered}' at ${codePointLength(rendered)} chars, over GitHub's ${GH_LABEL_NAME_MAX}-char label-name limit — shorten the value or the prefix`
        )
      }

      // A bare value may not impersonate another family's namespace. Value names
      // are allowed to contain a colon (release-please spells one
      // `autorelease: pending`), so nothing structural stops a prefix-less family
      // from declaring a value literally named `foreman:claude` — which would
      // render the same label another family owns, from a namespace it does not
      // belong to. The rendered-name uniqueness check above cannot see it when
      // the colliding twin is COMPOSED from agent-registry.json rather than
      // listed here.
      // Folded, like every other name comparison here: GitHub reads
      // `Foreman:new-backend` and `foreman:new-backend` as one label, so a
      // case-sensitive test would wave the capitalized spelling straight into
      // another family's namespace.
      if (family.prefix === null) {
        const folded = nameKey(value.name)
        const impersonated = declaredPrefixes.find((prefix) =>
          folded.startsWith(`${nameKey(prefix)}:`)
        )
        if (impersonated !== undefined) {
          semanticError(
            `${where} has no prefix of its own but its name opens with '${impersonated}:', the prefix of family ${seenPrefixes.get(impersonated) ?? impersonated} — a bare value must not render into another family's namespace`
          )
        }
      }

      const source = effectiveSource(family, value)
      const writers = effectiveWriters(family, value)
      const toolWriters = writers.filter((writer) => writer.startsWith('tool:'))

      if (source === 'github-default') {
        if (family.source === 'tool-owned') {
          semanticError(
            `${where} is github-default inside a tool-owned family — a label has one creator, not two`
          )
        }
        if (Object.hasOwn(value, 'color')) {
          semanticError(
            `${where} is github-default and sets a color — GitHub's own color is authoritative and this manifest must not restate it`
          )
        }
        if (Object.hasOwn(value, 'description')) {
          semanticError(
            `${where} is github-default and sets a description — GitHub's own description is authoritative and this manifest must not restate it`
          )
        }
      }

      if (source === null) {
        // Provisionable: everything gh label create needs must resolve.
        //
        // Whitespace is legal in a GitHub label name but not in one this repo
        // provisions: status.sh word-splits the rendered inventory to count what
        // a repo is missing, so `foo bar` would be read as two labels that do not
        // exist. The taxonomy's only spaced names are tool-owned
        // (release-please's `autorelease: pending`) and are never rendered, which
        // is why the schema permits the character at all.
        if (/\s/.test(rendered)) {
          semanticError(
            `${where} is provisioned but renders '${rendered}', which contains whitespace — the rendered inventory is word-split by its consumers, so a spaced name would be counted as two labels that do not exist`
          )
        }
        if (value.description === undefined) {
          semanticError(
            `${where} is provisioned but has no description — set one on the value, or mark it github-default/tool-owned if this repo does not create it`
          )
        }
        if (effectiveColor(family, value) === undefined) {
          semanticError(
            `${where} is provisioned but resolves no color — set color on the value or on family ${id}`
          )
        }
      }

      if (source === 'tool-owned') {
        if (toolWriters.length === 0) {
          semanticError(
            `${where} is tool-owned but names no tool:<name> writer — say which tool creates it`
          )
        }
        if (writers.includes('agent')) {
          semanticError(
            `${where} is tool-owned and agent-writable — an agent cannot rely on a label its owning tool creates on demand; provision it or drop 'agent'`
          )
        }
      } else if (toolWriters.length === writers.length) {
        semanticError(
          `${where} lists only tool:<name> writers but is not tool-owned — mark it source 'tool-owned' or give it a human/agent writer`
        )
      }
    }
  }

  if (workTypeFamilies !== 1) {
    semanticError(
      `expected exactly one family on the work-type axis, found ${workTypeFamilies} — work type is one axis, and a second family would make "exactly one work-type label" unenforceable`
    )
  }
}

if (errors.length > 0) {
  for (const error of errors) console.error(`FAIL: ${error}`)
  process.exit(1)
}

const valueCount = registry.families.reduce(
  (total, family) => total + (family.values?.length ?? 0),
  0
)
console.log(
  `label registry OK: ${registry.families.length} families, ${valueCount} inline value(s), ` +
    `${registry.families.filter((family) => Object.hasOwn(family, 'registry')).length} composed from agent-registry.json`
)
