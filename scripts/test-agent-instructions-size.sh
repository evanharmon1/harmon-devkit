#!/usr/bin/env bash
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
check="$repo/scripts/check-agent-instructions-size.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

exact="$tmpdir/exact.md"
over="$tmpdir/over.md"
dd if=/dev/zero of="$exact" bs=32768 count=1 2>/dev/null
dd if=/dev/zero of="$over" bs=32769 count=1 2>/dev/null

echo "==> exactly 32 KiB does not warn"
out="$(bash "$check" "$exact" 2>&1)" || fail "exact limit exited non-zero"
[ -z "$out" ] || fail "exact limit unexpectedly warned: $out"

echo "==> one byte over warns but remains advisory"
out="$(bash "$check" "$over" 2>&1)" || fail "oversize warning exited non-zero"
printf '%s' "$out" | grep -q 'Codex reads 32 KiB by default' ||
    fail "oversize file did not emit the expected warning"

echo "==> GitHub Actions receives an annotation without a failure"
out="$(GITHUB_ACTIONS=true bash "$check" "$over" 2>&1)" ||
    fail "GitHub warning path exited non-zero"
printf '%s' "$out" | grep -q '^::warning file=' ||
    fail "GitHub warning annotation was not emitted"

echo "==> invalid configuration fails loudly"
if AGENT_INSTRUCTIONS_WARN_BYTES=not-a-number bash "$check" "$exact" >/dev/null 2>&1; then
    fail "invalid byte limit was accepted"
fi

echo "==> AGENTS.md size advisory OK"
