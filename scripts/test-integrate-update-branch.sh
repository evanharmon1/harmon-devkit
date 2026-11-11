#!/usr/bin/env bash
# Hermetic behavioural tests for the integration stage's guarded server-side
# catch-up (ai/skills/universal/integrate/assets/update-branch.sh,
# harmon-devkit#1360).
#
# gh is stubbed on PATH and every call is logged, so each fixture asserts the
# exit code, what was printed, and what was (or was not) sent to GitHub: the
# helper's whole point is that it sends one PUT, in merge mode, guarded by the
# captured head — and nothing when a precondition fails.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/ai/skills/universal/integrate/assets/update-branch.sh"
skill_md="${repo_root}/ai/skills/universal/integrate/SKILL.md"
test_tmp="$(mktemp -d -t integrate-update-branch-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

bin_dir="${test_tmp}/bin"
fixtures="${test_tmp}/fixtures"
log="${test_tmp}/gh.log"
mkdir -p "$bin_dir"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "FAIL: $*" >&2
    exit 1
}

head_sha=1111111111111111111111111111111111111111
base_oid=2222222222222222222222222222222222222222
new_sha=3333333333333333333333333333333333333333
other_sha=4444444444444444444444444444444444444444
# The PR's baseRefOid, deliberately stale: GitHub keeps it at the base of the
# last head update, so the helper must read the tip from refs/heads/<base>.
stale_base_oid=5555555555555555555555555555555555555555
advanced_sha=6666666666666666666666666666666666666666

# The stub serves `pr view` from pr-<n>.json for the n-th read (falling back to
# the highest-numbered fixture at or below n), the PUT from put-out/put-err/
# put-exit, and the commit GET from commit.json.
cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    [ ! -f "$GH_FIXTURES/pr-view-exit" ] || exit "$(cat "$GH_FIXTURES/pr-view-exit")"
    count=0
    [ ! -f "$GH_FIXTURES/pr-count" ] || count="$(cat "$GH_FIXTURES/pr-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$GH_FIXTURES/pr-count"
    # A slow read after the first: exec, so the helper's timeout signals the
    # sleep itself and no orphan holds the command substitution's pipe open.
    if [ "$count" -ge 2 ] && [ -f "$GH_FIXTURES/pr-slow" ]; then
        exec sleep "$(cat "$GH_FIXTURES/pr-slow")"
    fi
    n=$count
    while [ "$n" -gt 1 ] && [ ! -f "$GH_FIXTURES/pr-$n.json" ]; do
        n=$((n - 1))
    done
    cat "$GH_FIXTURES/pr-$n.json"
    exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = PUT ]; then
    [ ! -f "$GH_FIXTURES/put-out" ] || cat "$GH_FIXTURES/put-out"
    [ ! -f "$GH_FIXTURES/put-err" ] || cat "$GH_FIXTURES/put-err" >&2
    exit "$(cat "$GH_FIXTURES/put-exit" 2>/dev/null || echo 0)"
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = GET ]; then
    case "${4:-}" in
    */git/ref/heads/*)
        # ref.json for the first read of the branch tip, ref-2.json (when
        # present) for later ones.
        [ ! -f "$GH_FIXTURES/ref-exit" ] || exit "$(cat "$GH_FIXTURES/ref-exit")"
        reads=0
        [ ! -f "$GH_FIXTURES/ref-count" ] || reads="$(cat "$GH_FIXTURES/ref-count")"
        reads=$((reads + 1))
        printf '%s\n' "$reads" >"$GH_FIXTURES/ref-count"
        if [ "$reads" -ge 2 ] && [ -f "$GH_FIXTURES/ref-2.json" ]; then
            cat "$GH_FIXTURES/ref-2.json"
        else
            cat "$GH_FIXTURES/ref.json"
        fi
        ;;
    */compare/*)
        # compare-<from>...<to>.json; an unscripted comparison fails.
        f="$GH_FIXTURES/compare-${4##*/compare/}.json"
        [ -f "$f" ] || exit 1
        cat "$f"
        ;;
    *)
        [ -f "$GH_FIXTURES/commit.json" ] || exit 1
        cat "$GH_FIXTURES/commit.json"
        ;;
    esac
    exit 0
fi
exit 90
STUB
chmod +x "${bin_dir}/gh"

pr_json() {
    # $1 head, $2 baseRefName, $3 state (default OPEN), $4 isDraft (default true)
    jq -cn --arg h "$1" --arg b "$2" --arg o "$stale_base_oid" --arg s "${3:-OPEN}" \
        --argjson d "${4:-true}" \
        '{state:$s,isDraft:$d,headRefOid:$h,baseRefName:$b,baseRefOid:$o}'
}

commit_json() {
    # $1 first parent, $2 second parent, $3 committer name, $4 verified
    jq -cn --arg p1 "$1" --arg p2 "$2" --arg n "$3" --argjson v "$4" \
        '{sha:"x",parents:[{sha:$p1},{sha:$p2}],
          commit:{committer:{name:$n,email:"noreply@github.com"},
                  verification:{verified:$v,reason:(if $v then "valid" else "unsigned" end)}}}'
}

reset() {
    rm -rf "$fixtures"
    mkdir -p "$fixtures"
    : >"$log"
    pr_json "$head_sha" main >"${fixtures}/pr-1.json"
    pr_json "$new_sha" main >"${fixtures}/pr-2.json"
    printf '%s\n' '{"message":"Updating pull request branch.","url":"https://github.com/o/r/pull/7"}' >"${fixtures}/put-out"
    commit_json "$head_sha" "$base_oid" GitHub true >"${fixtures}/commit.json"
    ref_json "$base_oid" >"${fixtures}/ref.json"
}

ref_json() {
    jq -cn --arg s "$1" '{ref:"refs/heads/main",object:{sha:$s,type:"commit"}}'
}

compare_json() {
    # $1 from, $2 to, $3 status
    jq -cn --arg s "$3" '{status:$s}' >"${fixtures}/compare-${1}...${2}.json"
}

run_helper() {
    rc=0
    out="$(PATH="${bin_dir}:$PATH" GH_LOG="$log" GH_FIXTURES="$fixtures" \
        "$helper" "$@" 2>"${test_tmp}/stderr")" || rc=$?
    err="$(cat "${test_tmp}/stderr")"
}

run_default() {
    # Success-path fixtures need enough budget for the recording gh process
    # under parallel suite load. Explicit zero-wait coverage stays below.
    run_helper --repo o/r --pr 7 --head "$head_sha" --base main --wait 30 --interval 0 "$@"
}

expect() {
    # $1 label, $2 expected rc, $3 stderr substring (or "")
    [ "$rc" -eq "$2" ] || fail "$1: expected rc $2, got $rc (stdout: $out; stderr: $err)"
    [ -z "$3" ] || case "$err" in
    *"$3"*) ;;
    *) fail "$1: stderr lacks '$3': $err" ;;
    esac
    return 0
}

no_put() {
    ! grep -q -- '--method PUT' "$log" || fail "$1: a PUT was sent: $(cat "$log")"
}

checker_json() {
    jq -cn --arg h "$head_sha" --argjson verdict "$1" \
        '{version:2,repo:"o/r",pr:7,head:$h,phase:"attached",
          last_reviewed_head:$h,last_reviewed_verdict:$verdict}'
}

