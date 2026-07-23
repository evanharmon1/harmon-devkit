#!/usr/bin/env bash
# Hermetic truth-table regressions for the fail-closed CI result helper.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
verifier="${repo}/scripts/verify-ci-results.sh"

fail() {
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

echo "CI result helper truth tables: PASS"
