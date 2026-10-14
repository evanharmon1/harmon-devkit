#!/usr/bin/env node
// retro-run-report.mjs — project one Dev flow v2 run's retained evidence into
// the fixed measurement sections of a `/retro` report.
//
// A projection, never a second source of truth: every number below is read
// from the run trajectory `dev-flow-stats.mjs --run <id> --json`
// harvests (issue #663) or from the resolved-policy line the renderer already
// published into the PR body (`dev-flow-support/assets/render-dev-flow.mjs`, issue #637).
// Nothing here re-derives a disposition, a cap, or an exit.
//
// Usage:
//   retro-run-report.mjs --repo <owner/repo> --pr <n> [--run <run_id>]
//     [--trusted-actor-id <id>]... [--trusted-actors-file <path>]
//     [--record-dir <path>] [--as-of <iso8601>] [--stats-script <path>] [--json]
//
// Exit codes — the caller (the /retro skill) branches on these:
//   0   a report was rendered on stdout.
//   10  we LOOKED and there is no retained evidence: `no-run-record` (no
//       evidence marker at all on the PR or its linked issues) or
//       `run-not-found` for an id supplied with --run, which nothing ever
//       claimed existed. This is the only exit that licenses "this session
//       has no run record". A marker-named run the harvester cannot find is
//       NOT here — that is the deleted-entry case, exit 11.
//   12  `no-stats-script` — this checkout has no harvester, so whether a run
//       record exists is UNKNOWN, not absent. Discovery still runs first, so
//       stderr says whether a marker was found that cannot be read here.
//   11  evidence exists but is INDETERMINATE — a broken or forged chain; two
//       trusted runs claimed on one PR; a harvested run bound to a different
//       PR; markers that exist but none from a trusted actor; or a trusted
//       marker naming a run the harvester cannot find (deleted-entry
//       tampering). Nothing is rendered; the reason is on stderr. Never
//       report a clean retro on this path, and never fall back to memory.
//   13  local-unverified — opt-in local record, not authenticated by a trusted GitHub evidence marker.
//       Never a verified report or an authenticated trajectory.
//   14  refused local record — unsafe or invalid local input, or unsupported
//       platform; never evidence tampering. Local reads are Linux-only.
//   2   usage error.  1  operational error (a `gh` or harvester failure).
//
// Why 10, 11 and 12 are three exits, not one. "Nothing was posted" is the
// normal pre-v2 session and costs the retro only its evidence section. "What
// is there does not authenticate" is a finding in its own right — collapsing
// it into 10 would let tampered evidence read as an ordinary memory-based
// retro. And "this checkout cannot read what may well be there" is neither:
// a missing local dependency is evidence about the checkout, never about the
// run, so reporting it as 10 would let a vendoring gap masquerade as a run
// that was never recorded (challenge round 1, confirmed P1).

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, readFileSync, realpathSync, mkdtempSync, writeFileSync, rmSync, statSync, constants, openSync, fstatSync, closeSync, readlinkSync, lstatSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const TOOL = 'retro-run-report'
const MAX_SYNC_BUFFER_BYTES = 64 * 1024 * 1024

const USAGE = `Usage: retro-run-report.mjs --repo <owner/repo> --pr <n> [options]

  --repo <owner/repo>          Required. The repository the run lives in.
  --pr <n>                     The session's PR. Required unless --run is given.
  --run <run_id>               Skip discovery and report on this run.
  --trusted-actor-id <id>      Repeatable. Trusted-orchestrator GitHub actor
                               ids. Gates which comments may name a run AND is
                               passed through to the harvester. Overrides the
                               remote repository registry when supplied.
  --trusted-actors-file <path> A JSON {"trusted_actor_ids": [...]} document,
                               passed through to the harvester. Explicit trust
                               flags override agent-registry.json; otherwise
                               trusted_orchestrator_actor_ids is required there.
  --as-of <iso8601>            Reconstruct the RUN RECORD and its comment
                               evidence as of this instant. These inputs stay
                               current-state: the linked-issue set (the PR's
                               closing and body references), the PR body the
                               disclosed caps are read from, and the default
                               trust set (default-branch registry).
                               Replay trusts the default allowlist as it is now;
                               the harvester still applies write-time registry
                               revisions to legacy evidence.
  --stats-script <path>        Override harvester discovery (tests, or a
                               checkout that keeps it somewhere else).
  --record-dir <path>          Parent directory containing <run_id>/run.json;
                               passed through unchanged to the harvester.
  --local-unverified           After run-not-found only, read --record-dir/--run
                               as unverified local data (exit 13). Linux-only:
                               containment needs a single-step descriptor path.
                               Unsafe or invalid local records exit 14, as does
                               an unsupported platform, with the refusal reason:
                               local descriptor containment cannot be established on this platform
                               Requires both flags. Ignored when authenticated
                               evidence exists.
  --json                       Emit the machine form instead of Markdown.`

class UsageError extends Error {}
class OperationalError extends Error {}
class LocalRefusalError extends Error {}
// Evidence that exists but does not authenticate, or cannot be attributed to
// one run. Distinct from "no evidence" — see the exit-code table above.
class IndeterminateError extends Error {
  constructor(message, { ignoredHints = [], untrusted = [], malformed = [] } = {}) {
    super(message)
    this.ignoredHints = [...ignoredHints]
    this.untrusted = [...untrusted]
    this.malformed = [...malformed]
  }
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { trustedActorIds: [] }
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i]
    const take = () => {
      const value = argv[i + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new UsageError(`${flag} requires a value`)
      }
      i += 1
      return value
    }
    switch (flag) {
      case '--help':
      case '-h':
        args.help = true
        break
      case '--repo':
        args.repo = take()
        break
      case '--pr':
        args.pr = take()
        break
      case '--run':
        args.run = take()
        break
      case '--trusted-actor-id':
        args.trustedActorIds.push(take())
        break
      case '--trusted-actors-file':
        args.trustedActorsFile = take()
        break
      case '--as-of':
        args.asOf = take()
        break
      case '--stats-script':
        args.statsScript = take()
        break
      case '--record-dir':
        args.recordDir = take()
        break
      case '--local-unverified':
        args.localUnverified = true
        break
      case '--json':
        args.json = true
        break
      default:
        throw new UsageError(`unknown argument ${JSON.stringify(flag)}`)
    }
  }
  return args
}

// The same grammar dev-flow-stats.mjs enforces on its own --as-of:
// UTC "Z" form only (a timezone-less stamp would parse as LOCAL time, making
// a "reproducible" cutoff environment-dependent), and calendar-valid, since
// Date.parse silently NORMALIZES an impossible date like 2026-02-30 into a
// different real one. Duplicated rather than imported because the harvester
// is a separate, optional script this asset must run without.
const ISO_TIMESTAMP_RE = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?Z$/

function isCalendarValid(match, epoch) {
  const d = new Date(epoch)
  return (
    d.getUTCFullYear() === Number(match[1]) &&
    d.getUTCMonth() + 1 === Number(match[2]) &&
    d.getUTCDate() === Number(match[3]) &&
    d.getUTCHours() === Number(match[4]) &&
    d.getUTCMinutes() === Number(match[5]) &&
    d.getUTCSeconds() === Number(match[6])
  )
}

function validateArgs(args) {
  if (!args.repo) throw new UsageError('--repo <owner/repo> is required')
  if (!/^[^/\s]+\/[^/\s]+$/.test(args.repo)) {
    throw new UsageError(`--repo must be owner/repo, got ${JSON.stringify(args.repo)}`)
  }
  if (args.pr !== undefined) {
    if (!/^[1-9][0-9]*$/.test(args.pr)) {
      throw new UsageError(`--pr must be a positive integer, got ${JSON.stringify(args.pr)}`)
    }
    args.pr = Number(args.pr)
  }
  if (args.pr === undefined && !args.run) {
    throw new UsageError('--pr <n> is required unless --run <run_id> is given')
  }
  // Checked here rather than where the harvester is resolved, so a mistyped
  // path is a usage error before the first `gh` call rather than after it.
  if (args.statsScript !== undefined && !existsSync(args.statsScript)) {
    throw new UsageError(`--stats-script path does not exist: ${args.statsScript}`)
  }
  if (args.recordDir !== undefined) {
    let isDirectory
    try {
      isDirectory = statSync(args.recordDir).isDirectory()
    } catch (error) {
      if (args.localUnverified && error.code !== 'ENOENT') {
        throw new LocalRefusalError('--record-dir cannot be read as a directory')
      }
      if (!existsSync(args.recordDir)) {
        throw new UsageError(`--record-dir path does not exist: ${args.recordDir}`)
      }
      throw error
    }
    if (!isDirectory) throw new UsageError('--record-dir must be a directory')
  }
  // Validated here for the same reason, and it became load-bearing the moment
  // the cutoff started filtering discovery: an unparseable value makes
  // Date.parse NaN, every `created <= NaN` false, and the tool report "no run
  // record" for a run that is plainly there — a typo turned into a false
  // statement about the evidence (challenge round 3, confirmed P1).
  if (args.asOf !== undefined) {
    const match = ISO_TIMESTAMP_RE.exec(args.asOf)
    const epoch = match ? Date.parse(args.asOf) : NaN
    if (!match || Number.isNaN(epoch) || !isCalendarValid(match, epoch)) {
      throw new UsageError(`--as-of is not a valid ISO-8601 UTC timestamp: ${JSON.stringify(args.asOf)}`)
    }
  }
}

// ---------------------------------------------------------------------------
// gh
// ---------------------------------------------------------------------------

// Resolved through $PATH, never an absolute path, so a test's stub directory
// prepended to PATH shadows the real gh — the shim pattern the rest of this
// repository's suites already use.
function gh(argv) {
  const result = spawnSync('gh', argv, { encoding: 'utf8', maxBuffer: MAX_SYNC_BUFFER_BYTES })
  if (result.error) {
    throw new OperationalError(`gh ${argv[0]} failed to execute: ${result.error.message}`)
  }
  if (result.status !== 0) {
    throw new OperationalError(`gh ${argv.join(' ')} exited ${result.status}: ${(result.stderr || '').trim()}`)
  }
  return result.stdout
}

function ghJson(argv) {
  const out = gh(argv)
  try {
    return JSON.parse(out)
  } catch (error) {
    throw new OperationalError(`gh ${argv.join(' ')} returned malformed JSON: ${error.message}`)
  }
}

// Conversation comments on an issue OR a pull request — GitHub stores both in
// the same collection. Fetched through `gh api --paginate` rather than
// `gh pr view --json comments`, which returns only the first page: a stage
// rollup on a busy PR sits well past comment 100, and a discovery that reads
// only the first page would report "no run record" for a run that plainly has
// one. Same call shape dev-flow-stats.mjs uses for the same reason.
function fetchComments(repo, number, asOf) {
  const pages = ghJson(['api', '--paginate', '--slurp', `repos/${repo}/issues/${number}/comments`])
  const comments = Array.isArray(pages) ? pages.flat() : []
  if (!asOf) return comments
  // --as-of promises an immutable reconstruction, and discovery is part of
  // the reconstruction: without this filter a marker posted after the cutoff
  // could select a different run, or make an earlier read newly ambiguous, so
  // the same cutoff would stop giving the same answer (challenge round 2,
  // confirmed P1). A comment with no usable created_at is excluded rather
  // than assumed early — nothing places it before the cutoff.
  const cutoff = Date.parse(asOf)
  return comments.filter((comment) => {
    const created = Date.parse(comment && comment.created_at)
    return Number.isFinite(created) && created <= cutoff
  })
}

// ---------------------------------------------------------------------------
// Harvester discovery
// ---------------------------------------------------------------------------

function repoRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      maxBuffer: MAX_SYNC_BUFFER_BYTES
    }).trim()
  } catch {
    return null
  }
}

// The harvester is this asset's own SIBLING now (harmon-devkit#974): both ship
// in the retro skill's `assets/`, so `task sync:skills` vendors them together
// and the pair cannot arrive half-installed the way a skill-here /
// repository-root-`scripts/`-there split could. It is therefore resolved from
// this file's own location rather than from the git top level, which is what
// makes the harvester findable in a consumer repo at all — a consumer has no
// `ai/` tree, and the depth from an asset to a repository root differs between
// harmon-devkit's source layout and a flattened `.claude/skills/` one.
//
// The "harvester missing" branch is kept even so: --stats-command still
// overrides, and a partially-vendored package should say what is absent rather
// than throw.
const ASSET_DIR = path.dirname(fileURLToPath(import.meta.url))

function resolveStatsCommand(explicit) {
  if (explicit) return statsCommandFor(explicit)
  for (const candidate of ['dev-flow-stats.sh', 'dev-flow-stats.mjs']) {
    const full = path.join(ASSET_DIR, candidate)
    if (existsSync(full)) return statsCommandFor(full)
  }
  return { missingReason: `${ASSET_DIR} has no dev-flow-stats.sh or dev-flow-stats.mjs beside this report generator — the retro skill's assets are incompletely vendored` }
}

function statsCommandFor(file) {
  return file.endsWith('.mjs') || file.endsWith('.js')
    ? { command: process.execPath, prefix: [file], display: `node ${file}` }
    : { command: file, prefix: [], display: file }
}

// ---------------------------------------------------------------------------
// Run-id discovery
// ---------------------------------------------------------------------------

// ai/schemas/README.md "Evidence marker and digest grammar": every evidence
// comment OPENS with one marker line, and the grammar is
//
//   <!-- devflow:<kind> v2 run_id=<id> stage=<stage> dest=<issue|pr> round=<n|-> seq=<n> -->
//
// Anchoring the match to the start of the comment body (harmon-devkit#752) is
// what stops a marker quoted inside prose — a real risk on a PR that discusses
// this protocol — from inventing a run.
const EVIDENCE_MARKER_RE = /^<!--\s+devflow:([a-z][a-z-]*)\s+v2\s+([^>]*?)-->/
const REVIEW_EVIDENCE_MARKER_RE = /^<!--[ \t]*dev-flow-v2-evidence:[ \t]*(\{[^\r\n]*\})[ \t]*-->(?=\r?\n|$)/
const REVIEW_EVIDENCE_PREFIX_RE = /^<!--[ \t]*dev-flow-v2-evidence:/
const NONCANONICAL_EVIDENCE_PREFIX_RE = /^<!--[ \t]*dev-flow-v2[- \t]+evidence(?=[ \t:\n]|-->|$)/

// Only these three kinds are evidence. An earlier revision accepted any
// lowercase kind carrying a run_id, so a trusted `devflow:example` comment on
// a protocol-discussion PR could select a run or force the multi-run
// indeterminate path (review round 4, confirmed P2).
const EVIDENCE_KINDS = new Set(['run-index', 'run-record', 'evidence'])

// run.schema.json's stage_transitions[].stage enum — the run's own span.
const MARKER_STAGES = new Set([
  'kickoff',
  'claim',
  'explore',
  'plan',
  'implement',
  'verify',
  'challenge',
  'review',
  'security',
  'integration'
])

function parseMarkerAttributes(chunk) {
  const attrs = {}
  for (const [, key, value] of chunk.matchAll(/([a-z_]+)=([^\s>]+)/g)) attrs[key] = value
  return attrs
}

// Returns {runId} for a canonical marker, {malformed: <why>} for a first-line
// devflow marker that is not one, or null for a comment that carries no marker
// at all. The three are genuinely different: only the first names a run, and
// only the second is worth reporting as an anomaly.
function parseMarker(body) {
  if (typeof body !== 'string') return null
  // Horizontal indentation only: `\s` would eat NEWLINES too, so a comment
  // that opens with blank lines and then quotes a marker would read as one
  // (review round 1, confirmed P2). The grammar says first LINE, so only
  // leading spaces/tabs on that line may be skipped.
  const firstLine = body.replace(/\r/g, '').replace(/^[ \t]+/, '')
  const reviewMarker = REVIEW_EVIDENCE_MARKER_RE.exec(firstLine)
  if (reviewMarker) {
    let value
    try {
      value = JSON.parse(reviewMarker[1])
    } catch {
      return { malformed: 'dev-flow-v2-evidence payload is not valid JSON' }
    }
    const keys = value && typeof value === 'object' && !Array.isArray(value) ? Object.keys(value).sort() : []
    if (JSON.stringify(keys) !== JSON.stringify(['destination', 'round', 'run_id', 'sequence', 'stage'])) {
      return { malformed: 'dev-flow-v2-evidence payload does not contain exactly run_id, stage, round, sequence, destination' }
    }
    if (typeof value.run_id !== 'string' || value.run_id.length === 0) return { malformed: 'run_id is not a non-empty string' }
    if (!MARKER_STAGES.has(value.stage)) return { malformed: `stage "${value.stage}" is not a run stage` }
    if (value.destination !== 'issue' && value.destination !== 'pr') return { malformed: `destination "${value.destination}" is not issue or pr` }
    if (value.round !== null && (!Number.isInteger(value.round) || value.round < 1)) return { malformed: 'round is neither null nor a positive integer' }
    if ((value.destination === 'issue') !== (value.round !== null)) return { malformed: 'destination and round do not form an issue-round or PR-rollup pair' }
    if (!Number.isInteger(value.sequence) || value.sequence < 1) return { malformed: 'sequence is not a positive integer' }
    return { kind: 'evidence', runId: value.run_id, destination: value.destination }
  }
  if (REVIEW_EVIDENCE_PREFIX_RE.test(firstLine)) return { malformed: 'dev-flow-v2-evidence marker has trailing content or an invalid payload' }
  if (NONCANONICAL_EVIDENCE_PREFIX_RE.test(firstLine)) {
    return { malformed: 'non-canonical dev-flow-v2 evidence marker (expected <!-- dev-flow-v2-evidence: {...} -->)' }
  }
  const marker = EVIDENCE_MARKER_RE.exec(firstLine)
  if (!marker) return null
  const kind = marker[1]
  if (!EVIDENCE_KINDS.has(kind)) return { malformed: `kind "${kind}" is not run-index, run-record or evidence` }
  const attrs = parseMarkerAttributes(marker[2])
  for (const required of ['run_id', 'stage', 'dest', 'round', 'seq']) {
    if (attrs[required] === undefined) return { malformed: `missing required marker field ${required}` }
  }
  if (!MARKER_STAGES.has(attrs.stage)) return { malformed: `stage "${attrs.stage}" is not a run stage` }
  if (attrs.dest !== 'issue' && attrs.dest !== 'pr') return { malformed: `dest "${attrs.dest}" is not issue or pr` }
  if (attrs.round !== '-' && !/^[1-9][0-9]*$/.test(attrs.round)) {
    return { malformed: `round "${attrs.round}" is neither "-" nor a positive integer` }
  }
  if (!/^[1-9][0-9]*$/.test(attrs.seq)) return { malformed: `seq "${attrs.seq}" is not a positive integer` }
  return { kind, runId: attrs.run_id, destination: attrs.dest }
}

// Which run a report is about is chosen by a marker, and a marker is just
// text anyone with comment rights can post. Gating discovery on the comment
// author's immutable actor id is what stops a drive-by comment naming some
// other (perfectly authentic) run from redirecting this PR's retro onto it,
// or a second bogus marker from forcing the ambiguity exit — challenge round
// 1, confirmed P1. ai/schemas/README.md already fixes the rule for the
// harvester ("a forged-author comment: reported, ignored"); discovery is the
// same trust boundary one step earlier, so it applies the same rule and
// REPORTS what it ignored rather than dropping it silently.
//
// Malformed and untrusted are kept apart on purpose. A malformed marker is
// noise — it never named a run, so it cannot make discovery indeterminate. A
// canonical marker from an untrusted author IS a claim, and refusing it is
// exactly what the indeterminate exit exists to surface.
function collectRunIds(comments, trustedActorIds, where, expectedDestination, untrusted, malformed) {
  const found = new Set()
  for (const comment of comments || []) {
    const parsed = parseMarker(comment && comment.body)
    if (!parsed) continue
    const actorId = comment.user && Number(comment.user.id)
    const entry = {
      comment_id: comment.id ?? null,
      actor_id: Number.isInteger(actorId) ? actorId : null,
      where
    }
    const isTrusted = Number.isInteger(actorId) && trustedActorIds.has(actorId)
    if (parsed.malformed) {
      // Whose marker it is decides what a malformed one MEANS. From an
      // untrusted author it is noise that never named a run. From a TRUSTED
      // orchestrator it is this run's own evidence, truncated or edited —
      // corrupted evidence, not absence — and reporting it as "no marker at
      // all" would license the memory fallback over a run that plainly
      // happened (cloud review round 1, confirmed P1).
      malformed.push({ ...entry, reason: parsed.malformed, trusted: isTrusted })
      continue
    }
    if (!isTrusted) {
      untrusted.push({ ...entry, run_id: parsed.runId })
      continue
    }
    if (parsed.destination !== expectedDestination) {
      malformed.push({
        ...entry,
        run_id: parsed.runId,
        trusted: true,
        reason: `marker destination ${parsed.destination} does not match ${where}`
      })
      continue
    }
    found.add(parsed.runId)
  }
  return found
}

