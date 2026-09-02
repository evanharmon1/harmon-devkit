#!/usr/bin/env bash
# Fixture-driven + hermetic regression tests for render-dev-flow.mjs
# (scripts/render-dev-flow.mjs, ai/schemas/fixtures/render/). Golden fixtures
# prove byte-stable projections from one shared record covering every
# disposition (fix/restructure/delete/decline/defer/file); the publish
# section fakes `gh` on PATH, the way scripts/test-shepherd-*.sh do, to
# exercise the read-modify-write transaction with no network access.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="${repo_root}/scripts/render-dev-flow.mjs"
fixtures_dir="${repo_root}/ai/schemas/fixtures/render"
golden_dir="${fixtures_dir}/golden"
record_dir="${fixtures_dir}/record"

test_tmp="$(mktemp -d -t render-dev-flow-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

out=
err=
rc=0

run() {
    set +e
    out="$(node "$renderer" "$@" 2>"${test_tmp}/stderr")"
    rc=$?
    set -e
    err="$(cat "${test_tmp}/stderr")"
}

assert_rc() {
    [ "$rc" -eq "$1" ] || fail "expected rc $1, got $rc: stdout='$out' stderr='$err'"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "expected '$1' to contain '$2'"
}

golden_matches() {
    local projection="$1" golden_file="$2"
    shift 2
    run "$projection" --record "$record_dir" "$@"
    assert_rc 0
    [ "$out" = "$(cat "${golden_dir}/${golden_file}")" ] ||
        fail "$projection drifted from ${golden_file} (diff shown)
$(diff <(printf '%s' "$out") "${golden_dir}/${golden_file}" || true)"
}

# ── golden projections ──────────────────────────────────────────────────

# The record's latest round (review round 2) reviewed this head; blocker-
# comment and readiness-input require --head explicitly (Codex challenge
# round 1, finding "Require the current head for blocker projections" —
# inferring it from adjudication order would silently under-report an
# unreviewed fix push as the reviewed round's own head).
render_head="2222222222222222222222222222222222222222"

echo "==> golden: deferred-findings matches ai/schemas/fixtures/render/golden/deferred-findings.txt"
golden_matches deferred-findings deferred-findings.txt

echo "==> golden: adjudication-record matches golden/adjudication-record.txt"
golden_matches adjudication-record adjudication-record.txt

echo "==> golden: round-table (integration round 1) matches golden/round-table.txt"
golden_matches round-table round-table.txt --stage integration --round 1 --verdict "${record_dir}/verdict.json"

echo "==> golden: policy-disclosure matches golden/policy-disclosure.txt"
golden_matches policy-disclosure policy-disclosure.txt

echo "==> golden: blocker-comment matches golden/blocker-comment.txt"
golden_matches blocker-comment blocker-comment.txt --verdict "${record_dir}/verdict.json" --head "$render_head"

echo "==> golden: thread-reply-plan matches golden/thread-reply-plan.json"
golden_matches thread-reply-plan thread-reply-plan.json

echo "==> golden: readiness-input matches golden/readiness-input.json"
golden_matches readiness-input readiness-input.json --head "$render_head"

echo "==> every disposition (fix/restructure/delete/decline/defer/file) appears in the adjudication-record golden"
for disposition in 'fix —' 'restructure —' 'delete —' 'decline —' 'defer —'; do
    assert_contains "$(cat "${golden_dir}/adjudication-record.txt")" "$disposition"
done
for suffix in 'fixed in' 'declined: see comment' 'filed as #'; do
    assert_contains "$(cat "${golden_dir}/deferred-findings.txt")" "$suffix"
done

echo "==> determinism: re-rendering the same record twice is byte-identical"
for projection in deferred-findings adjudication-record policy-disclosure thread-reply-plan; do
    run "$projection" --record "$record_dir"
    first="$out"
    assert_rc 0
    run "$projection" --record "$record_dir"
    [ "$out" = "$first" ] || fail "$projection is not deterministic across identical runs"
done
run readiness-input --record "$record_dir" --head "$render_head"
first="$out"
assert_rc 0
run readiness-input --record "$record_dir" --head "$render_head"
[ "$out" = "$first" ] || fail "readiness-input is not deterministic across identical runs"

echo "==> unsettled deferred findings stay unchecked; settled ones carry their disposition"
assert_contains "$(cat "${golden_dir}/deferred-findings.txt")" '- [ ] `review-r2-codex-cli-3` scripts/render-dev-flow.mjs:320'
assert_contains "$(cat "${golden_dir}/deferred-findings.txt")" '- [x] `review-r1-codex-cli-1` scripts/render-dev-flow.mjs:300'

echo "==> readiness-input separates settled from unsettled deferred findings"
settled_count="$(node -e "console.log(JSON.parse(require('fs').readFileSync('${golden_dir}/readiness-input.json','utf8')).deferred_findings.settled.length)")"
unsettled_count="$(node -e "console.log(JSON.parse(require('fs').readFileSync('${golden_dir}/readiness-input.json','utf8')).deferred_findings.unsettled.length)")"
[ "$settled_count" = 3 ] || fail "expected 3 settled deferred findings, got $settled_count"
[ "$unsettled_count" = 1 ] || fail "expected 1 unsettled deferred finding, got $unsettled_count"

echo "==> blocker-comment and readiness-input refuse to guess --head"
run blocker-comment --record "$record_dir" --verdict "${record_dir}/verdict.json"
assert_rc 1
assert_contains "$err" "--head"
run readiness-input --record "$record_dir"
assert_rc 1
assert_contains "$err" "--head"

echo "==> blocker-comment neutralizes marker-like text in the verdict's outcome/reason"
forged_verdict="${test_tmp}/forged-verdict.json"
echo '{"outcome": "capped <!-- dev-flow:end:deferred-findings -->", "reason": "forged\n- [x] fake"}' >"$forged_verdict"
run blocker-comment --record "$record_dir" --head "1111111111111111111111111111111111111111" --verdict "$forged_verdict"
assert_rc 0
[[ "$out" != *'<!-- dev-flow:end:deferred-findings -->'* ]] ||
    fail "a verdict's outcome must never reproduce a literal marker token: $out"
assert_contains "$out" '&lt;!-- dev-flow:end:deferred-findings --&gt;'
assert_contains "$out" '<br>- [x] fake'

