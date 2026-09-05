#!/usr/bin/env node
// normalize-finder-findings.mjs — decode ONE finder's raw output into the
// shared pass core every stage consumer already understands.
//
// It decodes MACHINE-SHAPED output only — a GitHub review and its comments.
// A local-CLI finder's free text is deliberately NOT decoded here, and that is
// a boundary rather than a gap: `/review`'s own contract already says "the
// registry invocation is the role's evidence source, not itself a result
// envelope: the dispatched role binds that output to the supplied run, scope,
// round, slot, and producer identity and returns `result.challenger` or
// `result.reviewer`". Reading that text is the ROLE's job, with the judgement
// a parser does not have.
//
// An earlier revision did decode it, and could not converge. Loosening the
// rule turned narration into findings ("Reviewing branch changes against
// origin/main."); tightening it dropped real ones (an unbadged file-level
// finding, two badged findings on consecutive lines). That is the same failure
// family this repository already documents at length above `verdict_class` in
// ai/skills/universal/integrate/assets/check-codex-cloud-review.sh — free text
// "is not a channel that can be parsed reliably" — and the fix there was the
// same one taken here: stop trying.
//
// A finder's `severity_map` still governs a local pass; the ROLE applies it.
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
//       [--registry <path>] [--input <file>]
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
// Exit: 0 decoded; 3 something could not be decoded; 2 usage or unreadable
// input. There is deliberately no flag to proceed past exit 3. An earlier
// revision had one, and it turned an undecodable P0 into a SUCCESSFUL empty
// pass — the finding reached stderr and nothing else, while the pass a stage
// banks is `findings[]`. A finding with no location cannot be represented at
// all (the shared schema requires `path`), so there is no honest "proceed
// anyway": decode it, or fix the input.

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
const opts = { registry: path.join(REPO_ROOT, 'agent-registry.json') }
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
//
// `matchesRule` still implements BOTH anchors although only `anywhere` is
// reachable from here now: a leading-token badge is what this repo's own
// prompt asks a local-CLI finder for, and those are decoded by the dispatched
// role, not by this script. The anchor stays generic because it is the
// registry's vocabulary, not this decoder's, and a future machine-shaped
// finder may well badge that way.
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
// A repo path needs SOME signal that separates it from an ordinary word, or
// every noun in a finding becomes a file. Requiring a dotted extension was one
// such signal and it was too narrow: `Dockerfile:12`, `Makefile`, `LICENSE`
// are ordinary repository files, and rejecting them made a local finder
// unusable the moment it reported one (#796 challenge round 4). The signal is
// now any ONE of three: a directory separator, a dotted extension, or a
// `:line` suffix — each of which a bare English word lacks.
//
// Residual, stated rather than rediscovered: a finding naming an
// extensionless file at the REPOSITORY ROOT with no line number (`LICENSE`,
// on its own) still does not decode, because at that point the token is
// textually indistinguishable from an ordinary noun and guessing would
// silently mislocate the finding. That case fails CLOSED — it is reported on
// stderr and the process exits 3 — so it is visible work for a human, never a
// dropped finding.
const PATH_TOKEN =
  /(?:^|[\s(`'"[])((?:[A-Za-z0-9_.-]+\/)+[A-Za-z0-9_.-]+|[A-Za-z0-9_-]+\.[A-Za-z0-9_]+|[A-Za-z0-9_.-]+(?=:\d))(?::(\d+))?/
function locationOf(text) {
  const match = PATH_TOKEN.exec(text)
  if (!match) return null
  // Trailing sentence punctuation is not part of a path: "against
  // origin/main." ends a sentence, and capturing the stop would put a path
  // in the record that does not exist.
  const candidate = match[1].replace(/[.,;:]+$/, '')
  // The same shape result.<role>.schema.json's own `path` pattern admits:
  // repo-relative, no `.`/`..` segment, and never empty.
  if (candidate.length === 0) return null
  if (candidate.split('/').some((segment) => segment === '.' || segment === '..')) return null
  return { path: candidate, line: match[2] ? Number(match[2]) : null }
}

// One body can state SEVERAL badged findings, and each needs its own id,
// priority and disposition — one cannot be fixed while another is declined if
// they share a record. Split at each point a severity rule matches, so each
// segment carries exactly one label; a body with one match (or none) comes
// back whole, which is the ordinary case.
function splitLabelledSegments(body) {
  const anchored = finder.severity_map.rules.filter((rule) => rule.anchor === 'anywhere')
  if (anchored.length === 0) return [body]
  const cuts = []
  const haystack = body.toLowerCase()
  for (const rule of anchored) {
    const needle = String(rule.match).toLowerCase()
    let at = haystack.indexOf(needle)
    while (at !== -1) {
      // Walk back over the markup a badge is wrapped in (`**P2**`, `_P2_`,
      // `` `P2` ``) so the segment opens with the whole badge rather than
      // splitting it in half and leaving `P2**` at the front.
      let start = at
      while (start > 0 && '*_`[('.includes(body[start - 1])) start -= 1
      cuts.push(start)
      at = haystack.indexOf(needle, at + needle.length)
    }
  }
  const starts = [...new Set(cuts)].sort((a, b) => a - b)
  if (starts.length < 2) return [body]
  // Everything before the first label rides with it: a heading or a lead-in
  // sentence belongs to the finding it introduces, not to a segment of its
  // own that would decode as an unlabelled extra.
  starts[0] = 0
  return starts
    .map((start, index) => body.slice(start, starts[index + 1] ?? body.length).trim())
    .filter((segment) => segment.length > 0)
}

// Findings are carried VERBATIM. Neither result schema bounds a finding body,
// and result.integrator's own contract says the integrator "never authors or
// interprets finding text" — an earlier revision truncated at 4,000
// characters, which silently removed the end of a long finding, where a
// remedy or the supporting context usually is. Only trailing whitespace per
// line is trimmed, and a blank LINE is content (see the note below).
function evidenceOf(text) {
  // Trailing spaces and tabs per line only. A blank LINE is content: an
  // integration finding is carried verbatim into adjudication, and collapsing
  // the paragraph breaks out of a review body rewrites the text a human is
  // being asked to adjudicate.
  return text.trim().replace(/[ \t]+$/gm, '')
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
  die(
    `finder '${opts.finder}' produces free text (raw_shape labelled-text), which this decoder does not read. ` +
      `That output is the dispatched role's evidence source under /review's own contract — the role binds it to ` +
      `the run, scope, round, slot and producer identity and returns the result envelope, applying this finder's ` +
      `severity_map itself. Only machine-shaped output (github-review-json) is decoded here.`
  )
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
  const surfaces = new Set(finder.collection?.terminal_signals?.surfaces ?? [])
  const actorId = finder.trusted_actor_id
  const byThisFinder = (node) => String(node?.user?.id ?? '') === String(actorId)
  // A REVIEW is bound by its own commit_id. An INLINE comment is bound by
  // `original_commit_id` — the commit it was actually written against —
  // because GitHub advances `commit_id` on a comment that still applies after
  // a push, so binding on that would accept a comment about an older tree as
  // current-head evidence. This is the same field the integrate checker's own
  // `inline_head_findings` selects on; the two must not disagree about which
  // comments belong to a head. A payload carrying only `commit_id` (a
  // hand-built fixture, an older capture) falls back to it rather than being
  // dropped.
  const atThisHead = (node) => String(node?.commit_id ?? '') === opts.reviewedHead
  const inlineAtThisHead = (node) =>
    node?.original_commit_id === undefined || node?.original_commit_id === null
      ? atThisHead(node)
      : String(node.original_commit_id) === opts.reviewedHead

  for (const comment of payload.comments ?? []) {
    if (!byThisFinder(comment) || !inlineAtThisHead(comment)) continue
    const body = String(comment.body ?? '')
    const location = comment.path
      ? { path: comment.path, line: comment.line === null || comment.line === undefined ? null : Number(comment.line) }
      : null
    pushFinding(body, `inline comment ${comment.id ?? '?'}`, location, String(comment.id ?? `inline-${findings.length + 1}`))
  }

  // The top-level CONVERSATION surface, for a finder whose registry entry
  // lists it. A top-level comment carries no commit_id — that is exactly why
  // its registry `head_binding` is `reviewed-commit-line` — so it binds
  // through the reviewed-commit prefix in its own body, matched the same way
  // the integrate checker matches it. Without this the surface decoded to
  // nothing at all, and a badged finding Codex posts there vanished from the
  // normalized pass while AGENTS.md requires exactly that finding to outrank
  // a later clean result.
  if (surfaces.has('comment')) {
    for (const comment of payload.top_level_comments ?? []) {
      if (!byThisFinder(comment)) continue
      const body = String(comment.body ?? '')
      const stamp = /Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})/i.exec(body)
      // No stamp is not this head's evidence: the binding is the only thing
      // tying a top-level comment to a commit, so an unstamped one is
      // unattributable rather than current.
      if (!stamp) continue
      if (!opts.reviewedHead.startsWith(stamp[1].toLowerCase())) continue
      if (!isLabelled(body)) continue
      for (const segment of splitLabelledSegments(body)) {
        pushFinding(segment, `comment ${comment.id ?? '?'}`, null, String(comment.id ?? 'comment'))
      }
    }
  }

  // A review BODY becomes a finding only when it states one in this finder's
  // own vocabulary. A finder whose verdict is the inline-comment count (its
  // severity_map has no rules) therefore never produces a body finding, which
  // is correct: its body is a summary, not a finding.
  const review = payload.review
  if (review && byThisFinder(review) && atThisHead(review)) {
    const body = String(review.body ?? '')
    if (isLabelled(body)) {
      for (const segment of splitLabelledSegments(body)) {
        pushFinding(segment, `review ${review.id ?? '?'}`, null, String(review.id ?? 'review'))
      }
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
  // this whole contract exists to prevent, and there is no flag to opt out of
  // it: a caller that "has read the report and decided" still ships a pass
  // with the finding missing from `findings[]`, which is the only place a
  // stage looks.
  for (const entry of undecoded) {
    console.error(`normalize-finder-findings: undecoded ${entry.source} (${entry.priority}): ${entry.reason}`)
    console.error(entry.text.split('\n').map((line) => `    ${line}`).join('\n'))
  }
  console.error(
    `normalize-finder-findings: ${undecoded.length} finding(s) could not be decoded and are NOT in the pass above. Fix the input or decode them by hand — there is no flag to continue past this, because a pass that omits a finding is exactly what a stage would bank as clean.`
  )
  process.exit(3)
}