echo "==> an unsettled cycle refuses catch-up before any GitHub call"
for verdict in null '"findings"' '"pending"'; do
    reset
    checker_json "$verdict" >"${fixtures}/state.json"
    run_default --state "${fixtures}/state.json"
    expect "unsettled ($verdict)" 17 "run a final checker check first"
    [ -z "$out" ] || fail "unsettled cycle printed a head"
    [ ! -s "$log" ] || fail "unsettled cycle reached gh: $(cat "$log")"
done

echo "==> final check recording clean permits the same catch-up"
reset
checker_json '"findings"' >"${fixtures}/state.json"
run_default --state "${fixtures}/state.json"
expect "before final check" 17 "unsettled-cycle"
checker_json '"clean"' >"${fixtures}/state.json"
run_default --state "${fixtures}/state.json"
expect "after final check" 0 ""
[ "$out" = "$new_sha" ] || fail "settled cycle printed '$out'"
[ "$(grep -c -- '--method PUT' "$log")" -eq 1 ] || fail "settled cycle did not send exactly one PUT"

echo "==> absent state permits catch-up with no open cycle"
reset
run_default --state "${fixtures}/absent.json"
expect "no open cycle" 0 "guard found no cycle state"
[ "$out" = "$new_sha" ] || fail "no open cycle printed '$out'"

echo "==> superseded cycle state does not block reconciliation of a new head"
for verdict in '"clean"' '"findings"' null; do
    reset
    checker_json "$verdict" | jq -c --arg old "$other_sha" \
        '.head = $old | .last_reviewed_head = $old' >"${fixtures}/state.json"
    run_default --state "${fixtures}/state.json"
    expect "superseded cycle ($verdict)" 0 ""
    [ "$out" = "$new_sha" ] || fail "superseded cycle printed '$out'"
done

echo "==> invalid, foreign, reserved and stale verdict markers fail closed"
for filter in \
    '.repo = "other/repo"' '.pr = 8' \
    '.phase = "reserved"' '.phase = null' \
    '.last_reviewed_head = "'"$other_sha"'"' \
    'del(.last_reviewed_head)' \
    '.version = 99' '.version = "2"' 'del(.version)' \
    'null' '{}'; do
    reset
    checker_json '"clean"' | jq -c "$filter" >"${fixtures}/state.json"
    run_default --state "${fixtures}/state.json"
    expect "invalid state ($filter)" 17 "unsettled-cycle"
    [ ! -s "$log" ] || fail "invalid state reached gh: $(cat "$log")"
done
for content in '' '{broken' '{"repo":"o/r"} {"repo":"o/r"}'; do
    reset
    printf '%s\n' "$content" >"${fixtures}/state.json"
    run_default --state "${fixtures}/state.json"
    expect "unreadable state ($content)" 17 "unsettled-cycle"
    [ ! -s "$log" ] || fail "unreadable state reached gh: $(cat "$log")"
done
reset
ln -s "${fixtures}/missing.json" "${fixtures}/state.json"
run_default --state "${fixtures}/state.json"
expect "dangling state symlink" 17 "unsettled-cycle"
no_put "dangling state symlink"

echo "==> a clean carried cycle permits another catch-up on its attested head"
reset
checker_json '"clean"' | jq -c --arg old "$other_sha" --arg current "$head_sha" \
    '.head = $old | .last_reviewed_head = $old | .carry = {attests_head:$current}' \
    >"${fixtures}/state.json"
run_default --state "${fixtures}/state.json"
expect "clean carried cycle" 0 ""
[ "$out" = "$new_sha" ] || fail "clean carried cycle printed '$out'"

echo "==> a terminal cycle without a receipt refuses catch-up before any write"
reset
checker_json '"clean"' | jq '.run_id="run-test" | .charged_cycles=1 | .exempt_cycles=0 | .attempt=1 | .trigger_comment_id="200"' >"${fixtures}/state.json"
record_dir="${fixtures}/record"
mkdir -p "$record_dir/passes"
printf '%s\n' '{"run_id":"run-test","pr_bindings":[{"number":7,"url":"https://github.com/o/r/pull/7"}],"receipts":[]}' >"$record_dir/run.json"
run_default --state "${fixtures}/state.json" --record "$record_dir"
expect "terminal unreceipted cycle" 17 "integration-receipt-required"
no_put "terminal unreceipted cycle"
# An actual admitted observation supplies the missing cycle, with exact head,
# trigger and attempt. A mismatched request never substitutes for it.
jq -n --arg h "$head_sha" '{run:{run_id:"run-test"},role:"integrator",status:"completed",head:$h,
  payload:{codex_cycle:{head:$h,cycle:1,attempt:1,trigger_comment_id:"200",exit_code:0}}}' >"$record_dir/passes/integration-r1-integrator.json"
jq '.receipts=[{kind:"pass",file:"integration-r1-integrator"}]' "$record_dir/run.json" >"$record_dir/run.next"
mv "$record_dir/run.next" "$record_dir/run.json"
run_default --state "${fixtures}/state.json" --record "$record_dir"
expect "terminal receipted cycle" 0 ""

echo "==> an unsettled carry for the captured head refuses catch-up"
reset
checker_json '"findings"' | jq -c --arg old "$other_sha" --arg current "$head_sha" \
    '.head = $old | .last_reviewed_head = $old | .carry = {attests_head:$current}' \
    >"${fixtures}/state.json"
run_default --state "${fixtures}/state.json"
expect "unsettled carried cycle" 17 "unsettled-cycle"
no_put "unsettled carried cycle"

echo "==> every repeated state is guarded, regardless of argument order"
for order in first last; do
    reset
    checker_json '"clean"' >"${fixtures}/clean.json"
    checker_json '"findings"' >"${fixtures}/unsettled.json"
    if [ "$order" = first ]; then
        run_default --state "${fixtures}/unsettled.json" --state "${fixtures}/clean.json"
    else
        run_default --state "${fixtures}/clean.json" --state "${fixtures}/unsettled.json"
    fi
    expect "repeated states ($order)" 17 "unsettled-cycle"
    [ ! -s "$log" ] || fail "repeated states reached gh: $(cat "$log")"
done
reset
checker_json '"clean"' >"${fixtures}/clean.json"
checker_json '"clean"' >"${fixtures}/another-clean.json"
run_default --state "${fixtures}/clean.json" --state "${fixtures}/another-clean.json"
expect "two clean finder states" 0 ""
[ "$out" = "$new_sha" ] || fail "two clean finder states printed '$out'"

echo "==> checker-supported versions and quota metadata remain allowed"
for version in 1 2; do
    reset
    checker_json '"clean"' | jq -c --argjson version "$version" \
        '.version = $version | .quota_exhausted_at = "2026-10-13T01:00:00Z"' \
        >"${fixtures}/state.json"
    run_default --state "${fixtures}/state.json"
    expect "supported version $version, quota metadata" 0 ""
    [ "$out" = "$new_sha" ] || fail "supported version printed '$out'"
done
reset
checker_json '"findings"' | jq -c --arg old "$other_sha" \
    '.head = $old | .last_reviewed_head = $old | .version = 99' >"${fixtures}/state.json"
