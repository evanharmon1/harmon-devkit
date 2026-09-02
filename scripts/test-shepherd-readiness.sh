#!/usr/bin/env bash
# Hermetic regression tests for the shepherd readiness gate and the read-only
# gh wrapper (ai/skills/universal/shepherd/assets/readiness-gate.sh, gh-ro.sh).
#
# The point of the gate is that no condition can be printed-and-promoted past:
# every fixture below asserts an exit code AND the machine token naming the
# decisive condition, and the full-pass fixture asserts the fingerprint is
# printed and stable. gh is stubbed on PATH; nothing talks to the network.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assets="${repo_root}/ai/skills/universal/shepherd/assets"
test_tmp="$(mktemp -d -t shepherd-readiness-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

bin_dir="${test_tmp}/bin"
fixtures="${test_tmp}/fixtures"
log="${test_tmp}/gh.log"
mkdir -p "$bin_dir" "$fixtures"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The gate resolves its Codex helper as a sibling of its own path, so the
# suite runs a byte-identical copy of the gate beside a STUB helper — that is
# the only way to pin the helper-exit mapping without a live Codex cycle.
# gh-ro.sh has no siblings to resolve and runs from the repo directly.
gate_dir="${test_tmp}/assets"
mkdir -p "$gate_dir"
cp "${assets}/readiness-gate.sh" "$gate_dir/"
gate="${gate_dir}/readiness-gate.sh"
ghro="${assets}/gh-ro.sh"
cat >"${gate_dir}/check-codex-cloud-review.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex-helper %s\n' "$*" >>"$GH_LOG"
rc=0
[ ! -f "$GH_FIXTURES/codex-exit" ] || rc="$(cat "$GH_FIXTURES/codex-exit")"
if [ "$rc" = 0 ]; then
    jq -cn '{status:"clean"}'
else
    jq -cn '{status:"stub-not-clean"}'
fi
exit "$rc"
STUB
chmod +x "${gate_dir}/check-codex-cloud-review.sh"

# Watchdog for gate invocations, same idiom as test-shepherd-codex.sh: a
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
moved_sha="2222222222222222222222222222222222222222"

default_body() {
    cat <<'BODY'
What/why prose.

## Deferred findings

- [x] scripts/a.sh:10 — quoting hardening — fixed in abc1234
- [x] docs/b.md:5 — wording nit — declined: the current prose is the accurate one
- [x] scripts/c.sh:1 — edge case — filed as #999

## Verification

- task verify
BODY
}

write_defaults() {
    jq -cn --arg head "$head_sha" \
        '{state:"OPEN",isDraft:true,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED"}' \
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
    # A Codex attempt state naming THIS repo, PR, and head — the gate refuses
    # to hand the helper a state file describing anything else.
    jq -cn --arg head "$head_sha" \
        '{version:1,repo:"example/repo",pr:493,head:$head,
          attempt:1,phase:"attached"}' >"${fixtures}/codex-state.json"
    printf '%s\n' '[[]]' >"${fixtures}/inline.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/reviews.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/top.pages.json"
    printf '%s\n' \
        '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"T1","isResolved":false}]}}}}}]' \
        >"${fixtures}/threads.pages.json"
    rm -f "${fixtures}/fail-endpoint" "${fixtures}/codex-exit"
    rm -f "${fixtures}/pr-view-count" "${fixtures}/pr-view-second.json"
    rm -f "${fixtures}"/count-* "${fixtures}"/second-*
    rm -f "${fixtures}/ro-exit"
    : >"$log"
}

run_gate() {
    set +e
    gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" check \
        --repo example/repo --pr 493 --head "$head_sha" "$@" 2>&1)"
    gate_rc=$?
    set -e
    check_watchdog "$gate_rc" run_gate "$gate_out"
}

