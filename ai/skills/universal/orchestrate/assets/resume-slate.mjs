#!/usr/bin/env node
// Read-only slate reconstruction. Output argv as JSON data, never shell text.
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import {
  currentPlan, itemRepository, parseFlags, readJson, requireId, stateRoot, validateFile,
} from '../../dev-flow-support/assets/run-record.mjs'

const assets = dirname(fileURLToPath(import.meta.url))
const optionalJson = file => existsSync(file) ? readJson(file, file) : null
const entries = dir => existsSync(dir) ? readdirSync(dir).sort() : []
const digest = branch => createHash('sha256').update(branch).digest('hex')

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
  const args = parseFlags(process.argv.slice(2), new Set(['slate', 'repo-root']), new Set())
  const slate = requireId('slate', args.slate)
  const repoRoot = execFileSync('git', ['-C', resolve(args['repo-root'] ?? process.cwd()),
    'rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  const { root } = stateRoot(repoRoot)
  const plan = currentPlan(root, slate)
  if (!plan) throw new Error(`no durable plan for slate ${slate}`)
  const result = { slate, lanes: [], undispatched: [], blockers: [], terminal_pointers: '', watcher: null }
  const specs = []
  const statusArgs = []
  const deadlines = []
  let registryRevision = null
  const retained = new Set((plan.retained_lanes ?? []).map(entry => entry.lane.run_id))
  const planned = [...plan.lanes, ...(plan.retained_lanes ?? []).map(entry => entry.lane)]
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
      const nonce = facts.sentinels.attempt_nonce
      const statusFile = join(runDir, `lane-status-${nonce}.json`)
      if (existsSync(statusFile)) {
        validateFile('lane-status', statusFile, statusFile)
        summary.lane_status = readJson(statusFile, statusFile)
        // Capture the same local branch ref the watcher uses; an unavailable
        // worktree or ref cannot attest even a schema-valid saved status.
        try {
          summary.local_branch_head = execFileSync('git', ['-C', resolve(facts.worktree_path),
            'rev-parse', '--verify', `refs/heads/${lane.branch}^{commit}`],
          { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
        } catch { /* Saved status remains historical evidence only. */ }
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
