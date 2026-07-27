#!/usr/bin/env bash
# test-track-work.sh — unit-test the track-work skill's two checks. Fully
# offline: issue bodies come from fixtures via $ISSUE_BODY_DIR, and the few
# cases that must exercise the live `gh` path use a PATH-stubbed `gh`.
#
# The checks are shipped inside the skill (ai/skills/universal/track-work/assets)
# so consumers vendor them with the skill, but harmon-devkit's own CI runs them
# on every PR via `task guard:closing-keywords` — these tests are what keep that
# guard honest. Run via `task test:track-work`.
set -euo pipefail
cd "$(dirname "$0")/.."

closing="./ai/skills/universal/track-work/assets/check-closing-keywords.sh"
rot="./ai/skills/universal/track-work/assets/check-issue-rot.sh"
repo="evanharmon1/harmon-devkit"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixtures="$tmp/issues"
mkdir -p "$fixtures"

# 5 — open acceptance criteria. 6 — everything ticked. 7 — alternate list
# markers, one still open. 8 — no task list at all.
printf '## Acceptance\n\n- [ ] first thing\n- [x] second thing\n' >"$fixtures/evanharmon1_harmon-devkit__5.md"
printf '## Acceptance\n\n- [x] first thing\n- [X] second thing\n' >"$fixtures/evanharmon1_harmon-devkit__6.md"
printf '* [x] done\n+ [ ] not done\n' >"$fixtures/evanharmon1_harmon-devkit__7.md"
printf 'Just prose, no checkboxes.\n' >"$fixtures/evanharmon1_harmon-devkit__8.md"

# run_closing BODY [REPO] -> echoes the exit code. Every case gets an explicit
# ISSUE_BODY_DIR and an empty GH_REPO so an ambient value cannot decide a test.
run_closing() {
    _rc=0
    printf '%s' "$1" |
        env ISSUE_BODY_DIR="$fixtures" GH_REPO="" "$closing" --repo "${2:-$repo}" >/dev/null 2>&1 || _rc=$?
    echo "$_rc"
}

# run_rot BODY -> echoes the exit code.
run_rot() {
    _rc=0
    printf '%s' "$1" | "$rot" >/dev/null 2>&1 || _rc=$?
    echo "$_rc"
}

echo "==> a body with no closing keyword passes"
[ "$(run_closing 'Refs #5 — tracked, not closed.')" = 0 ] || fail "Refs should not trip the guard"

echo "==> an empty body passes"
[ "$(run_closing '')" = 0 ] || fail "empty body should pass"

echo "==> closing an issue with open acceptance criteria fails"
[ "$(run_closing 'Closes #5')" = 1 ] || fail "unchecked boxes should fail"

echo "==> closing a fully ticked issue passes"
[ "$(run_closing 'Closes #6')" = 0 ] || fail "fully ticked issue should pass"

echo "==> closing an issue with no task list at all passes"
[ "$(run_closing 'Closes #8')" = 0 ] || fail "issue without checkboxes should pass"

echo "==> '*' and '+' task-list markers are counted too"
[ "$(run_closing 'Closes #7')" = 1 ] || fail "alternate list markers should be counted"

