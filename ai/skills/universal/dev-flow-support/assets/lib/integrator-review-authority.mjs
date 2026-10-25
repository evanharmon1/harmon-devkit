// Immutable, owner-recorded authority for an integration review cycle.
//
// The checker state in a worktree belongs to the integrator.  It is useful for
// polling, but it cannot say which PR head a review request was made for.  The
// run owner snapshots that state while it performs reserve/attach/carry and
// retains the snapshot through run-record.mjs's existing ruling mechanism.
// Receipt admission consumes only those snapshots as cycle authority.
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { join, normalize, relative, resolve } from 'node:path'

export const AUTHORITY_NOTE_PREFIX = 'integration-review-authority v1'
const SHA = /^[0-9a-f]{64}$/
const SHA40 = /^[0-9a-f]{40}$/
const POSITIVE = /^[1-9][0-9]*$/

export function digestBytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

export function authorityNote(kind, digest) {
  return `${AUTHORITY_NOTE_PREFIX} ${kind} sha256=${digest}`
}

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return null }
}

function validState(state) {
  return state && typeof state === 'object' &&
    typeof state.repo === 'string' && state.repo.length > 0 &&
    Number.isSafeInteger(state.pr) && state.pr > 0 &&
    SHA40.test(state.head ?? '') &&
    Number.isSafeInteger(state.charged_cycles) && state.charged_cycles >= 0 &&
    Number.isSafeInteger(state.exempt_cycles) && state.exempt_cycles >= 0 &&
    Number.isSafeInteger(state.attempt) && state.attempt >= 1
}

function authorityPath(common, runId, path, digest) {
  const runRoot = resolve(common, 'dev-flow-v2', 'runs', runId)
  const candidate = resolve(common, path)
  if (relative(runRoot, candidate).startsWith('..') || !candidate.startsWith(`${runRoot}/rulings/`)) return null
  if (!candidate.endsWith(`/rulings/${digest}`)) return null
  return candidate
}

// Intervention notes deliberately remain human-readable.  This parser owns the
// machine suffix so callers cannot turn arbitrary ruling prose into authority.
const NOTE = /^integration-review-authority v1 (reserve|attach|carry) sha256=([0-9a-f]{64}) \[ruling ([^\]]+) sha256=([0-9a-f]{64})\]$/

export function retainedAuthorities(record, { common, runId }) {
  const entries = []
  for (const intervention of record?.interventions ?? []) {
    const match = NOTE.exec(intervention?.note ?? '')
    if (!match || match[2] !== match[4]) continue
    const file = authorityPath(common, runId, normalize(match[3]), match[2])
    if (!file || !existsSync(file)) continue
    const bytes = readFileSync(file)
    if (digestBytes(bytes) !== match[2]) continue
    const authority = readJson(file)
    if (authority?.schema !== 1 || authority?.kind !== match[1] || !validState(authority.snapshot)) continue
    try {
      validateAuthority(authority, entries)
    } catch { continue }
    entries.push({ kind: match[1], digest: match[2], authority, intervention })
  }
  return entries
}

export function authorityCoordinate(state) {
  return `${state.repo}#${state.pr}:${state.head}:${state.charged_cycles + state.exempt_cycles}:${state.attempt}`
}

export function authorityIdentity(authority) {
  const { kind, snapshot } = authority
  if (kind !== 'carry') return `${kind}:${authorityCoordinate(snapshot)}:${snapshot.trigger_comment_id ?? ''}`
  const carry = snapshot.carry ?? {}
  return `${kind}:${authorityCoordinate(snapshot)}:${carry.from_head ?? ''}:${carry.attests_head ?? ''}:${carry.generation ?? ''}`
}

function stable(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}`
}

export function sameAuthoritySnapshot(left, right) {
  return stable(left?.snapshot) === stable(right?.snapshot)
}

export function validateAuthority(authority, prior = []) {
  const { kind, snapshot } = authority ?? {}
  if (!['reserve', 'attach', 'carry'].includes(kind)) throw new Error('unknown integration review authority kind')
  if (!validState(snapshot)) throw new Error('authority snapshot has no complete checker control tuple')
  const previous = authority.previous_authority_digest ?? null
  const expectedPrevious = prior.at(-1)?.digest ?? null
  if (previous !== expectedPrevious) throw new Error('authority is not linked to the immediately preceding retained capture')
  if (kind === 'reserve') {
    if (snapshot.phase !== 'reserved' || snapshot.trigger_comment_id != null) {
      throw new Error('reserve authority must snapshot an un-attached checker reservation')
    }
    return
  }
  if (kind === 'attach') {
    if (snapshot.phase !== 'attached' || !POSITIVE.test(String(snapshot.trigger_comment_id ?? ''))) {
      throw new Error('attach authority must snapshot an attached trigger')
    }
    const coordinate = authorityCoordinate(snapshot)
    if (!prior.some((entry) => entry.kind === 'reserve' && authorityCoordinate(entry.authority.snapshot) === coordinate)) {
      throw new Error('attach authority has no retained matching reserve authority')
    }
    return
  }
  const carry = snapshot.carry
  if (!carry || !SHA40.test(carry.from_head ?? '') || !SHA40.test(carry.attests_head ?? '')) {
    throw new Error('carry authority has no complete origin/attested-head proof')
  }
  const origin = snapshot.head
  const predecessor = prior.some((entry) => {
    const state = entry.authority.snapshot
    const attested = state.carry?.attests_head ?? state.head
    return ['attach', 'carry'].includes(entry.kind) &&
      (carry.from_head === origin ? state.head === origin : attested === carry.from_head)
  })
  if (!predecessor) {
    throw new Error('carry authority has no retained origin or immediate predecessor authority')
  }
}

export function authorityForEnvelope(record, envelope, options) {
  const cycle = envelope?.payload?.codex_cycle
  if (!cycle) return null
  const retained = retainedAuthorities(record, options)
  const candidates = retained.filter((entry) => {
    const state = entry.authority.snapshot
    const attested = state.carry?.attests_head ?? state.head
    return attested === envelope.head &&
      Number(cycle.cycle) === state.charged_cycles + state.exempt_cycles &&
      Number(cycle.attempt) === state.attempt &&
      String(cycle.trigger_comment_id) === String(state.trigger_comment_id)
  })
  if (candidates.length === 0) {
    const hasCapture = (record?.interventions ?? []).some((entry) =>
      typeof entry?.note === 'string' && entry.note.startsWith(AUTHORITY_NOTE_PREFIX))
    if (retained.length === 0 && !hasCapture) return null
    throw new Error('no retained owner authority matches the claimed review cycle')
  }
  if (candidates.length !== 1) throw new Error('multiple retained owner authorities match the claimed review cycle')
  const selected = candidates[0]
  const attested = selected.authority.snapshot.carry?.attests_head ?? selected.authority.snapshot.head
  if (attested !== envelope.head) throw new Error('retained owner authority does not attest the envelope head')
  return selected
}
