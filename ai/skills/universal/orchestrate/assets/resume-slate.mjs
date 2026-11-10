#!/usr/bin/env node
// Read-only slate reconstruction. Output argv as JSON data, never shell text.
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import {
  itemRepository, parseFlags, readJson, requireId, stateRoot, validateFile,
} from '../../dev-flow-support/assets/run-record.mjs'
import { authorizedCeiling } from '../../dev-flow-support/assets/lib/cap-authorizations.mjs'
import { effectiveFence } from '../../dev-flow-support/assets/plan-revise.mjs'

const assets = dirname(fileURLToPath(import.meta.url))
const optionalJson = file => existsSync(file) ? readJson(file, file) : null
const entries = dir => existsSync(dir) ? readdirSync(dir).sort() : []
const digest = branch => createHash('sha256').update(branch).digest('hex')

// ---------------------------------------------------------------------------
// Operational checkpoint (harmon-devkit#1893). A compact projection derived
// only from validated durable records. It never grants authority: every
// `next` is a provisional pointer that the orchestrator re-verifies against
// live gates, and history is summarised by counts plus links, never embedded.
// ---------------------------------------------------------------------------
const AUTHORITY = 'none: projection of durable records; re-verify live gates and the linked evidence before acting'
const MISSING = {
  pending_owner_actions: 'no durable source until #1891 records pending owner actions and waits',
  ownership_epoch: 'no durable source until #1890 records an ownership epoch',
  next_action_vocabulary: 'no durable source until #1892 defines the outcome and next-action vocabulary; `next.action` is provisional',
}
const missing = (source, reason) => ({ status: 'missing', source, reason })
const pathOf = entry => typeof entry === 'string' ? entry : entry?.path
const fenceItem = entry => ({ path: pathOf(entry), note: (typeof entry === 'object' && entry?.note) || '' })
const fenceItems = entries => entries.map(fenceItem).sort((a, b) => a.path.localeCompare(b.path) || a.note.localeCompare(b.note))
// The brief appends dispatch-time section notes to a planned note (`<plan note> — <extra>`),
// so a briefed note agrees with the plan when it equals it or extends it that way.
const noteAgrees = (planned, briefed) => planned === '' || briefed === planned || briefed.startsWith(`${planned} — `)
const fenceAgrees = (planned, briefed) => planned.length === briefed.length &&
  planned.every((item, index) => item.path === briefed[index].path && noteAgrees(item.note, briefed[index].note))
// Mirror lane-brief-values.mjs, which defaults breadth.max_in_flight to max_parallel_agents.
const normalizeBreadth = breadth => breadth && typeof breadth === 'object' && !Array.isArray(breadth)
  ? { ...breadth, max_in_flight: breadth.max_in_flight ?? breadth.max_parallel_agents } : breadth
// Run stages the lane status vocabulary cannot name; a lane at one of them reports `implement`.
const UNNAMED_BY_STATUS = new Set(['kickoff', 'claim', 'explore', 'plan'])
// Whether a saved status stage can describe the run's stage. A handoff status leads the run record:
// the lane reports integration before the owner records the transition out of security.
const stageAgrees = (runStage, status) => runStage === status.stage ||
  (UNNAMED_BY_STATUS.has(runStage) && status.stage === 'implement') ||
  (status.state === 'handoff' && status.stage === 'integration' && runStage === 'security')
const pinsDigest = pins => createHash('sha256').update(JSON.stringify(pins)).digest('hex')
// Key order is not meaning: compare through a sorted-key serialization so a reordered object is not a scope change.
const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value
const sameJson = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b))
const count = (dir, pattern = /./) => entries(dir).filter(name => pattern.test(name)).length

function adjudicatedRounds(runDir, stage) {
  const rounds = entries(join(runDir, 'adjudications'))
    .map(name => name.match(new RegExp(`^${stage}-r([0-9]+)\\.json$`))).filter(Boolean).map(match => Number(match[1]))
  return rounds.length === 0 ? 0 : Math.max(...rounds)
}

function stageBudget(run, runDir, stage, cap) {
  const used = adjudicatedRounds(runDir, stage)
  const source = `caps.${stage} (policy), run.json cap_authorizations, runs/<run>/adjudications/${stage}-r<n>.json`
  if (!Number.isInteger(cap)) return missing(source, 'no resolved cap')
  if (cap === 0) return { status: 'disabled', cap, source }
  const ceiling = authorizedCeiling(run, stage, cap)
  const remaining = Math.max(0, ceiling - used)
  return { cap, authorized_ceiling: ceiling, adjudicated_rounds: used, remaining, exhausted: remaining === 0, source }
}

