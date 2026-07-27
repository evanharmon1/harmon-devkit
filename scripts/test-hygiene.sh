#!/usr/bin/env bash
# test-hygiene.sh — unit-test lint-hygiene.sh's executable-bit check: a tracked
# shebanged file must be non-executable in git's index to fail; files without a
# shebang, untracked files, symlinks, binaries, and ignore-listed paths are
# exempt. Run via `task test:hygiene`.
set -euo pipefail
cd "$(dirname "$0")/.."
hygiene="$PWD/scripts/lint-hygiene.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Each case runs in a throwaway git repo so index modes are real, never the
# checkout this test happens to run from.
sandbox=""
cleanup() {
    # An `&&` chain as the last command would return 1 on the first call (no
    # sandbox yet) and `set -e` would kill the run before any assertion.
    if [ -n "$sandbox" ] && [ -d "$sandbox" ]; then
        rm -rf "$sandbox"
    fi
}
trap cleanup EXIT

new_repo() {
    cleanup
    sandbox="$(mktemp -d -t hygiene-test-XXXXXX)"
    git -C "$sandbox" init -q
    git -C "$sandbox" config user.email test@example.com
    git -C "$sandbox" config user.name test
}

# add PATH CONTENT MODE — write a file and stage it at an explicit index mode.
add() {
    printf '%s\n' "$2" >"$sandbox/$1"
    git -C "$sandbox" add -- "$1"
    git -C "$sandbox" update-index --chmod="$3" -- "$1"
}

# run -> echoes lint-hygiene's exit code for the sandbox as a whole.
run() {
    _rc=0
    (cd "$sandbox" && "$hygiene" >/dev/null 2>&1) || _rc=$?
    echo "$_rc"
}

echo "==> a tracked shebanged file without the exec bit fails"
new_repo
add script.sh '#!/usr/bin/env bash' -x
[ "$(run)" = 1 ] || fail "shebang at mode 100644 should fail"

echo "==> the failure names the file and the fix"
new_repo
add script.sh '#!/usr/bin/env bash' -x
out="$(cd "$sandbox" && "$hygiene" 2>&1 || true)"
case "$out" in
*"script.sh: shebang without the executable bit (fix: chmod +x 'script.sh')"*) ;;
*) fail "expected an actionable message, got: $out" ;;
esac

echo "==> the same file at mode 100755 passes"
new_repo
add script.sh '#!/usr/bin/env bash' +x
[ "$(run)" = 0 ] || fail "shebang at mode 100755 should pass"

echo "==> a non-shebanged file at mode 100644 passes"
new_repo
add notes.md 'no interpreter here' -x
[ "$(run)" = 0 ] || fail "a file without a shebang must not require the exec bit"

echo "==> a '#' comment that is not a shebang does not trigger the check"
new_repo
add config.yml '# just a comment' -x
[ "$(run)" = 0 ] || fail "'#' without '!' must not be read as a shebang"

echo "==> an untracked shebanged file is exempt (no published mode yet)"
new_repo
printf '%s\n' '#!/usr/bin/env bash' >"$sandbox/loose.sh"
chmod -x "$sandbox/loose.sh"
[ "$(run)" = 0 ] || fail "untracked files have no index mode to enforce"

echo "==> a shebanged file listed in .lint-hygiene-ignore is exempt"
new_repo
add vendored.sh '#!/usr/bin/env bash' -x
printf '%s\n' 'vendored.sh' >"$sandbox/.lint-hygiene-ignore"
git -C "$sandbox" add -- .lint-hygiene-ignore
[ "$(run)" = 0 ] || fail "the documented exemption file must cover this check too"

echo "==> a symlink to a shebanged file is skipped, not dereferenced"
new_repo
add real.sh '#!/usr/bin/env bash' +x
ln -s real.sh "$sandbox/alias.sh"
git -C "$sandbox" add -- alias.sh
[ "$(run)" = 0 ] || fail "symlinks must not be flagged"

echo "==> a binary whose bytes merely start '\\0#!' is not read as a shebang"
new_repo
perl -e 'print "\x00#!/bin/sh\n"' >"$sandbox/nul.bin"
git -C "$sandbox" add -- nul.bin
git -C "$sandbox" update-index --chmod=-x -- nul.bin
[ "$(run)" = 0 ] || fail "the binary skip should keep this out of the check"

echo "hygiene tests: all passed"
