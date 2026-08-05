#!/usr/bin/env bash
# test-meta-install.sh — unit-test meta-install.sh's home-path expansion and its
# refusal to act on an unsafe state.
#
# The expansion is the point: the destination reaches the script as a
# single-quoted Taskfile argument, so the shell has already declined to expand a
# leading `~` and the script must do it itself (issue #552). Every case runs in
# a throwaway HOME so a passing test proves expansion against a directory that
# is not the real one.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
script="$repo/scripts/meta-install.sh"

failures=0
pass() { echo "  ok — $1"; }
fail() {
    echo "  FAIL — $1" >&2
    failures=$((failures + 1))
}

# Each case gets its own sandbox: a git repo to satisfy the script's
# `rev-parse`, and a fake HOME to expand `~` into. The fake home is `fakehome/`
# rather than `home/` on purpose — test-template.sh scans rendered output for
# `/home/<name>/` literals, and a plain `home/` here reads as one of those.
sandbox=""
setup() {
    # `pwd -P` because macOS mktemp hands back /var/... while git and readlink
    # report the resolved /private/var/..., which would break path comparisons.
    sandbox="$(cd "$(mktemp -d)" && pwd -P)"
    mkdir -p "$sandbox/fakehome" "$sandbox/repo/.meta"
    git -C "$sandbox/repo" init -q
}
teardown() {
    if [ -n "$sandbox" ]; then
        rm -rf "$sandbox"
    fi
    sandbox=""
}
trap teardown EXIT

run() { (cd "$sandbox/repo" && HOME="$sandbox/fakehome" "$script" "$@"); }

echo "==> tilde in the destination expands to the calling user's HOME"
setup
mkdir -p "$sandbox/fakehome/Vault/Professional"
printf 'note\n' >"$sandbox/repo/.meta/Demo.md"
if run obsidian Demo '~/Vault/Professional' >/dev/null; then
    if [ -f "$sandbox/fakehome/Vault/Professional/Demo.md" ]; then
        pass "file moved into \$HOME/Vault/Professional"
    else
        fail "file did not land in the expanded destination"
    fi
    if [ -L "$sandbox/repo/.meta/Demo.md" ] &&
        [ "$(readlink "$sandbox/repo/.meta/Demo.md")" = "$sandbox/fakehome/Vault/Professional/Demo.md" ]; then
        pass "symlink points at the expanded absolute path"
    else
        fail "symlink missing or points at an unexpanded path"
    fi
    if [ -d "$sandbox/repo/~" ]; then
        fail "created a literal '~' directory — expansion did not happen"
    else
        pass "no literal '~' directory created"
    fi
else
    fail "script exited non-zero on a valid install"
fi
teardown

echo "==> a bunch file uses the 'Code Project - <name>.bunch' filename"
setup
mkdir -p "$sandbox/fakehome/Bunches"
printf 'bunch\n' >"$sandbox/repo/.meta/Code Project - Demo.bunch"
if run bunch Demo '~/Bunches' >/dev/null &&
    [ -f "$sandbox/fakehome/Bunches/Code Project - Demo.bunch" ]; then
    pass "bunch file moved to \$HOME/Bunches"
else
    fail "bunch file was not installed"
fi
teardown

echo "==> re-running an installed sidecar is a no-op, not an error"
setup
mkdir -p "$sandbox/fakehome/Vault"
printf 'note\n' >"$sandbox/repo/.meta/Demo.md"
run obsidian Demo '~/Vault' >/dev/null
if run obsidian Demo '~/Vault' >/dev/null 2>&1; then
    pass "second run succeeds"
else
    fail "second run failed — install is not idempotent"
fi
teardown

echo "==> an absolute destination is passed through unchanged"
setup
mkdir -p "$sandbox/fakehome/Abs"
printf 'note\n' >"$sandbox/repo/.meta/Demo.md"
if run obsidian Demo "$sandbox/fakehome/Abs" >/dev/null &&
    [ -f "$sandbox/fakehome/Abs/Demo.md" ]; then
    pass "absolute path still works"