const AGENT_RUNS_SOURCE = 'runs/<run>/monitor.json agent_run_budget'
function agentRunBudget(budget) {
  if (budget === undefined || budget === null) return missing(AGENT_RUNS_SOURCE, 'no agent-run reservation recorded')
  // A partial or malformed budget fails closed: never a number that could hide an exhausted condition.
  if (typeof budget !== 'object' || !Number.isSafeInteger(budget.max_agent_runs) || budget.max_agent_runs < 0 ||
      !Array.isArray(budget.reservations) ||
      !budget.reservations.every(entry => entry && typeof entry === 'object' && typeof entry.event === 'string' && Number.isSafeInteger(entry.ordinal))) {
    return missing(AGENT_RUNS_SOURCE, 'malformed agent_run_budget: needs an integer max_agent_runs and an array of reservations, each an object with a string event and an integer ordinal')
  }
  const reserved = budget.reservations.length
  return { max: budget.max_agent_runs, reserved, remaining: Math.max(0, budget.max_agent_runs - reserved), source: AGENT_RUNS_SOURCE }
}

// Operator pins are hoisted to the slate checkpoint; a lane carries a count and digest,
// and the pins themselves only when they differ from the slate's.
function lanePins(lane, slate) {
  const pins = Array.isArray(lane) ? lane : []
  const slatePins = Array.isArray(slate) ? slate : []
  const digest = pinsDigest(pins)
  const same = digest === pinsDigest(slatePins)
  return same ? { count: pins.length, digest, same_as_slate: true } : { count: pins.length, digest, same_as_slate: false, values: pins }
}