run_audit() {
    set +e
    gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" audit \
        --repo example/repo --pr 493 --head "$head_sha" "$@" 2>&1)"
    gate_rc=$?
    set -e
    check_watchdog "$gate_rc" run_audit "$gate_out"
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

echo "==> full pass prints a fingerprint, stable across two runs on identical data"
write_defaults
printf '0\n' >"${fixtures}/codex-exit"
run_gate --codex-state "${fixtures}/codex-state.json"
assert_gate 0 pass ready
first_fingerprint="$(gate_field fingerprint)"
[ -n "$first_fingerprint" ] && [ "$first_fingerprint" != "null" ] ||
    fail "pass did not print a fingerprint: $gate_out"
grep -q 'codex-helper check' "$log" ||
    fail "the enabled-Codex pass did not invoke the sibling helper"
# The classifier must run AFTER the fingerprint surfaces are captured, so
# Codex activity inside the baseline has been classified by a later read.
codex_log_line="$(grep -n 'codex-helper check' "$log" | head -n 1 | cut -d: -f1)"
threads_log_line="$(grep -n '^api graphql' "$log" | head -n 1 | cut -d: -f1)"
[ -n "$codex_log_line" ] && [ -n "$threads_log_line" ] &&
    [ "$codex_log_line" -gt "$threads_log_line" ] ||
    fail "the Codex classifier must run after the fingerprint-surface fetches (codex at line $codex_log_line, threads at $threads_log_line)"
rm -f "${fixtures}/pr-view-count"
run_gate --codex-state "${fixtures}/codex-state.json"
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
run_gate --codex-disabled
assert_gate 0 pass ready
if grep -q 'codex-helper' "$log"; then
    fail "--codex-disabled must not invoke the Codex helper"
fi

echo "==> a closed PR fails as pr-not-open"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"MERGED",isDraft:false,headRefOid:$head,
      reviewDecision:"",mergeStateStatus:"UNKNOWN"}' >"${fixtures}/pr-view.json"
run_gate --codex-disabled
assert_gate 1 fail pr-not-open

echo "==> a non-draft PR fails as pr-not-draft"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view.json"
run_gate --codex-disabled
assert_gate 1 fail pr-not-draft

echo "==> a head other than the adjudicated one fails as head-mismatch"
write_defaults
jq -cn --arg head "$moved_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view.json"
run_gate --codex-disabled
assert_gate 1 fail head-mismatch

echo "==> a failing check run fails as checks-failing and names the check"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {name:"build",status:"completed",conclusion:"success"},
    {name:"lint",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate --codex-disabled
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'lint' ||
    fail "checks-failing did not name the failing check: $gate_out"

echo "==> a pending (unconcluded) check run fails as checks-pending"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {name:"build",status:"completed",conclusion:"success"},
    {name:"verify",status:"in_progress",conclusion:null}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate --codex-disabled
assert_gate 1 fail checks-pending
printf '%s\n' "$gate_out" | grep -Fq 'verify' ||
    fail "checks-pending did not name the pending check: $gate_out"

echo "==> a failing latest legacy status fails as checks-failing"
write_defaults
jq -cn '[[{context:"ci/legacy",state:"success",id:1},
          {context:"ci/legacy",state:"failure",id:3}]]' \
    >"${fixtures}/statuses.pages.json"
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
assert_gate 0 pass ready

echo "==> an EMPTY check list is indeterminate, never a pass"
write_defaults
printf '%s\n' '[{"total_count":0,"check_runs":[]}]' \
    >"${fixtures}/check-runs.pages.json"
printf '%s\n' '[[]]' >"${fixtures}/statuses.pages.json"
run_gate --codex-disabled
assert_gate 2 indeterminate checks-indeterminate

echo "==> CHANGES_REQUESTED fails as changes-requested"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"CHANGES_REQUESTED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view.json"
run_gate --codex-disabled
assert_gate 1 fail changes-requested

echo "==> DIRTY and BEHIND fail; UNKNOWN is indeterminate"
for pair in "DIRTY 1 fail merge-state-dirty" "BEHIND 1 fail merge-state-behind" \
    "UNKNOWN 2 indeterminate merge-state-unknown"; do
    # shellcheck disable=SC2086
    set -- $pair
    write_defaults
    jq -cn --arg head "$head_sha" --arg ms "$1" \
        '{state:"OPEN",isDraft:true,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:$ms}' \
        >"${fixtures}/pr-view.json"
    run_gate --codex-disabled
    assert_gate "$2" "$3" "$4"