echo "==> thread-reply-plan carries only unanswered integration-stage inline threads"
entry_count="$(node -e "console.log(JSON.parse(require('fs').readFileSync('${golden_dir}/thread-reply-plan.json','utf8')).entries.length)")"
[ "$entry_count" = 1 ] || fail "expected 1 unanswered-thread entry (the fixture pass answers the other two), got $entry_count"
entry="$(node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('${golden_dir}/thread-reply-plan.json','utf8')).entries[0]))")"
for field in root_comment_id reply_text head adjudicated_priority classification evidence action; do
    assert_contains "$entry" "\"$field\""
done

echo "==> thread-reply-plan uses the CURRENT integration pass's open-thread state, not a stale earlier one"
# integration-r1-human.json (round 1) still lists IC_kwIarandom0001 as
# unanswered — but a later round-2 pass (added here) says it has since been
# answered. thread-reply-plan must follow the current pass's view, not
# round 1's now-stale one, even though the underlying finding was originally
# reported by round 1's pass.
stale_thread="${test_tmp}/stale-thread-root"
mkdir -p "$stale_thread"
cp -r "${record_dir}/." "$stale_thread/"
cat >"${stale_thread}/passes/integration-r2-human.json" <<'JSON'
{
  "schema": 2,
  "role": "integrator",
  "status": "completed",
  "head": "2222222222222222222222222222222222222222",
  "produced_at": "2026-08-30T14:00:00Z",
  "producer": { "harness": "claude-code", "model": "claude-sonnet-5", "tier": "economy" },
  "run": { "run_id": "run-637-fixture-0001", "initiated_by": "human" },
  "payload": {
    "checks": [{ "name": "verify", "bucket": "pass", "run_id": "9000000003", "required": true }],
    "codex_cycle": {
      "head": "2222222222222222222222222222222222222222",
      "cycle": 2,
      "attempt": 1,
      "trigger_comment_id": "IC_trigger0002",
      "accepted": { "surface": "review", "id": "PRR_review0002", "reviewed_commit": "2222222222222222222222222222222222222222" },
      "exit_code": 0
    },
    "integration_round": 2,
    "findings": [],
    "unanswered_thread_roots": [],
    "settled_at": "2026-08-30T14:00:00Z",
    "verdict": "pending"
  }
}
JSON
run thread-reply-plan --record "$stale_thread"
assert_rc 0
entries_now="$(node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).entries.length)" <<<"$out")"
[ "$entries_now" = 0 ] ||
    fail "expected 0 entries once round 2 reports the thread answered, got $entries_now: $out"

echo "==> cross-document consistency: an orphan settlement (no matching deferred finding) is rejected"
bad_run="${test_tmp}/orphan-settlement"
mkdir -p "$bad_run"
cp -r "${record_dir}/." "$bad_run/"
node -e "
const fs = require('fs');
const p = '${bad_run}/run.json';
const run = JSON.parse(fs.readFileSync(p, 'utf8'));
run.settlements.push({finding_id: 'review-r1-codex-cli-99', disposition: 'fix', settled_at: '2026-08-30T13:08:00Z', reference: {type: 'sha', value: 'c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff'}});
fs.writeFileSync(p, JSON.stringify(run, null, 2));
"
run deferred-findings --record "$bad_run"
assert_rc 1
assert_contains "$err" "orphan settlement"

echo "==> cross-document consistency: a settlement whose reference.type disagrees with its disposition is rejected"
bad_type="${test_tmp}/settlement-type-mismatch"
mkdir -p "$bad_type"
cp -r "${record_dir}/." "$bad_type/"
node -e "
const fs = require('fs');
const p = '${bad_type}/run.json';
const run = JSON.parse(fs.readFileSync(p, 'utf8'));
run.settlements[0].reference = {type: 'issue_number', value: '42'};
fs.writeFileSync(p, JSON.stringify(run, null, 2));
"
run deferred-findings --record "$bad_type"
assert_rc 1
assert_contains "$err" "expected 'sha'"

echo "==> cross-document consistency: a duplicate settlement is rejected for EVERY projection, not just the ones that build a settlement index themselves"
dup_settlement="${test_tmp}/duplicate-settlement"
mkdir -p "$dup_settlement"
cp -r "${record_dir}/." "$dup_settlement/"
node -e "
const fs = require('fs');
const p = '${dup_settlement}/run.json';
const run = JSON.parse(fs.readFileSync(p, 'utf8'));
run.settlements.push(run.settlements[0]);
fs.writeFileSync(p, JSON.stringify(run, null, 2));
"
run adjudication-record --record "$dup_settlement"
assert_rc 1
assert_contains "$err" "duplicate settlement for finding"

echo "==> cross-document consistency: a pass naming a different head than its adjudication is rejected"
bad_head="${test_tmp}/pass-head-mismatch"
mkdir -p "$bad_head"
cp -r "${record_dir}/." "$bad_head/"
node -e "
const fs = require('fs');
const p = '${bad_head}/passes/challenge-r1-codex-cli.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
envelope.head = '9999999999999999999999999999999999999999';
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run deferred-findings --record "$bad_head"
assert_rc 1
assert_contains "$err" "its pass envelope names head"

