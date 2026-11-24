#!/usr/bin/env node
// Project committed run state onto GitHub. No GitHub read or write participates
// in committing a run record. `reconcile --record DIR` retries a lagging mirror.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { itemKey, itemRepository, mutexHeld, withMutex } from './run-record.mjs'

export const STAGE_LABELS = ['implement', 'challenge', 'review', 'security', 'integration'].map((stage) => `stage:${stage}`)
export const ACTIVITY_LABELS = ['fixing', 'verifying']
const managed = (label) => label.startsWith('stage:') || ACTIVITY_LABELS.includes(label)
function defaultGithub(argv) {
  return execFileSync('gh', argv, { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'pipe'] })
}
const names = (snapshot) => {
  if (!Array.isArray(snapshot.labels) || snapshot.labels.some((label) => typeof label?.name !== 'string')) throw new Error('invalid label snapshot')
  return snapshot.labels.map((label) => label.name)
}

export function desiredLabels(record, handedOff = false) {
  if (handedOff || record.outcome !== null) return []
  let furthest = -1
  for (const { stage } of record.stage_transitions) {
    const index = ['implement', 'challenge', 'review', 'security', 'integration'].indexOf(stage === 'verify' ? 'implement' : stage)
    furthest = Math.max(furthest, index)
  }
  if (furthest < 0) return []
  const current = record.stage_transitions.at(-1).stage
  return [STAGE_LABELS[furthest], ...(current === 'verify' ? ['verifying'] : current === 'implement' && furthest > 0 ? ['fixing'] : [])]
}

// All discovery reads finish before writes. Every open same-repository closing
// link, branch-discovered Refs PR, and bound PR is included; fork PRs are skipped.
export function reconcileLabels({ record, issue, branch, handedOff = false }, github = defaultGithub) {
  const match = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/issues\/([1-9][0-9]*)\/?$/.exec(issue.url)
  if (!match || Number(match[2]) !== Number(String(issue.number).split('#').at(-1))) throw new Error('invalid issue identity')
  const [, repo, number] = match
  const json = (argv) => JSON.parse(github(argv))
  const snapshot = json(['issue', 'view', number, '--repo', repo, '--json', 'state,labels,closedByPullRequestsReferences'])
  names(snapshot)
  if (!Array.isArray(snapshot.closedByPullRequestsReferences)) throw new Error('invalid delivery links')
  const candidates = new Set(snapshot.closedByPullRequestsReferences.filter((pr) =>
    `${pr.repository?.owner?.login}/${pr.repository?.name}`.toLowerCase() === repo.toLowerCase()).map((pr) => pr.number))
  const listed = json(['pr', 'list', '--repo', repo, '--state', 'open', '--head', branch, '--limit', '1000', '--json', 'number,headRefName,isCrossRepository'])
  if (!Array.isArray(listed) || listed.length >= 1000) throw new Error('invalid or truncated delivery listing')
  for (const pr of listed) if (pr.headRefName === branch && pr.isCrossRepository === false) candidates.add(pr.number)
  if (record.pr) {
    const binding = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/([1-9][0-9]*)\/?$/.exec(record.pr.url)
    if (!binding || binding[1].toLowerCase() !== repo.toLowerCase() || Number(binding[2]) !== record.pr.number) throw new Error('invalid bound delivery identity')
    candidates.add(record.pr.number)
  }
  const targets = [{ kind: 'issue', number }]
  for (const candidate of candidates) {
    if (!Number.isSafeInteger(candidate) || candidate < 1) throw new Error('invalid delivery number')
    const pr = json(['pr', 'view', String(candidate), '--repo', repo, '--json', 'state,isCrossRepository,labels'])
    if (typeof pr.isCrossRepository !== 'boolean' || typeof pr.state !== 'string') throw new Error('invalid delivery snapshot')
    names(pr)
    if (pr.state === 'OPEN' && !pr.isCrossRepository) targets.push({ kind: 'pr', number: String(candidate) })
  }
  const refresh = () => targets.map(({ kind, number }) => {
    const { state, labels } = json([kind, 'view', number, '--repo', repo, '--json', 'state,labels'])
    if (state !== 'OPEN' && state !== 'CLOSED' && !(kind === 'pr' && state === 'MERGED')) throw new Error('invalid lifecycle state')
    return { state, labels: names({ labels }) }
  })
  const projected = desiredLabels(record, handedOff)
  const wanted = (current) => {
    const open = current.filter(({ state }) => state === 'OPEN')
    const ready = open.some(({ labels }) => labels.some((label) => ['parked', 'merge-ready'].includes(label.toLowerCase())))
    const shared = current[0].state === 'OPEN' && !ready ? projected : []
    return current.map(({ state }) => state === 'OPEN' ? shared : [])
  }
  let current = refresh()
  for (let attempt = 0; attempt < 3; attempt++) {
    const desired = wanted(current)
    for (const [index, { kind, number: target }] of targets.entries()) {
      const { labels } = current[index]
      for (const label of labels) {
        const normalized = label.toLowerCase()
        if (!managed(normalized) || desired[index].includes(normalized)) continue
        github([kind, 'edit', target, '--repo', repo, '--remove-label', label])
      }
      const applied = labels.map((label) => label.toLowerCase())
      for (const label of desired[index].filter((label) => !applied.includes(label))) {
        github([kind, 'edit', target, '--repo', repo, '--add-label', label])
      }
    }
    current = refresh()
    const expected = wanted(current)
    if (current.every(({ labels }, index) => {
      const applied = labels.map((label) => label.toLowerCase()).filter(managed).sort()
      return JSON.stringify(applied) === JSON.stringify([...expected[index]].sort())
    })) return `stage labels reconciled: ${[...expected[0]].sort().join(', ') || 'none'}`
  }
  throw new Error('label readback mismatch after bounded lifecycle repair')
}

