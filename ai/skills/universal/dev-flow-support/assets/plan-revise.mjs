#!/usr/bin/env node
// plan-revise.mjs — the mechanical half of a dispatch-plan recompute
// (`<git-common-dir>/dev-flow-v2/slates/<slate-id>/plan.json`,
// harmon-devkit#1296).
//
// Usage:
//   plan-revise.mjs genesis --slate ID --session ID --owner-token TOKEN --input PLAN --reason TEXT
//   plan-revise.mjs add-issue --slate ID --session ID --input ADDITION [--policy RESOLVED_JSON_FILE] --reason TEXT
//   plan-revise.mjs replace-unprovisioned --slate ID --session ID --lane ID --run-id FRESH --policy FILE --reason TEXT
//   plan-revise.mjs overlap --slate ID --session ID --owner-token TOKEN --lane-a ID --lane-b ID --path PATH... --resolution serialize|split --before N --after N --reason TEXT
//   plan-revise.mjs expand --slate ID --session ID --lane ID --path PATH --reason TEXT
//   plan-revise.mjs release --slate ID --session ID --issue N --lane ID --path PATH... --reason TEXT
//   plan-revise.mjs done --slate ID --session ID --issue N --reason TEXT [--input DECISIONS] [--policy RESOLVED_JSON_FILE]
//   plan-revise.mjs fix-request --slate ID --session ID --issue N --reason TEXT
//   plan-revise.mjs reactivate --slate ID --session ID --issue N [--run-id FRESH] --reason TEXT
//   plan-revise.mjs handoff --slate ID --session ID --issue N --pr N --reason TEXT [--expected-revision N]
//   plan-revise.mjs wave-release --slate ID --session ID --wave N --reason TEXT
//   plan-revise.mjs queue-order --slate ID --session ID --input ORDER --reason TEXT
// Selectors accept --repo owner/repo; omitted means the conductor repository.
// Queue-order input: {issues: [N, "owner/repo#N", ...]}, a permutation of the current queue.
// All commands accept --at TS; writes after genesis require the held owner token.
// Genesis input is planContent, including optional input provenance from slate-input.mjs.
// Its input field is retained in every complete revision snapshot.
// Overlaps supply resolution/dependency decisions;
// paths are computed. It requires a held reservation and never acquires a lock.
// Addition input: {issue, lane, repository_base?: {repo, base_sha}, overlaps?: [...], waves?: [...]}.
// With --policy, derive the profile from resolved-policy JSON; otherwise the
// addition must include the legacy profile: {lane, policy}.
// Replacement atomically updates the run/profile before the old run directory exists.
// Done/release input: {releases?: [{lane, paths}], addition?: ADDITION, waves?: [...]}.
// A newly introduced receiver uses addition; existing receivers gain dated expansions.
// Optional waves are the operator's complete placement decision; no wave is guessed.
//   plan-revise.mjs base-move --slate ID --session ID --new-base SHA --reason TEXT
//                             [--repo owner/name] [--repo-root PATH] [--input VERIFICATIONS]
//                             [--done N]... [--reverified N]... [--at TS] [--milestone N] [--issues N,N,...]
//
// Writes require --owner-token TOKEN; follow the shared caller contract at
// ../SKILL.md#owner-token-caller-contract.
//
// Appends one revision for a default-branch move: `base_sha` becomes the new
// base, every `--done` issue keeps its verified record as `verdict: "done"`
// (orchestrate § Planning step 2: never erase a verdict) and is removed from
// waves, lanes, lane_profiles, overlaps and merge_queue.
// Waiting handed-off successors are queued when their predecessors complete.
// An emptied wave is dropped, with later waves renumbered in order. The
// revision is chained (seq, prev_digest, digest over the canonical
// {seq, plan, at, reason, prev_digest}) and published through the candidate,
// `validate-result-schemas.mjs plan`, rename, readback sequence.
//
// Base-move input: {lanes: [{lane, status: "caught-up", sha: SHA40},
//                          {lane, status: "catch-up-owed"}]}. Owner-token authenticated
// decisions cover only named, touched provisioned lanes and are retained in reason.
// Without that input the mechanical default refuses those collisions.
// --reverified N records a read-only re-verification of a colliding live issue
// whose planned lane has no run directory; it preserves its fence and candidates.
// Handed-off issues are excluded from the live set below: their candidate
// paths do not block a base move, and eligible waiting handoffs queue mechanically.
// Everything that is orchestrator judgment is refused, naming what needs it,
// rather than written:
//   - the commits between the old and new base touch a live lane's effective
//     fence (fence + expansions) or a live issue's candidate files — the lane
//     may need a rebase, a fence change, or a re-verification;
//   - a done issue releases a dependent — a live issue lists it in
//     `blocked_by`, or an overlap's merge dependency names it as `before` —
//     because releasing a live dispatch dependent needs a wave decision;
//   - a live fence or candidate pattern has a component combining a bracket
//     class with `*`/`?`, or holding a backslash — such a pattern is never
//     interpreted here, so any move needs judgment;
//   - the new base does not descend from the old one, or nothing moved;
//   - the repository has an info/grafts file (replace refs are ignored).
// The existing plan is validated before anything else, so a broken chain is
// refused too. Mutations authenticate the held slate lock (see run-record.mjs).
//
// Exit codes: 0 written, 1 refused, 2 usage.

import { execFileSync } from 'node:child_process'
import { validateResolvedPolicy } from './devflow-policy.mjs'
import { pathMatches } from './lib/fence-match.mjs'
export { pathMatches } from './lib/fence-match.mjs'
import { createHash, randomBytes } from 'node:crypto'
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  Refusal,
  planPolicy,
  assertDispatchCapacity,
  planGraph, planWire, issueKey, itemKey, itemRepository, originRepository, repository,
  UsageError,
  acquireSlateLock,
  chainDigest,
  isBefore,
  parseFlags,
  parseScopeFlags,
  readJson,
  requireId,
  resolveAt,
  runCli,
  stateRoot,
  validateFile,
  withMutex,
  writeValidated,
} from './run-record.mjs'

// New revision inputs require a complete current policy; the shared projector
// also serves solo-init's historical merge-base migration policies.
function readPlanPolicy(policyFile, operatorPins = []) {
  const policy = readJson(policyFile, '--policy')
  try { validateResolvedPolicy(policy) }
  catch (error) { throw new Refusal(`--policy is not a complete resolved policy projection: ${error.message}`) }
  return planPolicy(policy, { operatorPins })
}

// The caller owns the slate lock. GitHub writes are deliberately reconciled
// after the validated plan is durable; `membership` retries an interrupted
// publication from the complete revision history.
function membershipIssues(plan) {
  return (plan?.issues ?? []).filter((issue) => issue.verdict !== 'done')
}

function membershipKey(issue) { return issue.url.toLowerCase() }

function membershipBody(session, slate, action) {
  return `Slate membership:\n- session: ${session}\n- slate: ${slate}\n- action: ${action}`
}

function claimHelperPath(kind) {
  const supportDir = dirname(fileURLToPath(import.meta.url))
  const relative = kind === 'release'
    ? '../../track-work/assets/release-claim.sh'
    : '../../claim/assets/claim-transaction.sh'
  return join(supportDir, relative)
}