echo "==> cross-document consistency: a challenger pass may back a challenge-stage finding, but not a review-stage one"
challenger_wrong_stage="${test_tmp}/challenger-wrong-stage"
mkdir -p "$challenger_wrong_stage"
cp -r "${record_dir}/." "$challenger_wrong_stage/"
node -e "
const fs = require('fs');
// A dedicated pass file, isolated from the shared challenge-r1-codex-cli.json
// (reusing that file's OWN finding here would also change its payload.stage
// for the OTHER finding it still legitimately backs in challenge-r1.json).
// result.challenger.schema.json pins payload.stage to the const \"challenge\"
// — a challenger payload can never itself claim to be review-stage — so the
// finding id is what is reassigned to review-r1's coordinates (satisfying
// the finding-id-segment check), while payload.stage/round stay genuinely
// \"challenge\"/1. That is what isolates STAGE_ROLES' role check: it fires
// before the payload-coordinate check ever runs for this row (both would
// fail here, but the role check is earlier in the function), so it is the
// one actually observed.
const adversarialPass = {
  schema: 2,
  role: 'challenger',
  status: 'completed',
  head: '1111111111111111111111111111111111111111',
  produced_at: '2026-08-30T11:30:00Z',
  producer: { harness: 'codex-cli', model: 'gpt-5-codex', tier: 'frontier' },
  run: { run_id: 'run-637-fixture-0001', initiated_by: 'human' },
  payload: {
    stage: 'challenge',
    round: 1,
    reviewed_head: '1111111111111111111111111111111111111111',
    finder: 'codex-cli',
    findings: [
      {
        id: 'review-r1-codex-cli-99',
        path: 'scripts/render-dev-flow.mjs',
        line: 210,
        class: 'correctness',
        provenance: 'original',
        fingerprint: 'new',
        priority: 'P1',
        recommended_disposition: 'fix',
        evidence: 'adversarial: a genuine challenger pass whose finding id is reassigned to review round 1 coordinates'
      }
    ],
    counts: { P0: 0, P1: 1, P2: 0, P3: 0 },
    attack_scenarios: [
      {
        id: 'as-adversarial-1',
        description: 'Reassigned a challenger pass finding to review round 1 coordinates via its finding id alone',
        outcome: 'surfaced-finding',
        finding_id: 'review-r1-codex-cli-99'
      }
    ]
  }
};
fs.writeFileSync('${challenger_wrong_stage}/passes/adversarial-challenger.json', JSON.stringify(adversarialPass, null, 2));
const revDoc = JSON.parse(fs.readFileSync('${challenger_wrong_stage}/adjudications/review-r1.json', 'utf8'));
// Push a new entry rather than overwriting an existing one — overwriting
// review-r1-codex-cli-1's own slot would orphan ITS pass finding (still
// present in review-r1-codex-cli.json) with no adjudication of its own,
// tripping the unrelated never-adjudicated check before reaching this
// test's own target.
revDoc.adjudications.push({
    finding_id: 'review-r1-codex-cli-99',
    reviewer_priority: 'P1',
    adjudicated_priority: 'P1',
    disposition: 'fix',
    reason: 'adversarial test entry',
    evidence: 'adversarial test entry',
    override: null
});
fs.writeFileSync('${challenger_wrong_stage}/adjudications/review-r1.json', JSON.stringify(revDoc, null, 2));
"
run deferred-findings --record "$challenger_wrong_stage"
assert_rc 1
assert_contains "$err" "requires a pass with role reviewer, but its matching pass has role challenger"

echo "==> cross-document consistency: an adjudication document from a foreign run is rejected"
bad_run_id="${test_tmp}/adjudication-run-mismatch"
mkdir -p "$bad_run_id"
cp -r "${record_dir}/." "$bad_run_id/"
node -e "
const fs = require('fs');
const p = '${bad_run_id}/adjudications/challenge-r1.json';
const doc = JSON.parse(fs.readFileSync(p, 'utf8'));
doc.run_id = 'some-other-run';
fs.writeFileSync(p, JSON.stringify(doc, null, 2));
"
run deferred-findings --record "$bad_run_id"
assert_rc 1
assert_contains "$err" "does not match run.json's run_id"

echo "==> cross-document consistency: a pass claiming a different initiated_by than run.json is rejected"
bad_initiated_by="${test_tmp}/pass-initiated-by-mismatch"
mkdir -p "$bad_initiated_by"
cp -r "${record_dir}/." "$bad_initiated_by/"
node -e "
const fs = require('fs');
const p = '${bad_initiated_by}/passes/challenge-r1-codex-cli.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
envelope.run.initiated_by = 'foreman';
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run deferred-findings --record "$bad_initiated_by"
assert_rc 1
assert_contains "$err" "its pass envelope names initiated_by foreman, but run.json's initiated_by is human"

echo "==> cross-document consistency: adjudication documents must agree on run_id even with no run.json to anchor it"
no_run_json_mismatch="${test_tmp}/no-run-json-run-id-mismatch"
mkdir -p "$no_run_json_mismatch"
cp -r "${record_dir}/." "$no_run_json_mismatch/"
rm "${no_run_json_mismatch}/run.json"
node -e "
const fs = require('fs');
const p = '${no_run_json_mismatch}/adjudications/challenge-r1.json';
const doc = JSON.parse(fs.readFileSync(p, 'utf8'));
doc.run_id = 'some-other-run';
fs.writeFileSync(p, JSON.stringify(doc, null, 2));
"
run adjudication-record --record "$no_run_json_mismatch"
assert_rc 1
assert_contains "$err" "does not match"
assert_contains "$err" "some-other-run"

echo "==> cross-document consistency: two files claiming the same round are rejected"
dup_round="${test_tmp}/duplicate-round"
mkdir -p "$dup_round"
cp -r "${record_dir}/." "$dup_round/"
cp "${record_dir}/adjudications/challenge-r1.json" "${dup_round}/adjudications/challenge-r1-copy.json"
run deferred-findings --record "$dup_round"
assert_rc 1
assert_contains "$err" "is already claimed by"

echo "==> cross-document consistency: a duplicate finding id within the same document is rejected"
# A duplicate spanning two DIFFERENT (stage, round) documents is no longer
# constructible: the finding-id-segment check (below) requires an id's own
# encoded stage/round to match its containing document, and loadRecord
# already refuses two documents claiming the same (stage, round) — together
# they mean an id's encoded coordinates pin it to exactly one document. So
# this now exercises the one remaining shape: the same id appearing twice
# inside one document's own adjudications[].
dup_finding="${test_tmp}/duplicate-finding-id"
mkdir -p "$dup_finding"
cp -r "${record_dir}/." "$dup_finding/"
node -e "
const fs = require('fs');
const p = '${dup_finding}/adjudications/challenge-r1.json';
const doc = JSON.parse(fs.readFileSync(p, 'utf8'));
doc.adjudications.push(doc.adjudications[0]);
fs.writeFileSync(p, JSON.stringify(doc, null, 2));
"
run deferred-findings --record "$dup_finding"
assert_rc 1
assert_contains "$err" "was already adjudicated in"

echo "==> cross-document consistency: a malformed settlement reference value (not 40-hex) is rejected"
bad_sha="${test_tmp}/settlement-value-malformed"
mkdir -p "$bad_sha"
cp -r "${record_dir}/." "$bad_sha/"
node -e "
const fs = require('fs');
const p = '${bad_sha}/run.json';
const run = JSON.parse(fs.readFileSync(p, 'utf8'));
run.settlements[0].reference.value = 'not-a-sha';
fs.writeFileSync(p, JSON.stringify(run, null, 2));
"
run deferred-findings --record "$bad_sha"
assert_rc 1
assert_contains "$err" "does not match the expected shape"

echo "==> thread-reply-plan requires the matching integrator pass, never a silent omission"
no_pass="${test_tmp}/integration-no-pass"
mkdir -p "$no_pass"
cp -r "${record_dir}/." "$no_pass/"
rm "${no_pass}/passes/integration-r1-human.json"
run thread-reply-plan --record "$no_pass"
assert_rc 1
assert_contains "$err" "cannot determine whether its thread is still unanswered"

