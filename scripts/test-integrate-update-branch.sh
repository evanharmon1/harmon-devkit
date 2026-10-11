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
    [ -f "$GH_FIXTURES/commit.json" ] || exit 1
    cat "$GH_FIXTURES/commit.json"
    exit 0
fi
exit 90
STUB
chmod +x "${bin_dir}/gh"

pr_json() {
    # $1 head, $2 baseRefName, $3 state (default OPEN), $4 isDraft (default true)
    jq -cn --arg h "$1" --arg b "$2" --arg o "$base_oid" --arg s "${3:-OPEN}" \
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
}

run_helper() {
    rc=0
    out="$(PATH="${bin_dir}:$PATH" GH_LOG="$log" GH_FIXTURES="$fixtures" \
        "$helper" "$@" 2>"${test_tmp}/stderr")" || rc=$?
    err="$(cat "${test_tmp}/stderr")"
}

run_default() {
    run_helper --repo o/r --pr 7 --head "$head_sha" --base main --wait 0 --interval 0 "$@"
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
expect "closed PR" 10 "not open"
no_put "closed PR"

echo "==> a PR that is ready for review is refused unless the maintainer asked"
# Challenge round 2: a promoted PR is caught up only on the maintainer's
# request, so the default refuses it before any write.
reset
pr_json "$head_sha" main OPEN false >"${fixtures}/pr-1.json"
run_default
expect "non-draft without the flag" 15 "maintainer's request"
no_put "non-draft without the flag"
reset
pr_json "$head_sha" main OPEN false >"${fixtures}/pr-1.json"
pr_json "$new_sha" main OPEN false >"${fixtures}/pr-2.json"
run_default --maintainer-requested
expect "non-draft with the flag" 0 ""
[ "$out" = "$new_sha" ] || fail "non-draft with the flag printed '$out'"
grep -qF -- '--method PUT' "$log" || fail "non-draft with the flag sent no PUT: $(cat "$log")"
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
classify "permission refusal" "gh: Resource not accessible by integration (HTTP 403)" 10 "refused"
classify "ruleset refusal" "gh: Repository rule violations found (HTTP 422)" 10 "refused"
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
run_default
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

echo "==> a retarget while the merge ran stops"
reset
pr_json "$new_sha" release >"${fixtures}/pr-2.json"
run_default
expect "retarget during" 14 "base-retargeted"

echo "==> a head that is not GitHub's catch-up is a newer push"
reset
commit_json "$other_sha" "$base_oid" GitHub true >"${fixtures}/commit.json"
run_default
expect "wrong first parent" 12 "not this catch-up"
reset
commit_json "$head_sha" "$other_sha" GitHub true >"${fixtures}/commit.json"
run_default
expect "base tip moved" 12 "not this catch-up"
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
    'through the same helper with `--maintainer-requested`' \
    '(`assets/update-branch.sh`, a GitHub write that moves the head)' \
    'assets/update-branch.sh --repo <repo> --pr <n>' \
    'A server-side catch-up spends no remediation round.' \
    'neither of them the run record' \
    '`- Base catch-up: <captured head> → <new head> (update-branch)`'; do
    case "$skill_flat" in
    *"$needle"*) ;;
    *) fail "SKILL.md lost: $needle" ;;
    esac
done

echo "PASS: update-branch.sh"
