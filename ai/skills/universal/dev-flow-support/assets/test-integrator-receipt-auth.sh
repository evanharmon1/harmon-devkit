#!/usr/bin/env bash
# Focused proofs for the owner-retained integration review authority boundary.
set -euo pipefail

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/integrator-receipt-auth.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

ASSET="$asset_dir/lib/integrator-receipt-auth.mjs" AUTHORITY="$asset_dir/lib/integrator-review-authority.mjs" AUTH_UNIT_DIR="$tmp" node --input-type=module <<'NODE'
import assert from 'node:assert/strict'
import { chmodSync, mkdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const { passAttestsCheckerCycle, trustedSettlements } = await import(pathToFileURL(process.env.ASSET).href)
const { authorityForEnvelope, authorityIdentity, authorityNote, conservativeLegacyControls, digestBytes, retainedAuthorities, retainedCarryPredecessor, retainedCarryReplay, retainedCycleOrigin, retainedReservation, retainedRetryReservation, validateAuthority } = await import(pathToFileURL(process.env.AUTHORITY).href)
const h1 = 'a'.repeat(40), h2 = 'b'.repeat(40), h3 = 'c'.repeat(40)
const common = join(process.env.AUTH_UNIT_DIR, 'common')
const runId = 'run', runRoot = join(common, 'dev-flow-v2', 'runs', runId)
mkdirSync(join(runRoot, 'rulings'), { recursive: true })
const finder = { slug: 'codex-cloud', actor_id: '199175422', clean_verdict: 'clean' }
const state = { repo: 'example/repo', pr: 1, head: h1, phase: 'attached', trigger_comment_id: '200', first_trigger_comment_id: '200', requested_at: '2026-01-01T00:01:00Z', timeout_min: 15, charged_cycles: 1, exempt_cycles: 0, attempt: 1, finder }
const terminalState = { ...state, last_reviewed_head: h1, last_reviewed_base_sha: 'd'.repeat(40), last_reviewed_verdict: 'clean' }
const reserve = { schema: 1, kind: 'reserve', captured_at: '2026-01-01T00:00:00Z', previous_authority_digest: null,
  snapshot: { ...state, phase: 'reserved', trigger_comment_id: null, first_trigger_comment_id: null, requested_at: null } }
const reserveBytes = Buffer.from(`${JSON.stringify(reserve)}\n`), reserveDigest = digestBytes(reserveBytes)
writeFileSync(join(runRoot, 'rulings', reserveDigest), reserveBytes)
const attach = { schema: 1, kind: 'attach', captured_at: '2026-01-01T00:01:00Z', previous_authority_digest: reserveDigest, snapshot: terminalState }
const terminalAttachBytes = Buffer.from(`${JSON.stringify(attach)}\n`), terminalAttachDigest = digestBytes(terminalAttachBytes)
writeFileSync(join(runRoot, 'rulings', terminalAttachDigest), terminalAttachBytes)
const carry2 = { schema: 1, kind: 'carry', captured_at: '2026-01-01T00:02:00Z', previous_authority_digest: terminalAttachDigest,
  parent_authority_digest: terminalAttachDigest, snapshot: { ...terminalState, carry: { from_head: h1, attests_head: h2 } } }
const terminalCarry2Bytes = Buffer.from(`${JSON.stringify(carry2)}\n`), terminalCarry2Digest = digestBytes(terminalCarry2Bytes)
writeFileSync(join(runRoot, 'rulings', terminalCarry2Digest), terminalCarry2Bytes)
const carry3 = { schema: 1, kind: 'carry', captured_at: '2026-01-01T00:03:00Z', previous_authority_digest: terminalCarry2Digest,
  parent_authority_digest: terminalCarry2Digest, snapshot: { ...terminalState, carry: { from_head: h2, attests_head: h3 } } }
const terminalCarry3Bytes = Buffer.from(`${JSON.stringify(carry3)}\n`), terminalCarry3Digest = digestBytes(terminalCarry3Bytes)
writeFileSync(join(runRoot, 'rulings', terminalCarry3Digest), terminalCarry3Bytes)
const note = (kind, digest) => `${authorityNote(kind, digest)} [ruling dev-flow-v2/runs/${runId}/rulings/${digest} sha256=${digest}]`
const record = {
  interventions: [
  { kind: 'other', note: note('reserve', reserveDigest) }, { kind: 'other', note: note('attach', terminalAttachDigest) },
  { kind: 'other', note: note('carry', terminalCarry2Digest) }, { kind: 'other', note: note('carry', terminalCarry3Digest) },
  ],
  run_id: runId,
  pr_bindings: [{ number: 1, url: 'https://github.com/example/repo/pull/1' }],
  receipts: [{ kind: 'pass', file: 'integration-r1-integrator' }],
}
const initialRecord = { ...record, interventions: record.interventions.slice(0, 2) }
mkdirSync(join(runRoot, 'passes'), { recursive: true })
writeFileSync(join(runRoot, 'passes', 'integration-r1-integrator.json'), JSON.stringify({
  run: { run_id: runId }, role: 'integrator', status: 'completed', head: h1,
  payload: { verdict: 'clean', codex_cycle: { head: h1, exit_code: 0, cycle: 1, attempt: 1, trigger_comment_id: '200' } },
}))
const envelope = { head: h1, payload: { codex_cycle: { cycle: 1, attempt: 1, trigger_comment_id: '200' } } }
assert.equal(authorityForEnvelope({ interventions: [] }, envelope, { common, runId }), null)
assert.equal(retainedAuthorities(record, { common, runId }).length, 4)
assert.equal(authorityForEnvelope(initialRecord, envelope, { common, runId }).digest, terminalAttachDigest)
const poisonedAttachReport = { ...terminalState, finder: { slug: 'foreign' }, run_id: 'foreign-run',
  reserved_at: '1999-01-01T00:00:00Z', timeout_min: 1, carry: { from_head: 'f'.repeat(40), attests_head: 'e'.repeat(40) } }
assert.equal(retainedReservation(initialRecord, poisonedAttachReport, { common, runId }).finder.slug, 'codex-cloud')
assert.equal(retainedCycleOrigin(initialRecord, { ...poisonedAttachReport, attempt: 2, finder: undefined }, { common, runId }).finder.slug, 'codex-cloud')

// Independent finders can reserve the same PR/head/cycle/attempt coordinates.
// Their durable chains may interleave, but another finder's later attachment
// must never supersede the Codex authority that this receipt authenticates.
const otherFinder = { slug: 'other-reviewer', actor_id: '42', clean_verdict: 'clean' }
const otherReserve = { schema: 1, kind: 'reserve', captured_at: '2026-01-01T00:01:30Z', previous_authority_digest: terminalAttachDigest,
  snapshot: { ...state, finder: otherFinder, phase: 'reserved', trigger_comment_id: null, first_trigger_comment_id: null, requested_at: null } }
const otherReserveBytes = Buffer.from(`${JSON.stringify(otherReserve)}\n`), otherReserveDigest = digestBytes(otherReserveBytes)
writeFileSync(join(runRoot, 'rulings', otherReserveDigest), otherReserveBytes)
const otherAttach = { schema: 1, kind: 'attach', captured_at: '2026-01-01T00:01:45Z', previous_authority_digest: otherReserveDigest,
  snapshot: { ...terminalState, finder: otherFinder, trigger_comment_id: '300', first_trigger_comment_id: '300' } }
const otherAttachBytes = Buffer.from(`${JSON.stringify(otherAttach)}\n`), otherAttachDigest = digestBytes(otherAttachBytes)
writeFileSync(join(runRoot, 'rulings', otherAttachDigest), otherAttachBytes)
const interleavedRecord = { ...initialRecord, interventions: [...initialRecord.interventions,
  { kind: 'other', note: note('reserve', otherReserveDigest) }, { kind: 'other', note: note('attach', otherAttachDigest) },
] }
assert.equal(authorityForEnvelope(interleavedRecord, envelope, { common, runId }).digest, terminalAttachDigest)
assert.throws(() => retainedReservation(interleavedRecord, poisonedAttachReport, { common, runId }), /ambiguous across retained finder authorities/)
assert.throws(() => retainedCycleOrigin(interleavedRecord, { ...poisonedAttachReport, attempt: 2, finder: undefined }, { common, runId }), /ambiguous across retained finder authorities/)
// Public coordinates alone remain ambiguous. A new capture can name one
// immutable retained ruling, while preserving the selected request controls.
assert.equal(retainedReservation(interleavedRecord, poisonedAttachReport, { common, runId }, reserveDigest).finder.slug, 'codex-cloud')
assert.equal(retainedReservation(interleavedRecord, poisonedAttachReport, { common, runId }, otherReserveDigest).finder.slug, 'other-reviewer')
const serialOtherAttach = { ...otherAttach, parent_authority_digest: otherReserveDigest }
const serialPrior = retainedAuthorities({ ...initialRecord, interventions: [...initialRecord.interventions, { kind: 'other', note: note('reserve', otherReserveDigest) }] }, { common, runId })
assert.doesNotThrow(() => validateAuthority(serialOtherAttach, serialPrior, interleavedRecord, { common, runId }))
// A selector disambiguates the retained parent; it must not manufacture a
// second immutable attachment for the same owner request.
assert.equal(authorityIdentity(otherAttach), authorityIdentity(serialOtherAttach))
assert.throws(() => validateAuthority({ ...serialOtherAttach, parent_authority_digest: reserveDigest }, serialPrior, interleavedRecord, { common, runId }), /reservation controls/)
assert.throws(() => validateAuthority({ ...serialOtherAttach, parent_authority_digest: 'f'.repeat(64) }, serialPrior, interleavedRecord, { common, runId }), /selector does not name/)

// Named and legacy Codex captures share one chronological admission frontier.
function appendCapturePair(source, profile, head, trigger, cycle = 1) {
  const history = retainedAuthorities(source, { common, runId })
  const reservation = { ...reserve, previous_authority_digest: history.at(-1)?.digest ?? null,
    snapshot: { ...reserve.snapshot, finder: profile, head, charged_cycles: cycle } }
  const bytes = Buffer.from(JSON.stringify(reservation)), digest = digestBytes(bytes)
  writeFileSync(join(runRoot, 'rulings', digest), bytes)
  const attachment = { ...attach, previous_authority_digest: digest,
    snapshot: { ...terminalState, finder: profile, head, charged_cycles: cycle, last_reviewed_head: head,
      trigger_comment_id: trigger, first_trigger_comment_id: trigger } }
  const attachedBytes = Buffer.from(JSON.stringify(attachment)), attachedDigest = digestBytes(attachedBytes)
  writeFileSync(join(runRoot, 'rulings', attachedDigest), attachedBytes)
  return { ...source, interventions: [...source.interventions,
    { note: note('reserve', digest) }, { note: note('attach', attachedDigest) }] }
}
const emptyHistory = { ...initialRecord, interventions: [] }
for (const profiles of [[finder, null], [null, finder]]) {
  const older = appendCapturePair(emptyHistory, profiles[0], h1, '200')
  const newer = appendCapturePair(older, profiles[1], h2, '400')
  assert.equal(authorityForEnvelope(newer, { head: h2, payload: { codex_cycle: {
    cycle: 1, attempt: 1, trigger_comment_id: '400' } } }, { common, runId }).authority.snapshot.head, h2)
  assert.throws(() => authorityForEnvelope(newer, envelope, { common, runId }), /current retained owner authority/)
}
// A named/legacy switch cannot revive an older same-head cycle through a
// retry, attachment replay, or carry selector. Exercise both history orders;
// the immutable identity/digest of each capture remains unchanged.
const transitionRejections = []
function refusedTransition(label, action, pattern) {
  try { action() } catch (error) {
    assert.match(error.message, pattern)
    transitionRejections.push({ label, refused: true })
    return
  }
  transitionRejections.push({ label, refused: false })
}
for (const profiles of [[finder, null], [null, finder]]) {
  const order = profiles[0] ? 'named-legacy' : 'legacy-named'
  const older = appendCapturePair(emptyHistory, profiles[0], h1, '200')
  const newer = appendCapturePair(older, profiles[1], h1, '400', 2)
  const history = retainedAuthorities(newer, { common, runId })
  const oldOrigin = history[1], current = history.at(-1)
  const retry = (origin) => ({ schema: 1, kind: 'reserve',
    previous_authority_digest: current.digest,
    snapshot: { ...origin.authority.snapshot, phase: 'reserved', attempt: 2,
      trigger_comment_id: null, requested_at: null } })
  const carry = (origin) => ({ schema: 1, kind: 'carry',
    previous_authority_digest: current.digest,
    snapshot: { ...origin.authority.snapshot, carry: { from_head: h1, attests_head: h2 } } })
  for (const selected of [false, true]) {
    const staleRetry = retry(oldOrigin), currentRetry = retry(current)
    const staleCarry = carry(oldOrigin), currentCarry = carry(current)
    if (selected) {
      staleRetry.parent_authority_digest = staleCarry.parent_authority_digest = oldOrigin.digest
      currentRetry.parent_authority_digest = currentCarry.parent_authority_digest = current.digest
    }
    refusedTransition(`${order} stale retry selected=${selected}`,
      () => validateAuthority(staleRetry, history, newer, { common, runId }), /current cycle frontier/)
    refusedTransition(`${order} stale carry selected=${selected}`,
      () => validateAuthority(staleCarry, history, newer, { common, runId }), /selector does not name|origin or immediate predecessor/)
    assert.doesNotThrow(() => validateAuthority(currentRetry, history, newer, { common, runId }))
    assert.doesNotThrow(() => validateAuthority(currentCarry, history, newer, { common, runId }))
  }
  refusedTransition(`${order} stale reservation replay`,
    () => retainedReservation(newer, oldOrigin.authority.snapshot, { common, runId }, history[0].digest), /selector does not name/)
  refusedTransition(`${order} stale public carry`,
    () => retainedCarryPredecessor(newer, carry(oldOrigin).snapshot, { common, runId }, oldOrigin.digest), /selector does not name/)
  assert.deepEqual(retainedReservation(newer, current.authority.snapshot, { common, runId }, history[2].digest), history[2].authority.snapshot)
  assert.equal(authorityForEnvelope(newer, { head: h1, payload: { codex_cycle: {
    cycle: 2, attempt: 1, trigger_comment_id: '400' } } }, { common, runId }).digest, current.digest)
  assert.equal(authorityIdentity(history[1].authority), authorityIdentity(retainedAuthorities(older, { common, runId })[1].authority))
}
assert.deepEqual(transitionRejections, transitionRejections.map((entry) => ({ ...entry, refused: true })))
console.log('both named/legacy chronology orders refuse stale transitions and allow the current cycle')
const unrelatedOnly = appendCapturePair(emptyHistory, otherFinder, h2, '300')
assert.equal(authorityForEnvelope(unrelatedOnly, envelope, { common, runId }), null)
assert.throws(() => authorityForEnvelope({ ...unrelatedOnly, interventions: [
  ...unrelatedOnly.interventions, { note: 'integration-review-authority v1 damaged' }
] }, envelope, { common, runId }), /malformed/)
assert.doesNotThrow(() => conservativeLegacyControls(state))
for (const changes of [{ charged_cycles: 2 }, { exempt_cycles: 1 }, { attempt: 2 },
  { carry: { from_head: h1, attests_head: h2 } }]) {
  assert.throws(() => conservativeLegacyControls({ ...state, ...changes }), /legacy review evidence/)
}
console.log('mixed named/legacy Codex chronology and unrelated-finder fallback OK')

// Both independent reservations can exist before either attachment. Each
// attachment names its retained parent; a cross-finder selection is refused.
const concurrentOtherReserve = { ...otherReserve, previous_authority_digest: reserveDigest }
const concurrentOtherReserveBytes = Buffer.from(`${JSON.stringify(concurrentOtherReserve)}\n`)
const concurrentOtherReserveDigest = digestBytes(concurrentOtherReserveBytes)
writeFileSync(join(runRoot, 'rulings', concurrentOtherReserveDigest), concurrentOtherReserveBytes)
const concurrentPrior = [{ kind: 'reserve', digest: reserveDigest, authority: reserve }, { kind: 'reserve', digest: concurrentOtherReserveDigest, authority: concurrentOtherReserve }]
const concurrentCodexAttach = { ...attach, previous_authority_digest: concurrentOtherReserveDigest, parent_authority_digest: reserveDigest }
assert.doesNotThrow(() => validateAuthority(concurrentCodexAttach, concurrentPrior, record, { common, runId }))
const concurrentOtherAttach = { ...otherAttach, previous_authority_digest: concurrentOtherReserveDigest, parent_authority_digest: concurrentOtherReserveDigest }
assert.doesNotThrow(() => validateAuthority(concurrentOtherAttach, concurrentPrior, record, { common, runId }))
assert.throws(() => validateAuthority({ ...concurrentCodexAttach, parent_authority_digest: concurrentOtherReserveDigest }, concurrentPrior, record, { common, runId }), /reservation controls/)
const interleavedCodexRetry = { schema: 1, kind: 'reserve', captured_at: '2026-01-01T00:02:00Z', previous_authority_digest: otherAttachDigest,
  snapshot: { ...state, phase: 'reserved', attempt: 2, trigger_comment_id: null, requested_at: null } }
assert.doesNotThrow(() => validateAuthority(interleavedCodexRetry, retainedAuthorities(interleavedRecord, { common, runId }), interleavedRecord, { common, runId }))
const interleavedCodexRetryBytes = Buffer.from(`${JSON.stringify(interleavedCodexRetry)}\n`), interleavedCodexRetryDigest = digestBytes(interleavedCodexRetryBytes)
writeFileSync(join(runRoot, 'rulings', interleavedCodexRetryDigest), interleavedCodexRetryBytes)
const afterCodexRetry = { ...interleavedRecord, interventions: [...interleavedRecord.interventions, { kind: 'other', note: note('reserve', interleavedCodexRetryDigest) }] }
const otherRetrySource = { ...interleavedCodexRetry.snapshot, finder: otherFinder, first_trigger_comment_id: '300' }
assert.equal(retainedRetryReservation(afterCodexRetry, otherRetrySource, { common, runId }, otherAttachDigest), null)
const selectedOtherRetry = { ...interleavedCodexRetry, previous_authority_digest: interleavedCodexRetryDigest, parent_authority_digest: otherAttachDigest,
  snapshot: { ...interleavedCodexRetry.snapshot, finder: otherFinder, first_trigger_comment_id: '300' } }
const selectedOtherRetryBytes = Buffer.from(`${JSON.stringify(selectedOtherRetry)}\n`), selectedOtherRetryDigest = digestBytes(selectedOtherRetryBytes)
writeFileSync(join(runRoot, 'rulings', selectedOtherRetryDigest), selectedOtherRetryBytes)
const selectedRetryRecord = { ...afterCodexRetry, interventions: [...afterCodexRetry.interventions, { kind: 'other', note: note('reserve', selectedOtherRetryDigest) }] }
const selectedOtherSource = { ...selectedOtherRetry.snapshot }
assert.equal(retainedRetryReservation(selectedRetryRecord, selectedOtherSource, { common, runId }, otherAttachDigest).finder.slug, 'other-reviewer')
assert.equal(retainedRetryReservation(selectedRetryRecord, selectedOtherSource, { common, runId }, otherAttachDigest).attempt, 2)
assert.throws(() => authorityForEnvelope(record, { ...envelope, head: 'd'.repeat(40) }, { common, runId }), /current retained owner authority/)
assert.equal(authorityForEnvelope(record, { ...envelope, head: h3 }, { common, runId }).digest, terminalCarry3Digest)
assert.throws(() => authorityForEnvelope(record, envelope, { common, runId }), /current retained owner authority/)
assert.equal(retainedAuthorities({ ...record, interventions: [...record.interventions, { note: 'ordinary intervention prose' }] }, { common, runId }).length, 4)
assert.throws(() => retainedAuthorities({ ...record, interventions: [...record.interventions, { note: 'integration-review-authority v1 damaged' }] }, { common, runId }), /recognized retained authority intervention is malformed/)
const terminalCarry3Path = join(runRoot, 'rulings', terminalCarry3Digest)
unlinkSync(terminalCarry3Path)
assert.throws(() => retainedAuthorities(record, { common, runId }), /recognized retained authority ruling is missing/)
assert.throws(() => authorityForEnvelope(record, { ...envelope, head: h3 }, { common, runId }), /recognized retained authority ruling is missing/)
writeFileSync(terminalCarry3Path, terminalCarry3Bytes)
writeFileSync(terminalCarry3Path, Buffer.from('tampered'))
assert.throws(() => retainedAuthorities(record, { common, runId }), /ruling digest does not match/)
writeFileSync(terminalCarry3Path, terminalCarry3Bytes)
const badSchema = { ...carry3, schema: 2 }
const badSchemaBytes = Buffer.from(`${JSON.stringify(badSchema)}\n`), badSchemaDigest = digestBytes(badSchemaBytes)
writeFileSync(join(runRoot, 'rulings', badSchemaDigest), badSchemaBytes)
const badSchemaRecord = { ...record, interventions: [...record.interventions.slice(0, 3), { note: note('carry', badSchemaDigest) }] }
assert.throws(() => retainedAuthorities(badSchemaRecord, { common, runId }), /invalid schema or snapshot/)
const invalidCarry = { ...carry3, snapshot: { ...carry3.snapshot, carry: { from_head: h1, attests_head: h3 } } }
const invalidCarryBytes = Buffer.from(`${JSON.stringify(invalidCarry)}\n`), invalidCarryDigest = digestBytes(invalidCarryBytes)
writeFileSync(join(runRoot, 'rulings', invalidCarryDigest), invalidCarryBytes)
const invalidCarryRecord = { ...record, interventions: [...record.interventions.slice(0, 3), { note: note('carry', invalidCarryDigest) }] }
assert.throws(() => retainedAuthorities(invalidCarryRecord, { common, runId }), /ruling is invalid/)
assert.equal(retainedCarryReplay(record, carry2.snapshot, { common, runId }), null)
assert.equal(retainedCarryReplay(record, carry3.snapshot, { common, runId })?.carry?.attests_head, h3)
assert.throws(() => retainedCarryPredecessor(record, carry2.snapshot, { common, runId }), /retained carry predecessor/)
assert.equal(retainedCarryPredecessor(initialRecord, carry2.snapshot, { common, runId }, terminalAttachDigest).head, h1)
assert.equal(retainedCarryReplay(record, carry3.snapshot, { common, runId }, terminalCarry2Digest)?.carry?.attests_head, h3)
assert.equal(retainedCarryReplay(record, carry3.snapshot, { common, runId }, terminalCarry3Digest), null)
const poisonedCarryReport = { ...carry3.snapshot, finder: { slug: 'foreign' }, run_id: 'foreign-run',
  reserved_at: '1999-01-01T00:00:00Z', timeout_min: 1 }
assert.equal(retainedCarryReplay(record, poisonedCarryReport, { common, runId })?.carry?.attests_head, h3)
assert.equal(retainedCarryPredecessor(record, { ...poisonedCarryReport,
  carry: { from_head: h3, attests_head: 'e'.repeat(40) } }, { common, runId }).carry?.attests_head, h3)
writeFileSync(join(runRoot, 'passes', 'integration-r1-integrator.json'), JSON.stringify({
  run: { run_id: runId }, role: 'integrator', status: 'completed', head: h1,
  payload: { verdict: 'clean', codex_cycle: { head: h1, exit_code: 0, cycle: 1, attempt: 2, trigger_comment_id: '200' } },
}))
assert.throws(() => retainedCarryPredecessor(initialRecord, carry2.snapshot, { common, runId }), /matching admitted authenticated terminal receipt/)
writeFileSync(join(runRoot, 'passes', 'integration-r1-integrator.json'), JSON.stringify({
  run: { run_id: runId }, role: 'integrator', status: 'completed', head: h1,
  payload: { verdict: 'clean', codex_cycle: { head: h1, exit_code: 0, cycle: 1, attempt: 1, trigger_comment_id: '200' } },
}))
const findingsAttach = { ...attach, snapshot: { ...terminalState, last_reviewed_verdict: 'findings' } }
const findingsBytes = Buffer.from(JSON.stringify(findingsAttach) + '\n'), findingsDigest = digestBytes(findingsBytes)
writeFileSync(join(runRoot, 'rulings', findingsDigest), findingsBytes)
const findingsRecord = { ...record, interventions: [
  { kind: 'other', note: note('reserve', reserveDigest) }, { kind: 'other', note: note('attach', findingsDigest) },
] }
const findingsCarryScratch = retainedCarryPredecessor(findingsRecord,
  { ...carry2.snapshot, last_reviewed_verdict: 'findings' }, { common, runId })
assert.equal(findingsCarryScratch.last_reviewed_verdict, 'clean')
const retainedFindings = retainedAuthorities(findingsRecord, { common, runId })
  .find((entry) => entry.kind === 'attach').authority.snapshot
assert.equal(retainedFindings.last_reviewed_verdict, 'findings')
assert.equal(retainedFindings.last_reviewed_base_sha, terminalState.last_reviewed_base_sha)
assert.deepEqual(retainedFindings.finder, terminalState.finder)
writeFileSync(join(runRoot, 'passes', 'integration-r2-integrator.json'), JSON.stringify({
  run: { run_id: runId }, role: 'integrator', status: 'completed', head: h1,
  payload: { verdict: 'clean', codex_cycle: { head: h1, exit_code: 0, cycle: 1, attempt: 1, trigger_comment_id: '200' } },
}))
const corroboratingRecord = { ...initialRecord, receipts: [
  { kind: 'pass', file: 'integration-r1-integrator' }, { kind: 'pass', file: 'integration-r2-integrator' },
] }
assert.equal(retainedCarryPredecessor(corroboratingRecord, carry2.snapshot, { common, runId }).head, h1)
assert.doesNotThrow(() => validateAuthority({ ...carry2, snapshot: { ...carry2.snapshot, charged_cycles: 0, exempt_cycles: 1 } },
  [{ kind: 'reserve', digest: reserveDigest, authority: reserve }, { kind: 'attach', digest: terminalAttachDigest, authority: attach }], record, { common, runId }))
assert.throws(() => validateAuthority({ ...carry2, snapshot: { ...carry2.snapshot, first_trigger_comment_id: '50' } },
  [{ kind: 'reserve', digest: reserveDigest, authority: reserve }, { kind: 'attach', digest: terminalAttachDigest, authority: attach }], record, { common, runId }), /predecessor request controls/)
assert.throws(() => validateAuthority({ ...carry2, snapshot: { ...carry2.snapshot, requested_at: '2025-12-31T23:00:00Z' } },
  [{ kind: 'reserve', digest: reserveDigest, authority: reserve }, { kind: 'attach', digest: terminalAttachDigest, authority: attach }], record, { common, runId }), /predecessor request controls/)
assert.equal(passAttestsCheckerCycle({ head: h2, payload: { codex_cycle: { carried: { origin_head: h1, attests_head: h2 } } } },
  { head: h1, carry: { attests_head: h3 } }), true)
assert.equal(passAttestsCheckerCycle({ head: h2, payload: { codex_cycle: { carried: { origin_head: h1, attests_head: h3 } } } },
  { head: h1 }), false)

// An old head-bound receipt remains admission evidence, but it cannot create
// a first carry without an owner-retained request/base capture.
const legacyCarry = { schema: 1, kind: 'carry', captured_at: '2026-01-01T00:00:00Z', previous_authority_digest: null,
  snapshot: { ...state, carry: { from_head: h1, attests_head: h2 } } }
assert.throws(() => validateAuthority(legacyCarry, [], { interventions: [] }, { common, runId }), /origin or immediate predecessor/)
const retryReserve = { schema: 1, kind: 'reserve', captured_at: '2026-01-01T00:02:00Z', previous_authority_digest: terminalAttachDigest,
  snapshot: { ...state, phase: 'reserved', attempt: 2, trigger_comment_id: null, requested_at: null } }
const retryPrior = [{ kind: 'reserve', digest: reserveDigest, authority: reserve }, { kind: 'attach', digest: terminalAttachDigest, authority: attach }]
assert.doesNotThrow(() => validateAuthority(retryReserve, retryPrior, record, { common, runId }))
assert.throws(() => validateAuthority({ ...retryReserve, snapshot: { ...retryReserve.snapshot, first_trigger_comment_id: '50' } }, retryPrior, record, { common, runId }), /retained first-request controls/)
assert.throws(() => validateAuthority({ ...retryReserve, snapshot: { ...retryReserve.snapshot, finder: { ...finder, clean_verdict: 'drifted' } } }, retryPrior, record, { common, runId }), /retry reserve authority/)
// A historical origin supports a same-cycle retry, but cannot revive it after
// the same finder has advanced to a later cycle.
const advancedReserve = { schema: 1, kind: 'reserve', captured_at: '2026-01-01T00:03:00Z', previous_authority_digest: terminalAttachDigest,
  snapshot: { ...reserve.snapshot, charged_cycles: 2 } }
const advancedPrior = [...retryPrior, { kind: 'reserve', digest: 'e'.repeat(64), authority: advancedReserve }]
assert.throws(() => validateAuthority({ ...retryReserve, previous_authority_digest: 'e'.repeat(64) }, advancedPrior, record, { common, runId }), /current cycle frontier/)

const requestedFinder = { slug: 'copilot-cloud', actor_id: '175728472', trigger_mechanism: 'requested-reviewer' }
const requestedReserve = { ...reserve, snapshot: { ...reserve.snapshot, finder: requestedFinder } }
const requestedReserveDigest = digestBytes(Buffer.from(`${JSON.stringify(requestedReserve)}\n`))
const requestedAttach = { ...attach, previous_authority_digest: requestedReserveDigest,
  snapshot: { ...terminalState, finder: requestedFinder, trigger_comment_id: null, first_trigger_comment_id: null,
    requested_at: '2026-01-01T00:01:00Z', first_requested_at: '2026-01-01T00:01:00Z' } }
assert.doesNotThrow(() => validateAuthority(requestedAttach, [{ kind: 'reserve', digest: requestedReserveDigest, authority: requestedReserve }], null, { common, runId }))
assert.throws(() => validateAuthority({ ...requestedAttach, snapshot: { ...requestedAttach.snapshot, first_requested_at: null } }, [{ kind: 'reserve', digest: requestedReserveDigest, authority: requestedReserve }], null, { common, runId }), /attached trigger/)

// These two distinct, equal-length JSON bodies have the same POSIX cksum:
// 2635492108-38. A caller-writable checker state carrying that checksum must
// not let an adjudication of the first body settle the live second body.
const collisionA = 'review body e94d71764d5f3e558c523e6a'
const collisionB = 'review body 2153b23429bc42dafa7a0b9d'
const ghBin = join(process.env.AUTH_UNIT_DIR, 'gh-bin')
mkdirSync(ghBin, { recursive: true })
const ghStub = join(ghBin, 'gh')
writeFileSync(ghStub, `#!/usr/bin/env node\nconsole.log(JSON.stringify({id:77,body:process.env.AUTH_LIVE_BODY,user:{id:Number(process.env.AUTH_LIVE_ACTOR ?? 199175422)},issue_url:'https://api.github.com/repos/example/repo/issues/1'}))\n`)
chmodSync(ghStub, 0o755)
process.env.PATH = `${ghBin}:${process.env.PATH}`
mkdirSync(join(runRoot, 'adjudications'), { recursive: true })
writeFileSync(join(runRoot, 'passes', 'integration-r9-integrator.json'), JSON.stringify({
  run: { run_id: runId }, role: 'integrator', status: 'completed', head: h1,
  payload: { findings: [{ id: 'integration-r9-codex-cloud-1', source_id: '77', body: collisionA }] },
}))
writeFileSync(join(runRoot, 'adjudications', 'integration-r9.json'), JSON.stringify({
  run_id: runId, stage: 'integration', round: 9, reviewed_head: h1,
  adjudications: [{ finding_id: 'integration-r9-codex-cloud-1', disposition: 'decline' }],
}))
const collisionRecord = { run_id: runId, receipts: [{ kind: 'pass', file: 'integration-r9-integrator' }], settlements: [] }
const collisionState = { repo: 'example/repo', pr: 1, head: h1, settled: [{ surface: 'comment', id: 77, disposition: 'declined', content_fingerprint: `fixture|2635492108-38` }] }
process.env.AUTH_LIVE_BODY = collisionB
assert.deepEqual(trustedSettlements(collisionState, collisionRecord, runRoot), [])
process.env.AUTH_LIVE_BODY = collisionA
assert.equal(trustedSettlements(collisionState, collisionRecord, runRoot).length, 1)
const customSettlementState = { ...collisionState, finder: otherFinder }
process.env.AUTH_LIVE_ACTOR = '42'
assert.equal(trustedSettlements(customSettlementState, collisionRecord, runRoot).length, 1)
process.env.AUTH_LIVE_ACTOR = '199175422'
assert.deepEqual(trustedSettlements(customSettlementState, collisionRecord, runRoot), [])
process.env.AUTH_LIVE_ACTOR = '42'
assert.deepEqual(trustedSettlements(customSettlementState, { ...collisionRecord, receipts: [] }, runRoot), [])
process.env.AUTH_LIVE_BODY = collisionB
assert.deepEqual(trustedSettlements(customSettlementState, collisionRecord, runRoot), [])
console.log('custom finder settlement authenticates its own actor, receipt and exact live body OK')
console.log('integrator owner authority authentication OK')
NODE