run_default --state "${fixtures}/state.json"
expect "unsupported superseded state" 17 "unsettled-cycle"
no_put "unsupported superseded state"

# ---- required vs advisory finders (harmon-devkit#1887) ----------------------
# The run record's resolved policy, never the caller or a candidate branch,
# decides which states gate. These fixtures reproduce harmon-init#1946: a
# clean required Codex cycle beside incomplete non-gating reviewers.
policy_json() {
    # $1 integration cap (default 6); $2 extra jq filter (default identity)
    jq -cn --argjson cap "${1:-6}" '{rounds:{integration:$cap},
      stages:{integration:{finders:["codex-cloud","claude","greptile"],
        finder:[{id:"codex-cloud",gates:true,carry:"identity"},
                {id:"claude",budget:2,gates:false,carry:"identity"},
                {id:"greptile",budget:1,gates:false,carry:"identity"}]}}}' |
        jq -c "${2:-.}"
}

finder_record() {
    # $1 integration cap; $2 policy filter; $3 run.json filter
    record_dir="${fixtures}/record"
    mkdir -p "$record_dir/passes"
    jq -cn '{run_id:"run-test",pr_bindings:[{number:7,url:"https://github.com/o/r/pull/7"}],receipts:[]}' |
        jq -c "${3:-.}" >"$record_dir/run.json"
    policy_json "${1:-6}" "${2:-.}" >"$record_dir/policy.json"
    # The required Codex cycle is terminal at the captured head, so the
    # receipt guard owes it an admitted integrator pass.
    receipt_pass codex 1 '{codex_cycle:{head:$h,cycle:1,attempt:1,trigger_comment_id:"200",exit_code:0}}'
}

receipt_pass() {
    # $1 label, $2 integration round, $3 jq payload (with $h the captured head)
    jq -n --arg h "$head_sha" "{run:{run_id:\"run-test\"},role:\"integrator\",status:\"completed\",head:\$h,
      payload:$3}" >"$record_dir/passes/integration-r$2-integrator.json"
    jq --arg f "integration-r$2-integrator" '.receipts += [{kind:"pass",file:$f}]' "$record_dir/run.json" >"$record_dir/run.next"
    mv "$record_dir/run.next" "$record_dir/run.json"
}

run_owned='.run_id = "run-test" | .charged_cycles = (.charged_cycles // 1) | .exempt_cycles = 0 | .attempt = (.attempt // 1) | .trigger_comment_id = (.trigger_comment_id // "200")'

finder_state() {
    # $1 slug, $2 verdict JSON, $3 phase (default attached), $4 extra filter
    checker_json "$2" | jq -c --arg s "$1" --arg p "${3:-attached}" \
        '.finder = {slug:$s} | .phase = $p' | jq -c "${4:-.}" | jq -c "$run_owned"
}

mixed_states() {
    # Clean required Codex (legacy finder-null form) beside two advisory
    # cycles in the one leavable shape a non-Codex finder can hold: a
    # usage-limit answer with no verdict, which the checker reserves afresh
    # without a cycle receipt. A released state is used only for Codex (the
    # integration cap 0 and end-to-end cases): the checker's `release` accepts
    # only an untriggered Codex reservation, so a released Greptile or Claude
    # state cannot exist. A cycle with findings for its own head is not
    # leavable (harmon-devkit#1944) and is exercised as a refusal below.
    checker_json '"clean"' | jq -c "$run_owned" >"${fixtures}/codex.json"
    finder_state claude null attached \
        '.quota_exhausted_at = "2026-11-04T01:00:00Z" | .charged_cycles = 1' >"${fixtures}/claude.json"
    finder_state greptile null attached \
        '.quota_exhausted_at = "2026-11-04T02:00:00Z" | .charged_cycles = 1' >"${fixtures}/greptile.json"
}

refusal_names_only_supported_commands() {
    # $1 label. The advisory-cycle-open refusal for a non-Codex finder states
    # the invariant only: it names no checker subcommand, since the recovery
    # commands (`release` in particular) exist for Codex alone. The state path
    # is stripped first so a temp-dir name cannot match.
    refusal="$(grep -F 'advisory-cycle-open' <<<"$err")" ||
        fail "$1: no advisory-cycle-open refusal: $err"
    refusal="${refusal//"$fixtures"/}"
    case "$refusal" in
    *"advisory-cycle-open: codex-cloud "*) fail "$1: expected a non-Codex refusal: $refusal" ;;
    esac
    ! grep -Eqw 'check|release|attach|reserve|settle|carry' <<<"$refusal" ||
        fail "$1: refusal for a non-Codex finder names a checker subcommand: $refusal"
    case "$refusal" in
    *"reached its own finder's terminal completion signal"*"settled through that finder's documented path"*) ;;
    *) fail "$1: refusal does not state the catch-up invariant: $refusal" ;;
    esac
}

open_states() {
    # harmon-init#1946 as observed: claude reserved again after a quota
    # refusal, greptile reserved with its one budgeted request spent. Neither
    # is terminal, so a head move would strand both.
    checker_json '"clean"' | jq -c "$run_owned" >"${fixtures}/codex.json"
    finder_state claude null reserved \
        '.quota_exhausted_at = "2026-11-04T01:00:00Z" | .charged_cycles = 1' >"${fixtures}/claude.json"
    finder_state greptile null reserved '.charged_cycles = 1 | .attempt = 2' >"${fixtures}/greptile.json"
}

state_sums() {
    cksum "${fixtures}/codex.json" "${fixtures}/claude.json" "${fixtures}/greptile.json"
}

mixed_args=()
set_mixed_args() {
    mixed_args=(--state "${fixtures}/codex.json" --state "${fixtures}/claude.json"
        --state "${fixtures}/greptile.json")
}

echo "==> a terminal advisory cycle beside a clean required one permits catch-up"
reset
finder_record
mixed_states
set_mixed_args
before_sums="$(state_sums)"
run_default "${mixed_args[@]}" --record "$record_dir"
expect "mixed required/advisory" 0 "advisory-unsettled: claude"
expect "mixed required/advisory" 0 "usage limit answered"
expect "mixed required/advisory" 0 "advisory-unsettled: greptile"
expect "mixed required/advisory" 0 "not a completed clean review"
expect "mixed required/advisory" 0 "stops at head-changed"
case "$err" in
*"stay observed"*) fail "the relaxation still claims the cycle stays observed: $err" ;;
esac
[ "$out" = "$new_sha" ] || fail "mixed required/advisory printed '$out'"
[ "$(grep -c -- '--method PUT' "$log")" -eq 1 ] || fail "mixed required/advisory did not send exactly one PUT"
grep -q -- "expected_head_sha=${head_sha}" "$log" || fail "mixed catch-up lost expected_head_sha: $(cat "$log")"
# Nothing about an advisory cycle is rewritten: request history, budget
# spend, quota marker and phase stay exactly as the checker left them.
[ "$(state_sums)" = "$before_sums" ] || fail "the helper rewrote a checker state"

