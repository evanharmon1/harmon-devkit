#!/usr/bin/env bash
# test-integrator-receipt-auth.sh — focused offline unit proofs for the
# immutable receipt snapshot boundary.  The production checker is intentionally
# unchanged; this fixture stubs only the GitHub reads used to authenticate its
# input tuple.
set -euo pipefail

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/integrator-receipt-auth.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
case "$*" in
  *"issues/comments/200"*)
    printf '%s\n' '{"id":200,"body":"@codex review","issue_url":"https://api.github.com/repos/example/repo/issues/1","created_at":"2026-01-01T00:22:00Z","user":{"id":12345}}'
    ;;
  *"commits/$head/check-suites?per_page=100"*)
    if [ "${NO_SUITES:-0}" = 1 ]; then printf '%s\n' '[{"check_suites":[]}]'; else printf '%s\n' '[{"check_suites":[{"created_at":"2026-01-01T00:00:00Z"}]}]'; fi
    ;;
  *"commits/$head"*)
    printf '%s\n' '{"commit":{"author":{"date":"2026-01-01T00:00:00Z"},"committer":{"date":"2026-01-01T00:00:01Z"}}}'
    ;;
  *"issues/1/comments?per_page=100"*)
    printf '%s\n' '[[{"id":100,"body":"@codex review","issue_url":"https://api.github.com/repos/example/repo/issues/1","created_at":"2026-01-01T00:01:00Z","user":{"id":12345}},{"id":200,"body":"@codex review","issue_url":"https://api.github.com/repos/example/repo/issues/1","created_at":"2026-01-01T00:22:00Z","user":{"id":12345}}]]'
    ;;
  *) printf 'unexpected gh request: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"

ASSET="$asset_dir/lib/integrator-receipt-auth.mjs" AUTH_UNIT_DIR="$tmp/unit-record" PATH="$tmp/bin:$PATH" node --input-type=module <<'NODE'
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const { authenticatedReviewCommentSnapshot, passAttestsCheckerCycle } = await import(pathToFileURL(process.env.ASSET).href)
const h1 = 'a'.repeat(40)
const h2 = 'b'.repeat(40)
const h3 = 'c'.repeat(40)
const state = {
  repo: 'example/repo', pr: 1, head: h1, trigger_comment_id: '200',
  first_trigger_comment_id: '100', requested_at: '2026-01-01T00:22:00Z',
  timeout_min: 20, requires_full_window: false, attempt: 2, charged_cycles: 1, exempt_cycles: 0,
}
const profile = { trigger_mechanism: 'review-comment', trigger_body: '@codex review' }
const recordDir = process.env.AUTH_UNIT_DIR
mkdirSync(join(recordDir, 'passes'), { recursive: true })
writeFileSync(join(recordDir, 'passes', 'integration-r1-integrator.json'), JSON.stringify({
  run: { run_id: 'run' }, head: h1, payload: { codex_cycle: { cycle: 1, trigger_comment_id: '200' } },
}))
const currentCycleRecord = { run_id: 'run', receipts: [{ kind: 'pass', file: 'integration-r1-integrator' }] }
const snapshot = authenticatedReviewCommentSnapshot(state, profile, [12345], currentCycleRecord, recordDir)
assert.equal(snapshot.state.first_trigger_comment_id, 100)
assert.equal(snapshot.state.timeout_min, 20)
assert.equal(snapshot.state.requires_full_window, true)
assert.equal(snapshot.independentlyProvesTwoAttempts, true)
const shortWindow = authenticatedReviewCommentSnapshot({ ...state, timeout_min: 10 }, profile, [12345], currentCycleRecord, recordDir)
assert.equal(shortWindow.state.timeout_min, 10)
assert.equal(shortWindow.independentlyProvesTwoAttempts, true)
const clampedWindow = authenticatedReviewCommentSnapshot({ ...state, timeout_min: 1 }, profile, [12345], currentCycleRecord, recordDir)
assert.equal(clampedWindow.state.timeout_min, 10)
assert.throws(
  () => authenticatedReviewCommentSnapshot({ ...state, first_trigger_comment_id: '999999999' }, profile, [12345], currentCycleRecord, recordDir),
  /first-trigger boundary/,
)
assert.throws(
  () => authenticatedReviewCommentSnapshot(state, profile, [67890], currentCycleRecord, recordDir),
  /exact trusted orchestrator review request/,
)
process.env.NO_SUITES = '1'
assert.throws(
  () => authenticatedReviewCommentSnapshot(state, profile, [12345], currentCycleRecord, recordDir),
  /no readable check-suite timestamp/,
)
delete process.env.NO_SUITES

const priorCycleRecord = { run_id: 'run', receipts: [{ kind: 'pass', file: 'integration-r1-integrator' }] }
const priorCycle = authenticatedReviewCommentSnapshot(
  { ...state, charged_cycles: 2, attempt: 2 }, profile, [12345], priorCycleRecord, recordDir,
)
assert.equal(priorCycle.independentlyProvesTwoAttempts, false)

const carried = (head, origin = h1) => ({ head, payload: { codex_cycle: { carried: { origin_head: origin, attests_head: head } } } })
assert.equal(passAttestsCheckerCycle(carried(h2), { head: h1, carry: { attests_head: h3 } }), true)
assert.equal(passAttestsCheckerCycle(carried(h3), { head: h1, carry: { attests_head: h3 } }), true)
assert.equal(passAttestsCheckerCycle(carried(h2, 'd'.repeat(40)), { head: h1 }), false)
assert.equal(passAttestsCheckerCycle({ head: h2, payload: { codex_cycle: { carried: { origin_head: h1, attests_head: h3 } } } }, { head: h1 }), false)
console.log('integrator receipt authentication OK')
NODE
