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
//   10  there is no retained evidence to start from; use the fallback
//       procedure. stderr names which of the three reasons applies:
//       `no-stats-script` (this checkout has no harvester — the ordinary case
//       in a consumer repo that has not vendored #663), `no-run-record` (no
//       evidence marker on the PR or its linked issues), or `run-not-found`
//       (a marker named a run the harvester cannot find).
//   11  evidence exists but is INDETERMINATE — a broken or forged chain, or
//       two different run ids on one PR. Nothing is rendered (there is no
//       trajectory to render); the reason is on stderr. Never report a clean
//       retro on this path, and never silently fall back to memory.
//   2   usage error.  1  operational error (a `gh` or harvester failure).
//
// Why 10 and 11 are different exits: "there is nothing to read" is the normal
// pre-v2 session and costs the retro only its evidence section, while "what is
// there does not authenticate" is a finding in its own right. Collapsing them
// would let tampered evidence read as an ordinary memory-based retro.

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'

const TOOL = 'retro-run-report'

const USAGE = `Usage: retro-run-report.mjs --repo <owner/repo> --pr <n> [options]

  --repo <owner/repo>          Required. The repository the run lives in.
  --pr <n>                     The session's PR. Required unless --run is given.
  --run <run_id>               Skip discovery and report on this run.
  --trusted-actor-id <id>      Repeatable. Trusted-orchestrator GitHub actor
                               ids, passed through to the harvester. Defaults
                               to the authenticated user's own actor id.
  --trusted-actors-file <path> A JSON {"trusted_actor_ids": [...]} document,
                               passed through to the harvester.
  --as-of <iso8601>            Reconstruct the run as of this instant.
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
function fetchComments(repo, number) {
  const pages = ghJson(['api', '--paginate', '--slurp', `repos/${repo}/issues/${number}/comments`])
  return Array.isArray(pages) ? pages.flat() : []
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
  if (explicit) {
    if (!existsSync(explicit)) {
      throw new UsageError(`--stats-script path does not exist: ${explicit}`)
    }
    return statsCommandFor(explicit)
  }
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
// comment OPENS with one marker line. Anchoring the match to the start of the
// comment body (harmon-devkit#752) is what stops a marker quoted inside prose
// — a real risk on a PR that discusses this protocol — from inventing a run.
const EVIDENCE_MARKER_RE = /^<!--\s+devflow:([a-z][a-z-]*)\s+v2\s+([^>]*?)-->/

const RUN_ID_ATTR_RE = /(?:^|\s)run_id=([^\s>]+)/

function runIdFromCommentBody(body) {
  if (typeof body !== 'string') return null
  const marker = EVIDENCE_MARKER_RE.exec(body.replace(/\r/g, '').replace(/^\s+/, ''))
  if (!marker) return null
  const runId = RUN_ID_ATTR_RE.exec(marker[2])
  return runId ? { kind: marker[1], runId: runId[1] } : null
}

function collectRunIds(comments) {
  const found = new Set()
  for (const comment of comments || []) {
    const hit = runIdFromCommentBody(comment && comment.body)
    if (hit) found.add(hit.runId)
  }
  return found
}

// Prefer the PR's own evidence comments over the issue's: a re-run posts a
// second run record on the same issue, so "which run is this PR's" is only
// answerable from PR-bound evidence. Fall back to the linked issues, which is
// where a run that capped before its PR existed keeps everything.
function discoverRun(args) {
  const pr = ghJson([
    'pr',
    'view',
    String(args.pr),
    '--repo',
    args.repo,
    '--json',
    'number,url,title,state,isDraft,body,closingIssuesReferences'
  ])
  const fromPr = [...collectRunIds(fetchComments(args.repo, pr.number))].sort()
  if (fromPr.length === 1) {
    return { pr, runId: fromPr[0], source: `evidence marker on PR #${pr.number}` }
  }
  if (fromPr.length > 1) {
    throw new IndeterminateError(
      `PR #${pr.number} carries evidence for more than one run (${fromPr.join(', ')}) — rerun with --run <run_id>`
    )
  }
  const issues = Array.isArray(pr.closingIssuesReferences) ? pr.closingIssuesReferences : []
  // Which issues carried a given run id, not just which ids exist: a run whose
  // record sits on a different issue than the reader expects is worth naming
  // in the report's provenance line rather than reducing to "an issue".
  const fromIssues = new Map()
  for (const issue of issues) {
    for (const runId of collectRunIds(fetchComments(args.repo, issue.number))) {
      const seen = fromIssues.get(runId) || new Set()
      seen.add(issue.number)
      fromIssues.set(runId, seen)
    }
  }
  if (fromIssues.size === 1) {
    const [runId, seen] = [...fromIssues.entries()][0]
    const where = [...seen].sort((a, b) => a - b).map((n) => `#${n}`).join(', ')
    return { pr, runId, source: `evidence marker on issue ${where}` }
  }
  if (fromIssues.size > 1) {
    throw new IndeterminateError(
      `the issues linked to PR #${pr.number} carry evidence for more than one run (${[...fromIssues.keys()].sort().join(', ')}) — rerun with --run <run_id>`
    )
  }
  return { pr, runId: null, source: null }
}

