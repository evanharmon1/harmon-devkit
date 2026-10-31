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
if [ "$kind:$operation" = pr:list ]; then
    cat "$NR_STATE/branch-prs.json"
    exit 0
fi
case "$kind:$number" in
issue:42) file="$NR_STATE/issue.json" ;;
pr:73) file="$NR_STATE/pr.json" ;;
pr:74) file="$NR_STATE/pr74.json" ;;
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
        closedByPullRequestsReferences:[{number:73,repository:{owner:{login:"test-owner"},name:"test.repo"},url:"https://github.com/test-owner/test.repo/pull/73"},
            {number:99,repository:{owner:{login:"foreign"},name:"repo"},url:"https://github.com/foreign/repo/pull/99"},
            {number:97,repository:{owner:{login:"test-owner"},name:"other.repo"}},
            {number:98,repository:{owner:{login:"forker"},name:"test.repo"}}]}' >"$tmp/issue.json"
    printf '%s\n' '[]' >"$tmp/branch-prs.json"
    jq -n '{state:"OPEN",isCrossRepository:false,labels:[{name:"Needs-Review"},{name:"feature"}]}' >"$tmp/pr.json"
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

# Repository identity, rather than a URL prefix or ambient host, selects links.
# Foreign identity must be refused even when its URL appears to match the repo.
setup_case present
jq '.closedByPullRequestsReferences[0].repository.owner.login = "TEST-OWNER"
    | .closedByPullRequestsReferences[0].url = "https://enterprise.example/test-owner/test.repo/pull/73"
    | .closedByPullRequestsReferences[1].url = "https://enterprise.example/test-owner/test.repo/pull/99"' \
    "$tmp/issue.json" >"$tmp/next"
mv "$tmp/next" "$tmp/issue.json"
[ "$(GH_HOST=other.example run_helper --repo Test-Owner/TEST.REPO --issue 42)" = 0 ] || fail "host-independent closing-link cleanup failed"
assert_clear "$tmp/issue.json"
assert_clear "$tmp/pr.json"
for foreign in 97 98 99; do
    ! grep -q "^pr .* $foreign " "$tmp/calls" || fail "foreign repository identity selected PR $foreign"
done

# Malformed closing links refuse before either marker can be changed.
for malformed in missing-repository empty-owner empty-name nonstring-owner nonstring-name; do
    setup_case present
    case "$malformed" in
    missing-repository) mutation='del(.closedByPullRequestsReferences[0].repository)' ;;
    empty-owner) mutation='.closedByPullRequestsReferences[0].repository.owner.login = ""' ;;
    empty-name) mutation='.closedByPullRequestsReferences[0].repository.name = ""' ;;
    nonstring-owner) mutation='.closedByPullRequestsReferences[0].repository.owner.login = 73' ;;
    nonstring-name) mutation='.closedByPullRequestsReferences[0].repository.name = 73' ;;
    esac
    jq "$mutation" "$tmp/issue.json" >"$tmp/next"
    mv "$tmp/next" "$tmp/issue.json"
    [ "$(run_helper --repo test-owner/test.repo --issue 42)" = 1 ] || fail "$malformed must exit 1"
    grep -Fq 'closing link repository identity is malformed' "$tmp/err" || fail "$malformed must explain refusal"
    ! grep -q ' edit ' "$tmp/calls" || fail "$malformed must perform zero edits"
    jq -e 'any(.labels[]; .name == "needs-review")' "$tmp/issue.json" >/dev/null || fail "$malformed cleared issue marker"
    jq -e 'any(.labels[]; .name == "Needs-Review")' "$tmp/pr.json" >/dev/null || fail "$malformed cleared PR marker"
done

