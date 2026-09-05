#!/usr/bin/env node
// retro-run-report.mjs — project one Dev flow v2 run's retained evidence into
// the fixed measurement sections of a `/retro` report.
//
// A projection, never a second source of truth: every number below is read
// from the run trajectory `scripts/dev-flow-stats.mjs --run <id> --json`
// harvests (issue #663) or from the resolved-policy line the renderer already
// published into the PR body (`scripts/render-dev-flow.mjs`, issue #637).
// Nothing here re-derives a disposition, a cap, or an exit.
//
// Usage:
//   retro-run-report.mjs --repo <owner/repo> --pr <n> [--run <run_id>]
//     [--trusted-actor-id <id>]... [--trusted-actors-file <path>]
//     [--as-of <iso8601>] [--stats-script <path>] [--json]
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
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'

const TOOL = 'retro-run-report'

const USAGE = `Usage: retro-run-report.mjs --repo <owner/repo> --pr <n> [options]

  --repo <owner/repo>          Required. The repository the run lives in.
  --pr <n>                     The session's PR. Required unless --run is given.
  --run <run_id>               Skip discovery and report on this run.
  --trusted-actor-id <id>      Repeatable. Trusted-orchestrator GitHub actor
                               ids. Gates which comments may name a run AND is
                               passed through to the harvester. REQUIRED (with
                               --trusted-actors-file): there is no default.
  --trusted-actors-file <path> A JSON {"trusted_actor_ids": [...]} document,
                               passed through to the harvester.
  --as-of <iso8601>            Reconstruct the RUN RECORD and its comment
                               evidence as of this instant. Discovery inputs
                               GitHub does not version are NOT reconstructed
                               and stay current-state: the linked-issue set
                               (the PR's closing references) and the PR body
                               the disclosed caps are read from. The report
                               says so wherever it uses one.
  --stats-script <path>        Override harvester discovery (tests, or a
                               checkout that keeps it somewhere else).
  --json                       Emit the machine form instead of Markdown.`

class UsageError extends Error {}
class OperationalError extends Error {}
// Evidence that exists but does not authenticate, or cannot be attributed to
// one run. Distinct from "no evidence" — see the exit-code table above.
class IndeterminateError extends Error {}

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
      case '--json':
        args.json = true
        break
      default:
        throw new UsageError(`unknown argument ${JSON.stringify(flag)}`)
    }
  }
  return args
}

// The same grammar scripts/dev-flow-stats.mjs enforces on its own --as-of:
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
  const result = spawnSync('gh', argv, { encoding: 'utf8' })
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
// one. Same call shape scripts/dev-flow-stats.mjs uses for the same reason.
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
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
  } catch {
    return null
  }
}

// The harvester lives in the repository under review, not beside this asset:
// skills are vendored into consumer repos (flattened, under .agents/skills/),
// while scripts/dev-flow-stats.mjs is `scripts/`-shipped and may simply not be
// there. Resolving from the git top level rather than import.meta.url is what
// makes "the retro skill is vendored but the harvester is not" the ordinary,
// well-handled case instead of a crash.
function resolveStatsCommand(explicit) {
  if (explicit) return statsCommandFor(explicit)
  const root = repoRoot()
  if (!root) return { missingReason: 'this directory is not inside a git repository, so the harvester could not be located' }
  for (const candidate of ['scripts/dev-flow-stats.sh', 'scripts/dev-flow-stats.mjs']) {
    const full = path.join(root, candidate)
    if (existsSync(full)) return statsCommandFor(full)
  }
  return { missingReason: `${root} has no scripts/dev-flow-stats.sh or scripts/dev-flow-stats.mjs` }
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
  const marker = EVIDENCE_MARKER_RE.exec(body.replace(/\r/g, '').replace(/^[ \t]+/, ''))
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
  return { kind, runId: attrs.run_id }
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
function collectRunIds(comments, trustedActorIds, where, untrusted, malformed) {
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
    if (parsed.malformed) {
      malformed.push({ ...entry, reason: parsed.malformed })
      continue
    }
    if (!Number.isInteger(actorId) || !trustedActorIds.has(actorId)) {
      untrusted.push({ ...entry, run_id: parsed.runId })
      continue
    }
    found.add(parsed.runId)
  }
  return found
}

