#!/usr/bin/env node
// validate-result-schemas.mjs — schema-check one dev-flow-v2 result/record
// fixture, plus the receipt-validation checks a raw JSON Schema cannot
// express because they read a sibling field outside the instance a payload
// schema validates (envelope vs payload) or need context from other
// documents in the same run (prior passes, the active run).
//
// Usage:
//   validate-result-schemas.mjs <kind> <file> [options]
//
//   kind: envelope | implementer | reviewer | integrator | adjudication | run
//
//   --known-ids <file.json>       JSON array of finding ids already used
//                                 elsewhere in the run (reviewer only) —
//                                 rejects a collision (spec: "a finding id
//                                 is unique within the run by construction").
//   --run-id <id>                 The active run's run_id (with
//   --initiated-by <human|foreman>  --initiated-by): rejects an
//                                 envelope whose `run` names a different run.
//
// Exit 0 and a one-line summary when the fixture is valid; exit 1 and every
// violation (one per line) otherwise.
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { createSchemaValidator } from './lib/json-schema-subset.mjs'

const SCHEMAS_DIR = path.resolve('ai/schemas')
const KINDS = ['envelope', 'implementer', 'reviewer', 'integrator', 'adjudication', 'run']
const FINDING_ID = /^(challenge|review)-r([1-9][0-9]*)-(.+)-([1-9][0-9]*)$/

function usage() {
  console.error(
    'usage: validate-result-schemas.mjs <envelope|implementer|reviewer|integrator|adjudication|run> <file> ' +
      '[--known-ids <file.json>] [--run-id <id> --initiated-by <human|foreman>]'
  )
}

function loadJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    console.error(`validate-result-schemas: cannot read valid JSON from ${file}: ${error.message}`)
    process.exit(1)
  }
}

function loadSchema(basename) {
  return loadJson(path.join(SCHEMAS_DIR, basename))
}

function parseArgs(argv) {
  const [kind, file, ...rest] = argv
  if (!kind || !file || !KINDS.includes(kind)) {
    usage()
    process.exit(2)
  }
  const options = { knownIds: null, runId: null, initiatedBy: null }
  for (let i = 0; i < rest.length; i += 1) {
    switch (rest[i]) {
      case '--known-ids':
        options.knownIds = loadJson(rest[(i += 1)])
        break
      case '--run-id':
        options.runId = rest[(i += 1)]
        break
      case '--initiated-by':
        options.initiatedBy = rest[(i += 1)]
        break
      default:
        console.error(`validate-result-schemas: unknown option ${rest[i]}`)
        usage()
        process.exit(2)
    }
  }
  return { kind, file, options }
}

function parseFindingId(id) {
  const match = FINDING_ID.exec(id)
  if (!match) return null
  const [, stage, round, finder, n] = match
  return { stage, round: Number(round), finder, n: Number(n) }
}

function validateAgainst(schema, instance, location) {
  const engine = createSchemaValidator(schema)
  try {
    engine.assertSupportedSchema(schema)
  } catch (error) {
    return [`${location}: invalid or unsupported schema: ${error.message}`]
  }
  return engine.validate(instance, schema, location)
}

// checkImplementerStatus — the completed/blocked conditional requirements
// from Foreman v1: cannot be a structural keyword because `status` lives on
// the envelope and the conditioned fields live in `payload` (a separate
// instance from the payload schema's point of view). See
// ai/schemas/README.md 'Composition'.
function checkImplementerStatus(envelope, errors) {
  const { status, payload } = envelope
  if (status === 'completed') {
    if (typeof payload.summary !== 'string' || payload.summary.trim() === '') {
      errors.push('$result.payload.summary: required (non-empty) when status is completed')
    }
    if (typeof payload.handoff !== 'string' || payload.handoff.trim() === '') {
      errors.push('$result.payload.handoff: required (non-empty) when status is completed')
    }
    if (!Array.isArray(payload.ac_test_map) || payload.ac_test_map.length === 0) {
      errors.push('$result.payload.ac_test_map: required (non-empty array) when status is completed')
    }
  } else if (status === 'blocked') {
    if (typeof payload.blocked_question !== 'string' || payload.blocked_question.trim() === '') {
      errors.push('$result.payload.blocked_question: required (non-empty) when status is blocked')
    }
  }
}

function checkActiveRun(envelope, options, errors) {
  if (options.runId === null) return
  const { run } = envelope
  if (run.run_id !== options.runId || run.initiated_by !== options.initiatedBy) {
    errors.push(
      `$result.run: run {run_id: ${JSON.stringify(run.run_id)}, initiated_by: ${JSON.stringify(
        run.initiated_by
      )}} is not the active run {run_id: ${JSON.stringify(options.runId)}, initiated_by: ${JSON.stringify(
        options.initiatedBy
      )}}`
    )
  }
}

