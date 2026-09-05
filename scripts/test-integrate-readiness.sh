#!/usr/bin/env bash
# Hermetic regression tests for the integration-stage readiness gate and the
# read-only gh wrapper (ai/skills/universal/integrate/assets/readiness-gate.sh,
# gh-ro.sh) — formerly the shepherd stage's; renamed with the stage, see
# specs/dev-flow-v2.md.
#
# The point of the gate is that no condition can be printed-and-promoted past:
# every fixture below asserts an exit code AND the machine token naming the
# decisive condition, and the full-pass fixture asserts the fingerprint is
# printed and stable. gh is stubbed on PATH; nothing talks to the network.
#
# The gate is NOT fully hermetic any more: it resolves scripts/render-dev-
# flow.sh and scripts/validate-result-schemas.mjs from the checkout's own
# `git rev-parse --show-toplevel`, so those two run for REAL against the
# record/integrator-result fixtures this file builds, rather than being
# stubbed. That is deliberate — it proves the integration, not just that the
# gate calls the right command name — and it is why `gate` below is called
# directly from its real path rather than a copied sibling: there is no more
# sibling-helper resolution left to control by copying.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assets="${repo_root}/ai/skills/universal/integrate/assets"
gate="${assets}/readiness-gate.sh"
ghro="${assets}/gh-ro.sh"
ghwb="${assets}/gh-write-broker.sh"
validator="${repo_root}/scripts/validate-result-schemas.mjs"
test_tmp="$(mktemp -d -t integrate-readiness-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

bin_dir="${test_tmp}/bin"
fixtures="${test_tmp}/fixtures"
record_dir="${test_tmp}/record"
log="${test_tmp}/gh.log"
mkdir -p "$bin_dir" "$fixtures" "$record_dir/adjudications"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Watchdog for gate invocations, same idiom as test-integrate-codex.sh: a
# fired watchdog means the helper hung, which is a distinct failure from any
# assertion below.
watchdog_bin=
if command -v timeout >/dev/null 2>&1; then
    watchdog_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    watchdog_bin=gtimeout
else
    fail "GNU timeout is required for the test suite's hang watchdog (coreutils; gtimeout on macOS)"
fi
watchdog_sec=120

check_watchdog() {
    rc=$1
    label=$2
    output=$3
    [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] ||
        fail "$label: watchdog fired after ${watchdog_sec}s — genuinely hung, not an assertion mismatch: $output"
}

cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"

# gh-ro pass-through cases: exit with a scripted code so propagation is
# observable without any endpoint dispatch.
if [ -f "$GH_FIXTURES/ro-exit" ]; then
    exit "$(cat "$GH_FIXTURES/ro-exit")"
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    count_file="$GH_FIXTURES/pr-view-count"
    count=0
    [ ! -f "$count_file" ] || count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -ge 2 ] && [ -f "$GH_FIXTURES/pr-view-second.json" ]; then
        cat "$GH_FIXTURES/pr-view-second.json"
    else
        cat "$GH_FIXTURES/pr-view.json"
    fi
    exit 0
fi

[ "${1:-}" = api ] || exit 90
shift
endpoint=
skip_next=0
for arg in "$@"; do
    if [ "$skip_next" = 1 ]; then
        skip_next=0
        continue
    fi
    case "$arg" in
    --paginate | --slurp) ;;
    --method | -F | -f | --jq | -q) skip_next=1 ;;
    *) [ -n "$endpoint" ] || endpoint=$arg ;;
    esac
done
[ -n "$endpoint" ] || exit 91

if [ -f "$GH_FIXTURES/fail-endpoint" ] &&
    grep -Fq "$(cat "$GH_FIXTURES/fail-endpoint")" <<<"$endpoint"; then
    exit 92
fi

