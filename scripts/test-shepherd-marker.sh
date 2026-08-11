#!/usr/bin/env bash
# Hermetic tests for the shepherd gate-then-push marker parser
# (require-marker.sh). A push must chain off the GATE's verdict, and readers
# cannot stand in for it: `tail -1 file && git push` exits 0 by PRINTING a
# FAILED marker. These tests pin the parser that replaces that pattern —
# exit 0 only when the file's marker line equals the expected token.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/ai/skills/universal/shepherd/assets/require-marker.sh"
test_tmp="$(mktemp -d -t shepherd-marker-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

marker_rc=0
marker_out=
marker_err=

run_marker() {
    set +e
    marker_out="$("$helper" "$@" 2>"${test_tmp}/stderr")"
    marker_rc=$?
    set -e
    marker_err="$(cat "${test_tmp}/stderr")"
}

assert_rc() {
    [ "$marker_rc" -eq "$1" ] ||
        fail "expected rc $1, got $marker_rc: stdout='$marker_out' stderr='$marker_err'"
}

assert_reason() {
    [ -n "$marker_err" ] ||
        fail "a refusal must carry a reason on stderr (rc=$marker_rc)"
}

echo "==> the marker line equal to the token exits 0"
printf 'gate output\nmore output\nCI-GREEN\n' >"${test_tmp}/green"
run_marker "${test_tmp}/green" CI-GREEN
assert_rc 0
[ -z "$marker_out" ] || fail "success should be quiet on stdout: $marker_out"

echo "==> a FAILED marker refuses the token — the tail-1 regression"
# This is the observed slip the helper exists to prevent: the gate wrote
# CI5-FAILED, `tail -1 file` printed it with exit 0, and `&&` pushed an
# unverified commit. The parser must say no where the reader said yes.
printf 'gate output\nCI5-FAILED\n' >"${test_tmp}/failed"
run_marker "${test_tmp}/failed" CI5-GREEN
assert_rc 1
assert_reason
tail -1 "${test_tmp}/failed" >/dev/null ||
    fail "tail itself should exit 0 here — that contrast is the point"

echo "==> a missing file refuses with a reason"
run_marker "${test_tmp}/does-not-exist" CI-GREEN
assert_rc 1
assert_reason

echo "==> an empty file has no marker line"
: >"${test_tmp}/empty"
run_marker "${test_tmp}/empty" CI-GREEN
assert_rc 1
assert_reason

echo "==> a file of only blank lines has no marker line"
printf '\n   \n\t\n' >"${test_tmp}/blank"
run_marker "${test_tmp}/blank" CI-GREEN
assert_rc 1
assert_reason

echo "==> a directory is refused, not parsed"
mkdir "${test_tmp}/dir"
run_marker "${test_tmp}/dir" CI-GREEN
assert_rc 1
assert_reason

echo "==> surrounding whitespace and CRLF on the marker line are stripped"
printf 'output\n  CI-GREEN \r\n' >"${test_tmp}/crlf"
run_marker "${test_tmp}/crlf" CI-GREEN
assert_rc 0

echo "==> trailing blank lines do not hide the marker"
printf 'output\nCI-GREEN\n\n   \n' >"${test_tmp}/trailing"
run_marker "${test_tmp}/trailing" CI-GREEN
assert_rc 0

echo "==> a marker line without a final newline still counts"
printf 'output\nCI-GREEN' >"${test_tmp}/nonewline"
run_marker "${test_tmp}/nonewline" CI-GREEN
assert_rc 0

echo "==> only the LAST non-blank line is the marker"
# A gate that echoed the token mid-log and then kept running (or failed)
# must not read as green: the marker is the file's final verdict, not any
# line that ever matched.
printf 'CI-GREEN\nstill running\n' >"${test_tmp}/stale"
run_marker "${test_tmp}/stale" CI-GREEN
assert_rc 1
assert_reason

echo "==> the comparison is exact equality, not a prefix or substring"
printf 'output\nCI-GREEN-NOT-REALLY\n' >"${test_tmp}/prefix"
run_marker "${test_tmp}/prefix" CI-GREEN
assert_rc 1
assert_reason
printf 'output\nsaw CI-GREEN earlier\n' >"${test_tmp}/substring"
run_marker "${test_tmp}/substring" CI-GREEN
assert_rc 1
assert_reason

echo "==> usage errors exit 2: arity, blank token, whitespace-wrapped token"
run_marker "${test_tmp}/green"
assert_rc 2
run_marker "${test_tmp}/green" CI-GREEN extra
assert_rc 2
run_marker "${test_tmp}/green" ''
assert_rc 2
run_marker "${test_tmp}/green" ' CI-GREEN'
assert_rc 2
run_marker "${test_tmp}/green" 'CI-GREEN '
assert_rc 2
run_marker "${test_tmp}/green" "$(printf 'CI\nGREEN')"
assert_rc 2

echo "==> the helper is POSIX sh (runs under sh, not only bash)"
printf 'output\nCI-GREEN\n' >"${test_tmp}/posix"
sh "$helper" "${test_tmp}/posix" CI-GREEN ||
    fail "require-marker.sh must run under plain sh"

echo "==> the push-gating chain form works end to end"
# The documented composition: an external write runs only when the parser
# said yes. Model the write as touching a file.
printf 'output\nCI-GREEN\n' >"${test_tmp}/chain-green"
rm -f "${test_tmp}/pushed"
if "$helper" "${test_tmp}/chain-green" CI-GREEN; then
    : >"${test_tmp}/pushed"
fi
[ -f "${test_tmp}/pushed" ] || fail "a green marker should allow the write"
printf 'output\nCI-FAILED\n' >"${test_tmp}/chain-red"
rm -f "${test_tmp}/pushed"
if "$helper" "${test_tmp}/chain-red" CI-GREEN 2>/dev/null; then
    : >"${test_tmp}/pushed"
fi
[ ! -f "${test_tmp}/pushed" ] || fail "a FAILED marker must block the write"

echo "shepherd gate-then-push marker parser: PASS"
