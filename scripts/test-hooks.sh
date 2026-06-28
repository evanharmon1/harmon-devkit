#!/usr/bin/env bash
# test-hooks.sh — round-trip the Taskfile targets the Claude Code hooks delegate
# to (lint:commit-msg:text, format:file). Guards against the go-task CLI_ARGS
# quoting/injection class of bug, where a valid commit message is silently
# rejected (blocking every commit) or a path with a space is silently skipped.
# Run via `task test:hooks`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

echo "==> lint:commit-msg:text accepts a valid conventional message"
if ! printf '%s' 'feat: a valid message' | task lint:commit-msg:text >/dev/null 2>&1; then
    fail "lint:commit-msg:text rejected a VALID conventional message"
fi

echo "==> lint:commit-msg:text rejects a non-conventional message"
if printf '%s' 'not a conventional message' | task lint:commit-msg:text >/dev/null 2>&1; then
    fail "lint:commit-msg:text accepted an INVALID message"
fi

echo "==> format:file formats a file, including a path containing a space"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
spaced="$tmpdir/with space.sh"
printf 'f(){\necho hi\n}\n' >"$spaced"
before="$(cat "$spaced")"
if ! task format:file -- "$spaced" >/dev/null 2>&1; then
    fail "format:file errored on a path containing a space"
fi
if [ "$before" = "$(cat "$spaced")" ]; then
    fail "format:file did not reformat a mis-formatted file"
fi

echo "==> hook-delegation targets OK (commit-msg accept/reject, format:file)"