# Issue-close callers without a branch or event cannot discover an open Refs PR.
# Pin the documented limit: the issue clears, but no unrelated PR is inferred.
setup_case present
printf '%s\n' '{"labels":[{"name":"needs-review"}],"closedByPullRequestsReferences":[]}' >"$tmp/issue.json"
printf '%s\n' '[{"number":73,"headRefName":"fix/refs","isCrossRepository":false}]' >"$tmp/branch-prs.json"
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "issue-close cleanup failed"
assert_clear "$tmp/issue.json"
jq -e 'any(.labels[]; .name == "Needs-Review")' "$tmp/pr.json" >/dev/null || fail "unbound Refs PR changed"
! grep -q '^pr ' "$tmp/calls" || fail "issue-close inferred a PR without branch/event/closing link"

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
# A PR write failure leaves the issue marker intact; retry still clears both.
setup_case pr-write-fail
[ "$(run_helper --repo test-owner/test.repo --issue 42)" != 0 ] || fail "partial failure must fail"
jq -e 'any(.labels[]; .name == "needs-review")' "$tmp/issue.json" >/dev/null || fail "failed PR cleanup must retain issue marker"
scenario=present
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "partial retry must complete"
assert_clear "$tmp/pr.json"

# A1: discover a Refs delivery from the recorded claim branch, with no event.
setup_case present
printf '%s\n' '{"labels":[{"name":"needs-review"}],"closedByPullRequestsReferences":[]}' >"$tmp/issue.json"
printf '%s\n' '[{"number":73,"headRefName":"fix/refs","isCrossRepository":false},{"number":99,"headRefName":"fix/refs","isCrossRepository":true}]' >"$tmp/branch-prs.json"
[ "$(run_helper --repo test-owner/test.repo --issue 42 --branch fix/refs)" = 0 ] || fail "claim branch discovery failed"
assert_clear "$tmp/issue.json"
assert_clear "$tmp/pr.json"

# R4-A: explicit branch discovery ignores unrelated PR-end environment.
setup_case present
printf '%s\n' '{"labels":[{"name":"needs-review"}],"closedByPullRequestsReferences":[]}' >"$tmp/issue.json"
printf '%s\n' '[{"number":73,"headRefName":"fix/refs","isCrossRepository":false}]' >"$tmp/branch-prs.json"
cp "$tmp/pr.json" "$tmp/pr74.json"
[ "$(GH_REPO=test-owner/test.repo PR_NUMBER=74 run_helper --repo test-owner/test.repo --issue 42 --branch fix/refs)" = 0 ] || fail "R4-A: branch cleanup failed"
assert_clear "$tmp/issue.json"
assert_clear "$tmp/pr.json"
! grep -q '^pr .* 74 ' "$tmp/calls" || fail "R4-A: ambient PR was selected"
jq -e 'any(.labels[]; .name == "Needs-Review")' "$tmp/pr74.json" >/dev/null || fail "R4-A: unrelated PR changed"

# Each fail-closed data guard refuses with a reason before any edit.
for guard in issue-labels branch-shape branch-limit candidate-number pr-labels; do
    setup_case present
    case "$guard" in
    issue-labels)
        jq '.labels = {}' "$tmp/issue.json" >"$tmp/next"
        mv "$tmp/next" "$tmp/issue.json"
        ;;
    branch-shape) printf '%s\n' '{}' >"$tmp/branch-prs.json" ;;
    branch-limit) jq -n '[range(100) | {number:73,headRefName:"fix/refs",isCrossRepository:false}]' >"$tmp/branch-prs.json" ;;
    candidate-number)
        jq '.closedByPullRequestsReferences[0].number = "invalid"' "$tmp/issue.json" >"$tmp/next"
        mv "$tmp/next" "$tmp/issue.json"
        ;;
    pr-labels)
        jq '.labels = {}' "$tmp/pr.json" >"$tmp/next"
        mv "$tmp/next" "$tmp/pr.json"
        ;;
    esac
    [ "$(run_helper --repo test-owner/test.repo --issue 42 --branch fix/refs)" != 0 ] || fail "$guard must refuse"
    [ -s "$tmp/err" ] || fail "$guard must explain refusal"
    ! grep -q ' edit ' "$tmp/calls" || fail "$guard must perform zero edits"
done

