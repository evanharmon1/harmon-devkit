#!/usr/bin/env node
// validate-result-schemas.mjs — schema-check one dev-flow-v2 result/record
// fixture, plus the receipt-validation checks a raw JSON Schema cannot
// express because they read a sibling field outside the instance a payload
// schema validates (envelope vs payload) or need context from other
// documents in the same run (prior passes, prior adjudications, the active
// run).
//
// Usage:
//   validate-result-schemas.mjs <kind> <file> [options]
//
//   kind: envelope | implementer | reviewer | integrator | adjudication | run
//   `envelope` dispatches on the instance's own `role` field (after the
//   envelope schema itself passes) and runs exactly the same payload +
//   receipt checks as invoking the role's own kind name directly — it is
//   not a payload-blind mode, just a way to validate a full result without
//   the caller having to already know its role.
//
//   --known-ids <file.json>       JSON array of finding ids already used
//                                 elsewhere in the run (reviewer only) —
//                                 rejects a collision (spec: "a finding id
//                                 is unique within the run by construction").
//   --run-id <id>                 The active run's run_id. Must be given
//   --initiated-by <human|foreman>  together with --initiated-by — one
//                                 without the other is a usage error, not a
//                                 guaranteed-mismatch: rejects an envelope
//                                 whose `run` names a different run.
//   --pass <envelope.json>        (adjudication only, repeatable) a reviewer
//                                 envelope this document adjudicates. Each
//                                 file is itself validated as a full
//                                 reviewer envelope (envelope schema +
//                                 reviewer payload + its own receipt checks,
//                                 no run context) before anything else runs;
//                                 an invalid --pass file fails immediately,
//                                 naming that file. With one or more --pass,
//                                 the document is cross-checked against the
//                                 UNION of their findings: completeness,
//                                 reviewer_priority fidelity, and that every
//                                 pass agrees with the others (and the
//                                 document) on run_id/stage/round/
//                                 reviewed_head.
//   --known-adjudicated <file.json>  (adjudication only) JSON array of
//                                 finding ids already adjudicated in an
//                                 earlier round document of this run —
//                                 rejects a collision (a finding is
//                                 adjudicated in exactly one round document,
//                                 ever).
//   --adjudication <file.json>   (run only, repeatable) an adjudication
//                                 document. Each file is itself validated as
//                                 a full adjudication document before
//                                 anything else runs; an invalid file fails
//                                 immediately, naming that file. With one or
//                                 more --adjudication, every settlement's
//                                 finding_id must be adjudicated exactly
//                                 once across the supplied documents, with
//                                 disposition `defer`.
//
// Exit 0 and a one-line summary when the fixture is valid; exit 1 and every
// violation (one per line) otherwise. A usage error (bad kind, missing
// file, a paired flag given alone) exits 2.
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { createSchemaValidator } from './lib/json-schema-subset.mjs'

const SCHEMAS_DIR = path.resolve('ai/schemas')
const KINDS = ['envelope', 'implementer', 'reviewer', 'integrator', 'adjudication', 'run']
const FINDING_ID = /^(challenge|review)-r([1-9][0-9]*)-(.+)-([1-9][0-9]*)$/
const SHA_PATTERN = /^[0-9a-f]{40}$/
const ISSUE_NUMBER_PATTERN = /^[1-9][0-9]*$/