// checkFindingIds — (b) no duplicate id within this pass, (c) no collision
// with ids already used elsewhere in the run (when --known-ids is given),
// (e) each id's stage/round/finder segments match this pass's own metadata,
// plus a counts-vs-tally cross-check.
function checkFindingIds(envelope, options, errors) {
  const { payload } = envelope
  if (!Array.isArray(payload.findings)) return
  const seen = new Set()
  const tally = { P0: 0, P1: 0, P2: 0, P3: 0 }
  for (const finding of payload.findings) {
    if (typeof finding.id !== 'string') continue
    if (seen.has(finding.id)) {
      errors.push(`$result.payload.findings: duplicate finding id ${finding.id} within this pass`)
    }
    seen.add(finding.id)
    if (Array.isArray(options.knownIds) && options.knownIds.includes(finding.id)) {
      errors.push(
        `$result.payload.findings: finding id ${finding.id} collides with a finding already in the run`
      )
    }
    const parsed = parseFindingId(finding.id)
    if (parsed) {
      if (parsed.stage !== payload.stage) {
        errors.push(
          `$result.payload.findings: finding id ${finding.id} names stage ${parsed.stage}, pass is ${payload.stage}`
        )
      }
      if (parsed.round !== payload.round) {
        errors.push(
          `$result.payload.findings: finding id ${finding.id} names round ${parsed.round}, pass is round ${payload.round}`
        )
      }
      if (parsed.finder !== payload.finder) {
        errors.push(
          `$result.payload.findings: finding id ${finding.id} names finder ${parsed.finder}, pass finder is ${payload.finder}`
        )
      }
    }
    if (Object.hasOwn(tally, finding.priority)) tally[finding.priority] += 1
  }
  if (payload.counts && typeof payload.counts === 'object') {
    for (const priority of ['P0', 'P1', 'P2', 'P3']) {
      if (payload.counts[priority] !== tally[priority]) {
        errors.push(
          `$result.payload.counts.${priority}: reports ${payload.counts[priority]}, findings actually contain ${tally[priority]}`
        )
      }
    }
  }
}

// checkHeadAgreement — every head-shaped field in a payload must equal the
// envelope's head (specs/dev-flow-v2.md § Results, "Heads must agree").
function checkHeadAgreement(kind, envelope, errors) {
  const { head, payload } = envelope
  if (kind === 'reviewer' && typeof payload.reviewed_head === 'string' && payload.reviewed_head !== head) {
    errors.push(
      `$result.payload.reviewed_head: ${payload.reviewed_head} does not match envelope head ${head}`
    )
  }
  if (kind === 'integrator' && payload.codex_cycle && typeof payload.codex_cycle === 'object') {
    if (typeof payload.codex_cycle.head === 'string' && payload.codex_cycle.head !== head) {
      errors.push(
        `$result.payload.codex_cycle.head: ${payload.codex_cycle.head} does not match envelope head ${head}`
      )
    }
    const accepted = payload.codex_cycle.accepted
    if (accepted && typeof accepted === 'object' && typeof accepted.reviewed_commit === 'string') {
      if (accepted.reviewed_commit !== head) {
        errors.push(
          `$result.payload.codex_cycle.accepted.reviewed_commit: ${accepted.reviewed_commit} does not match envelope head ${head}`
        )
      }
    }
  }
}

function checkAdjudicationEntries(document, errors) {
  if (!Array.isArray(document.adjudications)) return
  const seen = new Set()
  for (const entry of document.adjudications) {
    if (typeof entry.finding_id === 'string') {
      if (seen.has(entry.finding_id)) {
        errors.push(`$adjudication.adjudications: duplicate finding_id ${entry.finding_id}`)
      }
      seen.add(entry.finding_id)
    }
    if (entry.reviewer_priority === entry.adjudicated_priority) {
      if (entry.override !== null) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].override: must be null when adjudicated_priority equals reviewer_priority`
        )
      }
    } else if (
      entry.override === null ||
      typeof entry.override !== 'object' ||
      typeof entry.override.reason !== 'string' ||
      entry.override.reason.trim() === ''
    ) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}].override: required (with a reason) when adjudicated_priority (${entry.adjudicated_priority}) differs from reviewer_priority (${entry.reviewer_priority})`
      )
    }
  }
}

function checkSettlements(document, errors) {
  if (!Array.isArray(document.settlements)) return
  const seen = new Set()
  for (const entry of document.settlements) {
    if (typeof entry.finding_id !== 'string') continue
    if (seen.has(entry.finding_id)) {
      errors.push(`$run.settlements: duplicate finding_id ${entry.finding_id} — one settlement per finding`)
    }
    seen.add(entry.finding_id)
  }
}

function main() {
  const { kind, file, options } = parseArgs(process.argv.slice(2))
  const instance = loadJson(file)

  if (kind === 'adjudication' || kind === 'run') {
    const schema = loadSchema(`${kind === 'adjudication' ? 'adjudication' : 'run'}.schema.json`)
    const errors = validateAgainst(schema, instance, `$${kind}`)
    if (errors.length === 0) {
      if (kind === 'adjudication') checkAdjudicationEntries(instance, errors)
      if (kind === 'run') checkSettlements(instance, errors)
    }
    report(errors, `${kind} record OK`)
    return
  }

  const envelopeSchema = loadSchema('result.envelope.schema.json')
  const errors = validateAgainst(envelopeSchema, instance, '$result')

  if (kind !== 'envelope' && errors.length === 0) {
    if (instance.role !== kind) {
      errors.push(`$result.role: expected ${kind}, found ${JSON.stringify(instance.role)}`)
    } else {
      const payloadSchema = loadSchema(`result.${kind}.schema.json`)
      errors.push(...validateAgainst(payloadSchema, instance.payload, '$result.payload'))
      if (errors.length === 0) {
        checkActiveRun(instance, options, errors)
        if (kind === 'implementer') checkImplementerStatus(instance, errors)
        if (kind === 'reviewer') checkFindingIds(instance, options, errors)
        checkHeadAgreement(kind, instance, errors)
      }
    }
  }

  report(errors, `${kind} result OK (role=${instance.role ?? 'n/a'}, status=${instance.status ?? 'n/a'})`)
}

function report(errors, okMessage) {
  if (errors.length > 0) {
    for (const error of errors) console.error(`FAIL: ${error}`)
    process.exit(1)
  }
  console.log(okMessage)
}

main()