function issueCoordinates(issue) {
  const match = /^https:\/\/github\.com\/([a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\/issues\/([1-9][0-9]*)\/?$/.exec(issue.url)
  const plannedNumber = Number(String(issue.number).split('#').at(-1))
  if (!match || Number(match[2]) !== plannedNumber) throw new Refusal(`claim lifecycle: unsupported issue identity ${issue.url}`)
  return { repo: match[1], number: match[2] }
}

function releaseClaimForHandoff(issue, lane, pr, reason) {
  const { repo, number } = issueCoordinates(issue)
  const idempotencyKey = createHash('sha256')
    .update(JSON.stringify({ repo: repo.toLowerCase(), issue: number, branch: lane.branch, pr }))
    .digest('hex')
  const releaseReason = `plan-revise handoff PR #${pr} branch ${lane.branch} key=${idempotencyKey}; ${reason}`
  try {
    execFileSync(claimHelperPath('release'), [
      '--repo', repo, '--issue', String(number), '--reason', releaseReason,
      '--branch', lane.branch, '--idempotency-key', idempotencyKey,
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  } catch (error) {
    const detail = error.stderr?.toString().trim() || error.message
    // Exit 3 is not generally success: branch mismatch, a superseded claim,
    // and a ground shift must remain visible. Only the helper's exact
    // no-trusted-claim/no-live-markers result is a legitimate no-op handoff.
    if (!(error.status === 3 && detail.includes('has no trusted claim comment — nothing to release'))) {
      throw new Refusal(`handoff claim release failed for ${repo}#${number}: ${detail}`)
    }
  }
  // The helper may preserve claim labels it does not own. Handoff only frees
  // Working capacity once the live issue has no claim marker, regardless of
  // whether the helper released a claim or reported a legitimate no-op.
  let response
  try {
    response = JSON.parse(execFileSync('gh', ['api', `repos/${repo}/issues/${number}`], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    }))
  } catch (error) {
    throw new Refusal(`handoff claim verification failed for ${repo}#${number}: ${error.stderr?.toString().trim() || error.message}`)
  }
  if (!response || !Array.isArray(response.labels) || response.labels.some((label) => !label || typeof label.name !== 'string')) {
    throw new Refusal(`handoff claim verification failed for ${repo}#${number}: malformed issue labels response`)
  }
  const remaining = response.labels.find((label) => label.name.startsWith('claim:'))
  if (remaining) throw new Refusal(`handoff claim verification failed for ${repo}#${number}: ${remaining.name} remains`)
}

function restoreClaimForReactivation(issue, lane, args) {
  const required = ['claim-record-file', 'claim-label', 'family', 'registry-snapshot']
  const supplied = required.filter((flag) => args[flag] !== undefined)
  if (supplied.length !== required.length) {
    throw new Refusal(`reactivation requires ${required.map((flag) => `--${flag}`).join(', ')} from the claim resolver`)
  }
  if (args['model-label'] === undefined) throw new Refusal('reactivation requires --model-label (use none when no refinement is owned)')
  let recordFirstLine
  try { recordFirstLine = readFileSync(args['claim-record-file'], 'utf8').split(/\r?\n/, 1)[0] }
  catch (error) { throw new Refusal(`reactivation claim record could not be read: ${error.message}`) }
  const recordedBranch = /^Claiming — starting implementation on branch (.*) \(session .*\)\.$/.exec(recordFirstLine)?.[1]
  if (recordedBranch !== lane.branch) {
    throw new Refusal(`reactivation claim record branch ${recordedBranch ?? '(unreadable)'} does not match retained lane branch ${lane.branch}`)
  }
  const { repo, number } = issueCoordinates(issue)
  const helperArgs = [
    '--repo', repo, '--issue', String(number), '--record-file', args['claim-record-file'],
    '--claim-label', args['claim-label'], '--model-label', args['model-label'],
    '--family', args.family, '--registry-snapshot', args['registry-snapshot'],
  ]
  if (args['runtime-environment'] !== undefined) helperArgs.push('--runtime-environment', args['runtime-environment'])
  if (args['allow-label-less'] === true) helperArgs.push('--allow-label-less')
  if (args['approve-review-pullback'] === true) helperArgs.push('--approve-review-pullback')
  try {
    execFileSync(claimHelperPath('transaction'), helperArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  } catch (error) {
    const detail = error.stderr?.toString().trim() || error.message
    throw new Refusal(`reactivation claim restoration failed for ${repo}#${number}: ${detail}`)
  }
}

const viewerLogins = new WeakMap()

function trustedActors() {
  let root
  try { root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim() }
  catch { return new Set() }
  const registry = join(root, 'agent-registry.json')
  return new Set(existsSync(registry) ? (readJson(registry, 'agent registry').trusted_orchestrator_actor_ids ?? []) : [])
}

function activeMemberships(comments, trustedActorIds, viewerLogin) {
  const states = new Map()
  for (const comment of comments) {
    const match = /^Slate membership:\n- session: ([A-Za-z0-9._-]+)\n- slate: ([A-Za-z0-9._-]+)\n- action: (add|remove)\s*$/.exec(comment.body ?? '')
    if (!match) continue
    const id = comment.user?.id
    const isViewer = viewerLogin !== undefined && comment.user?.login === viewerLogin
    const trusted = isViewer || (comment.author_association !== undefined
      ? ['OWNER', 'MEMBER', 'COLLABORATOR'].includes(comment.author_association) || trustedActorIds.has(id)
      : id !== undefined ? trustedActorIds.has(id)
        : !comment.user)
    if (!trusted) continue
    const key = `${match[1]}\0${match[2]}`
    states.set(key, match[3] === 'add')
  }
  return states
}

function githubIssue(issue) {
  const match = /^https:\/\/github\.com\/([a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\/issues\/([1-9][0-9]*)\/?$/.exec(issue.url)
  if (!match) throw new Refusal(`membership: unsupported issue URL ${issue.url}`)
  return { repo: match[1], number: match[2] }
}

function gh(args) {
  try { return execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }) }
  catch (error) { throw new Refusal(`membership: GitHub operation failed: ${error.stderr?.toString().trim() || error.message}`) }
}

function localOtherMembership(root, slate, issue) {
  const dir = join(root, 'slates')
  if (!existsSync(dir)) return false
  for (const other of readdirSync(dir)) {
    if (other === slate) continue
    if (!existsSync(join(root, 'locks', `${other}.json`))) continue
    const file = join(dir, other, 'plan.json')
    if (!existsSync(file)) continue
    validateFile('plan', file, `membership plan ${other}`)
    const doc = readJson(file, 'membership plan')
    if (membershipIssues(doc.revisions.at(-1)?.plan).some((item) => membershipKey(item) === membershipKey(issue))) return true
  }
  return false
}

function recoveredSessions(root, slate, session) {
  const predecessors = new Set()
  const lockFile = join(root, 'locks', `${slate}.json`)
  const currentOwner = existsSync(lockFile) ? readJson(lockFile, 'slate lock').session : session
  const sessionsDir = join(root, 'locks', 'sessions', slate)
  if (currentOwner === session && existsSync(sessionsDir)) {
    for (const prior of readdirSync(sessionsDir)) if (prior !== session) predecessors.add(prior)
  }
  const dir = join(root, 'locks', 'recoveries', slate)
  if (!existsSync(dir)) return predecessors
  const edges = readdirSync(dir).filter((name) => name.endsWith('.json')).map((name) => readJson(join(dir, name), 'lock recovery'))
    .filter((audit) => audit.action === 'force-release' && (audit.lock?.slate_id ?? slate) === slate && typeof audit.lock?.session === 'string' && typeof audit.session === 'string')
  const visited = new Set([session])
  const pending = [session]
  while (pending.length) {
    const current = pending.pop()
    for (const audit of edges) if (audit.session === current && !visited.has(audit.lock.session)) {
      visited.add(audit.lock.session)
      predecessors.add(audit.lock.session)
      pending.push(audit.lock.session)
    }
  }
  return predecessors
}

export function reconcileMembership({ root, slate, session, issue, action, dryRun = false, github = gh }) {
  const { repo, number } = githubIssue(issue)
  const read = () => {
    const issueState = JSON.parse(github(['issue', 'view', number, '--repo', repo, '--json', 'labels']))
    const pages = JSON.parse(github(['api', `repos/${repo}/issues/${number}/comments`, '--paginate', '--slurp']))
    if (!Array.isArray(pages) || pages.some((page) => !Array.isArray(page))) throw new Refusal('membership: invalid paginated comments')
    return { labels: issueState.labels, comments: pages.flat() }
  }
  const available = JSON.parse(github(['label', 'list', '--repo', repo, '--limit', '1000', '--json', 'name']))
  if (!available.some((label) => label.name === 'slated')) return `membership: ${repo} has no slated label; skipped`
  let snapshot = read()
  if (!Array.isArray(snapshot.labels) || !Array.isArray(snapshot.comments)) throw new Refusal('membership: invalid issue response')
  const key = `${session}\0${slate}`
  const trustedActorIds = trustedActors()
  if (!viewerLogins.has(github)) {
    try {
      const viewer = JSON.parse(github(['api', 'user']))
      if (viewer && !Array.isArray(viewer) && typeof viewer.login === 'string') viewerLogins.set(github, viewer.login)
    } catch {}
  }
  const statesFor = (comments) => activeMemberships(comments, trustedActorIds, viewerLogins.get(github))
  const body = membershipBody(session, slate, action)
  if (dryRun) return `membership: would ${action} ${issue.url}`
  if (action === 'add') {
    mkdirSync(join(root, 'locks', 'sessions', slate), { recursive: true })
    writeFileSync(join(root, 'locks', 'sessions', slate, session), `${session}\n`)
  }
  const post = (commentBody) => {
    const previousCount = snapshot.comments.length
    github(['issue', 'comment', number, '--repo', repo, '--body', commentBody])
    snapshot = read()
    const appended = snapshot.comments.slice(previousCount).find((comment) => comment.body === commentBody)
    if (appended?.user?.login) viewerLogins.set(github, appended.user.login)
  }
  const retiredKeys = new Set()
  const retirePredecessors = () => {
    const currentActive = statesFor(snapshot.comments)
    for (const prior of recoveredSessions(root, slate, session)) {
      const priorKey = `${prior}\0${slate}`
      if (currentActive.get(priorKey) === true && !retiredKeys.has(priorKey)) {
        retiredKeys.add(priorKey)
        post(membershipBody(prior, slate, 'remove'))
      }
    }
  }
  retirePredecessors()
  const active = statesFor(snapshot.comments)
  if ((active.get(key) === true) !== (action === 'add') || !active.has(key)) {
    post(body)
    retirePredecessors()
  }
  snapshot = read()
  const states = statesFor(snapshot.comments)
  if ([...retiredKeys].some((priorKey) => states.get(priorKey) === true) || states.get(key) !== (action === 'add')) throw new Refusal('membership: comment publication not verified')
  const hasLabel = () => snapshot.labels.some((label) => label.name === 'slated')
  if (action === 'add') {
    if (!hasLabel()) {
      github(['issue', 'edit', number, '--repo', repo, '--add-label', 'slated'])
      snapshot = read()
      if (!hasLabel()) throw new Refusal('membership: label addition not verified')
    }
  } else if (![...states.values()].some(Boolean) && !localOtherMembership(root, slate, issue) && hasLabel()) {
    github(['issue', 'edit', number, '--repo', repo, '--remove-label', 'slated'])
    snapshot = read()
    if ([...statesFor(snapshot.comments).values()].some(Boolean) || localOtherMembership(root, slate, issue)) {
      if (!hasLabel()) {
        github(['issue', 'edit', number, '--repo', repo, '--add-label', 'slated'])
        snapshot = read()
        if (!hasLabel()) throw new Refusal('membership: concurrent label restoration not verified')
      }
    } else if (hasLabel()) {
      throw new Refusal('membership: label removal not verified')
    }
  }
  return `membership: ${action} ${issue.url}`
}

function syncRevision(root, slate, session, previous, current) {
  const before = new Map(membershipIssues(previous).map((issue) => [membershipKey(issue), issue]))
  const after = new Map(membershipIssues(current).map((issue) => [membershipKey(issue), issue]))
  const output = []
  for (const [key, issue] of after) if (!before.has(key)) output.push(reconcileMembership({ root, slate, session, issue, action: 'add' }))
  for (const [key, issue] of before) if (!after.has(key)) output.push(reconcileMembership({ root, slate, session, issue, action: 'remove' }))
  return output.join('\n')
}

export function membershipActions(document, root, close) {
  const issues = new Map()
  for (const revision of document.revisions) for (const issue of revision.plan.issues) issues.set(membershipKey(issue), issue)
  const current = document.revisions.at(-1).plan
  const active = new Set(membershipIssues(current).map(membershipKey))
  const started = new Set(document.revisions.flatMap(({ plan }) => plan.lanes
    .filter((lane) => existsSync(join(root, 'runs', lane.run_id)))
    .map((lane) => plan.issues.find((issue) => itemKey(plan, issue) === itemKey(plan, lane, 'issue')))
    .filter(Boolean).map(membershipKey)))
  for (const issue of current.issues) if (issue.verdict === 'handed-off') started.add(membershipKey(issue))
  return [...issues.values()].map((issue) => ({ issue,
    action: active.has(membershipKey(issue)) && (!close || started.has(membershipKey(issue))) ? 'add' : 'remove' }))
}

function membershipCommand(args) {
  const { root } = stateRoot()
  const slate = requireId('slate', args.slate), session = requireId('session', args.session)
  const canonical = join(root, 'slates', slate, 'plan.json')
  validateFile('plan', canonical, 'membership plan')
  acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'] })
  return withMutex(canonical, () => {
    const document = readJson(canonical, 'membership plan')
    return membershipActions(document, root, args.close).map(({ issue, action }) =>
      reconcileMembership({ root, slate, session, issue, action, dryRun: args['dry-run'] })).join('\n')
  })
}

// Every git call reads the real objects: replace refs are disabled, so an
// overridden history cannot hide a moved path (a grafts file, which no flag
// disables, is refused in baseMove).
function git(args, cwd = process.cwd()) {
  return execFileSync('git', ['--no-replace-objects', ...args], {
    cwd, encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' },
  })
}

function pathExists(path) {
  try { lstatSync(path); return true }
  catch (error) { if (error.code === 'ENOENT') return false; throw error }
}

function resolveCommit(value, label, cwd) {
  try {
    return git(['rev-parse', '--verify', '--quiet', `${value}^{commit}`], cwd).trim()
  } catch {
    throw new Refusal(`${label} ${value} is not a commit in this repository`)
  }
}

// Fence matching mirrors orchestrate/assets/fence-check.sh: per path
// component, literal first; a component holding `*` or `?` is a glob within
// that component (`{` and a bare `[x]` stay literal), and a `**` component
// matches any number of components. A component this matcher cannot
// interpret the same way never gets here (see uninterpretable).
// uninterpretable — a component combining a bracket class with `*`/`?`, or
// holding a backslash, means something to fence-check.sh this matcher does
// not reproduce.
function uninterpretable(pattern) {
  return pattern.split('/').some((part) => part.includes('\\') || (part.includes('[') && /[*?]/.test(part)))
}

function fencePaths(lane) {
  return [
    ...(lane.fence ?? []).map((item) => (typeof item === 'string' ? item : item?.path)).filter(Boolean),
    ...(lane.expansions ?? []).map((entry) => entry.path).filter(Boolean),
  ]
}

export function effectiveFence(lane) {
  return [...lane.fence.map((item) => typeof item === 'string' ? { path: item } : item),
    ...lane.expansions.map((entry) => ({ path: entry.path, note: `expansion ${entry.at}: ${entry.reason}` }))]
}

// Literal-vs-pattern matching uses the existing fence matcher. Two globs with
// disjoint literal prefixes are provably disjoint; otherwise fail closed rather
// than claim disjointness from the files that happen to exist today.
export function mayOverlap(left, right) {
  const uncertain = (pattern) => pattern.split('/').some((part) => part.includes('\\') || (part.includes('[') && /[*?]/.test(part)))
  if (uncertain(left) || uncertain(right)) return true
  const glob = (pattern) => /[*?]/.test(pattern)
  if (!glob(left)) return pathMatches(left, right)
  if (!glob(right)) return pathMatches(right, left)
  const a = left.split('/'), b = right.split('/')
  for (let i = 0; i < Math.min(a.length, b.length); i += 1) {
    if (glob(a[i]) || glob(b[i])) return true
    if (a[i] !== b[i]) return false
  }
  return true
}

export function reviseForBaseMove(previous, { newBase, done, changed, reverified = [], verifications = [], root, repo }) {
  const plan = planGraph(previous)
  const target = repo === undefined ? plan.repo : repository(repo)
  done = done.map((number) => issueKey(plan, number, target))
  reverified = reverified.map((number) => issueKey(plan, number, target))
  const doneSet = new Set(done)
  const known = new Set(plan.issues.filter((issue) => itemRepository(plan, issue) === target).map((issue) => issue.number))
  const unknown = done.filter((number) => !known.has(number))
  if (unknown.length > 0) throw new Refusal(`--done names issue(s) not in the plan: ${unknown.join(', ')}`)

  const live = plan.issues.filter((issue) => itemRepository(plan, issue) === target && !['done', 'handed-off'].includes(issue.verdict) && !doneSet.has(issue.number))
  // Explicit owner decisions authorize only the named, touched provisioned lanes.
  // They are recorded in the revision reason; run records and fences stay intact.
  if (!Array.isArray(verifications)) throw new Refusal('base-move lanes must be an array')
  const verified = new Set()
  for (const entry of verifications) {
    fields(entry, ['lane', 'status', 'sha'], 'base-move lane verification')
    const lane = workingLanes(plan).find((lane) => lane.lane === entry.lane && itemRepository(plan, lane) === target && !doneSet.has(lane.issue))
    const issue = plan.issues.find((issue) => issue.number === lane?.issue && issue.verdict !== 'done')
    if (!lane || !issue) throw new Refusal('verification must name a live lane in the target repository')
    if (typeof root !== 'string' || !root.trim() || !pathExists(join(root, 'runs', requireId('run-id', lane.run_id)))) throw new Refusal('verification requires a provisioned lane')
    if (verified.has(lane.issue)) throw new Refusal('duplicate lane verification')
    if (entry.status === 'caught-up') {
      if (typeof entry.sha !== 'string' || !/^[0-9a-f]{40}$/.test(entry.sha)) throw new Refusal('caught-up verification requires a full SHA')
    } else if (entry.status !== 'catch-up-owed' || entry.sha !== undefined) {
      throw new Refusal('verification requires caught-up with sha or catch-up-owed without sha')
    }
    const patterns = [...fencePaths(lane), ...issue.candidate_files]
    if (!changed.some((path) => patterns.some((pattern) => pathMatches(path, pattern)))) throw new Refusal('verified lane has no fence or candidate collision')
    verified.add(lane.issue)
  }
  const refusals = []
  const reverifiedSet = new Set(reverified)
  if (reverifiedSet.size > 0 && (typeof root !== 'string' || root.trim() === '')) throw new Refusal('--reverified requires state root')
  for (const number of reverifiedSet) {
    const issue = live.find((item) => item.number === number)
    const lane = plan.lanes.find((item) => item.issue === number)
    if (!issue || !lane) throw new Refusal(`--reverified #${number} is not a live issue with a planned lane`)
    const runId = requireId('run-id', lane.run_id)
    let provisioned = true
    try { lstatSync(join(root, 'runs', runId)) } catch (error) {
      if (error.code !== 'ENOENT') throw error
      provisioned = false
    }
    if (provisioned) {
      throw new Refusal(`--reverified #${number} names provisioned lane ${lane.lane} (run ${lane.run_id})`)
    }
    const patterns = [...fencePaths(lane), ...issue.candidate_files]
    for (const pattern of patterns) if (uninterpretable(pattern)) throw new Refusal(`pattern needs orchestrator judgment (not matched here): ${pattern}`)
    if (!changed.some((path) => patterns.some((pattern) => pathMatches(path, pattern)))) {
      throw new Refusal(`--reverified #${number} has no fence or candidate collision`)
    }
  }
  for (const issue of live) {
    for (const blocker of issue.blocked_by ?? []) {
      if (doneSet.has(blocker)) refusals.push(`done issue #${blocker} releases dependent #${issue.number} (blocked_by)`)
    }
  }
  for (const overlap of plan.overlaps) {
    const dependency = overlap.merge_dependency
    if (dependency && doneSet.has(dependency.before) && live.some((issue) => issue.number === dependency.after)) {
      refusals.push(`done issue #${dependency.before} releases dependent #${dependency.after} (merge dependency)`)
    }
  }
  // A pattern this helper cannot interpret makes any move need judgment
  // instead of being matched by a second glob engine.
  if (changed.length > 0) {
    const liveLanes = workingLanes(plan).filter((lane) => itemRepository(plan, lane) === target && !doneSet.has(lane.issue))
    for (const pattern of [...liveLanes.flatMap(fencePaths), ...live.flatMap((issue) => issue.candidate_files ?? [])]) {
      if (uninterpretable(pattern)) refusals.push(`pattern needs orchestrator judgment (not matched here): ${pattern}`)
    }
  }
  for (const lane of workingLanes(plan).filter((lane) => itemRepository(plan, lane) === target && !doneSet.has(lane.issue))) {
    const patterns = fencePaths(lane)
    for (const path of changed) {
      if (patterns.some((pattern) => pathMatches(path, pattern))) {
        if (!reverifiedSet.has(lane.issue) && !verified.has(lane.issue)) refusals.push(`base move touches lane ${lane.lane} (#${lane.issue}) fence: ${path}`)
      }
    }
  }
  for (const issue of live) {
    for (const path of changed) {
      if ((issue.candidate_files ?? []).some((pattern) => pathMatches(path, pattern))) {
        if (!reverifiedSet.has(issue.number) && !verified.has(issue.number)) refusals.push(`base move touches issue #${issue.number} candidate file: ${path}`)
      }
    }
  }
  if (refusals.length > 0) {
    throw new Refusal(`this recompute needs orchestrator judgment; nothing was written:\n  - ${refusals.join('\n  - ')}`)
  }

  if (target === plan.repo) plan.base_sha = newBase
  else plan.repository_bases = [...(plan.repository_bases ?? []).filter((entry) => repository(entry.repo) !== target), { repo: target, base_sha: newBase }]
  // Lane bases are snapshots for existing brief/run consumers; the repository
  // entry is authoritative for foreign repositories.
  for (const lane of plan.lanes) if (itemRepository(plan, lane) === target &&
      (target !== plan.repo || lane.base_sha !== undefined)) lane.base_sha = newBase
  for (const issue of plan.issues) if (doneSet.has(issue.number)) issue.verdict = 'done'
  if (plan.retained_lanes) plan.retained_lanes = plan.retained_lanes.filter((entry) => !doneSet.has(entry.lane.issue))
  const renumber = new Map()
  plan.waves = plan.waves
    .map((wave) => ({ ...wave, issues: wave.issues.filter((number) => !doneSet.has(number)) }))
    .filter((wave) => wave.issues.length > 0)
    .sort((a, b) => a.number - b.number)
    .map((wave, index) => {
      renumber.set(wave.number, index + 1)
      return { ...wave, number: index + 1 }
    })
  plan.lanes = plan.lanes
    .filter((lane) => !doneSet.has(lane.issue))
    .map((lane) => ({ ...lane, wave: renumber.get(lane.wave) ?? lane.wave }))
  if (plan.lane_profiles !== undefined) {
    const lanes = new Set(plan.lanes.map((lane) => lane.lane))
    plan.lane_profiles = plan.lane_profiles.filter((entry) => lanes.has(entry.lane))
  }
  plan.overlaps = plan.overlaps.filter((overlap) => !doneSet.has(overlap.issue_a) && !doneSet.has(overlap.issue_b))
  if (plan.merge_queue !== undefined) plan.merge_queue = plan.merge_queue.filter((entry) => !doneSet.has(entry.issue))
  queueWaitingHandoffs(plan)
  return planWire(plan)
}

function baseMove(args) {
  const { root } = stateRoot()
  const slate = requireId('slate', args.slate)
  const session = requireId('session', args.session)
  if (typeof args.reason !== 'string' || args.reason.trim() === '') throw new UsageError('--reason is required')
  if (typeof args['new-base'] !== 'string') throw new UsageError('--new-base is required')
  const done = (args.done ?? []).map((value) => {
    const number = Number(value)
    if (!Number.isInteger(number) || number < 1) throw new UsageError(`--done must be an issue number, got ${value}`)
    return number
  })
  const reverified = [...new Set((args.reverified ?? []).map((value) => {
    if (!/^[1-9][0-9]*$/.test(value) || !Number.isSafeInteger(Number(value))) throw new UsageError(`--reverified must be an issue number, got ${value}`)
    return Number(value)
  }))]
  const at = resolveAt(args.at)
  const canonical = join(root, 'slates', slate, 'plan.json')
  if (!existsSync(canonical)) throw new Refusal(`no plan for slate ${slate}: ${canonical}`)
  // Validated before the lock is taken, so a broken plan leaves no lock.
  validateFile('plan', canonical, `existing ${canonical}`)
  acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'], milestone: args.milestone, issues: args.issues })

  return withMutex(canonical, () => {
    const document = readJson(canonical, 'plan')
    if (document.slate_id !== slate) throw new Refusal(`${canonical} records slate_id ${JSON.stringify(document.slate_id)}, not ${slate}`)
    const last = document.revisions.at(-1)
    const conductor = last.plan.repo === undefined ? undefined : repository(last.plan.repo)
    const target = args.repo === undefined ? conductor : repository(args.repo)
    const foreign = target !== conductor
    let clone = process.cwd()
    if (foreign) {
      if (!last.plan.repo || !last.plan.issues.some((issue) => itemRepository(last.plan, issue) === target)) {
        throw new Refusal('target repository is not in the plan')
      }
      const parent = dirname(dirname(stateRoot().common))
      const candidates = args['repo-root'] ? [args['repo-root']] :
        readdirSync(parent, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => join(parent, entry.name))
      const matches = [...new Set(candidates.filter((path) => {
        try { return git(['rev-parse', '--show-toplevel'], path).trim() === realpathSync(path) && originRepository(path) === target } catch { return false }
      }).map((path) => realpathSync(path)))]
      if (matches.length !== 1) throw new Refusal(`expected one clone for ${target}; supply --repo-root PATH with matching origin`)
      clone = matches[0]
    }
    const oldBase = foreign ? last.plan.repository_bases?.find((entry) => repository(entry.repo) === target)?.base_sha : last.plan.base_sha
    if (!oldBase) throw new Refusal('target repository needs one recorded base_sha')
    const grafts = git(['rev-parse', '--path-format=absolute', '--git-path', 'info/grafts'], clone).trim()
    if (existsSync(grafts)) {
      throw new Refusal(`${grafts} exists; a grafted history cannot prove what a base move changed, refusing`)
    }
    const newBase = resolveCommit(args['new-base'], '--new-base', clone)
    resolveCommit(oldBase, 'the plan base', clone)
    if (newBase === oldBase) throw new Refusal(`base ${oldBase} did not move; nothing to revise`)
    try {
      git(['merge-base', '--is-ancestor', oldBase, newBase], clone)
    } catch {
      throw new Refusal(`new base ${newBase} does not descend from the plan base ${oldBase}`)
    }
    if (isBefore(at, last.at)) throw new Refusal(`${at} precedes revision ${last.seq} (${last.at})`)
    const changed = git(['diff', '--no-relative', '--name-only', '--no-renames', '-z', oldBase, newBase], clone).split('\0').filter(Boolean)
    const input = args.input ? readJson(args.input, 'base-move input') : {}
    fields(input, ['lanes'], 'base-move input')
    const verifications = input.lanes === undefined ? [] : input.lanes
    const plan = reviseForBaseMove(last.plan, { newBase, done, changed, reverified, verifications, root, repo: target })
    const seq = document.revisions.length
    const reason = `${args.reason}${reverified.length ? `, reverified ${reverified.map((n) => `#${n}`).join(' ')}` : ''}${verifications.length ? `, owner lane verifications ${JSON.stringify(verifications)}` : ''}`
    const entry = { seq, prev_digest: last.digest, at, reason, plan }
    entry.digest = chainDigest({ seq, plan, at, reason }, last.digest)
    document.revisions.push(entry)
    writeValidated('plan', canonical, document)
    const synced = syncRevision(root, slate, session, last.plan, plan)
    return `appended revision ${seq}: base ${oldBase.slice(0, 12)} → ${newBase.slice(0, 12)}${done.length ? `, done ${done.map((n) => `#${n}`).join(' ')}` : ''}${reverified.length ? `, reverified ${reverified.map((n) => `#${n}`).join(' ')}` : ''}${synced ? `\n${synced}` : ''}`
  })
}

// Only decision fields enter the writer. In particular, a complete replacement
// plan/fence is never accepted for a revision of an existing run.
function fields(value, allowed, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Refusal(`${label} must be an object`)
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) {
      const fenceNote = ['fence', 'plan'].includes(key) ? '; existing original fences are immutable' : ''
      throw new Refusal(`${label}.${key} is not accepted by this writer${fenceNote}`)
    }
  }
}

// Fence entries use the plan schema's string or {path, note} shape. Check
// their path strings before the glob matcher, leaving closed-object checks to
// candidate validation.
function decisionPaths(value, label, fence = false) {
  if (!Array.isArray(value) || value.length === 0) throw new UsageError(`${label} must be a non-empty array of path strings`)
  const paths = fence ? value.map((entry) => typeof entry === 'string' ? entry : entry?.path) : value
  if (paths.some((path) => typeof path !== 'string' || !path.trim())) {
    throw new UsageError(`${label} must contain non-empty path strings`)
  }
}

function liveIssues(plan) {
  return plan.issues.filter((issue) => issue.verdict !== 'done')
}

function pairKey(a, b) {
  return [a, b].sort((x, y) => String(x).localeCompare(String(y), 'en', { numeric: true })).join(':')
}

// Retained lanes own editable fences only while admitted for a fix round.
function workingLanes(plan) {
  return [...plan.lanes, ...(plan.retained_lanes ?? []).filter((entry) => entry.state === 'working').map((entry) => entry.lane)]
}

// The schema records exact candidate intersections. A glob-only intersection
// without a shared candidate entry cannot be represented: refuse and ask the
// operator to supply a concrete shared candidate, rather than inventing scope.
function computeOverlaps(plan, decisions) {
  if (!Array.isArray(decisions)) throw new Refusal('overlaps must be an array')
  const byPair = new Map()
  for (const decision of decisions) {
    const key = pairKey(decision.issue_a, decision.issue_b)
    if (byPair.has(key)) throw new Refusal(`duplicate overlap decision ${key}`)
    byPair.set(key, decision)
  }
  const overlaps = []
  const issues = liveIssues(plan)
  for (let i = 0; i < issues.length; i += 1) for (const right of issues.slice(i + 1)) {
    const left = issues[i]
    if (itemRepository(plan, left) !== itemRepository(plan, right)) continue
    const shared = [...new Set(left.candidate_files.filter((path) => right.candidate_files.includes(path)))].sort()
    const collision = left.candidate_files.some((a) => right.candidate_files.some((b) => mayOverlap(a, b)))
    const key = pairKey(left.number, right.number)
    const decision = byPair.get(key)
    if (!collision && !decision) continue
    if (!decision || !['serialize', 'split'].includes(decision.resolution) || !decision.merge_dependency) {
      throw new Refusal(`unresolved overlap ${key}; supply resolution and merge_dependency`)
    }
    if (collision && !shared.length) throw new Refusal(`glob overlap ${key} needs a shared candidate entry to record its resolution`)
    const paths = [...new Set([...shared, ...(decision.paths ?? [])])].sort()
    const [issue_a, issue_b] = [left.number, right.number].sort((a, b) => String(a).localeCompare(String(b), 'en', { numeric: true }))
    overlaps.push({ ...(left.repo === undefined ? {} : { repo: left.repo }), issue_a, issue_b, paths, resolution: decision.resolution, merge_dependency: decision.merge_dependency })
    byPair.delete(key)
  }
  if (byPair.size) throw new Refusal(`overlap decisions name no live candidate intersection: ${[...byPair.keys()].join(', ')}`)
  plan.overlaps = overlaps
  // Cross-wave ownership still needs a path-specific decision. The schema's
  // same-wave exact-string check alone cannot establish this property.
  const lanes = workingLanes(plan)
  for (let i = 0; i < lanes.length; i += 1) for (const right of lanes.slice(i + 1)) {
    const left = lanes[i]
    if (itemRepository(plan, left) !== itemRepository(plan, right)) continue
    const overlap = overlaps.find((entry) => pairKey(entry.issue_a, entry.issue_b) === pairKey(left.issue, right.issue))
    for (const a of effectiveFence(left)) for (const b of effectiveFence(right)) {
      if (!mayOverlap(a.path, b.path)) continue
      const covered = overlap?.paths.some((path) =>
        (a.path === b.path && path === a.path) ||
        (!/[*?]/.test(a.path) && pathMatches(a.path, path) && pathMatches(a.path, b.path)) ||
        (!/[*?]/.test(b.path) && pathMatches(b.path, path) && pathMatches(b.path, a.path)))
      if (!covered) throw new Refusal(`unresolved effective fence overlap ${left.lane}/${right.lane}: ${a.path} / ${b.path}`)
    }
  }
}

function appendIssue(plan, input, policyFile) {
  fields(input, ['issue', 'lane', 'profile', 'repository_base', 'overlaps', 'waves'], 'addition')
  if (policyFile !== undefined) {
    if (input.profile !== undefined) throw new Refusal('supply --policy or profile, not both')
    input = { ...input, profile: { lane: input.lane?.lane, policy: readPlanPolicy(policyFile) } }
  }
  if (!input.issue || !input.lane || !input.profile?.policy || input.profile.lane !== input.lane.lane) {
    throw new Refusal('addition requires issue, lane and complete resolved profile {lane, policy}')
  }
  decisionPaths(input.issue.candidate_files, 'issue.candidate_files')
  decisionPaths(input.lane.fence, 'lane.fence', true)
  if (plan.issues.some((issue) => issue.number === input.issue.number)) throw new Refusal(`issue #${input.issue.number} already exists`)
  if (input.issue.verdict === 'done') throw new Refusal('an added issue must be live')
  if (input.lane.issue !== input.issue.number) throw new Refusal('added lane must name the added issue')
  if (!plan.lane_profiles) {
    throw new Refusal('before adding an issue, hand-append a validated revision recording complete lane_profiles, per orchestrate SKILL.md § Planning')
  }
  const target = itemRepository(plan, input.issue)
  const foreign = target !== (plan.repo === undefined ? undefined : repository(plan.repo))
  const existingBase = plan.repository_bases?.find((entry) => repository(entry.repo) === target)
  if (foreign && !existingBase) {
    const base = input.repository_base
    if (!base || repository(base.repo) !== target || !/^[0-9a-f]{40}$/.test(base.base_sha)) {
      throw new Refusal('first issue in a foreign repository requires repository_base {repo, base_sha}')
    }
    fields(base, ['repo', 'base_sha'], 'repository_base')
    plan.repository_bases = [...(plan.repository_bases ?? []), { repo: target, base_sha: base.base_sha }]
  } else if (input.repository_base !== undefined) {
    throw new Refusal('repository base is already recorded; use base-move --repo to change it')
  }
  plan.issues.push(structuredClone(input.issue))
  plan.lanes.push(structuredClone(input.lane))
  plan.lane_profiles.push(structuredClone(input.profile))
  if (!input.waves) {
    const wave = plan.waves.find((entry) => entry.number === input.lane.wave)
    if (wave) wave.issues.push(input.issue.number)
    else plan.waves.push({ number: input.lane.wave, issues: [input.issue.number] })
  }
  return input.waves
}

function placeWaves(plan, waves) {
  if (waves === undefined) return
  if (!Array.isArray(waves)) throw new Refusal('waves must be an array')
  const placed = structuredClone(waves)
  // Refuse placement changes to released work; retirement already carries surviving memberships.
  for (const current of plan.waves.filter((wave) => wave.released === true)) {
    const wave = placed.find((entry) => entry.number === current.number)
    if (!wave || wave.issues.length !== current.issues.length ||
        !current.issues.every((number) => wave.issues.includes(number))) {
      throw new Refusal(`wave ${current.number}: only wave-release may change released membership`)
    }
  }
  for (const wave of placed) {
    const current = plan.waves.find((entry) => entry.number === wave.number)
    if (Object.hasOwn(wave, 'released') && wave.released !== current?.released) {
      throw new Refusal(`wave ${wave.number}: only wave-release may change released`)
    }
    if (current?.released === true) wave.released = true
    else delete wave.released
  }
  plan.waves = placed
  for (const lane of plan.lanes) {
    lane.wave = waves.find((wave) => wave.issues.includes(lane.issue))?.number
  }
}

// One predecessor relation: file merge ordering and issue prerequisites.
function planPredecessors(plan) {
  const predecessors = new Map((plan.issues ?? []).map((issue) => [issue.number, new Set(issue.blocked_by ?? [])]))
  for (const overlap of plan.overlaps ?? []) {
    const edge = overlap.merge_dependency
    if (edge) predecessors.get(edge.after)?.add(edge.before)
  }
  return predecessors
}

function retireIssue(plan, number, verdict = 'done') {
  const issue = plan.issues.find((entry) => entry.number === number)
  if (!issue || issue.verdict === 'done') throw new Refusal(`issue #${number} is not live in this slate`)
  issue.verdict = verdict
  if (verdict === 'handed-off') {
    const lane = plan.lanes.find((entry) => entry.issue === number)
    const retained = plan.retained_lanes?.find((entry) => entry.lane.issue === number)
    if (retained) {
      if (retained.state !== 'pending') retained.state = 'idle'
    }
    else if (lane) {
      plan.retained_lanes ??= []
      plan.retained_lanes.push({ lane: structuredClone(lane), policy: structuredClone(plan.lane_profiles?.find((entry) => entry.lane === lane.lane)?.policy ?? plan.policy), state: 'idle' })
    }
  } else if (plan.retained_lanes) plan.retained_lanes = plan.retained_lanes.filter((entry) => entry.lane.issue !== number)
  const lanes = new Set(plan.lanes.filter((lane) => lane.issue === number).map((lane) => lane.lane))
  plan.lanes = plan.lanes.filter((lane) => lane.issue !== number)
  if (plan.lane_profiles) plan.lane_profiles = plan.lane_profiles.filter((entry) => !lanes.has(entry.lane))
  if (verdict === 'done') {
    const remap = new Map()
    plan.waves = plan.waves.map((wave) => ({ ...wave, issues: wave.issues.filter((n) => n !== number) }))
      .filter((wave) => wave.issues.length).sort((a, b) => a.number - b.number).map((wave, index) => {
        remap.set(wave.number, index + 1)
        return { ...wave, number: index + 1 }
      })
    for (const lane of plan.lanes) lane.wave = remap.get(lane.wave)
    plan.overlaps = plan.overlaps.filter((entry) => entry.issue_a !== number && entry.issue_b !== number)
    if (plan.merge_queue !== undefined) plan.merge_queue = plan.merge_queue.filter((entry) => entry.issue !== number)
  }
}

// Every queued issue has each merge predecessor done or queued ahead of it.
// A waiting handoff retains its PR on the issue until its predecessors allow
// appending. Repeated passes release chains while preserving existing queue order.
function queueWaitingHandoffs(plan) {
  const queue = plan.merge_queue ?? []
  const issueByNumber = new Map(plan.issues.map((issue) => [issue.number, issue]))
  const predecessorByIssue = planPredecessors(plan)
  let added
  do {
    added = false
    for (const issue of plan.issues) {
      if (issue.verdict !== 'handed-off' || queue.some((entry) => entry.issue === issue.number)) continue
      const predecessors = [...predecessorByIssue.get(issue.number)]
      if (predecessors.some((number) => issueByNumber.get(number)?.verdict !== 'done' && !queue.some((entry) => entry.issue === number))) continue
      if (!Number.isInteger(issue.pr) || issue.pr < 1) throw new Refusal(`handed-off issue #${issue.number} needs its PR binding`)
      queue.push({ ...(issue.repo === undefined ? {} : { repo: issue.repo }), issue: issue.number, pr: issue.pr })
      added = true
    }
  } while (added)
  if (plan.merge_queue !== undefined || queue.length) plan.merge_queue = queue
}

function expandLane(plan, laneName, paths, at, reason, { source, fresh = false } = {}) {
  const lane = workingLanes(plan).find((entry) => entry.lane === laneName)
  if (!lane) throw new Refusal(`unknown receiving live lane ${laneName}`)
  if (!Array.isArray(paths) || !paths.length || paths.some((path) => typeof path !== 'string' || !path.trim())) {
    throw new Refusal('at least one nonempty path is required')
  }
  for (const path of paths) {
    const uncertain = source && [path, ...fencePaths(source)].find(uninterpretable)
    if (uncertain) throw new Refusal(`pattern needs orchestrator judgment (not matched here): ${uncertain}`)
    if (source && !effectiveFence(source).some((item) => path === item.path || (!/[*?]/.test(path) && pathMatches(path, item.path)))) {
      throw new Refusal(`released path ${path} is outside finished lane ${source.lane}'s effective fence`)
    }
    if (source && itemRepository(plan, source) !== itemRepository(plan, lane)) throw new Refusal('cannot release a fence across repositories')
    for (const other of workingLanes(plan).filter((entry) => entry.lane !== laneName && itemRepository(plan, entry) === itemRepository(plan, lane))) {
      if (effectiveFence(other).some((item) => mayOverlap(path, item.path))) {
        throw new Refusal(`path ${path} is covered by another live lane ${other.lane}'s effective fence`)
      }
    }
    if (effectiveFence(lane).some((item) => path === item.path || (!/[*?\[]/.test(path) && pathMatches(path, item.path)))) {
      throw new Refusal(`path ${path} is already covered by receiving lane ${laneName}`)
    }
    if (fresh) lane.fence.push({ path })
    else lane.expansions.push({ path, at, reason })
  }
}

// Release preference ordering without retiring issues or changing the base.
// The orchestrator records handoff only after the live handoff check passes;
// labels alone are never input to this writer. Live dispatch ceilings are
// checked at dispatch (#1704), not when recording this eligibility decision.
function releaseWave(plan, number) {
  const wave = plan.waves.find((entry) => entry.number === number)
  if (!wave) throw new Refusal(`unknown wave ${number}`)
  if (number === 1 || wave.released) throw new Refusal(`wave ${number} is already released`)
  const earlier = plan.waves.filter((entry) => entry.number < number)
  if (earlier.some((entry) => entry.number !== 1 && !entry.released)) {
    throw new Refusal('release the next wave in order; an earlier wave is not released')
  }
  const issues = new Map(plan.issues.map((issue) => [issue.number, issue]))
  for (const entry of earlier) for (const predecessor of entry.issues) {
    const issue = issues.get(predecessor)
    const pr = issue?.pr ?? plan.merge_queue?.find((binding) => binding.issue === predecessor)?.pr
    if (issue?.verdict !== 'done' && !(issue?.verdict === 'handed-off' && Number.isInteger(pr) && pr > 0)) {
      throw new Refusal(`wave ${number} waits for issue #${predecessor} to be done or handed-off with a bound PR`)
    }
  }
  const predecessors = planPredecessors(plan)
  for (const issue of wave.issues) for (const blocker of predecessors.get(issue)) {
    if (issues.get(blocker)?.verdict !== 'done') {
      throw new Refusal(`wave ${number} waits for merge prerequisite #${blocker} of issue #${issue} to be done`)
    }
  }
  wave.released = true
}

function decisionWrite(command, args) {
  const { root } = stateRoot()
  const slate = requireId('slate', args.slate)
  const session = requireId('session', args.session)
  if (typeof args.reason !== 'string' || !args.reason.trim()) throw new UsageError('--reason is required')
  if (command !== 'wave-release' && args.reason.startsWith('wave-release:')) {
    throw new Refusal('wave-release: reason prefix is reserved for wave-release')
  }
  const at = resolveAt(args.at)
  const canonical = join(root, 'slates', slate, 'plan.json')
  let input = args.input ? readJson(args.input, 'decision input') : {}
  if (['genesis', 'add-issue', 'queue-order'].includes(command) && !args.input) throw new UsageError('--input is required')
  if (command === 'genesis' && !args['owner-token']) throw new Refusal('genesis requires --owner-token for an already-held lock')
  mkdirSync(dirname(canonical), { recursive: true })
  const withAdmissionMutex = (operation) => ['reactivate', 'fix-request', 'handoff', 'add-issue', 'replace-unprovisioned'].includes(command)
    ? withMutex(join(root, 'dispatch'), operation) : operation()
  return withMutex(canonical, () => withAdmissionMutex(() => {
    if (command === 'genesis' && existsSync(canonical)) throw new Refusal(`slate ${slate} already has a plan`)
    if (command !== 'genesis' && !existsSync(canonical)) throw new Refusal(`no plan for slate ${slate}`)
    if (command !== 'genesis') validateFile('plan', canonical, 'existing plan')
    const document = command === 'genesis' ? { schema: 1, slate_id: slate, revisions: [] } : readJson(canonical, 'plan')
    if (document.slate_id !== slate) throw new Refusal('plan slate_id does not match its directory')
    const last = document.revisions.at(-1)
    if (last && isBefore(at, last.at)) throw new Refusal(`${at} precedes revision ${last.seq} (${last.at})`)
    let wire = structuredClone(last?.plan ?? input)
    let reactivationClaim
    if (wire.repo === undefined && (args.repo !== undefined || input.issue?.repo !== undefined ||
        input.addition?.issue?.repo !== undefined || wire.issues?.some((issue) => issue.repo !== undefined))) {
      wire.repo = originRepository()
    }
    if (command === 'genesis' && wire.repo !== undefined && repository(wire.repo) !== originRepository()) {
      throw new Refusal('plan repo must match the conductor origin')
    }
    const plan = planGraph(wire)
    const selection = () => issueKey(plan, Number(args.issue), args.repo)
    // Additions and wave placements enter the same graph representation as the
    // stored plan. Keep the wire schema validation at the publication boundary.
    const additionGraph = (addition) => {
      if (!addition) return addition
      const part = planGraph({ repo: plan.repo, issues: [addition.issue], lanes: [addition.lane],
        overlaps: addition.overlaps ?? [], waves: addition.waves ?? [] })
      return { ...addition, issue: part.issues[0], lane: part.lanes[0],
        ...(addition.overlaps === undefined ? {} : { overlaps: part.overlaps }),
        ...(addition.waves === undefined ? {} : { waves: part.waves }) }
    }
    if (command === 'add-issue') input = additionGraph(input)
    if (input.addition) input.addition = additionGraph(input.addition)
    if (input.waves) input.waves = planGraph({ repo: plan.repo, waves: input.waves }).waves
    if (command === 'queue-order' && Array.isArray(input.issues)) {
      try { input.issues = input.issues.map((n) => issueKey(plan, n)) }
      catch { throw new Refusal('queue-order issues must be a permutation of the current merge queue') }
    }
    const held = acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'] })
    let decisions = plan.overlaps
    if (command === 'genesis') {
      decisions = plan.overlaps.map(({ paths, ...decision }) => decision)
      if (!Array.isArray(plan.issues)) throw new UsageError('plan.issues must be an array')
      if (!Array.isArray(plan.lanes)) throw new UsageError('plan.lanes must be an array')
      for (const issue of plan.issues) if (issue?.verdict !== 'done') decisionPaths(issue?.candidate_files, 'issue.candidate_files')
      for (const lane of plan.lanes) decisionPaths(lane?.fence, 'lane.fence', true)
      const outside = plan.issues?.filter((issue) => !held.issues.map((n) => issueKey(plan, n)).includes(issue.number)) ?? []
      if (outside.length) throw new Refusal(`genesis issues outside the lock reservation: ${outside.map((issue) => issue.number).join(', ')}`)
    } else if (command === 'add-issue') {
      const waves = appendIssue(plan, input, args.policy)
      placeWaves(plan, waves)
      decisions = [...plan.overlaps, ...(input.overlaps ?? []).map(({ paths, ...decision }) => decision)]
    } else if (command === 'replace-unprovisioned') {
      fields(input, [], 'replace-unprovisioned input')
      const lane = plan.lanes.find((lane) => lane.lane === args.lane)
      if (!lane || (args.repo !== undefined && itemRepository(plan, lane) !== repository(args.repo))) throw new Refusal('unknown live lane in selected repository')
      if (pathExists(join(root, 'runs', requireId('run-id', lane.run_id)))) throw new Refusal('previous run directory exists; cannot replace provisioned lane')
      const next = requireId('run-id', args['run-id'])
      if (next === lane.run_id || document.revisions.some(({ plan }) => [...plan.lanes, ...(plan.retained_lanes ?? []).map((entry) => entry.lane)].some((entry) => entry.run_id === next)) || pathExists(join(root, 'runs', next))) throw new Refusal('replacement requires a fresh unused run_id')
      if (!plan.lane_profiles) throw new Refusal('replacement requires complete lane_profiles')
      if (!args.policy) throw new UsageError('--policy is required (resolved-policy JSON)')
      const policy = readPlanPolicy(args.policy, plan.lane_profiles.find((entry) => entry.lane === lane.lane).policy.operator_pins)
      lane.run_id = next
      // A new run starts with the same effective fence, including prior expansions.
      if (lane.expansions.length) lane.fence = effectiveFence(lane)
      lane.expansions = []
      plan.lane_profiles = plan.lane_profiles.filter((entry) => entry.lane !== lane.lane)
      plan.lane_profiles.push({ lane: lane.lane, policy })
    } else if (command === 'overlap') {
      fields(input, [], 'overlap input')
      const a = plan.lanes.find((lane) => lane.lane === args['lane-a'])
      const b = plan.lanes.find((lane) => lane.lane === args['lane-b'])
      if (!a || !b || a === b) throw new Refusal('overlap requires two distinct live lanes')
      if (itemRepository(plan, a) !== itemRepository(plan, b) || (args.repo !== undefined && itemRepository(plan, a) !== repository(args.repo))) throw new Refusal('overlap lanes must belong to the selected repository')
      decisionPaths(args.path, '--path')
      if (new Set(args.path).size !== args.path.length) throw new Refusal('duplicate overlap path')
      if (!['serialize', 'split'].includes(args.resolution)) throw new UsageError('--resolution must be serialize or split')
      const before = issueKey(plan, Number(args.before), args.repo), after = issueKey(plan, Number(args.after), args.repo)
      if (![a.issue, b.issue].includes(before) || ![a.issue, b.issue].includes(after) || before === after) throw new Refusal('merge dependency must order the two lanes')
      const existing = plan.overlaps.find((entry) => pairKey(entry.issue_a, entry.issue_b) === pairKey(a.issue, b.issue))
      if (existing && (existing.resolution !== args.resolution || existing.merge_dependency.before !== before || existing.merge_dependency.after !== after)) throw new Refusal('existing overlap has a different resolution or merge dependency')
      if (existing && args.path.some((path) => existing.paths.includes(path))) throw new Refusal('duplicate overlap decision')
      for (const path of args.path) {
        if (/[*?\\]/.test(path) || ![a, b].some((lane) => effectiveFence(lane).some((entry) => !uninterpretable(entry.path) && pathMatches(path, entry.path)))) throw new Refusal(`path ${path} must be a concrete path covered by a lane`)
      }
      const [issue_a, issue_b] = [a.issue, b.issue].sort((x, y) => String(x).localeCompare(String(y), 'en', { numeric: true }))
      decisions = [...plan.overlaps.filter((entry) => entry !== existing), { issue_a, issue_b, paths: [...(existing?.paths ?? []), ...args.path], resolution: args.resolution, merge_dependency: { before, after } }]
    } else if (command === 'expand') {
      fields(input, [], 'expand input')
      if (args.path?.length !== 1) throw new UsageError('expand requires exactly one --path')
      const lane = workingLanes(plan).find((entry) => entry.lane === args.lane)
      if (args.repo !== undefined && (!lane || itemRepository(plan, lane) !== repository(args.repo))) throw new Refusal('expand repository does not match lane')
      expandLane(plan, requireId('lane', args.lane), args.path, at, args.reason)
    } else if (command === 'fix-request' || command === 'reactivate') {
      const number = selection()
      const retained = plan.retained_lanes?.find((entry) => entry.lane.issue === number)
      const issue = plan.issues.find((entry) => entry.number === number)
      if (!retained || issue?.verdict !== 'handed-off') throw new Refusal('fix round requires a retained handed-off lane')
      const url = issue.url.replace(/\/issues\/[^/]+$/, `/pull/${issue.pr}`)
      let pr
      try { pr = JSON.parse(execFileSync('gh', ['pr', 'view', url, '--json', 'state'], { encoding: 'utf8' })) }
      catch { throw new Refusal('fix round PR state is indeterminate') }
      if (pr.state !== 'OPEN') throw new Refusal('fix round requires an open delivery PR')
      if (command === 'fix-request') {
        if (retained.state === 'working') throw new Refusal('lane already holds a Working slot')
        retained.state = 'pending'
      } else {
        if (retained.state !== 'pending') throw new Refusal('reactivation requires a pending fix request')
        reactivationClaim = { issue, lane: retained.lane }
        const candidate = planWire(plan)
        const lane = candidate.retained_lanes.find((entry) => entry.lane.lane === retained.lane.lane).lane
        assertDispatchCapacity(root, candidate, lane, slate)
        const previousFile = join(root, 'runs', retained.lane.run_id, 'run.json')
        let previous
        if (existsSync(previousFile) || args['run-id']) {
          validateFile('run', previousFile, 'previous run')
          previous = readJson(previousFile, 'previous run')
        }
        if (!args['run-id'] && previous?.outcome != null) throw new Refusal('terminal previous run requires reactivate --run-id for a fresh fix run')
        if (args['run-id']) {
          if (previous.outcome === null) throw new Refusal('a fresh run requires a terminal previous run')
          const next = requireId('run-id', args['run-id'])
          if (existsSync(join(root, 'runs', next))) throw new Refusal('fresh run already exists')
          retained.lane.fence = effectiveFence(retained.lane)
          retained.lane.expansions = []
          retained.lane.run_id = next
        }
        retained.state = 'working'
      }
    } else if (command === 'handoff') {
      fields(input, [], 'handoff input')
      const number = selection(), pr = Number(args.pr)
      if (!Number.isInteger(pr) || pr < 1) throw new UsageError('--pr must be a positive PR number')
      if (!plan.lanes.some((lane) => lane.issue === number) && !plan.retained_lanes?.some((entry) => entry.lane.issue === number)) throw new Refusal(`issue #${number} has no live source lane`)
      if (plan.retained_lanes?.some((entry) => entry.lane.issue === number) && plan.issues.find((issue) => issue.number === number)?.pr !== pr) throw new Refusal('re-handoff must retain the delivery PR binding')
      const repeat = plan.retained_lanes?.some((entry) => entry.lane.issue === number) && plan.issues.find((issue) => issue.number === number)?.pr === pr
      if (!repeat && ((plan.merge_queue ?? []).some((entry) => itemRepository(plan, entry) === itemRepository(plan, { repo: args.repo }) && entry.pr === pr) ||
          plan.issues.some((issue) => itemRepository(plan, issue) === itemRepository(plan, { repo: args.repo }) && issue.verdict === 'handed-off' && issue.pr === pr))) {
        throw new Refusal(`duplicate PR ${pr}`)
      }
      const retained = plan.retained_lanes?.find((entry) => entry.lane.issue === number)
      if (retained?.state === 'working' && args['expected-revision'] === undefined) {
        throw new Refusal('working retained lane requires handoff --expected-revision from the current handoff check')
      }
      if (args['expected-revision'] !== undefined && args['expected-revision'] !== String(last.seq)) {
        throw new Refusal('handoff --expected-revision does not match the current plan revision; repeat the live handoff check')
      }
      const lane = plan.lanes.find((entry) => entry.issue === number) ?? retained.lane
      releaseClaimForHandoff(plan.issues.find((issue) => issue.number === number), lane, pr, args.reason)
      retireIssue(plan, number, 'handed-off')
      plan.issues.find((issue) => issue.number === number).pr = pr
    } else if (command === 'wave-release') {
      fields(input, [], 'wave-release input')
      const number = Number(args.wave)
      if (!Number.isInteger(number) || number < 1) throw new UsageError('--wave must be a positive wave number')
      releaseWave(plan, number)
    } else if (command === 'queue-order') {
      fields(input, ['issues'], 'queue-order input')
      const queue = plan.merge_queue ?? []
      if (!Array.isArray(input.issues) || input.issues.length !== queue.length ||
          new Set(input.issues).size !== queue.length ||
          input.issues.some((number) => !queue.some((entry) => entry.issue === number))) {
        throw new Refusal('queue-order issues must be a permutation of the current merge queue')
      }
      plan.merge_queue = input.issues.map((number) => queue.find((entry) => entry.issue === number))
    } else {
      fields(input, ['releases', 'addition', 'waves'], 'retirement input')
      const number = selection()
      const source = workingLanes(plan).find((lane) => lane.issue === number)
      if (!source && (command !== 'done' || plan.issues.find((issue) => issue.number === number)?.verdict !== 'handed-off')) {
        throw new Refusal(`issue #${number} has no live source lane`)
      }
      if (!source && ((input.releases?.length ?? 0) > 0)) throw new Refusal('a handed-off issue has no source fence to release')
      retireIssue(plan, number)
      let waves
      if (input.addition) waves = appendIssue(plan, input.addition, args.policy)
      const releases = [...(input.releases ?? [])]
      if (command === 'release') {
        if (!args.lane || !args.path?.length) throw new UsageError('release requires --lane and --path')
        releases.push({ lane: args.lane, paths: args.path })
      }
      for (const release of releases) {
        fields(release, ['lane', 'paths'], 'release')
        expandLane(plan, release.lane, release.paths, at, args.reason, {
          source, fresh: release.lane === input.addition?.lane?.lane,
        })
      }
      placeWaves(plan, waves)
      placeWaves(plan, input.waves)
      decisions = [...plan.overlaps, ...(input.addition?.overlaps ?? []).map(({ paths, ...decision }) => decision)]
    }
    computeOverlaps(plan, decisions)
    if (['handoff', 'done', 'release'].includes(command)) queueWaitingHandoffs(plan)
    const seq = document.revisions.length
    const prev_digest = last?.digest ?? 'genesis'
    const reason = command === 'wave-release' ? `wave-release: ${args.reason}` : args.reason
    wire = planWire(plan)
    const entry = { seq, prev_digest, at, reason, plan: wire }
    entry.digest = chainDigest({ seq, plan: wire, at, reason }, prev_digest)
    document.revisions.push(entry)
    if (command === 'reactivate' || command === 'add-issue' || input.addition) {
      // Validate the complete candidate before publishing an external claim
      // transaction or widening the held reservation.
      const candidate = `${canonical}.candidate.${process.pid}.${randomBytes(4).toString('hex')}`
      writeFileSync(candidate, `${JSON.stringify(document, null, 2)}\n`, { flag: 'wx' })
      try {
        validateFile('plan', candidate, command === 'reactivate' ? 'candidate before claim restoration' : 'candidate before lock widening')
      } finally {
        unlinkSync(candidate)
      }
    }
    if (command === 'reactivate') {
      restoreClaimForReactivation(reactivationClaim.issue, reactivationClaim.lane, args)
    }
    // Prove the complete candidate valid before reserving any additional
    // issues. A refused revision must leave the held reservation unchanged.
    if (command === 'add-issue' || input.addition) {
      acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'],
        issues: [...new Set([...held.issues, ...plan.issues.map((issue) => issue.number)])] })
    }
    writeValidated('plan', canonical, document)
    const synced = syncRevision(root, slate, session, last?.plan, wire)
    return `appended revision ${seq}: ${command}${synced ? `\n${synced}` : ''}`
  }))
}

function main(argv) {
  const [command, ...rest] = argv
  if (command === 'overlap' && rest.length === 1 && rest[0] === '--help') return 'plan-revise.mjs overlap --slate ID --session ID --owner-token TOKEN --lane-a ID --lane-b ID --path PATH... --resolution serialize|split --before N --after N --reason TEXT [--repo OWNER/REPO]'
  const usage = 'plan-revise.mjs genesis|overlap|add-issue|expand|release|done|handoff|fix-request|reactivate|wave-release|queue-order|replace-unprovisioned|base-move|membership … (see the header)'
  if (!['genesis', 'add-issue', 'overlap', 'expand', 'release', 'done', 'handoff', 'fix-request', 'reactivate', 'wave-release', 'queue-order', 'replace-unprovisioned', 'base-move', 'membership'].includes(command)) throw new UsageError(usage)
  if (command === 'membership') return membershipCommand(parseFlags(rest, new Set(['slate', 'session', 'owner-token']), new Set(['close', 'dry-run'])))
  const allowed = command === 'base-move'
    ? ['repo', 'repo-root', 'slate', 'session', 'owner-token', 'new-base', 'input', 'reason', 'done', 'reverified', 'at', 'milestone', 'issues']
    : ['slate', 'session', 'owner-token', 'reason', 'at', 'repo',
      ...({ genesis: ['input'], 'add-issue': ['input', 'policy'], 'replace-unprovisioned': ['lane', 'run-id', 'policy'], overlap: ['lane-a', 'lane-b', 'path', 'resolution', 'before', 'after'], expand: ['lane', 'path'],
        release: ['issue', 'lane', 'path', 'input'], done: ['issue', 'input', 'policy'], handoff: ['issue', 'pr', 'expected-revision'], 'fix-request': ['issue'],
        reactivate: ['issue', 'run-id', 'claim-record-file', 'claim-label', 'model-label', 'family', 'runtime-environment', 'registry-snapshot', 'allow-label-less', 'approve-review-pullback'],
        'wave-release': ['wave'], 'queue-order': ['input'] }[command])]
  const args = parseScopeFlags(parseFlags(rest, new Set(allowed), new Set(['allow-label-less', 'approve-review-pullback']), new Set(['done', 'path', 'reverified'])))
  return command === 'base-move' ? baseMove(args) : decisionWrite(command, args)
}

if (realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url))) runCli(main)
