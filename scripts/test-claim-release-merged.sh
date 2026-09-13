#!/usr/bin/env bash
# test-claim-release-merged.sh — offline coverage for merged-PR claim release.
set -euo pipefail
cd "$(dirname "$0")/.."

script="$PWD/scripts/claim-release-merged.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    [ -f "$tmp/out" ] && sed 's/^/    /' "$tmp/out" >&2
    exit 1
}

cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
*'--json closingIssuesReferences'*) printf '%s\n' "${GH_CLOSING:-}" ;;
*'--json body'*) printf '%s\n' "${GH_BODY:-}" ;;
*'repos/'*)
    issue=""
    for arg in "$@"; do
        case "$arg" in
        repos/*/issues/*) issue="${arg##*/}" ;;
        esac
    done
    body="${GH_ISSUE_BODY:-## Acceptance criteria\n- [x] [CI] Done}"
    if [ "$issue" = "${GH_HUMAN_ISSUE:-}" ]; then
        body="${GH_HUMAN_BODY:-$body}"
    fi
    printf '{"state":"%s","body":%s}\n' "${GH_ISSUE_STATE:-open}" "$(printf '%s' "$body" | jq -Rs .)"
    ;;
*) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

cat >"$tmp/release-claim.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
issue=""
args="$*"
while [ "$#" -gt 0 ]; do
    case "$1" in
    --issue) issue="$2"; shift 2 ;;
    *) shift ;;
    esac
done
printf '%s\n' "$args" >>"${RELEASE_LOG:?}"
if [ "$issue" = "${RELEASE_FAIL_ISSUE:-}" ]; then
    exit "${RELEASE_FAIL_RC:-7}"
fi
if [ "$issue" = "${RELEASE_NO_CLAIM_ISSUE:-}" ]; then
    exit 3
fi
if [ "$issue" = "${RELEASE_IDEMPOTENT_ISSUE:-}" ]; then
    if [ -e "${RELEASE_STATE:?}" ]; then exit 3; fi
    : >"${RELEASE_STATE:?}"
fi
STUB
chmod +x "$tmp/release-claim.sh"

run_case() {
    : >"$tmp/release.log"
    : >"$tmp/summary"
    # PR_BODY_OVERRIDE exercises the workflow's event-snapshot path; every
    # other case covers the manual/backfill fetch fallback.
    if [ "${PR_BODY_OVERRIDE+set}" = set ]; then
        export PR_BODY="$PR_BODY_OVERRIDE"
    else
        unset PR_BODY
    fi
    set +e
    PATH="$tmp/bin:$PATH" RELEASE_CLAIM_SCRIPT="$tmp/release-claim.sh" \
        RELEASE_LOG="$tmp/release.log" RELEASE_STATE="$tmp/release.state" \
        GH_REPO="${GH_REPO_OVERRIDE:-owner/repo}" PR_NUMBER=1067 \
        MERGED_AT=2026-08-27T12:00:00Z \
        HEAD_REF=fix/partial GITHUB_STEP_SUMMARY="$tmp/summary" \
        "$script" >"$tmp/out" 2>&1
    run_rc=$?
    set -e
    unset PR_BODY
}

calls_are() {
    actual="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "--issue") print $(i + 1) }' "$tmp/release.log" |
        sort -n | tr '\n' ' ')"
    [ "$actual" = "$1" ] || fail "expected release calls '$1', got '$actual'"
}

echo "==> closing-keyword references release the merged PR's claim"
GH_CLOSING='' GH_BODY='Closes #42' run_case
[ "$run_rc" -eq 0 ] || fail "closing-keyword path exited $run_rc"
calls_are '42 '
grep -Fq -- '--not-after 2026-08-27T12:00:00Z --branch fix/partial' "$tmp/release.log" ||
    fail "release engine did not receive the event time and claiming branch"
grep -Fq 'Claim release: released' "$tmp/summary" || fail "missing released audit"

echo "==> partial Refs PR preserves open HUMAN work while releasing its claim"
GH_CLOSING='' GH_BODY='Refs #1048' GH_HUMAN_ISSUE=1048 \
    GH_HUMAN_BODY=$'## Acceptance criteria\n- [x] [CI] implementation\n- [ ] [HUMAN] approve ADR\n1. [ ] [HUMAN] ordered form\n> - [ ] [HUMAN] blockquoted form' run_case
[ "$run_rc" -eq 0 ] || fail "partial-reference path exited $run_rc"
calls_are '1048 '
grep -Fq 'Issue state: open' "$tmp/summary" || fail "partial issue was not reported open"
grep -Fq 'Remaining unticked criteria: 3' "$tmp/summary" || fail "remaining criteria across task forms were not counted"

