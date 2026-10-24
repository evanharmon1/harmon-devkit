#!/usr/bin/env node
// run-record.mjs — the one writer for a dev-flow v2 run record
// (`<git-common-dir>/dev-flow-v2/runs/<run-id>/run.json`), plus the slate
// lock both durable-state writers take (harmon-devkit#1296).
//
// Usage:
//   run-record.mjs transition   --slate ID --session ID --run-id ID --stage STAGE [--exit TEXT] [--at TS]
//                               [--remediation-head SHA --remediation-findings ID,ID,...]
//   run-record.mjs authorize-cap --slate ID --session ID --run-id ID --stage challenge|review|integration --round N --actor ID --instruction TEXT [--at TS]
//   run-record.mjs intervention --slate ID --session ID --run-id ID --kind asked|other|prompt --note TEXT [--ruling FILE] [--at TS]
//                               [--decision approved|denied --command TEXT [--answered-by orchestrator|human]]
//   run-record.mjs bind-pr      --slate ID --session ID --run-id ID --number N --url URL [--at TS]
//   run-record.mjs promote [--check] --slate ID --session ID --run-id ID --head SHA --fingerprint TEXT [--exit TEXT] [--at TS]
//   run-record.mjs close        --slate ID --session ID --run-id ID [--outcome capped|escalated|abandoned --exit TEXT] [--at TS]
//   run-record.mjs prune        [--dry-run] [--repo-root DIR]
//   run-record.mjs solo-init    --session ID --run-id run-<issue>-<name> --issue N --title TEXT --url URL
//                               --branch NAME --base SHA --policy FILE --actor-id N --strategy-source TEXT
//                               [--operator-pin TEXT]... [--registry-revision SHA] [--at TS]
//   run-record.mjs lane-init    --slate ID --session ID --lane ID --policy FILE [--at TS]
//   run-record.mjs receipt      --slate ID --session ID --run-id ID --pass FILE
//   run-record.mjs adjudicate   --slate ID --session ID --run-id ID --file FILE
//   run-record.mjs ledger       --slate ID --session ID --run-id ID --stage challenge|review
//   run-record.mjs lock acquire --slate ID --session ID [--milestone N] [--issues N,N,...]
//   run-record.mjs lock release --slate ID --session ID [--force --reason TEXT]
//   run-record.mjs lock check   --slate ID --session ID --owner-token TOKEN
//                               Read-only: validates the existing lock owner without acquiring or changing it.
//   run-record.mjs lock status  --slate ID
//
// Writes accept --owner-token TOKEN. For acquisition, persistence and recovery,
// follow ../SKILL.md#owner-token-caller-contract.
//
// A run belongs to exactly one slate: its first helper write requires --run-id
// to be a lane in some revision of this slate's plan and records the slate in
// `runs/<run-id>/owner-slate`; every later write requires the same slate. Each
// write requires an explicitly acquired slate lock and its owner token
// (or the matching session for a legacy token-less lock). Under a per-file mutex,
// it builds the complete candidate beside run.json, validates it with
// `validate-result-schemas.mjs run --receipts <candidate>` plus every
// `adjudications/*.json` in the run directory (or `--no-adjudications` when
// there are none), renames it over run.json, and validates the canonical
// readback the same way. A refusal before the rename leaves run.json as it
// was; a readback failure after the rename leaves the new content in place
// and is reported as a blocker. The validator owns the
// lifecycle rules (allowed edges, chronology, chains, projections); this
// writer adds the one it cannot see: once the run has ended — promoted,
// capped, escalated or abandoned — every write but an archiving `close` is
// refused, so nothing is recorded after the run's terminal outcome (the
// validator does not bound `pr_bindings[].bound_at`).
//
// `--exit` records how the stage being left ended: `transition` requires it
// when that entry has no exit yet, and `promote` defaults it to
// `ready-for-review: promoted at <head>`. `close` records a
// non-promotion terminal outcome (if the run is still open) and then moves
// the run's orchestrator files from
// `slates/<slate>/orchestrator/<run-id>/` into `runs/<run-id>/orchestrator/`.
// After the validated terminal write and readback, `promote` and `close` ask
// dev-flow-monitor.sh to retire only this run's active pointer. A cleanup
// failure is reported without undoing or refusing the terminal outcome.
// `prune` is the recovery path for terminal pointers left behind by a failed
// retirement; it takes per-pointer monitor locks and can run as `--dry-run`.
//
// `--remediation-head`/`--remediation-findings` record an integration
// remediation push on the transition that re-enters integration after it
// (harmon-devkit#1386): the head the push put on the branch and the
// finding ids it answers (integration findings, or challenge/review findings
// deferred to integration). dev-flow-exit.mjs --stage integration
// classifies head moves from that record only.
//
// `--ruling FILE` appends ` [ruling <path> sha256=<hex>]` to the intervention
// note, referencing a no-clobber snapshot in `runs/<run-id>/rulings/<hex>`.
// The snapshot survives close's archive and later edits to the source file.
// run.schema.json closes intervention items, so the digest travels in the note.
//
// Exit codes: 0 written (or an idempotent no-op), 1 refused, 2 usage.
// The state root is resolved from the current directory's
// `git rev-parse --git-common-dir`, except `prune --repo-root DIR` uses DIR's
// common directory.

