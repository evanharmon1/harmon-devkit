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
  originRepository, repository, itemRepository, assertDispatchCapacity, checkSlateLock,
  Refusal, UsageError, assertRunOwner, currentPlan, laneInit, lanePolicyProjection,
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


// Resolve by verified origin identity, never by a directory's spelling. An
// explicit mapping is authoritative: a wrong/missing mapped clone is refused.
function targetClone(repo, mappings, conductor) {
  const mapped = new Map()
  for (const value of mappings ?? []) {
    const split = value.indexOf('=')
    if (split < 1 || !value.slice(split + 1)) throw new UsageError('--repo-root requires owner/repo=/path')
    const key = repository(value.slice(0, split))
    if (mapped.has(key)) throw new UsageError(`duplicate --repo-root for ${key}`)
    mapped.set(key, resolve(value.slice(split + 1)))
  }
  const matches = (path) => {
    try { return git(['rev-parse', '--show-toplevel'], path) === realpathSync(path) && originRepository(path) === repo }
    catch { return false }
  }
  if (mapped.has(repo)) {
    const path = mapped.get(repo)
    if (!matches(path)) throw new Refusal(`no matching clone for ${repo}: --repo-root origin does not match`)
    return realpathSync(path)
  }
  const parent = dirname(conductor)
  const candidates = [conductor, ...readdirSync(parent, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => join(parent, entry.name))]
  const found = [...new Set(candidates.filter(matches).map((path) => realpathSync(path)))]
  if (found.length !== 1) throw new Refusal(`expected one clone for ${repo}, found ${found.length}; supply --repo-root ${repo}=/path`)
  return found[0]
}

function provision(args) {
  monitor(['check-assets'])
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
  return withMutex(planFile, () => {
    const plan = currentPlan(root, slate)
    if (plan.repo !== undefined) plan.repo = repository(plan.repo)
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
    const targetRepo = itemRepository(plan, lane)
    const foreign = targetRepo !== undefined && targetRepo !== plan.repo
    const conductor = dirname(common)
    if (plan.repo !== undefined && originRepository() !== plan.repo) throw new Refusal('plan repo differs from conductor origin')
    const clone = foreign ? targetClone(targetRepo, args['repo-root'], conductor) : process.cwd()
    const worktreePath = resolve(facts.worktree_path)
    const createWorktree = foreign && !existsSync(worktreePath)
    if (createWorktree && worktreePath !== join(realpathSync(clone), '.worktrees', lane.lane)) {
      throw new Refusal(`new worktree for ${targetRepo} must be ${join(realpathSync(clone), '.worktrees', lane.lane)}`)
    }
    const targetCommon = git(['rev-parse', '--path-format=absolute', '--git-common-dir'], clone)
    const base = foreign ? plan.repository_bases?.find((entry) => repository(entry.repo) === targetRepo)?.base_sha ?? lane.base_sha : plan.base_sha
    if (!base) throw new Refusal(`foreign lane ${targetRepo} needs a recorded base_sha`)
    const worktree = createWorktree ? worktreePath : realpathSync(worktreePath)
    if (!createWorktree && (git(['rev-parse', '--show-toplevel'], worktree) !== worktree ||
        git(['rev-parse', '--path-format=absolute', '--git-common-dir'], worktree) !== targetCommon ||
        git(['branch', '--show-current'], worktree) !== lane.branch ||
        git(['rev-parse', 'HEAD'], worktree) !== base)) {
      throw new Refusal('facts.worktree_path must be the prepared lane branch at the validated plan base in this clone')
    }
    facts.worktree_path = worktree
    const grafts = git(['rev-parse', '--path-format=absolute', '--git-path', 'info/grafts'], clone)
    if (existsSync(grafts)) throw new Refusal('grafted history cannot prove the plan base')
    const defaultRef = git(['symbolic-ref', 'refs/remotes/origin/HEAD'], clone)
    const defaultBranch = defaultRef.replace(/^refs\/remotes\/origin\//, '')
    if (!defaultRef.startsWith('refs/remotes/origin/') || lane.branch === defaultBranch ||
        git(['rev-parse', `${defaultRef}^{commit}`], clone) !== base) {
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
    checkSlateLock({ root, slate, session: args.session, ownerToken: args['owner-token'] })
    assertDispatchCapacity(root, plan, lane, slate)
    if (createWorktree) {
      const parent = dirname(worktree)
      mkdirSync(parent, { recursive: true })
      if (realpathSync(parent) !== parent) throw new Refusal('target worktree parent must not be a symlink')
      git(['worktree', 'add', '-b', lane.branch, worktree, base], clone)
    }
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
  })
}

function main(argv) {
  const flags = new Set(['slate', 'session', 'owner-token', 'lane', 'facts', 'policy', 'nonce', 'at', 'repo-root'])
  return provision(parseFlags(argv, flags, new Set(), new Set(['repo-root'])))
}

if (realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url))) runCli(main)