function buildCheckpoint(ctx, plan, planDoc, planFile, blockers) {
  const { summary, lane, run, runDir, monitor, facts, active, retained, retainedState } = ctx
  const profile = plan.lane_profiles?.find(entry => entry.lane === lane.lane)?.policy
  const policy = profile ?? retained?.policy ?? plan.policy
  const policySource = profile ? 'plan.lane_profiles' : retained ? 'plan.retained_lanes' : 'plan.policy'
  const caps = policy?.caps ?? {}
  const planItems = fenceItems(effectiveFence({ fence: lane.fence ?? [], expansions: lane.expansions ?? [] }))
  const plannedBase = lane.base_sha ?? plan.base_sha
  const baseSource = lane.base_sha ? 'plan.lanes[].base_sha' : 'plan.base_sha'
  const revisions = planDoc.revisions
  const transitions = run.stage_transitions
  const lastExited = [...transitions].reverse().find(entry => typeof entry.exit === 'string')
  const adjudicationFiles = count(join(runDir, 'adjudications'))
  const lockRecoveries = join(ctx.root, 'locks', 'recoveries', ctx.slate)
  const conditions = []
  const conflicts = []
  const condition = (kind, detail) => conditions.push({ kind, ...detail })
  const status = summary.lane_status
  const budgets = {
    challenge: stageBudget(run, runDir, 'challenge', caps.challenge),
    review: stageBudget(run, runDir, 'review', caps.review),
    integration: missing('caps.integration (policy)', 'integration cycles are counted by the checker and exit engine, not a durable record this view reads'),
    remediation: missing('caps.remediation (policy)', 'remediation pushes are counted by the exit engine, not a durable record this view reads'),
    agent_runs: agentRunBudget(monitor?.agent_run_budget),
  }
  // A stage that already exited is history, not a live constraint; only the current stage or one with no recorded exit can block.
  const stageExited = stage => transitions.some(entry => entry.stage === stage && typeof entry.exit === 'string')
  for (const stage of ['challenge', 'review']) {
    if (budgets[stage].exhausted && (summary.stage === stage || !stageExited(stage))) {
      condition('budget-exhausted', { stage, source: budgets[stage].source })
    }
  }
  if (budgets.agent_runs.remaining === 0) condition('budget-exhausted', { stage: 'agent-runs', source: budgets.agent_runs.source })
  const startedMs = Date.parse(run.started_at)
  const wallMinutes = caps.wall_clock_min
  const deadlineMs = Number.isFinite(startedMs) && Number.isFinite(wallMinutes) ? startedMs + wallMinutes * 60000 : null
  const nowMs = ctx.nowMs
  const wallClock = deadlineMs === null
    ? missing('run.json started_at + caps.wall_clock_min', 'no wall-clock ceiling resolved')
    : { started_at: run.started_at, wall_clock_min: wallMinutes, deadline: new Date(deadlineMs).toISOString().replace('.000Z', 'Z'),
      expired: run.outcome === null && nowMs > deadlineMs, source: 'run.json started_at + caps.wall_clock_min' }
  if (wallClock.expired) condition('wall-clock-expired', { deadline: wallClock.deadline })
  // Approval scope: the dispatch-time brief must still agree with the current plan.
  if (facts) {
    const compare = (field, planned, briefed) => { if (!sameJson(planned, briefed)) conflicts.push({ field, plan: planned, brief: briefed }) }
    compare('issue', lane.issue, facts.issue?.number)
    compare('base_sha', plannedBase, facts.base_sha)
    const briefItems = fenceItems(facts.fence ?? [])
    if (!fenceAgrees(planItems, briefItems)) conflicts.push({ field: 'fence', plan: planItems, brief: briefItems })
    compare('caps', caps, facts.caps)
    compare('role_tiers', policy?.role_tiers, facts.role_tiers)
    compare('breadth', normalizeBreadth(policy?.breadth), normalizeBreadth(facts.breadth))
    if (deadlineMs !== null && Date.parse(facts.deadline) !== deadlineMs) {
      conflicts.push({ field: 'deadline', plan: wallClock.deadline, brief: facts.deadline })
    }
  }
  if (conflicts.length > 0) condition('scope-changed', { fields: conflicts.map(entry => entry.field) })
  // Status disagreements are not approval-scope changes; they only void the saved status as a basis for `next`.
  // Stages are compared only when the status is newer than the run's last transition: an older status
  // predates the current stage and says nothing about it.
  const lastEntered = Date.parse(transitions.at(-1)?.entered_at)
  const stageDisagrees = Boolean(status) && Date.parse(status.updated_at) > lastEntered && !stageAgrees(summary.stage, status)
  const statusUnreliable = status && (summary.lane_status_freshness !== 'current' || stageDisagrees)
  if (status && summary.lane_status_freshness !== 'current') {
    conflicts.push({ field: 'lane_status.head', lane_status: status.head, local_branch: summary.local_branch_head, freshness: summary.lane_status_freshness })
  }
  if (stageDisagrees) {
    conflicts.push({ field: 'lane_status.stage', run: summary.stage, lane_status: status.stage })
    condition('status-stage-mismatch', { run: summary.stage, lane_status: status.stage })
  }
  const reservations = summary.unreconciled_reservations
  const heads = { lane_status: status?.head ?? null, local_branch: summary.local_branch_head }
  if (summary.lane_status_freshness === 'stale') condition('stale-head', { lane_status: heads.lane_status, local_branch: heads.local_branch })
  if (summary.lane_status_freshness === 'unverifiable') condition('unverifiable-head', { lane_status: heads.lane_status })
  for (const reservation of reservations) {
    if (summary.local_branch_head && reservation.expected_head !== summary.local_branch_head) {
      condition('stale-reservation', { event: reservation.event, expected_head: reservation.expected_head, local_branch: summary.local_branch_head })
    }
  }
  const blocked = blockers.filter(entry => entry.run_id === summary.run_id)
  for (const entry of blocked) condition('resume-blocked', { reason: entry.reason })
  const pending = []
  if (status?.state === 'decision-request') pending.push({ kind: 'decision-request', request_id: status.request_id, stage: status.stage, round: status.round, source: 'lane-status' })
  if (status?.state === 'blocked') pending.push({ kind: 'lane-blocked', stage: status.stage, round: status.round, summary: status.summary, source: 'lane-status' })
  for (const reservation of reservations) pending.push({ kind: 'unreconciled-reservation', event: reservation.event, action: reservation.action, expected_head: reservation.expected_head, source: 'monitor.json' })
  if (retainedState === 'pending') pending.push({ kind: 'retained-lane-pending-fix', source: 'plan.retained_lanes' })
  let next
  if (summary.outcome !== null) {
    next = summary.pr ? { action: 'observe-pr', detail: `run ended (${summary.outcome}); the bound PR keeps a retained watcher spec` }
      : { action: 'none', detail: `run ended (${summary.outcome})` }
  } else if (wallClock.expired) next = { action: 'report-deadline-blocker', detail: 'wall-clock ceiling passed' }
  else if (reservations.length > 0) next = { action: 'reconcile-reservation', detail: reservations.map(entry => entry.event).join(',') }
  else if (statusUnreliable) next = { action: 'verify-live-state', detail: 'saved lane status is stale, unverifiable or disagrees with run.json; re-read the live lane before acting' }
  else if (status?.state === 'decision-request') next = { action: 'answer-decision-request', detail: status.request_id }
  else if (status?.state === 'blocked') next = { action: 'resolve-blocker', detail: status.summary }
  else if (status?.state === 'handoff') next = { action: 'run-integration', detail: summary.pr ? `PR #${summary.pr.number}` : 'no PR bound yet' }
  else if (status?.state === 'done') next = { action: 'none', detail: 'lane reported done' }
  else if (status?.state === 'working') next = { action: 'await-lane', detail: `stage ${status.stage}, round ${status.round}` }
  else next = { action: 'unknown', detail: 'no lane status recorded' }
  next = { ...next, authority: 'none', vocabulary: 'provisional', requires_live_check: true, conditions: conditions.map(entry => entry.kind) }
  return {
    authority: AUTHORITY,
    evaluated_at: new Date(nowMs).toISOString().replace('.000Z', 'Z'),
    scope: { issue: lane.issue, wave: lane.wave, base_sha: plannedBase, base_sha_source: baseSource, fence: planItems, input: plan.input ?? null,
      plan_revision: { seq: revisions.at(-1).seq, digest: revisions.at(-1).digest, revisions: revisions.length }, source: 'plan.json' },
    constraints: { policy_source: policySource, rigor: policy?.rigor, caps, breadth: normalizeBreadth(policy?.breadth), parallel_cap: plan.dispatcher?.parallel_cap,
      role_tiers: policy?.role_tiers,
      operator_pins: lanePins(policy?.operator_pins, plan.policy?.operator_pins) },
    position: { stage: summary.stage, generation: summary.generation, branch: summary.branch, pr: summary.pr, retained_state: retainedState ?? null,
      heads, freshness: summary.lane_status_freshness, lane_status: status ? { state: status.state, seq: status.seq, stage: status.stage, round: status.round, updated_at: status.updated_at } : null },
    budgets,
    wall_clock: wallClock,
    last_completed: lastExited ? { stage: lastExited.stage, exit: lastExited.exit, entered_at: lastExited.entered_at, source: 'run.json stage_transitions' }
      : missing('run.json stage_transitions', 'no stage has exited yet'),
    pending_decisions: pending,
    conditions,
    conflicts,
    next,
    pending_owner_actions: missing('#1891', MISSING.pending_owner_actions),
    ownership_epoch: missing('#1890', MISSING.ownership_epoch),
    next_action_vocabulary: missing('#1892', MISSING.next_action_vocabulary),
    evidence: {
      plan: planFile, run: join(runDir, 'run.json'), policy: existsSync(join(runDir, 'policy.json')) ? join(runDir, 'policy.json') : null,
      monitor: monitor ? join(runDir, 'monitor.json') : null, brief: summary.brief,
      lane_status: status ? join(runDir, `lane-status-${facts.sentinels.attempt_nonce}.json`) : null,
      report: facts?.report_path ?? null, adjudications: existsSync(join(runDir, 'adjudications')) ? join(runDir, 'adjudications') : null,
      passes: existsSync(join(runDir, 'passes')) ? join(runDir, 'passes') : null,
      lock_recoveries: existsSync(lockRecoveries) ? lockRecoveries : null,
    },
    history: { stage_transitions: transitions.length, interventions: run.interventions?.length ?? 0, cap_authorizations: run.cap_authorizations?.length ?? 0,
      adjudication_files: adjudicationFiles, pass_files: count(join(runDir, 'passes')), plan_revisions: revisions.length, lock_recoveries: count(lockRecoveries) },
  }
}

