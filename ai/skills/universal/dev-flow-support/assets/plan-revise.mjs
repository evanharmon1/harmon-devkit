#!/usr/bin/env node
// plan-revise.mjs — the mechanical half of a dispatch-plan recompute
// (`<git-common-dir>/dev-flow-v2/slates/<slate-id>/plan.json`,
// harmon-devkit#1296).
//
// Usage:
//   plan-revise.mjs genesis --slate ID --session ID --owner-token TOKEN --input PLAN --reason TEXT
//   plan-revise.mjs add-issue --slate ID --session ID --input ADDITION --reason TEXT
//   plan-revise.mjs expand --slate ID --session ID --lane ID --path PATH --reason TEXT
//   plan-revise.mjs release --slate ID --session ID --issue N --lane ID --path PATH... --reason TEXT
//   plan-revise.mjs done --slate ID --session ID --issue N --reason TEXT [--input DECISIONS]
//   plan-revise.mjs handoff --slate ID --session ID --issue N --pr N --reason TEXT
//   plan-revise.mjs wave-release --slate ID --session ID --wave N --reason TEXT
//   plan-revise.mjs queue-order --slate ID --session ID --input ORDER --reason TEXT
// Queue-order input: {issues: [N, ...]}, a permutation of the current queue.
// All commands accept --at TS; writes after genesis require the held owner token.
// Genesis input is planContent, with overlaps supplying resolution/dependency decisions;
// paths are computed. It requires a held reservation and never acquires a lock.
// Addition input: {issue, lane, profile: {lane, policy}, overlaps?: [...], waves?: [...]}.
// Done/release input: {releases?: [{lane, paths}], addition?: ADDITION, waves?: [...]}.
// A newly introduced receiver uses addition; existing receivers gain dated expansions.
// Optional waves are the operator's complete placement decision; no wave is guessed.
//   plan-revise.mjs base-move --slate ID --session ID --new-base SHA --reason TEXT
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
import { randomBytes } from 'node:crypto'
import { existsSync, lstatSync, mkdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  Refusal,
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

// Every git call reads the real objects: replace refs are disabled, so an
// overridden history cannot hide a moved path (a grafts file, which no flag
// disables, is refused in baseMove).
function git(args) {
  return execFileSync('git', ['--no-replace-objects', ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' },
  })
}

function resolveCommit(value, label) {
  try {
    return git(['rev-parse', '--verify', '--quiet', `${value}^{commit}`]).trim()
  } catch {
    throw new Refusal(`${label} ${value} is not a commit in this repository`)
  }
}

// Fence matching mirrors orchestrate/assets/fence-check.sh: per path
// component, literal first; a component holding `*` or `?` is a glob within
// that component (`{` and a bare `[x]` stay literal), and a `**` component
// matches any number of components. A component this matcher cannot
// interpret the same way never gets here (see uninterpretable).
function componentMatches(part, pattern) {
  if (part === pattern) return true
  if (!/[*?]/.test(pattern)) return false
  const source = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')
  // s and u: `?`/`*` match any code point, line breaks included, as bash case does.
  return new RegExp(`^${source}$`, 'su').test(part)
}

function matchParts(pattern, path, pi = 0, qi = 0) {
  if (pi === pattern.length) return qi === path.length
  if (pattern[pi] === '**') {
    for (let next = qi; next <= path.length; next += 1) if (matchParts(pattern, path, pi + 1, next)) return true
    return false
  }
  return qi < path.length && componentMatches(path[qi], pattern[pi]) && matchParts(pattern, path, pi + 1, qi + 1)
}

export function pathMatches(path, pattern) {
  return matchParts(pattern.split('/'), path.split('/'))
}

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

export function reviseForBaseMove(previous, { newBase, done, changed, reverified = [], root }) {
  const plan = structuredClone(previous)
  const doneSet = new Set(done)
  const known = new Set(plan.issues.map((issue) => issue.number))
  const unknown = done.filter((number) => !known.has(number))
  if (unknown.length > 0) throw new Refusal(`--done names issue(s) not in the plan: ${unknown.join(', ')}`)

  const live = plan.issues.filter((issue) => !['done', 'handed-off'].includes(issue.verdict) && !doneSet.has(issue.number))
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
    const liveLanes = plan.lanes.filter((lane) => !doneSet.has(lane.issue))
    for (const pattern of [...liveLanes.flatMap(fencePaths), ...live.flatMap((issue) => issue.candidate_files ?? [])]) {
      if (uninterpretable(pattern)) refusals.push(`pattern needs orchestrator judgment (not matched here): ${pattern}`)
    }
  }
  for (const lane of plan.lanes.filter((lane) => !doneSet.has(lane.issue))) {
    const patterns = fencePaths(lane)
    for (const path of changed) {
      if (patterns.some((pattern) => pathMatches(path, pattern))) {
        if (!reverifiedSet.has(lane.issue)) refusals.push(`base move touches lane ${lane.lane} (#${lane.issue}) fence: ${path}`)
      }
    }
  }
  for (const issue of live) {
    for (const path of changed) {
      if ((issue.candidate_files ?? []).some((pattern) => pathMatches(path, pattern))) {
        if (!reverifiedSet.has(issue.number)) refusals.push(`base move touches issue #${issue.number} candidate file: ${path}`)
      }
    }
  }
  if (refusals.length > 0) {
    throw new Refusal(`this recompute needs orchestrator judgment; nothing was written:\n  - ${refusals.join('\n  - ')}`)
  }

  plan.base_sha = newBase
  for (const issue of plan.issues) if (doneSet.has(issue.number)) issue.verdict = 'done'
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
  return plan
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

  return withMutex(join(root, 'dispatch'), () => withMutex(canonical, () => {
    const document = readJson(canonical, 'plan')
    if (document.slate_id !== slate) throw new Refusal(`${canonical} records slate_id ${JSON.stringify(document.slate_id)}, not ${slate}`)
    const last = document.revisions.at(-1)
    const oldBase = last.plan.base_sha
    const grafts = git(['rev-parse', '--path-format=absolute', '--git-path', 'info/grafts']).trim()
    if (existsSync(grafts)) {
      throw new Refusal(`${grafts} exists; a grafted history cannot prove what a base move changed, refusing`)
    }
    const newBase = resolveCommit(args['new-base'], '--new-base')
    resolveCommit(oldBase, 'the plan base')
    if (newBase === oldBase) throw new Refusal(`base ${oldBase} did not move; nothing to revise`)
    try {
      git(['merge-base', '--is-ancestor', oldBase, newBase])
    } catch {
      throw new Refusal(`new base ${newBase} does not descend from the plan base ${oldBase}`)
    }
    if (isBefore(at, last.at)) throw new Refusal(`${at} precedes revision ${last.seq} (${last.at})`)
    const changed = git(['diff', '--no-relative', '--name-only', '--no-renames', '-z', oldBase, newBase]).split('\0').filter(Boolean)
    const plan = reviseForBaseMove(last.plan, { newBase, done, changed, reverified, root })
    const seq = document.revisions.length
    const reason = `${args.reason}${reverified.length ? `, reverified ${reverified.map((n) => `#${n}`).join(' ')}` : ''}`
    const entry = { seq, prev_digest: last.digest, at, reason, plan }
    entry.digest = chainDigest({ seq, plan, at, reason }, last.digest)
    document.revisions.push(entry)
    writeValidated('plan', canonical, document)
    return `appended revision ${seq}: base ${oldBase.slice(0, 12)} → ${newBase.slice(0, 12)}${done.length ? `, done ${done.map((n) => `#${n}`).join(' ')}` : ''}${reverified.length ? `, reverified ${reverified.map((n) => `#${n}`).join(' ')}` : ''}`
  }))
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
  return [a, b].sort((x, y) => x - y).join(':')
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
    const shared = [...new Set(left.candidate_files.filter((path) => right.candidate_files.includes(path)))].sort()
    const collision = left.candidate_files.some((a) => right.candidate_files.some((b) => mayOverlap(a, b)))
    const key = pairKey(left.number, right.number)
    if (!collision) continue
    const decision = byPair.get(key)
    if (!decision || !['serialize', 'split'].includes(decision.resolution) || !decision.merge_dependency) {
      throw new Refusal(`unresolved overlap ${key}; supply resolution and merge_dependency`)
    }
    if (!shared.length) throw new Refusal(`glob overlap ${key} needs a shared candidate entry to record its resolution`)
    const [issue_a, issue_b] = [left.number, right.number].sort((a, b) => a - b)
    overlaps.push({ issue_a, issue_b, paths: shared, resolution: decision.resolution, merge_dependency: decision.merge_dependency })
    byPair.delete(key)
  }
  if (byPair.size) throw new Refusal(`overlap decisions name no live candidate intersection: ${[...byPair.keys()].join(', ')}`)
  plan.overlaps = overlaps
  // Cross-wave ownership still needs a path-specific decision. The schema's
  // same-wave exact-string check alone cannot establish this property.
  for (let i = 0; i < plan.lanes.length; i += 1) for (const right of plan.lanes.slice(i + 1)) {
    const left = plan.lanes[i]
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

function appendIssue(plan, input) {
  fields(input, ['issue', 'lane', 'profile', 'overlaps', 'waves'], 'addition')
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
      queue.push({ issue: issue.number, pr: issue.pr })
      added = true
    }
  } while (added)
  if (plan.merge_queue !== undefined || queue.length) plan.merge_queue = queue
}