done

echo "==> an unchecked deferred finding fails as deferred-unchecked"
write_defaults
body="$(printf '## Deferred findings\n\n- [ ] scripts/a.sh:10 — still open\n')"
jq -cn --arg head "$head_sha" --arg body "$body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/pr.json"
run_gate --codex-disabled
assert_gate 1 fail deferred-unchecked

echo "==> a ticked deferred finding without an outcome fails as deferred-no-outcome"
write_defaults
body="$(printf '## Deferred findings\n\n- [x] scripts/a.sh:10 — says done, shows nothing\n')"
jq -cn --arg head "$head_sha" --arg body "$body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/pr.json"
run_gate --codex-disabled
assert_gate 1 fail deferred-no-outcome

echo "==> a body with no deferred-findings section passes that condition"
write_defaults
jq -cn --arg head "$head_sha" \
    '{number:493,title:"t",body:"plain body",head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/pr.json"
run_gate --codex-disabled
assert_gate 0 pass ready

echo "==> an unanswered inline thread fails as threads-unanswered"
write_defaults
jq -cn '[[{id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
           created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
           body:"finding"}]]' >"${fixtures}/inline.pages.json"
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
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
run_gate --codex-disabled
assert_gate 1 fail threads-edited-since-reply

echo "==> --allow-edited-root clears exactly that edited root"
write_defaults
edited_thread
run_gate --codex-disabled --allow-edited-root 900
assert_gate 0 pass ready

echo "==> --allow-edited-root never clears an unanswered thread"
write_defaults
jq -cn '[[{id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
           created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
           body:"finding"}]]' >"${fixtures}/inline.pages.json"
run_gate --codex-disabled --allow-edited-root 900
assert_gate 1 fail threads-unanswered

echo "==> a failed identity lookup is indeterminate, never answered"
write_defaults
printf 'user' >"${fixtures}/fail-endpoint"
run_gate --codex-disabled
assert_gate 2 indeterminate fetch-failed

echo "==> a failed inline-comment fetch is indeterminate, never a pass"
write_defaults
printf 'pulls/493/comments' >"${fixtures}/fail-endpoint"
run_gate --codex-disabled
assert_gate 2 indeterminate fetch-failed

echo "==> a failed fingerprint-surface fetch (reviews) is indeterminate"
write_defaults
printf 'pulls/493/reviews' >"${fixtures}/fail-endpoint"
run_gate --codex-disabled
assert_gate 2 indeterminate fetch-failed

echo "==> a failed thread-resolution fetch (graphql) is indeterminate"
write_defaults
printf 'graphql' >"${fixtures}/fail-endpoint"
run_gate --codex-disabled
assert_gate 2 indeterminate fetch-failed

echo "==> a head that moves mid-gate fails as head-moved on the final re-read"
write_defaults
jq -cn --arg head "$moved_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view-second.json"
run_gate --codex-disabled
assert_gate 1 fail head-moved

echo "==> a promotion mid-gate fails as pr-not-draft on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view-second.json"
run_gate --codex-disabled
assert_gate 1 fail pr-not-draft

echo "==> Codex helper findings/pending/retry/escalate all fail as codex-not-clean"
for helper_rc in 10 11 12 13; do
    write_defaults
    printf '%s\n' "$helper_rc" >"${fixtures}/codex-exit"
    run_gate --codex-state "${fixtures}/codex-state.json"
    assert_gate 1 fail codex-not-clean
done

echo "==> Codex helper exit 2 is codex-indeterminate"
write_defaults
printf '2\n' >"${fixtures}/codex-exit"
run_gate --codex-state "${fixtures}/codex-state.json"
assert_gate 2 indeterminate codex-indeterminate

