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

echo "==> thread-reply-plan carries only unanswered integration-stage inline threads"
entry_count="$(node -e "console.log(JSON.parse(require('fs').readFileSync('${golden_dir}/thread-reply-plan.json','utf8')).entries.length)")"
[ "$entry_count" = 1 ] || fail "expected 1 unanswered-thread entry (the fixture pass answers the other two), got $entry_count"
entry="$(node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('${golden_dir}/thread-reply-plan.json','utf8')).entries[0]))")"
for field in root_comment_id reply_text head adjudicated_priority classification evidence action; do
    assert_contains "$entry" "\"$field\""
done

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

echo "==> cross-document consistency: two files claiming the same round are rejected"
dup_round="${test_tmp}/duplicate-round"
mkdir -p "$dup_round"
cp -r "${record_dir}/." "$dup_round/"
cp "${record_dir}/adjudications/challenge-r1.json" "${dup_round}/adjudications/challenge-r1-copy.json"
run deferred-findings --record "$dup_round"
assert_rc 1
assert_contains "$err" "is already claimed by"

echo "==> cross-document consistency: a duplicate finding id across DIFFERENT rounds is rejected"
dup_finding="${test_tmp}/duplicate-finding-id"
mkdir -p "$dup_finding"
cp -r "${record_dir}/." "$dup_finding/"
node -e "
const fs = require('fs');
const p = '${dup_finding}/adjudications/review-r2.json';
const doc = JSON.parse(fs.readFileSync(p, 'utf8'));
const dupe = JSON.parse(fs.readFileSync('${record_dir}/adjudications/challenge-r1.json', 'utf8')).adjudications[0];
doc.adjudications.push(dupe);
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

echo "==> verdict.json / policy.json shapes are validated, not just parsed as JSON"
bad_verdict="${test_tmp}/bad-verdict.json"
echo '{"outcome": 42}' >"$bad_verdict"
run round-table --record "$record_dir" --stage review --round 2 --verdict "$bad_verdict"
assert_rc 1
assert_contains "$err" "outcome must be a non-empty string"

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
assert_contains "$err" "rounds.challenge, if present, must be a non-negative integer"

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
    jq -n --rawfile body "$body" --arg head "$(cat "$GH_FIXTURES/current-head")" --argjson draft "$is_draft" \
        '{number: 123, url: "https://example/pull/123", headRefOid: $head, isDraft: $draft, body: $body}' \
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
    local body="$1" is_draft="${2:-true}" head="${3:-$head_sha}"
    printf '%s' "$body" | jq -Rs --arg head "$head" --argjson draft "$is_draft" \
        '{number: 123, url: "https://example/pull/123", headRefOid: $head, isDraft: $draft, body: .}' \
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

echo "render-dev-flow.mjs publish (fake gh, no network): PASS"
