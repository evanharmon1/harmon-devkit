// json-schema-subset.mjs — a hand-rolled validator for a deliberately small
// subset of JSON Schema (draft 2020-12 vocabulary, restricted keyword set).
// No ajv, no npm deps — every consumer of this repo's schemas (this repo's
// own scripts, Foreman's Python) can re-implement this same subset without a
// library, which is the point: the schema files are the contract, not a
// particular validator's behavior.
//
// Extracted from scripts/validate-agent-registry.mjs (the original, single-
// schema implementation) so result-schema validation does not duplicate the
// ~350-line structural engine. Behavior for every keyword that file already
// supported is unchanged; two keywords were added because the result-schema
// family needs them (see below), and the ref-resolution root is now a
// constructor parameter instead of a module-level closure, so more than one
// schema file can be validated against in one process.
//
// Supported keywords, beyond the original set:
//   - minimum / maximum — inclusive numeric bounds (round/line/attempt/
//     sequence numbers all need "at least 1"; the registry never needed
//     numeric bounds, so the original omitted them).
//   - if / then / else — same-document conditional requirements (e.g. an
//     integrator payload's `applied_dispositions` is required only when its
//     own `verdict` is `clean`). Cross-document conditions (an implementer
//     payload's required fields depending on the sibling envelope's
//     `status`) are deliberately NOT expressed this way — see
//     ai/schemas/README.md's "Composition" section for why those are
//     receipt-validation semantic checks instead.
//   - allOf — unconditional composition (every member schema applies to the
//     whole instance, errors accumulate from all of them). Added for
//     result.schema.json's role dispatch: one `{if, then}` pair per role,
//     each `then` pointing `payload` at that role's `$defs` entry via
//     `$ref`, so a native JSON-Schema validator (no separate dispatch
//     script) can validate a full envelope+payload in one document.
export const SUPPORTED_SCHEMA_KEYWORDS = new Set([
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
  'additionalProperties',
  'minimum',
  'maximum',
  'if',
  'then',
  'else',
  'allOf'
])

export const SUPPORTED_INSTANCE_TYPES = new Set([
  'array',
  'boolean',
  'integer',
  'null',
  'number',
  'object',
  'string'
])

export function isSchemaObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

export function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`

  return `{${Object.keys(value)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
    .join(',')}}`
}

export function jsonEqual(left, right) {
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

function exceedsMaxLength(value, maximum) {
  let length = 0
  const codePoints = value[Symbol.iterator]()
  while (length <= maximum && !codePoints.next().done) {
    length += 1
  }
  return length > maximum
}

export function instanceType(value) {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  if (Number.isInteger(value)) return 'integer'
  return typeof value
}

function schemaError(location, keyword, expectation) {
  throw new Error(`${location}.${keyword}: ${expectation}`)
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
      types.some((type) => typeof type !== 'string' || !SUPPORTED_INSTANCE_TYPES.has(type)) ||
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
  for (const keyword of ['minimum', 'maximum']) {
    if (Object.hasOwn(rule, keyword) && typeof rule[keyword] !== 'number') {
      schemaError(location, keyword, 'must be a number')
    }
  }
  if (
    Object.hasOwn(rule, 'minimum') &&
    Object.hasOwn(rule, 'maximum') &&
    rule.maximum < rule.minimum
  ) {
    schemaError(location, 'maximum', 'must be >= minimum')
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
  if (Object.hasOwn(rule, 'allOf') && (!Array.isArray(rule.allOf) || rule.allOf.length === 0)) {
    schemaError(location, 'allOf', 'must be a non-empty array')
  }
}

// createSchemaValidator ROOT — a validator bound to ROOT for `$ref`
// resolution. Each schema FILE is validated with its own validator instance,
// since this subset (like the registry's) supports only same-document
// `#/...` references, never a cross-file $ref.
export function createSchemaValidator(rootSchema) {
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
      }, rootSchema)
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
      if (!SUPPORTED_SCHEMA_KEYWORDS.has(keyword)) {
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
    for (const keyword of ['if', 'then', 'else']) {
      if (Object.hasOwn(rule, keyword)) {
        assertSupportedSchema(rule[keyword], `${location}.${keyword}`, audit)
      }
    }
    for (const [index, child] of (rule.allOf ?? []).entries()) {
      assertSupportedSchema(child, `${location}.allOf[${index}]`, audit)
    }
    audit.active.delete(rule)
    audit.complete.add(rule)
  }

  function validateInto(value, rule, location, errors) {
    if (Object.hasOwn(rule, '$ref')) {
      const target = resolveRef(rule.$ref)
      if (!isSchemaObject(target)) {
        errors.push(`${location}: schema reference ${rule.$ref} does not resolve to an object schema`)
        return
      }
      validateInto(value, target, location, errors)
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
      if (rule.maxLength !== undefined && exceedsMaxLength(value, rule.maxLength)) {
        errors.push(`${location}: must contain at most ${rule.maxLength} character(s)`)
      }
      if (rule.pattern && !new RegExp(rule.pattern, 'u').test(value)) {
        errors.push(`${location}: does not match ${rule.pattern}`)
      }
    }

    if (typeof value === 'number') {
      if (rule.minimum !== undefined && value < rule.minimum) {
        errors.push(`${location}: must be >= ${rule.minimum}`)
      }
      if (rule.maximum !== undefined && value > rule.maximum) {
        errors.push(`${location}: must be <= ${rule.maximum}`)
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
        value.forEach((item, index) => validateInto(item, rule.items, `${location}[${index}]`, errors))
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
        if (Object.hasOwn(value, key)) validateInto(value[key], childRule, `${location}.${key}`, errors)
      }
    }

    // if/then/else: the `if` branch is trialed into a throwaway array so a
    // non-matching trial never pollutes the real error list — only whether it
    // was EMPTY matters. This is the one keyword pair whose evaluation order
    // depends on another keyword's outcome; every other keyword above is
    // independent and can accumulate into `errors` directly.
    if (Object.hasOwn(rule, 'if')) {
      const trial = []
      validateInto(value, rule.if, location, trial)
      if (trial.length === 0) {
        if (Object.hasOwn(rule, 'then')) validateInto(value, rule.then, location, errors)
      } else if (Object.hasOwn(rule, 'else')) {
        validateInto(value, rule.else, location, errors)
      }
    }

    // allOf: unconditional — every member applies to the whole instance at
    // the SAME location, and every member's errors accumulate directly
    // (unlike if/then, there is no trial: allOf has no condition to decide
    // between branches, each member simply always applies).
    for (const child of rule.allOf ?? []) {
      validateInto(value, child, location, errors)
    }
  }

  return {
    assertSupportedSchema(rule, location) {
      assertSupportedSchema(rule, location)
    },
    // validate VALUE against RULE at LOCATION, returning the error list.
    validate(value, rule, location) {
      const errors = []
      validateInto(value, rule, location, errors)
      return errors
    }
  }
}