function snapshot(directory, replacementOnly = false) {
  const recordDir = resolve(directory)
  const root = dirname(dirname(recordDir))
  const runPath = join(recordDir, 'run.json'), ownerPath = join(recordDir, 'owner-slate')
  if (replacementOnly && (!existsSync(runPath) || !existsSync(ownerPath))) return null
  const recordBytes = readFileSync(runPath, 'utf8'), record = JSON.parse(recordBytes)
  if (replacementOnly && record.outcome !== null) return null
  const ownerBytes = readFileSync(ownerPath, 'utf8')
  const slate = ownerBytes.trim()
  if (!/^[A-Za-z0-9._-]+$/.test(slate) || ['.', '..'].includes(slate)) throw new Error('invalid owner slate')
  const planBytes = readFileSync(join(root, 'slates', slate, 'plan.json'), 'utf8')
  const plan = JSON.parse(planBytes).revisions.at(-1).plan
  const retained = plan.retained_lanes?.find((entry) => entry.lane.run_id === record.run_id)
  const lane = plan.lanes.find((entry) => entry.run_id === record.run_id) ?? retained?.lane
  if (replacementOnly && (!lane || (retained && retained.state !== 'working'))) return null
  if (!lane) throw new Error('run no longer owns a current lane; refusing stale projection')
  const issue = plan.issues.find((entry) => itemKey(plan, entry) === itemKey(plan, lane, 'issue'))
  if (!issue) throw new Error('run issue missing from plan')
  const repo = itemRepository(plan, issue)
  if (repo && !issue.url.toLowerCase().startsWith(`https://github.com/${repo}/issues/`)) throw new Error('run issue repository differs from URL')
  return { root, record, issue, branch: lane.branch, handedOff: retained !== undefined && retained.state !== 'working', version: JSON.stringify([recordBytes, ownerBytes, planBytes]) }
}

function refuseReplacement({ root, record }, identity) {
  const runs = join(root, 'runs')
  for (const entry of readdirSync(runs, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name === record.run_id) continue
    const replacement = snapshot(join(runs, entry.name), true)
    if (replacement?.issue.url.toLowerCase().replace(/\/$/, '') === identity) {
      throw new Error(`replacement run ${replacement.record.run_id} owns this issue; refusing stale projection`)
    }
  }
}

export function reconcileRecord(directory, github = defaultGithub, { timeoutMs = 60000, maxAttempts = 3 } = {}) {
  const initial = snapshot(directory), identity = initial.issue.url.toLowerCase().replace(/\/$/, '')
  const locks = join(initial.root, 'stage-labels'); mkdirSync(locks, { recursive: true })
  // One qualified-issue lock spans run replacements; state writers never take it.
  return withMutex(join(locks, createHash('sha256').update(identity).digest('hex')), () => {
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const before = snapshot(directory)
      if (before.issue.url.toLowerCase().replace(/\/$/, '') !== identity) throw new Error('run issue identity changed')
      // A finished solo run's old plan can still list its lane after replacement.
      if (before.record.outcome !== null || before.handedOff) refuseReplacement(before, identity)
      const result = reconcileLabels(before, github)
      if (snapshot(directory).version === before.version) return result
    }
    throw new Error('projection state kept advancing; retry reconciliation against the newest run and plan')
  }, { timeoutMs })
}

export function projectRecordBestEffort(directory) {
  try {
    if (mutexHeld()) throw new Error('best-effort projection must run after every mutex callback returns')
    return reconcileRecord(directory, defaultGithub, { timeoutMs: 0 })
  } catch (error) {
    console.error(`stage-labels: record committed; projection failed: ${error.message}; retry stage-labels.mjs reconcile --record ${directory}`)
    return null
  }
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    const [command, flag, directory, ...extra] = process.argv.slice(2)
    if (command !== 'reconcile' || flag !== '--record' || !directory || extra.length) throw new Error('usage: stage-labels.mjs reconcile --record DIR')
    console.log(reconcileRecord(directory))
  } catch (error) { console.error(`stage-labels: ${error.message}`); process.exitCode = 1 }
}
