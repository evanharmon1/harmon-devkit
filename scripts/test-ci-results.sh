#!/usr/bin/env bash
# Hermetic truth tables for CI aggregation and closing-keyword semantics.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
verifier="${repo}/scripts/verify-ci-results.sh"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

accept_required() {
    label="$1"
    expected="$2"
    shift 2
    if ! EXPECTED_RESULT="$expected" "$verifier" "$@" >/dev/null 2>&1; then
        fail "CI result helper rejected ${label}"
    fi
}

reject_required() {
    label="$1"
    expected="$2"
    shift 2
    if EXPECTED_RESULT="$expected" "$verifier" "$@" >/dev/null 2>&1; then
        fail "CI result helper accepted ${label}"
    fi
}

accept_required "trusted jobs succeeding" success lint=success security=success
accept_required "fork-suppressed jobs skipping" skipped lint=skipped security=skipped
reject_required "a skipped trusted job" success lint=success security=skipped
reject_required "a successful fork-suppressed job" skipped lint=skipped security=success
reject_required "a failed job" success lint=success security=failure
reject_required "a cancelled job" success lint=success security=cancelled
reject_required "an unknown job result" success lint=success security=unknown
reject_required "an empty result" success lint=success security=
reject_required "an empty job name" success =success
reject_required "a malformed pair" success lint
reject_required "an unsupported expectation" neutral lint=neutral
reject_required "an empty result set" success

build_workflow="${repo}/.github/workflows/build.yml"
# The shared suite's new parallel job must retain the same fork boundary as
# lint, and both aggregate paths must account for its result.
yq -e '.jobs.verify.needs | contains(["test-suite"])' "$build_workflow" >/dev/null ||
    fail 'verify must depend on test-suite'
[ "$(yq -r '.jobs."test-suite".if' "$build_workflow")" = "$(yq -r '.jobs.lint.if' "$build_workflow")" ] ||
    fail 'test-suite must use the same untrusted-fork boundary as lint'
yq -e '.jobs."test-suite".steps[] | select(.run == "task test:suite")' "$build_workflow" >/dev/null ||
    fail 'the required suite job must run the shared Taskfile suite'
yq -r '.jobs.verify.steps[] | select(.name == "Verify deliberate skips at the untrusted-fork boundary") | .run' "$build_workflow" |
    grep -F 'check_skipped test-suite "$TEST_SUITE_RESULT"' >/dev/null ||
    fail 'fork aggregation must verify the suite was deliberately skipped'
for result in failure cancelled skipped; do
    reject_required "a $result shared suite" success lint=success "test-suite=$result" security=success
done
accept_required "the shared suite succeeds" success lint=success test-suite=success security=success
accept_required "the fork suite skips" skipped lint=skipped test-suite=skipped security=skipped

workflow="${repo}/.github/workflows/closing-keywords.yml"
grep -Fq 'types: [opened, edited, synchronize, reopened]' "$workflow" || fail 'metadata guard must re-check every PR edit'
grep -q '^  merge_group:$' "$workflow" || fail 'guard must emit the required check for merge groups'
grep -q '^  closing-keywords:$' "$workflow" || fail 'guard must retain the required closing-keywords check context'
grep -Fq 'group: closing-keywords-${{ github.event.pull_request.number || github.ref }}' "$workflow" || fail 'guard needs independent per-PR or merge-group concurrency'
if grep -Eq '^  closing-keywords:|needs:.*closing-keywords|needs\.closing-keywords\.result|CLOSING_KEYWORDS_RESULT' "$build_workflow"; then
    fail 'Build must not contain or aggregate the standalone metadata guard'
fi
if grep -Eq '^    types:.*edited' "$build_workflow"; then
    fail 'metadata edits must not restart Build'
fi
yq -e '.jobs."closing-keywords".steps[].env | select(.PR_TITLE != null) | .PR_TITLE == "${{ github.event.pull_request.title }}"' "$workflow" >/dev/null ||
    fail 'standalone metadata guard must read the current event title'
yq -e '.jobs."closing-keywords".steps[].env | select(.PR_BODY != null) | .PR_BODY == "${{ github.event.pull_request.body }}"' "$workflow" >/dev/null ||
    fail 'standalone metadata guard must read the current event body'
grep -q 'HEAD_REPO:.*head.repo.full_name' "$workflow" || fail 'bootstrap must compare the PR head repository'
grep -q "grep -q '(HTTP 404)'" "$workflow" || fail 'bootstrap must require a confirmed default-branch 404'
grep -Fq '[ "$HEAD_REPO" = "$GH_REPO" ]' "$workflow" || fail 'bootstrap must permit same-repo heads only'
grep -q 'fetch_script "$DEFAULT_BRANCH"' "$workflow" || fail 'guard must prefer the default-branch script'
grep -q 'fetch_script "$HEAD_SHA"' "$workflow" || fail 'same-repo bootstrap must fetch the head SHA'
grep -q 'PR_COMMITS:.*pull_request.commits' "$workflow" || fail 'guard must receive the PR commit count'
grep -Fq '[ "$PR_COMMITS" -gt 250 ]' "$workflow" || fail 'guard must reject PRs beyond the commits API limit'
grep -Fq 'closing-keyword result is indeterminate' "$workflow" || fail 'commit-limit rejection must be distinct'
commit_limit_line="$(grep -nF '[ "$PR_COMMITS" -gt 250 ]' "$workflow" | cut -d: -f1)"
commits_fetch_line="$(grep -nF 'gh api --paginate "repos/${GH_REPO}/pulls/${PR_NUMBER}/commits"' "$workflow" | cut -d: -f1)"
[ "$commit_limit_line" -lt "$commits_fetch_line" ] || fail 'commit-limit rejection must precede the commits API fetch'

# Keep the closing-keyword fixtures in this CI contract test rather than in an
# orphan target: all five semantic cases run wherever CI checks its result
# aggregation, including generated repositories without vendored skills.
"${repo}/scripts/test-closing-keywords.sh"

echo "CI result helper truth tables: PASS"