function expandLane(plan, laneName, paths, at, reason, { source, fresh = false } = {}) {
  const lane = plan.lanes.find((entry) => entry.lane === laneName)
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
    for (const other of plan.lanes.filter((entry) => entry.lane !== laneName)) {
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
  const input = args.input ? readJson(args.input, 'decision input') : {}
  if (['genesis', 'add-issue', 'queue-order'].includes(command) && !args.input) throw new UsageError('--input is required')
  if (command === 'genesis' && !args['owner-token']) throw new Refusal('genesis requires --owner-token for an already-held lock')
  mkdirSync(dirname(canonical), { recursive: true })
  return withMutex(canonical, () => {
    if (command === 'genesis' && existsSync(canonical)) throw new Refusal(`slate ${slate} already has a plan`)
    if (command !== 'genesis' && !existsSync(canonical)) throw new Refusal(`no plan for slate ${slate}`)
    if (command !== 'genesis') validateFile('plan', canonical, 'existing plan')
    const document = command === 'genesis' ? { schema: 1, slate_id: slate, revisions: [] } : readJson(canonical, 'plan')
    if (document.slate_id !== slate) throw new Refusal('plan slate_id does not match its directory')
    const last = document.revisions.at(-1)
    if (last && isBefore(at, last.at)) throw new Refusal(`${at} precedes revision ${last.seq} (${last.at})`)
    const plan = structuredClone(last?.plan ?? input)
    const held = acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'] })
    let decisions = plan.overlaps
    if (command === 'genesis') {
      if (!Array.isArray(plan.issues)) throw new UsageError('plan.issues must be an array')
      if (!Array.isArray(plan.lanes)) throw new UsageError('plan.lanes must be an array')
      for (const issue of plan.issues) if (issue?.verdict !== 'done') decisionPaths(issue?.candidate_files, 'issue.candidate_files')
      for (const lane of plan.lanes) decisionPaths(lane?.fence, 'lane.fence', true)
      const outside = plan.issues?.filter((issue) => !held.issues.includes(issue.number)) ?? []
      if (outside.length) throw new Refusal(`genesis issues outside the lock reservation: ${outside.map((issue) => issue.number).join(', ')}`)
    } else if (command === 'add-issue') {
      const waves = appendIssue(plan, input)
      placeWaves(plan, waves)
      decisions = [...plan.overlaps, ...(input.overlaps ?? [])]
    } else if (command === 'expand') {
      fields(input, [], 'expand input')
      if (args.path?.length !== 1) throw new UsageError('expand requires exactly one --path')
      expandLane(plan, requireId('lane', args.lane), args.path, at, args.reason)
    } else if (command === 'handoff') {
      fields(input, [], 'handoff input')
      const number = Number(args.issue), pr = Number(args.pr)
      if (!Number.isInteger(number) || number < 1) throw new UsageError('--issue must be a positive issue number')
      if (!Number.isInteger(pr) || pr < 1) throw new UsageError('--pr must be a positive PR number')
      if (!plan.lanes.some((lane) => lane.issue === number)) throw new Refusal(`issue #${number} has no live source lane`)
      if ((plan.merge_queue ?? []).some((entry) => entry.pr === pr) ||
          plan.issues.some((issue) => issue.verdict === 'handed-off' && issue.pr === pr)) {
        throw new Refusal(`duplicate PR ${pr}`)
      }
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
      const number = Number(args.issue)
      if (!Number.isInteger(number) || number < 1) throw new UsageError('--issue must be a positive issue number')
      const source = plan.lanes.find((lane) => lane.issue === number)
      if (!source && (command !== 'done' || plan.issues.find((issue) => issue.number === number)?.verdict !== 'handed-off')) {
        throw new Refusal(`issue #${number} has no live source lane`)
      }
      if (!source && ((input.releases?.length ?? 0) > 0)) throw new Refusal('a handed-off issue has no source fence to release')
      retireIssue(plan, number)
      let waves
      if (input.addition) waves = appendIssue(plan, input.addition)
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
      decisions = [...plan.overlaps, ...(input.addition?.overlaps ?? [])]
    }
    computeOverlaps(plan, decisions)
    if (['handoff', 'done', 'release'].includes(command)) queueWaitingHandoffs(plan)
    const seq = document.revisions.length
    const prev_digest = last?.digest ?? 'genesis'
    const reason = command === 'wave-release' ? `wave-release: ${args.reason}` : args.reason
    const entry = { seq, prev_digest, at, reason, plan }
    entry.digest = chainDigest({ seq, plan, at, reason }, prev_digest)
    document.revisions.push(entry)
    // Prove the complete candidate valid before reserving any additional
    // issues. A refused revision must leave the held reservation unchanged.
    if (command === 'add-issue' || input.addition) {
      const candidate = `${canonical}.candidate.${process.pid}.${randomBytes(4).toString('hex')}`
      writeFileSync(candidate, `${JSON.stringify(document, null, 2)}\n`, { flag: 'wx' })
      try {
        validateFile('plan', candidate, 'candidate before lock widening')
      } finally {
        unlinkSync(candidate)
      }
      acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'],
        issues: [...new Set([...held.issues, ...plan.issues.map((issue) => issue.number)])] })
    }
    writeValidated('plan', canonical, document)
    return `appended revision ${seq}: ${command}`
  })
}

function main(argv) {
  const [command, ...rest] = argv
  const usage = 'plan-revise.mjs genesis|add-issue|expand|release|done|handoff|wave-release|queue-order|base-move … (see the header)'
  if (!['genesis', 'add-issue', 'expand', 'release', 'done', 'handoff', 'wave-release', 'queue-order', 'base-move'].includes(command)) throw new UsageError(usage)
  const allowed = command === 'base-move'
    ? ['slate', 'session', 'owner-token', 'new-base', 'reason', 'done', 'reverified', 'at', 'milestone', 'issues']
    : ['slate', 'session', 'owner-token', 'reason', 'at',
      ...({ genesis: ['input'], 'add-issue': ['input'], expand: ['lane', 'path'],
        release: ['issue', 'lane', 'path', 'input'], done: ['issue', 'input'], handoff: ['issue', 'pr'], 'wave-release': ['wave'], 'queue-order': ['input'] }[command])]
  const args = parseScopeFlags(parseFlags(rest, new Set(allowed), new Set(), new Set(['done', 'path', 'reverified'])))
  return command === 'base-move' ? baseMove(args) : decisionWrite(command, args)
}

if (realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url))) runCli(main)
