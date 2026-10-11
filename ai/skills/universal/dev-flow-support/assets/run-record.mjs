#!/usr/bin/env node
// run-record.mjs — the one writer for a dev-flow v2 run record
// (`<git-common-dir>/dev-flow-v2/runs/<run-id>/run.json`), plus the slate
// lock both durable-state writers take (harmon-devkit#1296).
//
// Usage:
//   run-record.mjs transition   --slate ID --session ID --run-id ID --stage STAGE [--exit TEXT] [--at TS]
//   run-record.mjs intervention --slate ID --session ID --run-id ID --kind asked|other --note TEXT [--ruling FILE] [--at TS]
//   run-record.mjs bind-pr      --slate ID --session ID --run-id ID --number N --url URL [--at TS]
//   run-record.mjs promote      --slate ID --session ID --run-id ID --head SHA --fingerprint TEXT [--exit TEXT] [--at TS]
//   run-record.mjs close        --slate ID --session ID --run-id ID [--outcome capped|escalated|abandoned --exit TEXT] [--at TS]
//   run-record.mjs lock acquire --slate ID --session ID [--milestone N] [--issues N,N,...]
//   run-record.mjs lock release --slate ID --session ID [--force --reason TEXT]
//   run-record.mjs lock status  --slate ID
//
// A run belongs to exactly one slate: its first helper write requires --run-id
// to be a lane in some revision of this slate's plan and records the slate in
// `runs/<run-id>/owner-slate`; every later write requires the same slate. Each
// write takes the slate lock (acquiring it on first use, its scope always
// derived from the current plan). Then, under a short-lived per-file mutex,
// it builds the complete candidate beside run.json, validates it with
// `validate-result-schemas.mjs run --receipts <candidate>` plus every
// `adjudications/*.json` in the run directory (or `--no-adjudications` when
// there are none), renames it over run.json, and validates the canonical
// readback the same way. A refusal before the rename leaves run.json as it
// was; a readback failure after the rename leaves the new content in place
// and is reported as a blocker. The validator owns the
// lifecycle rules (allowed edges, chronology, chains, projections); this
// writer adds the one it cannot see: once the run is promoted, no entry may
// be dated after `promotion.promoted_at` (the validator does not bound
// `pr_bindings[].bound_at`).
//
// `--exit` on `transition` and `promote` records how the stage being left
// ended; it is required when that entry has no exit yet. `close` records a
// non-promotion terminal outcome (if the run is still open) and then moves
// the run's orchestrator files from
// `slates/<slate>/orchestrator/<run-id>/` into `runs/<run-id>/orchestrator/`.
//
// `--ruling FILE` appends ` [ruling <path> sha256=<hex>]` to the intervention
// note: run.schema.json closes intervention items, so the digest travels in
// the note, where a later reader can compare it against the file.
//
// Exit codes: 0 written (or an idempotent no-op), 1 refused, 2 usage.
// The state root is always resolved from the current directory's
// `git rev-parse --git-common-dir`.

import { createHash, randomBytes } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
  linkSync,
  openSync,
  closeSync,
} from 'node:fs'
import { hostname } from 'node:os'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const ASSET_DIR = dirname(realpathSync(fileURLToPath(import.meta.url)))
const VALIDATOR = join(ASSET_DIR, 'validate-result-schemas.mjs')
const TIMESTAMP = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$/
const SAFE_ID = /^[A-Za-z0-9._-]+$/

export class Refusal extends Error {}
export class UsageError extends Error {}

// ---------------------------------------------------------------------------
// Shared helpers (imported by plan-revise.mjs)
// ---------------------------------------------------------------------------

export function stateRoot(cwd = process.cwd()) {
  let common
  try {
    common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim()
  } catch {
    throw new Refusal('could not resolve the Git common directory from the current directory')
  }
  if (common === '') throw new Refusal('could not resolve the Git common directory from the current directory')
  return { common, root: join(common, 'dev-flow-v2') }
}

export function requireId(name, value) {
  if (typeof value !== 'string' || !SAFE_ID.test(value) || value === '.' || value === '..') {
    throw new UsageError(`--${name} is missing or unsafe (expected ${SAFE_ID})`)
  }
  return value
}