echo "==> newer claim records are left untouched across repeated PR cleanup"
GH_CLOSING='' GH_BODY='Refs #50' RELEASE_NO_CLAIM_ISSUE=50 run_case
[ "$run_rc" -eq 0 ] || fail "newer-claim first run exited $run_rc"
GH_CLOSING='' GH_BODY='Refs #50' RELEASE_NO_CLAIM_ISSUE=50 run_case
[ "$run_rc" -eq 0 ] || fail "newer-claim repeat exited $run_rc"
calls_are '50 '
grep -Fq 'no attributable live claim' "$tmp/summary" || fail "missing benign no-claim audit"

echo "==> one merged PR can release several distinct issue claims"
GH_CLOSING='' GH_BODY='Refs #8, Refs #7, and cross/repo#9' run_case
[ "$run_rc" -eq 0 ] || fail "multi-issue path exited $run_rc"
calls_are '7 8 '

echo "==> a repository-qualified same-repo reference is recognized"
GH_CLOSING='' GH_BODY='Refs owner/repo#33, not other/repo#34, nor prefix-owner/repo#35, nor https://github.com/owner/repo#36' run_case
[ "$run_rc" -eq 0 ] || fail "qualified-reference path exited $run_rc"
calls_are '33 '

echo "==> incidental mentions are not delivery references"
GH_CLOSING='' GH_BODY='Refs #10; remaining work tracked in #11, fixes #12, and prefix #13' run_case
[ "$run_rc" -eq 0 ] || fail "incidental-mention path exited $run_rc"
calls_are '10 12 '

echo "==> qualified matching is case-insensitive, as GitHub slugs are"
GH_CLOSING='' GH_BODY='Refs Owner/Repo#37' run_case
[ "$run_rc" -eq 0 ] || fail "case-variant path exited $run_rc"
calls_are '37 '

echo "==> a repository name ending in punctuation still matches qualified refs"
GH_REPO_OVERRIDE='owner/repo-' GH_CLOSING='' GH_BODY='Refs owner/repo-#44' run_case
[ "$run_rc" -eq 0 ] || fail "punctuation-suffix path exited $run_rc"
calls_are '44 '

echo "==> excess candidates are truncated loudly, never silently"
big_body="$(awk 'BEGIN { for (n = 1; n <= 60; n++) printf "Refs #%d\n", n }')"
GH_CLOSING='' GH_BODY="$big_body" run_case
[ "$run_rc" -eq 5 ] || fail "cap path exited $run_rc, expected 5"
released="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "--issue") print $(i + 1) }' "$tmp/release.log" | wc -l | tr -d ' ')"
[ "$released" = "50" ] || fail "expected 50 capped release calls, got $released"
grep -Fq 'candidate cap exceeded' "$tmp/summary" || fail "missing truncation audit"

echo "==> a zero candidate cap performs no release mutation"
CLAIM_RELEASE_MAX_CANDIDATES=0 GH_CLOSING='' GH_BODY='Refs #45' run_case
[ "$run_rc" -eq 5 ] || fail "zero-cap path exited $run_rc, expected 5"
calls_are ''
grep -Fq 'Processed the first 0 of 1 references' "$tmp/summary" || fail "missing zero-cap audit"

echo "==> the event body snapshot outranks the live PR body"
GH_CLOSING='' GH_BODY='Refs #98' PR_BODY_OVERRIDE='Refs #97' run_case
[ "$run_rc" -eq 0 ] || fail "snapshot path exited $run_rc"
calls_are '97 '

echo "==> no attributable record is benign and does not infer ownership"
GH_CLOSING='' GH_BODY='Refs #61' RELEASE_NO_CLAIM_ISSUE=61 run_case
[ "$run_rc" -eq 0 ] || fail "no-claim path exited $run_rc"
calls_are '61 '
grep -Fq 'no attributable live claim' "$tmp/summary" || fail "no-claim outcome was not auditable"

echo "==> one release failure does not starve other referenced issues"
GH_CLOSING='' GH_BODY='Refs #70 and Refs #71' RELEASE_FAIL_ISSUE=70 RELEASE_FAIL_RC=7 run_case
[ "$run_rc" -eq 7 ] || fail "failure path exited $run_rc, expected 7"
calls_are '70 71 '
grep -Fq 'failed (exit 7)' "$tmp/summary" || fail "missing failed audit"

echo "==> rerunning after release is idempotent"
rm -f "$tmp/release.state"
GH_CLOSING='' GH_BODY='Refs #90' RELEASE_IDEMPOTENT_ISSUE=90 run_case
[ "$run_rc" -eq 0 ] || fail "idempotent first run exited $run_rc"
GH_CLOSING='' GH_BODY='Refs #90' RELEASE_IDEMPOTENT_ISSUE=90 run_case
[ "$run_rc" -eq 0 ] || fail "idempotent rerun exited $run_rc"
calls_are '90 '
grep -Fq 'no attributable live claim' "$tmp/summary" || fail "idempotent rerun was not reported"

echo "claim-release-merged: all cases passed"