echo "==> a terminal advisory findings cycle refuses catch-up with no GitHub write"
# The checker's reserve owes a terminal cycle with a verdict for its own head
# a receipt before reserving the finder afresh, and the integrator keeps
# non-gating activity out of finder_cycles and codex_cycle, so the head move
# would strand it until a non-gating cycle can be receipted (#1944).
reset
finder_record
mixed_states
finder_state greptile '"findings"' attached '.charged_cycles = 1' >"${fixtures}/greptile.json"
set_mixed_args
before_sums="$(state_sums)"
run_default "${mixed_args[@]}" --record "$record_dir"
expect "advisory findings" 17 "advisory-cycle-open: greptile"
expect "advisory findings" 17 "until a non-gating cycle can be receipted (harmon-devkit#1944)"
refusal_names_only_supported_commands "advisory findings"
[ -z "$out" ] || fail "advisory findings printed a head"
[ ! -s "$log" ] || fail "advisory findings reached gh: $(cat "$log")"
[ "$(state_sums)" = "$before_sums" ] || fail "advisory findings rewrote a checker state"

echo "==> a required finder's terminal cycle without a receipt still refuses"
reset
mixed_states
finder_record
jq '.receipts = []' "$record_dir/run.json" >"$record_dir/run.next"
mv "$record_dir/run.next" "$record_dir/run.json"
set_mixed_args
run_default "${mixed_args[@]}" --record "$record_dir"
expect "unreceipted required cycle" 17 "integration-receipt-required"
expect "unreceipted required cycle" 17 "codex-cloud cycle 1"
[ -z "$out" ] || fail "unreceipted required cycle printed a head"
[ ! -s "$log" ] || fail "unreceipted required cycle reached gh: $(cat "$log")"

echo "==> a non-terminal advisory cycle refuses catch-up with no GitHub write"
# challenge-r1-codex-adversarial-1: after a head move the checker's check
# stops at head-changed before reading evidence, attach refuses the moved
# head, and a reserved state blocks the finder's next reservation. A pending
# or reserved advisory cycle would be stranded, so the catch-up waits for it.
for case_name in observed reserved reserved-quota awaiting-answer stale-verdict; do
    reset
    finder_record
    # Each case is the terminal mixed set with one advisory cycle reopened,
    # except `observed`, which is harmon-init#1946's two reserved cycles.
    case "$case_name" in
    observed) open_states ;;
    reserved)
        mixed_states
        finder_state greptile null reserved >"${fixtures}/greptile.json"
        ;;
    reserved-quota)
        mixed_states
        finder_state claude null reserved '.quota_exhausted_at = "2026-11-04T01:00:00Z"' >"${fixtures}/claude.json"
        ;;
    awaiting-answer)
        mixed_states
        finder_state greptile null attached >"${fixtures}/greptile.json"
        ;;
    stale-verdict)
        mixed_states
        finder_state greptile '"findings"' attached \
            ".last_reviewed_head = \"${other_sha}\"" >"${fixtures}/greptile.json"
        ;;
    esac
    set_mixed_args
    before_sums="$(state_sums)"
    run_default "${mixed_args[@]}" --record "$record_dir"
    expect "open advisory ($case_name)" 17 "advisory-cycle-open"
    expect "open advisory ($case_name)" 17 "No GitHub write was made"
    # challenge-r2-codex-adversarial-1: every refusal here is for claude or
    # greptile, for which the checker has no `release`; the recovery is the
    # invariant, never a Codex-only command.
    refusal_names_only_supported_commands "open advisory ($case_name)"
    [ -z "$out" ] || fail "open advisory ($case_name) printed a head"
    [ ! -s "$log" ] || fail "open advisory ($case_name) reached gh: $(cat "$log")"
    [ "$(state_sums)" = "$before_sums" ] || fail "open advisory ($case_name) rewrote a checker state"
done

echo "==> a required finder's guard is unchanged by the advisory refusal"
# A reserved or unanswered required cycle still refuses as unsettled-cycle,
# never as an advisory refusal, and before any GitHub call.
for phase in reserved attached; do
    reset
    finder_record
    mixed_states
    finder_state codex-cloud null "$phase" >"${fixtures}/codex.json"
    set_mixed_args
    run_default "${mixed_args[@]}" --record "$record_dir"
    expect "required $phase" 17 "unsettled-cycle"
    case "$err" in
    *advisory-cycle-open*) fail "required $phase was reported as advisory: $err" ;;
    esac
    [ ! -s "$log" ] || fail "required $phase reached gh: $(cat "$log")"
done

echo "==> after a permitted catch-up the checker accepts the left-behind advisory state for a fresh reservation"
# End to end against the real checker: it proves only that the terminal
# advisory state a relaxed catch-up leaves behind is one `reserve` accepts
# for a fresh reservation on the new head, or the relaxation would strand the
# finder after all. The reservation itself is the legacy Codex-shaped one
# (no `--finder`); it does not exercise per-finder registry plumbing. The
# checker runs from a seeded fixture
# checkout (its asset-freshness probe needs a full, non-shallow history whose
# HEAD is the PR base) with a stub gh answering only what reserve reads.
checker_src="${repo_root}/ai/skills/universal/integrate/assets"
checker_repo="${test_tmp}/checker-repo"
checker_assets="${checker_repo}/ai/skills/universal/integrate/assets"
mkdir -p "$checker_assets" "${checker_repo}/ai/skills/universal/dev-flow-support/assets"
for asset in check-codex-cloud-review.sh asset-freshness.sh gh-write-broker.sh trusted-registry.sh; do
    cp "${checker_src}/${asset}" "${checker_assets}/${asset}"
done
cp -R "${repo_root}/ai/skills/universal/dev-flow-support/assets/lib" \
    "${checker_repo}/ai/skills/universal/dev-flow-support/assets/"