echo "==> every closing keyword and inflection is recognised"
for kw in close closes closed fix fixes fixed resolve resolves resolved; do
    [ "$(run_closing "${kw} #5")" = 1 ] || fail "'${kw}' should be treated as a closing keyword"
    upper="$(printf '%s' "$kw" | tr '[:lower:]' '[:upper:]')"
    [ "$(run_closing "${upper} #5")" = 1 ] || fail "'${upper}' should match case-insensitively"
done

echo "==> a word merely ending in a keyword is not a closing keyword"
[ "$(run_closing 'This prefixes #5 with context.')" = 0 ] || fail "'prefixes' must not match 'fixes'"
[ "$(run_closing 'The subcloses #5 marker.')" = 0 ] || fail "'subcloses' must not match 'closes'"

echo "==> 'Closes:' with a colon separator is recognised"
[ "$(run_closing 'Closes: #5')" = 1 ] || fail "colon separator should still close"

echo "==> the full issue URL form resolves to the same issue"
[ "$(run_closing "Fixes https://github.com/${repo}/issues/5")" = 1 ] || fail "URL form should resolve"

echo "==> a cross-repo closing keyword fails even when the issue is fully ticked"
printf '## Acceptance\n\n- [x] all done\n' >"$fixtures/evanharmon1_harmon-init__6.md"
[ "$(run_closing 'closes evanharmon1/harmon-init#6')" = 1 ] || fail "cross-repo close should fail"

echo "==> the same cross-repo issue passes when referenced without a keyword"
[ "$(run_closing 'Refs evanharmon1/harmon-init#6')" = 0 ] || fail "cross-repo Refs should pass"

echo "==> a closing keyword inside a code fence still fails (fail-closed by design)"
[ "$(run_closing 'Example:

```
Closes #5
```
')" = 1 ] || fail "code-fenced closing keyword should still fail"

echo "==> an unreadable issue fails as unverified (2), not as clean"
[ "$(run_closing 'Closes #404')" = 2 ] || fail "missing issue should exit 2"

echo "==> a bare #N resolves against GH_REPO when --repo is absent"
_rc=0
printf 'Closes #5' | env ISSUE_BODY_DIR="$fixtures" GH_REPO="$repo" "$closing" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "GH_REPO should supply the default repo (got $_rc)"

echo "==> --body-env reads the body without it touching a command line"
_rc=0
env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_BODY='Closes #5' \
    "$closing" --repo "$repo" --body-env PR_BODY >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "--body-env should read PR_BODY (got $_rc)"

echo "==> --body-env on an unset variable is an empty body, not an error"
_rc=0
env -u PR_BODY ISSUE_BODY_DIR="$fixtures" GH_REPO="" \
    "$closing" --repo "$repo" --body-env PR_BODY >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "an unset body variable should pass (got $_rc)"

echo "==> the same issue referenced twice is reported once"
out="$(printf 'Closes #5 and closes #5 again' |
    env ISSUE_BODY_DIR="$fixtures" GH_REPO="" "$closing" --repo "$repo" 2>&1 || true)"
[ "$(printf '%s\n' "$out" | grep -c 'still has')" = 1 ] || fail "duplicate references should be deduped"

# --- the live `gh` path, with a stubbed binary -------------------------------
stub="$tmp/bin"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/bin/sh
# `issue view` rejects a pull-request number; `pr view` accepts it.
case "$1 $2" in
"issue view") exit 1 ;;
"pr view") exit 0 ;;
"repo view") echo "evanharmon1/harmon-devkit" ;;
*) exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

echo "==> a closing keyword pointing at a pull request is skipped, not failed"
_rc=0
printf 'Closes #42' | env PATH="$stub:$PATH" GH_REPO="" "$closing" --repo "$repo" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "a PR number carries no backlog and should be skipped (got $_rc)"

echo "==> the default repo falls back to \`gh repo view\` when nothing else supplies it"
_rc=0
printf 'Closes #5' |
    env PATH="$stub:$PATH" GH_REPO="" ISSUE_BODY_DIR="$fixtures" "$closing" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "gh repo view should supply the default repo (got $_rc)"

# --- check-issue-rot.sh ------------------------------------------------------

echo "==> a draft with nothing perishable passes"
[ "$(run_rot 'The guard must reject a skipped verification.')" = 0 ] || fail "clean draft should pass"

echo "==> a file:line citation with no Verify section fails"
[ "$(run_rot 'The check in scripts/foo.sh:42 returns 0 on failure.')" = 1 ] || fail "file:line without Verify should fail"

echo "==> a temporal claim with no Verify section fails"
for phrase in 'Currently it exits 0.' 'Today it exits 0.' 'As of the last run it exits 0.' 'Right now it exits 0.'; do
    [ "$(run_rot "$phrase")" = 1 ] || fail "'$phrase' should be flagged as perishable"
done

echo "==> the same citation passes once a Verify section covers it"
[ "$(run_rot 'scripts/foo.sh:42 returns 0 on failure.

## Verify

```sh
task test:hygiene
```
')" = 0 ] || fail "Verify section should clear the draft"

echo "==> a Verify section at any heading level counts"
[ "$(run_rot 'scripts/foo.sh:42 is wrong.

### Verify

Run the test.
')" = 0 ] || fail "### Verify should count"

echo "==> a word merely containing a temporal phrase is not flagged"
[ "$(run_rot 'The representation is stable.')" = 0 ] || fail "'representation' must not match 'present'"

echo "==> usage errors exit 2"
_rc=0
"$rot" "$tmp/does-not-exist.md" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "a missing draft file should exit 2 (got $_rc)"
_rc=0
"$rot" a b >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "extra arguments should exit 2 (got $_rc)"
_rc=0
printf 'x' | "$closing" --repo >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "--repo without a value should exit 2 (got $_rc)"

echo "✓ track-work checks behave"