echo "==> adjudication-record's Classification column reflects the pass's real class, never a fabricated confirmed/false-positive"
assert_contains "$(cat "${golden_dir}/adjudication-record.txt")" '| correctness |'
assert_contains "$(cat "${golden_dir}/adjudication-record.txt")" '| hardening |'
assert_contains "$(cat "${golden_dir}/adjudication-record.txt")" '| n/a |'

echo "==> cross-document consistency: a pass finding with no adjudication is rejected, not silently invisible"
unadjudicated_pass="${test_tmp}/unadjudicated-pass-finding"
mkdir -p "$unadjudicated_pass"
cp -r "${record_dir}/." "$unadjudicated_pass/"
node -e "
const fs = require('fs');
const p = '${unadjudicated_pass}/passes/challenge-r1-codex-cli.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
envelope.payload.findings.push({
    id: 'challenge-r1-codex-cli-99',
    path: 'scripts/render-dev-flow.mjs',
    line: 1,
    class: 'correctness',
    provenance: 'original',
    fingerprint: 'new',
    priority: 'P1',
    recommended_disposition: 'fix',
    evidence: 'never adjudicated by any document'
});
envelope.payload.counts.P1 += 1;
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run adjudication-record --record "$unadjudicated_pass"
assert_rc 1
assert_contains "$err" "challenge-r1-codex-cli-99"
assert_contains "$err" "never adjudicated by any supplied adjudication document"

echo "==> cross-document consistency: a drifted reviewer_priority copy is rejected"
drift_priority="${test_tmp}/reviewer-priority-drift"
mkdir -p "$drift_priority"
cp -r "${record_dir}/." "$drift_priority/"
node -e "
const fs = require('fs');
const p = '${drift_priority}/passes/challenge-r1-codex-cli.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
envelope.payload.findings[0].priority = 'P0';
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run deferred-findings --record "$drift_priority"
assert_rc 1
assert_contains "$err" "copies reviewer_priority"

echo "==> cross-document consistency: a pass whose payload declares a different round is rejected"
# The finding id and the adjudicating document both correctly say round 1 —
# only the pass's OWN payload.round (a second, independent encoding) drifts,
# which only the payload-coordinate check (not the finding-id-segment check)
# can catch.
drift_payload_round="${test_tmp}/payload-round-drift"
mkdir -p "$drift_payload_round"
cp -r "${record_dir}/." "$drift_payload_round/"
node -e "
const fs = require('fs');
const p = '${drift_payload_round}/passes/review-r1-codex-cli.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
envelope.payload.round = 99;
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run deferred-findings --record "$drift_payload_round"
assert_rc 1
assert_contains "$err" "its pass payload declares stage/round review/99"

echo "==> cross-document consistency: an integrator pass whose payload declares a different round is rejected"
drift_integration_round="${test_tmp}/payload-integration-round-drift"
mkdir -p "$drift_integration_round"
cp -r "${record_dir}/." "$drift_integration_round/"
node -e "
const fs = require('fs');
const p = '${drift_integration_round}/passes/integration-r1-human.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
envelope.payload.integration_round = 99;
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run deferred-findings --record "$drift_integration_round"
assert_rc 1
assert_contains "$err" "its pass payload declares integration_round 99, but the adjudicating document's round is 1"

echo "==> cross-document consistency: a foreign-run integrator pass cannot masquerade as the current thread-state snapshot"
foreign_integration_pass="${test_tmp}/foreign-integration-snapshot"
mkdir -p "$foreign_integration_pass"
cp -r "${record_dir}/." "$foreign_integration_pass/"
node -e "
const fs = require('fs');
const src = JSON.parse(fs.readFileSync('${foreign_integration_pass}/passes/integration-r1-human.json', 'utf8'));
const foreign = JSON.parse(JSON.stringify(src));
foreign.run.run_id = 'some-other-run';
foreign.payload.integration_round = 99;
foreign.payload.findings = [];
foreign.payload.unanswered_thread_roots = [];
foreign.payload.verdict = 'pending';
fs.writeFileSync('${foreign_integration_pass}/passes/foreign-integration.json', JSON.stringify(foreign, null, 2));
"
run thread-reply-plan --record "$foreign_integration_pass"
assert_rc 0
entry_count_foreign="$(node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).entries.length)" <<<"$out")"
[ "$entry_count_foreign" = 1 ] ||
    fail "a foreign-run pass must not win 'latest' and hide the real run's open thread, got $entry_count_foreign entries: $out"

echo "==> cross-document consistency: disposition defer is rejected for stage integration"
defer_integration="${test_tmp}/defer-in-integration"
mkdir -p "$defer_integration"
cp -r "${record_dir}/." "$defer_integration/"
node -e "
const fs = require('fs');
const p = '${defer_integration}/adjudications/integration-r1.json';
const doc = JSON.parse(fs.readFileSync(p, 'utf8'));
doc.adjudications[0].disposition = 'defer';
fs.writeFileSync(p, JSON.stringify(doc, null, 2));
"
run deferred-findings --record "$defer_integration"
assert_rc 1
assert_contains "$err" "is not valid for stage integration"

echo "==> deferred-findings requires the matching pass for a deferred finding (never a bare finding_id as its location)"
no_pass_deferred="${test_tmp}/deferred-no-pass"
mkdir -p "$no_pass_deferred"
cp -r "${record_dir}/." "$no_pass_deferred/"
rm "${no_pass_deferred}/passes/review-r1-codex-cli.json"
run deferred-findings --record "$no_pass_deferred"
assert_rc 1
assert_contains "$err" "no matching pass supplied"

echo "==> round-table rejects a partial --stage/--round selector instead of guessing"
run round-table --record "$record_dir" --stage review
assert_rc 1
assert_contains "$err" "--stage and --round together"
run round-table --record "$record_dir" --round 2
assert_rc 1
assert_contains "$err" "--stage and --round together"

echo "==> usage: --round rejects a non-integer value instead of silently becoming NaN"
run round-table --record "$record_dir" --stage review --round abc
assert_rc 2

echo "==> usage: --pr rejects a partially-parsed or non-positive value instead of silently truncating"
run publish --record "$record_dir" --repo o/r --pr 1e2 --head "1111111111111111111111111111111111111111" --sections policy-disclosure
assert_rc 2
run publish --record "$record_dir" --repo o/r --pr -5 --head "1111111111111111111111111111111111111111" --sections policy-disclosure
assert_rc 2
run publish --record "$record_dir" --repo o/r --pr 0 --head "1111111111111111111111111111111111111111" --sections policy-disclosure
assert_rc 2

echo "==> usage: --head rejects anything shorter than a full 40-hex sha"
run readiness-input --record "$record_dir" --head nope
assert_rc 2
run readiness-input --record "$record_dir" --head "1111111111111111111111111111111111111"
assert_rc 2
run readiness-input --record "$record_dir" --head "1111111111111111111111111111111111111111"
assert_rc 0

