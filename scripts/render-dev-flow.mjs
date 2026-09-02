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
//                         finding, unchecked until a run.json settlement
//                         terminalizes it (fix/decline/file grammar below).
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
//                         action, from run.json + --verdict.
//   thread-reply-plan     JSON: {finding_id, root_comment_id, reply_text}
//                         per integration-stage finding (the only stage
//                         whose findings carry a GitHub-native source_id —
//                         see ai/schemas/README.md).
//   readiness-input       JSON: settled/unsettled deferred findings by id,
//                         for the readiness gate to consume instead of
//                         parsing Markdown.
//
// A record directory (--record <dir>) holds:
//   run.json              One run.schema.json document. Required except when
//                         rendering adjudication-record/round-table without
//                         any settlement/blocker context.
//   adjudications/*.json  One or more adjudication.schema.json documents
//                         (one per round). Every *.json file in the
//                         directory is read; order is irrelevant, output
//                         order is always recomputed from content.
//   passes/*.json         Result envelopes (role reviewer/integrator) that
//                         the adjudications reference, enriching a finding
//                         with path/line/class/provenance/fingerprint/finder
//                         (challenge/review) or body/source_id (integration).
//                         Optional: a finding_id with no matching pass still
//                         renders, using only what the adjudication entry
//                         itself carries.
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
// publish additionally requires --repo, --pr, --head, and --sections (a
// comma list drawn from policy-disclosure, deferred-findings,
// adjudication-record — the three sections that live in the PR body; the
// caller states explicitly which ones this call updates, so a section is
// never silently republished or silently skipped). See "Publish algorithm"
// below.
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
const SETTLEMENT_GRAMMAR = { fix: 'fixed in', decline: 'declined:', file: 'filed as' }

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
      case '--round':
        options.round = Number.parseInt(need(arg), 10)
        break
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
// record directory. Structural validation only (this schema family's own
// receipt/cross-document checks — run chronology, adjudication-vs-pass
// agreement — are validate-result-schemas.mjs's job upstream of this
// renderer; re-running them here would duplicate ~1800 lines for no
// projection this script produces). A malformed document fails loudly
// naming the file, rather than silently rendering from a partial parse.
function loadRecord(dir, schemasDir) {
  const record = { run: null, adjudications: [], passes: [], verdict: null, policy: null }

  const runFile = path.join(dir, 'run.json')
  if (fs.existsSync(runFile)) {
    record.run = loadJson(runFile)
    validateAgainst(schemasDir, 'run.schema.json', record.run, runFile)
  }

  for (const file of listJsonFiles(path.join(dir, 'adjudications'))) {
    const doc = loadJson(file)
    validateAgainst(schemasDir, 'adjudication.schema.json', doc, file)
    record.adjudications.push({ file, doc })
  }

  for (const file of listJsonFiles(path.join(dir, 'passes'))) {
    const envelope = loadJson(file)
    validateAgainst(schemasDir, 'result.envelope.schema.json', envelope, file)
    if (envelope.role !== 'reviewer' && envelope.role !== 'integrator') {
      fail(`${file}: passes/ may only hold reviewer or integrator envelopes, got role ${envelope.role}`)
    }
    validateAgainst(schemasDir, `result.${envelope.role}.schema.json`, envelope.payload, `${file}#/payload`)
    record.passes.push({ file, envelope })
  }

  const verdictFile = path.join(dir, 'verdict.json')
  if (fs.existsSync(verdictFile)) record.verdict = loadJson(verdictFile)

  const policyFile = path.join(dir, 'policy.json')
  if (fs.existsSync(policyFile)) record.policy = loadJson(policyFile)

  return record
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
    for (const finding of findings) {
      if (passFindingsById.has(finding.id)) {
        fail(`${file}: finding id ${finding.id} also appears in an earlier pass file`)
      }
      passFindingsById.set(finding.id, { finding, role: envelope.role })
    }
  }

  const entries = []
  for (const { file, doc } of record.adjudications) {
    for (const entry of doc.adjudications) {
      const idMatch = FINDING_ID.exec(entry.finding_id)
      if (!idMatch) fail(`${file}: malformed finding id ${entry.finding_id}`)
      entries.push({
        entry,
        stage: doc.stage,
        round: doc.round,
        reviewed_head: doc.reviewed_head,
        finder: idMatch[3],
        n: Number.parseInt(idMatch[4], 10),
        pass: passFindingsById.get(entry.finding_id) || null
      })
    }
  }
  return entries
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

function classification(disposition) {
  return disposition === 'decline' ? 'false positive' : 'confirmed'
}

function shortSha(sha) {
  return typeof sha === 'string' ? sha.slice(0, 7) : sha
}