export function resolveAt(value) {
  if (value === undefined) return new Date().toISOString().replace(/\.[0-9]{3}Z$/, 'Z')
  if (!TIMESTAMP.test(value) || !Number.isFinite(Date.parse(value))) {
    throw new UsageError(`--at must be a UTC timestamp like 2026-10-11T12:00:00Z, got ${JSON.stringify(value)}`)
  }
  return value
}

export function isBefore(a, b) {
  return Date.parse(a) < Date.parse(b)
}

// Canonical JSON and chain digest — byte-for-byte the convention
// validate-result-schemas.mjs verifies (sorted keys, undefined dropped).
export function canonicalJson(value) {
  if (value === undefined) return undefined
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map((v) => (v === undefined ? 'null' : canonicalJson(v))).join(',')}]`
  const keys = Object.keys(value)
    .filter((k) => value[k] !== undefined)
    .sort()
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`
}

export function chainDigest(contentFields, prevDigest) {
  return createHash('sha256')
    .update(canonicalJson({ ...contentFields, prev_digest: prevDigest }), 'utf8')
    .digest('hex')
}

export function sha256File(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex')
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

function ownerAlive(owner) {
  if (!owner || owner.host !== hostname() || !Number.isInteger(owner.pid)) return true
  try {
    process.kill(owner.pid, 0)
    return true
  } catch (error) {
    return error.code === 'EPERM'
  }
}

// withMutex — a short-lived exclusive section around one read-modify-write.
// The mutex is `<target>.wlock`, created O_EXCL and stamped with pid/host. A
// mutex whose owner is a dead process on this host is broken under a
// `.break` directory guard that re-reads the stamp first, so two contenders
// cannot both break it and then both enter.
export function withMutex(target, fn, { timeoutMs = 15000 } = {}) {
  const lock = `${target}.wlock`
  const stamp = JSON.stringify({ pid: process.pid, host: hostname(), nonce: randomBytes(8).toString('hex') })
  const deadline = Date.now() + timeoutMs
  for (;;) {
    try {
      const fd = openSync(lock, 'wx')
      writeFileSync(fd, stamp)
      closeSync(fd)
      break
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
    }
    let observed = null
    try {
      observed = readFileSync(lock, 'utf8')
    } catch {
      continue
    }
    let owner = null
    try {
      owner = JSON.parse(observed)
    } catch {
      owner = null
    }
    if (owner && !ownerAlive(owner)) {
      const guard = `${lock}.break`
      try {
        mkdirSync(guard)
        try {
          if (readFileSync(lock, 'utf8') === observed) unlinkSync(lock)
        } catch {
          // already gone — the next attempt decides
        } finally {
          rmdirSync(guard)
        }
        continue
      } catch {
        // another contender is breaking it
      }
    }
    if (Date.now() > deadline) {
      throw new Refusal(`timed out waiting for ${lock}; inspect it (and any ${lock}.break) before retrying`)
    }
    sleepMs(100)
  }
  try {
    return fn()
  } finally {
    try {
      if (readFileSync(lock, 'utf8') === stamp) unlinkSync(lock)
    } catch {
      // nothing to release
    }
  }
}

export function readJson(file, label) {
  let text
  try {
    text = readFileSync(file, 'utf8')
  } catch {
    throw new Refusal(`${label} not found: ${file}`)
  }
  try {
    return JSON.parse(text)
  } catch {
    throw new Refusal(`${label} is not valid JSON: ${file}`)
  }
}

// A run record is always validated in strict mode: its own receipts bind the
// stages, and every adjudication document beside it is supplied (or the
// confirmed-zero flag when there is none) — the review skill's recipe for
// every run.json replacement. The candidate sits beside run.json, so both
// share one run directory.
function contextArgs(kind, file) {
  if (kind !== 'run') return []
  const directory = join(dirname(file), 'adjudications')
  const documents = existsSync(directory)
    ? readdirSync(directory)
        .filter((name) => name.endsWith('.json'))
        .sort()
    : []
  const adjudications =
    documents.length === 0 ? ['--no-adjudications'] : documents.flatMap((name) => ['--adjudication', join(directory, name)])
  return ['--receipts', file, ...adjudications]
}

function runValidator(kind, file) {
  try {
    execFileSync(process.execPath, [VALIDATOR, kind, file, ...contextArgs(kind, file)], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    return null
  } catch (error) {
    return `${error.stderr || ''}${error.stdout || ''}`.trim() || `validator exited ${error.status}`
  }
}

export function validateFile(kind, file, label) {
  const failure = runValidator(kind, file)
  if (failure !== null) throw new Refusal(`${label} failed \`${kind}\` validation:\n${failure}`)
}

// writeValidated — the candidate, validate, rename, readback sequence.
export function writeValidated(kind, canonical, document) {
  const candidate = `${canonical}.candidate.${process.pid}.${randomBytes(4).toString('hex')}`
  writeFileSync(candidate, `${JSON.stringify(document, null, 2)}\n`)
  const failure = runValidator(kind, candidate)
  if (failure !== null) {
    unlinkSync(candidate)
    throw new Refusal(`candidate refused by \`${kind}\` validation; ${canonical} is unchanged:\n${failure}`)
  }
  renameSync(candidate, canonical)
  const readback = runValidator(kind, canonical)
  if (readback !== null) {
    throw new Refusal(`BLOCKER: ${canonical} failed readback validation after rename:\n${readback}`)
  }
}

// ---------------------------------------------------------------------------
// Slate lock
// ---------------------------------------------------------------------------
//
// One lock file per slate under `<root>/locks/<slate-id>.json`, recording the
// holding session and the slate's scope: its milestone (when milestone-backed)
// and its issue set. Acquisition runs under the locks directory's mutex and is
// refused while another session holds the same slate id, the same milestone,
// or any of the same issues — so the same work opened under a second slate id
// is refused too. A session re-acquiring its own lock is a no-op.

function lockPaths(root, slate) {
  const dir = join(root, 'locks')
  return { dir, file: join(dir, `${slate}.json`), registry: join(dir, 'registry') }
}

// currentPlan — the slate's latest plan revision, or null when no plan exists.
export function currentPlan(root, slate) {
  const file = join(root, 'slates', slate, 'plan.json')
  if (!existsSync(file)) return null
  const document = readJson(file, 'plan')
  const plan = Array.isArray(document.revisions) ? document.revisions.at(-1)?.plan : null
  if (!Array.isArray(plan?.issues) || !Array.isArray(plan?.lanes)) throw new Refusal(`plan has no readable issues and lanes: ${file}`)
  return plan
}

// readRunOwner — the run's recorded owning slate, or null before its first
// helper write. The record is created whole (temp file, then link), so an
// empty or partial one is never written here and is refused as malformed.
function readRunOwner(root, runId) {
  const ownerFile = join(root, 'runs', runId, 'owner-slate')
  if (!existsSync(ownerFile)) return null
  const owner = readFileSync(ownerFile, 'utf8').trim()
  if (!SAFE_ID.test(owner) || owner === '.' || owner === '..') {
    throw new Refusal(`owner record ${ownerFile} is empty or malformed; inspect it before writing this run`)
  }
  return owner
}

// assertRunOwner — refuse a run another slate owns. Runs before the slate
// lock is taken, so a refused write leaves no lock behind.
export function assertRunOwner(root, slate, runId) {
  const owner = readRunOwner(root, runId)
  if (owner !== null && owner !== slate) throw new Refusal(`run ${runId} is owned by slate ${owner}, not ${slate}; refusing`)
}

// bindRunToSlate — a run's owning slate is recorded once, at its first helper
// write, in `runs/<run-id>/owner-slate`. That first write requires the run to
// be a lane in some revision of this slate's plan; every later write only
// requires the locked slate to equal the recorded owner, so a run retired from
// the current revision still writes and closes.
export function bindRunToSlate(root, slate, runId) {
  const ownerFile = join(root, 'runs', runId, 'owner-slate')
  if (readRunOwner(root, runId) === null) {
    const file = join(root, 'slates', slate, 'plan.json')
    const revisions = existsSync(file) ? readJson(file, 'plan').revisions : []
    if (!Array.isArray(revisions) || !revisions.some((revision) => (revision?.plan?.lanes ?? []).some((lane) => lane?.run_id === runId))) {
      throw new Refusal(`run ${runId} is not a lane in any revision of slate ${slate}'s plan; refusing to write it under this slate`)
    }
    mkdirSync(dirname(ownerFile), { recursive: true })
    const temporary = `${ownerFile}.tmp.${process.pid}.${randomBytes(4).toString('hex')}`
    writeFileSync(temporary, `${slate}\n`)
    try {
      linkSync(temporary, ownerFile)
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
    } finally {
      unlinkSync(temporary)
    }
  }
  assertRunOwner(root, slate, runId)
}

function normalizeScope({ milestone, issues }) {
  const set = [...new Set(issues ?? [])].sort((a, b) => a - b)
  return { milestone: milestone ?? null, issues: set }
}

function readLock(file) {
  const lock = readJson(file, 'slate lock')
  if (typeof lock.session !== 'string' || !Array.isArray(lock.issues)) {
    throw new Refusal(`slate lock is malformed: ${file}`)
  }
  return lock
}

// acquireSlateLock — the lock's issue set is the plan's whenever a plan
// exists, re-derived on every acquisition; --issues is accepted only before
// there is a plan, or when it equals the plan's set. The milestone is
// recorded from --milestone (the plan schema carries none) and never changes
// once recorded. Every acquisition that records a new or changed scope is
// checked against every other session's lock.
export function acquireSlateLock({ root, slate, session, milestone, issues }) {
  const { dir, file, registry } = lockPaths(root, slate)
  mkdirSync(dir, { recursive: true })
  const plan = currentPlan(root, slate)
  const planned = plan === null ? null : normalizeScope({ issues: plan.issues.map((issue) => issue.number) }).issues
  if (planned !== null && issues !== undefined && canonicalJson(normalizeScope({ issues }).issues) !== canonicalJson(planned)) {
    throw new Refusal(`--issues ${issues.join(',')} disagrees with slate ${slate}'s plan (${planned.join(',')}); the plan is the scope`)
  }
  return withMutex(registry, () => {
    const held = existsSync(file) ? readLock(file) : null
    if (held !== null && held.session !== session) {
      throw new Refusal(`slate ${slate} is locked by session ${held.session} (since ${held.acquired_at}); refusing`)
    }
    if (held !== null && milestone !== undefined && held.milestone !== null && held.milestone !== milestone) {
      throw new Refusal(`slate ${slate} is locked for milestone ${held.milestone}, not ${milestone}`)
    }
    const scope = normalizeScope({
      milestone: held?.milestone ?? milestone,
      issues: planned ?? (issues !== undefined ? issues : held?.issues),
    })
    if (scope.milestone === null && scope.issues.length === 0) {
      throw new Refusal(
        `slate ${slate} has no lock yet and no scope to record: pass --milestone and/or --issues, or write its plan.json first`,
      )
    }
    if (held !== null && canonicalJson(scope) === canonicalJson({ milestone: held.milestone ?? null, issues: held.issues })) {
      return held
    }
    for (const name of readdirSync(dir)) {
      if (!name.endsWith('.json') || name === `${slate}.json`) continue
      const other = readLock(join(dir, name))
      if (other.session === session) continue
      if (scope.milestone !== null && other.milestone === scope.milestone) {
        throw new Refusal(
          `milestone ${scope.milestone} is already locked by session ${other.session} under slate ${other.slate_id}; refusing`,
        )
      }
      const shared = scope.issues.filter((n) => other.issues.includes(n))
      if (shared.length > 0) {
        throw new Refusal(
          `issue(s) ${shared.join(', ')} are already locked by session ${other.session} under slate ${other.slate_id}; refusing`,
        )
      }
    }
    const lock = { schema: 1, slate_id: slate, session, ...scope, acquired_at: held?.acquired_at ?? resolveAt(undefined) }
    const temporary = `${file}.tmp.${process.pid}`
    writeFileSync(temporary, `${JSON.stringify(lock, null, 2)}\n`)
    renameSync(temporary, file)
    return lock
  })
}

export function releaseSlateLock({ root, slate, session, force, reason }) {
  const { dir, file, registry } = lockPaths(root, slate)
  if (!existsSync(dir)) return null
  return withMutex(registry, () => {
    if (!existsSync(file)) return null
    const held = readLock(file)
    if (held.session !== session && !force) {
      throw new Refusal(`slate ${slate} is locked by session ${held.session}; only that session may release it (or --force --reason)`)
    }
    if (force && (typeof reason !== 'string' || reason.trim() === '')) {
      throw new UsageError('--force requires --reason')
    }
    unlinkSync(file)
    return held
  })
}

// ---------------------------------------------------------------------------
// Run-record writes
// ---------------------------------------------------------------------------

const OUTCOME_FIELDS = ['outcome', 'at']
const PR_FIELDS = ['number', 'url', 'bound_at']

function appendChain(entries, fields, content) {
  const prev = entries.length === 0 ? 'genesis' : entries.at(-1).digest
  const picked = Object.fromEntries(fields.map((field) => [field, content[field]]))
  return [...entries, { seq: entries.length, ...picked, prev_digest: prev, digest: chainDigest(picked, prev) }]
}

function guardTimestamp(record, at) {
  if (typeof record.started_at === 'string' && isBefore(at, record.started_at)) {
    throw new Refusal(`${at} is before the run's started_at ${record.started_at}`)
  }
  const promotedAt = record.promotion?.promoted_at
  if (typeof promotedAt === 'string' && isBefore(promotedAt, at)) {
    throw new Refusal(`${at} is after promotion.promoted_at ${promotedAt}; nothing in the run is dated after its promotion`)
  }
}

function closeLastExit(record, exit, { required }) {
  const transitions = record.stage_transitions
  const last = transitions.at(-1)
  if (typeof last.exit === 'string' && last.exit.trim() !== '') {
    if (exit !== undefined && exit !== last.exit) {
      throw new Refusal(`stage ${last.stage} already recorded exit ${JSON.stringify(last.exit)}; an exit is never rewritten`)
    }
    return
  }
  if (exit === undefined || exit.trim() === '') {
    if (required) throw new Refusal(`--exit is required: stage ${last.stage} has no recorded exit yet`)
    return
  }
  last.exit = exit
}

function rulingSuffix(common, file) {
  let absolute
  try {
    absolute = realpathSync(resolve(file))
  } catch {
    throw new Refusal(`ruling file not found: ${file}`)
  }
  const rel = relative(common, absolute)
  const shown = rel !== '' && !rel.startsWith('..') && !rel.startsWith(sep) ? rel : absolute
  return ` [ruling ${shown} sha256=${sha256File(absolute)}]`
}

const MUTATORS = {
  transition(record, args) {
    if (record.outcome !== null) throw new Refusal(`run already ended with outcome ${record.outcome}`)
    const stage = args.stage
    if (typeof stage !== 'string' || stage === '') throw new UsageError('--stage is required')
    guardTimestamp(record, args.at)
    closeLastExit(record, args.exit, { required: true })
    record.stage_transitions.push({ stage, entered_at: args.at })
    // dev-flow-exit reads the active stage from the receipts sequence, so the
    // transition and its receipt land in the same candidate.
    record.receipts = [...(record.receipts ?? []), { kind: 'transition', stage, entered_at: args.at }]
    return `transition → ${stage}`
  },
  intervention(record, args, context) {
    if (args.kind !== 'asked' && args.kind !== 'other') throw new UsageError('--kind must be asked or other')
    if (typeof args.note !== 'string' || args.note.trim() === '') throw new UsageError('--note is required')
    guardTimestamp(record, args.at)
    const note = args.ruling === undefined ? args.note : `${args.note}${rulingSuffix(context.common, args.ruling)}`
    record.interventions.push({ kind: args.kind, at: args.at, note })
    return `intervention (${args.kind})`
  },
  'bind-pr'(record, args) {
    const number = Number(args.number)
    if (!Number.isInteger(number) || number < 1) throw new UsageError('--number must be a positive integer')
    if (typeof args.url !== 'string' || args.url === '') throw new UsageError('--url is required')
    if (record.pr && record.pr.number === number && record.pr.url === args.url) return null
    guardTimestamp(record, args.at)
    record.pr_bindings = appendChain(record.pr_bindings, PR_FIELDS, { number, url: args.url, bound_at: args.at })
    record.pr = { number, url: args.url }
    return `pr binding → #${number}`
  },
  promote(record, args) {
    if (record.outcome !== null) throw new Refusal(`run already ended with outcome ${record.outcome}`)
    if (typeof args.head !== 'string' || !/^[0-9a-f]{40}$/.test(args.head)) throw new UsageError('--head must be a 40-hex SHA')
    if (typeof args.fingerprint !== 'string' || args.fingerprint === '') throw new UsageError('--fingerprint is required')
    guardTimestamp(record, args.at)
    closeLastExit(record, args.exit ?? `ready-for-review: promoted at ${args.head}`, { required: true })
    record.outcome_transitions = appendChain(record.outcome_transitions, OUTCOME_FIELDS, {
      outcome: 'ready-for-review',
      at: args.at,
    })
    record.outcome = 'ready-for-review'
    record.promotion = { head: args.head, promoted_at: args.at, gate_fingerprint: args.fingerprint }
    return 'promotion'
  },
  close(record, args) {
    if (record.outcome !== null) {
      if (args.outcome !== undefined && args.outcome !== record.outcome) {
        throw new Refusal(`run already ended with outcome ${record.outcome}; refusing ${args.outcome}`)
      }
      return null
    }
    if (!['capped', 'escalated', 'abandoned'].includes(args.outcome)) {
      throw new UsageError('--outcome must be capped, escalated or abandoned for an open run (ready-for-review is `promote`)')
    }
    guardTimestamp(record, args.at)
    closeLastExit(record, args.exit, { required: true })
    record.outcome_transitions = appendChain(record.outcome_transitions, OUTCOME_FIELDS, { outcome: args.outcome, at: args.at })
    record.outcome = args.outcome
    return `outcome → ${args.outcome}`
  },
}

// archiveOrchestratorFiles — move `slates/<slate>/orchestrator/<run-id>/`
// into `runs/<run-id>/orchestrator/`, one attempt directory at a time, and
// refuse rather than overwrite an attempt already archived.
export function archiveOrchestratorFiles(root, slate, runId) {
  const source = join(root, 'slates', slate, 'orchestrator', runId)
  if (!existsSync(source)) return []
  const target = join(root, 'runs', runId, 'orchestrator')
  mkdirSync(target, { recursive: true })
  const entries = readdirSync(source)
  const clashes = entries.filter((name) => existsSync(join(target, name)))
  if (clashes.length > 0) {
    throw new Refusal(`archive target already holds ${clashes.map((name) => join(target, name)).join(', ')}; refusing to overwrite`)
  }
  for (const name of entries) renameSync(join(source, name), join(target, name))
  rmdirSync(source)
  return entries
}

function recordWrite(command, args) {
  const { common, root } = stateRoot()
  const slate = requireId('slate', args.slate)
  const session = requireId('session', args.session)
  const runId = requireId('run-id', args['run-id'])
  args.at = resolveAt(args.at)
  assertRunOwner(root, slate, runId)
  acquireSlateLock({ root, slate, session, milestone: args.milestone, issues: args.issues })
  bindRunToSlate(root, slate, runId)
  const canonical = join(root, 'runs', runId, 'run.json')
  const summary = withMutex(canonical, () => {
    const record = readJson(canonical, 'run record')
    if (record.run_id !== runId) throw new Refusal(`${canonical} records run_id ${JSON.stringify(record.run_id)}, not ${runId}`)
    if (!Array.isArray(record.stage_transitions) || record.stage_transitions.length === 0) {
      throw new Refusal(`${canonical} has no stage_transitions`)
    }
    validateFile('run', canonical, `existing ${canonical}`)
    const result = MUTATORS[command](record, args, { common })
    if (result === null) return null
    writeValidated('run', canonical, record)
    return result
  })
  if (command === 'close') {
    const moved = archiveOrchestratorFiles(root, slate, runId)
    const closed = summary === null ? 'run already closed' : `recorded ${summary}`
    return `${closed}; archived ${moved.length} orchestrator attempt(s) into runs/${runId}/orchestrator/`
  }
  return summary === null ? 'no change (already recorded)' : `recorded ${summary}`
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const VALUE_FLAGS = new Set([
  'slate', 'session', 'run-id', 'stage', 'exit', 'at', 'kind', 'note', 'ruling', 'number', 'url',
  'head', 'fingerprint', 'outcome', 'milestone', 'issues', 'reason',
])
const BOOLEAN_FLAGS = new Set(['force'])

export function parseFlags(argv, valueFlags = VALUE_FLAGS, booleanFlags = BOOLEAN_FLAGS, repeatable = new Set()) {
  const args = {}
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (!token.startsWith('--')) throw new UsageError(`unexpected argument ${JSON.stringify(token)}`)
    const name = token.slice(2)
    if (booleanFlags.has(name)) {
      args[name] = true
      continue
    }
    if (!valueFlags.has(name)) throw new UsageError(`unknown flag ${token}`)
    const value = argv[index + 1]
    if (value === undefined) throw new UsageError(`${token} needs a value`)
    index += 1
    if (repeatable.has(name)) {
      args[name] = [...(args[name] ?? []), value]
    } else {
      if (Object.hasOwn(args, name)) throw new UsageError(`${token} given twice`)
      args[name] = value
    }
  }
  return args
}

export function parseScopeFlags(args) {
  if (args.milestone !== undefined) {
    const milestone = Number(args.milestone)
    if (!Number.isInteger(milestone) || milestone < 1) throw new UsageError('--milestone must be a positive integer')
    args.milestone = milestone
  }
  if (args.issues !== undefined) {
    const issues = args.issues.split(',').map((value) => Number(value.trim()))
    if (issues.length === 0 || !issues.every((n) => Number.isInteger(n) && n >= 1)) {
      throw new UsageError('--issues must be a comma-separated list of issue numbers')
    }
    args.issues = issues
  }
  return args
}

function lockCommand(sub, args) {
  const { root } = stateRoot()
  const slate = requireId('slate', args.slate)
  if (sub === 'status') {
    const { file } = lockPaths(root, slate)
    return existsSync(file) ? JSON.stringify(readLock(file)) : `slate ${slate} is unlocked`
  }
  const session = requireId('session', args.session)
  if (sub === 'acquire') {
    const lock = acquireSlateLock({ root, slate, session, milestone: args.milestone, issues: args.issues })
    return `slate ${slate} locked by session ${lock.session}`
  }
  if (sub === 'release') {
    const held = releaseSlateLock({ root, slate, session, force: args.force === true, reason: args.reason })
    if (held === null) return `slate ${slate} was not locked`
    return args.force === true && held.session !== session
      ? `slate ${slate} lock held by session ${held.session} force-released: ${args.reason}`
      : `slate ${slate} released`
  }
  throw new UsageError(`unknown lock subcommand ${JSON.stringify(sub)}`)
}

export function runCli(main) {
  try {
    const message = main(process.argv.slice(2))
    if (message) console.log(message)
  } catch (error) {
    if (error instanceof UsageError) {
      console.error(`usage: ${error.message}`)
      process.exit(2)
    }
    if (error instanceof Refusal) {
      console.error(`refused: ${error.message}`)
      process.exit(1)
    }
    throw error
  }
}

function main(argv) {
  const [command, ...rest] = argv
  if (command === 'lock') {
    const [sub, ...flags] = rest
    return lockCommand(sub, parseScopeFlags(parseFlags(flags)))
  }
  if (!Object.hasOwn(MUTATORS, command ?? '')) {
    throw new UsageError('run-record.mjs transition|intervention|bind-pr|promote|close|lock … (see the header)')
  }
  return recordWrite(command, parseScopeFlags(parseFlags(rest)))
}

if (realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url))) runCli(main)