echo "==> usage: --max-retries rejects a partially-parsed value instead of silently truncating"
run publish --record "$record_dir" --repo o/r --pr 1 --head "1111111111111111111111111111111111111111" \
    --sections policy-disclosure --max-retries 1e2
assert_rc 2

echo "==> verdict.json / policy.json shapes are validated, not just parsed as JSON"
bad_verdict="${test_tmp}/bad-verdict.json"
echo '{"outcome": 42}' >"$bad_verdict"
run round-table --record "$record_dir" --stage review --round 2 --verdict "$bad_verdict"
assert_rc 1
assert_contains "$err" "outcome must be a non-empty string"

echo "==> verdict.json's round counters must be non-negative / at-least-1, not just integers"
negative_rounds_counted="${test_tmp}/negative-rounds-counted.json"
echo '{"outcome": "capped", "rounds_counted": -1}' >"$negative_rounds_counted"
run round-table --record "$record_dir" --stage review --round 2 --verdict "$negative_rounds_counted"
assert_rc 1
assert_contains "$err" "rounds_counted, if present, must be a non-negative integer"

zero_next_round="${test_tmp}/zero-next-round.json"
echo '{"outcome": "capped", "next_round": 0}' >"$zero_next_round"
run round-table --record "$record_dir" --stage review --round 2 --verdict "$zero_next_round"
assert_rc 1
assert_contains "$err" "next_round, if present, must be a positive integer"

bad_policy="${test_tmp}/bad-policy.json"
echo '{"rigor": {"level": "standard"}}' >"$bad_policy"
run policy-disclosure --record "$record_dir" --policy "$bad_policy"
assert_rc 1
assert_contains "$err" "rigor.source must be a non-empty string"

echo "==> policy.json's individual round-cap values are validated, not just the container"
bad_cap="${test_tmp}/bad-cap-policy.json"
echo '{"rigor": {"level": "standard", "source": "default_rigor"}, "rounds": {"challenge": "three"}}' >"$bad_cap"
run policy-disclosure --record "$record_dir" --policy "$bad_cap"
assert_rc 1
assert_contains "$err" "rounds.challenge must be a non-negative integer"

echo "==> policy.json's rounds cannot be omitted or partial — every cap is required"
missing_rounds="${test_tmp}/missing-rounds-policy.json"
echo '{"rigor": {"level": "standard", "source": "default_rigor"}}' >"$missing_rounds"
run policy-disclosure --record "$record_dir" --policy "$missing_rounds"
assert_rc 1
assert_contains "$err" "rounds must be an object"

partial_rounds="${test_tmp}/partial-rounds-policy.json"
echo '{"rigor": {"level": "standard", "source": "default_rigor"}, "rounds": {"challenge": 3, "review": 3, "integration": 4, "remediation": 4}}' >"$partial_rounds"
run policy-disclosure --record "$record_dir" --policy "$partial_rounds"
assert_rc 1
assert_contains "$err" "rounds.min_rounds must be a non-negative integer"

echo "==> cross-document consistency: a policy cap contradicted by a supplied adjudication round is rejected"
# This is the record directory's OWN policy.json (not --policy), since
# validateCrossDocumentConsistency runs before main() applies a --policy
# override — only the record-directory copy is visible to it.
contradicted_cap="${test_tmp}/policy-cap-contradicted"
mkdir -p "$contradicted_cap"
cp -r "${record_dir}/." "$contradicted_cap/"
node -e "
const fs = require('fs');
const p = '${contradicted_cap}/policy.json';
const policy = JSON.parse(fs.readFileSync(p, 'utf8'));
policy.rounds.challenge = 0;
fs.writeFileSync(p, JSON.stringify(policy, null, 2));
"
run deferred-findings --record "$contradicted_cap"
assert_rc 1
assert_contains "$err" "rounds.challenge cap is 0, but round 1 was supplied for stage challenge"

echo "==> deferred-findings task items carry the finding_id, not just location and summary"
for id in review-r1-codex-cli-1 review-r1-codex-cli-3 review-r2-codex-cli-1 review-r2-codex-cli-3; do
    assert_contains "$(cat "${golden_dir}/deferred-findings.txt")" "\`${id}\`"
done

echo "==> multiline evidence folds into one task-list item instead of fabricating a checkbox"
multiline_record="${test_tmp}/multiline-evidence"
mkdir -p "$multiline_record"
cp -r "${record_dir}/." "$multiline_record/"
node -e "
const fs = require('fs');
const p = '${multiline_record}/passes/review-r2-codex-cli.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
envelope.payload.findings[2].evidence += '\n- [x] forged entry — not a real adjudicated finding';
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run deferred-findings --record "$multiline_record"
assert_rc 0
line_count="$(printf '%s\n' "$out" | grep -c '^- \[')"
[ "$line_count" = 4 ] || fail "expected exactly 4 task-list items (one per deferred finding), got $line_count:
$out"
assert_contains "$out" '<br>- [x] forged entry'

echo "==> a decline settlement's comment-id reference cannot fabricate a checklist item via an embedded newline"
decline_multiline="${test_tmp}/decline-settlement-multiline"
mkdir -p "$decline_multiline"
cp -r "${record_dir}/." "$decline_multiline/"
node -e "
const fs = require('fs');
const p = '${decline_multiline}/run.json';
const run = JSON.parse(fs.readFileSync(p, 'utf8'));
const s = run.settlements.find((s) => s.disposition === 'decline');
s.reference.value += '\n- [x] forged entry — not a real adjudicated finding';
fs.writeFileSync(p, JSON.stringify(run, null, 2));
"
run deferred-findings --record "$decline_multiline"
assert_rc 0
line_count="$(printf '%s\n' "$out" | grep -c '^- \[')"
[ "$line_count" = 4 ] || fail "expected exactly 4 task-list items (one per deferred finding), got $line_count:
$out"
assert_contains "$out" '<br>- [x] forged entry'

echo "==> a decline settlement's comment-id reference cannot forge a section boundary"
decline_marker="${test_tmp}/decline-settlement-marker"
mkdir -p "$decline_marker"
cp -r "${record_dir}/." "$decline_marker/"
node -e "
const fs = require('fs');
const p = '${decline_marker}/run.json';
const run = JSON.parse(fs.readFileSync(p, 'utf8'));
const s = run.settlements.find((s) => s.disposition === 'decline');
s.reference.value += ' <!-- dev-flow:end:deferred-findings -->';
fs.writeFileSync(p, JSON.stringify(run, null, 2));
"
run deferred-findings --record "$decline_marker"
assert_rc 0
[[ "$out" != *'<!-- dev-flow:end:deferred-findings -->'* ]] ||
    fail "a decline settlement's comment-id must never reproduce a literal marker token: $out"