git init -q "$checker_repo"
git -C "$checker_repo" config user.name "Update Branch Test"
git -C "$checker_repo" config user.email "update-branch-test@example.invalid"
git -C "$checker_repo" add ai
git -C "$checker_repo" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m "test: seed checker assets"
checker_base="$(git -C "$checker_repo" rev-parse HEAD)"
checker_bin="${test_tmp}/checker-bin"
mkdir -p "$checker_bin"
cat >"${checker_bin}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CHECKER_GH_LOG"
case "$*" in
*"--json baseRefOid"*) printf '%s\n' "$CHECKER_BASE" ;;
*"--json headRefOid,state"*) jq -cn --arg h "$CHECKER_HEAD" '{state:"OPEN",headRefOid:$h}' ;;
"api repos/o/r/pulls/7") jq -cn --arg b "$CHECKER_BASE" '{base:{sha:$b}}' ;;
*) exit 1 ;;
esac
STUB
chmod +x "${checker_bin}/gh"
checker_reserve() {
    # $1 state file; reserves attempt 1 on the caught-up head as this run.
    rc=0
    out="$(cd "$checker_repo" && PATH="${checker_bin}:$PATH" CHECKER_GH_LOG="${test_tmp}/checker-gh.log" \
        CHECKER_BASE="$checker_base" CHECKER_HEAD="$new_sha" \
        CODEX_RESERVE_HEAD_WAIT_SEC=0 CODEX_RESERVE_HEAD_POLL_SEC=0 \
        "${checker_assets}/check-codex-cloud-review.sh" reserve --state "$1" --repo o/r --pr 7 \
        --head "$new_sha" --attempt 1 --run-id run-test --timeout-min 15 \
        --record "$record_dir" 2>"${test_tmp}/stderr")" || rc=$?
    err="$(cat "${test_tmp}/stderr")"
}
# Only the shapes the helper relaxes are reachable here: a usage limit for
# claude, and a release only for Codex (non-gating here under integration cap
# 0), since `release` accepts nothing but an untriggered Codex reservation. A
# findings cycle is refused before catch-up (harmon-devkit#1944).
for terminal in claude-quota codex-released; do
    reset
    if [ "$terminal" = codex-released ]; then
        finder_record 0
    else
        finder_record
    fi
    mixed_states
    case "$terminal" in
    claude-quota) advisory_state="${fixtures}/claude.json" ;;
    codex-released)
        advisory_state="${fixtures}/codex.json"
        checker_json null | jq -c "$run_owned" |
            jq -c '.phase = "released" | .trigger_comment_id = null' >"$advisory_state"
        ;;
    esac
    set_mixed_args
    run_default "${mixed_args[@]}" --record "$record_dir"
    expect "catch-up before reserve ($terminal)" 0 "advisory-unsettled"
    [ "$out" = "$new_sha" ] || fail "catch-up before reserve ($terminal) printed '$out'"
    checker_reserve "$advisory_state"
    [ "$rc" -eq 0 ] || fail "checker refused a fresh reservation after catch-up ($terminal): rc $rc: $err"
    jq -e --arg h "$new_sha" '.phase == "reserved" and .head == $h and .attempt == 1 and
        .run_id == "run-test"' "$advisory_state" >/dev/null ||
        fail "checker did not reserve the new head ($terminal): $(cat "$advisory_state")"
done
# The control: the reserved state the helper now refuses to leave behind is
# exactly one the checker cannot replace on the new head.
reset
finder_record
open_states
checker_reserve "${fixtures}/greptile.json"
[ "$rc" -ne 0 ] || fail "checker replaced an unresolved advisory reservation"
case "$err" in
*"an unresolved reservation must be reconciled"*) ;;
*) fail "checker control refused for another reason: $err" ;;
esac

echo "==> without the trusted record every state is guarded as required"
reset
mixed_states
run_default --state "${fixtures}/greptile.json" --state "${fixtures}/claude.json" --state "${fixtures}/codex.json"
expect "no record" 17 "unsettled-cycle"
[ ! -s "$log" ] || fail "no record reached gh: $(cat "$log")"

echo "==> a required finder still blocks: unsettled, late findings or reserved"
for verdict in null '"findings"' '"pending"'; do
    reset
    finder_record
    mixed_states
    checker_json "$verdict" | jq -c "$run_owned" >"${fixtures}/codex.json"
    set_mixed_args
    run_default "${mixed_args[@]}" --record "$record_dir"
    expect "required unsettled ($verdict)" 17 "unsettled-cycle"
    [ ! -s "$log" ] || fail "required unsettled reached gh: $(cat "$log")"
done
reset
finder_record
mixed_states
finder_state codex-cloud '"findings"' attached >"${fixtures}/codex.json"
set_mixed_args
run_default "${mixed_args[@]}" --record "$record_dir"
expect "named Codex late findings" 17 "unsettled-cycle"
no_put "named Codex late findings"

echo "==> omitting a required state cannot earn an advisory relaxation"
reset
finder_record
mixed_states
run_default --state "${fixtures}/claude.json" --state "${fixtures}/greptile.json" --record "$record_dir"
expect "required omitted" 17 "required-state-missing"
expect "required omitted" 17 "codex-cloud"
no_put "required omitted"
reset
finder_record
mixed_states
run_default --state "${fixtures}/absent-codex.json" --state "${fixtures}/greptile.json" --record "$record_dir"
expect "required state absent" 17 "required-state-missing"
no_put "required state absent"

echo "==> a finder the policy makes required by budget or gates stays required"
# gates omitted (legacy default) and an ambiguous duplicate profile both gate.
for filter in \
    '.stages.integration.finder |= map(if .id == "greptile" then del(.gates) else . end)' \
    '.stages.integration.finder += [{id:"greptile",gates:false,budget:1}]'; do
    reset
    finder_record 6 "$filter"
    mixed_states
    set_mixed_args
    run_default "${mixed_args[@]}" --record "$record_dir"
    expect "greptile required ($filter)" 17 "unsettled-cycle"
    no_put "greptile required ($filter)"
done
# budget 0 opts a finder out, as integration cap 0 opts every finder out.
reset
finder_record 6 '.stages.integration.finder |= map(if .id == "greptile" then .gates = true | .budget = 0 else . end)'
mixed_states
set_mixed_args
run_default "${mixed_args[@]}" --record "$record_dir"
expect "greptile budget 0" 0 "advisory-unsettled: greptile"
reset
finder_record 0
mixed_states
# Under cap 0 Codex is non-gating: a released reservation relaxes, findings for
# its own head refuse until a non-gating cycle can be receipted (#1944), and an
# unanswered cycle is still not terminal, so it refuses.
checker_json null | jq -c "$run_owned" |
    jq -c '.phase = "released" | .trigger_comment_id = null' >"${fixtures}/codex.json"
set_mixed_args
run_default "${mixed_args[@]}" --record "$record_dir"
expect "integration cap 0" 0 "advisory-unsettled: codex-cloud"
checker_json '"findings"' | jq -c "$run_owned" >"${fixtures}/codex.json"
: >"$log"
run_default "${mixed_args[@]}" --record "$record_dir"
expect "integration cap 0, findings" 17 "advisory-cycle-open: codex-cloud"
expect "integration cap 0, findings" 17 "harmon-devkit#1944"
[ ! -s "$log" ] || fail "integration cap 0, findings reached gh: $(cat "$log")"
checker_json null | jq -c "$run_owned" >"${fixtures}/codex.json"
: >"$log"
run_default "${mixed_args[@]}" --record "$record_dir"
expect "integration cap 0, unanswered" 17 "advisory-cycle-open"
[ ! -s "$log" ] || fail "integration cap 0, unanswered reached gh: $(cat "$log")"
# Only a Codex cycle's refusal names the checker commands, because only
# there do they apply.
expect "integration cap 0, unanswered" 17 "reached its own finder's terminal completion signal"
expect "integration cap 0, unanswered" 17 "For this Codex cycle that means a checker check"
expect "integration cap 0, unanswered" 17 "a checker release of an untriggered reservation"

echo "==> a missing, unreadable, unbound or unknown-slug policy fails closed"
for case_name in missing-policy broken-policy bad-cap unbound-record unknown-slug no-finders; do
    reset
    finder_record
    mixed_states
    case "$case_name" in
    missing-policy) rm -f "$record_dir/policy.json" ;;
    broken-policy) printf '{broken\n' >"$record_dir/policy.json" ;;
    bad-cap) policy_json 6 '.rounds.integration = "6"' >"$record_dir/policy.json" ;;
    unbound-record) finder_record 6 . '.pr_bindings = [{number:8,url:"https://github.com/o/r/pull/8"}]' ;;
    unknown-slug) finder_state copilot-cloud null reserved >"${fixtures}/greptile.json" ;;
    no-finders) policy_json 6 'del(.stages.integration.finders)' >"$record_dir/policy.json" ;;
    esac
    set_mixed_args
    run_default "${mixed_args[@]}" --record "$record_dir"
    expect "fail closed ($case_name)" 17 "finder-policy-indeterminate"
    # An unbound record is refused by the receipt guard too, whichever runs first.
    [ "$case_name" = unbound-record ] || expect "fail closed ($case_name)" 17 "unsettled-cycle"
    no_put "fail closed ($case_name)"
