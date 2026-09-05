#!/usr/bin/env node
// normalize-finder-findings.mjs — decode ONE finder's raw output into the
// shared pass core every stage consumer already understands.
//
// The point of this script is what it makes unnecessary. Adjudication,
// scripts/dev-flow-exit.mjs and scripts/render-dev-flow.mjs read
// `findings[]` — id, path, line, class, provenance, fingerprint, priority,
// recommended_disposition, evidence — and must never learn which product
// produced one. So every finder-shaped decision lives here and in that
// finder's own agent-registry.json entry (`raw_shape`, `severity_map`), and a
// new finder is a registry entry plus fixtures rather than a branch in three
// shared consumers.
//
// Usage:
//   normalize-finder-findings.mjs --finder <slug> --stage <challenge|review>
//       --round <n> --reviewed-head <sha40> [--slot <slug>]
//       [--registry <path>] [--input <file>] [--allow-undecoded]
//
// Raw output arrives on stdin unless --input names a file. The result is the
// pass core on stdout:
//
//   { stage, round, reviewed_head, finder, slot, substitutes_for?,
//     findings: [...], counts: {P0,P1,P2,P3} }
//
// For a review-stage finder that IS a complete, schema-valid
// result.reviewer payload. For a challenge-stage one it is that payload minus
// `attack_scenarios`, which is the challenger ROLE's own evidence (what it
// attempted, finding or not) and cannot be decoded from a finder's output —
// the role appends it before returning its envelope.
//
// Three fields are decoded conservatively ON PURPOSE, because the raw output
// does not carry them and inventing them would put an unverified assertion
// into evidence:
//
//   provenance   always `original`. The exit script verifies provenance
//                against the trusted history and downgrades to `round:N` with
//                recorded evidence; asserting a round here would be a claim
//                the decoder cannot support.
//   fingerprint  always `new`. `repeat-of` / `supersedes` needs the earlier
//                rounds' validated findings, which the dispatched role has in
//                its brief and this decoder does not.
//   class        derived from the decoded priority (P0/P1 correctness,
//                P2 hardening, P3 nit) unless the raw text states one
//                explicitly as `class: <value>`. A design-level finding is
//                one the role reclassifies with the evidence to do so.
//
// Exit: 0 decoded; 3 something could not be decoded (see --allow-undecoded);
// 2 usage or unreadable input.

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

function die(message, code = 2) {
  console.error(`normalize-finder-findings: ${message}`)
  process.exit(code)
}