assert_contains "$out" '&lt;!-- dev-flow:end:deferred-findings --&gt;'

echo "==> marker-like text in a finding's evidence cannot forge a section boundary"
marker_record="${test_tmp}/marker-forgery"
mkdir -p "$marker_record"
cp -r "${record_dir}/." "$marker_record/"
node -e "
const fs = require('fs');
const p = '${marker_record}/passes/review-r2-codex-cli.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
envelope.payload.findings[2].evidence += ' <!-- dev-flow:end:deferred-findings -->';
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run deferred-findings --record "$marker_record"
assert_rc 0
[[ "$out" != *'<!-- dev-flow:end:deferred-findings -->'* ]] ||
    fail "a finding's own evidence text must never reproduce a literal marker token: $out"
assert_contains "$out" '&lt;!-- dev-flow:end:deferred-findings --&gt;'

echo "==> a credential in a finding's evidence is redacted, never posted in the clear"
# The test secret is built by runtime concatenation on both the JS and bash
# sides — never written as one contiguous literal in this file's own source
# — so this test file itself does not also trip the repo's OWN Semgrep
# AWS-key-shape rule when CI scans it; the RUNTIME value written into the
# fixture and rendered by the script under test is unaffected, which is
# what gitleaks --pipe actually scans.
secret_record="${test_tmp}/secret-in-evidence"
mkdir -p "$secret_record"
cp -r "${record_dir}/." "$secret_record/"
node -e "
const fs = require('fs');
const p = '${secret_record}/passes/review-r2-codex-cli.json';
const envelope = JSON.parse(fs.readFileSync(p, 'utf8'));
const secretValue = 'AKIA' + 'QZJXK2VN8T5WYHRM';
envelope.payload.findings[2].evidence += ' aws_key = \"' + secretValue + '\"';
fs.writeFileSync(p, JSON.stringify(envelope, null, 2));
"
run deferred-findings --record "$secret_record"
assert_rc 0
secret_value="AKIA""QZJXK2VN8T5WYHRM"
[[ "$out" != *"$secret_value"* ]] ||
    fail "a detected credential must never reach rendered output in the clear: $out"
assert_contains "$out" '[REDACTED:generic-api-key]'

echo "==> usage: a negative --max-retries is rejected before any gh call"
run publish --record "$record_dir" --repo o/r --pr 1 --head "1111111111111111111111111111111111111111" \
    --sections policy-disclosure --max-retries -1
assert_rc 2

# ── usage / validation errors ───────────────────────────────────────────

echo "==> usage: unknown projection exits 2"
run bogus-projection --record "$record_dir"
assert_rc 2

echo "==> usage: missing --record exits 2"
run deferred-findings
assert_rc 2

echo "==> usage: --record pointing at a non-directory exits 2"
: >"${test_tmp}/not-a-dir"
run deferred-findings --record "${test_tmp}/not-a-dir"
assert_rc 2

echo "==> usage: round-table on a multi-round record with no --stage/--round is a reported error, not a guess"
run round-table --record "$record_dir"
assert_rc 1
assert_contains "$err" "--stage and --round"

echo "==> usage: publish without --sections exits 2"
run publish --record "$record_dir" --repo o/r --pr 1 --head "1111111111111111111111111111111111111111"
assert_rc 2

echo "==> usage: publish rejects a non-publishable section"
run publish --record "$record_dir" --repo o/r --pr 1 --head "1111111111111111111111111111111111111111" --sections round-table
assert_rc 2

echo "==> schema validation: a malformed run.json is rejected before any rendering"
mkdir -p "${test_tmp}/bad-run"
cat >"${test_tmp}/bad-run/run.json" <<'JSON'
{"schema":2,"run_id":"x","initiated_by":"human","started_at":"2026-01-01T00:00:00Z","stage_transitions":[{"stage":"kickoff","entered_at":"2026-01-01T00:00:00Z"}],"interventions":[],"outcome":null,"pr":null,"evidence_comments":[],"settlements":[]}
JSON
run readiness-input --record "${test_tmp}/bad-run"
assert_rc 1
assert_contains "$err" "run.schema.json"

echo "==> schema validation: a malformed adjudication document is rejected before rendering, naming the file"
mkdir -p "${test_tmp}/bad-adjudication/adjudications"
cat >"${test_tmp}/bad-adjudication/adjudications/bad.json" <<'JSON'
{"schema":2,"run_id":"x","stage":"review","round":1,"reviewed_head":"not-a-sha","adjudications":[]}
JSON
run deferred-findings --record "${test_tmp}/bad-adjudication"
assert_rc 1
assert_contains "$err" "adjudication.schema.json"

echo "render-dev-flow.mjs (projections + validation): PASS"

# ── publish: fake gh on PATH, no network ────────────────────────────────
# One shim, one live pointer: $GH_FIXTURES/current-view.json is the whole
# simulated PR state. `pr view` reads it verbatim; `pr edit` replaces its
# body with stdin, then a test-set hook file can mutate the state further
# (inject a concurrent edit, simulate a crash) before returning. This avoids
# the fragility of a call-count-indexed fixture sequence, where a test that
# reads the PR a different number of times than expected silently falls back
# to stale data instead of failing loudly.
#
# jq --rawfile (never --arg "$(cat ...)") is load-bearing throughout: command
# substitution strips trailing newlines, which would make every fingerprint
# comparison below fail for a reason that has nothing to do with the code
# under test.

bin_dir="${test_tmp}/bin"
gh_fixtures="${test_tmp}/gh-fixtures"
gh_log="${test_tmp}/gh.log"
mkdir -p "$bin_dir"

# install_standard_gh — `pr view` reads the live current-view.json pointer;
# `pr edit` replaces its body with stdin, optionally injecting one
# concurrent-edit hook or a post-write crash, and rewrites the pointer.
install_standard_gh() {
    cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    cat "$GH_FIXTURES/current-view.json"
    exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = edit ]; then
    cat >"$GH_FIXTURES/written-body.txt"
    body="$GH_FIXTURES/written-body.txt"
    if [ -f "$GH_FIXTURES/concurrent-edit-once" ] && [ ! -f "$GH_FIXTURES/concurrent-edit-done" ]; then
        printf '\n\nHuman note added mid-write.\n' >>"$body"
        : >"$GH_FIXTURES/concurrent-edit-done"
    fi
    is_draft=true
    [ ! -f "$GH_FIXTURES/promote-after-write" ] || is_draft=false
    state=OPEN
    [ ! -f "$GH_FIXTURES/close-after-write" ] || state=CLOSED
    jq -n --rawfile body "$body" --arg head "$(cat "$GH_FIXTURES/current-head")" --argjson draft "$is_draft" --arg state "$state" \
        '{number: 123, url: "https://example/pull/123", headRefOid: $head, isDraft: $draft, body: $body, state: $state}' \
        >"$GH_FIXTURES/current-view.json"
    if [ -f "$GH_FIXTURES/crash-after-write" ]; then
        echo "simulated crash after the write landed" >&2
        exit 1
    fi
    exit 0
