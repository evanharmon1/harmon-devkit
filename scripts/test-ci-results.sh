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

accept_required "trusted jobs succeeding" success check=success security=success
accept_required "fork-suppressed jobs skipping" skipped check=skipped security=skipped
reject_required "a skipped trusted job" success check=success security=skipped
reject_required "a successful fork-suppressed job" skipped check=skipped security=success
reject_required "a failed job" success check=success security=failure
reject_required "a cancelled job" success check=success security=cancelled
reject_required "an unknown job result" success check=success security=unknown
reject_required "an empty result" success check=success security=
reject_required "an empty job name" success =success
reject_required "a malformed pair" success check
reject_required "an unsupported expectation" neutral check=neutral
reject_required "an empty result set" success

build_workflow="${repo}/.github/workflows/build.yml"
# The shared suite's new parallel job must retain the same fork boundary as
# lint, and both aggregate paths must account for its result.
yq -e '.jobs.verify.needs | contains(["repo-guards"])' "$build_workflow" >/dev/null ||
    fail 'verify must depend on repo-guards'
[ "$(yq -r '.jobs."repo-guards".if' "$build_workflow")" = "$(yq -r '.jobs.check.if' "$build_workflow")" ] ||
    fail 'repo-guards must use the same untrusted-fork boundary as check'
yq -e '.jobs."repo-guards".steps[] | select(.run == "task ci:repo-guards")' "$build_workflow" >/dev/null ||
    fail 'the required suite job must run the shared Taskfile suite'
yq -r '.jobs.verify.steps[] | select(.name == "Verify deliberate skips at the untrusted-fork boundary") | .run' "$build_workflow" |
    grep -F 'check_skipped repo-guards "$REPO_GUARDS_RESULT"' >/dev/null ||
    fail 'fork aggregation must verify the suite was deliberately skipped'
for result in failure cancelled skipped; do
    reject_required "a $result shared suite" success check=success "repo-guards=$result" security=success
done
accept_required "the shared suite succeeds" success check=success repo-guards=success security=success
accept_required "the fork suite skips" skipped check=skipped repo-guards=skipped security=skipped

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

# A docs skip is evidence from a successful classifier, on PRs only.
if ! output="$(DOCS_ONLY=true CHANGES_RESULT=success CI_EVENT_NAME=pull_request \
    DOCS_ONLY_JOBS='build-test' "$verifier" changes=success check=success build-test=skipped 2>&1)"; then
    fail 'classifier-authorized skip rejected'
fi
grep -Fq 'Job build-test deliberately skipped: docs-only' <<<"$output" ||
    fail 'deliberate skip was not reported distinctly'
for classifier_result in failure cancelled skipped ''; do
    if DOCS_ONLY=true CHANGES_RESULT="$classifier_result" CI_EVENT_NAME=pull_request \
        DOCS_ONLY_JOBS='build-test' "$verifier" build-test=skipped >/dev/null 2>&1; then
        fail "upstream-failure skip accepted ($classifier_result)"
    fi
done
for event in push merge_group workflow_dispatch ''; do
    if DOCS_ONLY=true CHANGES_RESULT=success CI_EVENT_NAME="$event" \
        DOCS_ONLY_JOBS='build-test' "$verifier" build-test=skipped >/dev/null 2>&1; then
        fail "docs-only skip accepted on $event"
    fi
done
for docs_only in false unknown ''; do
    if DOCS_ONLY="$docs_only" CHANGES_RESULT=success CI_EVENT_NAME=pull_request \
        DOCS_ONLY_JOBS='build-test' "$verifier" build-test=skipped >/dev/null 2>&1; then
        fail "skip accepted with docs_only=$docs_only"
    fi
done
if DOCS_ONLY=true CHANGES_RESULT=success CI_EVENT_NAME=pull_request \
    DOCS_ONLY_JOBS='build-test' "$verifier" security=skipped >/dev/null 2>&1; then
    fail 'security skip accepted on a docs-only PR'
fi
if DOCS_ONLY=true CHANGES_RESULT=success CI_EVENT_NAME=pull_request \
    DOCS_ONLY_JOBS='build-test' "$verifier" check=failure build-test=skipped >/dev/null 2>&1; then
    fail 'docs skip hid a failed always-on job'
fi

# Root-only CI coverage needs the stress job bound into both verifier paths.
# Generated consumers do not declare that root-only job, so their rendered
# workflow takes the same aggregate checks without these extra assertions.
if grep -Eq '^  session-cleanup-stress:' "$repo/.github/workflows/build.yml"; then
    trusted_inline="$(awk '
        /name: Verify required jobs succeeded/ { step = 1 }
        step && /^        run: / { sub(/^        run: /, ""); print; exit }
    ' "$repo/.github/workflows/build.yml")"
    [ -n "$trusted_inline" ] || fail 'inline trusted aggregate was not found'
    trusted_aggregate() {
        CHANGES_RESULT=success CHECK_RESULT=success REPO_GUARDS_RESULT=success \
            DEVCONTAINER_PERMISSIONS_RESULT=success TEMPLATE_TEST_RESULT=success \
            SESSION_CLEANUP_STRESS_RESULT="$1" \
            bash -c "cd \"$repo\" && $trusted_inline" >/dev/null 2>&1
    }
    trusted_aggregate success || fail 'inline aggregate rejected successful cleanup stress'
    for result in failure cancelled skipped; do
        if trusted_aggregate "$result"; then
            fail "inline aggregate accepted cleanup stress result: $result"
        fi
    done
fi

# Exercise the actual inline fork aggregate: it must fail if a job did not
# skip at the fork boundary, rather than treating an upstream failure as a skip.
inline="$(awk '
    /name: Verify deliberate skips at the untrusted-fork boundary/ { step = 1 }
    step && /^        run: \|/ { body = 1; next }
    body && /^      -/ { exit }
    body { sub(/^          /, ""); print }
' "$repo/.github/workflows/build.yml")"
[ -n "$inline" ] || fail 'inline fork aggregate was not found'
fork_aggregate() {
    TEST_CONTRACTS_RESULT=skipped TEST_HELPERS_RESULT=skipped TEST_SKILLS_RESULT=skipped \
        CHANGES_RESULT="$1" CHECK_RESULT=skipped REPO_GUARDS_RESULT=skipped \
        DEVCONTAINER_PERMISSIONS_RESULT=skipped TEMPLATE_TEST_RESULT=skipped \
        SESSION_CLEANUP_STRESS_RESULT="${2:-skipped}" \
        CODEGEN_GUARD_RESULT=skipped SECURITY_RESULT=skipped BUILD_TEST_RESULT=skipped \
        E2E_RESULT=skipped LIGHTHOUSE_RESULT=skipped RENDER_PARITY_RESULT=skipped \
        bash -c "$inline" >/dev/null 2>&1
}
fork_aggregate skipped || fail 'inline aggregate rejected deliberate fork skips'
if fork_aggregate failure; then
    fail 'inline aggregate accepted a classifier failure at the fork boundary'
fi
if grep -Eq '^  session-cleanup-stress:' "$repo/.github/workflows/build.yml" &&
    fork_aggregate skipped success; then
    fail 'inline aggregate accepted a non-skipped cleanup stress job at the fork boundary'
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