// Prefer the PR's own evidence comments over the issue's: a re-run posts a
// second run record on the same issue, so "which run is this PR's" is only
// answerable from PR-bound evidence. Fall back to the linked issues, which is
// where a run that capped before its PR existed keeps everything.
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
  const fromPr = [...collectRunIds(fetchComments(args.repo, pr.number, asOf), trustedActorIds, `PR #${pr.number}`, untrusted, malformed)].sort()
  if (fromPr.length === 1) {
    return { pr, runId: fromPr[0], source: `evidence marker on PR #${pr.number}`, untrusted, malformed }
  }
  if (fromPr.length > 1) {
    throw new IndeterminateError(
      `PR #${pr.number} carries trusted evidence for more than one run (${fromPr.join(', ')}) — rerun with --run <run_id>`
    )
  }
  // NOT reconstructed by --as-of, and the report says so. The linked-issue
  // set comes from the PR's closing references as they stand NOW: GitHub does
  // not version that link, so a re-link after the cutoff changes which issues
  // a historical read searches. Rather than patch a fourth current-state
  // input into the cutoff (review round 4's P1, after r2's comment filter and
  // r3's cutoff validation), --as-of is restructured to the invariant it can
  // actually keep: it reconstructs the RUN RECORD and its comment evidence at
  // the cutoff, and every discovery input GitHub does not version is
  // current-state and disclosed as such in the output.
  const issues = Array.isArray(pr.closingIssuesReferences) ? pr.closingIssuesReferences : []
  // Which issues carried a given run id, not just which ids exist: a run whose
  // record sits on a different issue than the reader expects is worth naming
  // in the report's provenance line rather than reducing to "an issue".
  const fromIssues = new Map()
  for (const issue of issues) {
    const comments = fetchComments(args.repo, issue.number, asOf)
    for (const runId of collectRunIds(comments, trustedActorIds, `issue #${issue.number}`, untrusted, malformed)) {
      const seen = fromIssues.get(runId) || new Set()
      seen.add(issue.number)
      fromIssues.set(runId, seen)
    }
  }
  if (fromIssues.size === 1) {
    const [runId, seen] = [...fromIssues.entries()][0]
    const where = [...seen].sort((a, b) => a - b).map((n) => `#${n}`).join(', ')
    return { pr, runId, source: `evidence marker on issue ${where}`, untrusted, malformed }
  }
  if (fromIssues.size > 1) {
    throw new IndeterminateError(
      `the issues linked to PR #${pr.number} carry trusted evidence for more than one run (${[...fromIssues.keys()].sort().join(', ')}) — rerun with --run <run_id>`
    )
  }
  return { pr, runId: null, source: null, untrusted, malformed }
}

// ---------------------------------------------------------------------------
// Trusted actor ids
// ---------------------------------------------------------------------------

// There is no default trust root, deliberately. An earlier revision fell back
// to the authenticated account, which made a run's evidence valid or invalid
// depending on who happened to run `/retro` and let a reader's own comments
// authenticate their own retrospective — the evidence spec requires authority
// to "derive solely from configured trusted orchestrator actor IDs", and
// "whoever is logged in" is not configured (challenge round 2, confirmed P1).
// scripts/dev-flow-stats.mjs already requires the ids explicitly; matching it
// removes the divergence rather than papering over it. agent-registry.json
// will carry the allowlist under harmon-devkit#741; until then the caller
// supplies it, from a committed --trusted-actors-file or the flag.
function resolveTrustedActorArgs(args) {
  const passthrough = []
  const ids = new Set()
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
    if (!Array.isArray(doc.trusted_actor_ids)) {
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
      'at least one --trusted-actor-id or --trusted-actors-file entry is required — a marker only names a run if a configured trusted orchestrator posted it, and there is deliberately no "whoever is logged in" default (harmon-devkit#741 will supply the allowlist from agent-registry.json)'
    )
  }
  // Name the ids, not just their provenance. "Supplied on the command line"
  // cannot be reproduced or audited from a pasted retro, and it is exactly
  // what a reader needs in order to tell a misconfigured allowlist from a
  // hostile marker when the ignored-marker count is nonzero (review round 3,
  // confirmed P2).
  const listed = [...ids].sort((a, b) => a - b).join(', ')
  const from = args.trustedActorsFile ? ` (including ${args.trustedActorsFile})` : ''
  return { passthrough, ids, source: `actor id(s) ${listed}${from}` }
}

// ---------------------------------------------------------------------------
// Harvest
// ---------------------------------------------------------------------------