import { createHash, randomBytes } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { validateCapAuthorizations } from './lib/cap-authorizations.mjs'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmdirSync,
  rmSync,
  unlinkSync,
  writeFileSync,
  linkSync,
} from 'node:fs'
import { hostname, tmpdir } from 'node:os'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { validateResolvedPolicy } from './devflow-policy.mjs'

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
    // The stamp is written whole and linked into place, so the mutex is either
    // absent or carries a complete, attributable owner.
    const temporary = `${lock}.tmp.${process.pid}.${randomBytes(4).toString('hex')}`
    writeFileSync(temporary, stamp)
    let acquired = false
    try {
      linkSync(temporary, lock)
      acquired = true
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
    } finally {
      unlinkSync(temporary)
    }
    if (acquired) break
    // An unreadable stamp (vanished, or not a readable file) falls through to
    // the same deadline and back-off as a live owner, never a hot retry loop.
    let observed = null
    try {
      observed = readFileSync(lock, 'utf8')
    } catch {
      observed = null
    }
    let owner = null
    if (observed !== null) {
      try {
        owner = JSON.parse(observed)
      } catch {
        owner = null
      }
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

// validatedCandidate writes a candidate beside its canonical record and proves
// it through the same strict validator used by every replacement. Its caller
// either renames it (a writer) or removes it (a read-only precheck).
function validatedCandidate(kind, canonical, document) {
  const candidate = `${canonical}.candidate.${process.pid}.${randomBytes(4).toString('hex')}`
  writeFileSync(candidate, `${JSON.stringify(document, null, 2)}\n`)
  const failure = runValidator(kind, candidate)
  if (failure !== null) {
    unlinkSync(candidate)
    throw new Refusal(`candidate refused by \`${kind}\` validation; ${canonical} is unchanged:\n${failure}`)
  }
  return candidate
}

// writeValidated — the candidate, validate, rename, readback sequence.
export function writeValidated(kind, canonical, document) {
  const candidate = validatedCandidate(kind, canonical, document)
  renameSync(candidate, canonical)
  const readback = runValidator(kind, canonical)
  if (readback !== null) {
    throw new Refusal(`BLOCKER: ${canonical} failed readback validation after rename:\n${readback}`)
  }
}

function validateCandidate(kind, canonical, document) {
  const candidate = validatedCandidate(kind, canonical, document)
  try {
    return null
  } finally {
    try {
      unlinkSync(candidate)
    } catch (error) {
      // Another validator may have removed a candidate concurrently. Every
      // other cleanup failure means the read-only precheck did not complete.
      if (error?.code !== 'ENOENT') throw error
    }
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

// readValidatedPlan — the slate's plan document after `validate-result-schemas.mjs
// plan` accepts it, or null when no plan exists. Nothing reads a plan for the
// lock scope or a run's ownership before it has validated.
function readValidatedPlan(root, slate) {
  const file = join(root, 'slates', slate, 'plan.json')
  if (!existsSync(file)) return null
  validateFile('plan', file, `slate ${slate}'s ${file}`)
  const document = readJson(file, 'plan')
  if (document.slate_id !== slate) {
    throw new Refusal(`${file} records slate_id ${JSON.stringify(document.slate_id)}, not ${slate}; a plan is bound to its slate directory`)
  }
  return document
}

// currentPlan — the slate's latest plan revision, or null when no plan exists.
export function currentPlan(root, slate) {
  const document = readValidatedPlan(root, slate)
  if (document === null) return null
  const file = join(root, 'slates', slate, 'plan.json')
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
  assertRunCanBindToSlate(root, slate, runId)
  if (readRunOwner(root, runId) === null) {
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

// assertRunCanBindToSlate is bindRunToSlate without its one durable write.
// Promotion's --check mode uses it after lock ownership has been proven: a
// prospective first binding must be in a validated plan, but checking it must
// never create owner-slate. The writer still calls bindRunToSlate before its
// real mutation, so a successful check cannot authorize a later write.
function assertRunCanBindToSlate(root, slate, runId) {
  if (readRunOwner(root, runId) !== null) {
    assertRunOwner(root, slate, runId)
    return
  }
  const revisions = readValidatedPlan(root, slate)?.revisions ?? []
  if (!Array.isArray(revisions) || !revisions.some((revision) => (revision?.plan?.lanes ?? []).some((lane) => lane?.run_id === runId))) {
    throw new Refusal(`run ${runId} is not a lane in any revision of slate ${slate}'s plan; refusing to write it under this slate`)
  }
}

function normalizeScope({ milestone, issues }) {
  const set = [...new Set(issues ?? [])].sort((a, b) => a - b)
  return { milestone: milestone ?? null, issues: set }
}

function readLock(file) {
  const lock = readJson(file, 'slate lock')
  if (typeof lock.session !== 'string' || !Array.isArray(lock.issues) ||
      (Object.hasOwn(lock, 'owner_token_digest') && !/^[0-9a-f]{64}$/.test(lock.owner_token_digest ?? ''))) {
    throw new Refusal(`slate lock is malformed: ${file}`)
  }
  return lock
}

// A session is a display name; only the token proves ownership of a new lock.
// Token-less locks predate this contract and remain usable until released.
function assertLockOwner(held, session, ownerToken) {
  if (held.session !== session) {
    throw new Refusal(`slate ${held.slate_id} is locked by session ${held.session}; refusing`)
  }
  if (!Object.hasOwn(held, 'owner_token_digest')) {
    console.error('warning: legacy slate lock authorizes by session; use lock release then lock acquire to upgrade')
    return
  }
  if (typeof ownerToken !== 'string' || createHash('sha256').update(ownerToken).digest('hex') !== held.owner_token_digest) {
    throw new Refusal('slate lock owner token does not match; pass the token from the original lock acquire output with --owner-token; only if the token is truly lost, recover with operator-confirmed lock release --force --reason, then lock acquire')
  }
}

// acquireSlateLock — the lock's issue set is the plan's whenever a plan
// exists, re-derived on every acquisition; --issues is accepted only before
// there is a plan, or when it equals the plan's set. The milestone is
// recorded from --milestone (the plan schema carries none) and never changes
// once recorded. Every acquisition that records a new or changed scope is
// checked against every other session's lock.
function validateSlateLock({ root, slate, session, ownerToken = process.env.RUN_RECORD_OWNER_TOKEN, milestone, issues, create = false }) {
  const { dir, file, registry } = lockPaths(root, slate)
  const plan = currentPlan(root, slate)
  const planned = plan === null ? null : normalizeScope({ issues: plan.issues.map((issue) => issue.number) }).issues
  const outside = (reserved) => (planned ?? []).filter((n) => !reserved.includes(n))
  const held = existsSync(file) ? readLock(file) : null
  if (held === null && !create) {
    throw new Refusal(`slate ${slate} is unlocked; run lock acquire with --slate, --session and --issues first`)
  }
  if (held !== null) assertLockOwner(held, session, ownerToken)
  if (held !== null && milestone !== undefined && held.milestone !== null && held.milestone !== milestone) {
    throw new Refusal(`slate ${slate} is locked for milestone ${held.milestone}, not ${milestone}`)
  }
  // The reservation is taken before the plan is published (--issues), and
  // the canonical plan must stay inside it; a slate with no lock yet falls
  // back to the plan's own issue set.
  const scope = normalizeScope({
    milestone: held?.milestone ?? milestone,
    issues: issues !== undefined ? issues : (held?.issues ?? planned),
  })
  const unreserved = outside(scope.issues)
  if (unreserved.length > 0) {
    throw new Refusal(
      `slate ${slate}'s plan names issue(s) ${unreserved.join(', ')} outside the reserved scope (${scope.issues.join(',')}); reserve them with \`lock acquire --issues\` before publishing the plan`,
    )
  }
  if (scope.milestone === null && scope.issues.length === 0) {
    throw new Refusal(
      `slate ${slate} has no lock yet and no scope to record: pass --milestone and/or --issues, or write its plan.json first`,
    )
  }
  if (held !== null && canonicalJson(scope) === canonicalJson({ milestone: held.milestone ?? null, issues: held.issues })) {
    return { dir, file, registry, held, scope, changed: false }
  }
  for (const name of readdirSync(dir)) {
    if (!name.endsWith('.json') || name === `${slate}.json`) continue
    const other = readLock(join(dir, name))
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
  return { dir, file, registry, held, scope, changed: true }
}

function checkSlateLock(args) {
  const { dir, registry } = lockPaths(args.root, args.slate)
  if (!existsSync(dir)) return validateSlateLock(args)
  return withMutex(registry, () => validateSlateLock(args))
}

export function acquireSlateLock({ root, slate, session, ownerToken = process.env.RUN_RECORD_OWNER_TOKEN, milestone, issues, create = false }) {
  const { dir, file, registry } = lockPaths(root, slate)
  mkdirSync(dir, { recursive: true })
  return withMutex(registry, () => {
    const { held, scope, changed } = validateSlateLock({ root, slate, session, ownerToken, milestone, issues, create })
    if (!changed) return held
    const mintedToken = held === null ? randomBytes(32).toString('hex') : null
    const lock = { schema: 1, slate_id: slate, session, ...scope, acquired_at: held?.acquired_at ?? resolveAt(undefined),
      ...(held === null ? { owner_token_digest: createHash('sha256').update(mintedToken).digest('hex') }
        : Object.hasOwn(held, 'owner_token_digest') ? { owner_token_digest: held.owner_token_digest } : {}),
    }
    const temporary = `${file}.tmp.${process.pid}`
    writeFileSync(temporary, `${JSON.stringify(lock, null, 2)}\n`)
    renameSync(temporary, file)
    // Only a fresh explicit acquisition may print the token. The transient
    // `created` flag never reaches the lock file or status output.
    return held === null ? { ...lock, created: true, mintedToken } : lock
  })
}

export function releaseSlateLock({ root, slate, session, ownerToken = process.env.RUN_RECORD_OWNER_TOKEN, force, reason }) {
  if (force && (typeof reason !== 'string' || reason.trim() === '')) {
    throw new UsageError('--force requires --reason')
  }
  const { dir, file, registry } = lockPaths(root, slate)
  if (!existsSync(dir)) return null
  return withMutex(registry, () => {
    if (!existsSync(file)) return null
    const held = readLock(file)
    if (!force) assertLockOwner(held, session, ownerToken)
    if (force) {
      // Retain the observed owner and the operator's attribution BEFORE
      // removing the reservation. If audit publication fails, keep the lock.
      // This records intent: a crash before unlink may leave the lock held.
      const audit = { action: 'force-release', at: resolveAt(undefined), session, reason, lock: held }
      const auditPath = join(dir, 'recoveries', slate, `${randomBytes(16).toString('hex')}.json`)
      publishExclusive(auditPath, `${JSON.stringify(audit, null, 2)}\n`, 'lock recovery')
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

// guardTimestamp — every new entry: the run must still be open (any terminal
// outcome, promotion included, ends it) and the entry no earlier than
// started_at.
function guardTimestamp(record, at) {
  if (record.outcome !== null) {
    throw new Refusal(`run already ended with outcome ${record.outcome}; no entry is written after a run ends`)
  }
  if (typeof record.started_at === 'string' && isBefore(at, record.started_at)) {
    throw new Refusal(`${at} is before the run's started_at ${record.started_at}`)
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

function rulingSuffix(common, runId, file) {
  let absolute
  try {
    absolute = realpathSync(resolve(file))
  } catch {
    throw new Refusal(`ruling file not found: ${file}`)
  }
  // Hash and publish the same read, not two reads of a mutable source.
  const content = readFileSync(absolute)
  const digest = createHash('sha256').update(content).digest('hex')
  const snapshot = join(common, 'dev-flow-v2', 'runs', runId, 'rulings', digest)
  publishExclusive(snapshot, content, 'ruling')
  return ` [ruling ${relative(common, snapshot)} sha256=${digest}]`
}

// remediationRecord — the explicit remediation-push record (harmon-devkit#1386),
// written on the transition that re-enters integration after the push: the
// pushed head and the integration finding ids it answers (an empty list only
// for the local-merge fallback reconciliation). A server-side catch-up or a
// carry is not a push and records nothing. Both flags or neither.
function remediationRecord(record, stage, args) {
  const head = args['remediation-head']
  const findings = args['remediation-findings']
  if (head === undefined && findings === undefined) return null
  if (head === undefined || findings === undefined) {
    throw new UsageError('--remediation-head and --remediation-findings are given together')
  }
  if (stage !== 'integration' || !record.stage_transitions.some((t) => t.stage === 'integration')) {
    throw new Refusal('a remediation push is recorded only on a transition that re-enters integration')
  }
  if (!/^[0-9a-f]{40}$/.test(head)) throw new UsageError('--remediation-head must be a 40-hex SHA')
  const ids = findings.trim() === '' ? [] : findings.split(',').map((id) => id.trim())
  // Integration findings, or challenge/review findings deferred to integration.
  const bad = ids.find((id) => !/^(challenge|review|integration)-r[1-9][0-9]*-[a-z0-9-]+-[1-9][0-9]*$/.test(id))
  if (bad !== undefined) throw new UsageError(`--remediation-findings: ${JSON.stringify(bad)} is not a challenge, review or integration finding id`)
  return { head, findings: ids }
}

const MUTATORS = {
  transition(record, args) {
    if (record.outcome !== null) throw new Refusal(`run already ended with outcome ${record.outcome}`)
    const stage = args.stage
    if (typeof stage !== 'string' || stage === '') throw new UsageError('--stage is required')
    guardTimestamp(record, args.at)
    const remediation = remediationRecord(record, stage, args)
    closeLastExit(record, args.exit, { required: true })
    record.stage_transitions.push(remediation ? { stage, entered_at: args.at, remediation } : { stage, entered_at: args.at })
    // dev-flow-exit reads the active stage from the receipts sequence, so the
    // transition and its receipt land in the same candidate.
    record.receipts = [...(record.receipts ?? []), { kind: 'transition', stage, entered_at: args.at }]
    return `transition → ${stage}`
  },
  'authorize-cap'(record, args) {
    guardTimestamp(record, args.at)
    const entry = { stage: args.stage, round: Number(args.round), actor: args.actor, instruction: args.instruction, at: args.at }
    record.cap_authorizations = [...(record.cap_authorizations ?? []), entry]
    try {
      validateCapAuthorizations(record)
    } catch (error) {
      throw new Refusal(error.message)
    }
    return `cap authorization (${entry.stage} round ${entry.round})`
  },
  intervention(record, args, context) {
    if (!['asked', 'other', 'prompt'].includes(args.kind)) throw new UsageError('--kind must be asked, other or prompt')
    const prompt = {}
    if (args.kind === 'prompt') {
      if (!['approved', 'denied'].includes(args.decision)) throw new UsageError('--decision must be approved or denied')
      if (typeof args.command !== 'string' || args.command.trim() === '') throw new UsageError('--command is required')
      if (args['answered-by'] !== undefined && !['orchestrator', 'human'].includes(args['answered-by'])) throw new UsageError('--answered-by must be orchestrator or human')
      prompt.decision = args.decision
      prompt.command = args.command
      if (args['answered-by'] !== undefined) prompt.answered_by = args['answered-by']
    } else if (['decision', 'command', 'answered-by'].some((key) => args[key] !== undefined)) {
      throw new UsageError('prompt fields require --kind prompt')
    }
    if (typeof args.note !== 'string' || args.note.trim() === '') throw new UsageError('--note is required')
    guardTimestamp(record, args.at)
    const note = args.ruling === undefined ? args.note : `${args.note}${rulingSuffix(context.common, record.run_id, args.ruling)}`
    record.interventions.push({ kind: args.kind, at: args.at, note, ...prompt })
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
    for (const binding of record.pr_bindings) {
      if (isBefore(args.at, binding.bound_at)) {
        throw new Refusal(`${args.at} is before PR binding #${binding.number} at ${binding.bound_at}; promotion cannot predate a recorded PR binding`)
      }
    }
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
    const enteredAt = record.stage_transitions.at(-1).entered_at
    if (isBefore(args.at, enteredAt)) {
      throw new Refusal(`${args.at} is before the active stage ${record.stage_transitions.at(-1).stage} began (${enteredAt}); a run cannot end before its last stage started`)
    }
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

function recordMutation(command, args, { check = false } = {}) {
  const { common, root } = stateRoot()
  const slate = requireId('slate', args.slate)
  const session = requireId('session', args.session)
  const runId = requireId('run-id', args['run-id'])
  args.at = resolveAt(args.at)
  assertRunOwner(root, slate, runId)
  if (check) {
    checkSlateLock({ root, slate, session, ownerToken: args['owner-token'], milestone: args.milestone, issues: args.issues })
    assertRunCanBindToSlate(root, slate, runId)
  } else {
    acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'], milestone: args.milestone, issues: args.issues })
    bindRunToSlate(root, slate, runId)
  }
  const canonical = join(root, 'runs', runId, 'run.json')
  const summary = withMutex(canonical, () => {
    const record = readJson(canonical, 'run record')
    if (record.run_id !== runId) throw new Refusal(`${canonical} records run_id ${JSON.stringify(record.run_id)}, not ${runId}`)
    if (!Array.isArray(record.stage_transitions) || record.stage_transitions.length === 0) {
      throw new Refusal(`${canonical} has no stage_transitions`)
    }
    validateFile('run', canonical, `existing ${canonical}`)
    const candidate = check ? structuredClone(record) : record
    const result = MUTATORS[command](candidate, args, { common })
    if (result === null) return null
    if (check) validateCandidate('run', canonical, candidate)
    else writeValidated('run', canonical, candidate)
    return result
  })
  if (check) return `checked ${summary === null ? 'no change (already recorded)' : summary} (read-only)`
  const retirement = command === 'promote' || command === 'close' ? retireActivePointer(runId) : null
  if (command === 'close') {
    const moved = archiveOrchestratorFiles(root, slate, runId)
    const closed = summary === null ? 'run already closed' : `recorded ${summary}`
    return `${closed}; ${retirement}; archived ${moved.length} orchestrator attempt(s) into runs/${runId}/orchestrator/`
  }
  if (command === 'promote') return `recorded ${summary}; ${retirement}`
  return summary === null ? 'no change (already recorded)' : `recorded ${summary}`
}

// Initialize a planned lane without inventing a slate or changing its scope.
// The provisioning composer validates its other inputs before calling this
// writer; direct callers receive the same run/ownership/lock protections.
export function laneInit(args) {
  const { root } = stateRoot()
  const slate = requireId('slate', args.slate)
  const session = requireId('session', args.session)
  const laneName = requireId('lane', args.lane)
  const at = resolveAt(args.at)
  const plan = currentPlan(root, slate)
  const lane = plan?.lanes.find((entry) => entry.lane === laneName)
  if (!lane) throw new Refusal(`unknown lane ${laneName} in the last validated plan revision`)
  const runId = requireId('run-id', lane.run_id)
  const repoRoot = git(['rev-parse', '--show-toplevel'])
  checkActivationAllowed(repoRoot, lane.branch, runId)
  const runDir = join(root, 'runs', runId)
  const canonical = join(runDir, 'run.json')
  if (existsSync(canonical)) throw new Refusal(`${canonical} already exists`)
  if (existsSync(runDir) && readdirSync(runDir).length > 0) {
    throw new Refusal(`${runDir} already contains state; inspect before initializing`)
  }
  assertRunOwner(root, slate, runId)
  acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'] })
  const profile = plan.lane_profiles?.find((entry) => entry.lane === laneName)?.policy ?? plan.policy
  const record = kickoffRecord(runId, at,
    `resolved: rigor ${profile.rigor} (${profile.rigor_source}), strategy ${profile.strategy} (${profile.strategy_source}); lane ${laneName} of slate ${slate}, session ${session}`)
  const projection = lanePolicyProjection(plan, lane, args.policy)
  const selection = finderSelection(projection)
  if (selection.length > 0) record.finder_selection = selection
  // Validate the complete kickoff record before creating its durable directory.
  // This also rejects calendar-invalid timestamps resolveAt cannot detect.
  const temporary = mkdtempSync(join(tmpdir(), 'lane-init-'))
  try {
    writeValidated('run', join(temporary, 'run.json'), record)
  } finally {
    rmSync(temporary, { recursive: true, force: true })
  }
  mkdirSync(runDir, { recursive: true })
  return withMutex(canonical, () => {
    if (existsSync(canonical)) throw new Refusal(`${canonical} already exists`)
    writeValidated('run', canonical, record)
    bindRunToSlate(root, slate, runId)
    publishExclusive(join(runDir, 'policy.json'), `${JSON.stringify(projection, null, 2)}\n`, 'policy projection')
    return JSON.stringify({ run_id: runId, record_directory: runDir })
  })
}

function kickoffRecord(runId, at, exit) {
  return {
    schema: 2, run_id: runId, initiated_by: 'human', started_at: at,
    stage_transitions: [{ stage: 'kickoff', entered_at: at, exit }],
    receipts: [], interventions: [], outcome: null, pr: null,
    evidence_comments: [], evidence_registrations: [], pr_bindings: [],
    outcome_transitions: [], settlements: [], promotion: null,
  }
}

// Preserve the resolver's complete projection for both kickoff writers. Fields
// such as stages, tier_order and gates govern later receipts and pushes.
function kickoffPolicyProjection(policy, plannedPolicy) {
  return { ...policy, rigor: { ...policy.rigor, source: policy.rigor.source ?? plannedPolicy.rigor_source } }
}

function finderSelection(policy) {
  return (Array.isArray(policy.finder_selection) ? policy.finder_selection : [])
    .map(({ stage, configured, requested, effective }) => ({ stage, configured, requested, effective }))
}

export function lanePolicyProjection(plan, lane, policyFile) {
  if (typeof policyFile !== 'string' || !policyFile) throw new UsageError('--policy is required (resolved-policy JSON)')
  const policy = readJson(policyFile, '--policy')
  try {
    validateResolvedPolicy(policy)
  } catch (error) {
    throw new Refusal(`--policy is not a complete resolved policy projection: ${error.message}`)
  }
  const profile = plan.lane_profiles?.find((entry) => entry.lane === lane.lane)?.policy ?? plan.policy
  const projected = planPolicy(policy, { strategySource: profile.strategy_source, operatorPins: profile.operator_pins })
  // The plan may carry attributed prose ("explicit operator input ...") where
  // the resolver records "operator". Compare execution values, not that prose.
  projected.rigor_source = profile.rigor_source
  if (canonicalJson(projected) !== canonicalJson(profile)) {
    throw new Refusal('--policy does not match the lane profile in the last validated plan revision')
  }
  return kickoffPolicyProjection(policy, profile)
}

// ---------------------------------------------------------------------------
// Solo runs: the inline confidence-stage path (harmon-devkit#1183, #973)
// ---------------------------------------------------------------------------
//
// An interactive session with no orchestrator still runs its confidence
// stages, and the #973 decision is that it records them in a REAL run, the
// same files the orchestrated path writes, never a second format. These four
// commands are the only writers that path needs beyond `transition`,
// `bind-pr`, `promote` and `close` above; each validates with the same
// validator and publishes through the same no-clobber or
// candidate/rename/readback steps.
//
//   solo-init  reserves a minimal single-lane run: a one-lane slate
//              `solo-<run-id>` (its own plan, lock and owner binding, so every
//              existing writer accepts the run unchanged), the resolved policy
//              projection as policy.json, a kickoff run.json, and the branch's
//              active pointer through orchestrate's dev-flow-monitor.sh.
//              Invariant: every refusable precondition (the registry revision,
//              the session's actor in its trusted set, the branch's pointer
//              naming no live run) is resolved before the first write, and a
//              step that still fails afterwards undoes everything this call
//              created. It supersedes only a pointer whose run has ended. A
//              terminal run's pointer is retired; a new run on the same branch
//              therefore starts at generation 1 again.
//   receipt    admits one challenger/reviewer pass (see admitPass), puts it at
//              passes/<stage>-r<round>-<slot>.json (no-clobber), and appends
//              its {kind:"pass"} receipt.
//   adjudicate validates one round's adjudication document against that
//              round's receipted passes, publishes it (no-clobber) under
//              adjudications/, and re-validates run.json with it, removing it
//              again if the record no longer validates.
//   ledger     materializes the exit engine's evidence inputs for one stage
//              from the branch's own commits: history.<stage>.json (the change ledger,
//              one entry per file the fix between consecutive reviewed heads
//              touched) and heads.json (the branch's first-parent head map).

const SOLO_ROLES = ['orchestrator', 'implementer', 'challenger', 'reviewer', 'integrator']
const CONFIDENCE_STAGES = new Set(['challenge', 'review'])

export function soloSlate(runId) {
  return `solo-${runId}`
}

function git(args, cwd = process.cwd()) {
  return execFileSync('git', ['--no-replace-objects', ...args], {
    cwd,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' },
  }).replace(/\n$/, '')
}

function monitorPath() {
  const monitor = resolve(ASSET_DIR, '..', '..', 'orchestrate', 'assets', 'dev-flow-monitor.sh')
  if (!existsSync(monitor)) {
    throw new Refusal(`${monitor} is missing; vendor the universal skill category as a unit`)
  }
  return monitor
}

function checkActivationAllowed(repoRoot, branch, runId) {
  const monitor = monitorPath()
  try {
    const snapshot = JSON.parse(execFileSync('bash', [monitor, 'check-activation', '--branch', branch, '--run-id', runId,
      '--repo-root', repoRoot], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim())
    if (!snapshot || !Number.isSafeInteger(snapshot.generation) || snapshot.generation < 0 ||
        (snapshot.run_id !== null && !/^[A-Za-z0-9._-]+$/.test(snapshot.run_id)) ||
        (snapshot.run_id === null && snapshot.generation !== 0) ||
        (snapshot.run_id !== null && snapshot.generation < 1)) {
      throw new Refusal('activation preflight returned an invalid predecessor snapshot')
    }
    return snapshot
  } catch (error) {
    if (error instanceof Refusal) throw error
    const details = [error.stderr, error.stdout]
      .map((value) => (Buffer.isBuffer(value) ? value.toString('utf8') : `${value ?? ''}`))
      .filter(Boolean)
      .join('\n')
      .trim()
    throw new Refusal(`activation refused: ${details || `exit ${error.status ?? 'unknown'}`}`)
  }
}

function activePointerPath(root, branch) {
  return join(root, 'active', `${createHash('sha256').update(branch, 'utf8').digest('hex')}.json`)
}

function retireActivePointer(runId) {
  try {
    const repoRoot = git(['rev-parse', '--show-toplevel'])
    return execFileSync('bash', [monitorPath(), 'retire', '--run-id', runId, '--repo-root', repoRoot], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim()
  } catch (error) {
    const details = [error.stderr, error.stdout]
      .map((value) => (Buffer.isBuffer(value) ? value.toString('utf8') : `${value ?? ''}`))
      .filter(Boolean)
      .join('\n')
      .trim()
    console.error(`warning: active pointer retirement for ${runId} did not complete${details ? `:\n${details}` : ` (exit ${error.status ?? 'unknown'})`}`)
    return 'active pointer retirement reported incomplete'
  }
}

function pruneActivePointers(args) {
  try {
    const repoRoot = resolve(args['repo-root'] ?? git(['rev-parse', '--show-toplevel']))
    const command = [monitorPath(), 'prune']
    if (args['dry-run'] === true) command.push('--dry-run')
    command.push('--repo-root', repoRoot)
    return execFileSync('bash', command, {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim()
  } catch (error) {
    const details = [error.stderr, error.stdout]
      .map((value) => (Buffer.isBuffer(value) ? value.toString('utf8') : `${value ?? ''}`))
      .filter(Boolean)
      .join('\n')
      .trim()
    throw new Refusal(`active pointer prune failed${details ? `:\n${details}` : ` (exit ${error.status ?? 'unknown'})`}`)
  }
}

// publishExclusive — write `content` to `target` only if it does not exist,
// through a dot-file beside it and link(2); an existing target is adopted
// when it holds exactly these bytes and refused otherwise. Returns whether
// this call created it.
function publishExclusive(target, content, label) {
  mkdirSync(dirname(target), { recursive: true })
  if (existsSync(target)) {
    if (!readFileSync(target).equals(Buffer.from(content))) {
      throw new Refusal(`${target} already exists with different content; a published ${label} is never overwritten`)
    }
    return false
  }
  const temporary = join(dirname(target), `.${label.replace(/[^a-z]/g, '')}.${process.pid}.${randomBytes(4).toString('hex')}`)
  writeFileSync(temporary, content)
  try {
    linkSync(temporary, target)
  } catch (error) {
    if (error.code !== 'EEXIST') throw error
    if (!readFileSync(target).equals(Buffer.from(content))) {
      throw new Refusal(`${target} was published concurrently with different content; refusing`)
    }
    return false
  } finally {
    unlinkSync(temporary)
  }
  return true
}

function planPolicy(policy, { strategySource, operatorPins }) {
  const fail = (what) => {
    throw new Refusal(`--policy is not a resolved policy projection (devflow-policy.mjs resolve): ${what}`)
  }
  const rounds = policy?.rounds
  const breadth = policy?.breadth
  if (typeof policy?.rigor?.level !== 'string') fail('no rigor.level')
  if (!rounds || !breadth) fail('no rounds or breadth')
  if (typeof policy?.strategy?.name !== 'string') fail('no strategy.name')
  const role_tiers = {}
  for (const role of SOLO_ROLES) {
    const tier = policy?.roles?.[role]?.tier
    if (typeof tier !== 'string') fail(`no roles.${role}.tier`)
    role_tiers[role] = tier
  }
  return {
    rigor: policy.rigor.level,
    // The projection names its own source for an operator or label choice;
    // `chosen_by: null` is the reader's statement that the default applied.
    rigor_source: policy.rigor.source ?? policy.rigor.chosen_by ?? 'default_rigor',
    caps: Object.fromEntries(['challenge', 'review', 'integration', 'remediation', 'min_rounds', 'wall_clock_min'].map((k) => [k, rounds[k]])),
    breadth: { max_agent_runs: breadth.max_agent_runs, max_parallel_agents: breadth.max_parallel_agents },
    strategy: policy.strategy.name,
    strategy_source: strategySource,
    role_tiers,
    operator_pins: operatorPins,
  }
}

// governingRegistryRevision — the agent-registry.json revision the merge base
// carries: --base must BE the merge base of the default branch and the
// branch's head, so a branch that edits the registry never governs its own
// trust set (AGENTS.md's merge-base rule).
function governingRegistryRevision(repoRoot, base, branch) {
  let ref
  try {
    ref = git(['symbolic-ref', 'refs/remotes/origin/HEAD'], repoRoot)
  } catch {
    throw new Refusal('could not resolve the default branch (refs/remotes/origin/HEAD is unset)')
  }
  let tip
  try {
    tip = git(['rev-parse', '--verify', '--quiet', `refs/heads/${branch}^{commit}`], repoRoot)
  } catch {
    throw new Refusal(`--branch ${branch} names no local branch (refs/heads/${branch}); a solo run is reserved for an existing branch`)
  }
  const mergeBase = git(['merge-base', ref, tip], repoRoot)
  if (mergeBase !== base) throw new Refusal(`--base ${base} is not the merge base ${mergeBase} of ${ref} and ${branch}`)
  const revision = git(['log', '-1', '--format=%H', base, '--', 'agent-registry.json'], repoRoot)
  if (!/^[0-9a-f]{40}$/.test(revision)) throw new Refusal(`the merge base ${base} carries no agent-registry.json revision`)
  return revision
}

// refuseGrafts — every proof here (merge bases, ancestry, diffs) reads the
// commit graph; replace refs are disabled per call, but no flag disables an
// info/grafts file, so its presence is a refusal before any of them runs.
function refuseGrafts(repoRoot = process.cwd()) {
  const grafts = git(['rev-parse', '--path-format=absolute', '--git-path', 'info/grafts'], repoRoot)
  if (existsSync(grafts)) throw new Refusal(`${grafts} exists; a grafted history cannot prove a reviewed head or a fix, refusing`)
}

// trustedAt — the actor ids agent-registry.json trusts at `revision`.
function trustedAt(repoRoot, revision) {
  let registry
  try {
    registry = JSON.parse(git(['show', `${revision}:agent-registry.json`], repoRoot))
  } catch {
    throw new Refusal(`could not read agent-registry.json at registry revision ${revision}`)
  }
  const ids = registry?.trusted_orchestrator_actor_ids
  if (!Array.isArray(ids)) throw new Refusal(`agent-registry.json at ${revision} declares no trusted_orchestrator_actor_ids`)
  return ids
}

function soloInit(args) {
  const { common, root } = stateRoot()
  const session = requireId('session', args.session)
  const runId = requireId('run-id', args['run-id'])
  const issue = Number(args.issue)
  if (!Number.isSafeInteger(issue) || issue < 1) throw new UsageError('--issue must be a positive integer')
  if (!new RegExp(`^run-${issue}-[A-Za-z0-9._-]+$`).test(runId)) {
    throw new UsageError(`--run-id must be the canonical run-${issue}-<name> identity for issue ${issue}`)
  }
  for (const flag of ['title', 'url', 'branch', 'policy', 'strategy-source']) {
    if (typeof args[flag] !== 'string' || args[flag].trim() === '') throw new UsageError(`--${flag} is required`)
  }
  const actor = Number(args['actor-id'])
  if (!/^[1-9][0-9]*$/.test(args['actor-id'] ?? '') || !Number.isSafeInteger(actor)) {
    throw new UsageError('--actor-id must be the posting GitHub account id (gh api user --jq .id)')
  }
  const branch = args.branch
  if (!/^[0-9a-f]{40}$/.test(args.base ?? '')) throw new UsageError('--base must be a 40-hex SHA')
  if (args['registry-revision'] !== undefined && !/^[0-9a-f]{40}$/.test(args['registry-revision'])) {
    throw new UsageError('--registry-revision must be a 40-hex SHA')
  }
  const at = resolveAt(args.at)
  const repoRoot = git(['rev-parse', '--show-toplevel'])
  refuseGrafts(repoRoot)
  const policy = readJson(args.policy, '--policy')
  const plannedPolicy = planPolicy(policy, { strategySource: args['strategy-source'], operatorPins: args['operator-pin'] ?? [] })
  const selection = finderSelection(policy)
  const slate = soloSlate(runId)
  const runDir = join(root, 'runs', runId)

  // Preconditions — every one refusable, all resolved before the first write.
  // An ended run is never re-armed: its record is final.
  const existing = join(runDir, 'run.json')
  if (existsSync(existing) && readJson(existing, 'run record').outcome !== null) {
    throw new Refusal(`run ${runId} has ended (outcome ${readJson(existing, 'run record').outcome}); reserve a fresh run id`)
  }
  const revision = governingRegistryRevision(repoRoot, args.base, branch)
  if (args['registry-revision'] !== undefined && args['registry-revision'] !== revision) {
    throw new Refusal(`--registry-revision ${args['registry-revision']} differs from the merge base's governing revision ${revision}`)
  }
  if (!trustedAt(repoRoot, revision).includes(actor)) {
    throw new Refusal(`actor ${actor} is not in agent-registry.json's trusted_orchestrator_actor_ids at ${revision}; its evidence markers would not authenticate, so no solo run is reserved`)
  }
  const activationPredecessor = checkActivationAllowed(repoRoot, branch, runId)
  const active = activePointerPath(root, branch)
  const current = activationPredecessor.run_id === null ? null : activationPredecessor
  if (current !== null && current.run_id !== runId) {
    const other = join(root, 'runs', current.run_id, 'run.json')
    const ended = existsSync(other) && readJson(other, 'active run record').outcome !== null
    if (!ended) {
      throw new Refusal(`branch ${branch} already has live active run ${current.run_id} (generation ${current.generation}); a solo run never supersedes a run that has not ended`)
    }
  }
  const binding = join(runDir, 'branch.json')
  const bindingExisted = existsSync(binding)
  if (bindingExisted && readJson(binding, 'run branch binding').branch !== branch) {
    throw new Refusal(`run ${runId} is already bound to branch ${readJson(binding, 'run branch binding').branch}, not ${branch}`)
  }
  assertRunOwner(root, slate, runId)

  // Writes. Each records how to undo itself, so a later failure leaves
  // nothing this call created behind (a re-arm adopts what already existed).
  const undo = []
  try {
    acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'], issues: [issue] })
    const planFile = join(root, 'slates', slate, 'plan.json')
    mkdirSync(dirname(planFile), { recursive: true })
    withMutex(planFile, () => {
      if (existsSync(planFile)) {
        const plan = currentPlan(root, slate)
        if (!plan.lanes.some((lane) => lane.run_id === runId && lane.issue === issue && lane.branch === branch)) {
          throw new Refusal(`${planFile} exists but does not plan run ${runId} for issue ${issue} on ${branch}`)
        }
        return
      }
      const reason = `solo run reserved by interactive session ${session} (inline confidence stages, harmon-devkit#1183)`
      const content = {
        seq: 0,
        at,
        reason,
        plan: {
          base_sha: args.base,
          policy: plannedPolicy,
          dispatcher: { kind: 'interactive', parallel_cap: plannedPolicy.breadth.max_parallel_agents, foreman_max_parallel: null },
          issues: [{ number: issue, title: args.title, url: args.url, verdict: 'valid', candidate_files: ['**'], blocked_by: [] }],
          overlaps: [],
          waves: [{ number: 1, issues: [issue] }],
          lanes: [{ lane: 'solo', issue, wave: 1, branch, run_id: runId, fence: ['**'], expansions: [] }],
        },
      }
      writeValidated('plan', planFile, {
        schema: 1,
        slate_id: slate,
        revisions: [{ ...content, prev_digest: 'genesis', digest: chainDigest(content, 'genesis') }],
      })
      undo.push(() => rmSync(join(root, 'slates', slate), { recursive: true, force: true }))
    })
    const ownerFile = join(runDir, 'owner-slate')
    const ownerExisted = existsSync(ownerFile)
    bindRunToSlate(root, slate, runId)
    if (!ownerExisted) undo.push(() => rmSync(ownerFile, { force: true }))

    // policy.json is the projection itself; the one field the renderer needs
    // and a default resolution leaves unset is the rigor source it discloses.
    const projection = kickoffPolicyProjection(policy, plannedPolicy)
    const policyFile = join(runDir, 'policy.json')
    if (publishExclusive(policyFile, `${JSON.stringify(projection, null, 2)}\n`, 'policy projection')) {
      undo.push(() => rmSync(policyFile, { force: true }))
    }
    const canonical = join(runDir, 'run.json')
    withMutex(canonical, () => {
      if (existsSync(canonical)) {
        const record = readJson(canonical, 'run record')
        if (record.run_id !== runId) throw new Refusal(`${canonical} records run_id ${JSON.stringify(record.run_id)}, not ${runId}`)
        if (record.outcome !== null) throw new Refusal(`run ${runId} has ended (outcome ${record.outcome}); reserve a fresh run id`)
        validateFile('run', canonical, `existing ${canonical}`)
        return
      }
      writeValidated('run', canonical, {
        schema: 2,
        run_id: runId,
        initiated_by: 'human',
        started_at: at,
        stage_transitions: [
          {
            stage: 'kickoff',
            entered_at: at,
            exit: `resolved: rigor ${plannedPolicy.rigor} (${plannedPolicy.rigor_source}), strategy ${plannedPolicy.strategy} (${plannedPolicy.strategy_source}); solo run for session ${session}`,
          },
        ],
        receipts: [],
        // The resolved per-run finder selection, persisted where the exit
        // engine restores it from (#810), so an added finder's slot counts.
        ...(selection.length > 0 ? { finder_selection: selection } : {}),
        interventions: [],
        outcome: null,
        pr: null,
        evidence_comments: [],
        evidence_registrations: [],
        pr_bindings: [],
        outcome_transitions: [],
        settlements: [],
        promotion: null,
      })
      undo.push(() => rmSync(canonical, { force: true }))
    })

    let generation = current?.generation ?? 0
    if (current?.run_id !== runId) {
      undo.push(() => {
        if (!bindingExisted) rmSync(binding, { force: true })
      })
      try {
        generation = Number(
          execFileSync('bash', [monitorPath(), 'activate', '--active-state', active, '--run-id', runId, '--branch', branch,
            '--expected-predecessor', current?.run_id ?? 'absent', '--expected-generation', String(generation),
            '--registry-revision', revision, '--writer', 'feature-owner',
            '--repo-root', repoRoot], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(),
        )
      } catch (error) {
        throw new Refusal(`activation refused: ${`${error.stderr || ''}`.trim() || `exit ${error.status}`}`)
      }
    }
    return JSON.stringify({
      run_id: runId,
      slate_id: slate,
      session,
      branch,
      generation,
      active_state_path: active,
      record_directory: runDir,
      policy_projection: join(runDir, 'policy.json'),
      common_dir: common,
    })
  } catch (error) {
    for (const step of undo.reverse()) {
      try {
        step()
      } catch {
        // best effort: the refusal below names the original cause
      }
    }
    try {
      rmdirSync(runDir)
    } catch {
      // not empty, or never created
    }
    throw error
  }
}

function runValidatorWith(argv) {
  try {
    execFileSync(process.execPath, [VALIDATOR, ...argv], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
    return null
  } catch (error) {
    return `${error.stderr || ''}${error.stdout || ''}`.trim() || `validator exited ${error.status}`
  }
}

function withJsonTemp(runDir, value, fn) {
  const file = join(runDir, `.context.${process.pid}.${randomBytes(4).toString('hex')}.json`)
  writeFileSync(file, JSON.stringify(value))
  try {
    return fn(file)
  } finally {
    unlinkSync(file)
  }
}

function receiptedPassNames(record) {
  return (record.receipts ?? []).filter((receipt) => receipt.kind === 'pass').map((receipt) => receipt.file)
}

function adjudicatedRounds(runDir, stage) {
  const directory = join(runDir, 'adjudications')
  if (!existsSync(directory)) return []
  return readdirSync(directory)
    .map((name) => new RegExp(`^${stage}-r([1-9][0-9]*)\\.json$`).exec(name))
    .filter(Boolean)
    .map((match) => Number(match[1]))
}

// branchHead — the head of the branch the run is bound to (branch.json), read
// from the shared refs so any worktree of the clone resolves the same commit.
function branchHead(runDir) {
  const binding = join(runDir, 'branch.json')
  if (!existsSync(binding)) throw new Refusal(`${binding} is missing; the run is bound to no branch`)
  const { branch } = readJson(binding, 'run branch binding')
  try {
    return { branch, head: git(['rev-parse', '--verify', '--quiet', `refs/heads/${branch}^{commit}`]) }
  } catch {
    throw new Refusal(`branch ${branch} does not resolve to a commit in this clone`)
  }
}

// resolvedSlots — the stage's finder slots: the run's policy projection's
// configured finders plus any the run's finder_selection added.
function resolvedSlots(record, runDir, stage) {
  const policy = readJson(join(runDir, 'policy.json'), 'run policy projection')
  const selected = (record.finder_selection ?? []).filter((entry) => entry.stage === stage).flatMap((entry) => entry.effective ?? [])
  return new Set([...(policy?.stages?.[stage]?.finders ?? []), ...selected])
}

// admitPass — the receipt invariant: a pass is evidence only when it is a
// completed pass for a configured slot of the active stage, for that stage's
// next unadjudicated round, of the branch head under review — the same head
// every pass already receipted for that round reviewed — produced inside the
// stage's span. Anything else would take a slot the exit engine never counts
// (and an immutable slot cannot be retried) or wedge the run.
function admitPass(record, envelope, runDir) {
  const { stage, round, reviewed_head: reviewed } = envelope.payload ?? {}
  const slot = envelope.payload?.slot ?? envelope.payload?.finder
  const refuse = (reason) => {
    throw new Refusal(`pass ${stage}-r${round}-${slot} is not admissible: ${reason}`)
  }
  if (envelope.role !== 'challenger' && envelope.role !== 'reviewer') refuse('it is not a challenger or reviewer result envelope')
  if (!CONFIDENCE_STAGES.has(stage) || !Number.isSafeInteger(round) || round < 1 || typeof slot !== 'string') {
    refuse('it names no confidence stage, positive round and slot')
  }
  if (envelope.status !== 'completed') refuse(`its status is ${JSON.stringify(envelope.status)}, not "completed"`)
  const role = stage === 'challenge' ? 'challenger' : 'reviewer'
  if (envelope.role !== role) refuse(`stage ${stage} is filled only by a ${role} envelope, not ${envelope.role}`)
  const resolution = readJson(join(runDir, 'policy.json'), 'run policy projection')
  const order = Array.isArray(resolution?.tier_order) ? resolution.tier_order : null
  const resolvedTier = resolution?.roles?.[role]?.tier
  if (order !== null && typeof resolvedTier === 'string' && order.includes(resolvedTier) &&
      !(order.indexOf(envelope.producer?.tier) >= order.indexOf(resolvedTier))) {
    refuse(`its producer tier ${JSON.stringify(envelope.producer?.tier)} is below the run's resolved ${role} tier ${resolvedTier}`)
  }
  const active = record.stage_transitions.at(-1)
  if (active.stage !== stage) refuse(`the run's active stage is ${active.stage}`)
  const slots = resolvedSlots(record, runDir, stage)
  if (!slots.has(slot)) refuse(`slot ${slot} is not a configured ${stage} finder (${[...slots].join(', ') || 'none'})`)
  const next = Math.max(0, ...adjudicatedRounds(runDir, stage)) + 1
  if (round !== next) refuse(`the next unadjudicated ${stage} round is ${next}`)
  // A round's head is fixed from its first receipt to its adjudication; a
  // round whose head moved is invalidated and re-run, never mixed
  // (harmon-devkit#1445 owns that invalidation).
  const fixed = receiptedPassNames(record)
    .filter((file) => file.startsWith(`${stage}-r${round}-`))
    .map((file) => readJson(join(runDir, 'passes', `${file}.json`), 'receipted pass').payload?.reviewed_head)
    .find((value) => value !== reviewed)
  if (fixed !== undefined) refuse(`${stage} round ${round} is fixed at head ${fixed} by its receipted passes; a moved round is invalidated and re-run (harmon-devkit#1445), never mixed`)
  const { branch, head } = branchHead(runDir)
  if (envelope.head !== head || reviewed !== head) refuse(`it reviewed ${reviewed}, not ${branch}'s head ${head}`)
  if (typeof envelope.produced_at !== 'string' || !TIMESTAMP.test(envelope.produced_at) ||
      isBefore(envelope.produced_at, active.entered_at) || Date.now() < Date.parse(envelope.produced_at)) {
    refuse(`produced_at ${JSON.stringify(envelope.produced_at)} is outside the stage's span (${active.entered_at} to now)`)
  }
  return `${stage}-r${round}-${slot}`
}

// ledgerEntries — the change ledger for one fix: how the commits between two
// reviewed heads changed each file (new-side added lines, old-side deleted
// lines, and the rename source), in the shape dev-flow-exit.mjs verifies
// provenance and fingerprints against.
// Paths come only from `--name-status -z` (raw bytes, NUL-separated, never
// quoted or prefixed), and each file's hunk headers from a diff limited to
// that pathspec, so no presentation header is ever parsed for a path.
function ledgerEntries(round, from, to) {
  const diffArgs = ['-c', 'core.quotePath=false', 'diff', '--no-ext-diff', '--no-color', '--no-textconv', '-M']
  const fields = git([...diffArgs, '--name-status', '-z', from, to]).split('\0').filter((field) => field !== '')
  const entries = []
  for (let index = 0; index < fields.length; ) {
    const status = fields[index]
    const renamed = /^[RC]/.test(status)
    const source = fields[index + 1]
    const path = renamed ? fields[index + 2] : source
    index += renamed ? 3 : 2
    // A deleted file has no new-side path; it can carry no later finding.
    if (status === 'D') continue
    const entry = { round, path, added_lines: [], deleted_lines: [], renamed_from: status.startsWith('R') ? source : null }
    const pathspec = (value) => `:(literal)${value}`
    const hunks = git([...diffArgs, '--unified=0', '--src-prefix=a/', '--dst-prefix=b/', from, to, '--',
      ...(renamed ? [pathspec(source)] : []), pathspec(path)])
    for (const line of hunks.split('\n').filter((text) => text.startsWith('@@ '))) {
      const hunk = /^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@/.exec(line)
      if (!hunk) throw new Refusal(`unparseable hunk header ${JSON.stringify(line)} between ${from} and ${to}`)
      const [oldStart, oldCount, newStart, newCount] = [hunk[1], hunk[2] ?? '1', hunk[3], hunk[4] ?? '1'].map(Number)
      for (let i = 0; i < oldCount; i += 1) entry.deleted_lines.push(oldStart + i)
      for (let i = 0; i < newCount; i += 1) entry.added_lines.push(newStart + i)
    }
    entries.push(entry)
  }
  return entries
}

const SIDE_EFFECTS = {
  receipt(record, args, { runDir }) {
    if (typeof args.pass !== 'string' || args.pass === '') throw new UsageError('--pass is required')
    guardTimestamp(record, resolveAt(undefined))
    const envelope = readJson(args.pass, 'pass')
    const bytes = readFileSync(args.pass)
    const slot = envelope?.payload?.slot ?? envelope?.payload?.finder
    const name = `${envelope?.payload?.stage}-r${envelope?.payload?.round}-${slot}`
    // The name becomes a path: validate it before any path is built.
    if (typeof slot !== 'string' || !SAFE_ID.test(slot) || !SAFE_ID.test(name)) {
      throw new Refusal(`pass ${JSON.stringify(name)} is not admissible: its stage, round and slot do not form a safe file name`)
    }
    const canonical = join(runDir, 'passes', `${name}.json`)
    if (receiptedPassNames(record).includes(name)) {
      if (!existsSync(canonical) || !readFileSync(canonical).equals(bytes)) {
        throw new Refusal(`pass ${name} is already receipted with different content; a receipted pass is immutable`)
      }
      return null
    }
    admitPass(record, envelope, runDir)
    const knownIds = receiptedPassNames(record).flatMap((file) => {
      const path = join(runDir, 'passes', `${file}.json`)
      if (!existsSync(path)) throw new Refusal(`run.json receipts pass ${file}, but ${path} does not exist`)
      return (readJson(path, 'receipted pass').payload?.findings ?? []).map((finding) => finding.id)
    })
    const failure = withJsonTemp(runDir, knownIds, (known) =>
      runValidatorWith(['envelope', args.pass, '--run-id', record.run_id, '--initiated-by', record.initiated_by, '--known-ids', known, '--receipt']),
    )
    if (failure !== null) throw new Refusal(`pass ${args.pass} failed receipt validation; nothing was published:\n${failure}`)
    publishExclusive(canonical, bytes, 'pass')
    record.receipts = [...(record.receipts ?? []), { kind: 'pass', file: name }]
    return { write: true, summary: `pass receipt ${name}` }
  },
  adjudicate(record, args, { runDir, canonical: runPath }) {
    if (typeof args.file !== 'string' || args.file === '') throw new UsageError('--file is required')
    guardTimestamp(record, resolveAt(undefined))
    const document = readJson(args.file, 'adjudication')
    const bytes = readFileSync(args.file)
    if (document?.run_id !== record.run_id) throw new Refusal(`adjudication names run ${JSON.stringify(document?.run_id)}, not ${record.run_id}`)
    const { stage, round } = document
    if (!CONFIDENCE_STAGES.has(stage) || !Number.isSafeInteger(round) || round < 1) {
      throw new Refusal('adjudication names no confidence stage and positive round')
    }
    const name = `${stage}-r${round}`
    const target = join(runDir, 'adjudications', `${name}.json`)
    if (existsSync(target)) {
      if (!readFileSync(target).equals(bytes)) throw new Refusal(`${target} already exists with different content; a round is adjudicated once`)
      return null
    }
    const active = record.stage_transitions.at(-1).stage
    if (stage !== active) throw new Refusal(`adjudication is for stage ${stage}, but the run's active stage is ${active}`)
    const passes = receiptedPassNames(record)
      .filter((file) => file.startsWith(`${name}-`))
      .map((file) => join(runDir, 'passes', `${file}.json`))
    if (passes.length === 0) throw new Refusal(`round ${name} has no receipted pass to adjudicate`)
    const missing = [...resolvedSlots(record, runDir, stage)].filter((slot) => !receiptedPassNames(record).includes(`${name}-${slot}`))
    if (missing.length > 0) throw new Refusal(`round ${name} is incomplete: no receipted pass for slot(s) ${missing.join(', ')}`)
    const directory = join(runDir, 'adjudications')
    const known = existsSync(directory)
      ? readdirSync(directory)
          .filter((file) => file.endsWith('.json') && file !== `${name}.json`)
          .flatMap((file) => (readJson(join(directory, file), 'adjudication').adjudications ?? []).map((entry) => entry.finding_id))
      : []
    const failure = withJsonTemp(runDir, known, (knownFile) =>
      runValidatorWith(['adjudication', args.file, ...passes.flatMap((pass) => ['--pass', pass]),
        '--run-id', record.run_id, '--initiated-by', record.initiated_by, '--known-adjudicated', knownFile, '--receipt']),
    )
    if (failure !== null) throw new Refusal(`adjudication ${args.file} failed receipt validation; nothing was published:\n${failure}`)
    publishExclusive(target, bytes, 'adjudication')
    const readback = runValidator('run', runPath)
    if (readback !== null) {
      unlinkSync(target)
      throw new Refusal(`run.json does not validate with ${name}; the adjudication was withdrawn:\n${readback}`)
    }
    return { write: false, summary: `adjudication ${name}` }
  },
  ledger(record, args, { runDir }) {
    const stage = args.stage
    if (!CONFIDENCE_STAGES.has(stage)) throw new UsageError('--stage must be challenge or review')
    guardTimestamp(record, resolveAt(undefined))
    const active = record.stage_transitions.at(-1).stage
    if (stage !== active) throw new Refusal(`ledger is for stage ${stage}, but the run's active stage is ${active}`)
    const heads = new Map()
    for (const file of receiptedPassNames(record).filter((name) => name.startsWith(`${stage}-r`))) {
      const pass = readJson(join(runDir, 'passes', `${file}.json`), 'receipted pass')
      const round = pass.payload.round
      if (heads.has(round) && heads.get(round) !== pass.payload.reviewed_head) {
        throw new Refusal(`${stage} round ${round}'s passes reviewed different heads`)
      }
      heads.set(round, pass.payload.reviewed_head)
    }
    const { branch, head } = branchHead(runDir)
    const rounds = [...heads.keys()].sort((a, b) => a - b)
    const ancestor = (a, b) => {
      try {
        git(['merge-base', '--is-ancestor', a, b])
        return true
      } catch {
        return false
      }
    }
    const history = []
    for (const [index, round] of rounds.entries()) {
      if (!ancestor(heads.get(round), head)) {
        throw new Refusal(`${stage} round ${round}'s reviewed head ${heads.get(round)} is not on ${branch}; the branch was rewritten`)
      }
      const next = rounds[index + 1]
      if (next !== undefined) history.push(...ledgerEntries(round, heads.get(round), heads.get(next)))
    }
    // First-parent head map from the branch head back to its merge base with
    // the default branch, which is the explicit root.
    let defaultRef
    try {
      defaultRef = git(['symbolic-ref', 'refs/remotes/origin/HEAD'])
    } catch {
      throw new Refusal('could not resolve the default branch (refs/remotes/origin/HEAD is unset)')
    }
    const mergeBase = git(['merge-base', defaultRef, head])
    const map = { [mergeBase]: { parent: null } }
    const walk = git(['rev-list', '--first-parent', '--parents', `${mergeBase}..${head}`])
    for (const line of walk.split('\n').filter(Boolean)) {
      const [commit, parent] = line.split(' ')
      map[commit] = { parent: parent ?? null }
    }
    // The ledger is per stage (its entries carry only round and path, so one
    // file across stages would mix challenge and review rounds); the head map
    // is stage-independent and shared.
    for (const [file, value] of [[`history.${stage}.json`, history], ['heads.json', map]]) {
      const target = join(runDir, file)
      const temporary = `${target}.tmp.${process.pid}.${randomBytes(4).toString('hex')}`
      writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`)
      renameSync(temporary, target)
    }
    return { write: false, summary: `${stage} ledger (${history.length} entr${history.length === 1 ? 'y' : 'ies'} over ${rounds.length} round(s)) and head map` }
  },
}

function sideEffectWrite(command, args) {
  const { root } = stateRoot()
  const slate = requireId('slate', args.slate)
  const session = requireId('session', args.session)
  const runId = requireId('run-id', args['run-id'])
  refuseGrafts()
  assertRunOwner(root, slate, runId)
  acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'] })
  bindRunToSlate(root, slate, runId)
  const runDir = join(root, 'runs', runId)
  const canonical = join(runDir, 'run.json')
  const summary = withMutex(canonical, () => {
    const record = readJson(canonical, 'run record')
    if (record.run_id !== runId) throw new Refusal(`${canonical} records run_id ${JSON.stringify(record.run_id)}, not ${runId}`)
    validateFile('run', canonical, `existing ${canonical}`)
    const result = SIDE_EFFECTS[command](record, args, { runDir, canonical })
    if (result === null) return null
    if (result.write) writeValidated('run', canonical, record)
    return result.summary
  })
  return summary === null ? 'no change (already recorded)' : `recorded ${summary}`
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const VALUE_FLAGS = new Set([
  'slate', 'session', 'owner-token', 'run-id', 'stage', 'exit', 'at', 'kind', 'note', 'ruling', 'number', 'url',
  'decision', 'command', 'answered-by',
  'head', 'fingerprint', 'outcome', 'milestone', 'issues', 'reason',
  'remediation-head', 'remediation-findings',
  'issue', 'title', 'branch', 'base', 'policy', 'registry-revision', 'pass', 'file',
  'actor-id', 'strategy-source', 'operator-pin', 'round', 'actor', 'instruction', 'lane',
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
    if (!existsSync(file)) return `slate ${slate} is unlocked`
    return JSON.stringify(readLock(file))
  }
  const session = requireId('session', args.session)
  if (sub === 'check') {
    const { file } = lockPaths(root, slate)
    if (!existsSync(file)) throw new Refusal(`slate ${slate} is unlocked`)
    assertLockOwner(readLock(file), session, args['owner-token'])
    return 'slate lock owner verified (read-only)'
  }
  if (sub === 'acquire') {
    const lock = acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'], milestone: args.milestone, issues: args.issues, create: true })
    return lock.created === true ? lock.mintedToken : null
  }
  if (sub === 'release') {
    const held = releaseSlateLock({ root, slate, session, ownerToken: args['owner-token'], force: args.force === true, reason: args.reason })
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
  if (command === 'prune') {
    return pruneActivePointers(parseFlags(rest, new Set(['repo-root']), new Set(['dry-run'])))
  }
  if (command === 'lock') {
    const [sub, ...flags] = rest
    return lockCommand(sub, parseScopeFlags(parseFlags(flags)))
  }
  if (command === 'solo-init') return soloInit(parseFlags(rest, VALUE_FLAGS, BOOLEAN_FLAGS, new Set(['operator-pin'])))
  if (command === 'lane-init') return laneInit(parseFlags(rest))
  if (command === 'promote') {
    const args = parseScopeFlags(parseFlags(rest, VALUE_FLAGS, new Set(['check'])))
    return recordMutation(command, args, { check: args.check === true })
  }
  if (Object.hasOwn(SIDE_EFFECTS, command ?? '')) return sideEffectWrite(command, parseFlags(rest))
  if (!Object.hasOwn(MUTATORS, command ?? '')) {
    throw new UsageError('run-record.mjs transition|authorize-cap|intervention|bind-pr|promote|close|prune [--dry-run] [--repo-root DIR]|solo-init|lane-init|receipt|adjudicate|ledger|lock … (see the header)')
  }
  return recordMutation(command, parseScopeFlags(parseFlags(rest)))
}

if (realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url))) runCli(main)