else
    fail "absolute destination was mangled"
fi
teardown

echo "==> a relative destination is made absolute before the link is written"
setup
mkdir -p "$sandbox/repo/vault"
printf 'note\n' >"$sandbox/repo/.meta/Demo.md"
if run obsidian Demo 'vault' >/dev/null 2>&1; then
    if [ -e "$sandbox/repo/.meta/Demo.md" ]; then
        pass "backlink resolves (not dangling via .meta/vault/)"
    else
        fail "backlink dangles — the relative path was written into the symlink"
    fi
    if [ -f "$sandbox/repo/vault/Demo.md" ]; then
        pass "file landed in the repo-root-relative directory"
    else
        fail "file did not land where the relative path pointed"
    fi
else
    fail "rejected a relative destination that exists"
fi
teardown

echo "==> refuses rather than guessing"
setup
mkdir -p "$sandbox/fakehome/Vault"
if run obsidian Missing '~/Vault' >/dev/null 2>&1; then
    fail "accepted a missing .meta/ source file"
else
    pass "missing source file rejected"
fi
printf 'note\n' >"$sandbox/repo/.meta/Demo.md"
if run obsidian Demo '~/DoesNotExist' >/dev/null 2>&1; then
    fail "accepted a destination directory that does not exist"
else
    pass "missing destination directory rejected"
fi
mkdir -p "$sandbox/fakehome/Vault2"
printf 'other\n' >"$sandbox/fakehome/Vault2/Demo.md"
if run obsidian Demo '~/Vault2' >/dev/null 2>&1; then
    fail "overwrote an existing file at the destination"
else
    pass "existing destination file rejected"
fi
# A DANGLING symlink at the destination is something that exists; `-e` follows
# the link and reports false, so `mv` would silently replace it.
mkdir -p "$sandbox/fakehome/Vault3"
ln -s "$sandbox/fakehome/nowhere.md" "$sandbox/fakehome/Vault3/Demo.md"
if run obsidian Demo '~/Vault3' >/dev/null 2>&1; then
    fail "clobbered a dangling symlink at the destination"
else
    pass "dangling destination symlink rejected"
fi
if [ -L "$sandbox/fakehome/Vault3/Demo.md" ] && [ -e "$sandbox/repo/.meta/Demo.md" ]; then
    pass "both the dangling link and the source survived the refusal"
else
    fail "the refusal did not leave the dangling link and the source intact"
fi
if run nonsense Demo '~/Vault' >/dev/null 2>&1; then
    fail "accepted an unknown kind"
else
    pass "unknown kind rejected"
fi
teardown

echo "==> a failed backlink puts the file back in .meta/"
setup
# The move has to succeed and only the `ln -s` fail, which no filesystem
# permission arrangement produces (`mv` out of .meta/ needs the same write
# permission `ln -s` into it does). Stubbing `ln` on PATH isolates that one
# step — the point is the rollback branch, not how ln came to fail.
mkdir -p "$sandbox/fakehome/Vault" "$sandbox/bin"
printf '#!/bin/sh\nexit 1\n' >"$sandbox/bin/ln"
chmod +x "$sandbox/bin/ln"
printf 'note\n' >"$sandbox/repo/.meta/Demo.md"
if (cd "$sandbox/repo" && HOME="$sandbox/fakehome" PATH="$sandbox/bin:$PATH" \
    "$script" obsidian Demo '~/Vault') >/dev/null 2>&1; then
    fail "reported success despite the symlink failing"
else
    pass "failed backlink is reported as a failure"
fi
if [ -f "$sandbox/repo/.meta/Demo.md" ] && [ ! -e "$sandbox/fakehome/Vault/Demo.md" ]; then
    pass "file rolled back into .meta/ and the destination is clean"
else
    fail "file was stranded — not in .meta/, or left at the destination"
fi
teardown

if [ "$failures" -gt 0 ]; then
    echo "test-meta-install: FAILED ($failures)" >&2
    exit 1
fi
echo "test-meta-install: PASS"
