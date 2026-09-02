#!/usr/bin/env node
// render-dev-flow.mjs — deterministic projections from validated Dev flow v2
// records (ai/schemas/adjudication.schema.json, run.schema.json, result
// envelopes), plus a `publish` subcommand that merges marked generated
// sections into a draft PR body. specs/dev-flow-v2.md 'Rendering is a
// projection, never another source of truth': every projection here is a
// pure function of its record inputs, never a place that infers a
// disposition or re-authors a decision the adjudication record already made.
//
// Usage:
//   render-dev-flow.mjs <projection> --record <dir> [options]
//   render-dev-flow.mjs publish --record <dir> --repo <owner/repo> --pr <n>
//                                --head <sha> --sections <a,b,...> [options]
//
// Projections:
//   deferred-findings     Markdown task list of every `defer`-dispositioned
//                         finding — `` `<finding_id>` <location> — <summary> ``,
//                         unchecked until a run.json settlement terminalizes
//                         it (fix/decline/file grammar below).
//   adjudication-record   Markdown: one collapsed <details> table per
//                         supplied adjudication document (round), columns
//                         finding/reviewer-priority/adjudicated-priority/
//                         classification/evidence/action/provenance.
//   round-table           Markdown: the same table for exactly ONE round
//                         (--stage/--round, or the sole round supplied),
//                         plus an Exit line from --verdict when given.
//   policy-disclosure     Markdown: the rigor announcement line, plus any
//                         off-default/off-profile disclosures, from
//                         --policy.
//   blocker-comment       Markdown: head/stage/outcome/unresolved/next
//                         action, from run.json + --verdict. Requires --head
//                         (the caller's actual current HEAD — never inferred
//                         from adjudication order, which can lag behind an
//                         unreviewed fix push).
//   thread-reply-plan     JSON: {finding_id, root_comment_id, reply_text,
//                         head, adjudicated_priority, classification,
//                         evidence, action} per integration-stage finding
//                         whose source_id is a still-unanswered inline
//                         thread root (result.integrator.schema.json
//                         unanswered_thread_roots) — the only stage whose
//                         findings carry a GitHub-native source_id at all
//                         (see ai/schemas/README.md).
//   readiness-input       JSON: settled/unsettled deferred findings by id,
//                         for the readiness gate to consume instead of
//                         parsing Markdown. Requires --head, same reasoning
//                         as blocker-comment.
//
// A record directory (--record <dir>) holds:
//   run.json              One run.schema.json document. Required except when
//                         rendering adjudication-record/round-table without
//                         any settlement/blocker context.
//   adjudications/*.json  One or more adjudication.schema.json documents
//                         (one per round). Every *.json file in the
//                         directory is read; order is irrelevant, output
//                         order is always recomputed from content.
//   passes/*.json         Result envelopes (role challenger/reviewer/integrator) that
//                         the adjudications reference, enriching a finding
//                         with path/line/class/provenance/fingerprint/finder
//                         (challenge/review) or body/source_id (integration).
//                         Optional for most projections: a finding_id with no
//                         matching pass still renders, using only what the
//                         adjudication entry itself carries. deferred-findings
//                         and thread-reply-plan are the exceptions — both
//                         REQUIRE the matching pass for every finding they
//                         touch (a missing one is an indeterminate error, not
//                         a reduced-fidelity render), since both feed a
//                         downstream action (a PR-body task list, a GitHub
//                         reply) where "identity doubling as location" or "we
//                         couldn't tell if this thread is answered" would be
//                         silently wrong rather than merely thin.
//   verdict.json          Optional. The exit-computation verdict (#636):
//                         {outcome, reason, rounds_counted, next_round,
//                         corrections[]}, consumed as-is.
//   policy.json           Optional. Resolved-policy disclosure input (this
//                         script's own contract, since no upstream schema
//                         defines one yet):
//                         {rigor:{level,source}, rounds:{challenge,review,
//                         integration,remediation,min_rounds},
//                         disclosures:[{kind,detail}]}.
//
// Every record is checked, beyond schema validity, for local (single-
// directory) cross-document consistency before anything renders: a pass
// naming a different head/run_id than the adjudication that references it,
// a settlement naming a finding absent from every supplied adjudication
// document, a settlement for a finding never dispositioned `defer`, or a
// settlement whose reference shape (type AND value) disagrees with its own
// disposition are all rejected, as is a copied reviewer_priority that has
// drifted from its source pass, an adjudication document from a foreign
// run, a duplicate finding id across adjudication files, a pass whose role
// does not match the stage that cross-references it, and a `defer`
// disposition on an integration-stage finding (renderer/spec.md
// "Publication SHALL validate local sidecar entries against adjudications"
// — applied to every projection, not only publish, since an inconsistent
// record is suspect for all of them).
//
// publish additionally requires --repo, --pr, --head, and --sections (a
// comma list drawn from policy-disclosure, deferred-findings,
// adjudication-record — the three sections that live in the PR body; the
// caller states explicitly which ones this call updates, so a section is
// never silently republished or silently skipped), and rejects a --pr that
// disagrees with run.json's own `pr` (a `pr-mismatch` blocker) and a second
// concurrent invocation against the same --record directory (a
// `concurrent-publish` blocker; see "Publish algorithm" below).
//
// Exit 0 on success (rendered output on stdout, or --out). Exit 1 on a
// rendering error (malformed record, e.g. a settlement referencing an
// unknown finding) or a publish blocker (a JSON blocker object is printed
// instead of a result). Exit 2 on a usage error.
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createSchemaValidator } from './lib/json-schema-subset.mjs'

const DEFAULT_SCHEMAS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'ai', 'schemas')
const PROJECTIONS = [
  'deferred-findings',
  'adjudication-record',
  'round-table',
  'policy-disclosure',
  'blocker-comment',
  'thread-reply-plan',
  'readiness-input'
]
const PUBLISHABLE_SECTIONS = ['policy-disclosure', 'deferred-findings', 'adjudication-record']
const FINDING_ID = /^(challenge|review|integration)-r([1-9][0-9]*)-([a-z0-9-]+)-([1-9][0-9]*)$/
const STAGE_ORDER = { challenge: 0, review: 1, integration: 2 }
// Which pass role(s) may legitimately back a finding at each stage. Challenge
// accepts both: result.challenger.schema.json (#635) is the current role for
// a challenge-stage pass, but result.reviewer.schema.json's own `stage` enum
// still admits "challenge" too (unchanged by #635) for a pre-#635 record
// still using that role — both remain schema-valid simultaneously. Review and
// integration accept exactly one role each; a challenger pass never carries a
// review-stage finding (its own schema fixes `stage` to a `const`).
const STAGE_ROLES = { challenge: ['challenger', 'reviewer'], review: ['reviewer'], integration: ['integrator'] }
const SETTLEMENT_GRAMMAR = { fix: 'fixed in', decline: 'declined:', file: 'filed as' }
const REPLY_VERB = { fix: 'Fixed', restructure: 'Restructured', delete: 'Removed', decline: 'Declined', file: 'Filed' }

