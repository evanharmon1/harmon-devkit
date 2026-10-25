#!/usr/bin/env bash
# Focused proofs for the owner-retained integration review authority boundary.
set -euo pipefail

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/integrator-receipt-auth.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

ASSET="$asset_dir/lib/integrator-receipt-auth.mjs" AUTHORITY="$asset_dir/lib/integrator-review-authority.mjs" AUTH_UNIT_DIR="$tmp" node --input-type=module <<'NODE'
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const { passAttestsCheckerCycle } = await import(pathToFileURL(process.env.ASSET).href)
const { authorityForEnvelope, authorityNote, digestBytes, retainedAuthorities, validateAuthority } = await import(pathToFileURL(process.env.AUTHORITY).href)
const h1 = 'a'.repeat(40), h2 = 'b'.repeat(40), h3 = 'c'.repeat(40)
const common = join(process.env.AUTH_UNIT_DIR, 'common')
const runId = 'run', runRoot = join(common, 'dev-flow-v2', 'runs', runId)
mkdirSync(join(runRoot, 'rulings'), { recursive: true })
const state = { repo: 'example/repo', pr: 1, head: h1, phase: 'attached', trigger_comment_id: '200', charged_cycles: 1, exempt_cycles: 0, attempt: 1 }
const reserve = { schema: 1, kind: 'reserve', captured_at: '2026-01-01T00:00:00Z', previous_authority_digest: null,
  snapshot: { ...state, phase: 'reserved', trigger_comment_id: null } }
const reserveBytes = Buffer.from(`${JSON.stringify(reserve)}\n`), reserveDigest = digestBytes(reserveBytes)
writeFileSync(join(runRoot, 'rulings', reserveDigest), reserveBytes)
const attach = { schema: 1, kind: 'attach', captured_at: '2026-01-01T00:01:00Z', previous_authority_digest: reserveDigest, snapshot: state }
const attachBytes = Buffer.from(`${JSON.stringify(attach)}\n`), attachDigest = digestBytes(attachBytes)
writeFileSync(join(runRoot, 'rulings', attachDigest), attachBytes)
const carry2 = { schema: 1, kind: 'carry', captured_at: '2026-01-01T00:02:00Z', previous_authority_digest: attachDigest,
  snapshot: { ...state, carry: { from_head: h1, attests_head: h2 } } }
const carry2Bytes = Buffer.from(`${JSON.stringify(carry2)}\n`), carry2Digest = digestBytes(carry2Bytes)
writeFileSync(join(runRoot, 'rulings', carry2Digest), carry2Bytes)
const carry3 = { schema: 1, kind: 'carry', captured_at: '2026-01-01T00:03:00Z', previous_authority_digest: carry2Digest,
  snapshot: { ...state, carry: { from_head: h2, attests_head: h3 } } }
const carry3Bytes = Buffer.from(`${JSON.stringify(carry3)}\n`), carry3Digest = digestBytes(carry3Bytes)
writeFileSync(join(runRoot, 'rulings', carry3Digest), carry3Bytes)
const note = (kind, digest) => `${authorityNote(kind, digest)} [ruling dev-flow-v2/runs/${runId}/rulings/${digest} sha256=${digest}]`
const record = { interventions: [
  { kind: 'other', note: note('reserve', reserveDigest) }, { kind: 'other', note: note('attach', attachDigest) },
  { kind: 'other', note: note('carry', carry2Digest) }, { kind: 'other', note: note('carry', carry3Digest) },
] }
const envelope = { head: h1, payload: { codex_cycle: { cycle: 1, attempt: 1, trigger_comment_id: '200' } } }
assert.equal(authorityForEnvelope({ interventions: [] }, envelope, { common, runId }), null)
assert.equal(retainedAuthorities(record, { common, runId }).length, 4)
assert.equal(authorityForEnvelope(record, envelope, { common, runId }).digest, attachDigest)
assert.throws(() => authorityForEnvelope(record, { ...envelope, head: 'd'.repeat(40) }, { common, runId }), /no retained owner authority/)
assert.equal(authorityForEnvelope(record, { ...envelope, head: h3 }, { common, runId }).digest, carry3Digest)
assert.equal(passAttestsCheckerCycle({ head: h2, payload: { codex_cycle: { carried: { origin_head: h1, attests_head: h2 } } } },
  { head: h1, carry: { attests_head: h3 } }), true)
assert.equal(passAttestsCheckerCycle({ head: h2, payload: { codex_cycle: { carried: { origin_head: h1, attests_head: h3 } } } },
  { head: h1 }), false)

// A legacy r1 can seed the first carry only when a receipt already admitted
// exact immutable clean evidence.  Later carries use the normal retained
// chain, so receipt bytes cannot become a general historical escape hatch.
const legacyRun = 'legacy-run', legacyRoot = join(common, 'dev-flow-v2', 'runs', legacyRun)
mkdirSync(join(legacyRoot, 'passes'), { recursive: true })
const legacyState = { ...state }
const legacyPass = {
  run: { run_id: legacyRun }, role: 'integrator', status: 'completed', head: h1,
  payload: { integration_round: 1, verdict: 'clean', codex_cycle: {
    head: h1, cycle: 1, attempt: 1, trigger_comment_id: '200', exit_code: 0,
    accepted: { surface: 'comment', reviewed_commit: h1 },
  } },
}
writeFileSync(join(legacyRoot, 'passes', 'integration-r1-integrator.json'), `${JSON.stringify(legacyPass)}\n`)
const legacyRecord = {
  run_id: legacyRun,
  receipts: [{ kind: 'pass', file: 'integration-r1-integrator' }],
  pr_bindings: [{ number: 1, url: 'https://github.com/example/repo/pull/1' }],
  interventions: [],
}
const legacyCarry = { schema: 1, kind: 'carry', captured_at: '2026-01-01T00:00:00Z', previous_authority_digest: null,
  snapshot: { ...legacyState, carry: { from_head: h1, attests_head: h2 } } }
const legacyOptions = { common, runId: legacyRun }
assert.doesNotThrow(() => validateAuthority(legacyCarry, [], legacyRecord, legacyOptions))
assert.throws(() => validateAuthority({ ...legacyCarry, snapshot: { ...legacyCarry.snapshot, carry: { from_head: h2, attests_head: h3 } } }, [], legacyRecord, legacyOptions), /origin or immediate predecessor/)
assert.throws(() => validateAuthority(legacyCarry, [], { ...legacyRecord, receipts: [] }, legacyOptions), /origin or immediate predecessor/)
writeFileSync(join(legacyRoot, 'passes', 'integration-r1-integrator.json'), `${JSON.stringify({ ...legacyPass, head: h2 })}\n`)
assert.throws(() => validateAuthority(legacyCarry, [], legacyRecord, legacyOptions), /origin or immediate predecessor/)
writeFileSync(join(legacyRoot, 'passes', 'integration-r1-integrator.json'), `${JSON.stringify(legacyPass)}\n`)
const legacyCarry2 = { schema: 1, kind: 'carry', captured_at: '2026-01-01T00:01:00Z', previous_authority_digest: 'd'.repeat(64),
  snapshot: { ...legacyState, carry: { from_head: h2, attests_head: h3 } } }
const legacyPredecessor = [{ kind: 'carry', digest: 'd'.repeat(64), authority: legacyCarry }]
assert.doesNotThrow(() => validateAuthority(legacyCarry2, legacyPredecessor, legacyRecord, legacyOptions))
console.log('integrator owner authority authentication OK')
NODE