function harvestTrajectory(stats, args, runId, trusted) {
  const argv = [...stats.prefix, '--repo', args.repo, '--run', runId, '--json', ...trusted.passthrough]
  if (args.asOf) argv.push('--as-of', args.asOf)
  const result = spawnSync(stats.command, argv, { encoding: 'utf8' })
  if (result.error) {
    throw new OperationalError(`${stats.display} failed to execute: ${result.error.message}`)
  }
  const stderr = (result.stderr || '').trim()
  if (result.status === 1) {
    return { missing: `run-not-found — ${stderr || `the harvester does not know run ${runId}`}` }
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
const POLICY_LINE_RE =
  /^rigor:\s*`([^`]*)`\s*\(`([^`]*)`\)\s*→\s*challenge ≤(\d+), review ≤(\d+), integration (\d+), remediation (\d+), min_rounds (\d+)\s*$/

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
      remediation: Number(match[6]),
      min_rounds: Number(match[7])
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

function measure(trajectory, policy) {
  const transitions = Array.isArray(trajectory.stage_transitions) ? trajectory.stage_transitions : []
  const rounds = Array.isArray(trajectory.rounds) ? trajectory.rounds : []
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
    return {
      stage,
      entries: transitions
        .filter((transition) => transition.stage === stage)
        .map((transition) => ({ entered_at: transition.entered_at, exit: transition.exit ?? null })),
      rounds_spent: own.length,
      cap,
      findings: own.reduce((total, round) => total + (round.finding_count || 0), 0),
      passes: own.reduce((total, round) => total + (round.pass_count || 0), 0),
      rounds_without_adjudication: own.filter((round) => !round.has_adjudication).map((round) => round.round),
      interventions: interventions
        .filter((entry) => stageAt(transitions, entry.at) === stage)
        .map((entry) => ({ at: entry.at, kind: entry.kind, note: entry.note }))
    }
  })

  const classProvenance = Object.entries(trajectory.findings_by_class_and_provenance || {})
    .map(([key, count]) => {
      const slash = key.indexOf('/')
      return slash === -1
        ? { class: key, provenance: 'unspecified', count }
        : { class: key.slice(0, slash), provenance: key.slice(slash + 1), count }
    })
    .sort((a, b) => b.count - a.count || a.class.localeCompare(b.class) || a.provenance.localeCompare(b.provenance))

  // The acceptance criterion wants class/provenance INSIDE each stage
  // section, and the trajectory only aggregates it run-wide. Where exactly
  // one stage produced findings the aggregate is unambiguously that stage's,
  // so attribute it and say so; where more than one did, no split is
  // derivable from this evidence and the run-wide table stands with the gap
  // named in each affected stage section (review round 2, adjudicated P2 —
  // the remedy is a harvester change this lane may not make).
  const stagesWithFindings = [...new Set(stages.filter((st) => st.findings > 0).map((st) => st.stage))]
  const attribution =
    classProvenance.length === 0
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
      forged_comments: (trajectory.forged_comments || []).length
    }
  }
}