function usage() {
  console.error(
    'usage: validate-result-schemas.mjs <envelope|implementer|reviewer|integrator|adjudication|run> <file> ' +
      '[--known-ids <file.json>] [--run-id <id> --initiated-by <human|foreman>] ' +
      '[--pass <file.json> ...] [--known-adjudicated <file.json>] [--adjudication <file.json> ...]'
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

// loadIdArray FILE FLAG — a JSON array of strings, or exit 1 naming exactly
// what is wrong. Never silently disable the check a malformed file was
// meant to feed: `Array.isArray` guards downstream would otherwise treat
// "not an array" the same as "no flag given at all".
function loadIdArray(file, flag) {
  const data = loadJson(file)
  if (!Array.isArray(data) || !data.every((entry) => typeof entry === 'string')) {
    console.error(`validate-result-schemas: ${flag} file ${file} must be a JSON array of strings`)
    process.exit(1)
  }
  return data
}

// loadAndValidateContext FILE FLAG VALIDATE — load FILE and run VALIDATE
// (one of validateEnvelopeInstance / validateAdjudicationInstance) over it;
// any error fails immediately, naming FILE, before the primary document is
// ever cross-checked against it.
function loadAndValidateContext(file, flag, validate) {
  const data = loadJson(file)
  const errors = validate(data)
  if (errors.length > 0) {
    console.error(`validate-result-schemas: ${flag} file ${file} is invalid:`)
    for (const error of errors) console.error(`  FAIL: ${error}`)
    process.exit(1)
  }
  return data
}

function parseArgs(argv) {
  const [kind, file, ...rest] = argv
  if (!kind || !file || !KINDS.includes(kind)) {
    usage()
    process.exit(2)
  }
  const options = {
    knownIds: null,
    runId: null,
    initiatedBy: null,
    passes: [],
    knownAdjudicated: null,
    adjudications: []
  }
  for (let i = 0; i < rest.length; i += 1) {
    switch (rest[i]) {
      case '--known-ids':
        options.knownIds = loadIdArray(rest[(i += 1)], '--known-ids')
        break
      case '--run-id':
        options.runId = rest[(i += 1)]
        break
      case '--initiated-by':
        options.initiatedBy = rest[(i += 1)]
        break
      case '--pass': {
        const passFile = rest[(i += 1)]
        const data = loadAndValidateContext(passFile, '--pass', (candidate) =>
          validateEnvelopeInstance(candidate, 'reviewer', { knownIds: null, runId: null, initiatedBy: null })
        )
        options.passes.push({ file: passFile, data })
        break
      }
      case '--known-adjudicated':
        options.knownAdjudicated = loadIdArray(rest[(i += 1)], '--known-adjudicated')
        break
      case '--adjudication': {
        const adjudicationFile = rest[(i += 1)]
        const data = loadAndValidateContext(adjudicationFile, '--adjudication', (candidate) =>
          validateAdjudicationInstance(candidate)
        )
        options.adjudications.push({ file: adjudicationFile, data })
        break
      }
      default:
        console.error(`validate-result-schemas: unknown option ${rest[i]}`)
        usage()
        process.exit(2)
    }
  }
  // --run-id and --initiated-by are one pair, not two independent flags: one
  // given without the other can never legitimately match (initiated_by is a
  // required enum, never null), so it is a usage error, not a guaranteed
  // rejection for the wrong reason.
  if ((options.runId === null) !== (options.initiatedBy === null)) {
    console.error('validate-result-schemas: --run-id and --initiated-by must be given together')
    usage()
    process.exit(2)
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

// checkAppliedDispositionsUnique — applied_dispositions[].finding_id must
// be unique. Always runs for role integrator, independent of `verdict`:
// this is a structural defect in the array itself, not a clean-verdict
// rule, and rejecting it explicitly (rather than building a keep-last Map
// keyed by finding_id, which silently drops the earlier entry) is the
// point — a duplicate here means two different claims about the same
// finding's disposition, and neither one should be silently discarded.
function checkAppliedDispositionsUnique(payload, errors) {
  const seen = new Set()
  for (const entry of payload.applied_dispositions ?? []) {
    if (typeof entry.finding_id !== 'string') continue
    if (seen.has(entry.finding_id)) {
      errors.push(`$result.payload.applied_dispositions: duplicate finding_id ${entry.finding_id}`)
    }
    seen.add(entry.finding_id)
  }
}

// checkIntegratorCleanVerdict — a `clean` verdict is a claim about the
// WHOLE payload, not just its own field: at least one check must actually
// have run (AGENTS.md's readiness gate: an empty check list is
// indeterminate, not a pass) and every one of them green-or-skipped, no
// thread may be left unanswered, the Codex cycle (if any) must itself be
// clean, and every finding raised must be accounted for by a non-deferred
// applied disposition. Same-document, always runs for role integrator —
// `verdict` and everything it constrains are all sibling fields of one
// payload instance.
function checkIntegratorCleanVerdict(payload, errors) {
  if (payload.verdict !== 'clean') return
  if (!Array.isArray(payload.checks) || payload.checks.length === 0) {
    errors.push('$result.payload.checks: must be non-empty when verdict is clean — an empty check list is indeterminate, not a pass')
  }
  for (const check of payload.checks ?? []) {
    if (check.bucket !== 'pass' && check.bucket !== 'skipping') {
      errors.push(
        `$result.payload.checks: ${check.name} has bucket ${JSON.stringify(check.bucket)}, incompatible with verdict clean`
      )
    }
  }
  if (Array.isArray(payload.unanswered_thread_roots) && payload.unanswered_thread_roots.length > 0) {
    errors.push('$result.payload.unanswered_thread_roots: must be empty when verdict is clean')
  }
  const cycle = payload.codex_cycle
  if (cycle !== null && cycle !== undefined) {
    if (cycle.exit_code !== 0 || !cycle.accepted) {
      errors.push(
        '$result.payload.codex_cycle: must be null, or exit_code 0 with accepted present, when verdict is clean'
      )
    }
  }
  const appliedTo = new Map(
    (payload.applied_dispositions ?? [])
      .filter((entry) => typeof entry.finding_id === 'string')
      .map((entry) => [entry.finding_id, entry.disposition])
  )
  for (const finding of payload.findings ?? []) {
    if (typeof finding.id !== 'string') continue
    if (!appliedTo.has(finding.id)) {
      errors.push(
        `$result.payload.findings: finding ${finding.id} has no applied disposition, required when verdict is clean`
      )
    }
  }
  for (const disposition of appliedTo.values()) {
    if (disposition === 'defer') {
      errors.push('$result.payload.applied_dispositions: a defer disposition is incompatible with verdict clean')
    }
  }
}

// validateEnvelopeInstance INSTANCE KIND OPTIONS — the full envelope +
// payload + receipt-validation pipeline, shared by the top-level `<kind>
// <file>` invocation and by --pass's own pre-validation of the reviewer
// envelope it names (kind: 'reviewer', OPTIONS carrying no run context).
function validateEnvelopeInstance(instance, kind, options) {
  const envelopeSchema = loadSchema('result.envelope.schema.json')
  const errors = validateAgainst(envelopeSchema, instance, '$result')

  // `envelope` dispatches on the instance's own role — it is NOT a
  // payload-blind mode. A caller who already knows the role (kind is one of
  // implementer/reviewer/integrator) gets the extra assertion that the
  // instance's role agrees with what they expected.
  if (errors.length === 0) {
    if (kind !== 'envelope' && instance.role !== kind) {
      errors.push(`$result.role: expected ${kind}, found ${JSON.stringify(instance.role)}`)
    } else {
      const role = instance.role
      const payloadSchema = loadSchema(`result.${role}.schema.json`)
      errors.push(...validateAgainst(payloadSchema, instance.payload, '$result.payload'))
      if (errors.length === 0) {
        checkActiveRun(instance, options, errors)
        if (role === 'implementer') checkImplementerStatus(instance, errors)
        if (role === 'reviewer') checkFindingIds(instance, options, errors)
        if (role === 'integrator') {
          checkAppliedDispositionsUnique(instance.payload, errors)
          checkIntegratorCleanVerdict(instance.payload, errors)
        }
        checkHeadAgreement(role, instance, errors)
      }
    }
  }
  checkTimestampRealness(instance, errors, '$result')
  return errors
}

// checkAdjudicationEntries — internal self-consistency, always run: no
// duplicate finding_id within the document, and override present (with a
// reason) exactly when adjudicated_priority differs from reviewer_priority.
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

// checkAdjudicationIdAttribution — self-contained (no --pass needed): a
// finding id's <stage>-r<round> segments are part of its own grammar, so
// they must equal the document's own stage/round without any external
// context at all.
function checkAdjudicationIdAttribution(document, errors) {
  for (const entry of document.adjudications ?? []) {
    if (typeof entry.finding_id !== 'string') continue
    const parsed = parseFindingId(entry.finding_id)
    if (!parsed) continue
    if (parsed.stage !== document.stage) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}]: names stage ${parsed.stage}, document is stage ${document.stage}`
      )
    }
    if (parsed.round !== document.round) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}]: names round ${parsed.round}, document is round ${document.round}`
      )
    }
  }
}

