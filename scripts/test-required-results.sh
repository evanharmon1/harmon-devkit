#!/usr/bin/env bash
# Hermetic truth-table regression for verify-required-results.sh.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
verify="${repo}/scripts/verify-required-results.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

accept() {
    label="$1"
    expected="$2"
    shift 2
    if ! EXPECTED_RESULT="$expected" "$verify" "$@" >/dev/null 2>&1; then
        fail "rejected ${label}"
    fi
}

reject() {
    label="$1"
    expected="$2"
    shift 2
    if EXPECTED_RESULT="$expected" "$verify" "$@" >/dev/null 2>&1; then
        fail "accepted ${label}"
    fi
}

accept "trusted jobs succeeding" success lint=success security=success build-test=success
accept "fork-suppressed jobs skipping" skipped lint=skipped security=skipped build-test=skipped

reject "a skipped trusted job" success lint=success security=skipped
reject "a successful fork-suppressed job" skipped lint=skipped security=success
reject "a failed job" success lint=success security=failure
reject "a cancelled job" success lint=success security=cancelled
reject "an empty result" success lint=success security=
reject "an empty job name" success =success
reject "a malformed pair" success lint
reject "an unsupported expectation" neutral lint=neutral
reject "an empty result set" success

echo "Required-job aggregate truth table: PASS"