const args = process.argv.slice(2)
const opts = { registry: path.join(REPO_ROOT, 'agent-registry.json'), allowUndecoded: false }
for (let i = 0; i < args.length; i += 1) {
  const flag = args[i]
  const takesValue = [
    '--finder',
    '--stage',
    '--round',
    '--reviewed-head',
    '--slot',
    '--substitutes-for',
    '--registry',
    '--input'
  ]
  if (flag === '--allow-undecoded') {
    opts.allowUndecoded = true
    continue
  }
  if (!takesValue.includes(flag)) die(`unknown argument ${flag}`)
  const value = args[i + 1]
  if (value === undefined) die(`${flag} requires a value`)
  opts[flag.replace(/^--/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value
  i += 1
}

for (const required of ['finder', 'stage', 'round', 'reviewedHead']) {
  if (!opts[required]) die(`--${required.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)} is required`)
}
if (!['challenge', 'review', 'integration'].includes(opts.stage)) {
  die('--stage must be challenge, review or integration')
}
if (!/^[1-9][0-9]*$/.test(opts.round)) die('--round must be a positive integer')
if (!/^[0-9a-f]{40}$/.test(opts.reviewedHead)) die('--reviewed-head must be a 40-character lowercase sha')

let registry
try {
  registry = JSON.parse(fs.readFileSync(opts.registry, 'utf8'))
} catch (error) {
  die(`cannot read the registry at ${opts.registry}: ${error.message}`)
}
const finder = (registry.finders ?? []).find((entry) => entry.slug === opts.finder)
if (!finder) die(`'${opts.finder}' is not a registered finder in ${opts.registry}`)
if (Array.isArray(finder.stages) && !finder.stages.includes(opts.stage)) {
  die(`finder '${opts.finder}' is registered for stage(s) ${finder.stages.join(', ')}, not ${opts.stage}`)
}

let raw
try {
  raw = opts.input ? fs.readFileSync(opts.input, 'utf8') : fs.readFileSync(0, 'utf8')
} catch (error) {
  die(`cannot read the finder's raw output: ${error.message}`)
}

// ── severity ────────────────────────────────────────────────────────────────
// Ordered, first-match-wins, case-insensitive — the registry's own contract,
// and the registry validator already refuses a repeated (match, anchor) pair,
// so no rule here is unreachable. WHERE a rule may match is the rule's own
// `anchor`, and it is load-bearing rather than cosmetic: the local-CLI prompt
// asks for the badge "as the first token of the finding" and, in the same
// breath, for narration that says "there are no P0 or P1 findings" — under a
// bare substring test that sentence reads as a P0.
function matchesRule(text, rule) {
  const needle = String(rule.match).toLowerCase()
  if (rule.anchor === 'anywhere') return text.toLowerCase().includes(needle)
  // leading-token: the block's first whitespace-delimited token, stripped of
  // the punctuation a badge is commonly wrapped in (**P1**, `P1`, "P1:").
  const token = text.trim().split(/\s+/, 1)[0] ?? ''
  return token.toLowerCase().replace(/^[^a-z0-9]+|[^a-z0-9]+$/g, '') === needle
}

// Did any rule fire at all? Distinct from priorityOf, which cannot say whether
// it returned a matched priority or the default.
function isLabelled(text) {
  return finder.severity_map.rules.some((rule) => matchesRule(text, rule))
}

// A finding matching no rule takes `default`, which the schema forbids from
// being P3: AGENTS.md adjudicates an unlabelled finding as AT LEAST a P2.
function priorityOf(text) {
  for (const rule of finder.severity_map.rules) {
    if (matchesRule(text, rule)) return rule.priority
  }
  return finder.severity_map.default
}

const CLASS_BY_PRIORITY = { P0: 'correctness', P1: 'correctness', P2: 'hardening', P3: 'nit' }
const CLASSES = new Set(['design', 'correctness', 'consistency', 'hardening', 'nit'])
function classOf(text, priority) {
  const stated = /(?:^|\n)\s*class:\s*([a-z]+)\s*(?:$|\n)/i.exec(text)
  if (stated && CLASSES.has(stated[1].toLowerCase())) return stated[1].toLowerCase()
  return CLASS_BY_PRIORITY[priority]
}

// A P2 or P3 is carried to the integration stage rather than fixed in the
// local loop (AGENTS.md "Deferring P2s"), which is exactly `defer`. This is a
// RECOMMENDATION; the adjudication record holds the actual disposition.
function dispositionOf(priority) {
  return priority === 'P0' || priority === 'P1' ? 'fix' : 'defer'
}

// The path must survive result.<role>.schema.json's own `path` pattern:
// repo-relative, no leading slash, no drive letter, no backslash, no `.`/`..`
// segment. Matching that here rather than emitting something the schema will
// reject means an undecodable path is REPORTED, not discovered three steps
// later as a validation failure with no way back to the raw text.
const PATH_TOKEN = /(?:^|[\s(`'"[])((?:[A-Za-z0-9_.-]+\/)*[A-Za-z0-9_.-]+\.[A-Za-z0-9_]+)(?::(\d+))?/
function locationOf(text) {
  const match = PATH_TOKEN.exec(text)
  if (!match) return null
  const candidate = match[1]
  if (candidate.split('/').some((segment) => segment === '.' || segment === '..')) return null
  return { path: candidate, line: match[2] ? Number(match[2]) : null }
}

const EVIDENCE_MAX = 4000
function evidenceOf(text) {
  // Trailing spaces and tabs per line only. A blank LINE is content: an
  // integration finding is carried verbatim into adjudication, and collapsing
  // the paragraph breaks out of a review body rewrites the text a human is
  // being asked to adjudicate.
  const trimmed = text.trim().replace(/[ \t]+$/gm, '')
  return trimmed.length > EVIDENCE_MAX
    ? `${trimmed.slice(0, EVIDENCE_MAX)}\n... [evidence truncated at ${EVIDENCE_MAX} characters]`
    : trimmed
}

const findings = []
const undecoded = []

function pushFinding(text, sourceLabel, location, sourceId) {
  const priority = priorityOf(text)
  const resolved = location ?? locationOf(text)
  // An integration finding is carried VERBATIM (result.integrator's own
  // contract) and needs no decoded path, so a body with no file reference is
  // a complete finding there and undecodable only on a confidence stage.
  if (!resolved && opts.stage !== 'integration') {
    undecoded.push({ source: sourceLabel, reason: 'no repo-relative path could be decoded', priority, text: evidenceOf(text) })
    return
  }
  findings.push({
    source_id: sourceId ?? sourceLabel,
    id: `${opts.stage}-r${opts.round}-${opts.finder}-${findings.length + 1}`,
    path: resolved?.path ?? null,
    line: resolved?.line ?? null,
    class: classOf(text, priority),
    provenance: 'original',
    fingerprint: 'new',
    priority,
    recommended_disposition: dispositionOf(priority),
    evidence: evidenceOf(text)
  })
}

if (finder.raw_shape === 'labelled-text') {
  // Blank-line-separated blocks. Every local-CLI finder reports this way:
  // the ones driven with this repo's own prompt badge each finding P0-P3, and
  // CodeRabbit's CLI, which takes no instructions of ours, states its own
  // labels in the same block. Which of the two a block is, is the severity
  // map's problem, not this loop's.
  const blocks = raw
    .split(/\n\s*\n/)
    .map((block) => block.trim())
    .filter((block) => block.length > 0)
  for (const [index, block] of blocks.entries()) {
    // A block that neither carries a severity label nor names a file is
    // narration (a header, a summary, "no P0 or P1 findings"), not a finding.
    // Requiring BOTH signals would drop a genuine unlabelled finding, which
    // AGENTS.md says is worth at least a P2 of adjudication; requiring
    // neither would turn every heading into one.
    if (!isLabelled(block) && !locationOf(block)) continue
    pushFinding(block, `block ${index + 1}`, null, `block-${index + 1}`)
  }
} else if (finder.raw_shape === 'github-review-json') {
  // The PR-side shape: one review plus the inline comments attributed to it.
  // Only this finder's own trusted actor and only the reviewed head count —
  // another bot's comment, or one about an earlier commit, is not this
  // finder's evidence for this cycle.
  let payload
  try {
    payload = JSON.parse(raw)
  } catch (error) {
    die(`raw output is not the JSON this finder's raw_shape declares: ${error.message}`)
  }
  const actorId = finder.trusted_actor_id
  const byThisFinder = (node) => String(node?.user?.id ?? '') === String(actorId)
  const atThisHead = (node) => String(node?.commit_id ?? '') === opts.reviewedHead

  for (const comment of payload.comments ?? []) {
    if (!byThisFinder(comment) || !atThisHead(comment)) continue
    const body = String(comment.body ?? '')
    const location = comment.path
      ? { path: comment.path, line: comment.line === null || comment.line === undefined ? null : Number(comment.line) }
      : null
    pushFinding(body, `inline comment ${comment.id ?? '?'}`, location, String(comment.id ?? `inline-${findings.length + 1}`))
  }

  // A review BODY becomes a finding only when it states one in this finder's
  // own vocabulary. A finder whose verdict is the inline-comment count (its
  // severity_map has no rules) therefore never produces a body finding, which
  // is correct: its body is a summary, not a finding.
  const review = payload.review
  if (review && byThisFinder(review) && atThisHead(review)) {
    const body = String(review.body ?? '')
    if (isLabelled(body)) {
      pushFinding(body, `review ${review.id ?? '?'}`, null, String(review.id ?? 'review'))
    }
  }
} else {
  die(`finder '${opts.finder}' declares an unsupported raw_shape ${finder.raw_shape}`)
}

// ── output ──────────────────────────────────────────────────────────────────
// Two shapes, because the two stages' own schemas are two shapes, and neither
// is this script's invention:
//
//   challenge/review  the confidence pass core (result.challenger /
//                     result.reviewer). For review that IS a complete,
//                     schema-valid reviewer payload.
//   integration       result.integrator's `findings[]` slice — {id, body,
//                     source_id} and nothing else, because that schema says
//                     the integrator "never authors or interprets finding
//                     text". The decoded priorities still matter for the
//                     adjudication table, so they ride ALONGSIDE the payload
//                     slice as `severity_hypotheses`, explicitly labelled a
//                     hypothesis rather than smuggled into a payload whose
//                     schema rejects them.
//
// Both carry the finder in the finding IDs (`<stage>-r<n>-<finder>-<k>`),
// which is the only place a downstream consumer needs it.
let output
if (opts.stage === 'integration') {
  output = {
    stage: 'integration',
    integration_round: Number(opts.round),
    finder: opts.finder,
    findings: findings.map((found) => ({
      id: found.id,
      body: found.evidence,
      source_id: found.source_id
    })),
    severity_hypotheses: findings.map((found) => ({ id: found.id, priority: found.priority }))
  }
} else {
  const counts = { P0: 0, P1: 0, P2: 0, P3: 0 }
  for (const found of findings) counts[found.priority] += 1
  output = {
    stage: opts.stage,
    round: Number(opts.round),
    reviewed_head: opts.reviewedHead,
    finder: opts.finder,
    slot: opts.slot ?? opts.finder,
    findings: findings.map(({ source_id, ...core }) => core),
    counts
  }
  if (opts.substitutesFor) output.substitutes_for = opts.substitutesFor
}

process.stdout.write(`${JSON.stringify(output, null, 2)}\n`)

if (undecoded.length > 0) {
  // Fail CLOSED. Dropping a finding the decoder could not place would remove
  // it from adjudication silently, and a dropped P0 is exactly the failure
  // this whole contract exists to prevent. --allow-undecoded is for a caller
  // that has read the report and decided.
  for (const entry of undecoded) {
    console.error(`normalize-finder-findings: undecoded ${entry.source} (${entry.priority}): ${entry.reason}`)
    console.error(entry.text.split('\n').map((line) => `    ${line}`).join('\n'))
  }
  if (!opts.allowUndecoded) {
    console.error(
      `normalize-finder-findings: ${undecoded.length} finding(s) could not be decoded and are NOT in the pass above; adjudicate them by hand or re-run with --allow-undecoded once you have.`
    )
    process.exit(3)
  }
}
