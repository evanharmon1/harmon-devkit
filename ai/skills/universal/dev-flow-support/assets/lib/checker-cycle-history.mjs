// Checker observations are immutable receipts, never role result envelopes.
// Admission authenticates live evidence; historical readers verify retained bytes
// and their owner-captured request authority without polling an obsolete head.
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { digestBytes, retainedAuthorities } from './integrator-review-authority.mjs'

export function checkerCycleHistory(record, recordDir) {
  const receipts = record.checker_cycle_receipts ?? []
  if (!Array.isArray(receipts)) throw new Error('checker cycle receipts must be an array')
  if (receipts.length === 0) return []
  // The clean-run fast path is deliberately still a single charged cycle.
  if (receipts.length !== 1) throw new Error('checker history must contain exactly one initial clean cycle')
  const authorities = retainedAuthorities(record, { common: resolve(recordDir, '../../..'), runId: record.run_id })
  return receipts.map((entry) => {
    if (!/^[0-9a-f]{64}$/.test(entry.digest ?? '')) throw new Error('invalid checker receipt digest')
    const bytes = readFileSync(join(recordDir, 'checker-cycles', `${entry.digest}.json`))
    if (digestBytes(bytes) !== entry.digest) throw new Error('checker receipt digest mismatch')
    const receipt = JSON.parse(bytes)
    const authority = authorities.find((item) => item.digest === receipt.authority_digest && item.kind === 'attach')
    const state = authority?.authority.snapshot
    const cc = receipt.cycle
    const binding = record.pr_bindings?.at(-1)
    if (receipt.schema !== 1 || receipt.kind !== 'checker-cycle' || receipt.run_id !== record.run_id ||
        receipt.initiated_by !== record.initiated_by || receipt.captured_at !== entry.at ||
        typeof cc?.head !== 'string' || !/^[0-9a-f]{40}$/.test(cc.head) ||
        !Number.isSafeInteger(cc?.attempt) || cc.attempt < 1 || cc.attempt > 2 ||
        !Number.isFinite(Date.parse(receipt.captured_at)) ||
        !state || state.run_id !== record.run_id || state.carry != null ||
        (state.finder?.slug ?? 'codex-cloud') !== 'codex-cloud' ||
        binding?.number !== state.pr || new URL(binding.url).pathname !== `/${state.repo}/pull/${state.pr}` ||
        receipt.head !== state.head || cc?.head !== state.head ||
        state.charged_cycles + state.exempt_cycles !== 1 ||
        cc.cycle !== 1 || cc.charged !== 1 || cc.exempt !== 0 || cc.exit_code !== 0 || cc.carried != null ||
        cc.attempt !== state.attempt || String(cc.trigger_comment_id) !== String(state.trigger_comment_id) ||
        !['comment', 'review', 'reaction'].includes(cc.accepted?.surface) || !cc.accepted?.id ||
        Date.parse(receipt.captured_at) < Date.parse(authority.authority.captured_at) ||
        Date.parse(receipt.captured_at) < Date.parse(record.started_at)) {
      throw new Error('checker receipt is not bound to its run, PR and retained terminal request')
    }
    return receipt
  })
}

// Shared by admission sequencing and both head-movement/debt guards. A retry
// can discharge the earlier attempt of the same cycle; a carry names its own
// attested head and never changes the original cycle's identity.
export function terminalReviewHistory(record, recordDir) {
  const history = checkerCycleHistory(record, recordDir).map((receipt) => ({
    source: 'checker', run_id: receipt.run_id, head: receipt.head,
    verdict: 'clean', cycles: [{ finder: 'codex-cloud', ...receipt.cycle }],
  }))
  for (const entry of record.receipts ?? []) {
    if (entry.kind !== 'pass' || !/^integration-r[1-9][0-9]*-integrator$/.test(entry.file ?? '')) continue
    const pass = JSON.parse(readFileSync(join(recordDir, 'passes', `${entry.file}.json`), 'utf8'))
    if (pass?.run?.run_id !== record.run_id || pass.role !== 'integrator' || pass.status !== 'completed') continue
    const cycles = [...(pass.payload?.finder_cycles ?? [])].filter((cycle) => cycle.finder !== 'codex-cloud')
    if (pass.payload?.codex_cycle) cycles.push({ finder: 'codex-cloud', ...pass.payload.codex_cycle })
    history.push({ source: 'integrator', run_id: record.run_id, head: pass.head, verdict: pass.payload?.verdict, cycles })
  }
  return history
}
