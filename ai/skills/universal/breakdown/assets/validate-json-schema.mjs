// Dependency-free validator for the schema subset used by Harmon registries.
// Schemas are repository data; unsupported keywords fail closed.

const keywords = new Set([
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
const instanceTypes = new Set([
  'array',
  'boolean',
  'integer',
  'null',
  'number',
  'object',
  'string'
])

// Registry schemas come from the target repository, so their patterns are
// data, not JavaScript to execute. Support only the bounded patterns used by
// the version-1 Harmon schemas and implement them with fixed predicates.
const safePatterns = new Map([
  ['^[a-z0-9]+(?:-[a-z0-9]+)*$', (value) => /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value)],
  ['^[0-9A-F]{6}$', (value) => /^[0-9A-F]{6}$/.test(value)],
  [
    '^(human|trusted-human|agent|tool:[a-z0-9-]+)$',
    (value) => /^(?:human|trusted-human|agent|tool:[a-z0-9-]+)$/.test(value)
  ],
  [
    '^[a-z0-9]+(?:-[a-z0-9]+)*[.]sh$',
    (value) => /^[a-z0-9]+(?:-[a-z0-9]+)*[.]sh$/.test(value)
  ],
  [
    '^agent:[a-z0-9]+(?:[a-z0-9._-]*[a-z0-9])?$',
    (value) => /^agent:[a-z0-9]+(?:[a-z0-9._-]*[a-z0-9])?$/.test(value)
  ]
])

function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`
  return `{${Object.keys(value)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
    .join(',')}}`
}

function equal(left, right) {
  return canonical(left) === canonical(right)
}

function typeOf(value) {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  if (Number.isInteger(value)) return 'integer'
  return typeof value
}

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

export function validateJsonSchema(instance, schema) {
  if (!object(schema)) throw new Error('schema root must be an object')

  function resolve(ref) {
    if (!ref.startsWith('#/')) throw new Error(`unsupported schema reference ${ref}`)
    const target = ref
      .slice(2)
      .split('/')
      .map((part) => part.replaceAll('~1', '/').replaceAll('~0', '~'))
      .reduce((node, part) => (object(node) || Array.isArray(node) ? node[part] : undefined), schema)
    if (!object(target)) throw new Error(`schema reference ${ref} does not resolve to an object`)
    return target
  }

  const active = new Set()
  const complete = new Set()
  function audit(rule, where) {
    if (!object(rule)) throw new Error(`${where}: schemas must be objects`)
    if (active.has(rule)) throw new Error(`${where}: cyclic schema references are unsupported`)
    if (complete.has(rule)) return
    active.add(rule)
    for (const key of Object.keys(rule)) {
      if (!keywords.has(key)) throw new Error(`${where}: unsupported schema keyword ${key}`)
    }
    if (Object.hasOwn(rule, '$ref')) {
      if (Object.keys(rule).some((key) => key !== '$ref')) {
        throw new Error(`${where}: schema keywords alongside $ref are unsupported`)
      }
      audit(resolve(rule.$ref), `${where}.$ref(${rule.$ref})`)
    }
    for (const key of ['$schema', '$id', '$ref', 'title', 'description', '$comment']) {
      if (Object.hasOwn(rule, key) && typeof rule[key] !== 'string') {
        throw new Error(`${where}.${key}: must be a string`)
      }
    }
    if (Object.hasOwn(rule, 'type')) {
      const types = Array.isArray(rule.type) ? rule.type : [rule.type]
      if (
        types.length === 0 ||
        new Set(types).size !== types.length ||
        types.some((type) => typeof type !== 'string' || !instanceTypes.has(type))
      ) {
        throw new Error(`${where}.type: must name unique supported types`)
      }
    }
    if (Object.hasOwn(rule, 'enum')) {
      if (!Array.isArray(rule.enum) || rule.enum.length === 0) {
        throw new Error(`${where}.enum: must be a non-empty array`)
      }
      if (rule.enum.some((item, index) => rule.enum.slice(0, index).some((prior) => equal(item, prior)))) {
        throw new Error(`${where}.enum: values must be unique`)
      }
    }
    for (const key of ['minLength', 'maxLength', 'minItems']) {
      if (Object.hasOwn(rule, key) && (!Number.isInteger(rule[key]) || rule[key] < 0)) {
        throw new Error(`${where}.${key}: must be a non-negative integer`)
      }
    }
    if (rule.maxLength !== undefined && rule.minLength !== undefined && rule.maxLength < rule.minLength) {
      throw new Error(`${where}.maxLength: must be >= minLength`)
    }
    if (Object.hasOwn(rule, 'pattern')) {
      if (typeof rule.pattern !== 'string') throw new Error(`${where}.pattern: must be a string`)
      if (!safePatterns.has(rule.pattern)) {
        throw new Error(`${where}.pattern: is not a supported bounded registry pattern`)
      }
    }
    if (Object.hasOwn(rule, 'uniqueItems') && typeof rule.uniqueItems !== 'boolean') {
      throw new Error(`${where}.uniqueItems: must be boolean`)
    }
    if (Object.hasOwn(rule, 'required')) {
      if (
        !Array.isArray(rule.required) ||
        new Set(rule.required).size !== rule.required.length ||
        rule.required.some((key) => typeof key !== 'string')
      ) {
        throw new Error(`${where}.required: must be a unique string array`)
      }
    }
    for (const key of ['$defs', 'properties']) {
      if (Object.hasOwn(rule, key) && !object(rule[key])) {
        throw new Error(`${where}.${key}: must be an object`)
      }
      for (const [name, child] of Object.entries(rule[key] ?? {})) {
        audit(child, `${where}.${key}.${name}`)
      }
    }
    if (Object.hasOwn(rule, 'items')) audit(rule.items, `${where}.items`)
    if (
      Object.hasOwn(rule, 'additionalProperties') &&
      typeof rule.additionalProperties !== 'boolean'
    ) {
      throw new Error(`${where}.additionalProperties: must be boolean`)
    }
    active.delete(rule)
    complete.add(rule)
  }
  audit(schema, '$schema')

  const errors = []
  function validate(value, rule, where) {
    if (rule.$ref) return validate(value, resolve(rule.$ref), where)
    if (Object.hasOwn(rule, 'const') && !equal(value, rule.const)) {
      errors.push(`${where}: must equal ${JSON.stringify(rule.const)}`)
    }
    if (rule.enum && !rule.enum.some((candidate) => equal(value, candidate))) {
      errors.push(`${where}: must be one of ${rule.enum.map(JSON.stringify).join(', ')}`)
    }
    if (rule.type) {
      const allowed = Array.isArray(rule.type) ? rule.type : [rule.type]
      const actual = typeOf(value)
      if (!allowed.includes(actual) && !(actual === 'integer' && allowed.includes('number'))) {
        errors.push(`${where}: expected ${allowed.join(' or ')}, found ${actual}`)
        return
      }
    }
    if (typeof value === 'string') {
      const length = [...value].length
      if (rule.minLength !== undefined && length < rule.minLength) {
        errors.push(`${where}: must contain at least ${rule.minLength} character(s)`)
      }
      if (rule.maxLength !== undefined && length > rule.maxLength) {
        errors.push(`${where}: must contain at most ${rule.maxLength} character(s)`)
      }
      if (rule.pattern && !safePatterns.get(rule.pattern)(value)) {
        errors.push(`${where}: does not match ${rule.pattern}`)
      }
    }
    if (Array.isArray(value)) {
      if (rule.minItems !== undefined && value.length < rule.minItems) {
        errors.push(`${where}: must contain at least ${rule.minItems} item(s)`)
      }
      if (rule.uniqueItems && new Set(value.map(canonical)).size !== value.length) {
        errors.push(`${where}: items must be unique`)
      }
      if (rule.items) value.forEach((item, index) => validate(item, rule.items, `${where}[${index}]`))
    }
    if (object(value)) {
      for (const key of rule.required ?? []) {
        if (!Object.hasOwn(value, key)) errors.push(`${where}: missing required property ${key}`)
      }
      if (rule.additionalProperties === false) {
        for (const key of Object.keys(value)) {
          if (!Object.hasOwn(rule.properties ?? {}, key)) {
            errors.push(`${where}: unexpected property ${key}`)
          }
        }
      }
      for (const [key, child] of Object.entries(rule.properties ?? {})) {
        if (Object.hasOwn(value, key)) validate(value[key], child, `${where}.${key}`)
      }
    }
  }
  validate(instance, schema, '$registry')
  return errors
}