fi
echo "unhandled: $*" >&2
exit 99
STUB
    chmod +x "${bin_dir}/gh"
}

install_standard_gh
export PATH="${bin_dir}:$PATH"
export GH_LOG="$gh_log"
export GH_FIXTURES="$gh_fixtures"

head_sha="3333333333333333333333333333333333333333"

reset_gh_fixtures() {
    rm -rf "$gh_fixtures"
    mkdir -p "$gh_fixtures"
    printf '%s\n' "$head_sha" >"${gh_fixtures}/current-head"
    : >"$gh_log"
}

# seed_view BODY [IS_DRAFT] [HEAD] — write the live PR-state pointer directly.
seed_view() {
    local body="$1" is_draft="${2:-true}" head="${3:-$head_sha}" state="${4:-OPEN}"
    printf '%s' "$body" | jq -Rs --arg head "$head" --argjson draft "$is_draft" --arg state "$state" \
        '{number: 123, url: "https://example/pull/123", headRefOid: $head, isDraft: $draft, body: ., state: $state}' \
        >"${gh_fixtures}/current-view.json"
}

fresh_record() {
    local dir="${test_tmp}/pub-record-$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -r "${record_dir}/." "$dir/"
    printf '%s' "$dir"
}

current_view_body() {
    node -e "console.log(JSON.parse(require('fs').readFileSync('${gh_fixtures}/current-view.json','utf8')).body)"
}

echo "==> publish: first write appends every requested section and verifies via re-read"
reset_gh_fixtures
seed_view 'What/why prose.

More body text.
'
pub_record="$(fresh_record 1)"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" \
    --sections policy-disclosure,deferred-findings,adjudication-record
assert_rc 0
assert_contains "$out" '"status": "published"'
assert_contains "$out" '"changed": true'
assert_contains "$out" '"attempts": 1'
assert_contains "$(current_view_body)" '<!-- dev-flow:begin:policy-disclosure -->'
assert_contains "$(current_view_body)" 'What/why prose.'
[ ! -f "${pub_record}/.publish-state.json" ] || fail "reservation must be retired after a verified write"

echo "==> publish: idempotent resume — unchanged inputs against the already-published body is a no-op"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" \
    --sections policy-disclosure,deferred-findings,adjudication-record
assert_rc 0
assert_contains "$out" '"changed": false'
gh_calls="$(wc -l <"$gh_log" | tr -d ' ')"
[ "$gh_calls" = 1 ] || fail "a no-op resume should make exactly one gh call (the read), got $gh_calls: $(cat "$gh_log")"

echo "==> publish: a concurrent human edit during the write window is repaired from a fresh read"
reset_gh_fixtures
seed_view 'Human prose stays untouched.
'
: >"${gh_fixtures}/concurrent-edit-once"
pub_record="$(fresh_record 2)"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 0
assert_contains "$out" '"changed": true'
assert_contains "$out" '"attempts": 2'
final_body="$(current_view_body)"
assert_contains "$final_body" 'Human note added mid-write.'
assert_contains "$final_body" 'Human prose stays untouched.'
assert_contains "$final_body" '<!-- dev-flow:begin:policy-disclosure -->'
[ ! -f "${pub_record}/.publish-state.json" ] || fail "reservation must be retired once the repair round verifies"

echo "==> publish: a promotion landing during the write is a blocker, not a reported success"
# Codex challenge round 1, finding "Recheck draft state after publishing the
# body": the write can land on a PR another actor promoted out of draft
# between publish's initial read and its gh pr edit call; the post-write
# verification read must catch that rather than reporting success because
# only headRefOid/body were re-checked.
reset_gh_fixtures
seed_view 'Prose.
'
: >"${gh_fixtures}/promote-after-write"
pub_record="$(fresh_record 8)"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"status": "blocker"'
assert_contains "$out" '"reason": "promoted-during-publish"'
[ -f "${pub_record}/.publish-state.json" ] ||
    fail "a promotion mid-write must retain the reservation — the write landed but the transaction did not verify clean"
rm -f "${gh_fixtures}/promote-after-write"

echo "==> publish: interruption after a landed write, before local success is recorded, resumes without duplicating"
reset_gh_fixtures
seed_view 'Prose before any publish.
'
: >"${gh_fixtures}/crash-after-write"
pub_record="$(fresh_record 3)"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"status": "blocker"'
assert_contains "$out" '"reason": "gh-failed"'
[ -f "${pub_record}/.publish-state.json" ] ||
    fail "an interrupted write must keep its reservation so a resume can adopt the landed write"
landed_body="$(current_view_body)"
assert_contains "$landed_body" '<!-- dev-flow:begin:policy-disclosure -->'
rm -f "${gh_fixtures}/crash-after-write"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 0
assert_contains "$out" '"changed": false'
[ "$(grep -c 'pr edit' "$gh_log" || true)" = 0 ] || fail "resume must not re-write an already-landed section"
[ ! -f "${pub_record}/.publish-state.json" ] || fail "reservation must be retired once the resume verifies"

echo "==> publish: bounded retry exhaustion reports a blocker and keeps the reservation for a later retry"
# A single clobber converges on the NEXT attempt's fresh read — whatever
# landed becomes "current content" and is preserved verbatim, same as the
# concurrent-edit-once case above. Modeling a conflict the bounded retry
# cannot outlast needs a reverting adversary: `pr view` always answers with
# the frozen original body no matter what `pr edit` just wrote, so every
# attempt's fresh read recomputes the identical intended body, writes it,
# and rereads the still-unwritten original — mismatching forever.
reset_gh_fixtures
seed_view 'Prose.
'
cp "${gh_fixtures}/current-view.json" "${gh_fixtures}/frozen-view.json"
cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    cat "$GH_FIXTURES/frozen-view.json"
    exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = edit ]; then
    cat >"$GH_FIXTURES/written-body.txt"
    exit 0