// Measurements the retro is asked for that today's evidence surface cannot
// supply. Named here, with the issue that would close each, rather than
// silently omitted — an absent section reads as "nothing to report".
function unavailableMeasurements(measured) {
  const gaps = [
    {
      measurement: 'findings by class and provenance, keyed by stage',
      reason:
        "the run trajectory's findings_by_class_and_provenance aggregates over the whole run, so this report's breakdown is run-wide unless exactly one stage found anything",
      issue: 'harmon-devkit#779'
    },
    {
      measurement: 'remediation rounds spent against the remediation cap',
      reason:
        'remediation is budgeted independently of integration, but it is not a stage in run.schema.json\'s stage enum and the run trajectory exposes no remediation count, so the remediation cap shown in the policy line above is disclosed and unmeasured — an integration run cannot be shown to have exhausted it',
      issue: 'harmon-devkit#663 successors'
    },
    {
      measurement: 'adjudicated-priority overrides per finding',
      reason:
        'the run trajectory reduces each round\'s adjudication document to a has_adjudication boolean, dropping reviewer_priority, adjudicated_priority and override',
      issue: 'harmon-devkit#753'
    }
  ]
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

// Free text here is reviewer- and human-authored prose (intervention notes,
// stage exits, disclosure details) that a reader may paste into a PR body or
// comment. Neutralize marker sequences and fold newlines for the same reason
// render-dev-flow.mjs does: an evidence note that quotes `<!--` would forge a
// section boundary on the next parse.
function safe(value) {
  return String(value ?? '')
    .replace(/<!--/g, '&lt;!--')
    .replace(/-->/g, '--&gt;')
    .replace(/\r?\n/g, ' ')
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
      '  Discovery inputs GitHub does not version are **not** reconstructed and are read as they stand now: the **linked-issue set** (the PR\'s closing references, which decide which issues a fallback search reaches) and the **PR body** the disclosed caps above come from. Re-linking an issue, or editing the body, changes those even for a fixed cutoff.'
    )
  }
  l.push('')

  l.push('### Policy the PR discloses (unverified)')
  l.push('')
  if (report.policy.present) {
    const r = report.policy.rounds
    l.push(
      `rigor: \`${safe(report.policy.rigor.level)}\` (\`${safe(report.policy.rigor.source)}\`) → challenge ≤${r.challenge}, review ≤${r.review}, integration ${r.integration}, remediation ${r.remediation}, min_rounds ${r.min_rounds}`
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
    if (stage.cap !== null || stage.rounds_spent > 0) {
      const cap = stage.cap === null ? 'no cap recorded' : `cap ${stage.cap} (disclosed, unverified)`
      l.push(`- Rounds spent: ${stage.rounds_spent} / ${cap}`)
      l.push(`- Findings: ${stage.findings} across ${stage.passes} pass(es)`)
      l.push(
        `- Rounds with no adjudication record: ${stage.rounds_without_adjudication.length === 0 ? 'none' : stage.rounds_without_adjudication.join(', ')}`
      )
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
      if (attribution.scope === 'stage' && attribution.stage === stage.stage) {
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
  if (report.measurements.findings_by_class_and_provenance.length === 0) {
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
  l.push(
    `- Trust evaluation: ${safe(report.source.trusted_actors)} — the caller's current set, **not** the run's kickoff-time registry revision, so an orchestrator trusted at kickoff and removed since would read as untrusted here (harmon-devkit#741)`
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
      `${TOOL}: ignoring an untrusted evidence marker naming run ${marker.run_id} on ${marker.where} (comment ${marker.comment_id ?? 'unknown'}, actor ${marker.actor_id ?? 'unknown'})`
    )
  }
  for (const marker of malformed) {
    console.error(
      `${TOOL}: ignoring a malformed devflow marker on ${marker.where} (comment ${marker.comment_id ?? 'unknown'}): ${marker.reason}`
    )
  }
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
  if (!runId) {
    try {
      const discovered = discoverRun(args, trusted.ids)
      pr = discovered.pr
      runId = discovered.runId
      runIdFrom = discovered.source
      untrustedMarkers = discovered.untrusted
      malformedMarkers = discovered.malformed
    } catch (error) {
      if (!(error instanceof IndeterminateError)) throw error
      console.error(`${TOOL}: indeterminate — ${error.message}`)
      return 11
    }
    // Before the no-run-record return, not after: "nothing was found" and
    // "something was found and refused" must never look the same on stderr.
    reportIgnoredMarkers(untrustedMarkers, malformedMarkers)
    if (!runId) {
      // "No trusted marker" and "no marker at all" are different answers, and
      // only the second one licenses the fallback. Markers that exist but do
      // not authenticate are either a redirect attempt or a trust root that
      // has MOVED since the run — an orchestrator trusted at kickoff and
      // removed since is exactly the case the evidence contract protects, and
      // this tool cannot tell the two apart because it authenticates against
      // the caller's set rather than the run's kickoff-time registry revision
      // (harmon-devkit#741). Reporting either as "no run record" would
      // reinterpret a run that plainly happened as one that did not
      // (review round 1, confirmed P1).
      if (untrustedMarkers.length > 0) {
        const runs = [...new Set(untrustedMarkers.map((m) => m.run_id))].sort().join(', ')
        console.error(
          `${TOOL}: indeterminate — PR #${args.pr} and its linked issues carry ${untrustedMarkers.length} evidence marker(s) naming ${runs}, none authored by a trusted actor (${trusted.source}). That is either a redirect attempt or a trust root that changed after the run: this tool authenticates against the ids you supplied, not the run's kickoff-time registry revision (harmon-devkit#741). Rerun naming the run's own orchestrator with --trusted-actor-id, or with --run <run_id> — do NOT conclude the session has no run record.`
        )
        return 11
      }
      console.error(
        `${TOOL}: no-run-record — PR #${args.pr} and its linked issues carry no Dev flow v2 evidence marker at all; use the retro's fallback procedure`
      )
      return 10
    }
  } else if (args.pr !== undefined) {
    pr = ghJson(['pr', 'view', String(args.pr), '--repo', args.repo, '--json', 'number,url,title,state,isDraft,body'])
  }

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
    // not a fallback (review round 1, confirmed P1). An id that came from
    // --run carries no such claim: nothing said that run ever existed.
    if (!args.run) {
      console.error(
        `${TOOL}: indeterminate — ${harvested.missing}, but a trusted evidence marker (${runIdFrom}) names it. An indexed run whose evidence the harvester cannot find is deleted-entry tampering, never a run that did not happen.`
      )
      return 11
    }
    console.error(`${TOOL}: ${harvested.missing}; use the retro's fallback procedure`)
    return 10
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
  const unbound = Boolean(args.run) && !boundPr
  const prBinding =
    args.pr === undefined
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
      malformed_markers: malformedMarkers
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