function location(row) {
  if (row.pass && row.pass.finding.path) {
    const { path: p, line } = row.pass.finding
    return line === null || line === undefined ? p : `${p}:${line}`
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
  return row.pass && row.pass.role === 'reviewer' ? row.pass.finding.provenance : 'n/a'
}

function escapeCell(text) {
  return String(text).replaceAll('|', '\\|').replaceAll('\r\n', ' ').replaceAll('\n', '<br>')
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
function settlementSuffix(settlement) {
  const { type, value } = settlement.reference
  if (type === 'sha') return `${SETTLEMENT_GRAMMAR.fix} ${shortSha(value)}`
  if (type === 'issue_number') return `${SETTLEMENT_GRAMMAR.file} #${value}`
  if (type === 'comment_id') return `${SETTLEMENT_GRAMMAR.decline} see comment ${value}`
  fail(`run.json: settlement for ${settlement.finding_id} has unknown reference type ${type}`)
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
    result = `${result.replace(/\n+$/, '')}\n\n${appended}\n`
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
    entry.disposition
  )} | ${escapeCell(summary(row))} | ${action} | ${provenance(row)} |`
}

function renderDeferredFindings(record) {
  const rows = buildFindingIndex(record)
    .filter((row) => row.entry.disposition === 'defer')
    .sort(compareRows)
  const settlements = buildSettlementIndex(record.run)
  const lines = ['## Deferred findings', '']
  if (rows.length === 0) {
    lines.push('None.')
  } else {
    for (const row of rows) {
      const settlement = settlements.get(row.entry.finding_id)
      const loc = location(row)
      const text = summary(row)
      if (settlement) {
        lines.push(`- [x] ${loc} — ${text} — ${settlementSuffix(settlement)}`)
      } else {
        lines.push(`- [ ] ${loc} — ${text}`)
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
  const head = verdict.reason ? `${verdict.outcome} — ${verdict.reason}` : verdict.outcome
  const details = []
  if (Number.isInteger(verdict.rounds_counted)) details.push(`rounds counted: ${verdict.rounds_counted}`)
  if (Number.isInteger(verdict.next_round)) details.push(`next round: ${verdict.next_round}`)
  if (Array.isArray(verdict.corrections) && verdict.corrections.length > 0) {
    details.push(`corrections: ${verdict.corrections.join('; ')}`)
  }
  return details.length > 0 ? `**Exit:** ${head} (${details.join('; ')})` : `**Exit:** ${head}`
}

function renderRoundTable(record, options) {
  const allRows = buildFindingIndex(record)
  let target
  if (options.stage && Number.isInteger(options.round)) {
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
  return `rigor: \`${rigor.level}\` (\`${rigor.source}\`)${capText}`
}

function renderPolicyDisclosure(record) {
  if (!record.policy) fail('policy-disclosure requires policy.json in the record directory')
  const lines = [policyLine(record.policy)]
  const disclosures = record.policy.disclosures || []
  if (disclosures.length > 0) {
    lines.push('')
    for (const d of disclosures) lines.push(`- ${d.kind}: ${d.detail}`)
  }
  return lines.join('\n')
}

// The most recent adjudication document by (stage order, round) — the same
// ordering renderAdjudicationRecord groups by — stands in for "the run's
// current head" when the caller does not pass --head explicitly: it is the
// reviewed_head of whichever round most recently ran.
function latestReviewedHead(record) {
  if (record.adjudications.length === 0) return null
  const sorted = [...record.adjudications].sort((a, b) => {
    const sa = STAGE_ORDER[a.doc.stage] ?? 99
    const sb = STAGE_ORDER[b.doc.stage] ?? 99
    return sa !== sb ? sa - sb : a.doc.round - b.doc.round
  })
  return sorted[sorted.length - 1].doc.reviewed_head
}

function renderBlockerComment(record, options = {}) {
  if (!record.run) fail('blocker-comment requires run.json in the record directory')
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
  const head = options.head || latestReviewedHead(record) || 'unknown'
  lines.push(`- Head: \`${head}\``)
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
        `  - ${row.entry.finding_id} — ${location(row)} — ${summary(row)} (${row.entry.adjudicated_priority}, ${row.entry.disposition})`
      )
    }
  }
  const nextAction = Number.isInteger(verdict.next_round) ? `dispatch round ${verdict.next_round}` : 'escalate to a human'
  lines.push(`- Next action: ${nextAction}`)
  return lines.join('\n')
}

function renderThreadReplyPlan(record) {
  const rows = buildFindingIndex(record).filter((row) => row.stage === 'integration' && row.pass)
  const entries = rows
    .sort(compareRows)
    .map((row) => {
      const { entry } = row
      let replyText
      if (entry.disposition === 'decline') replyText = `Declined: ${entry.reason}`
      else if (entry.disposition === 'file') replyText = `Filed: ${entry.reason}`
      else replyText = `Fixed: ${entry.reason}`
      return { finding_id: entry.finding_id, root_comment_id: row.pass.finding.source_id, reply_text: replyText }
    })
  return JSON.stringify({ schema: 'dev-flow-render.thread-reply-plan.v1', entries }, null, 2)
}

function renderReadinessInput(record, options = {}) {
  if (!record.run) fail('readiness-input requires run.json in the record directory')
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
      head: options.head || latestReviewedHead(record) || null,
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

// publish: see the module doc comment's "Publish algorithm". Every attempt
// re-reads the PR fresh; nothing here trusts a cached body across attempts,
// so a concurrent human edit is repaired from a fresh read rather than
// clobbered, and a crash between a landed write and this process recording
// success is safe to resume — the fresh read on the next invocation already
// matches the intended content and short-circuits to success without a
// second write (renderer/spec.md "Remote handoff is idempotent").
function publish(record, options) {
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

      const reread = JSON.parse(gh(['pr', 'view', String(options.pr), '--repo', options.repo, '--json', 'headRefOid,body']))
      if (reread.headRefOid !== options.head) {
        return blockerResult('head-changed-during-publish', `PR head moved to ${reread.headRefOid} mid-write`, { pr: options.pr })
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
  if (options.verdictFile) record.verdict = loadJson(options.verdictFile)
  if (options.policyFile) record.policy = loadJson(options.policyFile)

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
