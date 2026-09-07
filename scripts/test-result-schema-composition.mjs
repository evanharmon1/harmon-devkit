#!/usr/bin/env node

import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { createSchemaValidator } from './lib/json-schema-subset.mjs'

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

console.log('native result schema composition OK')
