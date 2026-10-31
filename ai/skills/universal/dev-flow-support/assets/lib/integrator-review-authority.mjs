// Immutable, owner-recorded authority for an integration review cycle.
//
// The checker state in a worktree belongs to the integrator.  It is useful for
// polling, but it cannot say which PR head a review request was made for.  The
// run owner snapshots reserve/carry immediately and a reconstructed attachment
// only after polling reaches a terminal or retry observation, retaining that
// snapshot through run-record.mjs's existing ruling mechanism.
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
  return parseJson(readFileSync(path))
}

function parseJson(bytes) {
  try { return JSON.parse(bytes.toString('utf8')) } catch { return null }
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

export function retainedAuthorities(record, options) {
  const { common, runId } = options
  const entries = []
  for (const intervention of record?.interventions ?? []) {
    const note = intervention?.note ?? ''
    const match = NOTE.exec(note)
    if (!match) {
      if (typeof note === 'string' && note.startsWith(AUTHORITY_NOTE_PREFIX)) {
        throw new Error('recognized retained authority intervention is malformed')
      }
      continue
    }
    if (match[2] !== match[4]) throw new Error('recognized retained authority intervention digest is inconsistent')
    const file = authorityPath(common, runId, normalize(match[3]), match[2])
    if (!file) throw new Error('recognized retained authority has an invalid ruling path')
    if (!existsSync(file)) throw new Error('recognized retained authority ruling is missing')
    const bytes = readFileSync(file)
    if (digestBytes(bytes) !== match[2]) throw new Error('recognized retained authority ruling digest does not match its intervention')
    const authority = parseJson(bytes)
    if (authority?.schema !== 1 || authority?.kind !== match[1] || !validState(authority.snapshot)) {
      throw new Error('recognized retained authority ruling has an invalid schema or snapshot')
    }
    try {
      validateAuthority(authority, entries, record, options)
    } catch (error) {
      throw new Error(`recognized retained authority ruling is invalid: ${error.message}`)
    }
    entries.push({ kind: match[1], digest: match[2], authority, intervention })
  }
  return entries
}

export function authorityCoordinate(state) {
  return `${state.repo}#${state.pr}:${state.head}:${state.charged_cycles + state.exempt_cycles}:${state.attempt}:${finderIdentity(state)}`
}

export function authorityIdentity(authority) {
  const { kind, snapshot } = authority
  const parent = authority?.parent_authority_digest ?? ''
  // A parent digest selects an ambiguous retained authority; it is not part of
  // the immutable request being captured.  A request first captured while its
  // parent was unique must therefore remain the same request when a later
  // finder makes that parent ambiguous and the owner supplies its selector.
  // The coordinate already partitions named finders, and the trigger anchor
  // distinguishes review-comment requests within that partition.
  if (kind !== 'carry') return `${kind}:${authorityCoordinate(snapshot)}:${snapshot.trigger_comment_id ?? ''}`
  const carry = snapshot.carry ?? {}
  return `${kind}:${authorityCoordinate(snapshot)}:${carry.from_head ?? ''}:${carry.attests_head ?? ''}:${carry.generation ?? ''}:${parent}`
}

function stable(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}`
}

// A finder slug is the immutable partition for one reviewer's authority
// history.  Full finder profiles remain in cycle/request controls, where they
// protect retry and carry from silently changing a reviewer's configuration.
// The null partition preserves the conservative legacy checker shape in
// immutable identities; live frontier selection uses its Codex chronology.
function finderIdentity(state) {
  const slug = state?.finder?.slug
  return typeof slug === 'string' && slug.length > 0 ? `finder:${slug}` : 'legacy:null'
}

// Legacy finder-null captures and named Codex captures belong to one ordered
// review history. Use this only for live frontier selection, never to rewrite
// immutable request identities or relax profile/control authentication.
function chronologyIdentity(state) {
  const identity = finderIdentity(state)
  return identity === 'legacy:null' ? 'finder:codex-cloud' : identity
}

export function sameAuthoritySnapshot(left, right) {
  return stable(left?.snapshot) === stable(right?.snapshot)
}

// Attachment is produced by the canonical checker from this retained state.
// These fields identify the request control tuple after that transition.  The
// checker alone may change requires_full_window as it reconstructs the trigger.
function cycleIdentity(state) {
  return {
    repo: state?.repo,
    pr: state?.pr,
    head: state?.head,
    cycle: Number(state?.charged_cycles) + Number(state?.exempt_cycles),
    finder: state?.finder ?? null,
  }
}

// Mutable public-capture reports do not select a finder. They may locate one
// immutable retained parent by its cycle coordinates, but a coordinate shared
// by more than one finder is an ambiguity, never a reason to let the report's
// mutable finder pick one of them.
function cycleLocator(state) {
  return cycleIdentity(state)
}

function publicCycleLocator(state) {
  return {
    repo: state?.repo,
    pr: state?.pr,
    head: state?.head,
    cycle: Number(state?.charged_cycles) + Number(state?.exempt_cycles),
  }
}

// Request controls belong to an owner-created cycle, not the integrator's
// mutable checker file.  CI's charged/exempt split is deliberately absent:
// the canonical checker recomputes it from current CI evidence at admission.
function requestControls(state) {
  return {
    ...cycleIdentity(state),
    attempt: state?.attempt,
    first_trigger_comment_id: state?.first_trigger_comment_id ?? null,
    trigger_comment_id: state?.trigger_comment_id ?? null,
    requested_at: state?.requested_at ?? null,
    first_requested_at: state?.first_requested_at ?? null,
    timeout_min: state?.timeout_min ?? null,
  }
}

function reservationControls(state) {
  return {
    ...cycleIdentity(state),
    attempt: state?.attempt,
    reserved_at: state?.reserved_at ?? null,
    timeout_min: state?.timeout_min ?? null,
  }
}

// `retainedAuthorities` reconstructs the ordered immutable history for the
// caller-owned run. A live transition starts only from that history's latest
// entry; caller-controlled checker fields can describe it but cannot select a
// prior entry. Historical reads below are deliberately separate.
function currentAuthorityFrontier(prior, state) {
  if (state === undefined) {
    const identities = new Set(prior.map((entry) => chronologyIdentity(entry.authority.snapshot)))
    if (identities.size > 1) throw new Error('current authority frontier needs an immutable finder identity')
    return prior.at(-1) ?? null
  }
  return prior.filter((entry) => chronologyIdentity(entry.authority.snapshot) === chronologyIdentity(state)).at(-1) ?? null
}

function authorityFrontiers(prior) {
  const frontiers = new Map()
  for (const entry of prior) frontiers.set(chronologyIdentity(entry.authority.snapshot), entry)
  return [...frontiers.values()]
}

function uniquePublicParent(candidates, relation, parentDigest) {
  if (parentDigest !== undefined) {
    if (!SHA.test(parentDigest)) throw new Error(`${relation} selector is not an immutable authority digest`)
    const selected = candidates.filter((entry) => entry.digest === parentDigest)
    if (selected.length !== 1) throw new Error(`${relation} selector does not name a compatible retained authority`)
    return selected[0]
  }
  if (candidates.length > 1) {
    throw new Error(`${relation} is ambiguous across retained finder authorities`)
  }
  return candidates[0] ?? null
}

function samePublicCycle(left, right) {
  return stable(publicCycleLocator(left)) === stable(publicCycleLocator(right))
}

function matchingPublicReserve(prior, state, parentDigest) {
  const candidates = []
  for (const frontier of authorityFrontiers(prior)) {
    const snapshot = frontier.authority.snapshot
    if (!samePublicCycle(snapshot, state) || Number(snapshot.attempt) !== Number(state?.attempt)) continue
    if (frontier.kind === 'reserve') {
      candidates.push(frontier)
      continue
    }
    // A crash replay may observe the current attachment again. Its immutable
    // frontier, not any mutable trigger or finder field, identifies the one
    // reservation that began it.
    if (frontier.kind !== 'attach') continue
    const reserves = prior.filter((entry) => entry.kind === 'reserve' &&
      authorityCoordinate(entry.authority.snapshot) === authorityCoordinate(snapshot))
    if (reserves.length === 1) candidates.push(reserves[0])
    else if (reserves.length > 1) {
      throw new Error('current retained attachment has ambiguous reserve authority')
    }
  }
  return uniquePublicParent(candidates, 'retained reservation parent', parentDigest)
}

function matchingPublicCycleOrigin(prior, state, parentDigest) {
  // Retry reservations are the current frontier for their finder, but the
  // selected first attachment remains the immutable origin they extend.
  const candidates = prior.filter((entry) =>
    entry.kind === 'attach' && Number(entry.authority.snapshot.attempt) === 1 &&
    samePublicCycle(entry.authority.snapshot, state))
  const origin = uniquePublicParent(candidates, 'retained first-request parent', parentDigest)
  return currentCycleOrigin(prior, origin)
}

function currentCycleOrigin(prior, origin) {
  if (!origin) return null
  // An immutable first request is historical context, never a way to revive a
  // cycle this finder has already advanced past. Select the frontier from the
  // origin's retained finder identity, not mutable capture input.
  const frontier = currentAuthorityFrontier(prior, origin.authority.snapshot)
  if (!frontier || !samePublicCycle(frontier.authority.snapshot, origin.authority.snapshot)) {
    throw new Error('retained first-request parent is not this finder’s current cycle frontier')
  }
  return origin
}

function matchingPublicCarryPredecessor(prior, state, parentDigest) {
  const from = state?.carry?.from_head
  const candidates = authorityFrontiers(prior).filter((entry) => {
    if (!['attach', 'carry'].includes(entry.kind)) return false
    const snapshot = entry.authority.snapshot
    const attested = snapshot.carry?.attests_head ?? snapshot.head
    return attested === from && Number(snapshot.attempt) === Number(state?.attempt) &&
      samePublicCycle(snapshot, state)
  })
  return uniquePublicParent(candidates, 'retained carry predecessor', parentDigest)
}

function matchingReserve(prior, state) {
  const frontier = currentAuthorityFrontier(prior, state)
  if (frontier?.kind === 'reserve' &&
      authorityCoordinate(frontier.authority.snapshot) === authorityCoordinate(state)) {
    return frontier
  }
  // Re-observing the current attachment must replay its own retained
  // reservation without making a later attachment reachable. The current
  // frontier proves this is that attachment; only then may we read its
  // historical reservation control tuple.
  if (frontier?.kind !== 'attach' ||
      authorityCoordinate(frontier.authority.snapshot) !== authorityCoordinate(state) ||
      String(frontier.authority.snapshot.trigger_comment_id) !== String(state.trigger_comment_id)) return null
  const matches = prior.filter((entry) => entry.kind === 'reserve' &&
    authorityCoordinate(entry.authority.snapshot) === authorityCoordinate(state))
  return matches.length === 1 ? matches[0] : null
}

function matchingOriginAttach(prior, state) {
  // The first attachment remains immutable context for a retry after the
  // latest frontier advanced to its attempt-2 reservation. This is a
  // historical read, not selection for a new live transition.
  const matches = prior.filter((entry) => entry.kind === 'attach' &&
    Number(entry.authority.snapshot.attempt) === 1 &&
    stable(cycleLocator(entry.authority.snapshot)) === stable(cycleLocator(state)))
  return currentCycleOrigin(prior, matches.length === 1 ? matches[0] : null)
}

function matchingCarryPredecessor(prior, state) {
  const from = state?.carry?.from_head
  const frontier = currentAuthorityFrontier(prior, state)
  if (!frontier || !['attach', 'carry'].includes(frontier.kind)) return null
  const predecessor = frontier.authority.snapshot
  const attested = predecessor.carry?.attests_head ?? predecessor.head
  return attested === from &&
    Number(predecessor.attempt) === Number(state?.attempt) &&
    stable(cycleIdentity(predecessor)) === stable(cycleIdentity(state))
    ? frontier
    : null
}

function matchingCarryReplay(prior, state) {
  const wanted = state?.carry
  const frontier = currentAuthorityFrontier(prior, state)
  if (frontier?.kind !== 'carry') return null
  const retained = frontier.authority.snapshot
  return retained.carry?.from_head === wanted?.from_head &&
    retained.carry?.attests_head === wanted?.attests_head &&
    Number(retained.attempt) === Number(state?.attempt) &&
    stable(cycleIdentity(retained)) === stable(cycleIdentity(state)) &&
    stable(requestControls(retained)) === stable(requestControls(state))
    ? frontier
    : null
}

function matchingTerminalReceipt(record, snapshot, { common, runId }) {
  const binding = record?.pr_bindings?.at(-1)
  let bound = false
  try {
    const url = new URL(binding?.url)
    bound = Number(binding?.number) === Number(snapshot.pr) &&
      url.pathname.replace(/^\/+|\/+$/g, '') === `${snapshot.repo}/pull/${snapshot.pr}`
  } catch { /* an unbound receipt cannot authorize a carry */ }
  // The admitted receipt, not this immutable terminal observation, attests
  // that the cycle is now clean: findings may have been settled after capture.
  // The attachment still proves the original reviewed head and corroborated base.
  if (!bound || snapshot.last_reviewed_head !== snapshot.head ||
      !['clean', 'findings'].includes(snapshot.last_reviewed_verdict) ||
      !SHA40.test(snapshot.last_reviewed_base_sha ?? '')) return false
  const matches = (record?.receipts ?? []).filter((receipt) =>
    receipt?.kind === 'pass' && /^integration-r[1-9][0-9]*-integrator$/.test(receipt?.file ?? ''))
    .map((receipt) => readJson(join(common, 'dev-flow-v2', 'runs', runId, 'passes', `${receipt.file}.json`)))
    .filter((pass) => {
      const finder = snapshot?.finder?.slug
      const cycle = finder && finder !== 'codex-cloud'
        ? pass?.payload?.finder_cycles?.find((entry) => entry?.finder === finder)
        : pass?.payload?.codex_cycle
      return pass?.run?.run_id === record?.run_id && pass?.role === 'integrator' &&
        pass?.status === 'completed' && pass?.head === snapshot.head &&
        pass?.payload?.verdict === 'clean' && cycle?.head === snapshot.head &&
        cycle?.exit_code === 0 && Number(cycle?.cycle) === Number(snapshot.charged_cycles) + Number(snapshot.exempt_cycles) &&
        Number(cycle?.attempt) === Number(snapshot.attempt) &&
        String(cycle?.trigger_comment_id) === String(snapshot.trigger_comment_id)
    })
  // Independent completed passes can corroborate exactly the same clean
  // cycle. They are evidence of the same immutable origin, not competing
  // origins; each item already passed the full binding above.
  return matches[0] ?? null
}

function hasOwnerTimeout(state) {
  return Number.isSafeInteger(state?.timeout_min) && state.timeout_min >= 10
}

// Legacy r1 predates owner captures. Its initial, live admission still
// validates the checker itself, so retain this pure compatibility projection.
export function conservativeLegacyControls(state, { allowCarry = false } = {}) {
  if ((!allowCarry && state?.carry) || Number(state?.charged_cycles) !== 1 ||
      Number(state?.exempt_cycles) !== 0 || Number(state?.attempt) !== 1) {
    throw new Error('legacy review evidence cannot prove non-initial cycle counters or carry provenance')
  }
  return { first_trigger_comment_id: 1, requires_full_window: true, timeout_min: 15 }
}

export function retainedReservation(record, state, options, parentDigest) {
  const prior = retainedAuthorities(record, options)
  const reserve = matchingPublicReserve(prior, state, parentDigest)
  if (!reserve) throw new Error('attach authority has no retained matching reserve authority')
  return reserve.authority.snapshot
}

// The first retained attachment is the cycle's immutable owner origin.  It is
// selected by cycle identity rather than globally: later ordinary heads and
// cycles retain their own first request, and current CI settlement may still
// redistribute the charged/exempt pair without changing that identity.
export function retainedCycleOrigin(record, state, options, parentDigest) {
  const origin = matchingPublicCycleOrigin(retainedAuthorities(record, options), state, parentDigest)
  if (!origin) throw new Error('no retained first attachment matches this review cycle origin')
  return origin.authority.snapshot
}

export function retainedCycleOriginEntry(record, state, options, parentDigest) {
  const origin = matchingPublicCycleOrigin(retainedAuthorities(record, options), state, parentDigest)
  if (!origin) throw new Error('no retained first attachment matches this review cycle origin')
  return origin
}

export function retainedRetryReservation(record, state, options, parentDigest) {
  const origin = retainedCycleOriginEntry(record, state, options, parentDigest)
  const candidates = retainedAuthorities(record, options).filter((entry) => entry.kind === 'reserve' &&
    Number(entry.authority.snapshot.attempt) === 2 &&
    samePublicCycle(entry.authority.snapshot, state) &&
    stable(entry.authority.snapshot.finder) === stable(origin.authority.snapshot.finder) &&
    (entry.authority.parent_authority_digest === origin.digest ||
      (entry.authority.parent_authority_digest === undefined &&
       stable(requestControls(entry.authority.snapshot)) === stable(requestControls(state)))) )
  if (candidates.length > 1) throw new Error('retry reservation is ambiguous for the selected retained first request')
  return candidates[0]?.authority.snapshot ?? null
}

export function retainedCarryPredecessor(record, state, options, parentDigest) {
  const predecessor = matchingPublicCarryPredecessor(retainedAuthorities(record, options), state, parentDigest)
  if (!predecessor) throw new Error('no retained carry predecessor matches this review cycle origin')
  const snapshot = predecessor.authority.snapshot
  if (predecessor.kind === 'attach') {
    const receipt = matchingTerminalReceipt(record, snapshot, options)
    if (!receipt) throw new Error('retained carry origin has no matching admitted authenticated terminal receipt')
    // Never alter the retained terminal observation. A matching admitted clean
    // receipt may settle a findings result, so only the ephemeral canonical
    // carry proof receives its clean verdict.
    if (snapshot.last_reviewed_verdict === 'findings') return { ...snapshot, last_reviewed_verdict: 'clean' }
  }
  return snapshot
}

// Replaying an existing carry rechecks that exact immutable ruling. Starting
// again from its attachment would manufacture a different carried_at value.
export function retainedCarryReplay(record, state, options, parentDigest) {
  const prior = retainedAuthorities(record, options)
  // A selector for a new carry names its predecessor, not a carry that does
  // not exist yet.  Replay is therefore an optional lookup; caller falls
  // through to predecessor selection when it names no replay candidate.
  let candidates = authorityFrontiers(prior).filter((entry) => {
    if (entry.kind !== 'carry') return false
    const snapshot = entry.authority.snapshot
    const wanted = state?.carry
    return snapshot.carry?.from_head === wanted?.from_head &&
      snapshot.carry?.attests_head === wanted?.attests_head &&
      Number(snapshot.attempt) === Number(state?.attempt) && samePublicCycle(snapshot, state)
  })
  // A selector always names the immutable *parent*, including on replay.
  // The carried child is matched by its immutable coordinates and retained
  // parent binding; it never becomes a self-parenting selector.
  if (parentDigest !== undefined) {
    candidates = candidates.filter((entry) => entry.authority.parent_authority_digest === parentDigest)
    if (candidates.length === 0) return null
  }
  const replay = uniquePublicParent(candidates, 'retained carry replay')
  return replay?.authority.snapshot ?? null
}

export function validateAuthority(authority, prior = [], record = null, options = null) {
  const { kind, snapshot } = authority ?? {}
  if (!['reserve', 'attach', 'carry'].includes(kind)) throw new Error('unknown integration review authority kind')
  if (!validState(snapshot)) throw new Error('authority snapshot has no complete checker control tuple')
  const previous = authority.previous_authority_digest ?? null
  const expectedPrevious = prior.at(-1)?.digest ?? null
  if (previous !== expectedPrevious) throw new Error('authority is not linked to the immediately preceding retained capture')
  const parentDigest = authority.parent_authority_digest
  if (parentDigest !== undefined && !SHA.test(parentDigest)) throw new Error('authority parent selector is not an immutable authority digest')
  if (kind === 'reserve') {
    if (snapshot.phase !== 'reserved' || snapshot.trigger_comment_id != null) {
      throw new Error('reserve authority must snapshot an un-attached checker reservation')
    }
    if (!hasOwnerTimeout(snapshot)) {
      throw new Error('reserve authority requires an explicit owner timeout of at least 10 minutes')
    }
    if (Number(snapshot.attempt) === 2) {
      const origin = parentDigest === undefined
        ? matchingOriginAttach(prior, snapshot)
        : matchingPublicCycleOrigin(prior, snapshot, parentDigest)
      if (!origin || origin.kind !== 'attach') {
        throw new Error('retry reserve authority does not extend the selected retained first request')
      }
      if (!origin || Number(snapshot.first_trigger_comment_id) !== Number(origin.authority.snapshot.first_trigger_comment_id) ||
          Number(snapshot.timeout_min) !== Number(origin.authority.snapshot.timeout_min) ||
          stable(snapshot.finder) !== stable(origin.authority.snapshot.finder)) {
        throw new Error('retry reserve authority does not preserve the retained first-request controls')
      }
    }
    return
  }
  if (kind === 'attach') {
    const requestedReviewer = snapshot?.finder?.trigger_mechanism === 'requested-reviewer'
    const attachedRequest = requestedReviewer
      ? snapshot.trigger_comment_id == null && typeof snapshot.requested_at === 'string' &&
        typeof snapshot.first_requested_at === 'string'
      : POSITIVE.test(String(snapshot.trigger_comment_id ?? ''))
    if (snapshot.phase !== 'attached' || !attachedRequest) {
      throw new Error('attach authority must snapshot an attached trigger')
    }
    const reserve = parentDigest === undefined
      ? matchingReserve(prior, snapshot)
      : matchingPublicReserve(prior, snapshot, parentDigest)
    if (!reserve || snapshot.carry != null ||
        stable(reservationControls(reserve.authority.snapshot)) !== stable(reservationControls(snapshot)))
      throw new Error('attach authority does not preserve the retained reservation controls')
    const priorFirst = reserve.authority.snapshot.first_trigger_comment_id
    if (priorFirst != null && Number(snapshot.first_trigger_comment_id) !== Number(priorFirst))
      throw new Error('attach authority rewrites the retained first-request identity')
    if (Number(snapshot.attempt) === 2) {
      const origin = matchingOriginAttach(prior, snapshot)
      if (!origin || Number(snapshot.first_trigger_comment_id) !== Number(origin.authority.snapshot.first_trigger_comment_id) ||
          Number(snapshot.timeout_min) !== Number(origin.authority.snapshot.timeout_min) ||
          stable(snapshot.finder) !== stable(origin.authority.snapshot.finder) ||
          (requestedReviewer && snapshot.first_requested_at !== origin.authority.snapshot.first_requested_at)) {
        throw new Error('retry attach authority does not preserve the retained first-request controls')
      }
    }
    return
  }
  const carry = snapshot.carry
  if (!carry || !SHA40.test(carry.from_head ?? '') || !SHA40.test(carry.attests_head ?? '')) {
    throw new Error('carry authority has no complete origin/attested-head proof')
  }
  const predecessor = parentDigest === undefined
    ? matchingCarryPredecessor(prior, snapshot)
    : matchingPublicCarryPredecessor(prior, snapshot, parentDigest)
  if (!predecessor) {
    throw new Error('carry authority has no retained origin or immediate predecessor authority')
  }
  if (predecessor && stable(requestControls(predecessor.authority.snapshot)) !== stable(requestControls(snapshot))) {
    throw new Error('carry authority does not preserve the retained predecessor request controls')
  }
}

// Select the current retained authority for the run's bound PR before looking
// at an envelope's claimed cycle coordinates. Callers that need the current
// request authority must use this frontier instead of treating a missing
// attachment as proof that no request was made: reserve is captured before the
// trigger, while an attachment can be retained only after a later observation.
export function currentAuthorityForBinding(record, options, finder) {
  const retained = retainedAuthorities(record, options)
  if (retained.length === 0) {
    const hasCapture = (record?.interventions ?? []).some((entry) =>
      typeof entry?.note === 'string' && entry.note.startsWith(AUTHORITY_NOTE_PREFIX))
    if (!hasCapture) return null
    throw new Error('no retained owner authority is available for the run’s trusted PR binding')
  }
  // The run binds one PR at a time. Select its current immutable frontier
  // before reading caller-supplied envelope coordinates so a historical clean
  // receipt cannot be made current by selecting old attempt/trigger fields.
  const binding = record?.pr_bindings?.at(-1)
  let boundRepo = null
  let boundPr = null
  try {
    const url = new URL(binding?.url)
    const pieces = url.pathname.replace(/^\/+|\/+$/g, '').split('/')
    if (pieces.length === 4 && pieces[2] === 'pull' && Number(binding?.number) === Number(pieces[3])) {
      boundRepo = pieces.slice(0, 2).join('/')
      boundPr = Number(binding.number)
    }
  } catch { /* no trusted PR binding means no current authority */ }
  const applicable = retained.filter((entry) =>
    boundRepo !== null && entry.authority.snapshot.repo === boundRepo &&
    Number(entry.authority.snapshot.pr) === boundPr)
  const requestedIdentity = finder === undefined ? undefined : chronologyIdentity({ finder: typeof finder === 'string' ? { slug: finder } : finder })
  const identities = new Set(applicable.map((entry) => chronologyIdentity(entry.authority.snapshot)))
  if (requestedIdentity === undefined && identities.size > 1) {
    throw new Error('current authority binding needs an immutable finder identity')
  }
  // Named and historical finder-null Codex captures form one admission
  // chronology. Selecting the named partition first could revive an older
  // request after a newer legacy capture. Profile compatibility is still
  // authenticated against the trusted registry at receipt admission.
  const codex = requestedIdentity === 'finder:codex-cloud'
  const selected = applicable.filter((entry) => requestedIdentity === undefined ||
    chronologyIdentity(entry.authority.snapshot) === requestedIdentity).at(-1)
  // An unrelated finder's history cannot disable conservative original-head
  // legacy admission. retainedAuthorities has already validated the complete
  // chain, so damaged captures still refuse before this fallback is reached.
  if (!selected && codex) return null
  if (!selected) throw new Error('no retained owner authority applies to the run’s trusted PR binding')
  return selected
}

export function authorityForFinderCycle(record, envelope, finder, cycle, options) {
  if (!cycle) return null
  const selected = currentAuthorityForBinding(record, options, finder)
  if (!selected) return null
  const state = selected.authority.snapshot
  const attested = selected.authority.snapshot.carry?.attests_head ?? selected.authority.snapshot.head
  const requestMatches = state.trigger_comment_id == null
    ? cycle.trigger_comment_id == null
    : String(cycle.trigger_comment_id) === String(state.trigger_comment_id)
  if (attested !== envelope.head ||
      Number(cycle.cycle) !== Number(state.charged_cycles) + Number(state.exempt_cycles) ||
      Number(cycle.attempt) !== Number(state.attempt) ||
      !requestMatches) {
    throw new Error('claimed review cycle does not match the current retained owner authority')
  }
  return selected
}

export function authorityForEnvelope(record, envelope, options) {
  return authorityForFinderCycle(record, envelope, 'codex-cloud', envelope?.payload?.codex_cycle, options)
}
