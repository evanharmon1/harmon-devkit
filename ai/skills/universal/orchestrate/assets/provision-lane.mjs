#!/usr/bin/env node
// Compose existing writers; never acquire a new slate lock or revise a plan.
// Usage: provision-lane.mjs --slate ID --session ID --owner-token TOKEN
//                         --lane ID --facts FILE --policy FILE --nonce NONCE [--at UTC]
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  Refusal, UsageError, acquireSlateLock, assertRunOwner, currentPlan, laneInit, lanePolicyProjection,
  parseFlags, readJson, requireId, resolveAt, runCli, stateRoot, validateFile, withMutex,
} from '../../dev-flow-support/assets/run-record.mjs'
import { assertDisjointFences, buildBriefValues, renderBrief, validateFacts } from './lane-brief-values.mjs'

const ASSETS = dirname(realpathSync(fileURLToPath(import.meta.url)))
const MONITOR = join(ASSETS, 'dev-flow-monitor.sh')

function git(args, cwd = process.cwd()) {
  try {
    return execFileSync('git', ['--no-replace-objects', ...args], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' } }).trim()
  } catch {
    throw new Refusal('could not verify the provisioned worktree or Git history')
  }
}

function monitor(args) {
  try {
    return execFileSync('bash', [MONITOR, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  } catch (error) {
    throw new Refusal(`monitor refused: ${String(error.stderr || '').trim() || `exit ${error.status}`}; inspect durable state before retrying`)
  }
}

// Capacity is a dispatch predicate, never a plan-coherence predicate. Historical
// lane assignments identify runs even after handoff retires their current lane.
// All provisioners in this clone hold the same mutex through activation.
function github(kind, url, fields) {
  try {
    return JSON.parse(execFileSync('gh', [kind, 'view', url, '--json', fields], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    }))
  } catch {
    throw new Refusal(`dispatch capacity is indeterminate: could not read ${kind} ${url}`)
  }
}

export function assertDispatchCapacity(root, candidatePlan, candidateLane) {
  const issues = new Map()
  const runs = new Map()
  const add = (issue) => {
    if (!issue || typeof issue.url !== 'string') throw new Refusal('dispatch capacity: missing issue identity')
    // Canonical issue URL binds the host, repository and issue number.
    const url = issue.url.replace(/\/$/, '')
    if (!issues.has(url)) issues.set(url, { url, prs: new Set(), dispatched: false })
    return issues.get(url)
  }
  const slates = join(root, 'slates')
  for (const entry of readdirSync(slates, { withFileTypes: true })) {
    if (!entry.isDirectory() || !existsSync(join(slates, entry.name, 'plan.json'))) continue
    const plan = currentPlan(root, entry.name)
    const document = readJson(join(slates, entry.name, 'plan.json'), 'dispatch plan')
    for (const revision of document.revisions) {
      for (const lane of revision.plan.lanes) {
        const issue = revision.plan.issues.find((issue) => issue.number === lane.issue)
        const prior = runs.get(lane.run_id)
        if (prior && prior.url !== issue.url) throw new Refusal(`dispatch capacity: ambiguous run ${lane.run_id}`)
        runs.set(lane.run_id, issue)
      }
    }
    for (const issue of plan.issues) {
      const bindings = [issue.pr, ...(plan.merge_queue ?? []).filter((item) => item.issue === issue.number).map((item) => item.pr)]
      if (bindings.some((pr) => pr !== undefined)) {
        const item = add(issue)
        for (const pr of bindings) if (pr !== undefined) item.prs.add(item.url.replace(/\/issues\/[^/]+$/, `/pull/${pr}`))
      }
    }
  }
  const runRoot = join(root, 'runs')
  if (existsSync(runRoot)) for (const entry of readdirSync(runRoot, { withFileTypes: true })) {
    const file = join(runRoot, entry.name, 'run.json')
    if (!entry.isDirectory() || !existsSync(file)) continue
    validateFile('run', file, 'dispatch run')
    const run = readJson(file, 'dispatch run')
    if (run.run_id !== entry.name) throw new Refusal(`dispatch capacity: run identity differs from ${entry.name}`)
    const issue = runs.get(entry.name)
    if (!issue) throw new Refusal(`dispatch capacity: run ${entry.name} has no durable plan issue binding`)
    const item = add(issue)
    item.dispatched = true
    if (run.pr !== null && run.pr !== undefined) {
      if (typeof run.pr.url !== 'string') throw new Refusal(`dispatch capacity: invalid PR binding for ${entry.name}`)
      item.prs.add(run.pr.url)
    }
  }
  // An active pointer without its run must never silently free a slot.
  const activeRoot = join(root, 'active')
  if (existsSync(activeRoot)) for (const name of readdirSync(activeRoot)) {
    if (!name.endsWith('.json')) continue
    const pointer = readJson(join(activeRoot, name), 'dispatch active pointer')
    requireId('run-id', pointer.run_id)
    if (!existsSync(join(runRoot, pointer.run_id, 'run.json'))) {
      throw new Refusal(`dispatch capacity: active run ${pointer.run_id} has no run record`)
    }
  }
  const candidate = add(candidatePlan.issues.find((issue) => issue.number === candidateLane.issue))
  const working = new Set([candidate.url])
  const inFlight = new Set([candidate.url])
  for (const item of issues.values()) {
    const state = github('issue', item.url, 'labels,state')
    if (!state || !['OPEN', 'CLOSED'].includes(state.state) || !Array.isArray(state.labels) ||
        state.labels.some((label) => !label || typeof label.name !== 'string')) {
      throw new Refusal(`dispatch capacity: invalid issue state for ${item.url}`)
    }
    if (item === candidate && state.state !== 'OPEN') throw new Refusal('dispatch candidate issue is closed')
    if (item.dispatched && state.labels.some((label) => label.name.startsWith('claim:'))) {
      working.add(item.url)
      inFlight.add(item.url)
    }
    for (const url of item.prs) {
      const pr = github('pr', url, 'state')
      if (!pr || !['OPEN', 'CLOSED', 'MERGED'].includes(pr.state)) throw new Refusal(`dispatch capacity: invalid PR state for ${url}`)
      if (pr.state === 'OPEN') inFlight.add(item.url)
    }
  }
  const breadth = (candidatePlan.lane_profiles?.find((profile) => profile.lane === candidateLane.lane)?.policy ?? candidatePlan.policy).breadth
  const parallel = Math.min(breadth.max_parallel_agents, candidatePlan.dispatcher.parallel_cap)
  const flight = breadth.max_in_flight ?? breadth.max_parallel_agents
  const counts = `working ${working.size}, in-flight ${inFlight.size} (including candidate #${candidateLane.issue})`
  if (working.size > parallel) throw new Refusal(`dispatch exceeds max_parallel_agents ${parallel}: ${counts}`)
  if (inFlight.size > flight) throw new Refusal(`dispatch exceeds max_in_flight ${flight}: ${counts}`)
  return { working: working.size, in_flight: inFlight.size }
}

function provision(args) {
  const slate = requireId('slate', args.slate)
  requireId('session', args.session)
  requireId('lane', args.lane)
  requireId('nonce', args.nonce)
  if (!args.facts) throw new UsageError('--facts is required')
  const at = resolveAt(args.at)
  const { common, root } = stateRoot()
  const planFile = join(root, 'slates', slate, 'plan.json')
  if (!existsSync(planFile)) throw new Refusal(`no plan for slate ${slate}`)
  // Also serializes a concurrent plan-revise; no candidate is dispatched from
  // a plan snapshot superseded while its brief was being built.
  return withMutex(join(root, 'dispatch'), () => withMutex(planFile, () => {
    const plan = currentPlan(root, slate)
    const lane = plan.lanes.find((entry) => entry.lane === args.lane)
    if (!lane) throw new Refusal(`unknown lane ${args.lane} in the last validated plan revision`)
    requireId('run-id', lane.run_id)
    const runDir = join(root, 'runs', lane.run_id)
    if (existsSync(join(runDir, 'run.json'))) throw new Refusal(`${runDir}/run.json already exists`)
    if (existsSync(runDir) && readdirSync(runDir).length) throw new Refusal(`${runDir} already contains state; inspect before provisioning`)
    assertRunOwner(root, slate, lane.run_id)
    assertDisjointFences(plan, lane)
    lanePolicyProjection(plan, lane, args.policy)
    const facts = readJson(args.facts, 'lane facts')
    validateFacts(facts)
    const worktree = realpathSync(facts.worktree_path)
    if (git(['rev-parse', '--show-toplevel'], worktree) !== worktree ||
        git(['rev-parse', '--path-format=absolute', '--git-common-dir'], worktree) !== common ||
        git(['branch', '--show-current'], worktree) !== lane.branch ||
        git(['rev-parse', 'HEAD'], worktree) !== plan.base_sha) {
      throw new Refusal('facts.worktree_path must be the prepared lane branch at the validated plan base in this clone')
    }
    facts.worktree_path = worktree
    const grafts = git(['rev-parse', '--path-format=absolute', '--git-path', 'info/grafts'])
    if (existsSync(grafts)) throw new Refusal('grafted history cannot prove the plan base')
    const defaultRef = git(['symbolic-ref', 'refs/remotes/origin/HEAD'])
    const defaultBranch = defaultRef.replace(/^refs\/remotes\/origin\//, '')
    if (!defaultRef.startsWith('refs/remotes/origin/') || lane.branch === defaultBranch ||
        git(['rev-parse', `${defaultRef}^{commit}`]) !== plan.base_sha) {
      throw new Refusal('target tracking head differs from the plan base, or lane names the default branch; recompute the plan first')
    }
    const revision = git(['log', '-1', '--format=%H', plan.base_sha, '--', ':(top)agent-registry.json'])
    if (!/^[0-9a-f]{40}$/.test(revision)) throw new Refusal('plan base has no governing registry revision')
    const active = monitor(['active-path', '--branch', lane.branch])
    const activationOutput = monitor(['check-activation', '--branch', lane.branch, '--run-id', lane.run_id])
    let activationPredecessor
    try {
      activationPredecessor = JSON.parse(activationOutput)
    } catch {
      throw new Refusal('activation preflight returned an invalid predecessor snapshot')
    }
    if (!activationPredecessor || activationPredecessor.run_id !== null || activationPredecessor.generation !== 0 ||
        existsSync(active)) {
      throw new Refusal(`branch ${lane.branch} already has an active pointer; inspect terminal pointers with run-record.mjs prune --dry-run before provisioning`)
    }
    const directory = monitor(['orchestrator-dir', '--slate-id', slate, '--run-id', lane.run_id, '--nonce', args.nonce])
    if (existsSync(directory)) throw new Refusal('orchestrator attempt directory already exists')
    const generation = 1
    const { values, envelope } = buildBriefValues({ plan, lane, facts, nonce: args.nonce, at, generation, active, runDir, defaultBranch })
    const brief = renderBrief(join(ASSETS, 'lane-brief.md'), resolve(ASSETS, '..', 'SKILL.md'), values)
    // All validators and refusable input checks precede any durable write.
    const temporary = mkdtempSync(join(tmpdir(), 'provision-lane-'))
    try {
      const candidate = join(temporary, 'brief.md')
      writeFileSync(candidate, brief)
      validateFile('brief', candidate, 'rendered lane brief')
    } finally {
      rmSync(temporary, { recursive: true, force: true })
    }
    if (!existsSync(join(root, 'locks', `${slate}.json`))) throw new Refusal('slate must already be reserved with lock acquire')
    acquireSlateLock({ root, slate, session: args.session, ownerToken: args['owner-token'] })
    assertDispatchCapacity(root, plan, lane)
    laneInit({ slate, session: args.session, 'owner-token': args['owner-token'], lane: lane.lane, policy: args.policy, at })
    const activated = monitor(['activate', '--active-state', active, '--run-id', lane.run_id, '--branch', lane.branch,
      '--expected-predecessor', 'absent', '--expected-generation', '0',
      '--registry-revision', revision, '--writer', 'feature-owner'])
    if (activated !== String(generation)) throw new Refusal('activation generation differs from the validated brief')
    const state = monitor(['state-path', '--run-id', lane.run_id])
    monitor(['reserve-agent-run', '--state', state, '--event', `dispatch-${lane.lane}-${args.nonce}`,
      '--max-agent-runs', String(envelope.breadth.max_agent_runs), '--writer', 'feature-owner',
      '--active-state', active, '--run-id', lane.run_id, '--branch', lane.branch, '--generation', String(generation)])
    // orchestrator-dir is deliberately the sole resolver of this layout.
    // mkdir is performed only after the complete brief passed validation.
    mkdirSync(directory, { recursive: true })
    const briefPath = join(directory, 'lane-brief.md')
    writeFileSync(briefPath, brief, { flag: 'wx' })
    validateFile('brief', briefPath, 'published lane brief')
    return JSON.stringify({ run_id: lane.run_id, branch: lane.branch, generation,
      active_state_path: active, record_directory: runDir, brief_path: briefPath, report_path: envelope.report_path })
  }))
}

function main(argv) {
  const flags = new Set(['slate', 'session', 'owner-token', 'lane', 'facts', 'policy', 'nonce', 'at'])
  return provision(parseFlags(argv, flags, new Set()))
}

if (realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url))) runCli(main)
