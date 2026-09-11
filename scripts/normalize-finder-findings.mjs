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
// Where a rule's match occurs at the start of a line (after the markup a badge
// is wrapped in), or -1. That position is what makes a badge a LABEL rather
// than a mention: "the P0/P1 rule in AGENTS.md" contains both strings and
// labels nothing.
function leadingHit(text, rule) {
  if (rule.anchor !== 'anywhere') return matchesRule(text, rule) ? 0 : -1
  const needle = String(rule.match).toLowerCase()
  const haystack = text.toLowerCase()
  let at = haystack.indexOf(needle)
  while (at !== -1) {
    let start = at
    while (start > 0 && '*_`[('.includes(text[start - 1])) start -= 1
    // The SAME token boundary the fallback path applies. An earlier fix put it
    // only in matchesRule(), but priorityOf() consults this function first —
    // so a line-start `P30` still took P3, which is the higher-precedence path
    // and therefore the one that actually decided the priority.
    if ((start === 0 || text[start - 1] === '\n') && !isWordChar(haystack[at + needle.length])) return start
    at = haystack.indexOf(needle, at + 1)
  }
  return -1
}

// Is the character at `i` part of the same token as the badge? A bare
// substring test made `P30` match the `P3` rule and normalize a finding whose
// badge is off the scale into the cosmetic, non-gating tier — the exact
// opposite of the rule that an unrecognized badge is adjudicated as at least a
// P2. Alphanumeric neighbours are what disqualify a hit; punctuation and
// whitespace do not, because a badge is routinely wrapped (`**P1**`, `P1:`).
function isWordChar(ch) {
  return ch !== undefined && /[a-z0-9]/.test(ch)
}

function includesAsToken(haystack, needle) {
  let at = haystack.indexOf(needle)
  while (at !== -1) {
    if (!isWordChar(haystack[at - 1]) && !isWordChar(haystack[at + needle.length])) return true
    at = haystack.indexOf(needle, at + 1)
  }
  return false
}