fi
echo "unhandled: $*" >&2
exit 99
STUB
chmod +x "${bin_dir}/gh"
pub_record="$(fresh_record 4)"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" \
    --sections policy-disclosure --max-retries 2
assert_rc 1
assert_contains "$out" '"status": "blocker"'
assert_contains "$out" '"reason": "retry-exhausted"'
assert_contains "$out" '"attempts": 3'
[ -f "${pub_record}/.publish-state.json" ] || fail "an exhausted retry must retain its reservation for a later attempt"

install_standard_gh # the frozen-view shim above was single-purpose

echo "==> publish: a PR at the wrong head is a blocker, no write attempted"
reset_gh_fixtures
seed_view 'Prose.
'
pub_record="$(fresh_record 5)"
run publish --record "$pub_record" --repo owner/repo --pr 123 \
    --head "0000000000000000000000000000000000000000" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "head-mismatch"'
[ "$(grep -c 'pr edit' "$gh_log" || true)" = 0 ] || fail "a head mismatch must never attempt a write"

echo "==> publish: a non-draft PR is a blocker, no write attempted"
reset_gh_fixtures
seed_view 'Prose.
' false
pub_record="$(fresh_record 6)"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "not-draft"'
[ "$(grep -c 'pr edit' "$gh_log" || true)" = 0 ] || fail "a non-draft PR must never attempt a write"

echo "==> publish: run.json naming a different PR is a blocker, no write attempted"
reset_gh_fixtures
seed_view 'Prose.
'
pub_record="$(fresh_record 9)"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 999 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "pr-mismatch"'
[ "$(grep -c 'pr view\|pr edit' "$gh_log" || true)" = 0 ] || fail "a run/PR mismatch must be caught before any gh call"

echo "==> publish: an unparseable run.json PR URL blocks rather than silently skipping the check"
reset_gh_fixtures
seed_view 'Prose.
'
pub_record="$(fresh_record 11)"
node -e "
const fs = require('fs');
const p = '${pub_record}/run.json';
const run = JSON.parse(fs.readFileSync(p, 'utf8'));
run.pr.url = 'not-a-github-url';
fs.writeFileSync(p, JSON.stringify(run, null, 2));
"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "pr-mismatch"'
[ "$(grep -c 'pr view\|pr edit' "$gh_log" || true)" = 0 ] || fail "an unparseable PR URL must be caught before any gh call"

echo "==> publish: a second concurrent publish against the same record directory is a blocker, not a race"
reset_gh_fixtures
seed_view 'Prose.
'
pub_record="$(fresh_record 10)"
: >"${pub_record}/.publish-lock"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "concurrent-publish"'
[ "$(wc -l <"$gh_log" | tr -d ' ')" = 0 ] || fail "a held lock must be checked before any gh call"
rm -f "${pub_record}/.publish-lock"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 0
[ ! -f "${pub_record}/.publish-lock" ] || fail "the lock must be released once the call completes"

echo "==> publish: appending a section preserves the existing body's own trailing newlines exactly"
reset_gh_fixtures
seed_view 'Trailing blank lines follow.



'
pub_record="$(fresh_record 12)"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 0
preserved_prefix="$(current_view_body | sed -n '/<!-- dev-flow:begin/q;p')"
expected_prefix="$(printf 'Trailing blank lines follow.\n\n\n\n')"
[ "$preserved_prefix" = "$expected_prefix" ] ||
    fail "existing trailing newlines must survive byte-for-byte, got: $(printf '%s' "$preserved_prefix" | cat -A)"

echo "==> publish: malformed markers (mismatched begin/end) are a blocker, not a guess"
reset_gh_fixtures
seed_view 'Prose.

<!-- dev-flow:begin:policy-disclosure -->
stale content, no matching end marker
'
pub_record="$(fresh_record 7)"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "malformed-markers"'
[ "$(grep -c 'pr edit' "$gh_log" || true)" = 0 ] || fail "malformed markers must never attempt a write"

echo "==> publish: a section's markers nested inside another section's are a blocker, never a silent deletion"
reset_gh_fixtures
seed_view 'Prose.

<!-- dev-flow:begin:policy-disclosure -->
old policy text
<!-- dev-flow:begin:deferred-findings -->
- [ ] an open task that must survive
<!-- dev-flow:end:deferred-findings -->
<!-- dev-flow:end:policy-disclosure -->
'
pub_record="$(fresh_record 15)"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "malformed-markers"'
assert_contains "$out" 'nested inside'
[ "$(grep -c 'pr edit' "$gh_log" || true)" = 0 ] || fail "nested markers must never attempt a write"

echo "==> publish: a closed PR is a blocker, no write attempted"
reset_gh_fixtures
seed_view 'Prose.
' true "$head_sha" CLOSED
pub_record="$(fresh_record 16)"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "not-open"'
[ "$(grep -c 'pr edit' "$gh_log" || true)" = 0 ] || fail "a closed PR must never attempt a write"

echo "==> publish: a PR closed during the write window is a blocker, not a reported success"
reset_gh_fixtures
seed_view 'Prose.
'
: >"${gh_fixtures}/close-after-write"
pub_record="$(fresh_record 17)"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "closed-during-publish"'

echo "==> publish: run.json's PR URL number disagreeing with its own pr.number is a blocker, no write attempted"
reset_gh_fixtures
seed_view 'Prose.
'
pub_record="$(fresh_record 13)"
node -e "
const fs = require('fs');
const p = '${pub_record}/run.json';
const run = JSON.parse(fs.readFileSync(p, 'utf8'));
run.pr.url = 'https://github.com/owner/repo/pull/999';
fs.writeFileSync(p, JSON.stringify(run, null, 2));
"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections policy-disclosure
assert_rc 1
assert_contains "$out" '"reason": "pr-mismatch"'
[ "$(grep -c 'pr view\|pr edit' "$gh_log" || true)" = 0 ] ||
    fail "a URL/number mismatch inside run.json must be caught before any gh call"

echo "==> publish: a section renderer's fail() mid-render still releases the lock (process.exit skips finally)"
reset_gh_fixtures
seed_view 'Prose.
'
pub_record="$(fresh_record 14)"
rm "${pub_record}/passes/review-r2-codex-cli.json"
: >"$gh_log"
run publish --record "$pub_record" --repo owner/repo --pr 123 --head "$head_sha" --sections deferred-findings
assert_rc 1
assert_contains "$err" "no matching pass supplied"
[ ! -f "${pub_record}/.publish-lock" ] ||
    fail "a fail()-triggered process.exit mid-render must not leave the lock behind"

echo "render-dev-flow.mjs publish (fake gh, no network): PASS"
