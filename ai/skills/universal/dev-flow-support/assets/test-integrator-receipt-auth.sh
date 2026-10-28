#!/usr/bin/env bash
# Focused proofs for the owner-retained integration review authority boundary.
set -euo pipefail

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/integrator-receipt-auth.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

ASSET="$asset_dir/lib/integrator-receipt-auth.mjs" AUTHORITY="$asset_dir/lib/integrator-review-authority.mjs" AUTH_UNIT_DIR="$tmp" node --input-type=module <<'NODE'
import assert from 'node:assert/strict'
import { mkdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const { passAttestsCheckerCycle } = await import(pathToFileURL(process.env.ASSET).href)
const { authorityForEnvelope, authorityNote, digestBytes, retainedAuthorities, retainedCarryPredecessor, retainedCarryReplay, validateAuthority } = await import(pathToFileURL(process.env.AUTHORITY).href)
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
  snapshot: { ...terminalState, carry: { from_head: h1, attests_head: h2 } } }
const terminalCarry2Bytes = Buffer.from(`${JSON.stringify(carry2)}\n`), terminalCarry2Digest = digestBytes(terminalCarry2Bytes)
writeFileSync(join(runRoot, 'rulings', terminalCarry2Digest), terminalCarry2Bytes)
const carry3 = { schema: 1, kind: 'carry', captured_at: '2026-01-01T00:03:00Z', previous_authority_digest: terminalCarry2Digest,
  snapshot: { ...terminalState, carry: { from_head: h2, attests_head: h3 } } }
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
const interleavedCodexRetry = { schema: 1, kind: 'reserve', captured_at: '2026-01-01T00:02:00Z', previous_authority_digest: otherAttachDigest,
  snapshot: { ...state, phase: 'reserved', attempt: 2, trigger_comment_id: null, requested_at: null } }
assert.doesNotThrow(() => validateAuthority(interleavedCodexRetry, retainedAuthorities(interleavedRecord, { common, runId }), interleavedRecord, { common, runId }))
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
console.log('integrator owner authority authentication OK')
NODE
