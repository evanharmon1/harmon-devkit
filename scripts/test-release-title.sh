#!/usr/bin/env bash
# test-release-title.sh — unit-test require-release-title.sh: a content change
# under a non-releasing title fails; releasing titles and non-content chores
# pass; path-prefix matching respects the `/` boundary. Run via
# `task test:release-title`.
set -euo pipefail
cd "$(dirname "$0")/.."
guard="./scripts/require-release-title.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# run TITLE CHANGED_FILES PREFIX... -> echoes the guard's exit code.
run() {
    _t="$1"
    _c="$2"
    shift 2
    _rc=0
    PR_TITLE="$_t" PR_BODY="" CHANGED_FILES="$_c" "$guard" "$@" >/dev/null 2>&1 || _rc=$?
    echo "$_rc"
}

echo "==> content change under a chore title fails"
[ "$(run 'chore: update to harmon-init v4.0.0' "$(printf 'ai/skills/repo/x.md\nREADME.md')" ai/skills templates scripts)" = 1 ] ||
    fail "chore + skill change should fail"

echo "==> ambient PR_BODY cannot make an unrelated case pass"
PR_BODY='BREAKING CHANGE: inherited from the caller'
[ "$(run 'chore: update to harmon-init v4.0.0' 'ai/skills/repo/x.md' ai/skills)" = 1 ] ||
    fail "run helper leaked the caller's PR_BODY into an isolated test case"
unset PR_BODY

echo "==> the same content change under a fix title passes"
[ "$(run 'fix(standardize-repo): publish skill updates' 'ai/skills/repo/x.md' ai/skills templates scripts)" = 0 ] ||
    fail "fix + skill change should pass"

echo "==> a feat title passes"
[ "$(run 'feat: add a skill' 'ai/skills/new.md' ai/skills)" = 0 ] || fail "feat should pass"

echo "==> a breaking-change (!) chore-shaped title passes"
[ "$(run 'refactor!: drop a skill' 'ai/skills/old.md' ai/skills)" = 0 ] || fail "! breaking should pass"

echo "==> a stray '!:' later in a chore title does NOT bypass the guard"
[ "$(run 'chore: update docs !: not breaking' 'ai/skills/x.md' ai/skills)" = 1 ] ||
    fail "a bare !: elsewhere in the title must not count as breaking"

echo "==> BREAKING CHANGE in the body passes even with a chore title"
_rc=0
PR_TITLE='chore: x' PR_BODY='BREAKING CHANGE: removed foo' CHANGED_FILES='ai/skills/x.md' \
    "$guard" ai/skills >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "BREAKING CHANGE body should pass"

echo "==> a chore touching only non-content paths passes"
[ "$(run 'chore: tidy docs' "$(printf 'docs/x.md\nREADME.md')" ai/skills templates scripts)" = 0 ] ||
    fail "chore without content change should pass"

echo "==> docs is non-releasing: docs title touching a guarded path fails"
[ "$(run 'docs(standardize-repo): tweak' 'ai/skills/repo/x.md' ai/skills)" = 1 ] ||
    fail "docs + guarded content should fail"

echo "==> a nested file under a prefix matches"
[ "$(run 'chore: x' 'templates/scriptTemplates/shellScriptTemplate.sh' templates)" = 1 ] ||
    fail "nested file under templates should match"

echo "==> prefix boundary: a sibling dir sharing a name prefix does NOT match"
[ "$(run 'chore: x' 'ai/skills-extra/x.md' ai/skills)" = 0 ] ||
    fail "ai/skills-extra must not match the ai/skills prefix"

echo "==> a configured prefix written with a trailing slash still matches"
[ "$(run 'chore: x' 'templates/x.sh' templates/)" = 1 ] ||
    fail "a trailing-slash prefix (templates/) must still match templates/x.sh"

echo "==> an unconventional title with a content change fails"
[ "$(run 'update the skills' 'ai/skills/x.md' ai/skills)" = 1 ] ||
    fail "unconventional title + content change should fail"

echo "==> no prefixes configured is inert (exit 0)"
[ "$(run 'chore: x' 'ai/skills/x.md')" = 0 ] || fail "no prefixes should be inert"

echo "==> an empty title is a usage error (exit 2)"
_rc=0
PR_TITLE='' CHANGED_FILES='ai/skills/x.md' "$guard" ai/skills >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "empty title should be a usage error"

echo "release-title guard: all cases passed"
