#!/usr/bin/env bash
# Offline behavioral tests: the review marker is independent of claim ownership.
set -euo pipefail
cd "$(dirname "$0")/.."

script="$PWD/ai/skills/universal/track-work/assets/clear-needs-review.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NR_CALLS"
kind="$1" operation="$2" number="$3"
case "$kind:$number" in
issue:42) file="$NR_STATE/issue.json" ;;
pr:73) file="$NR_STATE/pr.json" ;;
*) exit 9 ;;
esac
case "$operation" in
view)
    [ "$NR_SCENARIO" != read-fail ] || exit 7
    if [ "$kind" = pr ] && [ "$NR_SCENARIO" = pr-read-fail ]; then exit 7; fi
    cat "$file"
    ;;
edit)
    [[ "$*" == *" --remove-label "* ]] || exit 9
    if [ "$NR_SCENARIO" = write-fail ] ||
        { [ "$kind" = pr ] && [ "$NR_SCENARIO" = pr-write-fail ]; }; then exit 8; fi
    [ "$NR_SCENARIO" != ignored-removal ] || exit 0
    label="${@: -1}"
    jq --arg label "$label" '.labels |= map(select(.name != $label))' "$file" >"$file.next"
    mv "$file.next" "$file"
    ;;
*) exit 9 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

run_helper() {
    local rc=0
    : >"$tmp/calls"
    env PATH="$tmp/bin:$PATH" NR_CALLS="$tmp/calls" NR_SCENARIO="$scenario" NR_STATE="$tmp" \
        "$script" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
    printf '%s\n' "$rc"
}

setup_case() {
    scenario="$1"
    jq -n --arg label "${2:-needs-review}" '{labels:[{name:"feature"},{name:"claim:gpt"},{name:"needs-review-extra"},{name:$label}],
        closedByPullRequestsReferences:[{number:73,url:"https://github.com/test-owner/test.repo/pull/73"},
            {number:99,url:"https://github.com/foreign/repo/pull/99"}]}' >"$tmp/issue.json"
    jq -n '{labels:[{name:"Needs-Review"},{name:"feature"}]}' >"$tmp/pr.json"
}
assert_clear() {
    jq -e 'all(.labels[]; (.name | ascii_downcase) != "needs-review")' "$1" >/dev/null || fail "$1 retains needs-review"
}

setup_case present
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "paired cleanup should succeed: $(cat "$tmp/err")"
assert_clear "$tmp/issue.json"
assert_clear "$tmp/pr.json"
jq -e '.labels | length == 3' "$tmp/issue.json" >/dev/null || fail "cleanup touched unrelated issue labels"
grep -Fxq 'pr edit 73 --repo test-owner/test.repo --remove-label Needs-Review' "$tmp/calls" || fail "PR removal must use exact live spelling"
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "retry must be idempotent"
! grep -q ' edit ' "$tmp/calls" || fail "absent markers must not write"

setup_case case-variant Needs-Review
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "mixed-case label should be removed"
grep -Fxq 'issue edit 42 --repo test-owner/test.repo --remove-label Needs-Review' "$tmp/calls" || fail "issue removal must use exact live name"

# PR-end Refs callers have no closing link; preserve existing argv with event context.
for binding in explicit event; do
    setup_case present
    printf '%s\n' '{"labels":[],"closedByPullRequestsReferences":[]}' >"$tmp/issue.json"
    if [ "$binding" = explicit ]; then
        result="$(run_helper --repo test-owner/test.repo --issue 42 --pr 73)"
    else
        result="$(GH_REPO=test-owner/test.repo PR_NUMBER=73 run_helper --repo test-owner/test.repo --issue 42)"
    fi
    [ "$result" = 0 ] || fail "$binding PR binding failed: $(cat "$tmp/err")"
    assert_clear "$tmp/pr.json"
done

setup_case present
printf '%s\n' '{"labels":[],"closedByPullRequestsReferences":[]}' >"$tmp/issue.json"
[ "$(GH_REPO=foreign/repo PR_NUMBER=99 run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "foreign event must be ignored"
! grep -q '^pr ' "$tmp/calls" || fail "foreign event must not select a PR"

for failure in read-fail pr-read-fail write-fail pr-write-fail ignored-removal; do
    setup_case "$failure"
    [ "$(run_helper --repo test-owner/test.repo --issue 42)" != 0 ] || fail "$failure must propagate"
    case "$failure" in
    read-fail | pr-read-fail)
        ! grep -q ' edit ' "$tmp/calls" || fail "read failure must precede every write"
        ;;
    esac
done
# A PR write failure leaves the issue clear; retry must still discover and clear the PR.
setup_case pr-write-fail
[ "$(run_helper --repo test-owner/test.repo --issue 42)" != 0 ] || fail "partial failure must fail"
assert_clear "$tmp/issue.json"
scenario=present
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "partial retry must complete"
assert_clear "$tmp/pr.json"

scenario=present
for bad_pr in abc 0 -1 '73;echo bad'; do
    [ "$(run_helper --repo test-owner/test.repo --issue 42 --pr "$bad_pr")" != 0 ] || fail "invalid PR accepted"
    [ ! -s "$tmp/calls" ] || fail "invalid PR must fail before gh"
done
for bad_issue in abc 0 -1 '42;echo bad' '42/1'; do
    [ "$(run_helper --repo test-owner/test.repo --issue "$bad_issue")" != 0 ] || fail "invalid issue accepted: $bad_issue"
    [ ! -s "$tmp/calls" ] || fail "invalid issue must be refused before gh"
done
for bad_repo in owner owner/repo/extra 'owner/repo;bad' 'owner name/repo' /repo owner/; do
    [ "$(run_helper --repo "$bad_repo" --issue 42)" != 0 ] || fail "invalid repo accepted: $bad_repo"
    [ ! -s "$tmp/calls" ] || fail "invalid repo must be refused before gh"
done
for missing in --repo --issue; do
    [ "$(run_helper "$missing")" != 0 ] || fail "missing argument accepted"
    [ ! -s "$tmp/calls" ] || fail "missing argument must be refused before gh"
done
[ "$(run_helper --issue 42)" != 0 ] || fail "missing repo accepted"
[ ! -s "$tmp/calls" ] || fail "missing repo must be refused before gh"
[ "$(run_helper --repo test-owner/test.repo)" != 0 ] || fail "missing issue accepted"
[ ! -s "$tmp/calls" ] || fail "missing issue must be refused before gh"
[ "$(run_helper --help)" = 0 ] || fail "help should succeed"
[ ! -s "$tmp/calls" ] || fail "help must not call gh"

echo "ALL PASS"