echo "==> a missing Codex attempt state is codex-indeterminate, never a pass"
write_defaults
run_gate --codex-state "${fixtures}/no-such-state.json"
assert_gate 2 indeterminate codex-indeterminate

echo "==> a Codex state for another PR is refused before the helper ever runs"
write_defaults
jq -cn --arg head "$head_sha" \
    '{version:1,repo:"example/repo",pr:777,head:$head,
      attempt:1,phase:"attached"}' >"${fixtures}/codex-state.json"
run_gate --codex-state "${fixtures}/codex-state.json"
assert_gate 2 indeterminate codex-indeterminate
if grep -q 'codex-helper check' "$log"; then
    fail "a mismatched state file must not reach the Codex helper"
fi

echo "==> a CHANGES_REQUESTED review landing mid-gate fails on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"CHANGES_REQUESTED",mergeStateStatus:"BLOCKED"}' \
    >"${fixtures}/pr-view-second.json"
run_gate --codex-disabled
assert_gate 1 fail changes-requested

echo "==> a DIRTY merge state arising mid-gate fails on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"DIRTY"}' \
    >"${fixtures}/pr-view-second.json"
run_gate --codex-disabled
assert_gate 1 fail merge-state-dirty

echo "==> the fingerprint is double-read: gated evaluation plus a fresh compare"
write_defaults
run_gate --codex-disabled
assert_gate 0 pass ready
pr_object_fetches="$(grep -cxF 'api repos/example/repo/pulls/493' "$log")"
[ "$pr_object_fetches" -eq 2 ] ||
    fail "expected exactly two PR-object fetches (the gated body, then the fresh compare), saw $pr_object_fetches"

echo "==> a body edit mid-gate fails as content-moved, never laundered into a pass"
write_defaults
edited_body="$(printf '## Deferred findings\n\n- [ ] scripts/sneaky.sh:1 — added after the deferred check ran\n')"
jq -cn --arg head "$head_sha" --arg body "$edited_body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/second-pr.json"
run_gate --codex-disabled
assert_gate 1 fail content-moved
printf '%s\n' "$gate_out" | grep -Fq 'PR-title/body' ||
    fail "content-moved did not name the changed surface: $gate_out"

echo "==> a top-level comment landing mid-gate fails as content-moved"
write_defaults
jq -cn '[[{id:70,user:{login:"reviewer-bot"},body:"a late finding",
           updated_at:"2026-08-01T03:00:00Z"}]]' \
    >"${fixtures}/second-top.pages.json"
run_gate --codex-disabled
assert_gate 1 fail content-moved
printf '%s\n' "$gate_out" | grep -Fq 'top-level-comments' ||
    fail "content-moved did not name the changed surface: $gate_out"