function matchesRule(text, rule) {
  const needle = String(rule.match).toLowerCase()
  if (rule.anchor === 'anywhere') return includesAsToken(text.toLowerCase(), needle)
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
  // A LABEL first — a rule whose match opens a line. Scanning the whole body
  // for any occurrence let a finding that merely discusses "the P0/P1 gate"
  // take P0, because the rules are ordered severest-first and a mention reads
  // exactly like a badge to `includes`.
  for (const rule of finder.severity_map.rules) {
    if (leadingHit(text, rule) !== -1) return rule.priority
  }
  // Nothing labels this body. Fall back to any occurrence, so a badge written
  // somewhere other than a line start still counts for something rather than
  // silently defaulting — the default below is the floor, not the answer.
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
      const found = at
      at = haystack.indexOf(needle, found + needle.length)
      // Walk back over the markup a badge is wrapped in (`**P2**`, `_P2_`,
      // `` `P2` ``) so the segment opens with the whole badge rather than
      // splitting it in half and leaving `P2**` at the front.
      let start = found
      while (start > 0 && '*_`[('.includes(body[start - 1])) start -= 1
      // A cut only where the badge OPENS A LINE. Every occurrence would split
      // on prose too: a finding that discusses "the P0/P1 gate", or names a
      // symbol containing one, would be chopped into fabricated findings and
      // could pick up a spurious severity from the mention. Both Codex and
      // CodeRabbit lead a finding with its badge, so the line start is the
      // signal, and a mid-sentence mention is left where it is.
      if (start === 0 || body[start - 1] === '\n') cuts.push(start)
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

  const SUBMITTED_REVIEW_STATES = new Set(['approved', 'changes_requested', 'commented'])
  const reviewIsSubmitted = (review) => {
    const state = review?.state
    if (state === undefined || state === null) return false
    return SUBMITTED_REVIEW_STATES.has(String(state).toLowerCase())
  }

  // Inline comments must belong to the REVIEW being decoded, not merely to the
  // same actor at the same head. A re-trigger without a head change leaves the
  // previous review's comments in place, so a clean review plus a stale P1
  // from an earlier review normalized as a current finding — and for a
  // count-declaring finder the same staleness shows up as a false
  // actionable-count mismatch instead. Correlation is by
  // `pull_request_review_id`, which the GitHub reviews API always sets on an
  // inline review comment.
  const selectedReviewId = payload.review?.id
  const inlineForThisFinder = (payload.comments ?? []).filter((c) => byThisFinder(c) && inlineAtThisHead(c))
  if (inlineForThisFinder.length > 0) {
    if (selectedReviewId === undefined || selectedReviewId === null) {
      die(
        `${finder.slug} supplied ${inlineForThisFinder.length} current-head inline comment(s) but no review to attribute them to — ` +
          `without \`review.id\` a stale comment from an earlier review cannot be told from this one's`,
        3
      )
    }
    if (reviewIsSubmitted(payload.review)) {
      for (const comment of inlineForThisFinder) {
        const owner = comment.pull_request_review_id
        if (owner === undefined || owner === null) {
          die(
            `${finder.slug} inline comment ${comment.id ?? '?'} carries no \`pull_request_review_id\`, so it cannot be attributed to review ` +
              `${selectedReviewId} — refusing rather than banking a comment that may belong to an earlier review`,
            3
          )
        }
        if (String(owner) !== String(selectedReviewId)) {
          die(
            `${finder.slug} inline comment ${comment.id ?? '?'} belongs to review ${owner}, not the supplied review ${selectedReviewId} — ` +
              `it is an earlier review's finding at the same head and must not be decoded as this round's`,
            3
          )
        }
      }
    }
  }

  for (const comment of payload.comments ?? []) {
    if (!byThisFinder(comment) || !inlineAtThisHead(comment)) continue
    if (!reviewIsSubmitted(payload.review)) continue
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
      if (!stamp) continue
      const stampSha = stamp[1].toLowerCase()
      if (stampSha.length < 40) {
        if (opts.reviewedHead.startsWith(stampSha)) {
          die(
            `${finder.slug} top-level comment ${comment.id ?? '?'} stamps an abbreviated SHA ` +
              `(${stampSha.length} chars) that prefix-matches the reviewed head — ` +
              `this decoder has no git access to prove the abbreviation is unique`,
            3
          )
        }
        continue
      }
      if (stampSha !== opts.reviewedHead) continue
      if (!isLabelled(body)) continue
      for (const segment of splitLabelledSegments(body)) {
        pushFinding(segment, `comment ${comment.id ?? '?'}`, null, String(comment.id ?? 'comment'))
      }
    }
  }

  // No current-head artifact from this finder at all is INDETERMINATE, not a
  // clean review. An empty or partial GitHub fetch — `{}` was enough —
  // previously emitted a successful result with `findings: []`, which a caller
  // could persist as a completed slice: missing terminal evidence was
  // indistinguishable from a reviewer that found nothing. A finder that states
  // its own count is covered by the stricter reconciliation below; this is the
  // floor for the ones that do not. It asks only that SOMETHING attributable
  // to this finder and bound to this head appears on one of the surfaces its
  // registry entry declares — a review, an inline comment, or a stamped
  // top-level comment. A genuinely clean cloud review still carries its
  // review or comment, so this does not refuse a real empty result.
  // TERMINAL, not merely present — and only on a surface this finder's own
  // registry entry declares. An earlier revision asked for any actor-
  // authenticated artifact at the head, which two payloads slipped past: a
  // current-head review whose body is pending text or unrecognized vendor
  // wording, and a top-level comment for a finder like `copilot-cloud` whose
  // profile lists only `review` and `inline`. Both produced a successful
  // empty slice.
  //
  // What counts as terminal is the finder's DECLARED `verdict_mode`, not one
  // hard-coded notion of doneness — the three shipped modes say it three
  // different ways, and a blanket "clean sentence or decodable findings" rule
  // would refuse a legitimately clean CodeRabbit or Copilot review.
  const verdictMode = finder.collection?.terminal_signals?.verdict_mode
  const declaredClean = finder.collection?.terminal_signals?.clean_verdict
  const declaredCount = finder.collection?.terminal_signals?.actionable_pattern
  const cleanVerdictMetadata = (() => {
    const ts = finder.collection?.terminal_signals ?? {}
    const patterns = []
    const strings = []
    for (const key of ['metadata_line', 'heading']) {
      if (ts[key]) patterns.push(new RegExp(String(ts[key]).replace(/\[\[:space:\]\]/g, '\\s'), 'i'))
    }
    for (const key of ['about_summary', 'carrier_sentence']) {
      if (ts[key]) strings.push(String(ts[key]).toLowerCase())
    }
    return { patterns, strings }
  })()
  const bodyIsTerminal = (body) => {
    const text = String(body ?? '')
    if (isLabelled(text)) return true
    switch (verdictMode) {
      case 'clean-sentence': {
        if (!declaredClean) return false
        const want = String(declaredClean).toLowerCase()
        const head = text.replace(/^[\s*_`>#-]+/, '').toLowerCase()
        if (!head.startsWith(want)) return false
        const strippedLen = text.length - head.length
        const remainder = text.slice(strippedLen + want.length)
        for (const line of remainder.split('\n')) {
          const trimmed = line.trim()
          if (trimmed.length === 0) continue
          const recognized =
            cleanVerdictMetadata.patterns.some((p) => p.test(trimmed)) ||
            cleanVerdictMetadata.strings.some((s) => trimmed.toLowerCase().includes(s))
          if (!recognized) return false
        }
        return true
      }
      case 'actionable-count':
        // The finder states how many findings it posted; zero is a verdict.
        return Boolean(declaredCount) && new RegExp(String(declaredCount).replace(/\[\[:space:\]\]/g, '\\s'), 'i').test(text)
      case 'inline-comment-count':
        // The inline comments ARE the result and a review carrying none is
        // the clean verdict, so a SUBMITTED review's existence at this head is
        // the signal. There is no sentence or count to match — which is
        // exactly why the state check below carries the whole weight here.
        return true
      default:
        return false
    }
  }
  // The `reaction` surface, where the finder declares one. A fresh success
  // reaction on the exact trigger comment is a complete clean verdict for
  // codex-cloud, and the integrate checker already treats it as one — so a
  // reaction-only cycle used to exit 3 here as though no evidence existed,
  // refusing a result that is genuinely terminal. It must be THIS finder's
  // reaction, the declared success content, and on the trigger the caller
  // names, so a stray 👍 from anyone else proves nothing.
  const successReaction = finder.collection?.terminal_signals?.success_reaction
  const sawSuccessReaction =
    surfaces.has('reaction') &&
    Boolean(successReaction) &&
    (payload.trigger_reactions ?? []).some(
      (r) => byThisFinder(r) && String(r.content ?? '').toLowerCase() === String(successReaction).toLowerCase()
    )
  const sawCurrentHeadArtifact =
    sawSuccessReaction ||
    (surfaces.has('review') &&
      payload.review !== undefined &&
      payload.review !== null &&
      byThisFinder(payload.review) &&
      atThisHead(payload.review) &&
      reviewIsSubmitted(payload.review) &&
      bodyIsTerminal(payload.review.body)) ||
    (surfaces.has('inline') && reviewIsSubmitted(payload.review) &&
      (payload.comments ?? []).some((c) => byThisFinder(c) && inlineAtThisHead(c))) ||
    (surfaces.has('comment') &&
      (payload.top_level_comments ?? []).some((c) => {
        if (!byThisFinder(c)) return false
        const stamp = /Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})/i.exec(String(c.body ?? ''))
        if (!stamp) return false
        const cStampSha = stamp[1].toLowerCase()
        if (cStampSha.length < 40) {
          if (opts.reviewedHead.startsWith(cStampSha)) {
            die(
              `${finder.slug} top-level comment ${c.id ?? '?'} stamps an abbreviated SHA ` +
                `(${cStampSha.length} chars) that prefix-matches the reviewed head — ` +
                `this decoder has no git access to prove the abbreviation is unique`,
              3
            )
          }
          return false
        }
        if (cStampSha !== opts.reviewedHead) return false
        return bodyIsTerminal(c.body)
      }))
  if (!sawCurrentHeadArtifact) {
    die(
      `${finder.slug} produced no artifact attributable to it at ${opts.reviewedHead} on any surface its registry entry declares — ` +
        `the supplied payload carries no current-head terminal evidence, and emitting an empty slice would make a missing or partial fetch ` +
        `indistinguishable from a review that found nothing`,
      3
    )
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

  // The finder's own declared finding count, where its registry entry states
  // one. A review saying "Actionable comments posted: 2" whose supplied
  // comments array holds one — a partial fetch, an unpaginated read — would
  // otherwise normalize the shortfall away and report a smaller round as
  // complete. The pattern is the registry's; the reconciliation is here.
  const actionablePattern = finder.collection?.terminal_signals?.actionable_pattern
  if (actionablePattern) {
    if (!review || !byThisFinder(review) || !atThisHead(review)) {
      die(
        `${finder.slug} states its own finding count, so its current-head review is required evidence — the supplied payload carries none for this finder at ${opts.reviewedHead}, and a partial fetch would otherwise normalize a short comments array into a complete-looking round`,
        3
      )
    }
    const declared = new RegExp(actionablePattern.replace(/\[\[:space:\]\]/g, '\\s'), 'i').exec(
      String(review.body ?? '')
    )
    if (!declared || declared[1] === undefined) {
      die(
        `${finder.slug}'s current-head review does not state a parseable finding count (${actionablePattern}), so the supplied evidence cannot be checked for completeness`,
        3
      )
    }
    const expected = Number(declared[1])
    const decoded = findings.length
    if (!Number.isFinite(expected)) {
      die(`${finder.slug}'s declared finding count is not a number: ${declared[1]}`, 3)
    }
    if (decoded !== expected) {
      die(
        `${finder.slug} declares ${expected} actionable comment(s) but ${decoded} were decoded from the supplied evidence — ` +
          `the input is incomplete (an unpaginated or partial fetch), and normalizing the shortfall away would report a smaller round as complete`,
        3
      )
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