function attemptBriefs(root, slate, runId, runDir) {
  const files = entries(runDir).filter(name => /^lane-brief-.+\.md$/.test(name)).map(name => join(runDir, name))
  const ownerDir = join(root, 'slates', slate, 'orchestrator', runId)
  for (const nonce of entries(ownerDir)) {
    const file = join(ownerDir, nonce, 'lane-brief.md')
    if (existsSync(file)) files.push(file)
  }
  return files
}

function briefFacts(file) {
  validateFile('brief', file, file)
  const body = readFileSync(file, 'utf8')
  const section = body.split('<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->')[1]
    .split('<!-- END SCHEMA-BOUND ENVELOPE FACTS -->')[0]
  return JSON.parse(section.match(/```json\s*([\s\S]*?)```/)[1])
}

function main() {
  const args = parseFlags(process.argv.slice(2), new Set(['slate', 'repo-root', 'now']), new Set())
  // Whole seconds, the precision `--now` accepts, so `evaluated_at` can always be passed back as `--now`.
  let nowMs = Math.floor(Date.now() / 1000) * 1000
  if (args.now !== undefined) {
    nowMs = Date.parse(args.now)
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(args.now) || !Number.isFinite(nowMs)) {
      throw new Error(`--now must be a UTC timestamp like 2026-10-11T12:00:00Z, got ${JSON.stringify(args.now)}`)
    }
  }
  const slate = requireId('slate', args.slate)
  const repoRoot = execFileSync('git', ['-C', resolve(args['repo-root'] ?? process.cwd()),
    'rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  const { root } = stateRoot(repoRoot)
  // One validated read: the scope, policy and revision metadata all come from this single document.
  const planFile = join(root, 'slates', slate, 'plan.json')
  if (!existsSync(planFile)) throw new Error(`no durable plan for slate ${slate}`)
  validateFile('plan', planFile, `slate ${slate}'s ${planFile}`)
  const planDoc = readJson(planFile, planFile)
  if (planDoc.slate_id !== slate) throw new Error(`${planFile} records slate_id ${JSON.stringify(planDoc.slate_id)}, not ${slate}`)
  const plan = Array.isArray(planDoc.revisions) ? planDoc.revisions.at(-1)?.plan : null
  if (!Array.isArray(plan?.issues) || !Array.isArray(plan?.lanes)) throw new Error(`plan has no readable issues and lanes: ${planFile}`)
  const result = { slate, lanes: [], undispatched: [], blockers: [], terminal_pointers: '', watcher: null }
  const contexts = []
  const specs = []
  const statusArgs = []
  const deadlines = []
  let registryRevision = null
  const retained = new Set((plan.retained_lanes ?? []).map(entry => entry.lane.run_id))
  const planned = [...plan.lanes, ...(plan.retained_lanes ?? []).map(entry => entry.lane)]
  const retainedEntries = new Map((plan.retained_lanes ?? []).map(entry => [entry.lane.run_id, entry]))
  for (const lane of planned) {
    const runId = requireId('run-id', lane.run_id)
    const runDir = join(root, 'runs', runId)
    const runFile = join(runDir, 'run.json')
    try {
      const activeFile = join(root, 'active', `${digest(lane.branch)}.json`)
      if (!existsSync(runFile)) {
        const active = entries(join(root, 'active')).filter(name => name.endsWith('.json'))
          .some(name => readJson(join(root, 'active', name), 'active pointer').run_id === runId)
        if (retained.has(runId) || entries(runDir).length > 0 ||
            entries(join(root, 'slates', slate, 'orchestrator', runId)).length > 0 || active) {
          throw new Error('missing run record with surviving dispatch evidence')
        }
        result.undispatched.push({ lane: lane.lane, run_id: runId })
        continue
      }
      validateFile('run', runFile, runFile)
      const run = readJson(runFile, runFile)
      if (run.run_id !== runId) throw new Error('run id differs from plan')
      if (readFileSync(join(runDir, 'owner-slate'), 'utf8').trim() !== slate) throw new Error('run belongs to another slate')
      const binding = readJson(join(runDir, 'branch.json'), 'branch binding')
      if (binding.version !== 1 || binding.run_id !== runId || binding.branch !== lane.branch) throw new Error('branch binding differs from plan')
      const active = optionalJson(activeFile)
      const generation = active?.run_id === runId ? active.generation : null
      if (run.outcome === null && (!active || active.run_id !== runId || active.branch !== lane.branch ||
          active.version !== 1 || !Number.isSafeInteger(generation) || generation < 1)) throw new Error('live run lacks a matching active generation')
      const monitor = optionalJson(join(runDir, 'monitor.json'))
      if (monitor && (monitor.version !== 1 || !Array.isArray(monitor.actions) ||
          monitor.actions.some(action => !['reserved', 'adopted', 'cancelled'].includes(action.state)))) throw new Error('invalid monitor state')
      const summary = { lane: lane.lane, run_id: runId, stage: run.stage_transitions.at(-1)?.stage,
        generation, branch: lane.branch, pr: run.pr, outcome: run.outcome,
        unreconciled_reservations: monitor?.actions.filter(action => action.state === 'reserved') ?? [],
        lane_status: null, lane_status_freshness: null, local_branch_head: null, brief: null }
      result.lanes.push(summary)
      const ctx = { summary, lane, run, runDir, monitor, facts: null, active, root, slate, nowMs,
        retained: retainedEntries.get(runId), retainedState: retainedEntries.get(runId)?.state }
      contexts.push(ctx)
      if (run.outcome === null || run.pr) {
        if (!active || active.version !== 1 || active.run_id !== runId || active.branch !== lane.branch ||
            !Number.isSafeInteger(generation) || generation < 1 || !/^[0-9a-f]{40}$/.test(active.registry_revision)) {
          throw new Error('watched run lacks a matching kickoff-pinned registry revision')
        }
        if (registryRevision !== null && registryRevision !== active.registry_revision) {
          throw new Error('watched runs have different kickoff-pinned registry revisions')
        }
        const git = (...argv) => execFileSync('git', ['--no-replace-objects', '-C', repoRoot, ...argv],
          { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
        if (existsSync(git('rev-parse', '--path-format=absolute', '--git-path', 'info/grafts'))) {
          throw new Error('grafted history cannot attest pinned registry')
        }
        if (git('cat-file', '-t', active.registry_revision) !== 'commit') throw new Error('registry revision is not a commit')
        JSON.parse(git('show', `${active.registry_revision}:agent-registry.json`))
        registryRevision = active.registry_revision
      }
      // Terminal runs with bound PRs still need a PR watch; other ended runs do not.
      if (run.outcome !== null) {
        if (run.pr) {
          const repo = new URL(run.pr.url).pathname.split('/').slice(1, 3).join('/')
          specs.push(`${lane.lane}:${run.pr.number}:retained:${repo}:pr`)
        }
        continue
      }
      const attempts = new Map()
      for (const file of attemptBriefs(root, slate, runId, runDir)) {
        const facts = briefFacts(file)
        if (facts.run_id !== runId || facts.branch !== lane.branch || facts.generation !== generation) continue
        if (resolve(facts.record_directory) !== runDir || resolve(facts.active_state_path) !== activeFile) throw new Error('brief paths differ from durable identity')
        const nonce = requireId('nonce', facts.sentinels.attempt_nonce)
        const previous = attempts.get(nonce)
        if (previous && JSON.stringify(previous.facts) !== JSON.stringify(facts)) throw new Error(`conflicting briefs for attempt ${nonce}`)
        attempts.set(nonce, { file, facts })
      }
      if (attempts.size !== 1) throw new Error(`expected one current-generation attempt, found ${attempts.size}; choose an attempt explicitly before re-arming`)
      const { file, facts } = [...attempts.values()][0]
      summary.brief = file
      ctx.facts = facts
      const nonce = facts.sentinels.attempt_nonce
      const statusFile = join(runDir, `lane-status-${nonce}.json`)
      // Capture the same local branch ref the watcher uses, with or without a saved
      // status; an unavailable worktree or ref cannot attest a status or a reservation.
      try {
        summary.local_branch_head = execFileSync('git', ['-C', resolve(facts.worktree_path),
          'rev-parse', '--verify', `refs/heads/${lane.branch}^{commit}`],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
      } catch { /* Unverifiable: saved status and reservations stay historical evidence only. */ }
      if (existsSync(statusFile)) {
        validateFile('lane-status', statusFile, statusFile)
        summary.lane_status = readJson(statusFile, statusFile)
        summary.lane_status_freshness = summary.local_branch_head === null ? 'unverifiable'
          : summary.lane_status.head.toLowerCase() === summary.local_branch_head ? 'current' : 'stale'
      }
      const repo = run.pr ? new URL(run.pr.url).pathname.split('/').slice(1, 3).join('/')
        : itemRepository(plan, lane) ?? new URL(facts.issue.url).pathname.split('/').slice(1, 3).join('/')
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo) || !/^[A-Za-z0-9_-]+$/.test(lane.lane) ||
          !/^[A-Za-z0-9_-]+$/.test(nonce) || lane.branch.includes(':')) throw new Error('lane cannot be represented by watcher spec')
      specs.push(`${lane.lane}:${lane.branch}:${nonce}:${repo}:cloud`)
      statusArgs.push('--status-file', `${lane.lane}=${statusFile}`)
      statusArgs.push('--status-root', `${lane.lane}=${resolve(facts.worktree_path)}`)
      if (run.pr) statusArgs.push('--pr', `${lane.lane}=${run.pr.number}`)
      deadlines.push(facts.deadline)
    } catch (error) {
      result.blockers.push({ lane: lane.lane, run_id: runId, reason: error.message })
    }
  }
  for (const ctx of contexts) {
    try {
      ctx.summary.checkpoint = buildCheckpoint(ctx, plan, planDoc, planFile, result.blockers)
    } catch (error) {
      // One lane's failure is that lane's blocker; the rest of the slate still reports.
      result.blockers.push({ lane: ctx.lane.lane, run_id: ctx.summary.run_id, reason: `checkpoint failed: ${error.message}` })
      ctx.summary.checkpoint = missing('operational checkpoint', `checkpoint failed: ${error.message}`)
    }
  }
  const lanes = result.lanes
  const built = lanes.map(entry => ({ lane: entry.lane, checkpoint: entry.checkpoint?.status === 'missing' ? null : entry.checkpoint }))
  result.checkpoint = {
    authority: AUTHORITY,
    evaluated_at: new Date(nowMs).toISOString().replace('.000Z', 'Z'),
    plan: { seq: planDoc.revisions.at(-1).seq, digest: planDoc.revisions.at(-1).digest, revisions: planDoc.revisions.length, source: planFile,
      base_sha: plan.base_sha, input: plan.input ?? null, rigor: plan.policy?.rigor, caps: plan.policy?.caps, breadth: normalizeBreadth(plan.policy?.breadth),
      parallel_cap: plan.dispatcher?.parallel_cap,
      operator_pins: { count: (plan.policy?.operator_pins ?? []).length, digest: pinsDigest(plan.policy?.operator_pins ?? []), values: plan.policy?.operator_pins ?? [] },
      merge_queue: plan.merge_queue ?? missing('plan.json merge_queue', 'no merge queue recorded') },
    lanes: lanes.length,
    undispatched: result.undispatched.map(entry => entry.lane),
    blocked: result.blockers.map(entry => ({ lane: entry.lane, reason: entry.reason })),
    pending_decisions: built.reduce((total, entry) => total + (entry.checkpoint?.pending_decisions.length ?? 0), 0),
    attention: [...built.flatMap(entry => (entry.checkpoint?.conditions ?? []).map(item => ({ lane: entry.lane, kind: item.kind }))),
      ...result.blockers.filter(entry => !built.some(item => item.lane === entry.lane && item.checkpoint)).map(entry => ({ lane: entry.lane, kind: 'resume-blocked' }))],
    next: built.map(entry => ({ lane: entry.lane, action: entry.checkpoint?.next.action ?? 'unknown' })),
    missing: Object.entries(MISSING).map(([field, reason]) => missing(field, reason)),
  }
  // Use the same terminal eligibility predicate as run-record prune; dry-run
  // does not acquire locks, retire pointers, or reconcile reservations.
  result.terminal_pointers = execFileSync('bash', [join(assets, 'dev-flow-monitor.sh'), 'prune', '--dry-run', '--repo-root', repoRoot],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  if (result.blockers.length === 0 && specs.length > 0) {
    const deadline = deadlines.sort().at(-1) ?? '1970-01-01T00:00:00Z'
    result.watcher = { executable: join(assets, 'lane-watch.sh'), argv: ['--registry',
      join(repoRoot, 'agent-registry.json'), '--registry-revision', registryRevision, '--state-file',
      join(root, 'slates', slate, 'lane-watch.state'), ...statusArgs, deadline, ...specs] }
  }
  console.log(JSON.stringify(result, null, 2))
  if (result.blockers.length > 0) process.exitCode = 1
}
try { main() } catch (error) {
  console.error(`resume-slate: ${error.message}`)
  process.exitCode = 1
}