function usage() {
  console.error(
    'usage: render-dev-flow.mjs <' +
      PROJECTIONS.join('|') +
      '> --record <dir> [--out <file>] [--stage <s>] [--round <n>] ' +
      '[--verdict <file>] [--policy <file>] [--schemas-dir <dir>]\n' +
      '   or: render-dev-flow.mjs publish --record <dir> --repo <owner/repo> --pr <n> ' +
      '--head <sha> --sections <a,b,...> [--max-retries <n>] [--schemas-dir <dir>]'
  )
}

function fail(message) {
  console.error(`render-dev-flow: ${message}`)
  process.exit(1)
}

function usageError(message) {
  console.error(`render-dev-flow: ${message}`)
  usage()
  process.exit(2)
}

// ── argv ────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  if (argv.length === 0) usageError('missing projection or subcommand')
  const command = argv[0]
  if (command !== 'publish' && !PROJECTIONS.includes(command)) {
    usageError(`unknown projection or subcommand: ${command}`)
  }
  const options = { command, sections: null }
  let i = 1
  while (i < argv.length) {
    const arg = argv[i]
    const need = (flag) => {
      if (i + 1 >= argv.length) usageError(`${flag} requires a value`)
      i += 1
      return argv[i]
    }
    switch (arg) {
      case '--record':
        options.record = need(arg)
        break
      case '--out':
        options.out = need(arg)
        break
      case '--stage':
        options.stage = need(arg)
        break
      case '--round': {
        const raw = need(arg)
        options.round = Number.parseInt(raw, 10)
        if (!Number.isInteger(options.round) || String(options.round) !== raw) {
          usageError(`--round must be an integer, got ${raw}`)
        }
        break
      }
      case '--verdict':
        options.verdictFile = need(arg)
        break
      case '--policy':
        options.policyFile = need(arg)
        break
      case '--repo':
        options.repo = need(arg)
        break
      case '--pr':
        options.pr = Number.parseInt(need(arg), 10)
        break
      case '--head':
        options.head = need(arg)
        break
      case '--sections':
        options.sections = need(arg)
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean)
        break
      case '--max-retries':
        options.maxRetries = Number.parseInt(need(arg), 10)
        break
      case '--schemas-dir':
        options.schemasDir = need(arg)
        break
      default:
        usageError(`unrecognized argument: ${arg}`)
    }
    i += 1
  }
  if (!options.record) usageError('--record <dir> is required')
  if (!fs.existsSync(options.record) || !fs.statSync(options.record).isDirectory()) {
    usageError(`--record ${options.record} is not a directory`)
  }
  if (command === 'publish') {
    if (!options.repo) usageError('publish requires --repo <owner/repo>')
    if (!options.pr) usageError('publish requires --pr <n>')
    if (!options.head) usageError('publish requires --head <sha>')
    if (!options.sections || options.sections.length === 0) {
      usageError('publish requires --sections <a,b,...>')
    }
    for (const section of options.sections) {
      if (!PUBLISHABLE_SECTIONS.includes(section)) {
        usageError(`unknown publishable section: ${section} (expected one of ${PUBLISHABLE_SECTIONS.join(', ')})`)
      }
    }
    options.maxRetries = Number.isInteger(options.maxRetries) ? options.maxRetries : 3
    if (options.maxRetries < 0) usageError(`--max-retries must be a non-negative integer, got ${options.maxRetries}`)
  }
  return options
}

// ── I/O + schema validation ────────────────────────────────────────────

function loadJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`cannot read valid JSON from ${file}: ${error.message}`)
  }
  return undefined
}