# A2: clearing one explicit/event delivery must leave a sibling and the shared
# issue marker intact, until no OTHER open same-repository delivery owes review.
for binding in explicit event; do
    setup_case present
    cp "$tmp/pr.json" "$tmp/pr74.json"
    if [ "$binding" = explicit ]; then
        result="$(run_helper --repo test-owner/test.repo --issue 42 --pr 74)"
    else
        result="$(GH_REPO=test-owner/test.repo PR_NUMBER=74 run_helper --repo test-owner/test.repo --issue 42)"
    fi
    [ "$result" = 0 ] || fail "scoped $binding cleanup failed"
    grep -Fxq NEEDS-REVIEW-RETAINED "$tmp/out" || fail "retained issue outcome must be distinct on stdout"
    assert_clear "$tmp/pr74.json"
    jq -e 'any(.labels[]; .name == "Needs-Review")' "$tmp/pr.json" >/dev/null || fail "sibling PR was cleared"
    jq -e 'any(.labels[]; .name == "needs-review")' "$tmp/issue.json" >/dev/null || fail "shared issue marker was cleared"
    ! grep -q '^pr edit 73 ' "$tmp/calls" || fail "cleanup wrote to sibling"
    jq '.state = "CLOSED"' "$tmp/pr.json" >"$tmp/pr.next"
    mv "$tmp/pr.next" "$tmp/pr.json"
    [ "$(run_helper --repo test-owner/test.repo --issue 42 --pr 74)" = 0 ] || fail "closed sibling retry failed"
    assert_clear "$tmp/issue.json"
    jq '.labels += [{name:"needs-review"}]' "$tmp/issue.json" >"$tmp/issue.next"
    mv "$tmp/issue.next" "$tmp/issue.json"
    jq '.state = "OPEN" | .isCrossRepository = true' "$tmp/pr.json" >"$tmp/pr.next"
    mv "$tmp/pr.next" "$tmp/pr.json"
    [ "$(run_helper --repo test-owner/test.repo --issue 42 --pr 74)" = 0 ] || fail "fork sibling cleanup failed"
    assert_clear "$tmp/issue.json"
    [ ! -s "$tmp/out" ] || fail "cleared issue must not report retention"
done

# S1/S2: branch and explicit-PR pull-back keep closing-linked siblings.
for issue_marker in needs-review Needs-Review; do
    for binding in branch pr; do
        setup_case present "$issue_marker"
        cp "$tmp/pr.json" "$tmp/pr74.json"
        printf '%s\n' '[{"number":74,"headRefName":"fix/claim","isCrossRepository":false}]' >"$tmp/branch-prs.json"
        if [ "$binding" = branch ]; then
            result="$(run_helper --repo test-owner/test.repo --issue 42 --branch fix/claim)"
        else
            result="$(run_helper --repo test-owner/test.repo --issue 42 --pr 74)"
        fi
        [ "$result" = 0 ] || fail "$binding pull-back must clear its own delivery"
        assert_clear "$tmp/pr74.json"
        grep -Fxq NEEDS-REVIEW-RETAINED "$tmp/out" || fail "$binding pull-back must report retained $issue_marker"
        jq -e --arg marker "$issue_marker" 'any(.labels[]; .name == $marker)' "$tmp/issue.json" >/dev/null || fail "shared issue marker was cleared"
        jq -e 'any(.labels[]; .name == "Needs-Review")' "$tmp/pr.json" >/dev/null || fail "closing-linked sibling was cleared"
        ! grep -q '^pr edit 73 ' "$tmp/calls" || fail "pull-back wrote to sibling"
    done
done

# A sibling hold does not retain an issue marker that was already absent.
setup_case present
cp "$tmp/pr.json" "$tmp/pr74.json"
jq '.labels = []' "$tmp/issue.json" >"$tmp/next"
mv "$tmp/next" "$tmp/issue.json"
[ "$(run_helper --repo test-owner/test.repo --issue 42 --pr 74)" = 0 ] || fail "absent issue marker cleanup failed"
[ ! -s "$tmp/out" ] || fail "absent issue marker must not report retention"
assert_clear "$tmp/issue.json"
assert_clear "$tmp/pr74.json"
jq -e 'any(.labels[]; .name == "Needs-Review")' "$tmp/pr.json" >/dev/null || fail "sibling hold changed"

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