done

echo "==> a candidate branch's policy and the caller cannot reclassify a finder"
# The helper reads only the record. A working tree whose .devflow.toml marks
# Codex non-gating changes nothing, and there is no caller-side class flag.
reset
finder_record
mixed_states
checker_json null | jq -c "$run_owned" >"${fixtures}/codex.json"
candidate="${fixtures}/candidate"
mkdir -p "$candidate"
printf '%s\n' '[[stage.integration.finder]]' 'id = "codex-cloud"' 'gates = false' >"$candidate/.devflow.toml"
set_mixed_args
rc=0
out="$(cd "$candidate" && PATH="${bin_dir}:$PATH" GH_LOG="$log" GH_FIXTURES="$fixtures" \
    "$helper" --repo o/r --pr 7 --head "$head_sha" --base main --wait 30 --interval 0 \
    "${mixed_args[@]}" --record "$record_dir" 2>"${test_tmp}/stderr")" || rc=$?
err="$(cat "${test_tmp}/stderr")"
expect "candidate policy" 17 "unsettled-cycle"
no_put "candidate policy"
for flag in --advisory --finder-class --gates; do
    reset
    run_default "$flag" codex-cloud
    expect "caller class flag $flag" 2 "unrecognised argument"
    [ ! -s "$log" ] || fail "caller class flag $flag reached gh"
done

echo "==> an advisory state is still structurally guarded"
for filter in '.repo = "other/repo"' '.pr = 8' '.version = 99' '.head = "nope"'; do
    reset
    finder_record
    mixed_states
    jq -c "$filter" "${fixtures}/greptile.json" >"${fixtures}/greptile.next"
    mv "${fixtures}/greptile.next" "${fixtures}/greptile.json"
    set_mixed_args
    run_default "${mixed_args[@]}" --record "$record_dir"
    expect "advisory structure ($filter)" 17 "unsettled-cycle"
    no_put "advisory structure ($filter)"
done

echo "==> a foreign-run advisory state keeps the receipt guard"
reset
finder_record
mixed_states
jq -c '.run_id = "run-other"' "${fixtures}/greptile.json" >"${fixtures}/greptile.next"
mv "${fixtures}/greptile.next" "${fixtures}/greptile.json"
set_mixed_args
run_default "${mixed_args[@]}" --record "$record_dir"
expect "foreign-run advisory" 17 "integration-receipt-required"
no_put "foreign-run advisory"

echo "==> a mixed catch-up keeps retarget, concurrent-push and provenance refusals"
reset
finder_record
mixed_states
set_mixed_args
pr_json "$head_sha" release >"${fixtures}/pr-1.json"
run_default "${mixed_args[@]}" --record "$record_dir"
expect "mixed retarget" 14 "base-retargeted"
no_put "mixed retarget"
reset
finder_record
mixed_states
set_mixed_args
pr_json "$other_sha" main >"${fixtures}/pr-1.json"
run_default "${mixed_args[@]}" --record "$record_dir"
expect "mixed concurrent push" 12 "a newer push"
no_put "mixed concurrent push"
reset
finder_record
mixed_states
set_mixed_args
pr_json "$other_sha" main >"${fixtures}/pr-2.json"
commit_json "$base_oid" "$head_sha" GitHub true >"${fixtures}/commit.json"
run_default "${mixed_args[@]}" --record "$record_dir"
expect "mixed push during request" 12 "not this catch-up"
reset
finder_record
mixed_states
set_mixed_args
commit_json "$head_sha" "$base_oid" GitHub false >"${fixtures}/commit.json"
run_default "${mixed_args[@]}" --record "$record_dir"
expect "mixed unsigned merge" 12 "GitHub did not make it"

echo "==> the projection extends configuration with the run's finder selection"
reset
finder_record 6 . '.finder_selection = [{stage:"integration",effective:[{finder:"gemini"}]}]'
projection="$(node "${repo_root}/ai/skills/universal/dev-flow-support/assets/lib/integration-finder-requirements.mjs" \
    classify --record "$record_dir" --repo o/r --pr 7 gemini greptile codex-cloud)" ||
    fail "classify refused a selected finder"
[ "$(jq -c . <<<"$projection")" = '{"classes":{"gemini":"required","greptile":"advisory","codex-cloud":"required"},"required":["codex-cloud","gemini"]}' ] ||
    fail "unexpected projection: $projection"
if node "${repo_root}/ai/skills/universal/dev-flow-support/assets/lib/integration-finder-requirements.mjs" \
    classify --record "$record_dir" --repo o/other --pr 7 greptile >/dev/null 2>&1; then
    fail "classify accepted a record bound to another repository"
fi
finder_record 6 . '.pr_bindings = [{number:7,url:"not a url"}]'
rc=0
err="$(node "${repo_root}/ai/skills/universal/dev-flow-support/assets/lib/integration-finder-requirements.mjs" \
    classify --record "$record_dir" --repo o/r --pr 7 greptile 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 1 ] || fail "classify accepted a malformed bound URL (rc $rc)"
[ "$err" = "the run record is not bound to o/r#7" ] || fail "malformed bound URL reported: $err"

echo "==> a clean catch-up prints GitHub's merge head"
reset
run_default
expect "clean catch-up" 0 ""
[ "$out" = "$new_sha" ] || fail "clean catch-up printed '$out', not $new_sha"
grep -qxF "api --method PUT repos/o/r/pulls/7/update-branch -f expected_head_sha=${head_sha}" "$log" ||
    fail "the PUT was not guarded by the captured head: $(cat "$log")"
[ "$(grep -c -- '--method PUT' "$log")" -eq 1 ] || fail "more than one PUT: $(cat "$log")"
! grep -Eqi 'rebase|update_method|updateMethod|graphql' "$log" ||
    fail "the request carried a rebase mode or GraphQL: $(cat "$log")"
grep -qxF "api --method GET repos/o/r/commits/${new_sha}" "$log" ||
    fail "the new head's provenance was not read: $(cat "$log")"

echo "==> every rebase spelling is refused before any gh call"
for flag in --rebase "--update-method rebase" --update-method=rebase "--method rebase" --method=REBASE; do
    reset
    # shellcheck disable=SC2086 # the flag and its value are split on purpose
    run_default $flag
    expect "rebase ($flag)" 2 "merge mode only"
    [ ! -s "$log" ] || fail "rebase ($flag) reached gh: $(cat "$log")"
done