// checkAdjudicationUniqueAcrossRun — mirrors checkFindingIds' --known-ids
// collision check exactly, one document at a time: a finding is adjudicated
// in exactly one round document, ever, so any id already adjudicated by an
// earlier round (--known-adjudicated) is a collision here too.
function checkAdjudicationUniqueAcrossRun(document, options, errors) {
  if (!Array.isArray(options.knownAdjudicated)) return
  for (const entry of document.adjudications ?? []) {
    if (typeof entry.finding_id === 'string' && options.knownAdjudicated.includes(entry.finding_id)) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}]: already adjudicated in an earlier round document of this run`
      )
    }
  }
}

// checkAdjudicationAgainstPass — cross-checks an adjudication document
// against the reviewer pass(es) it adjudicates (--pass, repeatable — a
// logical round is one pass per configured finder at the same
// reviewed_head, spec § Configuration). Every pass agrees with every other
// on run_id/stage/round/reviewed_head (mismatch names the offending pass
// file); the document is checked against that same agreed metadata; every
// finding across the UNION of the passes has exactly one adjudication
// entry, no entry names an id absent from every pass, and each entry's
// reviewer_priority matches its finding's own priority. Without --pass,
// none of this runs — the document is still schema-valid and self-
// consistent on its own (checkAdjudicationEntries), just not cross-checked
// against anything external.
function checkAdjudicationAgainstPass(document, passes, errors) {
  if (passes.length === 0) return
  const [reference, ...rest] = passes
  for (const other of rest) {
    if (other.data.run.run_id !== reference.data.run.run_id) {
      errors.push(
        `$adjudication: --pass ${other.file} has run_id ${other.data.run.run_id}, disagreeing with ${reference.file}'s ${reference.data.run.run_id}`
      )
    }
    if (other.data.payload.stage !== reference.data.payload.stage) {
      errors.push(
        `$adjudication: --pass ${other.file} has stage ${other.data.payload.stage}, disagreeing with ${reference.file}'s ${reference.data.payload.stage}`
      )
    }
    if (other.data.payload.round !== reference.data.payload.round) {
      errors.push(
        `$adjudication: --pass ${other.file} has round ${other.data.payload.round}, disagreeing with ${reference.file}'s ${reference.data.payload.round}`
      )
    }
    if (other.data.payload.reviewed_head !== reference.data.payload.reviewed_head) {
      errors.push(
        `$adjudication: --pass ${other.file} has reviewed_head ${other.data.payload.reviewed_head}, disagreeing with ${reference.file}'s ${reference.data.payload.reviewed_head}`
      )
    }
  }

  // A round is one pass per configured finder (spec § Configuration); a
  // retry REPLACES that finder's pass, it never joins a second one at its
  // side. Two --pass files naming the same finder are therefore never a
  // legitimate two-finder round — reject and name the finder.
  const finderSeenAt = new Map()
  for (const { file, data } of passes) {
    const finder = data.payload.finder
    if (finderSeenAt.has(finder)) {
      errors.push(
        `$adjudication: --pass ${file} repeats finder ${finder}, already supplied by ${finderSeenAt.get(finder)} — a round is one pass per finder`
      )
    } else {
      finderSeenAt.set(finder, file)
    }
  }

  const passFindings = new Map()
  for (const { data } of passes) {
    for (const finding of data.payload.findings ?? []) {
      if (typeof finding.id === 'string') passFindings.set(finding.id, finding)
    }
  }
  const adjudicated = new Set()
  for (const entry of document.adjudications ?? []) {
    if (typeof entry.finding_id !== 'string') continue
    adjudicated.add(entry.finding_id)
    const finding = passFindings.get(entry.finding_id)
    if (!finding) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}]: names a finding id absent from every --pass`
      )
      continue
    }
    if (entry.reviewer_priority !== finding.priority) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}].reviewer_priority: ${entry.reviewer_priority} does not match the pass finding's own priority ${finding.priority}`
      )
    }
  }
  for (const id of passFindings.keys()) {
    if (!adjudicated.has(id)) {
      errors.push(`$adjudication.adjudications: pass finding ${id} has no adjudication entry`)
    }
  }

  const { run: referenceRun, payload: referencePayload } = reference.data
  if (document.run_id !== referenceRun.run_id) {
    errors.push(`$adjudication.run_id: ${document.run_id} does not match the pass envelope's run.run_id ${referenceRun.run_id}`)
  }
  if (document.stage !== referencePayload.stage) {
    errors.push(`$adjudication.stage: ${document.stage} does not match the pass payload's stage ${referencePayload.stage}`)
  }
  if (document.round !== referencePayload.round) {
    errors.push(`$adjudication.round: ${document.round} does not match the pass payload's round ${referencePayload.round}`)
  }
  if (document.reviewed_head !== referencePayload.reviewed_head) {
    errors.push(
      `$adjudication.reviewed_head: ${document.reviewed_head} does not match the pass payload's reviewed_head ${referencePayload.reviewed_head}`
    )
  }
}