function listJsonFiles(dir) {
  if (!fs.existsSync(dir)) return []
  return fs
    .readdirSync(dir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((name) => path.join(dir, name))
}

function validateAgainst(schemasDir, schemaBasename, instance, location) {
  const schema = loadJson(path.join(schemasDir, schemaBasename))
  const engine = createSchemaValidator(schema)
  const errors = engine.validate(instance, schema, location)
  if (errors.length > 0) {
    fail(`${location} fails ${schemaBasename}:\n  ${errors.join('\n  ')}`)
  }
}

// loadRecord DIR SCHEMAS_DIR — read and schema-validate every document in a
// record directory. Structural (schema) validation only — this schema
// family's full receipt suite (run chronology, run-wide id collisions,
// cross-run context) stays validate-result-schemas.mjs's job upstream of
// this renderer, since it needs context (prior runs, --known-ids) no single
// --record directory carries. What IS local to one record directory —
// whether its own settlements and passes agree with its own adjudications —
// is this renderer's obligation too (renderer/spec.md "Publication SHALL
// validate local sidecar entries against adjudications"): see
// validateCrossDocumentConsistency, run once in main() over the loaded
// record. A malformed document fails loudly naming the file, rather than
// silently rendering from a partial parse.
function loadRecord(dir, schemasDir) {
  const record = { run: null, adjudications: [], passes: [], verdict: null, policy: null }

  const runFile = path.join(dir, 'run.json')
  if (fs.existsSync(runFile)) {
    record.run = loadJson(runFile)
    validateAgainst(schemasDir, 'run.schema.json', record.run, runFile)
  }

  const seenStageRound = new Map()
  for (const file of listJsonFiles(path.join(dir, 'adjudications'))) {
    const doc = loadJson(file)
    validateAgainst(schemasDir, 'adjudication.schema.json', doc, file)
    // The record-directory contract is one adjudication document per round
    // (this README's own "adjudications/*.json ... one per round"; a round
    // is one document because a round's evidence is posted as one comment,
    // docs/decisions/0002). Two files both claiming the same (stage, round)
    // with non-overlapping finding ids would not trip the duplicate-
    // finding-id check below, but adjudication-record would then render
    // BOTH files' rows under EACH file's <details> block (the row filter
    // matches by stage+round, not by source file) — the same table
    // duplicated, not two distinct rounds.
    const stageRoundKey = `${doc.stage}-r${doc.round}`
    if (seenStageRound.has(stageRoundKey)) {
      fail(`${file}: ${doc.stage} round ${doc.round} is already claimed by ${seenStageRound.get(stageRoundKey)} — one adjudication document per round`)
    }
    seenStageRound.set(stageRoundKey, file)
    record.adjudications.push({ file, doc })
  }

  for (const file of listJsonFiles(path.join(dir, 'passes'))) {
    const envelope = loadJson(file)
    validateAgainst(schemasDir, 'result.envelope.schema.json', envelope, file)
    if (envelope.role !== 'reviewer' && envelope.role !== 'integrator' && envelope.role !== 'challenger') {
      fail(`${file}: passes/ may only hold challenger, reviewer, or integrator envelopes, got role ${envelope.role}`)
    }
    validateAgainst(schemasDir, `result.${envelope.role}.schema.json`, envelope.payload, `${file}#/payload`)
    record.passes.push({ file, envelope })
  }

  const verdictFile = path.join(dir, 'verdict.json')
  if (fs.existsSync(verdictFile)) {
    record.verdict = loadJson(verdictFile)
    validateVerdictShape(record.verdict, verdictFile)
  }

  const policyFile = path.join(dir, 'policy.json')
  if (fs.existsSync(policyFile)) {
    record.policy = loadJson(policyFile)
    validatePolicyShape(record.policy, policyFile)
  }

  return record
}

// verdict.json and policy.json are this renderer's OWN contracts (no
// upstream ai/schemas/*.schema.json family owns them, so there is no
// createSchemaValidator schema to hand off to) — but they are still
// "present, so validated" like every other document here: a valid-JSON file
// that violates the documented shape must fail loudly naming the file, not
// silently render an incomplete disclosure or throw an uncaught TypeError
// reading a field that turned out to be the wrong type.
function validateVerdictShape(verdict, file) {
  if (typeof verdict !== 'object' || verdict === null || Array.isArray(verdict)) {
    fail(`${file}: must be a JSON object`)
  }
  if (typeof verdict.outcome !== 'string' || verdict.outcome === '') {
    fail(`${file}: outcome must be a non-empty string`)
  }
  if (verdict.reason !== undefined && typeof verdict.reason !== 'string') {
    fail(`${file}: reason, if present, must be a string`)
  }
  if (verdict.rounds_counted !== undefined && !Number.isInteger(verdict.rounds_counted)) {
    fail(`${file}: rounds_counted, if present, must be an integer`)
  }
  if (verdict.next_round !== undefined && !Number.isInteger(verdict.next_round)) {
    fail(`${file}: next_round, if present, must be an integer`)
  }
  if (verdict.corrections !== undefined) {
    if (!Array.isArray(verdict.corrections) || !verdict.corrections.every((c) => typeof c === 'string')) {
      fail(`${file}: corrections, if present, must be an array of strings`)
    }
  }
}

function validatePolicyShape(policy, file) {
  if (typeof policy !== 'object' || policy === null || Array.isArray(policy)) {
    fail(`${file}: must be a JSON object`)
  }
  if (typeof policy.rigor !== 'object' || policy.rigor === null || Array.isArray(policy.rigor)) {
    fail(`${file}: rigor must be an object`)
  }
  if (typeof policy.rigor.level !== 'string' || policy.rigor.level === '') {
    fail(`${file}: rigor.level must be a non-empty string`)
  }
  if (typeof policy.rigor.source !== 'string' || policy.rigor.source === '') {
    fail(`${file}: rigor.source must be a non-empty string`)
  }
  if (policy.rounds !== undefined) {
    if (typeof policy.rounds !== 'object' || policy.rounds === null || Array.isArray(policy.rounds)) {
      fail(`${file}: rounds, if present, must be an object`)
    }
    // Each cap is individually validated, not just the container: an
    // untyped value here (a string, a negative number, a nested object)
    // would otherwise reach policyLine's template string unexamined and
    // publish a garbled or nonsensical resolved-policy disclosure.
    for (const key of ['challenge', 'review', 'integration', 'remediation', 'min_rounds']) {
      const value = policy.rounds[key]
      if (value !== undefined && !(Number.isInteger(value) && value >= 0)) {
        fail(`${file}: rounds.${key}, if present, must be a non-negative integer`)
      }
    }
  }
  if (policy.disclosures !== undefined) {
    if (!Array.isArray(policy.disclosures)) fail(`${file}: disclosures, if present, must be an array`)
    for (const d of policy.disclosures) {
      if (typeof d !== 'object' || d === null || typeof d.kind !== 'string' || typeof d.detail !== 'string') {
        fail(`${file}: each disclosures[] entry must be {kind: string, detail: string}`)
      }
    }
  }
}

// ── finding index ──────────────────────────────────────────────────────

// A finding's identity is the SAME across the adjudication entry and its
// originating pass (specs/dev-flow-v2.md: "a finding id is unique within the
// run by construction"). This joins the two so a projection can render
// path/line/class/provenance when a pass is supplied, while still rendering
// (with reduced fidelity) when it is not — a projection that only needs the
// adjudication side must not require passes/ to exist.
function buildFindingIndex(record) {
  const passFindingsById = new Map()
  for (const { file, envelope } of record.passes) {
    const findings = envelope.payload.findings || []
    const unansweredThreadRoots =
      envelope.role === 'integrator' ? new Set(envelope.payload.unanswered_thread_roots || []) : null
    for (const finding of findings) {
      if (passFindingsById.has(finding.id)) {
        fail(`${file}: finding id ${finding.id} also appears in an earlier pass file`)
      }
      passFindingsById.set(finding.id, {
        finding,
        role: envelope.role,
        head: envelope.head,
        runId: envelope.run.run_id,
        unansweredThreadRoots
      })
    }
  }

  const entries = []
  const seenFindingIds = new Map()
  for (const { file, doc } of record.adjudications) {
    for (const entry of doc.adjudications) {
      const idMatch = FINDING_ID.exec(entry.finding_id)
      if (!idMatch) fail(`${file}: malformed finding id ${entry.finding_id}`)
      // A finding is adjudicated in exactly one round document, ever
      // (adjudication.schema.json's own $comment) — two adjudication files
      // naming the same finding_id (a stray copy, or two rounds disagreeing
      // about who owns it) must not silently render twice or let a Map
      // keyed by finding_id keep only the last one during settlement
      // validation.
      if (seenFindingIds.has(entry.finding_id)) {
        fail(`${file}: finding id ${entry.finding_id} was already adjudicated in ${seenFindingIds.get(entry.finding_id)}`)
      }
      seenFindingIds.set(entry.finding_id, file)
      entries.push({
        entry,
        stage: doc.stage,
        round: doc.round,
        reviewed_head: doc.reviewed_head,
        run_id: doc.run_id,
        finder: idMatch[3],
        n: Number.parseInt(idMatch[4], 10),
        pass: passFindingsById.get(entry.finding_id) || null
      })
    }
  }
  return entries
}

const EXPECTED_REFERENCE_TYPE = { fix: 'sha', decline: 'comment_id', file: 'issue_number' }
const REFERENCE_VALUE_PATTERN = { sha: /^[0-9a-f]{40}$/, issue_number: /^[1-9][0-9]*$/ }

// validateCrossDocumentConsistency — the local (single-record-directory)
// checks renderer/spec.md requires before publication, and that every
// projection benefits from: a settlement naming a finding this record set
// never adjudicated ("orphan"), settling a finding that was never deferred,
// pairing a disposition with the wrong reference shape or a malformed
// reference value, or an adjudication document naming a different run
// entirely, are all indistinguishable from a real, in-run settlement by
// JSON Schema alone (schema validates each document on its own; these
// invariants span two or three documents). A pass envelope naming a
// different head/run_id than the adjudication it was cross-referenced by
// would otherwise let a stale or foreign pass silently enrich a finding it
// does not actually belong to; an adjudication document from a foreign run
// would otherwise let a same-run_id-looking-but-actually-different finding
// id (ids are unique only WITHIN a run, per specs/dev-flow-v2.md) satisfy a
// settlement that was never really adjudicated by this run.
function validateCrossDocumentConsistency(record) {
  const rows = buildFindingIndex(record)
  const byId = new Map(rows.map((row) => [row.entry.finding_id, row]))

  if (record.run) {
    for (const { file, doc } of record.adjudications) {
      if (doc.run_id !== record.run.run_id) {
        fail(`${file}: its run_id ${doc.run_id} does not match run.json's run_id ${record.run.run_id}`)
      }
    }
  }

  for (const row of rows) {
    // "disposition: defer is rejected for stage integration" is a receipt
    // check in the schema family's own validator (adjudication.schema.json's
    // $comment; ai/schemas/README.md "Field-shape decisions"), not a
    // structural enum restriction the schema itself expresses — a
    // single-document violation could otherwise reach this renderer intact
    // and crash a projection (thread-reply-plan) with a confusing "unknown
    // disposition" error instead of a clear, attributed one.
    if (row.stage === 'integration' && row.entry.disposition === 'defer') {
      fail(`${row.entry.finding_id}: disposition 'defer' is not valid for stage integration (nothing downstream would ever settle it)`)
    }
    if (!row.pass) continue
    if (row.pass.head !== row.reviewed_head) {
      fail(
        `${row.entry.finding_id}: its pass envelope names head ${row.pass.head}, but the adjudicating document's reviewed_head is ${row.reviewed_head}`
      )
    }
    if (row.pass.runId !== row.run_id) {
      fail(
        `${row.entry.finding_id}: its pass envelope names run_id ${row.pass.runId}, but the adjudicating document's run_id is ${row.run_id}`
      )
    }
    const allowedRoles = STAGE_ROLES[row.stage] || []
    if (!allowedRoles.includes(row.pass.role)) {
      fail(
        `${row.entry.finding_id}: stage ${row.stage} requires a pass with role ${allowedRoles.join(' or ')}, but its matching pass has role ${row.pass.role}`
      )
    }
    // The adjudication's reviewer_priority is a COPY of the pass finding's
    // own priority, kept so "reviewer-vs-orchestrator disagreement can be
    // measured" (specs/dev-flow-v2.md) from the adjudication document alone.
    // A copy that has drifted from its source is worse than no copy: it
    // would publish a reviewer priority the actual pass no longer asserts,
    // silently hiding the very disagreement it exists to preserve. Mirrors
    // validate-result-schemas.mjs's own cross-check for the same reason.
    // Applies to challenger passes too — result.challenger.schema.json's
    // finding.priority is the same field under the same name, just from a
    // different role.
    if (
      (row.pass.role === 'reviewer' || row.pass.role === 'challenger') &&
      row.entry.reviewer_priority !== row.pass.finding.priority
    ) {
      fail(
        `${row.entry.finding_id}: its adjudication copies reviewer_priority ${row.entry.reviewer_priority}, but the matching pass finding's own priority is ${row.pass.finding.priority}`
      )
    }
  }

  if (!record.run) return
  for (const settlement of record.run.settlements) {
    const row = byId.get(settlement.finding_id)
    if (!row) {
      fail(
        `run.json: settlement for ${settlement.finding_id} names a finding absent from every supplied adjudication document (orphan settlement)`
      )
    }
    if (row.entry.disposition !== 'defer') {
      fail(
        `run.json: settlement for ${settlement.finding_id} names a finding whose adjudicated disposition is '${row.entry.disposition}', not 'defer' — only a deferred finding is ever settled`
      )
    }
    const expectedType = EXPECTED_REFERENCE_TYPE[settlement.disposition]
    if (settlement.reference.type !== expectedType) {
      fail(
        `run.json: settlement for ${settlement.finding_id} has disposition '${settlement.disposition}' but reference.type '${settlement.reference.type}' (expected '${expectedType}')`
      )
    }
    const valuePattern = REFERENCE_VALUE_PATTERN[settlement.reference.type]
    if (valuePattern && !valuePattern.test(settlement.reference.value)) {
      fail(
        `run.json: settlement for ${settlement.finding_id} has reference.type '${settlement.reference.type}' but value '${settlement.reference.value}' does not match the expected shape`
      )
    }
  }
}

function sortKey(row) {
  return [STAGE_ORDER[row.stage] ?? 99, row.round, row.finder, row.n]
}

function compareRows(a, b) {
  const ka = sortKey(a)
  const kb = sortKey(b)
  for (let i = 0; i < ka.length; i += 1) {
    if (ka[i] < kb[i]) return -1
    if (ka[i] > kb[i]) return 1
  }
  return 0
}

// Sourced from the originating pass's own `class` (design/correctness/
// hasFindingCore — true for a pass whose finding shares the challenge/review
// "finding core" (path/line/class/provenance/fingerprint/priority/
// recommended_disposition/evidence): result.reviewer.schema.json and
// result.challenger.schema.json declare it field-for-field identically
// (agent-registry.json #635 calls this the shared finding core, so #636's
// exit script can compute over both with no role-specific branch); an
// integrator finding has none of it.
function hasFindingCore(pass) {
  return Boolean(pass) && (pass.role === 'reviewer' || pass.role === 'challenger')
}

// consistency/hardening/nit) — never derived from `disposition`. Disposition
// and classification are independent workflow decisions (AGENTS.md's
// confirmed/plausible-but-unproven/false-positive taxonomy): a finding can be
// uncertain and still get `defer`red or `file`d, so "non-decline therefore
// confirmed" was a fabricated certainty the record never actually claimed.
// adjudication.schema.json carries no classification field of its own
// (additionalProperties: false, and it is not this renderer's schema to
// extend), so `class` — the one real, schema-backed categorical judgment a
// pass provides — is what this column actually reflects; 'n/a' without a
// matching pass or for an integration-stage finding (result.integrator
// findings carry no `class` either), same graceful-degradation rule
// `provenance()` already follows.
function classification(row) {
  return hasFindingCore(row.pass) ? row.pass.finding.class : 'n/a'
}

function shortSha(sha) {
  return typeof sha === 'string' ? sha.slice(0, 7) : sha
}

// The reviewer schema permits any non-empty string for `path` — free text a
// malformed or adversarial model output could shape into a marker token,
// same reasoning as summary()/reason. Every caller embeds this in Markdown,
// so it is neutralized here rather than at each call site.
function location(row) {
  if (row.pass && row.pass.finding.path) {
    const { path: p, line } = row.pass.finding
    return neutralizeMarkers(line === null || line === undefined ? p : `${p}:${line}`)
  }
  return row.entry.finding_id
}

function summary(row) {
  if (row.pass) {
    return row.pass.role === 'integrator' ? row.pass.finding.body : row.pass.finding.evidence
  }
  return row.entry.evidence
}

function provenance(row) {
  return hasFindingCore(row.pass) ? row.pass.finding.provenance : 'n/a'
}

// neutralizeMarkers — free text (a finding's own evidence/reason, a policy
// disclosure detail) is reviewer- or human-authored prose that this renderer
// does not control, and it is embedded verbatim inside a marked PR-body
// section or a Markdown task-list item. Two independent hazards, both fixed
// here so every plain-text (non-table) call site gets both for free:
//
// 1. Text that happens to quote "<!-- dev-flow:end:deferred-findings -->" —
//    a plausible thing to write when reviewing THIS renderer, and exactly
//    how one earlier finding here was raised — forges an extra marker:
//    mergeSections' regex has no way to tell a legitimate boundary from one
//    sitting inside a rendered sentence. HTML-entity-escaping just the
//    comment delimiters (not full HTML-escaping, which would mangle
//    unrelated `<`/`>` in ordinary prose) keeps the text human-readable — a
//    browser or GFM renderer still shows `<!--` — while making it
//    byte-distinct from a real marker on every later parse.
// 2. An embedded newline in a `- [ ] <location> — <summary>` task-list item
//    (schema-legal: `path`/`evidence` are unconstrained strings) turns a
//    continuation line into what Markdown parses as a SEPARATE list item —
//    a fabricated checkbox the human integration stage never adjudicated,
//    if the continuation happens to start with something list-item-shaped.
//    Folding every newline to `<br>` keeps the visual line break GFM
//    renders while keeping the raw source on one physical line, so there is
//    no line boundary left for a second `- [ ]`/`- [x]` to start on.
function neutralizeMarkers(text) {
  return String(text)
    .replaceAll('<!--', '&lt;!--')
    .replaceAll('-->', '--&gt;')
    .replaceAll('\r\n', '<br>')
    .replaceAll('\n', '<br>')
    .replaceAll('\r', '<br>')
}

function escapeCell(text) {
  return neutralizeMarkers(text).replaceAll('|', '\\|')
}

// ── settlements ─────────────────────────────────────────────────────────

function buildSettlementIndex(run) {
  const byId = new Map()
  if (!run) return byId
  for (const settlement of run.settlements) {
    if (byId.has(settlement.finding_id)) {
      fail(`run.json: duplicate settlement for finding ${settlement.finding_id}`)
    }
    byId.set(settlement.finding_id, settlement)
  }
  return byId
}

// The settlement schema carries only a bare comment id for a decline (see
// ai/schemas/README.md and run.schema.json's own reference.type comment) —
// no issue/PR number to build a permalink from, and no free-text reason: the
// reason lives in the referenced comment itself, not in this record. This
// renders exactly what the record has rather than guessing a URL shape.
// disposition (not reference.type) is authoritative — "there it is settled
// to fix, decline, or file" (specs/dev-flow-v2.md § Results) — validated by
// validateCrossDocumentConsistency to actually agree with reference.type
// before this ever runs.
function settlementSuffix(settlement) {
  const { disposition, reference } = settlement
  if (disposition === 'fix') return `${SETTLEMENT_GRAMMAR.fix} ${shortSha(reference.value)}`
  if (disposition === 'file') return `${SETTLEMENT_GRAMMAR.file} #${reference.value}`
  if (disposition === 'decline') return `${SETTLEMENT_GRAMMAR.decline} see comment ${neutralizeMarkers(reference.value)}`
  fail(`run.json: settlement for ${settlement.finding_id} has unknown disposition ${disposition}`)
  return ''
}

// ── markers ─────────────────────────────────────────────────────────────

function beginMarker(section) {
  return `<!-- dev-flow:begin:${section} -->`
}
function endMarker(section) {
  return `<!-- dev-flow:end:${section} -->`
}
function wrapSection(section, body) {
  return `${beginMarker(section)}\n${body.replace(/\n+$/, '')}\n${endMarker(section)}`
}

// mergeSections BODY SECTIONS — replace each named section's marked block in
// BODY with fresh content, preserving every other byte; append a new marked
// block (in PUBLISHABLE_SECTIONS order) for any section absent from BODY.
// Throws with a message naming the section on a malformed (mismatched or
// duplicated) marker pair — the caller reports that as a publish blocker
// rather than guessing which block to replace.
function mergeSections(body, sections) {
  let result = body
  const toAppend = []
  for (const section of Object.keys(sections)) {
    const re = new RegExp(
      `${escapeRegExp(beginMarker(section))}[\\s\\S]*?${escapeRegExp(endMarker(section))}`,
      'g'
    )
    const matches = result.match(re) || []
    if (matches.length > 1) {
      throw new Error(`duplicate marker pair for section ${section}`)
    }
    const beginCount = countOccurrences(result, beginMarker(section))
    const endCount = countOccurrences(result, endMarker(section))
    if (beginCount !== matches.length || endCount !== matches.length) {
      throw new Error(`mismatched begin/end marker for section ${section}`)
    }
    if (matches.length === 1) {
      result = result.replace(re, () => wrapSection(section, sections[section]))
    } else {
      toAppend.push(section)
    }
  }
  if (toAppend.length > 0) {
    const ordered = PUBLISHABLE_SECTIONS.filter((s) => toAppend.includes(s))
    const appended = ordered.map((s) => wrapSection(s, sections[s])).join('\n\n')
    // Every byte outside a marked section must survive verbatim — including
    // the existing body's own trailing newlines, which stripping-then-
    // re-adding a fixed separator would silently rewrite (3 trailing
    // newlines becoming exactly 2, say). Add only however many MORE
    // newlines are needed to reach a one-blank-line separation; never
    // remove what is already there.
    const trailingNewlines = (result.match(/\n*$/) || [''])[0].length
    const separator = '\n'.repeat(Math.max(0, 2 - trailingNewlines))
    result = `${result}${separator}${appended}\n`
  }
  return result
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function countOccurrences(haystack, needle) {
  return haystack.split(needle).length - 1
}

// ── projections ─────────────────────────────────────────────────────────

function tableHeader() {
  return (
    '| Finding | Reviewer | Adjudicated | Classification | Evidence | Action | Provenance |\n' +
    '| --- | --- | --- | --- | --- | --- | --- |'
  )
}

function tableRow(row) {
  const { entry } = row
  const adjudicated =
    entry.override === null
      ? entry.adjudicated_priority
      : `${entry.adjudicated_priority} (override: ${escapeCell(entry.override.reason)})`
  const action = `${entry.disposition} — ${escapeCell(entry.reason)}`
  return `| ${entry.finding_id} | ${entry.reviewer_priority ?? 'n/a'} | ${adjudicated} | ${classification(
    row
  )} | ${escapeCell(summary(row))} | ${action} | ${provenance(row)} |`
}

// Unlike adjudication-record/blocker-comment (audit trails that still carry
// value at reduced fidelity), a deferred-findings entry with no matching
// pass collapses "location" into a copy of "identity" (both become the bare
// finding_id) and "summary" into the adjudication's OWN evidence rather than
// the reviewer's — silently failing the renderer spec's own requirement
// that every deferred finding render with distinct identity, location, and
// summary. This is the PR-body task list a human or the integration stage
// acts on directly, so a missing pass here is an indeterminate error, the
// same treatment thread-reply-plan already gives a missing integrator pass.
function renderDeferredFindings(record) {
  const rows = buildFindingIndex(record)
    .filter((row) => row.entry.disposition === 'defer')
    .sort(compareRows)
  for (const row of rows) {
    if (!row.pass) {
      fail(
        `${row.entry.finding_id}: no matching pass supplied — deferred-findings requires the source pass for a real location and summary, not just the adjudication's own fields`
      )
    }
  }
  const settlements = buildSettlementIndex(record.run)
  const lines = ['## Deferred findings', '']
  if (rows.length === 0) {
    lines.push('None.')
  } else {
    for (const row of rows) {
      const settlement = settlements.get(row.entry.finding_id)
      // finding_id is required alongside location/summary — the renderer
      // spec names identity, location, and summary as three distinct
      // fields, and readiness-input/settlements are keyed by this id, so a
      // reader (or the integration stage) needs it visible here to
      // correlate a checkbox with either, especially when two findings
      // share a location or summary text. The id's own grammar
      // (^(challenge|review|integration)-r\d+-[a-z0-9-]+-\d+$) cannot
      // contain a marker or newline, so it needs no neutralization.
      const id = row.entry.finding_id
      const loc = location(row)
      const text = neutralizeMarkers(summary(row))
      if (settlement) {
        lines.push(`- [x] \`${id}\` ${loc} — ${text} — ${settlementSuffix(settlement)}`)
      } else {
        lines.push(`- [ ] \`${id}\` ${loc} — ${text}`)
      }
    }
  }
  return lines.join('\n')
}

function renderOneRoundTable(doc, rows) {
  const lines = [`<details>`, `<summary>${doc.stage} round ${doc.round} — reviewed ${doc.reviewed_head}</summary>`, '']
  lines.push(tableHeader())
  for (const row of rows) lines.push(tableRow(row))
  lines.push('', '</details>')
  return lines.join('\n')
}

function renderAdjudicationRecord(record) {
  const allRows = buildFindingIndex(record)
  const lines = ['## Adjudication record', '']
  const docs = [...record.adjudications].sort((a, b) => {
    const sa = STAGE_ORDER[a.doc.stage] ?? 99
    const sb = STAGE_ORDER[b.doc.stage] ?? 99
    return sa !== sb ? sa - sb : a.doc.round - b.doc.round
  })
  if (docs.length === 0) {
    lines.push('None.')
    return lines.join('\n')
  }
  const blocks = docs.map(({ doc }) => {
    const rows = allRows.filter((r) => r.stage === doc.stage && r.round === doc.round).sort(compareRows)
    return renderOneRoundTable(doc, rows)
  })
  lines.push(blocks.join('\n\n'))
  return lines.join('\n')
}

function verdictLine(verdict) {
  if (!verdict) return null
  const reason = verdict.reason ? neutralizeMarkers(verdict.reason) : null
  const head = reason ? `${verdict.outcome} — ${reason}` : verdict.outcome
  const details = []
  if (Number.isInteger(verdict.rounds_counted)) details.push(`rounds counted: ${verdict.rounds_counted}`)
  if (Number.isInteger(verdict.next_round)) details.push(`next round: ${verdict.next_round}`)
  if (Array.isArray(verdict.corrections) && verdict.corrections.length > 0) {
    details.push(`corrections: ${verdict.corrections.map(neutralizeMarkers).join('; ')}`)
  }
  return details.length > 0 ? `**Exit:** ${head} (${details.join('; ')})` : `**Exit:** ${head}`
}

function renderRoundTable(record, options) {
  const allRows = buildFindingIndex(record)
  // --stage/--round must be given together or not at all: a PARTIAL
  // selector (e.g. --stage only) previously fell through to "the sole
  // document" whenever exactly one was supplied, silently ignoring a
  // selector that might not even match it — a mistyped command would then
  // publish the wrong round with no error at all.
  if ((options.stage === undefined) !== (options.round === undefined)) {
    fail('round-table requires --stage and --round together, never only one')
  }
  let target
  if (options.stage !== undefined && Number.isInteger(options.round)) {
    target = record.adjudications.find((a) => a.doc.stage === options.stage && a.doc.round === options.round)
    if (!target) fail(`no adjudication document for stage ${options.stage} round ${options.round}`)
  } else if (record.adjudications.length === 1) {
    target = record.adjudications[0]
  } else {
    fail('round-table requires --stage and --round when more than one adjudication document is supplied')
  }
  const rows = allRows.filter((r) => r.stage === target.doc.stage && r.round === target.doc.round).sort(compareRows)
  const lines = ['### Round', '', renderOneRoundTable(target.doc, rows)]
  const line = verdictLine(record.verdict)
  if (line) lines.push('', line)
  return lines.join('\n')
}

function policyLine(policy) {
  const { rigor, rounds } = policy
  const capParts = []
  if (rounds) {
    if ('challenge' in rounds) capParts.push(`challenge ≤${rounds.challenge}`)
    if ('review' in rounds) capParts.push(`review ≤${rounds.review}`)
    if ('integration' in rounds) capParts.push(`integration ${rounds.integration}`)
    if ('remediation' in rounds) capParts.push(`remediation ${rounds.remediation}`)
    if ('min_rounds' in rounds) capParts.push(`min_rounds ${rounds.min_rounds}`)
  }
  const capText = capParts.length > 0 ? ` → ${capParts.join(', ')}` : ''
  // Backticks make GFM render this literally, but mergeSections' marker
  // scan is a raw byte match with no Markdown awareness — a code span does
  // not stop it from reading a forged marker inside rigor.level/source.
  return `rigor: \`${neutralizeMarkers(rigor.level)}\` (\`${neutralizeMarkers(rigor.source)}\`)${capText}`
}

function renderPolicyDisclosure(record) {
  if (!record.policy) fail('policy-disclosure requires policy.json in the record directory')
  const lines = [policyLine(record.policy)]
  const disclosures = record.policy.disclosures || []
  if (disclosures.length > 0) {
    lines.push('')
    for (const d of disclosures) lines.push(`- ${neutralizeMarkers(d.kind)}: ${neutralizeMarkers(d.detail)}`)
  }
  return lines.join('\n')
}

function renderBlockerComment(record, options = {}) {
  if (!record.run) fail('blocker-comment requires run.json in the record directory')
  // --head must be the caller's actual current HEAD, never inferred from
  // adjudication order: after the final permitted cycle finds an issue, the
  // resulting fix moves the head PAST the last round any adjudication
  // document ever reviewed, so "most recent reviewed_head" would silently
  // name a stale, already-superseded commit instead of the new unreviewed
  // one the blocker must name (renderer/spec.md "Blocker reports bind to
  // unresolved state": "A head change SHALL invalidate a blocker ...
  // projection that claims a prior head").
  if (!options.head) fail('blocker-comment requires --head <sha> (the caller\'s current HEAD, never inferred)')
  const lastTransition = record.run.stage_transitions[record.run.stage_transitions.length - 1]
  const verdict = record.verdict || {}
  const outcome = verdict.outcome || record.run.outcome || 'unknown'
  const reason = verdict.reason || lastTransition.exit || 'unresolved'
  const rows = buildFindingIndex(record)
  const settlements = buildSettlementIndex(record.run)
  const unresolved = rows.filter((row) => {
    if (row.entry.disposition !== 'defer') return false
    return !settlements.has(row.entry.finding_id)
  })
  const lines = [`## Blocker: ${lastTransition.stage} ${outcome} (${reason})`, '']
  lines.push(`- Head: \`${options.head}\``)
  lines.push(`- Stage: ${lastTransition.stage}`)
  lines.push(`- Outcome: \`${outcome}\` (\`${reason}\`)`)
  // "Spent" names the BLOCKED stage's own round count against its cap — the
  // verdict's rounds_counted is the exit script's authoritative count for
  // that one stage; record.policy.rounds only supplies the matching cap.
  if (Number.isInteger(verdict.rounds_counted) && record.policy?.rounds?.[lastTransition.stage] !== undefined) {
    lines.push(`- Spent: ${lastTransition.stage} ${verdict.rounds_counted}/${record.policy.rounds[lastTransition.stage]}`)
  }
  lines.push('- Unresolved:')
  if (unresolved.length === 0) {
    lines.push('  - None.')
  } else {
    for (const row of unresolved.sort(compareRows)) {
      lines.push(
        `  - ${row.entry.finding_id} — ${location(row)} — ${neutralizeMarkers(summary(row))} (${row.entry.adjudicated_priority}, ${row.entry.disposition})`
      )
    }
  }
  const nextAction = Number.isInteger(verdict.next_round) ? `dispatch round ${verdict.next_round}` : 'escalate to a human'
  lines.push(`- Next action: ${nextAction}`)
  return lines.join('\n')
}

// Only a finding whose source_id is named in ITS OWN pass's
// unanswered_thread_roots is an open inline thread still owed a reply: the
// integrator schema's source_id is the GitHub-native id of "an inline review
// comment id, a review id, [or] a locally-minted CI-failure marker"
// (ai/schemas/README.md) — most of those are not a thread at all, and even
// a genuine thread may already carry its reply. Emitting a plan entry for
// any of those would attempt an invalid API reply or duplicate an existing
// one.
//
// passes/ is optional for every OTHER projection — a finding with no
// matching pass still renders, just with reduced fidelity. That degradation
// is wrong here specifically: without the pass, this renderer cannot tell
// "already answered" from "not a thread at all" from "genuinely still
// open," so an integration-stage finding with no matching pass is an
// indeterminate error, never a silent omission — an empty entries[] must
// mean "confirmed nothing to reply to," not "we couldn't tell."
function renderThreadReplyPlan(record) {
  const integrationRows = buildFindingIndex(record).filter((row) => row.stage === 'integration')
  for (const row of integrationRows) {
    if (!row.pass) {
      fail(
        `${row.entry.finding_id}: no matching integrator pass supplied — cannot determine whether its thread is still unanswered`
      )
    }
  }
  const rows = integrationRows.filter((row) => row.pass.unansweredThreadRoots.has(row.pass.finding.source_id))
  const entries = rows
    .sort(compareRows)
    .map((row) => {
      const { entry } = row
      const verb = REPLY_VERB[entry.disposition]
      if (!verb) fail(`${entry.finding_id}: unknown disposition ${entry.disposition} for a reply plan`)
      return {
        finding_id: entry.finding_id,
        root_comment_id: row.pass.finding.source_id,
        reply_text: `${verb}: ${entry.reason}`,
        // Carried alongside root_comment_id/reply_text so a consumer can
        // verify this entry's semantic equivalence with the ledger and
        // PR-body projections, and so a head change invalidates a stale
        // plan instead of it being replayed against different code
        // (renderer/spec.md "Multi-surface dispositions remain equivalent").
        head: row.reviewed_head,
        adjudicated_priority: entry.adjudicated_priority,
        classification: classification(row),
        evidence: summary(row),
        action: `${entry.disposition} — ${entry.reason}`
      }
    })
  return JSON.stringify({ schema: 'dev-flow-render.thread-reply-plan.v1', entries }, null, 2)
}

function renderReadinessInput(record, options = {}) {
  if (!record.run) fail('readiness-input requires run.json in the record directory')
  // Same reasoning as renderBlockerComment: the readiness gate evaluates
  // against the CURRENT head, which a fix push can move past every
  // adjudication document this record set has ever seen.
  if (!options.head) fail('readiness-input requires --head <sha> (the caller\'s current HEAD, never inferred)')
  const settlements = buildSettlementIndex(record.run)
  const rows = buildFindingIndex(record).filter((row) => row.entry.disposition === 'defer')
  const settled = []
  const unsettled = []
  for (const row of rows.sort(compareRows)) {
    const settlement = settlements.get(row.entry.finding_id)
    if (settlement) {
      settled.push({
        finding_id: row.entry.finding_id,
        disposition: settlement.disposition,
        reference: settlement.reference,
        settled_at: settlement.settled_at
      })
    } else {
      unsettled.push({
        finding_id: row.entry.finding_id,
        adjudicated_priority: row.entry.adjudicated_priority,
        stage: row.stage,
        round: row.round
      })
    }
  }
  return JSON.stringify(
    {
      schema: 'dev-flow-render.readiness-input.v1',
      run_id: record.run.run_id,
      head: options.head,
      deferred_findings: { settled, unsettled }
    },
    null,
    2
  )
}

function render(command, record, options) {
  switch (command) {
    case 'deferred-findings':
      return renderDeferredFindings(record)
    case 'adjudication-record':
      return renderAdjudicationRecord(record)
    case 'round-table':
      return renderRoundTable(record, options)
    case 'policy-disclosure':
      return renderPolicyDisclosure(record)
    case 'blocker-comment':
      return renderBlockerComment(record, options)
    case 'thread-reply-plan':
      return renderThreadReplyPlan(record)
    case 'readiness-input':
      return renderReadinessInput(record, options)
    default:
      throw new Error(`unhandled projection: ${command}`)
  }
}

const SECTION_RENDERERS = {
  'policy-disclosure': renderPolicyDisclosure,
  'deferred-findings': renderDeferredFindings,
  'adjudication-record': renderAdjudicationRecord
}

// ── publish ─────────────────────────────────────────────────────────────

function sha256(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex')
}

function gh(args, input) {
  try {
    return execFileSync('gh', args, { input, encoding: 'utf8' })
  } catch (error) {
    const stderr = error.stderr ? error.stderr.toString() : error.message
    throw new Error(`gh ${args.join(' ')} failed: ${stderr}`)
  }
}

function reservationPath(recordDir) {
  return path.join(recordDir, '.publish-state.json')
}

function writeReservation(recordDir, state) {
  fs.writeFileSync(reservationPath(recordDir), JSON.stringify(state, null, 2))
}

function clearReservation(recordDir) {
  fs.rmSync(reservationPath(recordDir), { force: true })
}

function blockerResult(reason, detail, extra = {}) {
  return { status: 'blocker', reason, detail, ...extra }
}

function lockPath(recordDir) {
  return path.join(recordDir, '.publish-lock')
}

// publish: see the module doc comment's "Publish algorithm". Acquires an
// exclusive, record-directory-scoped lock first: `gh pr edit` has no
// compare-and-swap, so two publish() calls racing the same PR can each read
// the same original body, write independently, and each verify their OWN
// write before the other's lands — both report success while the
// last-writer body silently drops the first. A same-record-directory lock
// closes the most likely real trigger (an accidental double-invocation, a
// caller retrying while a prior attempt is still in flight); it does not —
// and cannot, from one process alone — close two publish calls against
// DIFFERENT record directories racing the SAME PR, which stays the same
// disclosed GitHub read-modify-write limitation as a concurrent human edit.
// A lock left behind by a crashed process is a stale-lock recovery: remove
// it and retry, the same operational shape as any other file-based recovery
// state in this family.
function publish(record, options) {
  const lock = lockPath(options.record)
  try {
    fs.writeFileSync(lock, String(process.pid), { flag: 'wx' })
  } catch (error) {
    if (error.code === 'EEXIST') {
      return blockerResult(
        'concurrent-publish',
        `another publish is already in flight for this record directory (${lock}); if left behind by a crashed process, remove it and retry`
      )
    }
    throw error
  }
  // A section renderer can call fail() on malformed record data (e.g. a
  // deferred finding with no matching pass) while this lock is held, and
  // fail() terminates via process.exit(), which skips the finally below
  // entirely — Node runs no pending finally block on that path. The 'exit'
  // event is the one hook Node guarantees fires (synchronously) on every
  // exit, explicit or not, so the lock is released there too; fs.rmSync's
  // force:true makes running it twice (finally, then here) harmless.
  process.on('exit', () => fs.rmSync(lock, { force: true }))
  try {
    return publishLocked(record, options)
  } finally {
    fs.rmSync(lock, { force: true })
  }
}

function publishLocked(record, options) {
  // A schema-valid but wrong PR: the caller's --pr/--repo happen to name a
  // draft at the expected head, but run.json's own pr identifies a
  // DIFFERENT PR entirely (a stale terminal, a copy-pasted number, a
  // stacked/cross-repo mistake). headRefOid/isDraft alone cannot catch
  // this — only the run record knows which PR this run's adjudications
  // actually belong to.
  if (record.run && record.run.pr) {
    if (record.run.pr.number !== options.pr) {
      return blockerResult(
        'pr-mismatch',
        `run.json names PR #${record.run.pr.number}, but publish was invoked for PR #${options.pr}`
      )
    }
    const urlMatch = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)$/.exec(record.run.pr.url)
    // An unparseable or unexpected-host URL must BLOCK, not silently skip
    // the check it was meant to feed: the same repo/number can otherwise
    // collide across a fork, and a malformed URL disabling the very safety
    // check that exists to catch this is worse than not having the check.
    if (!urlMatch) {
      return blockerResult('pr-mismatch', `run.json's PR URL is not a recognized github.com pull URL: ${record.run.pr.url}`)
    }
    if (urlMatch[1] !== options.repo) {
      return blockerResult(
        'pr-mismatch',
        `run.json's PR URL names repo ${urlMatch[1]}, but publish was invoked for --repo ${options.repo}`
      )
    }
    // The URL's own trailing number is a second, independent encoding of the
    // same PR — checking only options.pr against record.run.pr.number (above)
    // would silently accept a run.json where those two fields already
    // disagree with each other (a copy-pasted number, a stale terminal).
    if (Number(urlMatch[2]) !== record.run.pr.number) {
      return blockerResult(
        'pr-mismatch',
        `run.json's PR URL names #${urlMatch[2]}, but run.json.pr.number is ${record.run.pr.number}`
      )
    }
  }

  const sections = {}
  for (const section of options.sections) {
    sections[section] = SECTION_RENDERERS[section](record)
  }

  const maxAttempts = options.maxRetries + 1
  // wroteAny answers "did this call change the PR body at all" — distinct
  // from a single attempt's own no-op/wrote classification. A write in
  // attempt 1 followed by a attempt-2 fresh read that finds nothing further
  // to change (its own content already landed, a concurrent addition
  // preserved alongside it) still changed the PR body overall; only a call
  // whose every attempt was a no-op never did.
  let wroteAny = false
  try {
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      const view = JSON.parse(gh(['pr', 'view', String(options.pr), '--repo', options.repo, '--json', 'number,url,headRefOid,isDraft,body']))
      if (view.headRefOid !== options.head) {
        return blockerResult('head-mismatch', `PR head is ${view.headRefOid}, expected ${options.head}`, { pr: options.pr })
      }
      if (!view.isDraft) {
        return blockerResult('not-draft', `PR #${options.pr} is not a draft`, { pr: options.pr })
      }

      let intendedBody
      try {
        intendedBody = mergeSections(view.body, sections)
      } catch (error) {
        return blockerResult('malformed-markers', error.message, { pr: options.pr })
      }
      const intendedFingerprint = sha256(intendedBody)

      if (intendedBody === view.body) {
        clearReservation(options.record)
        return { status: 'published', pr: options.pr, head: options.head, sections: options.sections, fingerprint: intendedFingerprint, attempts: attempt, changed: wroteAny }
      }

      writeReservation(options.record, {
        head: options.head,
        pr: options.pr,
        repo: options.repo,
        sections: options.sections,
        intended_fingerprint: intendedFingerprint,
        attempt
      })

      gh(['pr', 'edit', String(options.pr), '--repo', options.repo, '--body-file', '-'], intendedBody)
      wroteAny = true

      const reread = JSON.parse(
        gh(['pr', 'view', String(options.pr), '--repo', options.repo, '--json', 'headRefOid,isDraft,body'])
      )
      if (reread.headRefOid !== options.head) {
        return blockerResult('head-changed-during-publish', `PR head moved to ${reread.headRefOid} mid-write`, { pr: options.pr })
      }
      if (!reread.isDraft) {
        // A known external actor (AGENTS.md's Codex-connector signature) can
        // promote a draft outside this transaction; the write already
        // landed, but reporting success would tell the caller a routine
        // publish where actually the PR just left draft mid-write.
        return blockerResult('promoted-during-publish', `PR #${options.pr} left draft state during the write`, {
          pr: options.pr
        })
      }
      const actualFingerprint = sha256(reread.body)
      if (actualFingerprint === intendedFingerprint) {
        clearReservation(options.record)
        return { status: 'published', pr: options.pr, head: options.head, sections: options.sections, fingerprint: actualFingerprint, attempts: attempt, changed: true }
      }
      // Mismatch: a concurrent edit landed in the write window. Loop for a
      // fresh read and repair, bounded by maxAttempts.
    }
  } catch (error) {
    // A failed gh call (network, auth, rate limit) is indeterminate, not a
    // defaultable success or a silent crash: retain the reservation (if one
    // was written) so a retry can resume, and report why.
    return blockerResult('gh-failed', error.message, { pr: options.pr })
  }

  return blockerResult('retry-exhausted', `no matching write after ${maxAttempts} attempts`, {
    pr: options.pr,
    attempts: maxAttempts
  })
}

// ── main ────────────────────────────────────────────────────────────────

function main(argv) {
  const options = parseArgs(argv)
  const schemasDir = options.schemasDir || process.env.RESULT_SCHEMAS_DIR || DEFAULT_SCHEMAS_DIR
  const record = loadRecord(options.record, schemasDir)
  validateCrossDocumentConsistency(record)
  if (options.verdictFile) {
    record.verdict = loadJson(options.verdictFile)
    validateVerdictShape(record.verdict, options.verdictFile)
  }
  if (options.policyFile) {
    record.policy = loadJson(options.policyFile)
    validatePolicyShape(record.policy, options.policyFile)
  }

  if (options.command === 'publish') {
    const result = publish(record, options)
    const output = JSON.stringify(result, null, 2)
    if (options.out) fs.writeFileSync(options.out, `${output}\n`)
    else console.log(output)
    process.exit(result.status === 'published' ? 0 : 1)
  }

  const output = render(options.command, record, options)
  if (options.out) fs.writeFileSync(options.out, `${output}\n`)
  else console.log(output)
}

main(process.argv.slice(2))