echo "==> usage errors and unknown flags are refused"
reset
run_helper
expect "no arguments" 2 "Usage"
run_helper --repo o/r --pr 7 --head short --base main
expect "malformed head" 2 "40-hex"
run_helper --repo o/r --pr 7 --head "$head_sha"
expect "missing base" 2 "--base is required"
run_default --force
expect "unknown flag" 2 "unrecognised argument"
run_default --state
expect "missing state value" 2 "Usage"
run_default --state ''
expect "empty state value" 2 "--state requires"
[ ! -s "$log" ] || fail "a refused invocation reached gh: $(cat "$log")"

echo "==> a retarget before the request stops without a PUT"
reset
pr_json "$head_sha" release >"${fixtures}/pr-1.json"
run_default
expect "retarget before" 14 "base-retargeted"
no_put "retarget before"

echo "==> a head that moved before the request is stale, without a PUT"
reset
pr_json "$other_sha" main >"${fixtures}/pr-1.json"
run_default
expect "moved before" 12 "newer push"
no_put "moved before"

echo "==> a PR that is not open is refused, without a PUT"
reset
pr_json "$head_sha" main CLOSED >"${fixtures}/pr-1.json"
run_default
expect "closed PR" 16 "not open"
no_put "closed PR"

echo "==> a PR that is ready for review is refused unless the maintainer asked"
# Challenge round 2: a promoted PR is caught up only on the maintainer's
# request, so the default refuses it before any write.
reset
pr_json "$head_sha" main OPEN false >"${fixtures}/pr-1.json"
run_default
expect "non-draft without the flag" 15 "catch-up requires"
no_put "non-draft without the flag"
reset
pr_json "$head_sha" main OPEN false >"${fixtures}/pr-1.json"
pr_json "$new_sha" main OPEN false >"${fixtures}/pr-2.json"
run_default --maintainer-requested
expect "non-draft with the flag" 0 ""
[ "$out" = "$new_sha" ] || fail "non-draft with the flag printed '$out'"
grep -qF -- '--method PUT' "$log" || fail "non-draft with the flag sent no PUT: $(cat "$log")"
reset
pr_json "$head_sha" main OPEN false >"${fixtures}/pr-1.json"
pr_json "$new_sha" main OPEN false >"${fixtures}/pr-2.json"
run_default --queue-head-upkeep "queue head authorized under ruling 53"
expect "orchestrator queue-head upkeep" 0 "queue head authorized under ruling 53"
[ "$out" = "$new_sha" ] || fail "queue-head upkeep printed '$out'"
grep -qF -- '--method PUT' "$log" || fail "queue-head upkeep sent no PUT"
for missing_reason in missing blank flag; do
    reset
    case "$missing_reason" in
    missing) run_default --queue-head-upkeep ;;
    blank) run_default --queue-head-upkeep "   " ;;
    flag) run_default --queue-head-upkeep --maintainer-requested ;;
    esac
    expect "queue-head upkeep $missing_reason reason" 2 "requires a reason"
    no_put "queue-head upkeep $missing_reason reason"
done
reset
jq -c 'del(.isDraft)' "${fixtures}/pr-1.json" >"${fixtures}/p" && mv "${fixtures}/p" "${fixtures}/pr-1.json"
run_default
expect "missing isDraft" 13 "isDraft"
no_put "missing isDraft"

echo "==> an unreadable PR is indeterminate, without a PUT"
reset
printf '1\n' >"${fixtures}/pr-view-exit"
run_default
expect "unreadable PR" 13 "cannot read"
no_put "unreadable PR"

echo "==> the API's answers are classified"
classify() {
    # $1 label, $2 gh stderr, $3 expected rc, $4 stderr token
    reset
    rm -f "${fixtures}/put-out"
    printf '%s\n' "$2" >"${fixtures}/put-err"
    printf '1\n' >"${fixtures}/put-exit"
    run_default
    expect "$1" "$3" "$4"
    [ "$(grep -c 'pr view' "$log")" -eq 1 ] || fail "$1: the head was polled after a failed request: $(cat "$log")"
}
classify "expected-head refusal" "gh: expected head sha didn't match current head ref. (HTTP 422)" 12 "stale-head"
classify "merge conflict" "gh: merge conflict between base and head (HTTP 422)" 11 "conflict"
# Only a recognized merge refusal falls back (10, 11); every other 4xx is 16.
classify "ruleset refusal" "gh: Repository rule violations found (HTTP 422)" 10 "ruleset"
# A merge-commit ban (linear history) rejects a local merge too: no fallback.
classify "merge-commit ban" "gh: This branch must not contain merge commits. (HTTP 422)" 16 "no fallback"
classify "linear-history ruleset" "gh: Repository rule violations found: This branch must not contain merge commits. (HTTP 422)" 16 "no fallback"
classify "permission refusal" "gh: Resource not accessible by integration (HTTP 403)" 16 "no fallback"
classify "rate limit" "gh: API rate limit exceeded for user ID 1. (HTTP 403)" 16 "no fallback"
classify "authentication failure" "gh: Bad credentials (HTTP 401)" 16 "no fallback"
classify "unknown 422" "gh: Validation Failed (HTTP 422)" 16 "no fallback"
classify "server error" "gh: Server Error (HTTP 502)" 13 "indeterminate"
classify "transport error" "error connecting to api.github.com" 13 "do not request again"

echo "==> a PR GitHub reports already level prints the captured head"
reset
rm -f "${fixtures}/put-out"
printf '%s\n' "gh: There are no new commits on the base branch. (HTTP 422)" >"${fixtures}/put-err"
printf '1\n' >"${fixtures}/put-exit"
run_default
expect "already level" 0 "level"
[ "$out" = "$head_sha" ] || fail "already level printed '$out'"

echo "==> a head still unmoved when the wait ends is indeterminate"
reset
rm -f "${fixtures}/pr-2.json"
run_helper --repo o/r --pr 7 --head "$head_sha" --base main --wait 0 --interval 0
expect "unmoved head" 13 "do not request again"
[ -z "$out" ] || fail "unmoved head printed '$out'"

echo "==> a head that moves within the wait is accepted"
reset
pr_json "$head_sha" main >"${fixtures}/pr-2.json"
pr_json "$new_sha" main >"${fixtures}/pr-3.json"
run_helper --repo o/r --pr 7 --head "$head_sha" --base main --wait 5 --interval 0
expect "late move" 0 ""
[ "$out" = "$new_sha" ] || fail "late move printed '$out'"

echo "==> the wait is bounded by wall clock even when a read is slow"
# P2 of challenge round 1: the wait used to be a sum of sleeps, so one read
# that hung added its whole duration on top. The second read hangs for 30s and
# would then report the moved head; a deadline that holds cuts it short at the
# time left and reports indeterminate well before that.
reset
printf '30\n' >"${fixtures}/pr-slow"
started=$(date +%s)
run_helper --repo o/r --pr 7 --head "$head_sha" --base main --wait 2 --interval 0
elapsed=$(($(date +%s) - started))
expect "slow read" 13 "do not request again"
[ "$elapsed" -lt 15 ] || fail "slow read: the wait ran ${elapsed}s past a 2s deadline"

echo "==> a promotion while the merge ran is reported"
# Challenge round 3: the draft check repeats after the request.
reset
pr_json "$new_sha" main OPEN false >"${fixtures}/pr-2.json"
run_default
expect "promoted mid-call" 15 "promoted while update-branch ran"
[ -z "$out" ] || fail "promoted mid-call printed '$out'"
reset
pr_json "$new_sha" main OPEN false >"${fixtures}/pr-2.json"
run_default --maintainer-requested
expect "promoted mid-call, maintainer-requested" 0 ""