echo "==> a check turning red mid-gate fails on the final re-evaluation"
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {name:"late-red",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/second-check-runs.pages.json"
run_gate --codex-disabled
assert_gate 1 fail checks-failing
printf '%s\n' "$gate_out" | grep -Fq 'late-red' ||
    fail "the final re-evaluation did not name the late-failing check: $gate_out"

echo "==> a second deferred-findings section cannot hide open findings"
write_defaults
dup_body="$(printf '## Deferred findings\n\nnone recorded here\n\n## Notes\n\nprose\n\n## Deferred findings\n\n- [ ] scripts/late.sh:1 — appended in a later section\n')"
jq -cn --arg head "$head_sha" --arg body "$dup_body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/pr.json"
run_gate --codex-disabled
assert_gate 1 fail deferred-unchecked

echo "==> unindented body prose cannot lend a ticked entry an outcome"
write_defaults
prose_body="$(printf '## Deferred findings\n\n- [x] scripts/a.sh:10 — outcome missing\nUnrelated paragraph mentioning declined: something else entirely.\n')"
jq -cn --arg head "$head_sha" --arg body "$prose_body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/pr.json"
run_gate --codex-disabled
assert_gate 1 fail deferred-no-outcome

echo "==> an indented continuation line can carry the outcome"
write_defaults
cont_body="$(printf '## Deferred findings\n\n- [x] scripts/a.sh:10 — long entry wraps\n  declined: reviewer agreed in the thread\n')"
jq -cn --arg head "$head_sha" --arg body "$cont_body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/pr.json"
run_gate --codex-disabled
assert_gate 0 pass ready

echo "==> a bare 'declined:' with no rationale settles nothing"
write_defaults
bare_body="$(printf '## Deferred findings\n\n- [x] scripts/a.sh:10 — waved away — declined:\n')"
jq -cn --arg head "$head_sha" --arg body "$bare_body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/pr.json"
run_gate --codex-disabled
assert_gate 1 fail deferred-no-outcome

echo "==> a child heading does not end the deferred section"
write_defaults
child_body="$(printf '## Deferred findings\n\n### Challenge findings\n\n- [ ] scripts/x.sh:2 — listed under a child heading\n\n## Verification\n\n- ok\n')"
jq -cn --arg head "$head_sha" --arg body "$child_body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/pr.json"
run_gate --codex-disabled
assert_gate 1 fail deferred-unchecked

echo "==> without GNU timeout the gate still runs, loudly unbounded"
write_defaults
restricted_bin="${test_tmp}/restricted-bin"
mkdir -p "$restricted_bin"
for tool in bash jq grep tr dirname cat; do
    tool_path="$(command -v "$tool")" ||
        fail "missing $tool for the no-timeout fixture"
    ln -s "$tool_path" "${restricted_bin}/$tool"
done
for hasher in sha256sum shasum; do
    hasher_path="$(command -v "$hasher" 2>/dev/null || true)"
    [ -z "$hasher_path" ] || ln -s "$hasher_path" "${restricted_bin}/$hasher"
done
ln -s "${bin_dir}/gh" "${restricted_bin}/gh"
set +e
gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" env PATH="$restricted_bin" \
    "$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --codex-disabled 2>&1)"
gate_rc=$?
set -e
check_watchdog "$gate_rc" no-timeout-fallback "$gate_out"
assert_gate 0 pass ready
printf '%s\n' "$gate_out" | grep -Fq 'no GNU timeout' ||
    fail "the timeout fallback must warn that calls are unbounded: $gate_out"

nondraft_pr_view() {
    jq -cn --arg head "$head_sha" \
        '{state:"OPEN",isDraft:false,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED"}' \
        >"${fixtures}/pr-view.json"
}

echo "==> audit passes a green already-promoted PR (check refuses the same PR)"
write_defaults
nondraft_pr_view
run_audit --codex-disabled
assert_gate 0 pass audit
write_defaults
nondraft_pr_view
run_gate --codex-disabled
assert_gate 1 fail pr-not-draft

echo "==> audit still fails red checks on an already-promoted PR"
write_defaults
nondraft_pr_view
jq -cn '[{total_count:1,check_runs:[
    {name:"lint",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_audit --codex-disabled
assert_gate 1 fail checks-failing

echo "==> audit refuses a draft target — there is no promotion to audit"
write_defaults
run_audit --codex-disabled
assert_gate 1 fail pr-draft

echo "==> the Codex mode is never skippable by silence"
write_defaults
set +e
usage_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" 2>&1)"
usage_rc=$?
set -e
[ "$usage_rc" -eq 2 ] ||
    fail "omitting both Codex flags should exit 2, got $usage_rc: $usage_out"
printf '%s\n' "$usage_out" | grep -Fq 'codex' ||
    fail "the missing-Codex-mode error does not say what is missing: $usage_out"
set +e
both_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --codex-disabled --codex-state "${fixtures}/codex-state.json" 2>&1)"
both_rc=$?
set -e
[ "$both_rc" -eq 2 ] ||
    fail "passing both Codex flags should exit 2, got $both_rc: $both_out"

echo "==> a short --head is a usage error, exit 2"
set +e
short_out="$("$gate" check --repo example/repo --pr 493 --head abc123 \
    --codex-disabled 2>&1)"
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

echo "shepherd readiness gate + gh-ro: PASS"
