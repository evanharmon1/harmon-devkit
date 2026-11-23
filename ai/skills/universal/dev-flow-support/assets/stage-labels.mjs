#!/usr/bin/env node
// Project committed run state onto GitHub. No GitHub read or write participates
// in committing a run record. `reconcile --record DIR` retries a lagging mirror.
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, realpathSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { itemKey, itemRepository, withMutex } from './run-record.mjs'

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
  const targets = [{ kind: 'issue', number, snapshot }]
  for (const candidate of candidates) {
    if (!Number.isSafeInteger(candidate) || candidate < 1) throw new Error('invalid delivery number')
    const pr = json(['pr', 'view', String(candidate), '--repo', repo, '--json', 'state,isCrossRepository,labels'])
    if (typeof pr.isCrossRepository !== 'boolean' || typeof pr.state !== 'string') throw new Error('invalid delivery snapshot')
    names(pr)
    if (pr.state === 'OPEN' && !pr.isCrossRepository) targets.push({ kind: 'pr', number: String(candidate), snapshot: pr })
  }
  const desired = snapshot.state === 'OPEN' ? desiredLabels(record, handedOff) : []
  // A handoff label already present is a safety backstop for solo handoffs and
  // partially completed lifecycle writes. Never add activity beside readiness.
  const handed = targets.some(({ snapshot: target }) => names(target).some((label) => ['parked', 'merge-ready'].includes(label)))
  const wanted = handed ? [] : desired
  for (const { kind, number: target, snapshot: before } of targets) {
    for (const label of names(before).filter((label) => managed(label) && !wanted.includes(label))) {
      github([kind, 'edit', target, '--repo', repo, '--remove-label', label])
    }
    for (const label of wanted.filter((label) => !names(before).includes(label))) {
      github([kind, 'edit', target, '--repo', repo, '--add-label', label])
    }
    const after = json([kind, 'view', target, '--repo', repo, '--json', 'labels'])
    if (JSON.stringify(names(after).filter(managed).sort()) !== JSON.stringify([...wanted].sort())) throw new Error(`label readback mismatch on ${kind} ${target}`)
  }
  return `stage labels reconciled: ${wanted.join(', ') || 'none'}`
}

export function reconcileRecord(directory, github = defaultGithub, { timeoutMs = 60000, maxAttempts = 3 } = {}) {
  const recordDir = resolve(directory)
  const root = dirname(dirname(recordDir))
  // This lock is independent of run.json's short write mutex. A record may
  // advance during network I/O; only fresh state read under this lock is used.
  return withMutex(join(recordDir, 'stage-labels'), () => {
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const recordBytes = readFileSync(join(recordDir, 'run.json'), 'utf8')
      const record = JSON.parse(recordBytes)
      const ownerBytes = readFileSync(join(recordDir, 'owner-slate'), 'utf8')
      const slate = ownerBytes.trim()
      if (!/^[A-Za-z0-9._-]+$/.test(slate) || ['.', '..'].includes(slate)) throw new Error('invalid owner slate')
      const planFile = join(root, 'slates', slate, 'plan.json')
      const planBytes = readFileSync(planFile, 'utf8')
      const plan = JSON.parse(planBytes).revisions.at(-1).plan
      const retained = plan.retained_lanes?.find((entry) => entry.lane.run_id === record.run_id)
      const lane = plan.lanes.find((entry) => entry.run_id === record.run_id) ?? retained?.lane
      if (!lane) throw new Error('run no longer owns a current lane; refusing stale projection')
      const issue = plan.issues.find((entry) => itemKey(plan, entry) === itemKey(plan, lane, 'issue'))
      if (!issue) throw new Error('run issue missing from plan')
      const repo = itemRepository(plan, issue)
      if (repo && !issue.url.toLowerCase().startsWith(`https://github.com/${repo}/issues/`)) throw new Error('run issue repository differs from URL')
      const result = reconcileLabels({ record, issue, branch: lane.branch, handedOff: retained !== undefined && retained.state !== 'working' }, github)
      if (readFileSync(join(recordDir, 'run.json'), 'utf8') === recordBytes &&
          readFileSync(join(recordDir, 'owner-slate'), 'utf8') === ownerBytes &&
          readFileSync(planFile, 'utf8') === planBytes) return result
    }
    throw new Error('projection state kept advancing; retry reconciliation against the newest run and plan')
  }, { timeoutMs })
}

export function projectRecordBestEffort(directory) {
  // A busy projection must not hold up another committed record write. Its
  // owner will re-read the advanced state; an explicit reconcile can also retry.
  try { return reconcileRecord(directory, defaultGithub, { timeoutMs: 0 }) } catch (error) {
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