echo "==> no timeout tool on PATH fails closed before any GitHub call"
# Challenge round 3: without timeout/gtimeout a read cannot be cut short, so
# the helper refuses to run rather than wait without a bound. The PATH holds
# only the tools the helper needs before that check, plus the gh stub.
reset
nt_bin="${test_tmp}/no-timeout-bin"
mkdir -p "$nt_bin"
ln -sf "${bin_dir}/gh" "${nt_bin}/gh"
for tool in bash jq grep cat tr date sleep mktemp rm head; do
    ln -sf "$(command -v "$tool")" "${nt_bin}/${tool}"
done
rc=0
out="$(PATH="$nt_bin" GH_LOG="$log" GH_FIXTURES="$fixtures" \
    "$(command -v bash)" "$helper" --repo o/r --pr 7 --head "$head_sha" --base main \
    --wait 0 --interval 0 2>"${test_tmp}/stderr")" || rc=$?
err="$(cat "${test_tmp}/stderr")"
expect "no timeout tool" 13 "neither timeout nor gtimeout"
[ ! -s "$log" ] || fail "no timeout tool reached gh: $(cat "$log")"

echo "==> a retarget while the merge ran stops"
reset
pr_json "$new_sha" release >"${fixtures}/pr-2.json"
run_default
expect "retarget during" 14 "base-retargeted"

echo "==> the base tip comes from the branch, not the PR's stale baseRefOid"
# Integration cycle 1 (P1, observed on PR #1377): baseRefOid stays at the base
# of the last head update. Every fixture's PR carries a stale baseRefOid; this
# one asserts the merge against the branch tip is accepted and the tip was read
# from refs/heads/<base> before the PUT.
reset
run_default
expect "stale baseRefOid" 0 ""
[ "$out" = "$new_sha" ] || fail "stale baseRefOid printed '$out'"
ref_line="$(grep -n 'git/ref/heads/main' "$log" | head -n 1 | cut -d: -f1)"
put_line="$(grep -n -- '--method PUT' "$log" | head -n 1 | cut -d: -f1)"
[ -n "$ref_line" ] && [ -n "$put_line" ] && [ "$ref_line" -lt "$put_line" ] ||
    fail "the base tip was not read from refs/heads/main before the PUT: $(cat "$log")"

echo "==> a base that advanced during the request is accepted"
reset
commit_json "$head_sha" "$advanced_sha" GitHub true >"${fixtures}/commit.json"
compare_json "$base_oid" "$advanced_sha" ahead
ref_json "$advanced_sha" >"${fixtures}/ref-2.json"
compare_json "$advanced_sha" "$advanced_sha" identical
run_default
expect "base advanced during the request" 0 ""
[ "$out" = "$new_sha" ] || fail "base advanced during the request printed '$out'"

echo "==> an unreadable base tip is indeterminate, without a PUT"
reset
printf '1\n' >"${fixtures}/ref-exit"
run_default
expect "unreadable base tip" 13 "cannot read the tip of main"
no_put "unreadable base tip"

echo "==> a head that is not GitHub's catch-up is a newer push"
reset
commit_json "$other_sha" "$base_oid" GitHub true >"${fixtures}/commit.json"
run_default
expect "wrong first parent" 12 "not this catch-up"
reset
commit_json "$head_sha" "$other_sha" GitHub true >"${fixtures}/commit.json"
compare_json "$base_oid" "$other_sha" diverged
run_default
expect "second parent unrelated to the base" 12 "does not descend"
reset
commit_json "$head_sha" "$advanced_sha" GitHub true >"${fixtures}/commit.json"
compare_json "$base_oid" "$advanced_sha" ahead
ref_json "$base_oid" >"${fixtures}/ref-2.json"
compare_json "$advanced_sha" "$base_oid" behind
run_default
expect "descendant no longer on the base" 12 "is not on main"
reset
commit_json "$head_sha" "$other_sha" GitHub true >"${fixtures}/commit.json"
run_default
expect "uncomparable second parent" 13 "cannot compare"
reset
jq -c '.parents = [{sha:"'"$head_sha"'"}]' "${fixtures}/commit.json" >"${fixtures}/c" && mv "${fixtures}/c" "${fixtures}/commit.json"
run_default
expect "single parent" 12 "not this catch-up"
reset
commit_json "$head_sha" "$base_oid" "Some Writer" true >"${fixtures}/commit.json"
run_default
expect "foreign committer" 12 "GitHub did not make it"
reset
commit_json "$head_sha" "$base_oid" GitHub false >"${fixtures}/commit.json"
run_default
expect "unsigned merge" 12 "GitHub did not make it"
reset
rm -f "${fixtures}/commit.json"
run_default
expect "unreadable commit" 13 "provenance"

echo "==> the skill wires the helper in"
skill_flat="$(tr '\n' ' ' <"$skill_md" | tr -s ' ')"
# A GitHub write is never pre-approved: the helper stays behind the prompt.
case "$skill_flat" in
*'assets/update-branch.sh:*)'*) fail "SKILL.md pre-approves update-branch.sh in allowed-tools" ;;
esac
for needle in \
    'Use the same helper with `--maintainer-requested`' \
    '(`assets/update-branch.sh`, a GitHub write that moves the head)' \
    'assets/update-branch.sh --repo <repo> --pr <n>' \
    '**Settle before catching up.** When a cycle or carry attests the current head' \
    'require its clean result before the catch-up moves the head' \
    'git rev-parse --path-format=absolute --git-path' \
    'integrate-codex/<owner>/<repo>/<pr>.json' \
    'Pass one `--state` per configured PR-side finder' \
    'Pass `--state` only once this run has reserved its own cycle' \
    'At integration cap 0 or before this run' \
    'state left by an earlier run must not block reconciliation' \
    'A cycle for a superseded head does not block reconciliation' \
    '--state "$state_file"' \
    '17 unsettled cycle' \
    'against the run record'"'"'s own resolved policy' \
    'prints `advisory-unsettled` and does not block' \
    'refuses with `advisory-cycle-open` (17)' \
    'stops at `head-changed` and reads no further evidence' \
    'Catch-up waits until every advisory cycle has reached its own finder'"'"'s terminal completion signal, or has been settled through that finder'"'"'s documented path.' \
    '(`release` accepts only a Codex reservation)' \
    'The caller cannot choose the class.' \
    'every state is guarded as required' \
    '`required-state-missing` (17) unless a present, readable `--state` names every required finder.' \
    'such a cycle blocks catch-up until a non-gating cycle can be receipted (harmon-devkit#1944)' \
    'independently of cycle receipts' \
    '**Standing routine catch-up authorization.**' \
    'The live handoff check still runs on the new head' \
    'A server-side catch-up spends no remediation round.' \
    'neither of them the run record' \
    '`- Base catch-up: <captured head> → <new head> (update-branch)`'; do
    case "$skill_flat" in
    *"$needle"*) ;;
    *) fail "SKILL.md lost: $needle" ;;
    esac
done

echo "PASS: update-branch.sh"