// validateAdjudicationInstance INSTANCE — schema + the always-on internal
// checks, shared by the top-level `adjudication <file>` invocation and by
// --adjudication's own pre-validation before it is used as run-kind
// context.
function validateAdjudicationInstance(instance) {
  const schema = loadSchema('adjudication.schema.json')
  const errors = validateAgainst(schema, instance, '$adjudication')
  if (errors.length === 0) {
    checkAdjudicationEntries(instance, errors)
    checkAdjudicationIdAttribution(instance, errors)
  }
  checkTimestampRealness(instance, errors, '$adjudication')
  return errors
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

// checkSettlementReferenceType — a settlement's reference.type must match
// its disposition (fix -> sha, file -> issue_number, decline -> comment_id)
// and the value must be shaped for that type. Same-document: disposition
// and reference are sibling fields of one settlement entry.
function checkSettlementReferenceType(document, errors) {
  const expectedType = { fix: 'sha', file: 'issue_number', decline: 'comment_id' }
  for (const [index, entry] of (document.settlements ?? []).entries()) {
    const reference = entry.reference
    if (!reference || typeof reference !== 'object') continue
    const expected = expectedType[entry.disposition]
    if (expected && reference.type !== expected) {
      errors.push(
        `$run.settlements[${index}].reference.type: disposition ${entry.disposition} requires type ${expected}, found ${JSON.stringify(reference.type)}`
      )
      continue
    }
    if (reference.type === 'sha' && typeof reference.value === 'string' && !SHA_PATTERN.test(reference.value)) {
      errors.push(`$run.settlements[${index}].reference.value: type sha requires a 40-hex value`)
    } else if (
      reference.type === 'issue_number' &&
      typeof reference.value === 'string' &&
      !ISSUE_NUMBER_PATTERN.test(reference.value)
    ) {
      errors.push(`$run.settlements[${index}].reference.value: type issue_number requires a positive integer string`)
    } else if (reference.type === 'comment_id' && typeof reference.value === 'string' && reference.value.trim() === '') {
      errors.push(`$run.settlements[${index}].reference.value: type comment_id requires a non-empty value`)
    }
  }
}

// checkRunPromotionOutcome — promotion is non-null if and only if outcome
// is "ready-for-review", in both directions: a promoted run that reports a
// different outcome, or a ready-for-review outcome with no promotion
// entry, are both inconsistent documents. Reaching ready-for-review always
// means a PR exists (the readiness gate promotes a draft PR — there is no
// promotion without one), so both of those states additionally require a
// non-null `pr`.
function checkRunPromotionOutcome(document, errors) {
  const promoted = document.promotion !== null && document.promotion !== undefined
  const ready = document.outcome === 'ready-for-review'
  if (promoted && !ready) {
    errors.push(`$run.promotion: present but outcome is ${JSON.stringify(document.outcome)}, not "ready-for-review"`)
  }
  if (ready && !promoted) {
    errors.push('$run.promotion: must be non-null when outcome is "ready-for-review"')
  }
  if ((promoted || ready) && (document.pr === null || document.pr === undefined)) {
    errors.push('$run.pr: must be non-null when outcome is "ready-for-review" or promotion is present')
  }
}

// checkEvidenceCommentsUniqueness — evidence_comments[].id is unique (it is
// the harvester's own lookup key), and each (marker.run_id, marker.stage,
// marker.sequence) triple is unique (that triple IS the deterministic
// marker the spec describes — two comments cannot legitimately share one).
function checkEvidenceCommentsUniqueness(document, errors) {
  const seenIds = new Set()
  const seenMarkers = new Set()
  for (const [index, comment] of (document.evidence_comments ?? []).entries()) {
    if (typeof comment.id === 'string') {
      if (seenIds.has(comment.id)) {
        errors.push(`$run.evidence_comments[${index}].id: duplicate comment id ${comment.id}`)
      }
      seenIds.add(comment.id)
    }
    const marker = comment.marker
    if (
      marker &&
      typeof marker.run_id === 'string' &&
      typeof marker.stage === 'string' &&
      typeof marker.sequence === 'number'
    ) {
      const key = JSON.stringify([marker.run_id, marker.stage, marker.sequence])
      if (seenMarkers.has(key)) {
        errors.push(
          `$run.evidence_comments[${index}].marker: duplicate marker (run_id=${marker.run_id}, stage=${marker.stage}, sequence=${marker.sequence})`
        )
      }
      seenMarkers.add(key)
    }
  }
}

// checkEvidenceMarkerRunId — every evidence comment's marker names the SAME
// run it was posted for; a marker naming a foreign run_id could otherwise
// be adopted by the wrong run's harvester (spec § Evidence, "a deterministic
// marker — run_id, stage, sequence"). Context-free: both fields live in the
// one run.schema.json document, no external input needed.
function checkEvidenceMarkerRunId(document, errors) {
  if (!Array.isArray(document.evidence_comments)) return
  for (const [index, comment] of document.evidence_comments.entries()) {
    const marker = comment.marker
    if (marker && typeof marker.run_id === 'string' && marker.run_id !== document.run_id) {
      errors.push(
        `$run.evidence_comments[${index}].marker.run_id: ${marker.run_id} does not match the run's own run_id ${document.run_id}`
      )
    }
  }
}

// checkAdjudicationRunIdMatchesRun — each --adjudication document's own
// run_id must equal the run record's run_id: a foreign run's adjudication
// document could otherwise settle a finding_id that only coincidentally
// collides with one from THIS run (finding ids are unique within a run,
// not globally). Named per offending file, same as the pass-agreement
// checks above.
function checkAdjudicationRunIdMatchesRun(document, adjudications, errors) {
  for (const { file, data } of adjudications) {
    if (data.run_id !== document.run_id) {
      errors.push(
        `$run: --adjudication ${file} has run_id ${data.run_id}, not this run's own run_id ${document.run_id}`
      )
    }
  }
}

// checkSettlementsAgainstAdjudications — with one or more --adjudication
// documents supplied, every settlement's finding must be adjudicated
// exactly once across the union of those documents, with disposition
// defer (settlements only ever terminalize a deferred finding). Without
// --adjudication, unchanged — settlements are still checked for internal
// duplicate finding_id (checkSettlements) but not against any adjudication.
function checkSettlementsAgainstAdjudications(document, adjudications, errors) {
  if (adjudications.length === 0) return
  const byFindingId = new Map()
  for (const { file, data } of adjudications) {
    for (const entry of data.adjudications ?? []) {
      if (typeof entry.finding_id !== 'string') continue
      if (!byFindingId.has(entry.finding_id)) byFindingId.set(entry.finding_id, [])
      byFindingId.get(entry.finding_id).push({ disposition: entry.disposition, file })
    }
  }
  for (const [index, settlement] of (document.settlements ?? []).entries()) {
    const matches = byFindingId.get(settlement.finding_id) ?? []
    if (matches.length === 0) {
      errors.push(
        `$run.settlements[${index}]: finding ${settlement.finding_id} is not adjudicated in any supplied --adjudication document`
      )
      continue
    }
    if (matches.length > 1) {
      errors.push(
        `$run.settlements[${index}]: finding ${settlement.finding_id} is adjudicated more than once across the supplied --adjudication documents (${matches
          .map((match) => match.file)
          .join(', ')})`
      )
      continue
    }
    if (matches[0].disposition !== 'defer') {
      errors.push(
        `$run.settlements[${index}]: finding ${settlement.finding_id} was adjudicated ${matches[0].disposition}, not defer, in ${matches[0].file}`
      )
    }
  }
}

// checkTimestampRealness — every *_at / at field must be a REAL instant, not
// merely regex-shaped: "2026-02-30T10:00:00Z" matches every schema's
// timestamp pattern but names a day that does not exist. JS's Date parser
// silently rolls an impossible date over into the next real one, so a
// round-trip through it — and back to the same Y-M-D h:m:s — is exactly the
// test. One generic walk over the whole instance (any object key equal to
// "at" or ending in "_at") rather than a per-schema keyword, since the
// subset engine's `pattern` keyword can only check shape, never calendar
// validity, and every schema in this family uses the same timestamp shape.
const TIMESTAMP_KEY = /(^at$|_at$)/
const TIMESTAMP_PARTS = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/

function isRealInstant(value) {
  const input = TIMESTAMP_PARTS.exec(value)
  if (!input) return true // shape violations are the schema pattern's job, not this check's
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return false
  const rendered = TIMESTAMP_PARTS.exec(parsed.toISOString())
  if (!rendered) return false
  // Compare Y-M-D h:m:s (index 1-6); fractional seconds are deliberately
  // excluded from the comparison, since normalising "no fraction" vs
  // ".000" vs any other valid fractional spelling of the same instant is
  // not what this check is proving.
  for (let i = 1; i <= 6; i += 1) {
    if (input[i] !== rendered[i]) return false
  }
  return true
}

function checkTimestampRealness(value, errors, location) {
  if (value === null || typeof value !== 'object') return
  if (Array.isArray(value)) {
    value.forEach((item, index) => checkTimestampRealness(item, errors, `${location}[${index}]`))
    return
  }
  for (const [key, child] of Object.entries(value)) {
    const childLocation = `${location}.${key}`
    if (TIMESTAMP_KEY.test(key) && typeof child === 'string' && !isRealInstant(child)) {
      errors.push(`${childLocation}: ${JSON.stringify(child)} is not a real instant`)
    }
    checkTimestampRealness(child, errors, childLocation)
  }
}

function main() {
  const { kind, file, options } = parseArgs(process.argv.slice(2))
  const instance = loadJson(file)

  if (kind === 'adjudication') {
    const errors = validateAdjudicationInstance(instance)
    if (errors.length === 0) {
      if (options.passes.length > 0) checkAdjudicationAgainstPass(instance, options.passes, errors)
      checkAdjudicationUniqueAcrossRun(instance, options, errors)
    }
    report(errors, 'adjudication record OK')
    return
  }

  if (kind === 'run') {
    const schema = loadSchema('run.schema.json')
    const errors = validateAgainst(schema, instance, '$run')
    if (errors.length === 0) {
      checkSettlements(instance, errors)
      checkEvidenceMarkerRunId(instance, errors)
      checkEvidenceCommentsUniqueness(instance, errors)
      checkRunPromotionOutcome(instance, errors)
      checkSettlementReferenceType(instance, errors)
      if (options.adjudications.length > 0) {
        checkAdjudicationRunIdMatchesRun(instance, options.adjudications, errors)
        checkSettlementsAgainstAdjudications(instance, options.adjudications, errors)
      }
    }
    checkTimestampRealness(instance, errors, '$run')
    report(errors, 'run record OK')
    return
  }

  const errors = validateEnvelopeInstance(instance, kind, options)
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
