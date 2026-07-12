#!/usr/bin/env bash
# test-tasks.sh — guard the Taskfile against regressions that only surface at
# run time: a Taskfile that no longer compiles, and setup tasks that fail when
# they should be safe no-ops. Run via `task test:tasks`.
#
# Coverage note: the bootstrap assertion only exercises the "Homebrew already
# installed" path, so it is skipped on runners without brew (e.g. the default
# ubuntu-latest CI). It still guards the common local/macOS case — the exact
# regression where `task bootstrap` aborted on a sudo precheck despite brew
# already being installed.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

echo "==> Taskfile compiles (every task parses)"
if ! task --list-all >/dev/null 2>&1; then
    fail "task --list-all failed — the Taskfile does not compile"
fi

echo "==> bootstrap is a no-op when Homebrew is already installed"
if command -v brew >/dev/null 2>&1; then
    if ! task bootstrap >/dev/null 2>&1; then
        fail "task bootstrap failed even though brew is already installed"
    fi
else
    echo "    (skipped: brew not on PATH)"
fi

echo "==> secret helper tasks reject missing destination metadata"
if printf '%s' 'dummy-secret' | task secret:set:1p >/dev/null 2>&1; then
    fail "task secret:set:1p succeeded without destination metadata"
fi
if printf '%s' 'dummy-secret' | task secret:set:gh >/dev/null 2>&1; then
    fail "task secret:set:gh succeeded without destination metadata"
fi

echo "==> task targets OK (compile + bootstrap idempotency)"