// ---------------------------------------------------------------------------
// Trusted actor ids
// ---------------------------------------------------------------------------

// The harvester trusts evidence only from a configured orchestrator actor id.
// agent-registry.json does not yet carry that allowlist (harmon-devkit#741 —
// its finders' trusted_actor_id names review bots, a different trust root
// entirely), so the honest default is the authenticated account: a retro is
// normally run by the same identity that orchestrated the run. A run driven by
// Foreman's service account needs --trusted-actor-id. The failure mode is
// fail-closed either way — the harvester rejects evidence it cannot attribute.
function resolveTrustedActorArgs(args) {
  const passthrough = []
  for (const id of args.trustedActorIds) passthrough.push('--trusted-actor-id', id)
  if (args.trustedActorsFile) passthrough.push('--trusted-actors-file', args.trustedActorsFile)
  if (passthrough.length > 0) return { passthrough, source: 'supplied on the command line' }
  const id = gh(['api', 'user', '--jq', '.id']).trim()
  if (!/^[1-9][0-9]*$/.test(id)) {
    throw new OperationalError(`could not resolve the authenticated actor id (got ${JSON.stringify(id)})`)
  }
  return { passthrough: ['--trusted-actor-id', id], source: `the authenticated account (actor id ${id})` }
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

// The caps a run was REVIEWED under are the ones its own PR disclosed, not
// whatever .devflow.toml says today: the config is edited between runs, and a
// retro that read the live file would silently rescore an old run against a
// budget it never had. So this parses the section render-dev-flow.mjs
// published, and reports the caps unknown rather than substituting a guess.
const POLICY_BEGIN = '<!-- dev-flow:begin:policy-disclosure -->'
const POLICY_END = '<!-- dev-flow:end:policy-disclosure -->'
const POLICY_LINE_RE =
  /^rigor:\s*`([^`]*)`\s*\(`([^`]*)`\)\s*→\s*challenge ≤(\d+), review ≤(\d+), integration (\d+), remediation (\d+), min_rounds (\d+)\s*$/

function readPolicyDisclosure(body) {
  if (typeof body !== 'string' || !body.includes(POLICY_BEGIN)) {
    return { present: false, reason: 'the PR body carries no dev-flow policy-disclosure section' }
  }
  // render-dev-flow.mjs refuses to publish a duplicated marker pair, so two of
  // them mean the body was hand-edited: which one governs is genuinely
  // unknowable, and picking the first would report a cap nobody chose.
  if (body.indexOf(POLICY_BEGIN) !== body.lastIndexOf(POLICY_BEGIN)) {
    return { present: false, reason: 'the PR body carries more than one policy-disclosure section' }
  }
  const start = body.indexOf(POLICY_BEGIN) + POLICY_BEGIN.length
  const end = body.indexOf(POLICY_END, start)
  if (end === -1) {
    return { present: false, reason: 'the PR body policy-disclosure section is not closed by its end marker' }
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
      reason: 'the PR body policy-disclosure section does not open with a parseable rigor line'
    }
  }
  return {
    present: true,
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

  return {
    stages,
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
        "the run trajectory's findings_by_class_and_provenance aggregates over the whole run, so this report's breakdown is run-wide",
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
  if (report.as_of) l.push(`- Reconstructed as of: ${safe(report.as_of)}`)
  l.push('')

  l.push('### Policy the run was reviewed under')
  l.push('')
  if (report.policy.present) {
    const r = report.policy.rounds
    l.push(
      `rigor: \`${safe(report.policy.rigor.level)}\` (\`${safe(report.policy.rigor.source)}\`) → challenge ≤${r.challenge}, review ≤${r.review}, integration ${r.integration}, remediation ${r.remediation}, min_rounds ${r.min_rounds}`
    )
    l.push('')
    l.push('Read from the PR body\'s published `policy-disclosure` section — the budget this run actually ran under, not the current `.devflow.toml`.')
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
      const cap = stage.cap === null ? 'no cap recorded' : `cap ${stage.cap}`
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
    l.push('')
  }

  l.push('### Findings by class and provenance')
  l.push('')
  if (report.measurements.findings_by_class_and_provenance.length === 0) {
    l.push('No findings recorded for this run.')
  } else {
    l.push('| class | provenance | count |')
    l.push('| --- | --- | --- |')
    for (const row of report.measurements.findings_by_class_and_provenance) {
      l.push(`| ${cell(row.class)} | ${cell(row.provenance)} | ${row.count} |`)
    }
    l.push('')
    l.push('`provenance` is the finding\'s own field: `original` (about the change) or `round:N` (about round N\'s fix of the same stage). A run whose later rounds are mostly `round:N` is a stage feeding on its own fixes.')
  }
  l.push('')

  l.push('### Overrides')
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
  }
  l.push('')

  l.push('### Interventions')
  l.push('')
  if (report.measurements.interventions.length === 0) {
    l.push('None — the run reached its outcome unattended.')
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

function run(argv) {
  const args = parseArgs(argv)
  if (args.help) {
    console.log(USAGE)
    return 0
  }
  validateArgs(args)

  const stats = resolveStatsCommand(args.statsScript)
  if (stats.missingReason) {
    console.error(
      `${TOOL}: no-stats-script — ${stats.missingReason}, so there is no retained run evidence to read; use the retro's fallback procedure`
    )
    return 10
  }

  let pr = null
  let runId = args.run || null
  let runIdFrom = args.run ? '--run on the command line' : null
  if (!runId) {
    try {
      const discovered = discoverRun(args)
      pr = discovered.pr
      runId = discovered.runId
      runIdFrom = discovered.source
    } catch (error) {
      if (!(error instanceof IndeterminateError)) throw error
      console.error(`${TOOL}: indeterminate — ${error.message}`)
      return 11
    }
    if (!runId) {
      console.error(
        `${TOOL}: no-run-record — PR #${args.pr} and its linked issues carry no Dev flow v2 evidence marker; use the retro's fallback procedure`
      )
      return 10
    }
  } else if (args.pr !== undefined) {
    pr = ghJson(['pr', 'view', String(args.pr), '--repo', args.repo, '--json', 'number,url,title,state,isDraft,body'])
  }

  const trusted = resolveTrustedActorArgs(args)
  let harvested
  try {
    harvested = harvestTrajectory(stats, args, runId, trusted)
  } catch (error) {
    if (!(error instanceof IndeterminateError)) throw error
    console.error(`${TOOL}: indeterminate — ${error.message}`)
    return 11
  }
  if (harvested.missing) {
    console.error(`${TOOL}: ${harvested.missing}; use the retro's fallback procedure`)
    return 10
  }

  const policy = readPolicyDisclosure(pr ? pr.body : null)
  const measurements = measure(harvested.trajectory, policy)
  const report = {
    schema: 'retro-run-report.v1',
    run_id: runId,
    as_of: args.asOf || null,
    source: { harvester: stats.display, run_id_from: runIdFrom, trusted_actors: trusted.source },
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