function parseBodyDiscovery(body, repo) {
  const issueNumbers = new Set()
  const runTokens = new Map()
  const ignoredHints = []
  if (typeof body !== 'string') return { issueNumbers, runTokens, ignoredHints }

  // These are the non-closing reference forms the track-work contract emits.
  // The declaration must own the line (with an optional list marker), so prose,
  // quotations, and lazy blockquote continuations cannot become lookup inputs.
  // An explicit owner/repo prefix is accepted only for this repository.
  const declarationRe = /^[ \t]*(?:(?:[-*+]|[0-9]+[.)])[ \t]+)?(?:refs|addresses|part[ \t]+of)[ \t]+(?=(?:(?:https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/(?:issues|pull)\/)|(?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#)[1-9][0-9]*\b)[^\r\n]*$/gim
  const referenceRe = /(?<url>https:\/\/github\.com\/(?<urlRepo>[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/(?<urlKind>issues|pull)\/(?<urlNumber>[1-9][0-9]*)\b)|(?:(?<repo>[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#|#)(?<number>[1-9][0-9]*)\b/gi
  const declarationLines = []
  for (const declaration of body.matchAll(declarationRe)) {
    declarationLines.push(declaration[0])
    for (const match of declaration[0].matchAll(referenceRe)) {
      const hintRepo = match.groups.urlRepo || match.groups.repo
      const issueNumber = Number(match.groups.urlNumber || match.groups.number)
      const hint = match.groups.url || `${match.groups.repo || ''}#${match.groups.number}`
      if (hintRepo && hintRepo.toLowerCase() !== repo.toLowerCase()) {
        ignoredHints.push({
          hint,
          tier: 'non-closing reference',
          reason: `cross-repository reference does not belong to ${repo}`
        })
      } else if (match.groups.urlKind && match.groups.urlKind.toLowerCase() === 'pull') {
        ignoredHints.push({
          hint,
          tier: 'non-closing reference',
          reason: `#${issueNumber} is a pull request, not an issue`
        })
      } else {
        issueNumbers.add(issueNumber)
      }
    }
  }

  // A contributor-controlled body token is only a lookup hint. Its issue
  // number says where the trusted marker must live; the exact run id still
  // has to be named by that marker before this tier can select it.
  const runIdRe = /\brun-(?<number>[1-9][0-9]*)-(?<slug>[A-Za-z0-9._-]+)/g
  const policyRunLines = body.match(/^[ \t]*(?:[-*][ \t]+)?run(?:[ \t]+(?:id|identity))?[ \t]*:[^\r\n]*$/gim) || []
  for (const line of [...declarationLines, ...policyRunLines]) {
    for (const match of line.matchAll(runIdRe)) {
      const runId = match[0]
      runTokens.set(runId, Number(match.groups.number))
    }
  }
  return { issueNumbers, runTokens, ignoredHints }
}

function addIssueRuns(target, issueNumber, runIds) {
  for (const runId of runIds) {
    const seen = target.get(runId) || new Set()
    seen.add(issueNumber)
    target.set(runId, seen)
  }
}

function selectIssueTier(prNumber, tier, runs, sourceSuffix, context) {
  if (runs.size > 1) {
    throw new IndeterminateError(
      `${tier} for PR #${prNumber} carry trusted evidence for more than one run (${[...runs.keys()].sort().join(', ')}) — rerun with --run <run_id>`,
      context
    )
  }
  if (runs.size === 0) return null
  const [runId, seen] = [...runs.entries()][0]
  const where = [...seen].sort((a, b) => a - b).map((n) => `#${n}`).join(', ')
  return { runId, source: `evidence marker on issue ${where} (${sourceSuffix})` }
}

function fetchHintRunIds(args, issueNumber, tier, trustedActorIds, untrusted, malformed, ignoredHints) {
  try {
    const item = ghJson(['api', `repos/${args.repo}/issues/${issueNumber}`])
    if (item && item.pull_request) {
      ignoredHints.push({
        hint: `issue #${issueNumber}`,
        tier,
        reason: `#${issueNumber} is a pull request, not an issue`
      })
      return new Set()
    }
    return collectRunIds(
      fetchComments(args.repo, issueNumber, args.asOf || null),
      trustedActorIds,
      `issue #${issueNumber}`,
      'issue',
      untrusted,
      malformed
    )
  } catch (error) {
    if (!(error instanceof OperationalError)) throw error
    // Challenge round 2 restructures the round-1 catch-all to the invariant:
    // only a durable, unusable hint can be ignored. A transient failure leaves
    // discovery retry-dependent and therefore cannot be treated as absence.
    if (/\bHTTP (?:404|410)\b/i.test(error.message)) {
      ignoredHints.push({
        hint: `issue #${issueNumber}`,
        tier,
        reason: error.message
      })
      return new Set()
    }
    throw new IndeterminateError(
      `${tier} issue #${issueNumber} could not be read reliably (${error.message}); rerun after GitHub recovers or use --run <run_id>`,
      { ignoredHints, untrusted, malformed }
    )
  }
}

// Prefer the PR's own evidence comments over closing references, then body
// non-closing references, then an authenticated body run-id token. Lower tiers
// can contribute anomaly reporting, but never override a run selected above.
function discoverRun(args, trustedActorIds) {
  const asOf = args.asOf || null
  const untrusted = []
  const malformed = []
  const pr = ghJson([
    'pr',
    'view',
    String(args.pr),
    '--repo',
    args.repo,
    '--json',
    'number,url,title,state,isDraft,body,closingIssuesReferences'
  ])
  const fromPr = [...collectRunIds(fetchComments(args.repo, pr.number, asOf), trustedActorIds, `PR #${pr.number}`, 'pr', untrusted, malformed)].sort()
  if (fromPr.length > 1) {
    throw new IndeterminateError(
      `PR #${pr.number} carries trusted evidence for more than one run (${fromPr.join(', ')}) — rerun with --run <run_id>`,
      { untrusted, malformed }
    )
  }
  // NOT reconstructed by --as-of, and the report says so. The linked-issue
  // set comes from the PR's closing references and current body as they stand
  // NOW: GitHub does not version those inputs, so a re-link or body edit after
  // the cutoff changes which issues a historical read searches. Rather than
  // patch a fourth current-state
  // input into the cutoff (review round 4's P1, after r2's comment filter and
  // r3's cutoff validation), --as-of is restructured to the invariant it can
  // actually keep: it reconstructs the RUN RECORD and its comment evidence at
  // the cutoff, and every discovery input GitHub does not version is
  // current-state and disclosed as such in the output.
  const closingIssues = Array.isArray(pr.closingIssuesReferences) ? pr.closingIssuesReferences : []
  const closingNumbers = new Set(
    closingIssues.map((issue) => Number(issue && issue.number)).filter((number) => Number.isInteger(number) && number > 0)
  )
  const bodyDiscovery = parseBodyDiscovery(pr.body, args.repo)
  const ignoredHints = [...bodyDiscovery.ignoredHints]
  const nonClosingNumbers = new Set([...bodyDiscovery.issueNumbers].filter((number) => !closingNumbers.has(number)))
  // Which issues carried a given run id, not just which ids exist: a run whose
  // record sits on a different issue than the reader expects is worth naming
  // in the report's provenance line rather than reducing to "an issue".
  const closingRuns = new Map()
  for (const issueNumber of closingNumbers) {
    closingRuns.set(
      issueNumber,
      collectRunIds(fetchComments(args.repo, issueNumber, asOf), trustedActorIds, `issue #${issueNumber}`, 'issue', untrusted, malformed)
    )
  }
  // The PR's own run wins, but the linked issues are still SCANNED — the
  // early return that used to skip them meant a redirect attempt or a
  // corrupted marker sitting on the authoritative issue never reached the
  // integrity counts, while the skill promises every ignored marker is
  // reported (cloud review round 1, confirmed P2). Selection preference and
  // anomaly reporting are different jobs; only the first one short-circuits.
  if (fromPr.length === 1) {
    return {
      pr,
      runId: fromPr[0],
      source: `evidence marker on PR #${pr.number}`,
      untrusted,
      malformed,
      ignoredHints,
      unverifiedBodyRunIds: []
    }
  }

  const fromClosing = new Map()
  for (const issueNumber of closingNumbers) addIssueRuns(fromClosing, issueNumber, closingRuns.get(issueNumber))
  const closingSelection = selectIssueTier(pr.number, 'the closing references', fromClosing, 'closing reference', {
    ignoredHints,
    untrusted,
    malformed
  })
  if (closingSelection) {
    return { pr, ...closingSelection, untrusted, malformed, ignoredHints, unverifiedBodyRunIds: [] }
  }

  const hintIssueNumbers = new Set([...nonClosingNumbers, ...bodyDiscovery.runTokens.values()])
  if (hintIssueNumbers.size > 10) {
    throw new IndeterminateError(
      `PR #${pr.number} body carries ${hintIssueNumbers.size} unique non-closing/token issue hints; the discovery limit is 10 — rerun with --run <run_id>`,
      { ignoredHints, untrusted, malformed }
    )
  }

  const hintIssueRuns = new Map(closingRuns)
  const fromNonClosing = new Map()
  for (const issueNumber of nonClosingNumbers) {
    const runIds = fetchHintRunIds(
      args,
      issueNumber,
      'non-closing reference',
      trustedActorIds,
      untrusted,
      malformed,
      ignoredHints
    )
    hintIssueRuns.set(issueNumber, runIds)
    addIssueRuns(fromNonClosing, issueNumber, runIds)
  }
  const nonClosingSelection = selectIssueTier(
    pr.number,
    'the non-closing issue references',
    fromNonClosing,
    'non-closing reference',
    { ignoredHints, untrusted, malformed }
  )
  if (nonClosingSelection) {
    return { pr, ...nonClosingSelection, untrusted, malformed, ignoredHints, unverifiedBodyRunIds: [] }
  }

  const fromBodyTokens = new Map()
  for (const [runId, issueNumber] of bodyDiscovery.runTokens) {
    const runIds = hintIssueRuns.has(issueNumber)
      ? hintIssueRuns.get(issueNumber)
      : fetchHintRunIds(
          args,
          issueNumber,
          'PR-body run-id token',
          trustedActorIds,
          untrusted,
          malformed,
          ignoredHints
        )
    hintIssueRuns.set(issueNumber, runIds)
    if (runIds.has(runId)) addIssueRuns(fromBodyTokens, issueNumber, [runId])
  }
  const bodyTokenSelection = selectIssueTier(
    pr.number,
    'the authenticated PR-body run-id tokens',
    fromBodyTokens,
    'PR-body run-id token',
    { ignoredHints, untrusted, malformed }
  )
  if (bodyTokenSelection) {
    return { pr, ...bodyTokenSelection, untrusted, malformed, ignoredHints, unverifiedBodyRunIds: [] }
  }
  const mismatchedBodyTokens = [...bodyDiscovery.runTokens.entries()].flatMap(([runId, issueNumber]) => {
    const otherRuns = [...(hintIssueRuns.get(issueNumber) || [])].filter((candidate) => candidate !== runId).sort()
    return otherRuns.length === 0 ? [] : [`${runId} vs ${otherRuns.join(', ')} on issue #${issueNumber}`]
  })
  if (mismatchedBodyTokens.length > 0) {
    throw new IndeterminateError(
      `PR #${pr.number} carries body run-id token(s) that do not match the trusted evidence on their named issues (${mismatchedBodyTokens.join('; ')}) — rerun with --run <run_id>`,
      { ignoredHints, untrusted, malformed }
    )
  }
  return {
    pr,
    runId: null,
    source: null,
    untrusted,
    malformed,
    ignoredHints,
    unverifiedBodyRunIds: [...bodyDiscovery.runTokens.keys()].sort()
  }
}

// Ordinary discovery and the local guard share the same refusal and diagnostics.
function requireDeterminateDiscovery(args, trusted, discovered) {
  if (discovered.runId) return
  const corrupted = discovered.malformed.filter((m) => m.trusted)
  if (discovered.untrusted.length > 0 || corrupted.length > 0) {
    const parts = []
    if (discovered.untrusted.length > 0) {
      const runs = [...new Set(discovered.untrusted.map((m) => m.run_id))].sort().map((id) => JSON.stringify(id)).join(', ')
      parts.push(
        `${discovered.untrusted.length} evidence marker(s) naming ${runs} whose authors are not trusted (${trusted.source}) — either a redirect attempt or a trust root that changed after the run, since discovery uses the selected set and an orchestrator removed from the allowlist since a run reads as indeterminate (fail closed)`
      )
    }
    if (corrupted.length > 0) {
      parts.push(
        `${corrupted.length} marker(s) from a TRUSTED actor that do not parse (${[...new Set(corrupted.map((m) => m.reason))].join('; ')}) — a trusted orchestrator's own evidence, truncated or edited, which is corrupted evidence rather than absence`
      )
    }
    throw new IndeterminateError(
      `PR #${args.pr} and its linked issues carry ${parts.join('; and ')}. Rerun naming the run's own orchestrator with --trusted-actor-id, or with --run <run_id> — do NOT conclude the session has no run record.`,
      { untrusted: discovered.untrusted, malformed: discovered.malformed, ignoredHints: discovered.ignoredHints }
    )
  }
}

// ---------------------------------------------------------------------------
// Trusted actor ids
// ---------------------------------------------------------------------------

// Authority comes only from configured orchestrator IDs, never the authenticated
// reader. Default discovery uses the target repository's default-branch registry,
// never the caller's checkout. Explicit flags override the selected set passed
// to the harvester; its evidence-format-specific trust rule is reported below.
function resolveTrustedActorArgs(args) {
  const passthrough = []
  const ids = new Set()
  let registrySource = null
  if (args.trustedActorIds.length === 0 && !args.trustedActorsFile) {
    let doc
    try {
      const metadata = ghJson(['api', `repos/${args.repo}`])
      const branch = metadata?.default_branch
      if (typeof branch !== 'string' || branch.trim().length === 0) {
        throw new Error('repository metadata has no default_branch')
      }
      const file = ghJson(['api', `repos/${args.repo}/contents/agent-registry.json?ref=${encodeURIComponent(branch)}`])
      if (file?.type !== 'file' || file.encoding !== 'base64' || typeof file.content !== 'string' ||
          typeof file.sha !== 'string' || !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(file.sha)) {
        throw new Error('registry Contents response must contain a base64 file and blob SHA')
      }
      doc = JSON.parse(Buffer.from(file.content, 'base64').toString('utf8'))
      registrySource = `${args.repo}@${branch} (${file.sha})`
    } catch (error) {
      throw new UsageError(`could not read/parse ${args.repo}'s default-branch agent-registry.json: ${error.message}`)
    }
    const configured = doc?.trusted_orchestrator_actor_ids
    if (!Array.isArray(configured) || configured.length === 0) {
      throw new UsageError('agent-registry.json must contain a nonempty trusted_orchestrator_actor_ids array; there is no authenticated-caller default')
    }
    for (const id of configured) {
      if (!Number.isSafeInteger(id) || id < 1) {
        throw new UsageError(`agent-registry.json trusted_orchestrator_actor_ids entries must be positive safe JSON integers, got ${JSON.stringify(id)}`)
      }
      if (ids.has(id)) {
        throw new UsageError(`agent-registry.json trusted_orchestrator_actor_ids must contain unique entries, got duplicate ${id}`)
      }
      if (Array.isArray(doc.finders) && doc.finders.some((finder) => finder?.trusted_actor_id === String(id))) {
        throw new UsageError(`agent-registry.json trusted_orchestrator_actor_ids includes finder actor ${id}; finder identities cannot authenticate orchestrator evidence`)
      }
      ids.add(id)
      passthrough.push('--trusted-actor-id', String(id))
    }
  }
  for (const id of args.trustedActorIds) {
    const n = Number(id)
    if (!Number.isInteger(n) || n < 1) {
      throw new UsageError(`--trusted-actor-id must be a positive integer, got ${JSON.stringify(id)}`)
    }
    ids.add(n)
    passthrough.push('--trusted-actor-id', id)
  }
  if (args.trustedActorsFile) {
    let doc
    try {
      doc = JSON.parse(readFileSync(args.trustedActorsFile, 'utf8'))
    } catch (error) {
      throw new UsageError(`could not read/parse --trusted-actors-file: ${error.message}`)
    }
    if (!Array.isArray(doc?.trusted_actor_ids)) {
      throw new UsageError('--trusted-actors-file must contain {"trusted_actor_ids": [...]}')
    }
    // Parsed here as well as passed through, because discovery gates on the
    // same set the harvester will use. Reading it twice is the price of not
    // having two different notions of "trusted" one step apart — and that is
    // exactly why FILE entries are type-checked rather than coerced. An
    // earlier revision ran Number() over them, so `[true]` became trusted
    // actor 1 and `["555"]` was accepted, while dev-flow-stats.mjs (on `main`
    // since #751) reads doc.trusted_actor_ids WITHOUT .map(Number) and
    // rejects both — scripts/test-retro-run-report.sh section 5 asserts that
    // agreement against the real script rather than restating it. Coercing
    // here therefore produced two different trust sets from one file — the
    // divergence this comment claims not to have (review round 4, confirmed
    // P2). Command-line ids stay coerced: argv is always a string, and the
    // harvester's own fromFlags maps Number over them too.
    for (const id of doc.trusted_actor_ids) {
      if (typeof id !== 'number' || !Number.isInteger(id) || id < 1) {
        throw new UsageError(
          `--trusted-actors-file entries must be JSON integers, got ${JSON.stringify(id)} — the harvester type-checks them without coercion, so a coerced value here would build a trust set it will reject`
        )
      }
      ids.add(id)
    }
    passthrough.push('--trusted-actors-file', args.trustedActorsFile)
  }
  if (ids.size === 0) {
    throw new UsageError(
      'at least one --trusted-actor-id or --trusted-actors-file entry is required when overriding agent-registry.json — there is no authenticated-caller default'
    )
  }
  // Name the ids, not just their provenance. "Supplied on the command line"
  // cannot be reproduced or audited from a pasted retro, and it is exactly
  // what a reader needs in order to tell a misconfigured allowlist from a
  // hostile marker when the ignored-marker count is nonzero (review round 3,
  // confirmed P2).
  const listed = [...ids].sort((a, b) => a - b).join(', ')
  const from = registrySource
    ? ` from ${registrySource} agent-registry.json trusted_orchestrator_actor_ids`
    : ` from explicit flags${args.trustedActorsFile ? ` (including ${args.trustedActorsFile})` : ''}`
  return { passthrough, ids, source: `actor id(s) ${listed}${from}` }
}

// ---------------------------------------------------------------------------
// Harvest
// ---------------------------------------------------------------------------

function harvestTrajectory(stats, args, runId, trusted) {
  const argv = [...stats.prefix, '--repo', args.repo, '--run', runId, '--json', ...trusted.passthrough]
  if (args.asOf) argv.push('--as-of', args.asOf)
  if (args.recordDir) argv.push('--record-dir', args.recordDir)
  // Integration Codex cycle 1 (P2), confirmed and fixed: this spawn passed
  // neither --repo-root nor a cwd override, so the harvester's own default
  // resolution ran instead — even though resolveStatsCommand (above) has
  // already found the actual repository top level to locate this script in
  // the first place. Pass that same resolved root through explicitly rather
  // than letting the harvester re-derive (or fail to derive) it.
  const root = repoRoot()
  if (root) argv.push('--repo-root', root)
  const result = spawnSync(stats.command, argv, {
    encoding: 'utf8',
    maxBuffer: MAX_SYNC_BUFFER_BYTES
  })
  if (result.error) {
    throw new OperationalError(`${stats.display} failed to execute: ${result.error.message}`)
  }
  const stderr = (result.stderr || '').trim()
  if (result.status === 1) {
    let structuredStatus = null
    try {
      structuredStatus = JSON.parse(result.stdout || 'null')?.status || null
    } catch {
      // A crash can also exit 1. Only a structured status licenses fallback;
      // stderr echoes arbitrary run ids and cannot prove absence.
    }
    if (structuredStatus === 'record-missing' || structuredStatus === 'run-not-found') {
      return { missingKind: structuredStatus, missing: `${structuredStatus} — ${stderr || `the harvester does not know run ${runId}`}` }
    }
  }
  if (result.status === 3) {
    throw new IndeterminateError(stderr || `the harvester reports run ${runId} indeterminate`)
  }
  if (result.status !== 0) {
    throw new OperationalError(`${stats.display} exited ${result.status}: ${stderr}`)
  }
  try {
    return { trajectory: JSON.parse(result.stdout) }
  } catch (error) {
    throw new OperationalError(`${stats.display} returned malformed JSON: ${error.message}`)
  }
}

// ---------------------------------------------------------------------------
// Resolved-policy disclosure, read back off the PR body
// ---------------------------------------------------------------------------

// Where the caps come from, and what that is worth. Reading the live
// .devflow.toml would be worse than useless — the config is edited between
// runs, so an old run would be silently rescored against a budget it never
// had. So this parses the section render-dev-flow.mjs published into the PR
// body instead, and reports the caps unknown rather than substituting a guess.
//
// But the PR body is MUTABLE and sits outside the authenticated evidence
// chain: anyone with write access can edit it, the renderer itself
// republishes it, and --as-of does not reconstruct it — a cutoff read still
// sees today's text. So these values are a DISCLOSURE, never a measurement,
// and every surface that shows them says so (challenge round 1, confirmed
// P1). They are still worth reporting: an unverified cap that is labelled is
// more use to a retro than no denominator at all, and the fix for the doubt
// is to check the caps against the run's own round evidence, which the report
// puts on the same page.
const POLICY_BEGIN = '<!-- dev-flow:begin:policy-disclosure -->'
const POLICY_END = '<!-- dev-flow:end:policy-disclosure -->'
// harmon-init#1341: the exempt-cycle ceiling renders as an optional
// ` (+N exempt)` immediately after the charged integration cap. It has to be
// OPTIONAL in this pattern, not merely added: a retro routinely reads PRs
// opened before the ceiling existed, or by a repo whose harmon-init pin
// predates it, and a required group would turn every one of those into
// "does not open with a parseable rigor line" — silently dropping the caps
// the report exists to show. Group 6 is the exempt count when present.
const POLICY_LINE_RE =
  /^rigor:\s*`([^`]*)`\s*\(`([^`]*)`\)\s*→\s*challenge ≤(\d+), review ≤(\d+), integration (\d+)(?: \(\+(\d+) exempt\))?, remediation (\d+), min_rounds (\d+)\s*$/

function readPolicyDisclosure(body) {
  if (typeof body !== 'string' || !body.includes(POLICY_BEGIN)) {
    return { present: false, verified: false, reason: 'the PR body carries no dev-flow policy-disclosure section' }
  }
  // render-dev-flow.mjs refuses to publish a duplicated marker pair, so two of
  // them mean the body was hand-edited: which one governs is genuinely
  // unknowable, and picking the first would report a cap nobody chose.
  if (body.indexOf(POLICY_BEGIN) !== body.lastIndexOf(POLICY_BEGIN)) {
    return { present: false, verified: false, reason: 'the PR body carries more than one policy-disclosure section' }
  }
  const start = body.indexOf(POLICY_BEGIN) + POLICY_BEGIN.length
  const end = body.indexOf(POLICY_END, start)
  if (end === -1) {
    return { present: false, verified: false, reason: 'the PR body policy-disclosure section is not closed by its end marker' }
  }
  const lines = body
    .slice(start, end)
    .replace(/\r/g, '')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
  const match = lines.length > 0 ? POLICY_LINE_RE.exec(lines[0]) : null
  if (!match) {
    return {
      present: false,
      verified: false,
      reason: 'the PR body policy-disclosure section does not open with a parseable rigor line'
    }
  }
  return {
    present: true,
    // Never true: nothing in this family authenticates a PR body. Carried as
    // an explicit field so a JSON consumer cannot mistake a disclosure for a
    // measurement by omission.
    verified: false,
    source: 'the PR body\'s policy-disclosure section as it stands now (mutable, unauthenticated, not reconstructed by --as-of)',
    rigor: { level: match[1], source: match[2] },
    rounds: {
      challenge: Number(match[3]),
      review: Number(match[4]),
      integration: Number(match[5]),
      // Absent group => the disclosure named no exempt ceiling, which is not
      // the same as a ceiling of 0: undefined means "this run had no exempt
      // budget concept at all", and a consumer must not render it as "+0".
      ...(match[6] === undefined ? {} : { integration_exempt: Number(match[6]) }),
      remediation: Number(match[7]),
      min_rounds: Number(match[8])
    },
    disclosures: lines.slice(1).filter((line) => line.startsWith('- ')).map((line) => line.slice(2))
  }
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

const FINDING_ID_RE = /^(challenge|review|integration)-r([1-9][0-9]*)-([a-z0-9-]+)-([1-9][0-9]*)$/

function stageAt(transitions, at) {
  const when = Date.parse(at)
  if (!Number.isFinite(when)) return null
  let current = null
  for (const transition of transitions) {
    const entered = Date.parse(transition.entered_at)
    if (Number.isFinite(entered) && entered <= when) current = transition.stage
  }
  return current
}

function classProvenanceRows(counts) {
  return Object.entries(counts || {})
    .map(([key, count]) => {
      const slash = key.indexOf('/')
      return slash === -1
        ? { class: key, provenance: 'unspecified', count }
        : { class: key.slice(0, slash), provenance: key.slice(slash + 1), count }
    })
    .sort((a, b) => b.count - a.count || a.class.localeCompare(b.class) || a.provenance.localeCompare(b.provenance))
}

function measure(trajectory, policy) {
  const transitions = Array.isArray(trajectory.stage_transitions) ? trajectory.stage_transitions : []
  const rounds = Array.isArray(trajectory.rounds) ? trajectory.rounds : []
  const slotFailures = Array.isArray(trajectory.slot_failures) ? trajectory.slot_failures : []
  const slotFailuresUnavailable = trajectory.slot_failures_unavailable === true
  const provenanceUnavailableRounds = Array.isArray(trajectory.provenance_unavailable_rounds)
    ? trajectory.provenance_unavailable_rounds
    : []
  const futureAdjudicationFiles = Array.isArray(trajectory.future_adjudication_files)
    ? trajectory.future_adjudication_files
    : []
  const interventions = Array.isArray(trajectory.interventions) ? trajectory.interventions : []
  const settlements = Array.isArray(trajectory.settlements) ? trajectory.settlements : []

  // Stage order is chronological by first entry, so a remediation loop (a
  // stage entered again later) keeps one section holding all of its rounds
  // rather than splitting into two that each look under-reviewed.
  const order = []
  const push = (stage) => {
    if (stage && !order.includes(stage)) order.push(stage)
  }
  for (const transition of transitions) push(transition.stage)
  for (const round of rounds) push(round.stage)
  if (policy.present) for (const stage of ['challenge', 'review', 'integration']) push(stage)

  const stages = order.map((stage) => {
    const own = rounds.filter((round) => round.stage === stage)
    const cap = policy.present && policy.rounds[stage] !== undefined ? policy.rounds[stage] : null
    const entries = transitions
      .filter((transition) => transition.stage === stage)
      .map((transition) => ({ entered_at: transition.entered_at, exit: transition.exit ?? null }))
    const stageInterventions = interventions
      .filter((entry) => stageAt(transitions, entry.at) === stage)
      .map((entry) => ({ at: entry.at, kind: entry.kind, note: entry.note }))
    // Unlike challenge/review, the review skill posts no evidence marker for
    // integration passes, so local evidence can never authenticate a round,
    // pass, or finding count here. Disclose that plainly instead of a count
    // that — since `rounds` never carries an "integration" entry — would
    // always read as a misleading zero (harmon-devkit#962 maintainer
    // extension: never a count, never zero).
    if (stage === 'integration') {
      // harmon-init#1341, challenge round 1 P1 (confirmed): the parser reads
      // the exempt ceiling, so the report must carry it. `cap` alone answers
      // "how many cycles were allowed?" with only the charged half, and for
      // the integration stage that is the number a reader uses to judge
      // whether a run overspent. Omitted when the disclosure named none, which
      // is not the same as a ceiling of 0 — see the parser's own note.
      const exemptCap = policy.present ? policy.rounds.integration_exempt : undefined
      return {
        stage,
        entries,
        cap,
        ...(exemptCap === undefined ? {} : { exempt_cap: exemptCap }),
        integration_evidence: trajectory.integration_evidence || 'unavailable',
        interventions: stageInterventions
      }
    }
    return {
      stage,
      entries,
      rounds_spent: own.length,
      cap,
      findings: own.reduce((total, round) => total + (round.finding_count || 0), 0),
      passes: own.reduce((total, round) => total + (round.pass_count || 0), 0),
      blocked_passes: own.reduce((total, round) => total + (round.blocked_passes || 0), 0),
      adjudications: own.reduce(
        (total, round) => total + (round.adjudication_count ?? (round.has_adjudication ? 1 : 0)),
        0
      ),
      round_evidence_counts: own.map((round) => ({
        round: round.round,
        passes: round.pass_count || 0,
        blocked_passes: round.blocked_passes || 0,
        adjudications: round.adjudication_count ?? (round.has_adjudication ? 1 : 0)
      })),
      rounds_without_adjudication: own
        .filter((round) => (round.adjudication_count ?? (round.has_adjudication ? 1 : 0)) === 0)
        .map((round) => round.round),
      slot_failures: slotFailures.filter((failure) => failure && failure.stage === stage),
      slot_failures_unavailable: slotFailuresUnavailable,
      provenance_unavailable_rounds: provenanceUnavailableRounds
        .filter((entry) => entry && entry.stage === stage)
        .map((entry) => entry.round),
      future_adjudication_files: futureAdjudicationFiles.filter((file) =>
        typeof file === 'string' && file.startsWith(`${stage}-r`)
      ),
      interventions: stageInterventions
    }
  })

  const classProvenance = classProvenanceRows(trajectory.findings_by_class_and_provenance)
  const stageCounts = trajectory.findings_by_stage_class_and_provenance
  for (const stage of stages) {
    stage.findings_by_class_and_provenance = stageCounts?.[stage.stage] === undefined
      ? null
      : classProvenanceRows(stageCounts[stage.stage])
  }

  // Older harvesters expose only the run-wide aggregate. Keep their
  // single-stage attribution and multi-stage gap when no stage map exists.
  const stagesWithFindings = [...new Set(stages.filter((st) => st.findings > 0).map((st) => st.stage))]
  const attribution =
    provenanceUnavailableRounds.length > 0
      ? { scope: classProvenance.length > 0 ? 'partial' : 'unavailable', stage: null }
      : classProvenance.length === 0
      ? { scope: 'none', stage: null }
      : stagesWithFindings.length === 1
        ? { scope: 'stage', stage: stagesWithFindings[0] }
        : { scope: 'run', stage: null }

  return {
    stages,
    class_provenance_attribution: attribution,
    findings_by_class_and_provenance: classProvenance,
    interventions: interventions.map((entry) => ({
      at: entry.at,
      kind: entry.kind,
      stage: stageAt(transitions, entry.at),
      note: entry.note
    })),
    settlements: settlements.map((entry) => {
      const parts = FINDING_ID_RE.exec(entry.finding_id)
      return {
        finding_id: entry.finding_id,
        stage: parts ? parts[1] : null,
        round: parts ? Number(parts[2]) : null,
        finder: parts ? parts[3] : null,
        disposition: entry.disposition,
        settled_at: entry.settled_at,
        reference: entry.reference || null
      }
    }),
    integrity: {
      orphan_comments: (trajectory.orphan_comments || []).length,
      forged_comments: (trajectory.forged_comments || []).length,
      // Local-record path only (harmon-devkit#1001 item 7): a trusted
      // actor's marker naming the wrong destination or a stage never
      // visited — a structural anomaly, not a forged-author claim. Absent
      // from the GitHub-comment harvest path, which never tags one; the
      // `|| []` default keeps this measurement 0 there, not missing.
      tampered_comments: (trajectory.tampered_comments || []).length
    }
  }
}

// Measurements the retro is asked for that today's evidence surface cannot
// supply. Named here, with the issue that would close each, rather than
// silently omitted — an absent section reads as "nothing to report".
function unavailableMeasurements(measured) {
  const gaps = []
  // Only a gap when it actually remains one. Where exactly one stage found
  // anything the breakdown IS rendered per stage, and declaring it missing
  // anyway would manufacture a follow-up for a measurement the report just
  // made — the skill carries every listed gap into improvements (cloud review
  // round 1, confirmed P2).
  if (measured.class_provenance_attribution.scope === 'run' &&
      measured.stages.some((stage) => stage.findings > 0 && stage.findings_by_class_and_provenance === null)) {
    gaps.push({
      measurement: 'findings by class and provenance, keyed by stage',
      reason:
        "the run trajectory's findings_by_class_and_provenance aggregates over the whole run, and more than one stage found something here, so no per-stage split is derivable",
      issue: 'harmon-devkit#779'
    })
  }
  gaps.push(
    {
      measurement: 'remediation rounds spent against the remediation cap',
      reason:
        'remediation is budgeted independently of integration, but it is not a stage in run.schema.json\'s stage enum and the run trajectory exposes no remediation count, so the remediation cap shown in the policy line above is disclosed and unmeasured — an integration run cannot be shown to have exhausted it',
      issue: 'harmon-devkit#663 successors'
    },
    {
      measurement: 'adjudicated-priority overrides per finding',
      reason:
        'the run trajectory reduces each round\'s adjudication documents to a count, dropping reviewer_priority, adjudicated_priority and override',
      issue: 'harmon-devkit#753'
    }
  )
  if (measured.settlements.every((entry) => entry.finder === null)) {
    gaps.push({
      measurement: 'findings by finder slug (agent-registry.json finders[].slug)',
      reason:
        "finder slugs reach this projection only through settled deferred findings' ids, and none of this run's settlements carries one",
      issue: 'harmon-devkit#753'
    })
  }
  return gaps
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Preserve verified text while neutralizing marker boundaries and folding
// all line terminators. HTML escaping belongs to the local renderer only.
function safe(value) {
  return String(value ?? '')
    .replace(/<!--/g, '&lt;!--')
    .replace(/-->/g, '--&gt;')
    .replace(/\r\n|[\r\n\u2028\u2029\u0085\u000b\u000c]/g, ' ')
}

function cell(value) {
  return safe(value).replace(/\|/g, '\\|')
}

function renderMarkdown(report) {
  const l = []
  const t = report.trajectory
  l.push(`## Run evidence — run \`${safe(report.run_id)}\``)
  l.push('')
  l.push(`- Issue: #${t.issue ?? '—'} · PR: ${t.pr ? `#${t.pr.number}` : '—'}`)
  l.push(`- Initiated by: \`${safe(t.initiated_by)}\` at ${safe(t.started_at)}`)
  l.push(`- Outcome: \`${safe(t.outcome ?? 'in-flight')}\``)
  l.push(
    `- Promotion: ${t.promotion ? `${safe(t.promotion.promoted_at)} at head ${safe(t.promotion.head).slice(0, 7)}` : 'none recorded'}`
  )
  l.push(`- Evidence source: \`${safe(report.source.harvester)}\`, run id from ${safe(report.source.run_id_from)}`)
  l.push(`- Trust root: ${safe(report.source.trusted_actors)}`)
  if (report.source.pr_binding) l.push(`- PR binding: ${safe(report.source.pr_binding)}`)
  if (report.as_of) {
    l.push(`- Reconstructed as of: ${safe(report.as_of)} — **the run record and its comment evidence only.**`)
    l.push(
      '  These inputs are **not** reconstructed and are read as they stand now: the **linked-issue set** (the PR\'s closing references plus same-repository non-closing references and run-id issue numbers parsed from its body, which decide which issues a fallback search reaches), the **PR body** the disclosed caps above come from, and the **default trust set** (the target repository\'s default-branch-head registry, when no explicit trust flags are supplied). A replay with --as-of trusts the default allowlist as it is now, while the harvester still applies write-time registry revisions to legacy evidence. Re-linking an issue, editing the body, or changing that allowlist changes those inputs even for a fixed cutoff.'
    )
  }
  l.push('')

  l.push('### Policy the PR discloses (unverified)')
  l.push('')
  if (report.policy.present) {
    const r = report.policy.rounds
    // harmon-init#1341, Codex cloud cycle 3 P2: this is the line a reader takes
    // as the run's budget, so it must carry the exempt ceiling too — otherwise
    // every new-format retro opens with an incomplete summary and only reveals
    // the extra allowance further down.
    const exemptSuffix =
      r.integration_exempt === undefined ? '' : ` (+${r.integration_exempt} exempt)`
    l.push(
      `rigor: \`${safe(report.policy.rigor.level)}\` (\`${safe(report.policy.rigor.source)}\`) → challenge ≤${r.challenge}, review ≤${r.review}, integration ${r.integration}${exemptSuffix}, remediation ${r.remediation}, min_rounds ${r.min_rounds}`
    )
    l.push('')
    l.push(
      '**Unverified.** Read from ' +
        safe(report.policy.source) +
        '. The PR body is outside the authenticated evidence chain — a later edit or republication changes it, and `--as-of` does not reconstruct it — so treat these caps as a claim to check against the rounds below, never as a measurement. They are not read from the current `.devflow.toml` either: that would rescore this run against a budget it may never have had.'
    )
  } else {
    l.push(`Caps unknown — ${safe(report.policy.reason)}. Rounds below are reported without a denominator.`)
  }
  l.push('')

  for (const stage of report.measurements.stages) {
    l.push(`### Stage \`${safe(stage.stage)}\``)
    l.push('')
    // The round lines are the point of a confidence stage's section and pure
    // noise on a stage that has neither a cap nor a round — `plan` reporting
    // "0 rounds, 0 findings" three times over buries the transition and
    // intervention lines that are the only thing it actually measures.
    // Integration is different: it carries no evidence marker at all, so
    // local evidence can never authenticate a round/pass/finding count for
    // it — disclose that instead of a count that would always read as zero.
    if (stage.stage === 'integration') {
      // harmon-init#1341: the charged cap alone understates what the run was
      // allowed to spend once base-merge-only cycles have a ceiling of their
      // own, and this line is where a reader judges whether a run overspent.
      const exemptSuffix = stage.exempt_cap === undefined ? '' : ` + ${stage.exempt_cap} exempt`
      const cap =
        stage.cap === null
          ? 'no cap recorded'
          : `cap ${stage.cap}${exemptSuffix} (disclosed, unverified)`
      l.push(`- Rounds/passes/findings: not measured from local evidence (${cap}) — integration passes carry no authenticated evidence marker today.`)
    } else if (stage.cap !== null || stage.rounds_spent > 0) {
      const cap = stage.cap === null ? 'no cap recorded' : `cap ${stage.cap} (disclosed, unverified)`
      l.push(`- Rounds spent: ${stage.rounds_spent} / ${cap}`)
      l.push(`- Findings: ${stage.findings} across ${stage.passes} pass(es)`)
      for (const evidence of stage.round_evidence_counts) {
        l.push(`- Round ${evidence.round} evidence: ${evidence.passes} pass(es), ${evidence.blocked_passes} blocked pass(es), ${evidence.adjudications} adjudication(s)`)
      }
      l.push(
        `- Rounds with no adjudication record: ${stage.rounds_without_adjudication.length === 0 ? 'none' : stage.rounds_without_adjudication.join(', ')}`
      )
      if (stage.slot_failures.length > 0) {
        l.push(`- Slot failures (retained verbatim): \`${safe(JSON.stringify(stage.slot_failures))}\``)
      }
      if (stage.slot_failures_unavailable) l.push('- Slot failures: unavailable under --as-of')
      if (stage.future_adjudication_files.length > 0) {
        l.push(`- Future adjudications excluded by --as-of: ${stage.future_adjudication_files.map((file) => `\`${safe(file)}\``).join(', ')}`)
      }
      if (stage.provenance_unavailable_rounds.length > 0) {
        l.push(`- Verified provenance/fingerprint unavailable for round(s): ${stage.provenance_unavailable_rounds.join(', ')}`)
      }
    }
    if (stage.entries.length === 0) {
      l.push('- Entered: never (the run recorded no transition into this stage)')
    } else {
      for (const entry of stage.entries) {
        l.push(`- Entered ${safe(entry.entered_at)} — exit: ${entry.exit ? safe(entry.exit) : 'still open'}`)
      }
    }
    l.push(
      `- Interventions during this stage: ${
        stage.interventions.length === 0
          ? 'none'
          : stage.interventions.map((entry) => `${safe(entry.kind)} at ${safe(entry.at)} (${safe(entry.note)})`).join('; ')
      }`
    )
    const attribution = report.measurements.class_provenance_attribution
    if (stage.findings > 0) {
      if (stage.findings_by_class_and_provenance !== null) {
        if (stage.provenance_unavailable_rounds.length > 0) {
          l.push(
            `- Findings by class and provenance: unavailable for round(s) ${stage.provenance_unavailable_rounds.join(', ')} — no matching verified \`verdict.json\` projection exists; raw producer assertions are not substituted.`
          )
        }
        if (stage.findings_by_class_and_provenance.length > 0) {
          l.push(stage.provenance_unavailable_rounds.length > 0
            ? '- Findings by class and provenance (partial verified projection):'
            : '- Findings by class and provenance:')
          for (const row of stage.findings_by_class_and_provenance) {
            l.push(`  - ${cell(row.class)} / ${cell(row.provenance)}: ${row.count}`)
          }
        } else if (stage.provenance_unavailable_rounds.length === 0) {
          l.push('- Findings by class and provenance: no verified findings recorded for this stage.')
        }
      } else if (stage.provenance_unavailable_rounds.length > 0) {
        l.push(
          `- Findings by class and provenance: unavailable for round(s) ${stage.provenance_unavailable_rounds.join(', ')} — no matching verified \`verdict.json\` projection exists; raw producer assertions are not substituted.`
        )
      } else if (attribution.scope === 'stage' && attribution.stage === stage.stage) {
        l.push('- Findings by class and provenance:')
        for (const row of report.measurements.findings_by_class_and_provenance) {
          l.push(`  - ${cell(row.class)} / ${cell(row.provenance)}: ${row.count}`)
        }
        l.push('  (this run\'s whole class/provenance aggregate, and this is its only stage with findings)')
      } else {
        l.push(
          '- Findings by class and provenance: not derivable per stage — the trajectory aggregates them across every stage that found something (harmon-devkit#779). See the run-wide table below.'
        )
      }
      l.push(
        '- Adjudication overrides: not derivable — the trajectory reduces each round\'s adjudication to a boolean (harmon-devkit#753).'
      )
    }
    l.push('')
  }

  l.push('### Findings by class and provenance')
  l.push('')
  if (report.measurements.class_provenance_attribution.scope === 'unavailable') {
    l.push('Unavailable: no affected round has a matching verified `verdict.json` projection; raw producer assertions are not reported as verified provenance.')
  } else if (report.measurements.class_provenance_attribution.scope === 'partial') {
    l.push('Partial verified projection only: rounds named unavailable above are excluded rather than counted from raw producer assertions.')
    l.push('')
  } else if (report.measurements.findings_by_class_and_provenance.length === 0) {
    l.push('No findings recorded for this run.')
  } else if (report.measurements.class_provenance_attribution.scope === 'stage') {
    l.push(
      `Every finding in this run belongs to stage \`${safe(report.measurements.class_provenance_attribution.stage)}\`, so the table below is also that stage's — see its section above.`
    )
    l.push('')
  }
  if (report.measurements.findings_by_class_and_provenance.length > 0) {
    l.push('| class | provenance | count |')
    l.push('| --- | --- | --- |')
    for (const row of report.measurements.findings_by_class_and_provenance) {
      l.push(`| ${cell(row.class)} | ${cell(row.provenance)} | ${row.count} |`)
    }
    l.push('')
    l.push('`provenance` is the finding\'s own field: `original` (about the change) or `round:N` (about round N\'s fix of the same stage). A run whose later rounds are mostly `round:N` is a stage feeding on its own fixes.')
  }
  l.push('')

  // Titled for what it actually covers. "Overrides" alone implied it also
  // covered reviewer-to-orchestrator PRIORITY overrides, so an empty section
  // read as "the orchestrator overrode nothing" when nothing had looked
  // (review round 1, confirmed P1). The gap is stated here, where a reader
  // looking for overrides will be, not only in the gap list at the end.
  l.push('### Policy overrides the PR discloses (unverified)')
  l.push('')
  const disclosures = report.policy.present ? report.policy.disclosures : []
  if (disclosures.length === 0) {
    l.push(
      report.policy.present
        ? 'No cap, waiver, tier, or strategy disclosure was published for this run.'
        : 'Unknown — the PR body published no policy-disclosure section to read them from.'
    )
  } else {
    for (const disclosure of disclosures) l.push(`- ${safe(disclosure)}`)
    l.push('')
    l.push('Same caveat as the policy line above: these come from the mutable PR body, not from authenticated run evidence.')
  }
  l.push('')
  l.push(
    '**Adjudication overrides are not covered here.** A finding whose adjudicated priority differs from the reviewer\'s is recorded in that round\'s adjudication document, and the run trajectory reduces each round\'s adjudication to a single boolean (harmon-devkit#753). An empty section above therefore means "no policy disclosure was published", never "the orchestrator overrode nothing".'
  )
  l.push('')

  l.push('### Interventions')
  l.push('')
  if (report.measurements.interventions.length === 0) {
    // Only a TERMINAL run can be said to have reached anything unattended;
    // an in-flight or blocked run has simply not needed a human YET, and
    // saying otherwise contradicts the outcome line above it (review round 2,
    // confirmed P2).
    l.push(
      report.trajectory.outcome
        ? 'None — the run reached its outcome unattended.'
        : 'None recorded so far. The run has no terminal outcome yet, so this is not yet an unattended run — only one that has not needed a human up to this point.'
    )
  } else {
    l.push('| at | kind | stage | note |')
    l.push('| --- | --- | --- | --- |')
    for (const entry of report.measurements.interventions) {
      l.push(`| ${cell(entry.at)} | ${cell(entry.kind)} | ${cell(entry.stage ?? '—')} | ${cell(entry.note)} |`)
    }
  }
  l.push('')

  l.push('### Deferred findings settled')
  l.push('')
  if (report.measurements.settlements.length === 0) {
    l.push('None.')
  } else {
    l.push('| finding | stage | round | finder | disposition | reference |')
    l.push('| --- | --- | --- | --- | --- | --- |')
    for (const entry of report.measurements.settlements) {
      const reference = entry.reference ? `${entry.reference.type} ${entry.reference.value}` : '—'
      l.push(
        `| \`${cell(entry.finding_id)}\` | ${cell(entry.stage ?? '—')} | ${entry.round ?? '—'} | ${cell(entry.finder ?? '—')} | ${cell(entry.disposition)} | ${cell(reference)} |`
      )
    }
  }
  l.push('')

  l.push('### Evidence integrity')
  l.push('')
  l.push(`- Trusted-but-unlisted comments: ${report.measurements.integrity.orphan_comments}`)
  l.push(`- Forged-author comments: ${report.measurements.integrity.forged_comments}`)
  if (report.measurements.integrity.tampered_comments > 0) {
    l.push(`- Tampered comments (trusted author, structural anomaly, not forged): ${report.measurements.integrity.tampered_comments}`)
  }
  l.push(
    `- Trust evaluation: ${safe(report.source.trusted_actors)}. This trusted set is passed to the harvester. Current-format evidence authenticates against exactly that set. Legacy evidence is additionally intersected with the registry revision in effect when it was written. An explicit flag set is trusted as given and can widen what is authenticated, so pass it only deliberately. Under the default registry trust set, an orchestrator removed from the allowlist since a run reads as indeterminate (fail closed).`
  )
  if (report.source.ignored_markers.length === 0) {
    l.push('- Untrusted evidence markers ignored during discovery: 0')
  } else {
    l.push(`- Untrusted evidence markers ignored during discovery: ${report.source.ignored_markers.length}`)
    for (const marker of report.source.ignored_markers) {
      l.push(
        `  - ${cell(marker.where)}, comment ${cell(marker.comment_id ?? 'unknown')}, actor ${cell(marker.actor_id ?? 'unknown')}, naming run \`${cell(marker.run_id)}\``
      )
    }
  }
  if (report.source.malformed_markers.length === 0) {
    l.push('- Malformed `devflow:` markers ignored during discovery: 0')
  } else {
    l.push(`- Malformed \`devflow:\` markers ignored during discovery: ${report.source.malformed_markers.length}`)
    for (const marker of report.source.malformed_markers) {
      l.push(
        `  - ${cell(marker.where)}, comment ${cell(marker.comment_id ?? 'unknown')}: ${cell(marker.reason)}`
      )
    }
  }
  if (report.source.ignored_hints.length === 0) {
    l.push('- Body discovery hints ignored: 0')
  } else {
    l.push(`- Body discovery hints ignored: ${report.source.ignored_hints.length}`)
    for (const hint of report.source.ignored_hints) {
      l.push(`  - ${cell(hint.hint)} (${cell(hint.tier)}): ${cell(hint.reason)}`)
    }
  }
  l.push('')

  l.push('### Not measurable from this run\'s evidence')
  l.push('')
  for (const gap of report.unavailable) {
    l.push(`- **${safe(gap.measurement)}** — ${safe(gap.reason)} (${safe(gap.issue)}).`)
  }
  return l.join('\n')
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

// Never silently: an ignored marker is either a misconfigured trust root or
// somebody trying to redirect the report, and both are worth saying out loud.
function reportIgnoredMarkers(untrusted, malformed) {
  for (const marker of untrusted) {
    console.error(
      `${TOOL}: ignoring an untrusted evidence marker naming run ${JSON.stringify(marker.run_id)} on ${marker.where} (comment ${marker.comment_id ?? 'unknown'}, actor ${marker.actor_id ?? 'unknown'})`
    )
  }
  for (const marker of malformed) {
    console.error(
      `${TOOL}: ignoring a malformed devflow marker on ${marker.where} from ${marker.trusted ? 'a TRUSTED actor' : 'an untrusted author'} (comment ${marker.comment_id ?? 'unknown'}): ${marker.reason}`
    )
  }
}

function reportIgnoredHints(ignoredHints) {
  for (const hint of ignoredHints) {
    console.error(`${TOOL}: ignoring body discovery hint ${JSON.stringify(hint.hint)} (${hint.tier}): ${hint.reason}`)
  }
}

// Local-only data never enters measure(), policy parsing, or authentication.
// Validate a snapshot of the bytes we render, not a file that may change after
// validation. The shipped run validator checks both shape and semantics.
const LOCAL_PROVENANCE = 'unverified (local record, not authenticated by a trusted GitHub evidence marker)'

function localSafe(value) {
  return safe(String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;'))
    .replace(/[\u0000-\u0008\u000a-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '')
}

function isLocalPathInside(parent, resolved) {
  const relative = path.relative(parent, resolved)
  return !(relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative))
}

function renderLocalUnverified(args, runId, requestedPr) {
  if (!args.run || !args.recordDir) throw new UsageError('--local-unverified requires --run and --record-dir for a local read')
  if (args.asOf) throw new UsageError('--as-of is unavailable for local-unverified records; rerun without it')
  if (runId === '.' || runId === '..' || /[/\\]/.test(runId)) {
    throw new LocalRefusalError('local run.json path escapes the selected run directory; --run must name one directory')
  }
  let parent
  try {
    parent = realpathSync(args.recordDir)
    if (!statSync(parent).isDirectory()) throw new LocalRefusalError('--record-dir is not a directory')
  } catch (error) {
    if (error instanceof LocalRefusalError) throw error
    throw new LocalRefusalError('--record-dir cannot be read as a directory')
  }
  const runDirectory = path.join(parent, runId)
  try {
    if (!statSync(runDirectory).isDirectory()) throw new LocalRefusalError('local run path is not a directory')
  } catch (error) {
    if (error.code === 'ENOENT') return null
    if (error instanceof LocalRefusalError) throw error
    throw new LocalRefusalError('local run path cannot be read as a directory')
  }
  if (typeof constants.O_NOFOLLOW !== 'number' || constants.O_NOFOLLOW === 0) {
    throw new LocalRefusalError('local no-follow reads are unavailable on this platform')
  }
  if (process.platform !== 'linux') {
    throw new LocalRefusalError('local descriptor containment cannot be established on this platform')
  }
  const file = path.join(runDirectory, 'run.json')
  let fd
  let resolved
  let bytes
  try {
    // O_NONBLOCK prevents a replaced FIFO from blocking before fstat refuses it.
    fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK)
    const fileStat = fstatSync(fd, { bigint: true })
    if (!fileStat.isFile()) throw new LocalRefusalError('local run.json is not a regular file')
    // One kernel readlink describes the open object. realpath would walk that
    // returned path again, letting renamed ancestors redirect the proof.
    let pathStat
    try {
      resolved = readlinkSync(`/proc/self/fd/${fd}`)
      if (!path.isAbsolute(resolved) || resolved.endsWith(' (deleted)')) {
        throw new LocalRefusalError('local descriptor containment cannot be established')
      }
      if (!isLocalPathInside(parent, resolved)) {
        throw new LocalRefusalError('local run.json descriptor resolves outside --record-dir')
      }
      pathStat = lstatSync(resolved, { bigint: true })
    } catch (error) {
      if (error instanceof LocalRefusalError) throw error
      throw new LocalRefusalError('local descriptor containment cannot be established')
    }
    if (fileStat.dev !== pathStat.dev || fileStat.ino !== pathStat.ino) {
      throw new LocalRefusalError('local run.json descriptor identity differs from its path')
    }
    bytes = readFileSync(fd, 'utf8')
  } catch (error) {
    if (fd === undefined && error.code === 'ENOENT') return null
    if (error.code === 'ELOOP' || error.code === 'ENOTDIR') {
      throw new LocalRefusalError('local run.json requires a no-follow regular file in a directory')
    }
    throw error
  } finally {
    if (fd !== undefined) closeSync(fd)
  }
  const validator = path.join(ASSET_DIR, '..', '..', 'dev-flow-support', 'assets', 'validate-result-schemas.mjs')
  if (!existsSync(validator)) throw new OperationalError('local run schema validator is unavailable')
  const snapshot = mkdtempSync(path.join(tmpdir(), 'retro-local-'))
  let record
  try {
    const snapshotFile = path.join(snapshot, 'run.json')
    writeFileSync(snapshotFile, bytes)
    const validation = spawnSync(process.execPath, [validator, 'run', snapshotFile], {
      encoding: 'utf8', maxBuffer: MAX_SYNC_BUFFER_BYTES
    })
    if (validation.error) throw new OperationalError(`local run schema validator failed: ${validation.error.message}`)
    if (validation.signal || validation.status === null) {
      throw new OperationalError(`local run schema validator failed: ${validation.signal ? `signal ${validation.signal}` : 'no exit status'}`)
    }
    if (validation.status !== 0) {
      if (validation.status !== 1 || !/^FAIL: /m.test(validation.stderr || '')) {
        throw new OperationalError(`local run schema validator failed without validation output: ${JSON.stringify((validation.stderr || '').trim())}`)
      }
      throw new LocalRefusalError(`local run.json failed schema validation: ${JSON.stringify((validation.stderr || '').trim())}`)
    }
    if (!/^run record OK(?: \(.*\))?\s*$/.test(validation.stdout || '')) {
      throw new OperationalError('local run schema validator produced no validation output')
    }
    record = JSON.parse(bytes)
  } finally {
    rmSync(snapshot, { recursive: true, force: true })
  }
  if (record.run_id !== runId) throw new LocalRefusalError('local run.json run_id differs from --run')
  if (args.pr !== undefined && record.pr && record.pr.number !== args.pr) {
    throw new LocalRefusalError(`local run.json records PR #${record.pr.number}, not the requested #${args.pr}`)
  }
  if (record.pr && requestedPr) {
    let normalized
    let expected
    try {
      normalized = new URL(record.pr.url).href.replace(/\/+$/, '').toLowerCase()
      expected = new URL(requestedPr.url).href.replace(/\/+$/, '').toLowerCase()
    } catch {
      throw new LocalRefusalError('local run.json PR URL is invalid')
    }
    if (normalized !== expected) {
      throw new LocalRefusalError('local run.json PR URL does not name the requested repository and PR')
    }
  }

  const measurements = []
  const add = (measurement, value) => measurements.push({ measurement, value, provenance: LOCAL_PROVENANCE })
  add('Started at', record.started_at)
  add('Initiated by', record.initiated_by)
  add('Outcome', record.outcome ?? 'not recorded')
  add('PR recorded locally', record.pr ? `#${record.pr.number} (${record.pr.url})` : 'not recorded')
  if (args.pr !== undefined && !record.pr) {
    add('PR binding', `no PR is recorded locally; this record is not bound to PR #${args.pr}`)
  }
  for (const transition of record.stage_transitions) {
    add('Stage entry', `${transition.stage} at ${transition.entered_at}; exit: ${transition.exit ?? 'not recorded'}`)
  }
  add('Adjudication rounds', existsSync(path.join(path.dirname(resolved), 'adjudications'))
    ? 'not measured — local adjudications are not authenticated'
    : 'not recorded — adjudications/ is absent')
  add('Findings and convergence', 'not measured — no authenticated adjudication evidence')
  if (record.interventions.length === 0) add('Interventions', 'none recorded')
  for (const entry of record.interventions) add('Intervention', `${entry.at}: ${entry.kind}; ${entry.note}`)
  if (record.settlements.length === 0) add('Settlements', 'none recorded')
  for (const entry of record.settlements) {
    add('Settlement recorded locally', `${entry.finding_id}: ${entry.disposition} at ${entry.settled_at}; ${entry.reference.type} ${entry.reference.value}`)
  }
  add('Promotion recorded locally', record.promotion
    ? `${record.promotion.head} at ${record.promotion.promoted_at}; fingerprint ${record.promotion.gate_fingerprint}`
    : 'not recorded')
  const report = {
    schema: 'retro-run-report.v1', status: 'local-unverified', verified: false,
    run_id: runId, provenance: LOCAL_PROVENANCE, source: { local_record: resolved }, measurements
  }
  return args.json ? JSON.stringify(report, null, 2).replace(/[\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, '0')}`) : [
    `## Run evidence — run \`${localSafe(runId)}\` — ${LOCAL_PROVENANCE}`, '',
    ...measurements.map((entry) => `- ${entry.measurement}: ${localSafe(entry.value)} — ${entry.provenance}`)
  ].join('\n')
}

function deletedEntryReason(missing, source) {
  return `${missing}, but a trusted evidence marker (${source}) names it. An indexed run whose evidence the harvester cannot find is deleted-entry tampering, never a run that did not happen.`
}

function run(argv) {
  const args = parseArgs(argv)
  if (args.help) {
    console.log(USAGE)
    return 0
  }
  validateArgs(args)

  // Trust first: discovery gates on the same actor-id set the harvester will
  // use, so it has to be resolved before a single marker is read.
  const trusted = resolveTrustedActorArgs(args)

  // Discovery BEFORE the harvester lookup, deliberately. Answering "is there
  // a run record?" needs GitHub, not a local script, and doing it first is
  // what lets a checkout with no harvester still distinguish "nothing was
  // ever posted" (exit 10) from "there is a record here I cannot read"
  // (exit 12) — challenge round 1, confirmed P1.
  let pr = null
  let runId = args.run || null
  let runIdFrom = args.run ? '--run on the command line' : null
  let untrustedMarkers = []
  let malformedMarkers = []
  let ignoredHints = []
  let unverifiedBodyRunIds = []
  if (!runId) {
    try {
      const discovered = discoverRun(args, trusted.ids)
      requireDeterminateDiscovery(args, trusted, discovered)
      pr = discovered.pr
      runId = discovered.runId
      runIdFrom = discovered.source
      untrustedMarkers = discovered.untrusted
      malformedMarkers = discovered.malformed
      ignoredHints = discovered.ignoredHints
      unverifiedBodyRunIds = discovered.unverifiedBodyRunIds
    } catch (error) {
      if (!(error instanceof IndeterminateError)) throw error
      reportIgnoredMarkers(error.untrusted, error.malformed)
      reportIgnoredHints(error.ignoredHints)
      console.error(`${TOOL}: indeterminate — ${error.message}`)
      return 11
    }
    // Before the no-run-record return, not after: "nothing was found" and
    // "something was found and refused" must never look the same on stderr.
    reportIgnoredMarkers(untrustedMarkers, malformedMarkers)
    reportIgnoredHints(ignoredHints)
    if (!runId) {
      console.error(
        `${TOOL}: no-run-record — PR #${args.pr} and its linked issues carry no Dev flow v2 evidence marker at all${unverifiedBodyRunIds.length > 0 ? `; PR-body run-id token(s) ${unverifiedBodyRunIds.map((id) => JSON.stringify(id)).join(', ')} had no matching trusted marker and cannot bind a run` : ''}; use the retro's fallback procedure`
      )
      return 10
    }
  } else if (args.pr !== undefined) {
    pr = ghJson(['pr', 'view', String(args.pr), '--repo', args.repo, '--json', 'number,url,title,state,isDraft,body'])
  }
  // In --run-only mode the trajectory may still name its own PR, and that
  // binding comes from the authenticated run record rather than a caller's
  // argument — a better source than --pr, not a worse one. Fetching it is
  // what stops a perfectly ordinary `--run <id>` report from declaring every
  // cap unknown (cloud review round 1, confirmed P2). Resolved after the
  // harvest below, since the trajectory is where the PR number comes from.

  const stats = resolveStatsCommand(args.statsScript)
  if (stats.missingReason) {
    // What is known about the run differs by how its id was obtained, and the
    // message must not blur the two: a trusted marker IS evidence the run was
    // recorded, while a --run argument is an unverified string this tool
    // never checked against anything (challenge round 2, confirmed P1).
    const standing = args.run
      ? `Run \`${runId}\` was supplied with --run and has NOT been verified against any marker — this tool cannot say whether it exists`
      : `Run \`${runId}\` IS recorded (${runIdFrom}) but cannot be read here`
    console.error(
      `${TOOL}: no-stats-script — ${stats.missingReason}. ${standing}. Vendor the harvester (harmon-devkit#663) or rerun with --stats-script; do NOT report the session as having no run record — this exit says nothing either way.`
    )
    return 12
  }

  let harvested
  try {
    harvested = harvestTrajectory(stats, args, runId, trusted)
  } catch (error) {
    if (!(error instanceof IndeterminateError)) throw error
    console.error(`${TOOL}: indeterminate — ${error.message}`)
    return 11
  }
  if (harvested.missing) {
    // A trusted marker naming a run the harvester cannot find is the evidence
    // spec's deleted-entry case — "reject it as deleted-entry tampering, never
    // reinterpret it as a run that did not happen" — so it is indeterminate,
    // not a fallback (review round 1, confirmed P1). A plain run-not-found id
    // from --run carries no such claim, but structured record-missing does:
    // the harvester authenticated its marker before finding the local gap.
    if (harvested.missingKind === 'record-missing' || !args.run) {
      const reason = !args.run ? deletedEntryReason(harvested.missing, runIdFrom)
        : `${harvested.missing}. Authenticated evidence exists, but its named local record is absent.`
      console.error(`${TOOL}: indeterminate — ${reason}`)
      return 11
    }
    // The opt-in may replace only the ordinary exit-10 outcome. Read-only
    // discovery guards that local read; it never selects a run or mutates --run.
    if (args.localUnverified) {
      let discovered = null
      if (args.pr !== undefined) {
        try {
          discovered = discoverRun(args, trusted.ids)
          requireDeterminateDiscovery(args, trusted, discovered)
        } catch (error) {
          if (!(error instanceof IndeterminateError)) throw error
          reportIgnoredMarkers(error.untrusted, error.malformed)
          reportIgnoredHints(error.ignoredHints)
          console.error(`${TOOL}: indeterminate — ${error.message}`)
          return 11
        }
      }
      const corrupted = discovered?.malformed.filter((marker) => marker.trusted) || []
      if (corrupted.length > 0) {
        reportIgnoredMarkers(discovered.untrusted, discovered.malformed)
        throw new IndeterminateError('trusted discovery evidence is malformed; local data cannot replace it')
      }
      if (discovered?.runId === runId) {
        reportIgnoredMarkers(discovered.untrusted, discovered.malformed)
        reportIgnoredHints(discovered.ignoredHints)
        console.error(`${TOOL}: indeterminate — ${deletedEntryReason(harvested.missing, discovered.source)}`)
        return 11
      }
      if (!discovered?.runId) {
        if (discovered) {
          reportIgnoredMarkers(discovered.untrusted, discovered.malformed)
          reportIgnoredHints(discovered.ignoredHints)
        }
        const local = renderLocalUnverified(args, runId, discovered?.pr || pr)
        if (local !== null) {
          console.log(local)
          return 13
        }
      }
    }
    console.error(`${TOOL}: ${harvested.missing}; use the retro's fallback procedure`)
    return 10
  }

  if (harvested.trajectory && harvested.trajectory.status === 'evidence-only') {
    const markerPrMatch = !args.run && /^evidence marker on PR #(\d+)$/.exec(runIdFrom || '')
    const harvestedPr = harvested.trajectory.pr_binding && Number(harvested.trajectory.pr_binding.number)
    const evidencePr = Number.isInteger(harvestedPr) && harvestedPr > 0
      ? harvestedPr
      : markerPrMatch
        ? Number(markerPrMatch[1])
        : null
    if (args.pr !== undefined && evidencePr !== null && evidencePr !== args.pr) {
      console.error(
        `${TOOL}: indeterminate — evidence-only run \`${safe(runId)}\` is bound to PR #${evidencePr}, not the requested #${args.pr}`
      )
      return 11
    }
    const prBinding = evidencePr === null
      ? 'unbound — authenticated markers identify the run, but no retained run record or PR marker binds it to a PR'
      : `bound to PR #${evidencePr}`
    const evidenceOnly = {
      schema: 'retro-run-report.v1',
      run_id: runId,
      status: 'evidence-only',
      issue: harvested.trajectory.issue,
      marker_facts: harvested.trajectory.marker_facts || [],
      untrusted_marker_facts: harvested.trajectory.untrusted_marker_facts || [],
      legacy_also_present: Boolean(harvested.trajectory.legacy_also_present),
      source: { harvester: stats.display, run_id_from: runIdFrom, trusted_actors: trusted.source, pr_binding: prBinding }
    }
    if (args.json) console.log(JSON.stringify(evidenceOnly, null, 2))
    else {
      console.log(`## Run evidence — run \`${safe(runId)}\``)
      console.log('')
      console.log(`- Status: \`evidence-only\``)
      console.log(`- Trust source: ${safe(evidenceOnly.source.trusted_actors)}`)
      console.log(`- Issue: #${evidenceOnly.issue}`)
      console.log(`- Authenticated marker facts: \`${JSON.stringify(evidenceOnly.marker_facts)}\``)
      console.log(`- Untrusted marker facts: \`${JSON.stringify(evidenceOnly.untrusted_marker_facts)}\``)
      console.log(`- Legacy also present: \`${evidenceOnly.legacy_also_present}\``)
      console.log(`- PR binding: ${safe(prBinding)}`)
      console.log('- Full trajectory unavailable: rerun with `--record-dir <path>` containing `<path>/<run_id>/run.json`.')
    }
    return 0
  }

  // A run record names its own PR. A trajectory that names a DIFFERENT one is
  // not this PR's run however authentic it is, and rendering it under this
  // PR's disclosed policy would attribute one run's rounds to another.
  const boundPr = harvested.trajectory.pr
  if (args.pr !== undefined && boundPr && boundPr.number !== args.pr) {
    console.error(
      `${TOOL}: indeterminate — run \`${runId}\` records PR #${boundPr.number}, not the requested #${args.pr}; the marker that named it does not bind it to this PR`
    )
    return 11
  }
  // An explicit --run read no marker, so when its record also names no PR
  // there is NOTHING linking the trajectory to the --pr the caller happened
  // to pass. Measuring it against that PR's disclosed caps would attribute
  // one run's rounds to another's budget (challenge round 2, confirmed P2 —
  // fixed in place rather than deferred: it is the same false-claim class as
  // the exit-12 message above and costs one branch).
  // ...and here is that resolution: --run with no --pr, but a record that
  // names one. The PR is fetched for its policy disclosure only; nothing
  // about selection changes, and a fetch failure degrades to caps-unknown
  // rather than failing the report.
  if (pr === null && boundPr) {
    try {
      pr = ghJson(['pr', 'view', String(boundPr.number), '--repo', args.repo, '--json', 'number,url,title,state,isDraft,body'])
    } catch (error) {
      if (!(error instanceof OperationalError)) throw error
      console.error(`${TOOL}: could not read PR #${boundPr.number} for its policy disclosure — caps will be reported unknown (${error.message})`)
    }
  }
  const unbound = Boolean(args.run) && !boundPr
  const prBinding =
    args.pr === undefined && !boundPr
      ? null
      : boundPr
        ? `bound to PR #${boundPr.number}`
        : unbound
          ? `none — the run id came from --run, its record names no PR, and no marker was read, so nothing binds this trajectory to #${args.pr}`
          : 'the run record names no PR yet, so the binding rests on the trusted marker that named this run'

  const policy = unbound
    ? {
        present: false,
        verified: false,
        reason: `run \`${runId}\` is not bound to PR #${args.pr} (supplied with --run, and its record names no PR), so that PR's disclosed caps are not this run's`
      }
    : readPolicyDisclosure(pr ? pr.body : null)
  const measurements = measure(harvested.trajectory, policy)
  const report = {
    schema: 'retro-run-report.v1',
    run_id: runId,
    as_of: args.asOf || null,
    source: {
      harvester: stats.display,
      run_id_from: runIdFrom,
      trusted_actors: trusted.source,
      pr_binding: prBinding,
      ignored_markers: untrustedMarkers,
      malformed_markers: malformedMarkers,
      ignored_hints: ignoredHints
    },
    trajectory: harvested.trajectory,
    policy,
    measurements,
    unavailable: unavailableMeasurements(measurements)
  }
  console.log(args.json ? JSON.stringify(report, null, 2) : renderMarkdown(report))
  return 0
}

function main() {
  try {
    return run(process.argv.slice(2))
  } catch (error) {
    if (error instanceof UsageError) {
      console.error(`${TOOL}: ${error.message}`)
      console.error(USAGE)
      return 2
    }
    if (error instanceof LocalRefusalError) {
      console.error(`${TOOL}: refused local record — ${error.message}`)
      return 14
    }
    if (error instanceof IndeterminateError) {
      console.error(`${TOOL}: indeterminate — ${error.message}`)
      return 11
    }
    if (error instanceof OperationalError) {
      console.error(`${TOOL}: ${error.message}`)
      return 1
    }
    throw error
  }
}

process.exitCode = main()