case "$endpoint" in
user) file=user.json ;;
graphql) file=threads.pages.json ;;
repos/*/pulls/*/comments*) file=inline.pages.json ;;
repos/*/pulls/*/reviews*) file=reviews.pages.json ;;
repos/*/issues/*/comments*) file=top.pages.json ;;
repos/*/commits/*/check-runs*) file=check-runs.pages.json ;;
repos/*/commits/*/statuses*) file=statuses.pages.json ;;
repos/*/actions/runs*) file=workflow-runs.pages.json ;;
repos/*/pulls/*) file=pr.json ;;
*) exit 93 ;;
esac
# The gate re-reads several surfaces before its verdict (checks twice, and
# every fingerprint surface once evaluated + once fresh); a second-<fixture>
# file, when present, is what the LATER fetches of that fixture see.
if [ -f "$GH_FIXTURES/second-$file" ]; then
    count_file="$GH_FIXTURES/count-$file"
    count=0
    [ ! -f "$count_file" ] || count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -ge 2 ]; then
        file="second-$file"
    fi
fi
cat "$GH_FIXTURES/$file"
STUB
chmod +x "${bin_dir}/gh"

export PATH="${bin_dir}:$PATH"
export GH_FIXTURES="$fixtures"
export GH_LOG="$log"

head_sha="1111111111111111111111111111111111111111"
# A second, distinct full SHA for the fixtures that need one head to disagree
# with another (harmon-devkit#685's promotion-head binding).
stale_head_sha="2222222222222222222222222222222222222222"
moved_sha="2222222222222222222222222222222222222222"

default_body() {
    cat <<'BODY'
What/why prose.

## Verification

- task verify
BODY
}

# A minimal valid run.json (ai/schemas/run.schema.json) with no findings at
# all — zero adjudications means readiness-input's finding index has nothing
# disposition:"defer" to report, so deferred_findings.{settled,unsettled} are
# always [] against it. This is the default record for every test that is
# not itself about deferred-finding settlement.
write_default_record() {
    jq -cn --arg head "$head_sha" '
      {schema:2, run_id:"test-run", initiated_by:"human",
       started_at:"2026-01-01T00:00:00Z",
       stage_transitions:[{stage:"integration",entered_at:"2026-01-01T00:00:00Z"}],
       interventions:[], outcome:null,
       pr:{number:493,url:"https://github.com/example/repo/pull/493"},
       evidence_comments:[], settlements:[], promotion:null,
       evidence_registrations:[], outcome_transitions:[],
       pr_bindings:[{seq:0,prev_digest:"genesis",
         digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
         number:493,url:"https://github.com/example/repo/pull/493",
         bound_at:"2026-01-01T00:00:00Z"}]}' \
        >"${record_dir}/run.json"
    rm -f "${record_dir}"/adjudications/*.json
}

# A schema-valid result.envelope (role integrator) at
# ${fixtures}/integrator-result-<name>.json. $2 is the codex_cycle sub-object
# (or the literal string "null"); $3 overrides the head baked into the
# envelope/codex_cycle/accepted (defaults to $head_sha) so a head-mismatch
# fixture can be built without hand-editing JSON.
write_integrator_result() {
    local name="$1" codex_cycle="$2" head="${3:-$head_sha}"
    local out="${fixtures}/integrator-result-${name}.json"
    # verdict is constrained against codex_cycle.exit_code by
    # validate-result-schemas.mjs's EXIT_CODE_VERDICT_CONSTRAINTS (0->clean,
    # 10->findings, 11|12->pending, 13|2->escalate); the gate's own step 9c
    # additionally requires status:"completed" and verdict:"clean" of the
    # gated pass, after the codex_cycle/findings checks, so a non-clean
    # fixture that gets past those still fails there. A null codex_cycle
    # (cap 0) takes the same "clean" path as exit_code 0.
    local exit_code
    exit_code="$(jq -r '.exit_code // "null"' <<<"$codex_cycle")"
    local verdict findings='[]' checks='[]'
    case "$exit_code" in
    null | 0)
        verdict=clean
        checks='[{"name":"build","bucket":"pass","run_id":"1","required":true}]'
        ;;
    10)
        verdict=findings
        findings='[{"id":"integration-r1-codex-cloud-1","body":"a finding","source_id":"1"}]'
        ;;
    11 | 12) verdict=pending ;;
    13 | 2) verdict=escalate ;;
    *) verdict=pending ;;
    esac
    jq -cn --arg head "$head" --argjson codex_cycle "$codex_cycle" \
        --argjson checks "$checks" --argjson findings "$findings" \
        --arg verdict "$verdict" '
      {schema:2, role:"integrator", status:"completed", head:$head,
       produced_at:"2026-01-01T00:00:00Z",
       producer:{harness:"claude-code",model:"test",tier:"economy"},
       run:{run_id:"test-run",initiated_by:"human"},
       payload:({checks:$checks, codex_cycle:$codex_cycle, integration_round:1,
                 findings:$findings, unanswered_thread_roots:[],
                 settled_at:"2026-01-01T00:00:00Z", verdict:$verdict}
         + (if $verdict == "clean" then {applied_dispositions:[]} else {} end))}' \
        >"$out"
    node "$validator" envelope "$out" >/dev/null ||
        fail "write_integrator_result $name: fixture failed schema validation"
    printf '%s' "$out"
}

# codex_cycle with exit_code 0 requires `accepted` (schema: required exactly
# when exit_code is 0 or 10); everything else omits it.
codex_cycle_json() {
    local exit_code="$1" head="${2:-$head_sha}"
    case "$exit_code" in
    0 | 10)
        jq -cn --arg head "$head" --argjson exit_code "$exit_code" \
            '{head:$head, cycle:1, attempt:1, trigger_comment_id:"1",
              accepted:{surface:"review", id:"1", reviewed_commit:$head},
              exit_code:$exit_code}'
        ;;
    *)
        jq -cn --arg head "$head" --argjson exit_code "$exit_code" \
            '{head:$head, cycle:1, attempt:1, trigger_comment_id:"1",
              exit_code:$exit_code}'
        ;;
    esac
}

write_defaults() {
    jq -cn --arg head "$head_sha" \
        '{state:"OPEN",isDraft:true,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
          headRefName:"feature-branch"}' \
        >"${fixtures}/pr-view.json"
    jq -cn --arg head "$head_sha" --arg body "$(default_body)" \
        '{number:493,title:"feat: change",body:$body,
          head:{sha:$head},user:{id:4242,login:"pr-author"}}' \
        >"${fixtures}/pr.json"
    # One completed-success run, one skipped (neutral) run.
    jq -cn '[{total_count:2,check_runs:[
        {name:"build",status:"completed",conclusion:"success"},
        {name:"optional",status:"completed",conclusion:"skipped"}]}]' \
        >"${fixtures}/check-runs.pages.json"
    # A context whose OLDER post is pending and NEWER is success: pins that
    # the gate reads only the latest status per context.
    jq -cn '[[{context:"ci/legacy",state:"pending",id:1},
              {context:"ci/legacy",state:"success",id:3}]]' \
        >"${fixtures}/statuses.pages.json"
    # No GitHub Actions workflow runs for this head by default: check runs
    # with no matching check_suite_id fall back to their app id (harmon-devkit#714).
    printf '%s\n' '[{"total_count":0,"workflow_runs":[]}]' \
        >"${fixtures}/workflow-runs.pages.json"
    jq -cn '{login:"pr-author"}' >"${fixtures}/user.json"
    printf '%s\n' '[[]]' >"${fixtures}/inline.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/reviews.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/top.pages.json"
    printf '%s\n' \
        '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"T1","isResolved":false}]}}}}}]' \
        >"${fixtures}/threads.pages.json"
    rm -f "${fixtures}/fail-endpoint"
    rm -f "${fixtures}/pr-view-count" "${fixtures}/pr-view-second.json"
    rm -f "${fixtures}"/count-* "${fixtures}"/second-*
    rm -f "${fixtures}/ro-exit"
    : >"$log"
    write_default_record
    write_integrator_result disabled null >/dev/null
}

# Both --record and --integrator-result are baked in here as the default
# (cap-0-equivalent, clean) case; a test that needs a different record or
# integrator result appends its own "$@" override — the gate's flag parser
# overwrites on repeat, so the last occurrence of either flag wins.
run_gate() {
    set +e
    gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" check \
        --repo example/repo --pr 493 --head "$head_sha" \
        --record "$record_dir" \
        --integrator-result "${fixtures}/integrator-result-disabled.json" \
        --integration-cap 0 \
        "$@" 2>&1)"
    gate_rc=$?
    set -e
    check_watchdog "$gate_rc" run_gate "$gate_out"
}

run_audit() {
    set +e
    gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" audit \
        --repo example/repo --pr 493 --head "$head_sha" \
        --record "$record_dir" \
        --integrator-result "${fixtures}/integrator-result-disabled.json" \
        --integration-cap 0 \
        "$@" 2>&1)"
    gate_rc=$?
    set -e
    check_watchdog "$gate_rc" run_audit "$gate_out"
}

# --codex-recheck's target is resolved as readiness-gate.sh's own sibling
# (script_dir/check-codex-cloud-review.sh), so proving a clean recheck
# actually unblocks the gate means giving it a REAL sibling — a copy of the
# gate beside a fake checker stub scripted via $RECHECK_FAKE_EXIT — rather
# than driving the real checker's full GitHub call sequence end to end
# (scripts/test-integrate-codex.sh owns that coverage; this file only proves
# the wiring). The stub is #!/bin/sh with no external calls, so it execs
# correctly even under the restricted-PATH fixture further down.
recheck_dir="${test_tmp}/recheck-gate"
mkdir -p "$recheck_dir"
cp "$gate" "${recheck_dir}/readiness-gate.sh"
chmod +x "${recheck_dir}/readiness-gate.sh"
cat >"${recheck_dir}/check-codex-cloud-review.sh" <<'STUB'
#!/bin/sh
exit "${RECHECK_FAKE_EXIT:-0}"
STUB
chmod +x "${recheck_dir}/check-codex-cloud-review.sh"
recheck_gate="${recheck_dir}/readiness-gate.sh"

# recheck_codex_freshness checks repo/pr/head against the gate's own before
# ever invoking the checker, so these three fields are the only ones that
# matter here — a real check-codex-cloud-review.sh state file carries much
# more (phase, trigger, timestamps), but the fake stub above never reads it.
recheck_state="${fixtures}/codex-recheck-state.json"
jq -cn --arg repo example/repo --argjson pr 493 --arg head "$head_sha" \
    '{repo:$repo, pr:$pr, head:$head}' >"$recheck_state"

# Runs $recheck_gate (the copy with the fake checker sibling) in place of the
# real gate for exactly one run_gate call, with the fake checker scripted to
# exit clean — for the handful of "codex_cycle exit_code 0" tests elsewhere
# in this file that need --codex-recheck to actually confirm freshness
# rather than merely be present.
run_gate_recheck_clean() {
    local saved_gate="$gate"
    gate="$recheck_gate"
    export RECHECK_FAKE_EXIT=0
    run_gate --codex-recheck "$recheck_state" "$@"
    unset RECHECK_FAKE_EXIT
    gate="$saved_gate"
}

# The gate emits its verdict as the final line; earlier lines are incidental
# stderr from the tools it drives.
gate_field() {
    printf '%s\n' "$gate_out" | tail -n 1 | jq -r --arg f "$1" '.[$f]'
}

assert_gate() {
    expected_rc=$1
    expected_status=$2
    expected_condition=$3
    [ "$gate_rc" -eq "$expected_rc" ] ||
        fail "expected rc $expected_rc, got $gate_rc: $gate_out"
    actual_status="$(gate_field status 2>/dev/null || true)"
    [ "$actual_status" = "$expected_status" ] ||
        fail "expected status $expected_status, got '$actual_status': $gate_out"
    actual_condition="$(gate_field condition 2>/dev/null || true)"
    [ "$actual_condition" = "$expected_condition" ] ||
        fail "expected condition $expected_condition, got '$actual_condition': $gate_out"
}

echo "==> full pass (Codex cycle terminal-clean) prints a fingerprint, stable across two runs on identical data"
write_defaults
clean_result="$(write_integrator_result clean "$(codex_cycle_json 0)")"
run_gate_recheck_clean --integrator-result "$clean_result" --integration-cap 1
assert_gate 0 pass ready
first_fingerprint="$(gate_field fingerprint)"
[ -n "$first_fingerprint" ] && [ "$first_fingerprint" != "null" ] ||
    fail "pass did not print a fingerprint: $gate_out"
rm -f "${fixtures}/pr-view-count"
run_gate_recheck_clean --integrator-result "$clean_result" --integration-cap 1
assert_gate 0 pass ready
second_fingerprint="$(gate_field fingerprint)"
[ "$first_fingerprint" = "$second_fingerprint" ] ||
    fail "fingerprint unstable across identical runs: $first_fingerprint vs $second_fingerprint"

echo "==> the fingerprint subcommand reproduces the pass fingerprint (post-promotion compare)"
set +e
fp_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" fingerprint \
    --repo example/repo --pr 493 2>&1)"
fp_rc=$?
set -e
check_watchdog "$fp_rc" fingerprint "$fp_out"
[ "$fp_rc" -eq 0 ] || fail "fingerprint subcommand failed: $fp_out"
standalone_fingerprint="$(printf '%s\n' "$fp_out" | tail -n 1 | jq -r '.fingerprint')"
[ "$standalone_fingerprint" = "$first_fingerprint" ] ||
    fail "fingerprint subcommand disagrees with check's: $standalone_fingerprint vs $first_fingerprint"

echo "==> BLOCKED mergeStateStatus and REVIEW_REQUIRED are promotable (never require CLEAN)"
# The defaults above already pin BLOCKED + REVIEW_REQUIRED; this case exists
# so a regression toward must-be-CLEAN names itself.
write_defaults
run_gate
assert_gate 0 pass ready

echo "==> a closed PR fails as pr-not-open"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"MERGED",isDraft:false,headRefOid:$head,
      reviewDecision:"",mergeStateStatus:"UNKNOWN",
      headRefName:"feature-branch"}' >"${fixtures}/pr-view.json"
run_gate
assert_gate 1 fail pr-not-open

echo "==> a non-draft PR fails as pr-not-draft"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch"}' \
    >"${fixtures}/pr-view.json"
run_gate
assert_gate 1 fail pr-not-draft

echo "==> a head other than the adjudicated one fails as head-mismatch"
write_defaults
jq -cn --arg head "$moved_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch"}' \
    >"${fixtures}/pr-view.json"
run_gate
assert_gate 1 fail head-mismatch

echo "==> a failing check run fails as checks-failing and names the check"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {name:"build",status:"completed",conclusion:"success"},
    {name:"lint",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'lint' ||
    fail "checks-failing did not name the failing check: $gate_out"

echo "==> a pending (unconcluded) check run fails as checks-pending"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {name:"build",status:"completed",conclusion:"success"},
    {name:"verify",status:"in_progress",conclusion:null}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate
assert_gate 1 fail checks-pending
printf '%s\n' "$gate_out" | grep -Fq 'verify' ||
    fail "checks-pending did not name the pending check: $gate_out"

echo "==> a failing latest legacy status fails as checks-failing"
write_defaults
jq -cn '[[{context:"ci/legacy",state:"success",id:1},
          {context:"ci/legacy",state:"failure",id:3}]]' \
    >"${fixtures}/statuses.pages.json"
run_gate
assert_gate 1 fail checks-failing

echo "==> a multi-MB check-runs payload still classifies (ARG_MAX regression)"
# A much-rerun head accumulates thousands of check runs. Passed to jq through
# argv (`--argjson runs`), that payload exceeds the kernel's per-argument
# limit and jq dies "Argument list too long" — which the gate could only
# report as `malformed-data`, indeterminate for a mechanical reason, on
# exactly the heads it matters most for (harmon-init#821's gate, 2026-08-12).
# The fixture must stay far above the limit for this test to keep reproducing,
# so its size is asserted rather than assumed.
write_defaults
jq -cn '[{total_count:60001,
    check_runs:([range(0;60000) |
        {name:("rerun-" + (. | tostring)),
         status:"completed",conclusion:"success"}] +
        [{name:"lint",status:"completed",conclusion:"failure"}])}]' \
    >"${fixtures}/check-runs.pages.json"
oversized_bytes="$(wc -c <"${fixtures}/check-runs.pages.json")"
[ "$oversized_bytes" -gt 1048576 ] ||
    fail "the ARG_MAX fixture shrank to ${oversized_bytes} bytes — below the per-argument limit it exists to exceed, so it no longer reproduces"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'lint' ||
    fail "the oversized payload was not classified — the failing check went unnamed: $gate_out"

# The downstream twin of the same death: with the classification surviving
# --slurpfile, a payload where the checks FAIL en masse used to join every
# name into the detail string, and emit's `jq --arg detail` put that
# multi-megabyte join back into one argv entry (exit 126). The detail must
# stay bounded — first names plus a count — while still naming real checks.
echo "==> an oversized payload of FAILING checks yields a bounded detail"
write_defaults
jq -cn '[{total_count:60000,
    check_runs:[range(0;60000) |
        {name:("broken-" + (. | tostring)),
         status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'broken-0' ||
    fail "the bounded detail names no failing check: $gate_out"
printf '%s\n' "$gate_out" | grep -Eq 'and 599[0-9]+ more' ||
    fail "the bounded detail does not carry the truncation count: $gate_out"
detail_bytes="$(printf '%s' "$gate_out" | wc -c)"
[ "$detail_bytes" -lt 8192 ] ||
    fail "the failing-checks detail is ${detail_bytes} bytes — unbounded diagnostics reintroduce the argv death one step downstream"

echo "==> a stale failed check suite superseded by a later success passes (harmon-devkit#714)"
# A workflow triggering on pull_request.edited (this repo's guard jobs) starts
# a fresh check suite on every PR-body edit against an unchanged head:
# filter=latest collapses only WITHIN one suite, so an early failure and a
# later success for the same check name both survive as separate check runs.
# The gate must collapse them itself, by workflow identity, and keep the
# later one — "later" by check-run id (delivery order), not started_at,
# which queuing can reorder relative to delivery.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request"},
    {check_suite_id:20,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> a stale PASSING check suite superseded by a later failure still fails (inverse of the above)"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:30}},
    {id:2,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:40}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:30,workflow_id:100,event:"pull_request"},
    {check_suite_id:40,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not name the check whose latest run fails: $gate_out"

echo "==> a suite that started later but was delivered earlier is not mistaken for the latest"
# started_at reflects when a runner picked the job up, not delivery order;
# under queuing an EARLIER delivery (the lower check_suite id) can start
# running AFTER a later one. Suite 80 is still the later delivery even though
# its run started first (00:00 vs suite 70's 00:05) — the gate must trust
# check_suite.id, not started_at, so suite 80's failure is the one that
# counts.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:70}},
    {id:2,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:80}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:70,workflow_id:100,event:"pull_request"},
    {check_suite_id:80,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing

echo "==> two distinct workflows whose jobs share a literal name are kept apart, never suite-broken"
# Same started_at and two different check_suite ids below: collapsing by name
# alone (the pre-#714 bug) feeds group_by a single group, and picking the
# latest suite then keeps whichever suite id is higher regardless of which
# workflow it belongs to — silently hiding this workflow's failure behind the
# other's success. Keyed on workflow identity, the two never share a group,
# so the failure cannot be hidden by which suite happens to sort higher.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:50}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:60}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:50,workflow_id:100,event:"pull_request"},
    {check_suite_id:60,workflow_id:200,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not surface the failing workflow's guard job when a same-named passing job from a different workflow has a higher id: $gate_out"

echo "==> the same workflow answering two different trigger events is kept apart (harmon-devkit#714 round 1)"
# build.yml here runs on pull_request, push, merge_group, AND workflow_dispatch
# alike. A later successful manual dispatch of the same workflow/job name is
# not a supersession of an earlier failed pull_request run — they answer
# different questions on the same commit. The event must be part of the
# collapse key, not just the workflow id.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"verify",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:90}},
    {id:2,name:"verify",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:91}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:90,workflow_id:100,event:"pull_request"},
    {check_suite_id:91,workflow_id:100,event:"workflow_dispatch"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'verify' ||
    fail "checks-failing did not surface the failed pull_request run when a later workflow_dispatch of the same workflow/job succeeded: $gate_out"

echo "==> two jobs in one workflow that render the same name are BOTH kept when they coexist in the latest suite (harmon-devkit#714 round 2)"
# A workflow can define two job blocks that both render as "verify" (a
# hardcoded name:, or a matrix with no differentiating label). Both check
# runs land in the SAME latest suite -- collapsing the whole identity group
# to a single highest-id winner would keep whichever job happened to get the
# higher id and silently drop the other's failure, even though neither
# superseded the other. An OLDER suite's run for the same identity must
# still be dropped as genuinely superseded.
write_defaults
jq -cn '[{total_count:3,check_runs:[
    {id:1,name:"verify",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:100}},
    {id:2,name:"verify",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:200}},
    {id:3,name:"verify",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:200}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:200,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'verify' ||
    fail "checks-failing did not surface the failing sibling job when a same-named passing sibling shares its (latest) suite: $gate_out"

echo "==> a same-sha run scoped to a DIFFERENT PR cannot supersede this PR's failure (harmon-devkit#714 round 3)"
# head_sha alone does not scope to one PR: the same commit can back open PRs
# against more than one base branch, and actions/runs returns every run for
# the sha regardless of which PR it belongs to. A newer, higher-suite-id run
# that is provably for PR 999 (not this gate's PR 493) must not be treated
# as superseding this PR's own failing suite, even though its check_suite id
# sorts higher.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493}]},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not survive when a higher-suite-id run scoped to a different PR shared the same name/workflow/event: $gate_out"

echo "==> an empty pull_requests association still allows the normal collapse (unscoped, as before)"
# GitHub is known to leave pull_requests empty even for a run that genuinely
# belongs to the open PR being gated -- absence must not be read as "wrong
# PR," or every ordinary same-PR case using this shape would wrongly split
# into two identities and both survive as false failures.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",pull_requests:[]},
    {check_suite_id:20,workflow_id:100,event:"pull_request",pull_requests:[]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> a run naming MULTIPLE PRs (a genuinely shared head) cannot clear this PR's own failure (harmon-devkit#714 review r1)"
# GitHub populates pull_requests with EVERY open PR whose head currently
# matches, not the one that triggered the run, so a run listing both 493 and
# 999 does not confidently belong to either -- a same-PR-number membership
# test alone would wrongly treat it as "ours" and let its later success
# supersede this PR's own confidently-scoped failure. It must still be kept
# (dropping it could hide a real failure), just never allowed to collapse
# against a run this gate IS confident belongs to this PR.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493}]},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493},{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not survive when a later run naming multiple PRs (including this one) shared the same name/workflow/event: $gate_out"

echo "==> a failing run that itself names multiple PRs still surfaces (ambiguous is kept, not dropped)"
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493},{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "a failing run naming multiple PRs (including this one) was dropped instead of surfaced: $gate_out"

echo "==> two ambiguous (multi-PR) suites do not clear one another (harmon-devkit#714 review r2)"
# There is no more confident basis for "later ambiguous suite supersedes an
# earlier ambiguous suite" than there was for "supersedes this PR's own
# confidently-scoped run" -- an ambiguous suite's identity must be
# permanently distinct so a later ambiguous success cannot hide an earlier
# ambiguous failure.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493},{number:999}]},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493},{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not survive when a later ambiguous suite's success shared its nominal workflow/event with an earlier ambiguous failure: $gate_out"

echo "==> a failing run unambiguously scoped to another PR is dropped outright, not just its metadata (harmon-devkit#714 review r2)"
# Excluding a run from the workflow lookup alone is not enough: its check
# run must not survive at all, or it falls to the app-id identity and, if
# failing, wrongly fails a PR it was never testing.
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> two different non-Actions apps sharing a check name are never conflated (harmon-devkit#714 review r3)"
# A check run with no actions/runs match falls back to its own app id. Piping
# the suite lookup result into a variable changes jq's current input for
# that branch -- reading .app.id from inside it (instead of capturing the
# outer run's app id first) silently reads the LOOKUP's non-existent app.id
# instead, which is always null, so every non-Actions run collapsed into the
# same "app:0" bucket regardless of which app actually posted it. Two
# different real app ids sharing a check name must stay in separate
# identities, or one app's later success can hide an entirely different
# app's failure.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"lint",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10},app:{id:42}},
    {id:2,name:"lint",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20},app:{id:77}}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'lint' ||
    fail "checks-failing did not survive when a different non-Actions app's later success shared a check name with an earlier failure: $gate_out"

echo "==> a shared head where BOTH PRs get an empty pull_requests is still told apart by branch name (harmon-devkit#714 shepherd, PR #723)"
# GitHub can return an empty pull_requests for a run genuinely triggered by a
# SIBLING PR too, not only for this one -- pull_requests[] membership alone
# then has nothing to compare. head_branch is available at no extra fetch
# cost and, when it does not match this PR's own branch (write_defaults sets
# headRefName to "feature-branch"), is positive evidence the run belongs to
# a different PR even though pull_requests came back empty on both sides.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[],head_branch:"feature-branch"},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[],head_branch:"someone-elses-branch"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not survive when a later run on a DIFFERENT branch (both sides reporting empty pull_requests) shared the same name/workflow/event: $gate_out"

echo "==> a push/workflow_dispatch run on another branch is never excluded by the branch heuristic (harmon-devkit#714 shepherd r2)"
# The branch-mismatch exclusion only makes sense for pull_request-triggered
# runs -- a push or workflow_dispatch run has no PR to belong to at all, so
# judging it against this PR's branch name is a category error. It already
# gets its own distinct identity via `event`, so a later same-named
# pull_request success must not hide an earlier push-triggered failure.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"push",
     pull_requests:[],head_branch:"main"},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[],head_branch:"feature-branch"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not survive a push-triggered failure on an unrelated branch, which the branch heuristic must not exclude: $gate_out"

echo "==> a multi-PR run that OMITS this PR entirely is excluded, not treated as ambiguous (harmon-devkit#714 shepherd r2)"
# A pull_requests list naming two or more OTHER PRs, with this PR's number
# nowhere in it, is just as conclusive as a singleton naming one other PR --
# length alone must not decide ambiguity; whether this PR's number appears
# in the list does.
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:999},{number:1000}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> a push run with a stale PR association naming only a sibling is never excluded (harmon-devkit#714 shepherd r3)"
# pull_requests[] on a non-pull_request-triggered run is a best-effort
# historical association GitHub attaches after the fact, not evidence about
# what the run itself tested -- a push run naming only PR 999 must not be
# judged "other-pr" and dropped, the same category error as judging it by
# branch would be.
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"push",
     pull_requests:[{number:999}],head_branch:"main"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not survive a push run whose only pull_requests association names a different PR: $gate_out"

echo "==> two push suites on different branches sharing a sha are kept apart by branch (harmon-devkit#714 shepherd r3)"
# The same tree pushed to two branches produces two independently
# significant answers -- without the branch in the identity, both would
# render as the same wf:<id>:push and collapse, letting one branch's later
# success hide the other's earlier failure.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"push",
     pull_requests:[],head_branch:"main"},
    {check_suite_id:20,workflow_id:100,event:"push",
     pull_requests:[],head_branch:"release"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'guard' ||
    fail "checks-failing did not survive when a push suite on a different branch shared the workflow/event but not the branch: $gate_out"

echo "==> an EMPTY check list is indeterminate, never a pass"
write_defaults
printf '%s\n' '[{"total_count":0,"check_runs":[]}]' \
    >"${fixtures}/check-runs.pages.json"
printf '%s\n' '[[]]' >"${fixtures}/statuses.pages.json"
run_gate
assert_gate 2 indeterminate checks-indeterminate

echo "==> CHANGES_REQUESTED fails as changes-requested"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"CHANGES_REQUESTED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch"}' \
    >"${fixtures}/pr-view.json"
run_gate
assert_gate 1 fail changes-requested

echo "==> DIRTY and BEHIND fail; UNKNOWN is indeterminate"
for pair in "DIRTY 1 fail merge-state-dirty" "BEHIND 1 fail merge-state-behind" \
    "UNKNOWN 2 indeterminate merge-state-unknown"; do
    # shellcheck disable=SC2086
    set -- $pair
    write_defaults
    jq -cn --arg head "$head_sha" --arg ms "$1" \
        '{state:"OPEN",isDraft:true,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:$ms,
          headRefName:"feature-branch"}' \
        >"${fixtures}/pr-view.json"
    run_gate
    assert_gate "$2" "$3" "$4"
done

echo "==> an unsettled deferred finding fails as deferred-unsettled"
write_defaults
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-1",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
# run.json's settlements[] stays empty from write_default_record — nothing
# has settled the one deferred finding the adjudication above declares.
run_gate
assert_gate 1 fail deferred-unsettled
printf '%s\n' "$gate_out" | grep -Fq 'review-r1-codex-cli-1' ||
    fail "deferred-unsettled did not name the unsettled finding: $gate_out"

echo "==> the same finding, once settled in run.json, passes that condition"
write_defaults
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-1",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", initiated_by:"human",
      started_at:"2026-01-01T00:00:00Z",
      stage_transitions:[{stage:"integration",entered_at:"2026-01-01T00:00:00Z"}],
      interventions:[], outcome:null,
      pr:{number:493,url:"https://github.com/example/repo/pull/493"},
      evidence_comments:[],
      settlements:[{finding_id:"review-r1-codex-cli-1", disposition:"decline",
        settled_at:"2026-01-01T00:01:00Z",
        reference:{type:"comment_id",value:"555"}}],
      promotion:null,
      evidence_registrations:[], outcome_transitions:[],
      pr_bindings:[{seq:0,prev_digest:"genesis",
        digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
        number:493,url:"https://github.com/example/repo/pull/493",
        bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
run_gate
assert_gate 0 pass ready

echo "==> a record with no deferred findings at all passes that condition"
write_defaults
run_gate
assert_gate 0 pass ready

# 9a: the pass's own findings[] is unconditional evidence, independent of
# codex_cycle (review round 2 gauntlet challenge, harmon-devkit#639). A
# schema-valid verdict:"clean" cannot itself carry an undispositioned finding
# (validate-result-schemas.mjs already ties every listed finding to a
# decline/file disposition there), so exercise the gap the schema does allow:
# a non-"clean" verdict (here "findings") whose codex_cycle is independently
# waived by --integration-cap 0. Nothing else in the gate (thread-linkage is
# inline-only, deferred-findings only covers findings already carried from an
# earlier stage) can ever catch a finding surfaced only here.
echo "==> a pass reporting a non-empty findings[] fails as unresolved-integrator-findings"
write_defaults
findings_result="${fixtures}/integrator-result-with-findings.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1,
            findings:[{id:"integration-r1-human-1",
                       body:"a top-level finding needing adjudication",
                       source_id:"42"}],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"findings"}}' \
    >"$findings_result"
node "$validator" envelope "$findings_result" >/dev/null ||
    fail "with-findings fixture failed schema validation"
run_gate --integrator-result "$findings_result"
assert_gate 1 fail unresolved-integrator-findings
printf '%s\n' "$gate_out" | grep -Fq 'integration-r1-human-1' ||
    fail "unresolved-integrator-findings did not name the finding: $gate_out"

# 9c (Codex cloud-review cycle on PR harmon-devkit#758): a pass that never
# finished is not a waiver. Under --integration-cap 0 a null codex_cycle is
# the legitimate waived case, but the SAME null cycle is what the agent
# reports when it skipped the cycle because CI was still pending (verdict
# "pending"), or when it stopped in its §1 before reading anything (status
# "blocked") — and both can carry empty findings[]/unanswered_thread_roots
# that mean "never collected". Live checks/threads above are green in these
# fixtures, so nothing but the verdict/status requirement itself can catch
# them.
write_integrator_pass_fixture() {
    local name="$1" status="$2" verdict="$3"
    local out="${fixtures}/integrator-result-${name}.json"
    jq -cn --arg head "$head_sha" --arg status "$status" --arg verdict "$verdict" '
      {schema:2, role:"integrator", status:$status, head:$head,
       produced_at:"2026-01-01T00:00:00Z",
       producer:{harness:"claude-code",model:"test",tier:"economy"},
       run:{run_id:"test-run",initiated_by:"human"},
       payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
                codex_cycle:null, integration_round:1, findings:[],
                unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
                verdict:$verdict}}' >"$out"
    node "$validator" envelope "$out" >/dev/null ||
        fail "$name fixture failed schema validation"
    printf '%s' "$out"
}

echo "==> a cap-0 pass with verdict pending (CI unsettled, cycle skipped) fails as integrator-not-clean"
write_defaults
pending_result="$(write_integrator_pass_fixture cap-zero-pending completed pending)"
run_gate --integrator-result "$pending_result" --integration-cap 0
assert_gate 1 fail integrator-not-clean
printf '%s\n' "$gate_out" | grep -Fq 'verdict is pending' ||
    fail "integrator-not-clean did not name the verdict: $gate_out"

echo "==> a cap-0 pass with status blocked fails as integrator-not-clean"
write_defaults
blocked_result="$(write_integrator_pass_fixture cap-zero-blocked blocked pending)"
run_gate --integrator-result "$blocked_result" --integration-cap 0
assert_gate 1 fail integrator-not-clean
printf '%s\n' "$gate_out" | grep -Fq 'status is blocked' ||
    fail "integrator-not-clean did not name the status: $gate_out"

echo "==> a cap-0 pass with verdict escalate fails as integrator-not-clean"
write_defaults
escalate_result="$(write_integrator_pass_fixture cap-zero-escalate completed escalate)"
run_gate --integrator-result "$escalate_result" --integration-cap 0
assert_gate 1 fail integrator-not-clean

echo "==> an unanswered inline thread fails as threads-unanswered"
write_defaults
jq -cn '[[{id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
           created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
           body:"finding"}]]' >"${fixtures}/inline.pages.json"
run_gate
assert_gate 1 fail threads-unanswered
printf '%s\n' "$gate_out" | grep -Fq '900' ||
    fail "threads-unanswered did not name the root: $gate_out"

echo "==> an answered thread passes; a reviewer follow-up after the reply fails"
write_defaults
jq -cn '[[
    {id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
     created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
     body:"finding"},
    {id:901,user:{login:"pr-author"},path:"f.sh",in_reply_to_id:900,
     created_at:"2026-08-01T01:00:00Z",updated_at:"2026-08-01T01:00:00Z",
     body:"fixed in abc"}]]' >"${fixtures}/inline.pages.json"
run_gate
assert_gate 0 pass ready
write_defaults
jq -cn '[[
    {id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
     created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
     body:"finding"},
    {id:901,user:{login:"pr-author"},path:"f.sh",in_reply_to_id:900,
     created_at:"2026-08-01T01:00:00Z",updated_at:"2026-08-01T01:00:00Z",
     body:"fixed in abc"},
    {id:902,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:900,
     created_at:"2026-08-01T02:00:00Z",updated_at:"2026-08-01T02:00:00Z",
     body:"follow-up"}]]' >"${fixtures}/inline.pages.json"
run_gate
assert_gate 1 fail threads-new-follow-up

edited_thread() {
    jq -cn '[[
        {id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
         created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T02:00:00Z",
         body:"finding, reworded"},
        {id:901,user:{login:"pr-author"},path:"f.sh",in_reply_to_id:900,
         created_at:"2026-08-01T01:00:00Z",updated_at:"2026-08-01T01:00:00Z",
         body:"fixed in abc"}]]' >"${fixtures}/inline.pages.json"
}

echo "==> an edit after the reply fails distinctly as threads-edited-since-reply"
write_defaults
edited_thread
run_gate
assert_gate 1 fail threads-edited-since-reply

echo "==> --allow-edited-root clears exactly that edited root"
write_defaults
edited_thread
run_gate --allow-edited-root 900
assert_gate 0 pass ready

echo "==> --allow-edited-root never clears an unanswered thread"
write_defaults
jq -cn '[[{id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
           created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
           body:"finding"}]]' >"${fixtures}/inline.pages.json"
run_gate --allow-edited-root 900
assert_gate 1 fail threads-unanswered

echo "==> a failed identity lookup is indeterminate, never answered"
write_defaults
printf 'user' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a failed inline-comment fetch is indeterminate, never a pass"
write_defaults
printf 'pulls/493/comments' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a failed fingerprint-surface fetch (reviews) is indeterminate"
write_defaults
printf 'pulls/493/reviews' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a failed thread-resolution fetch (graphql) is indeterminate"
write_defaults
printf 'graphql' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a head that moves mid-gate fails as head-moved on the final re-read"
write_defaults
jq -cn --arg head "$moved_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail head-moved

echo "==> a promotion mid-gate fails as pr-not-draft on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail pr-not-draft

echo "==> an integrator result reporting Codex findings/pending/retry/escalate all fail as codex-not-clean"
for exit_code in 10 11 12 13; do
    write_defaults
    result="$(write_integrator_result "exit-${exit_code}" "$(codex_cycle_json "$exit_code")")"
    run_gate --integrator-result "$result" --integration-cap 1
    assert_gate 1 fail codex-not-clean
done

echo "==> a codex_cycle exit_code of 2 (indeterminate) is codex-indeterminate"
write_defaults
result="$(write_integrator_result exit-2 "$(codex_cycle_json 2)")"
run_gate --integrator-result "$result" --integration-cap 1
assert_gate 2 indeterminate codex-indeterminate

echo "==> a missing --integrator-result file is refused as a usage error, never a pass"
write_defaults
set +e
missing_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" \
    --integrator-result "${fixtures}/no-such-result.json" 2>&1)"
missing_rc=$?
set -e
[ "$missing_rc" -eq 2 ] ||
    fail "a missing --integrator-result file should exit 2, got $missing_rc: $missing_out"
printf '%s\n' "$missing_out" | grep -Fq 'integrator-result' ||
    fail "the missing-integrator-result error does not name the flag: $missing_out"

echo "==> an integrator result naming a different head is refused before the Codex condition is read"
write_defaults
result="$(write_integrator_result other-head null "$moved_sha")"
run_gate --integrator-result "$result"
assert_gate 2 indeterminate codex-indeterminate

echo "==> an integrator result whose role is not integrator is refused"
write_defaults
non_integrator_result="${fixtures}/integrator-result-wrong-role.json"
jq -cn --arg head "$head_sha" \
    '{schema:2, role:"reviewer", status:"completed", head:$head,
      produced_at:"2026-01-01T00:00:00Z",
      producer:{harness:"claude-code",model:"test",tier:"economy"},
      run:{run_id:"test-run",initiated_by:"human"},
      payload:{stage:"review",reviewed_head:$head,findings:[],
               verdict:"clean"}}' >"$non_integrator_result"
run_gate --integrator-result "$non_integrator_result"
assert_gate 2 indeterminate codex-indeterminate

echo "==> an --integrator-result that fails schema validation is refused"
write_defaults
malformed_result="${fixtures}/integrator-result-malformed.json"
printf '%s\n' '{"not":"a valid envelope"}' >"$malformed_result"
run_gate --integrator-result "$malformed_result"
assert_gate 2 indeterminate codex-indeterminate

echo "==> an integrator result from a different run (same head) is refused — the run-identity invariant"
write_defaults
stale_run_result="$(write_integrator_result stale-run null)"
# write_integrator_result always stamps run:{run_id:"test-run",
# initiated_by:"human"}, matching write_default_record's own run.json — this
# is the one fixture in the suite that deliberately makes them disagree,
# simulating a superseded/resumed run's evidence surviving on disk with the
# SAME head as the active run (specs/dev-flow-v2.md:177-185).
jq -c '.run.run_id = "a-different-run"' "$stale_run_result" >"${stale_run_result}.tmp"
mv "${stale_run_result}.tmp" "$stale_run_result"
run_gate --integrator-result "$stale_run_result"
assert_gate 2 indeterminate codex-indeterminate

# ── harmon-devkit#685 criteria owned by #639 ────────────────────────────────
# codex_cycle.cycle <= [rounds.<policy>].integration; cap 0 <=> null cycle; a
# clean verdict with a null cycle under a positive cap is not clean.
# --integration-cap is required context the caller supplies (this script
# never reads .devflow.toml itself) — see the dedicated "never skippable by
# silence" case above for the omitted-flag usage error; every case below
# passes it explicitly.

echo "==> a non-null codex_cycle against --integration-cap 0 is codex-cap-mismatch"
write_defaults
clean_result="$(write_integrator_result cap-zero-nonnull "$(codex_cycle_json 0)")"
run_gate --integrator-result "$clean_result" --integration-cap 0
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> a null codex_cycle against a positive --integration-cap is codex-cap-mismatch"
write_defaults
run_gate --integration-cap 3
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> a null codex_cycle against --integration-cap 0 passes (the waived case)"
write_defaults
run_gate --integration-cap 0
assert_gate 0 pass ready

echo "==> codex_cycle.cycle within --integration-cap passes"
write_defaults
cycle_two="$(jq -c '.cycle = 2' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-cycle-ok "$cycle_two")"
run_gate_recheck_clean --integrator-result "$clean_result" --integration-cap 2
assert_gate 0 pass ready

echo "==> codex_cycle.cycle exceeding --integration-cap is codex-cap-mismatch"
write_defaults
cycle_three="$(jq -c '.cycle = 3' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-cycle-exceeded "$cycle_three")"
run_gate --integrator-result "$clean_result" --integration-cap 2
assert_gate 2 indeterminate codex-cap-mismatch

# --codex-recheck (harmon-devkit#639 gauntlet challenge round 1, finding 3):
# a cached codex_cycle.exit_code 0 can go stale between the dispatched
# integrator pass and this gate, so a clean exit_code 0 reconfirms itself
# against live state rather than being trusted unconditionally. All four
# cases below are cap-agnostic — no --integration-cap involved — since the
# recheck applies whenever codex_cycle reports exit_code 0, independent of
# whether a cap was given at all.

echo "==> a clean codex_cycle with no --codex-recheck is codex-stale"
write_defaults
recheck_missing_result="$(write_integrator_result recheck-missing "$(codex_cycle_json 0)")"
run_gate --integrator-result "$recheck_missing_result" --integration-cap 1
assert_gate 2 indeterminate codex-stale

echo "==> --codex-recheck naming a file that does not exist is codex-stale"
write_defaults
recheck_absent_result="$(write_integrator_result recheck-absent "$(codex_cycle_json 0)")"
run_gate --integrator-result "$recheck_absent_result" --integration-cap 1 \
    --codex-recheck "${fixtures}/does-not-exist.json"
assert_gate 2 indeterminate codex-stale

echo "==> --codex-recheck naming a state file for a different repo/pr/head is codex-stale"
write_defaults
recheck_mismatch_result="$(write_integrator_result recheck-mismatch "$(codex_cycle_json 0)")"
mismatched_state="${fixtures}/codex-recheck-state-mismatched.json"
jq -cn --arg repo other/repo --argjson pr 1 --arg head "$moved_sha" \
    '{repo:$repo, pr:$pr, head:$head}' >"$mismatched_state"
run_gate --integrator-result "$recheck_mismatch_result" --integration-cap 1 \
    --codex-recheck "$mismatched_state"
assert_gate 2 indeterminate codex-stale

echo "==> --codex-recheck against a real but not-yet-attached state is codex-stale (the real checker, exit 2)"
write_defaults
recheck_disagree_result="$(write_integrator_result recheck-disagrees "$(codex_cycle_json 0)")"
not_attached_state="${fixtures}/codex-recheck-state-not-attached.json"
jq -cn --arg repo example/repo --argjson pr 493 --arg head "$head_sha" \
    '{version:2, repo:$repo, pr:$pr, head:$head, attempt:1, phase:"reserved",
      settled:null, cycle_requested_at:null,
      previous_trigger_comment_id:null, timeout_min:15}' \
    >"$not_attached_state"
run_gate --integrator-result "$recheck_disagree_result" --integration-cap 1 \
    --codex-recheck "$not_attached_state"
assert_gate 2 indeterminate codex-stale
printf '%s\n' "$gate_out" | grep -Fq 'not attached' ||
    fail "codex-stale did not surface the real checker's own complaint: $gate_out"

# promotion.head equals the final integrator result's head AND its
# accepted-cycle reviewed commit; a stale pass cannot certify a newer head.
# The gate never gets a chance to check this itself: validate-result-
# schemas.mjs's own envelope receipt validation already rejects any envelope
# whose accepted.reviewed_commit disagrees with the envelope's own head
# (unconditionally, cap or no cap) — and the gate's separate envelope_head
# == --head check closes the remaining leg, so the two together are what
# make a stale reviewed_commit unable to certify a newer head. Prove the
# upstream half directly, since the gate can never observe a fixture that
# fails it (write_integrator_result's own validation step refuses first).
echo "==> a schema-valid envelope cannot carry a stale accepted.reviewed_commit"
stale_result="${fixtures}/integrator-result-stale-reviewed-commit.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:{head:$head, cycle:1, attempt:1,
              trigger_comment_id:"1",
              accepted:{surface:"review", id:"1",
                reviewed_commit:"3333333333333333333333333333333333333333"},
              exit_code:0},
            integration_round:1, findings:[], unanswered_thread_roots:[],
            settled_at:"2026-01-01T00:00:00Z", verdict:"clean",
            applied_dispositions:[]}}' >"$stale_result"
validator_out="$(node "$validator" envelope "$stale_result" 2>&1)" &&
    fail "a stale accepted.reviewed_commit should fail schema validation, got: $validator_out"
printf '%s\n' "$validator_out" | grep -Fq 'reviewed_commit' ||
    fail "the validator's rejection does not name reviewed_commit: $validator_out"

# Codex cloud-review cycle on PR harmon-devkit#758: a Codex-clean cycle
# (exit_code 0) alongside a separate, same-pass human/CI finding is the
# routine mixed-source case ai/agents/integrator.md §7 documents
# (verdict:"findings" even though the Codex cycle itself is clean) — the
# schema must not force verdict:"clean" whenever exit_code is 0, or this
# ordinary case could never produce a validatable envelope.
echo "==> a clean codex_cycle (exit_code 0) alongside verdict:findings is schema-valid"
mixed_source_result="${fixtures}/integrator-result-mixed-source.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:{head:$head, cycle:1, attempt:1,
              trigger_comment_id:"1",
              accepted:{surface:"review", id:"1", reviewed_commit:$head},
              exit_code:0},
            integration_round:1,
            findings:[{id:"integration-r1-human-1",
                       body:"a top-level finding needing adjudication",
                       source_id:"42"}],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"findings"}}' >"$mixed_source_result"
node "$validator" envelope "$mixed_source_result" >/dev/null ||
    fail "a clean codex_cycle alongside verdict:findings should validate: $(node "$validator" envelope "$mixed_source_result" 2>&1)"

# 9b is scoped to DEFERRED findings only (review round 2 gauntlet challenge,
# harmon-devkit#639): a finding this same integration pass discovered fresh
# was never carried with disposition `defer` by any adjudication document, so
# render-dev-flow.mjs's own cross-document consistency would reject a
# settlement for one outright — requiring a settlement here would make such a
# finding impossible to ever pass this gate, resolved or not. Prove that
# first, before proving the deferred case below still requires one.
echo "==> applied_dispositions naming a FRESH (never-deferred) finding needs no settlement and passes"
write_defaults
fresh_result="${fixtures}/integrator-result-fresh-disposition.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1, findings:[],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"clean",
            applied_dispositions:[{finding_id:"integration-r1-human-1",
                                    disposition:"fix"}]}}' \
    >"$fresh_result"
node "$validator" envelope "$fresh_result" >/dev/null ||
    fail "fresh-disposition fixture failed schema validation"
run_gate --integrator-result "$fresh_result"
assert_gate 0 pass ready

# A disposition claim alone, with no durable settlement behind it, cannot
# promote a genuinely deferred finding — check 6 (deferred-unsettled) already
# guards every deferred-and-unsettled finding regardless of what the current
# pass's applied_dispositions claims, so it fires here before 9b's own
# (narrower, settlement-existence-only) check ever gets a chance to.
echo "==> a DEFERRED finding claimed fixed in applied_dispositions still fails as deferred-unsettled without a settlement"
write_defaults
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-9",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
undisclosed_result="${fixtures}/integrator-result-undisclosed.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1, findings:[],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"clean",
            applied_dispositions:[{finding_id:"review-r1-codex-cli-9",
                                    disposition:"fix"}]}}' \
    >"$undisclosed_result"
node "$validator" envelope "$undisclosed_result" >/dev/null ||
    fail "undisclosed-disposition fixture failed schema validation"
run_gate --integrator-result "$undisclosed_result"
assert_gate 1 fail deferred-unsettled
printf '%s\n' "$gate_out" | grep -Fq 'review-r1-codex-cli-9' ||
    fail "deferred-unsettled did not name the unsettled finding: $gate_out"

echo "==> applied_dispositions naming a finding WITH a matching settlement passes"
write_defaults
# render-dev-flow.mjs's own cross-document consistency rejects an "orphan"
# settlement (one naming a finding no adjudication document declares) and a
# settlement for a finding never dispositioned defer — both real invariants,
# so the fixture needs a genuine defer-dispositioned adjudication behind the
# settlement, not just the settlement alone.
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-9",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", initiated_by:"human",
      started_at:"2026-01-01T00:00:00Z",
      stage_transitions:[{stage:"integration",entered_at:"2026-01-01T00:00:00Z"}],
      interventions:[], outcome:null,
      pr:{number:493,url:"https://github.com/example/repo/pull/493"},
      evidence_comments:[],
      settlements:[{finding_id:"review-r1-codex-cli-9", disposition:"fix",
        settled_at:"2026-01-01T00:01:00Z",
        reference:{type:"sha",value:"c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff"}}],
      promotion:null,
      evidence_registrations:[], outcome_transitions:[],
      pr_bindings:[{seq:0,prev_digest:"genesis",
        digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
        number:493,url:"https://github.com/example/repo/pull/493",
        bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
disclosed_result="${fixtures}/integrator-result-disclosed.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1, findings:[],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"clean",
            applied_dispositions:[{finding_id:"review-r1-codex-cli-9",
                                    disposition:"fix"}]}}' \
    >"$disclosed_result"
node "$validator" envelope "$disclosed_result" >/dev/null ||
    fail "disclosed-disposition fixture failed schema validation"
run_gate --integrator-result "$disclosed_result"
assert_gate 0 pass ready

# review round 3 gauntlet challenge, harmon-devkit#639 (Codex cloud-review
# cycle on PR #758): an id-only match let run.json record a DIFFERENT
# disposition than applied_dispositions claims and still read as settled.
echo "==> applied_dispositions naming fix but run.json's settlement says decline is disposition-unsettled"
write_defaults
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-9",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", initiated_by:"human",
      started_at:"2026-01-01T00:00:00Z",
      stage_transitions:[{stage:"integration",entered_at:"2026-01-01T00:00:00Z"}],
      interventions:[], outcome:null,
      pr:{number:493,url:"https://github.com/example/repo/pull/493"},
      evidence_comments:[],
      settlements:[{finding_id:"review-r1-codex-cli-9", disposition:"decline",
        settled_at:"2026-01-01T00:01:00Z",
        reference:{type:"comment_id",value:"555"}}],
      promotion:null,
      evidence_registrations:[], outcome_transitions:[],
      pr_bindings:[{seq:0,prev_digest:"genesis",
        digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
        number:493,url:"https://github.com/example/repo/pull/493",
        bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
mismatched_disposition_result="${fixtures}/integrator-result-mismatched-disposition.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1, findings:[],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"clean",
            applied_dispositions:[{finding_id:"review-r1-codex-cli-9",
                                    disposition:"fix"}]}}' \
    >"$mismatched_disposition_result"
node "$validator" envelope "$mismatched_disposition_result" >/dev/null ||
    fail "mismatched-disposition fixture failed schema validation"
run_gate --integrator-result "$mismatched_disposition_result"
assert_gate 1 fail disposition-unsettled
printf '%s\n' "$gate_out" | grep -Fq 'review-r1-codex-cli-9' ||
    fail "disposition-unsettled did not name the mismatched finding: $gate_out"

# ---------------------------------------------------------------------------
# harmon-devkit#685 — run-trajectory receipt invariants de-scoped from #634,
# carried here as required test cases. Each block below names the acceptance
# criterion it discharges and pairs the attack with its legitimate neighbour,
# so a check cannot be satisfied by an over-broad reading of either half.
# ---------------------------------------------------------------------------

# --- #685 criterion 9: the moment an integrator pass applies fix|decline|file
# --- to a deferred finding, the matching append-only settlement exists,
# --- REGARDLESS OF OUTCOME. The `fix` case is covered above; decline and file
# --- are the two dispositions that leave the head alone, so nothing else in
# --- this gate would ever notice them going unrecorded.
write_deferred_adjudication() {
    jq -cn --arg head "$head_sha" \
        '{schema:2, run_id:"test-run", stage:"review", round:1,
          reviewed_head:$head,
          adjudications:[{finding_id:"review-r1-codex-cli-9",
            reviewer_priority:"P2", adjudicated_priority:"P2",
            disposition:"defer", reason:"carrying to integration",
            evidence:"needs a second look", override:null}]}' \
        >"${record_dir}/adjudications/review-r1.json"
}

# $1 name, $2 disposition
write_disposition_result() {
    local out="${fixtures}/integrator-result-685-$1.json"
    jq -cn --arg head "$head_sha" --arg disp "$2" '
      {schema:2, role:"integrator", status:"completed", head:$head,
       produced_at:"2026-01-01T00:00:00Z",
       producer:{harness:"claude-code",model:"test",tier:"economy"},
       run:{run_id:"test-run",initiated_by:"human"},
       payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
                codex_cycle:null, integration_round:1, findings:[],
                unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
                verdict:"clean",
                applied_dispositions:[{finding_id:"review-r1-codex-cli-9",
                                        disposition:$disp}]}}' \
        >"$out"
    node "$validator" envelope "$out" >/dev/null ||
        fail "#685 disposition fixture ($2) failed schema validation"
    printf '%s\n' "$out"
}

for disposition in decline file; do
    echo "==> #685(9): a DEFERRED finding ${disposition}d in applied_dispositions with no settlement fails"
    write_defaults
    write_deferred_adjudication
    disposition_result="$(write_disposition_result "unsettled-${disposition}" "$disposition")"
    run_gate --integrator-result "$disposition_result"
    assert_gate 1 fail deferred-unsettled
    printf '%s\n' "$gate_out" | grep -Fq 'review-r1-codex-cli-9' ||
        fail "#685(9) ${disposition}: gate did not name the unsettled finding: $gate_out"
done

# $1 settlement disposition, $2 reference type, $3 reference value. Writes a
# whole record rather than patching: write_defaults resets run.json via
# write_default_record, so every case here restates it in full.
write_record_with_settlement() {
    jq -cn --arg disp "$1" --arg reftype "$2" --arg refvalue "$3" '
      {schema:2, run_id:"test-run", initiated_by:"human",
       started_at:"2026-01-01T00:00:00Z",
       stage_transitions:[{stage:"integration",entered_at:"2026-01-01T00:00:00Z"}],
       interventions:[], outcome:null,
       pr:{number:493,url:"https://github.com/example/repo/pull/493"},
       evidence_comments:[],
       settlements:[{finding_id:"review-r1-codex-cli-9", disposition:$disp,
                     settled_at:"2026-01-01T01:00:00Z",
                     reference:{type:$reftype, value:$refvalue}}],
       promotion:null, evidence_registrations:[], outcome_transitions:[],
       pr_bindings:[{seq:0,prev_digest:"genesis",
         digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
         number:493,url:"https://github.com/example/repo/pull/493",
         bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
}

echo "==> #685(9): the same decline, once settled in run.json with the SAME disposition, passes"
write_defaults
write_record_with_settlement decline comment_id 9001
write_deferred_adjudication
disposition_result="$(write_disposition_result settled-decline decline)"
run_gate --integrator-result "$disposition_result"
assert_gate 0 pass ready

echo "==> #685(9): a settlement recording file where the pass applied decline is disposition-unsettled"
write_defaults
write_record_with_settlement file issue_number 9002
write_deferred_adjudication
run_gate --integrator-result "$disposition_result"
assert_gate 1 fail disposition-unsettled

# --- #685 criterion 6: promotion.head equals the head of the final integrator
# --- result and its accepted-cycle reviewed commit; a stale integration pass
# --- cannot certify a newer promoted head. The envelope-head and
# --- accepted.reviewed_commit halves are proven elsewhere in this file; this
# --- is the record's own promotion entry, which was bound to nothing.
# $1 = the head the record claims it promoted (a promoted record is
# outcome: ready-for-review, which run.schema.json ties to a non-null
# promotion and a last stage_transitions entry of integration).
write_promoted_record() {
    jq -cn --arg head "$1" '
      {schema:2, run_id:"test-run", initiated_by:"human",
       started_at:"2026-01-01T00:00:00Z",
       stage_transitions:[{stage:"integration",entered_at:"2026-01-01T00:00:00Z",
                           exit:"converged"}],
       interventions:[], outcome:"ready-for-review",
       pr:{number:493,url:"https://github.com/example/repo/pull/493"},
       evidence_comments:[], settlements:[],
       promotion:{head:$head, promoted_at:"2026-01-01T02:00:00Z",
                  gate_fingerprint:"sha256:fingerprint"},
       evidence_registrations:[],
       outcome_transitions:[{seq:0,prev_digest:"genesis",
         digest:"c8d2ee4b1c0a3fd0cd5d6ffc3e5f1c1ba1d5b21b0f4c2ad2b0cbb35c6a9b8f2e",
         outcome:"ready-for-review", at:"2026-01-01T02:00:00Z"}],
       pr_bindings:[{seq:0,prev_digest:"genesis",
         digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
         number:493,url:"https://github.com/example/repo/pull/493",
         bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
    rm -f "${record_dir}"/adjudications/*.json
}

write_promoted_pr_view() {
    jq -cn --arg head "$head_sha" \
        '{state:"OPEN",isDraft:false,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
          headRefName:"feature-branch"}' >"${fixtures}/pr-view.json"
}

echo "==> #685(6): audit passes when run.json's promotion.head IS the gated head"
write_defaults
write_promoted_record "$head_sha"
write_promoted_pr_view
run_audit
assert_gate 0 pass audit

echo "==> #685(6): a promotion.head naming a different commit is promotion-head-mismatch"
write_defaults
write_promoted_record "$stale_head_sha"
write_promoted_pr_view
run_audit
assert_gate 2 indeterminate promotion-head-mismatch

echo "==> #685(6): the same stale promotion.head is refused by check too, not only audit"
write_defaults
write_promoted_record "$stale_head_sha"
run_gate
assert_gate 2 indeterminate promotion-head-mismatch

# --- #685 criterion 4: integration -> implement -> integration loops are
# --- counted against [rounds.<policy>].remediation; exceeding it is capped
# --- with escalation, and code-changing integration dispositions past the cap
# --- are rejected. --remediation-cap is what supplies the resolved value.
# $1 = number of integration entries in stage_transitions
write_record_with_integration_entries() {
    jq -cn --argjson n "$1" '
      # A minute counter keeps entered_at non-decreasing across the whole
      # array (checkRunChronology) while the edges stay on ALLOWED_EDGES'"'"'s
      # own graph: kickoff -> claim -> plan -> implement -> verify ->
      # security -> integration, then $n loops of
      # integration -> implement -> verify -> security -> integration.
      def at($m): "2026-01-01T" + (($m / 60 | floor) | tostring | ("0" * (2 - length)) + .) + ":" + (($m % 60) | tostring | ("0" * (2 - length)) + .) + ":00Z";
      [{stage:"kickoff",exit:"claimed"},
       {stage:"claim",exit:"planned"},
       {stage:"plan",exit:"briefed"},
       {stage:"implement",exit:"verified"},
       {stage:"verify",exit:"green"},
       {stage:"security",exit:"clean"}]
      + ([range(0; $n)] | map(
          [{stage:"integration",exit:"remediating"},
           {stage:"implement",exit:"fixed"},
           {stage:"verify",exit:"green"},
           {stage:"security",exit:"clean"}]) | flatten)
      + [{stage:"integration"}]
      | to_entries | map(.value + {entered_at: at(.key)})
      | . as $transitions
      | {schema:2, run_id:"test-run", initiated_by:"human",
         started_at:"2026-01-01T00:00:00Z",
         stage_transitions:$transitions,
         interventions:[], outcome:null,
         pr:{number:493,url:"https://github.com/example/repo/pull/493"},
         evidence_comments:[], settlements:[], promotion:null,
         evidence_registrations:[], outcome_transitions:[],
         pr_bindings:[{seq:0,prev_digest:"genesis",
           digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
           number:493,url:"https://github.com/example/repo/pull/493",
           bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
    node "$validator" run "${record_dir}/run.json" >/dev/null ||
        fail "#685(4) record fixture with $1 remediation loop(s) is not a valid run record"
    rm -f "${record_dir}"/adjudications/*.json
}

echo "==> #685(4): remediation loops within --remediation-cap pass"
write_defaults
write_record_with_integration_entries 2
run_gate --remediation-cap 3
assert_gate 0 pass ready

echo "==> #685(4): remediation loops exceeding --remediation-cap fail as remediation-capped"
write_defaults
write_record_with_integration_entries 2
run_gate --remediation-cap 1
assert_gate 1 fail remediation-capped

echo "==> #685(4): omitting --remediation-cap leaves the same record promotable (the flag is the only source)"
write_defaults
write_record_with_integration_entries 2
run_gate
assert_gate 0 pass ready

# A record that is exactly AT one remediation loop (two integration entries)
# and carries a settlement for the deferred finding, so the at-cap cases
# below turn only on the disposition the gated pass applies.
# $1 settlement disposition, $2 reference type, $3 reference value.
write_at_cap_record() {
    jq -cn --arg disp "$1" --arg reftype "$2" --arg refvalue "$3" '
      {schema:2, run_id:"test-run", initiated_by:"human",
       started_at:"2026-01-01T00:00:00Z",
       stage_transitions:[
         {stage:"kickoff",entered_at:"2026-01-01T00:00:00Z",exit:"claimed"},
         {stage:"claim",entered_at:"2026-01-01T00:01:00Z",exit:"planned"},
         {stage:"plan",entered_at:"2026-01-01T00:02:00Z",exit:"briefed"},
         {stage:"implement",entered_at:"2026-01-01T00:03:00Z",exit:"verified"},
         {stage:"verify",entered_at:"2026-01-01T00:04:00Z",exit:"green"},
         {stage:"security",entered_at:"2026-01-01T00:05:00Z",exit:"clean"},
         {stage:"integration",entered_at:"2026-01-01T00:06:00Z",exit:"remediating"},
         {stage:"implement",entered_at:"2026-01-01T00:07:00Z",exit:"fixed"},
         {stage:"verify",entered_at:"2026-01-01T00:08:00Z",exit:"green"},
         {stage:"security",entered_at:"2026-01-01T00:09:00Z",exit:"clean"},
         {stage:"integration",entered_at:"2026-01-01T00:10:00Z"}],
       interventions:[], outcome:null,
       pr:{number:493,url:"https://github.com/example/repo/pull/493"},
       evidence_comments:[],
       settlements:[{finding_id:"review-r1-codex-cli-9", disposition:$disp,
                     settled_at:"2026-01-01T00:11:00Z",
                     reference:{type:$reftype, value:$refvalue}}],
       promotion:null, evidence_registrations:[], outcome_transitions:[],
       pr_bindings:[{seq:0,prev_digest:"genesis",
         digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
         number:493,url:"https://github.com/example/repo/pull/493",
         bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
    node "$validator" run "${record_dir}/run.json" >/dev/null ||
        fail "#685(4) at-cap record fixture is not a valid run record"
}

echo "==> #685(4): AT the cap, a code-changing disposition is rejected"
write_defaults
write_at_cap_record fix sha "$head_sha"
write_deferred_adjudication
fix_result="$(write_disposition_result at-cap-fix fix)"
run_gate --integrator-result "$fix_result" --remediation-cap 1
assert_gate 1 fail remediation-capped
printf '%s\n' "$gate_out" | grep -Fq 'review-r1-codex-cli-9' ||
    fail "#685(4) at-cap: gate did not name the code-changing disposition: $gate_out"

echo "==> #685(4): AT the cap, a decline (which never moves the head) still passes"
write_defaults
write_at_cap_record decline comment_id 9003
write_deferred_adjudication
decline_result="$(write_disposition_result at-cap-decline decline)"
run_gate --integrator-result "$decline_result" --remediation-cap 1
assert_gate 0 pass ready

echo "==> #685(4): a non-integer --remediation-cap is a usage error, never silently ignored"
write_defaults
write_default_record
set +e
bad_cap_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" check \
    --repo example/repo --pr 493 --head "$head_sha" --record "$record_dir" \
    --integrator-result "${fixtures}/integrator-result-disabled.json" \
    --integration-cap 0 --remediation-cap not-a-number 2>&1)"
bad_cap_rc=$?
set -e
[ "$bad_cap_rc" -eq 2 ] ||
    fail "#685(4): a malformed --remediation-cap should exit 2, got $bad_cap_rc: $bad_cap_out"
printf '%s\n' "$bad_cap_out" | grep -Fq -- '--remediation-cap must be a non-negative integer' ||
    fail "#685(4): malformed --remediation-cap did not name the flag: $bad_cap_out"

# --- #685 criterion 5: codex_cycle.cycle <= [rounds].integration; cap 0 =>
# --- null cycle; a clean verdict with a null cycle under a positive cap is
# --- not clean. The five `check`-mode cases above cover all three clauses;
# --- this pins that `audit` — the mode the connector-flip reconcile path
# --- uses — waives none of them just because the PR is already promoted.
echo "==> #685(5): audit refuses a null codex_cycle under a positive --integration-cap too"
write_defaults
write_default_record
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch"}' >"${fixtures}/pr-view.json"
run_audit --integration-cap 3
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> a CHANGES_REQUESTED review landing mid-gate fails on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"CHANGES_REQUESTED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail changes-requested

echo "==> a DIRTY merge state arising mid-gate fails on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"DIRTY"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail merge-state-dirty

echo "==> the fingerprint is double-read: gated evaluation plus a fresh compare"
write_defaults
run_gate
assert_gate 0 pass ready
pr_object_fetches="$(grep -cxF 'api repos/example/repo/pulls/493' "$log")"
[ "$pr_object_fetches" -eq 2 ] ||
    fail "expected exactly two PR-object fetches (the gated body, then the fresh compare), saw $pr_object_fetches"

echo "==> a body edit mid-gate fails as content-moved, never laundered into a pass"
write_defaults
edited_body="$(printf 'What/why prose, edited after the gate read it.\n\n## Verification\n\n- task verify\n')"
jq -cn --arg head "$head_sha" --arg body "$edited_body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/second-pr.json"
run_gate
assert_gate 1 fail content-moved
printf '%s\n' "$gate_out" | grep -Fq 'PR-title/body' ||
    fail "content-moved did not name the changed surface: $gate_out"

echo "==> a top-level comment landing mid-gate fails as content-moved"
write_defaults
jq -cn '[[{id:70,user:{login:"reviewer-bot"},body:"a late finding",
           updated_at:"2026-08-01T03:00:00Z"}]]' \
    >"${fixtures}/second-top.pages.json"
run_gate
assert_gate 1 fail content-moved
printf '%s\n' "$gate_out" | grep -Fq 'top-level-comments' ||
    fail "content-moved did not name the changed surface: $gate_out"

echo "==> a check turning red mid-gate fails on the final re-evaluation"
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {name:"late-red",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/second-check-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'late-red' ||
    fail "the final re-evaluation did not name the late-failing check: $gate_out"

echo "==> without GNU timeout the gate still runs, loudly unbounded"
write_defaults
clean_result="$(write_integrator_result timeout-fallback "$(codex_cycle_json 0)")"
restricted_bin="${test_tmp}/restricted-bin"
mkdir -p "$restricted_bin"
# node, git, and gitleaks are required now (node for schema validation, git
# to locate scripts/render-dev-flow.sh from the checkout's own toplevel,
# gitleaks because render-dev-flow.mjs secret-scans every projection it
# renders, unconditionally, before printing it), on top of the original
# minimal toolset this fixture restricts PATH to.
for tool in bash jq grep tr dirname cat node git gitleaks; do
    tool_path="$(command -v "$tool")" ||
        fail "missing $tool for the no-timeout fixture"
    ln -s "$tool_path" "${restricted_bin}/$tool"
done
for hasher in sha256sum shasum; do
    hasher_path="$(command -v "$hasher" 2>/dev/null || true)"
    [ -z "$hasher_path" ] || ln -s "$hasher_path" "${restricted_bin}/$hasher"
done
ln -s "${bin_dir}/gh" "${restricted_bin}/gh"
# $recheck_gate (not $gate) and RECHECK_FAKE_EXIT=0: codex_cycle here is
# exit_code 0, so recheck_codex_freshness runs and needs its fake checker
# sibling to confirm clean — see run_gate_recheck_clean's comment above. The
# fake stub is #!/bin/sh with no external calls, so it execs fine under this
# restricted PATH too.
set +e
gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" env PATH="$restricted_bin" RECHECK_FAKE_EXIT=0 \
    "$recheck_gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" --integrator-result "$clean_result" \
    --integration-cap 1 --codex-recheck "$recheck_state" 2>&1)"
gate_rc=$?
set -e
check_watchdog "$gate_rc" no-timeout-fallback "$gate_out"
assert_gate 0 pass ready
printf '%s\n' "$gate_out" | grep -Fq 'no GNU timeout' ||
    fail "the timeout fallback must warn that calls are unbounded: $gate_out"

nondraft_pr_view() {
    jq -cn --arg head "$head_sha" \
        '{state:"OPEN",isDraft:false,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
          headRefName:"feature-branch"}' \
        >"${fixtures}/pr-view.json"
}

echo "==> audit passes a green already-promoted PR (check refuses the same PR)"
write_defaults
nondraft_pr_view
run_audit
assert_gate 0 pass audit
write_defaults
nondraft_pr_view
run_gate
assert_gate 1 fail pr-not-draft

echo "==> audit still fails red checks on an already-promoted PR"
write_defaults
nondraft_pr_view
jq -cn '[{total_count:1,check_runs:[
    {name:"lint",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_audit
assert_gate 1 fail checks-failing

echo "==> audit refuses a draft target — there is no promotion to audit"
write_defaults
run_audit
assert_gate 1 fail pr-draft

echo "==> --record, --integrator-result, and --integration-cap are never skippable by silence"
write_defaults
clean_result="$(write_integrator_result skip-check "$(codex_cycle_json 0)")"
set +e
usage_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" 2>&1)"
usage_rc=$?
set -e
[ "$usage_rc" -eq 2 ] ||
    fail "omitting --record and --integrator-result should exit 2, got $usage_rc: $usage_out"
set +e
no_record_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --integrator-result "$clean_result" --integration-cap 1 2>&1)"
no_record_rc=$?
set -e
[ "$no_record_rc" -eq 2 ] ||
    fail "omitting --record alone should exit 2, got $no_record_rc: $no_record_out"
set +e
no_result_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" --integration-cap 1 2>&1)"
no_result_rc=$?
set -e
[ "$no_result_rc" -eq 2 ] ||
    fail "omitting --integrator-result alone should exit 2, got $no_result_rc: $no_result_out"
set +e
no_cap_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" --integrator-result "$clean_result" 2>&1)"
no_cap_rc=$?
set -e
[ "$no_cap_rc" -eq 2 ] ||
    fail "omitting --integration-cap alone should exit 2, got $no_cap_rc: $no_cap_out"

echo "==> a short --head is a usage error, exit 2"
write_defaults
clean_result="$(write_integrator_result short-head "$(codex_cycle_json 0)")"
set +e
short_out="$("$gate" check --repo example/repo --pr 493 --head abc123 \
    --record "$record_dir" --integrator-result "$clean_result" 2>&1)"
short_rc=$?
set -e
[ "$short_rc" -eq 2 ] ||
    fail "a short --head should exit 2, got $short_rc: $short_out"

# ---------------------------------- gh-ro ----------------------------------

refuse_case() {
    label=$1
    shift
    set +e
    ro_out="$("$ghro" "$@" 2>&1)"
    ro_rc=$?
    set -e
    [ "$ro_rc" -eq 2 ] ||
        fail "gh-ro $label: expected refusal rc 2, got $ro_rc: $ro_out"
    printf '%s\n' "$ro_out" | grep -Fq 'refused' ||
        fail "gh-ro $label: refusal did not say refused: $ro_out"
    if grep -q '^api ' "$log"; then
        fail "gh-ro $label: a refused invocation still reached gh: $(cat "$log")"
    fi
}

echo "==> gh-ro refuses every mutation-capable argument"
write_defaults
refuse_case "-X POST" repos/example/repo/issues/493/comments -X POST
refuse_case "--method DELETE" repos/example/repo/issues/comments/1 --method DELETE
refuse_case "--method=PATCH" repos/example/repo/pulls/493 --method=PATCH
refuse_case "-f body" repos/example/repo/issues/493/comments -f body=hi
refuse_case "--field" repos/example/repo/issues/493/comments --field body=hi
refuse_case "-F body" repos/example/repo/issues/493/comments -F body=@file
refuse_case "--raw-field" repos/example/repo/issues/493/comments --raw-field body=hi
refuse_case "--input" repos/example/repo/issues/493/comments --input payload.json
refuse_case "--hostname" repos/example/repo/pulls/493 --hostname ghe.example
refuse_case "--header" repos/example/repo/pulls/493 -H 'Accept: application/vnd.github+json'
refuse_case "unknown flag" repos/example/repo/pulls/493 --verbose
refuse_case "attached -XGET" repos/example/repo/pulls/493 -XGET
refuse_case "graphql" graphql -f query=x
refuse_case "graphql alone" graphql
refuse_case "/graphql" /graphql
refuse_case "GraphQL case" GraphQL
refuse_case "absolute https URL" https://api.github.com/repos/example/repo/pulls/493
refuse_case "absolute http URL" http://127.0.0.1/latest/meta-data
refuse_case "two endpoints" repos/a/b/pulls/1 repos/a/b/pulls/2
refuse_case "no endpoint" --paginate
refuse_case "trailing -X without value" repos/a/b/pulls/1 -X

echo "==> gh-ro forwards a vetted read and pins --method GET exactly once"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghro" repos/example/repo/pulls/493/comments --paginate --slurp --jq '.[0]' \
    >/dev/null
grep -Fxq 'api --method GET --paginate --slurp --jq .[0] repos/example/repo/pulls/493/comments' "$log" ||
    fail "gh-ro forwarded unexpected arguments: $(cat "$log")"

echo "==> gh-ro accepts an explicit GET without duplicating the method flag"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghro" user --jq .login -X GET >/dev/null
grep -Fxq 'api --method GET --jq .login user' "$log" ||
    fail "gh-ro -X GET handling forwarded unexpected arguments: $(cat "$log")"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghro" user --method=GET >/dev/null
grep -Fxq 'api --method GET user' "$log" ||
    fail "gh-ro --method=GET handling forwarded unexpected arguments: $(cat "$log")"

echo "==> gh-ro propagates gh's own exit code"
write_defaults
printf '7\n' >"${fixtures}/ro-exit"
set +e
"$ghro" repos/example/repo/pulls/493/comments --paginate >/dev/null 2>&1
ro_rc=$?
set -e
[ "$ro_rc" -eq 7 ] ||
    fail "gh-ro should propagate gh's exit 7, got $ro_rc"

# ------------------------------ gh-write-broker -----------------------------

wb_refuse_case() {
    label=$1
    shift
    set +e
    wb_out="$("$ghwb" "$@" 2>&1)"
    wb_rc=$?
    set -e
    [ "$wb_rc" -eq 2 ] ||
        fail "gh-write-broker $label: expected refusal rc 2, got $wb_rc: $wb_out"
    printf '%s\n' "$wb_out" | grep -qE 'refused|Usage:' ||
        fail "gh-write-broker $label: refusal did not say refused or print usage: $wb_out"
    if grep -q '^api ' "$log"; then
        fail "gh-write-broker $label: a refused invocation still reached gh: $(cat "$log")"
    fi
}

echo "==> gh-write-broker refuses a malformed or mismatched call before reaching gh"
write_defaults
reply_body="${fixtures}/reply-body.txt"
printf 'exact reply text' >"$reply_body"
empty_body="${fixtures}/empty-body.txt"
: >"$empty_body"
wb_refuse_case "trigger with --comment-id" trigger --repo example/repo --pr 493 --comment-id 900
wb_refuse_case "trigger with --body-file" trigger --repo example/repo --pr 493 --body-file "$reply_body"
wb_refuse_case "reply missing --comment-id" reply --repo example/repo --pr 493 --body-file "$reply_body"
wb_refuse_case "reply missing --body-file" reply --repo example/repo --pr 493 --comment-id 900
wb_refuse_case "reply with nonexistent --body-file" reply --repo example/repo --pr 493 --comment-id 900 --body-file "${fixtures}/does-not-exist.txt"
wb_refuse_case "reply with empty --body-file" reply --repo example/repo --pr 493 --comment-id 900 --body-file "$empty_body"
wb_refuse_case "reply with non-numeric --comment-id" reply --repo example/repo --pr 493 --comment-id abc --body-file "$reply_body"
wb_refuse_case "top-level is not a recognized subcommand" top-level --repo example/repo --pr 493 --body-file "$reply_body"
wb_refuse_case "invalid repo" trigger --repo not-a-repo --pr 493
wb_refuse_case "invalid pr" trigger --repo example/repo --pr abc
wb_refuse_case "unknown subcommand" delete --repo example/repo --pr 493
wb_refuse_case "no subcommand"

echo "==> gh-write-broker trigger posts exactly the hardcoded body, nothing else"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghwb" trigger --repo example/repo --pr 493 >/dev/null
grep -Fxq "api repos/example/repo/issues/493/comments -f body=@codex review --jq .id" "$log" ||
    fail "gh-write-broker trigger forwarded unexpected arguments: $(cat "$log")"

echo "==> gh-write-broker reply posts exactly the given file to exactly that comment's replies"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghwb" reply --repo example/repo --pr 493 --comment-id 900 --body-file "$reply_body" >/dev/null
grep -Fxq "api repos/example/repo/pulls/493/comments/900/replies -F body=@${reply_body}" "$log" ||
    fail "gh-write-broker reply forwarded unexpected arguments: $(cat "$log")"

echo "==> gh-write-broker propagates gh's own exit code"
write_defaults
printf '7\n' >"${fixtures}/ro-exit"
set +e
"$ghwb" trigger --repo example/repo --pr 493 >/dev/null 2>&1
wb_rc=$?
set -e
[ "$wb_rc" -eq 7 ] ||
    fail "gh-write-broker should propagate gh's exit 7, got $wb_rc"

echo "integration readiness gate + gh-ro + gh-write-broker: PASS"
