#!/usr/bin/env node

import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// The subset validator moved into the dev-flow-support skill package with the
// rest of the v2 runtime (harmon-devkit#974); this root-side composition test
// still validates the authoring schemas, so it imports the one implementation
// from its new home rather than keeping a second copy under scripts/lib/.
import { createSchemaValidator } from '../ai/skills/universal/dev-flow-support/assets/lib/json-schema-subset.mjs'

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const schemaDir = path.join(repo, 'ai', 'schemas')
const fixtures = path.join(schemaDir, 'fixtures')
const roles = ['implementer', 'challenger', 'reviewer', 'integrator']

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function schema(name) {
  return readJson(path.join(schemaDir, name))
}

function withoutMetadata(value) {
  const copy = structuredClone(value)
  for (const key of ['$schema', '$id', 'title', '$comment']) delete copy[key]
  return copy
}

function rewriteNestedRefs(value, role) {
  if (Array.isArray(value)) return value.map((item) => rewriteNestedRefs(item, role))
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) => [key, rewriteNestedRefs(child, role)])
    )
  }
  if (typeof value !== 'string' || !value.startsWith('#/$defs/')) return value
  return `#/$defs/${role}/$defs/${value.slice('#/$defs/'.length)}`
}

function assertValid(engine, composed, file) {
  const instance = readJson(file)
  const errors = engine.validate(instance, composed, '$result')
  assert.deepEqual(errors, [], `${path.relative(repo, file)} must satisfy result.schema.json`)
  return instance
}

function assertInvalid(engine, composed, instance, label) {
  const errors = engine.validate(instance, composed, '$result')
  assert.notEqual(errors.length, 0, `${label} must be rejected by result.schema.json`)
}

const composed = schema('result.schema.json')
const envelope = schema('result.envelope.schema.json')
const engine = createSchemaValidator(composed)
engine.assertSupportedSchema(composed)

const envelopeKeys = ['type', 'additionalProperties', 'required', 'properties']
assert.deepEqual(
  Object.fromEntries(envelopeKeys.map((key) => [key, composed[key]])),
  Object.fromEntries(envelopeKeys.map((key) => [key, envelope[key]])),
  'composed root must stay byte-for-structure equal to the standalone envelope'
)

for (const role of roles) {
  const standalone = rewriteNestedRefs(withoutMetadata(schema(`result.${role}.schema.json`)), role)
  assert.deepEqual(
    composed.$defs[role],
    standalone,
    `result.schema.json $defs.${role} must match its standalone role schema`
  )
}

const valid = new Map()
for (const role of roles) {
  const directory = path.join(fixtures, `result.${role}.schema`, 'valid')
  for (const name of fs.readdirSync(directory).sort()) {
    if (!name.endsWith('.json')) continue
    const instance = assertValid(engine, composed, path.join(directory, name))
    if (!valid.has(role)) valid.set(role, instance)
  }
}

const missingHead = structuredClone(valid.get('implementer'))
delete missingHead.head
assertInvalid(engine, composed, missingHead, 'envelope missing head')

const wrongRolePayload = structuredClone(valid.get('implementer'))
wrongRolePayload.role = 'reviewer'
assertInvalid(engine, composed, wrongRolePayload, 'implementer payload dispatched as reviewer')

const extraPayloadKey = structuredClone(valid.get('integrator'))
extraPayloadKey.payload.unexpected = true
assertInvalid(engine, composed, extraPayloadKey, 'role payload with an unknown key')

const completedWithBlocker = readJson(path.join(fixtures,
  'result.integrator.schema/invalid/completed-with-blocker.json'))
assertInvalid(engine, composed, completedWithBlocker, 'completed integrator carrying blocker evidence')

console.log('native result schema composition OK')

// Lane status is standalone, with identical authoring/bundled schemas. Seq
// continuity is a two-document invariant exercised through the real CLI.
const statusSchema = schema('lane-status.schema.json')
assert.equal(fs.readFileSync(path.join(schemaDir, 'lane-status.schema.json'), 'utf8'),
  fs.readFileSync(path.join(repo, 'ai/skills/universal/dev-flow-support/assets/schemas/lane-status.schema.json'), 'utf8'))
const statusEngine = createSchemaValidator(statusSchema)
statusEngine.assertSupportedSchema(statusSchema)
const statusValid = readJson(path.join(fixtures, 'lane-status/valid/working.json'))
assert.deepEqual(statusEngine.validate(statusValid, statusSchema, '$status'), [])
for (const invalid of [{ ...statusValid, state: 'unknown' }, { ...statusValid, state: 'decision-request' }]) {
  assert.notEqual(statusEngine.validate(invalid, statusSchema, '$status').length, 0)
}
const statusTmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lane-status-composition-'))
try {
  const candidate = path.join(statusTmp, 'candidate.json')
  const previous = path.join(fixtures, 'lane-status/valid/working.json')
  const validator = path.join(repo, 'ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs')
  for (const [seq, expected] of [[1, 1], [0, 1], [3, 1], [2, 0]]) {
    fs.writeFileSync(candidate, JSON.stringify({ ...statusValid, seq }))
    const result = spawnSync(process.execPath, [validator, 'lane-status', candidate, '--prev', previous], { encoding: 'utf8' })
    assert.equal(result.status, expected, result.stderr)
  }
} finally {
  fs.rmSync(statusTmp, { recursive: true, force: true })
}
console.log('lane status composition and sequence checks OK')
