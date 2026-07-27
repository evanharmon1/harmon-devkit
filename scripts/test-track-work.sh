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

echo "==> ordered task-list checkboxes are counted (GFM renders them too)"
printf '## Acceptance\n\n1. [x] done\n2. [ ] not done\n' >"$fixtures/evanharmon1_harmon-devkit__9.md"
[ "$(run_closing 'Closes #9')" = 1 ] || fail "ordered '1. [ ]' items should be counted"
printf '## Acceptance\n\n1) [ ] not done\n' >"$fixtures/evanharmon1_harmon-devkit__10.md"
[ "$(run_closing 'Closes #10')" = 1 ] || fail "ordered '1) [ ]' items should be counted"

echo "==> task-list spacing variants all count as unchecked"
# GFM renders every one of these as a checkbox; a formatter can introduce the
# wider gaps on its own, and each would otherwise slip past the guard.
i=11
for item in '-  [ ] two spaces' '*   [ ] three spaces' '1.  [ ] ordered, two spaces' '  - [ ] indented'; do
    printf '## Acceptance\n\n%s\n' "$item" >"$fixtures/evanharmon1_harmon-devkit__${i}.md"
    [ "$(run_closing "Closes #${i}")" = 1 ] || fail "'$item' should count as an unchecked item"
    i=$((i + 1))
done

echo "==> a checked box is not counted, whatever the spacing"
printf '## Acceptance\n\n-  [x] done\n1.  [X] also done\n' >"$fixtures/evanharmon1_harmon-devkit__20.md"
[ "$(run_closing 'Closes #20')" = 0 ] || fail "checked boxes should not block a close"

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

echo "==> a closing keyword in the PR TITLE fails, even with a clean body"
# Squash-merge makes the title the commit subject, which closes issues on main.
_rc=0
env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='fix: cleanup, closes #5' PR_BODY='Nothing to see.' \
    "$closing" --repo "$repo" --body-env PR_BODY --title-env PR_TITLE >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "a closing keyword in the title should fail (got $_rc)"

echo "==> a title violation is reported as the title, not as a body line"
out="$(env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='fix: cleanup, closes #5' PR_BODY='Nothing to see.' \
    "$closing" --repo "$repo" --body-env PR_BODY --title-env PR_TITLE 2>&1 || true)"
printf '%s\n' "$out" | grep -q 'PR title' || fail "the violation should be located in the PR title"

echo "==> body line numbers stay correct when a title is also scanned"
out="$(env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='fix: a clean title' PR_BODY='line one
line two
Closes #5' "$closing" --repo "$repo" --body-env PR_BODY --title-env PR_TITLE 2>&1 || true)"
printf '%s\n' "$out" | grep -q 'body line 3' || fail "body line numbers should exclude the title line"

echo "==> a clean title and a clean body pass together"
_rc=0
env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='feat: add a thing' PR_BODY='Refs #5' \
    "$closing" --repo "$repo" --body-env PR_BODY --title-env PR_TITLE >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "a clean title and body should pass (got $_rc)"

echo "==> an empty title and body pass together"
_rc=0
env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='' PR_BODY='' \
    "$closing" --repo "$repo" --body-env PR_BODY --title-env PR_TITLE >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "empty title and body should pass (got $_rc)"

echo "==> a closing keyword in a COMMIT MESSAGE fails, with a clean title and body"
# Commit messages reach main under rebase/merge, and under squash too when the
# repo's squash_merge_commit_message is COMMIT_MESSAGES (as this repo's is).
printf 'fix: tidy up\n\nCloses #5\n' >"$tmp/commits.txt"
_rc=0
env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='feat: clean title' PR_BODY='Clean body.' \
    "$closing" --repo "$repo" --title-env PR_TITLE --body-env PR_BODY \
    --commits-file "$tmp/commits.txt" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "a closing keyword in a commit message should fail (got $_rc)"

echo "==> a commit violation is located as a commit message, not a body line"
out="$(env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='feat: clean' PR_BODY='Clean.' \
    "$closing" --repo "$repo" --title-env PR_TITLE --body-env PR_BODY \
    --commits-file "$tmp/commits.txt" 2>&1 || true)"
printf '%s\n' "$out" | grep -q 'commit message line 3' || fail "commit hits should report their own line numbers"

echo "==> an empty --commits-file value means no commits were supplied"
_rc=0
env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='feat: clean' PR_BODY='Refs #5' \
    "$closing" --repo "$repo" --title-env PR_TITLE --body-env PR_BODY \
    --commits-file "" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "an empty --commits-file should be a no-op (got $_rc)"

echo "==> a missing --commits-file path is a usage error, not a silent skip"
_rc=0
env ISSUE_BODY_DIR="$fixtures" GH_REPO="" \
    "$closing" --repo "$repo" --commits-file "$tmp/nope.txt" </dev/null >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "a nonexistent commits file should exit 2 (got $_rc)"

echo "==> clean commits alongside a clean title and body pass"
printf 'feat: add a thing\n\nRefs #5\n' >"$tmp/clean-commits.txt"
_rc=0
env ISSUE_BODY_DIR="$fixtures" GH_REPO="" PR_TITLE='feat: add a thing' PR_BODY='Refs #5' \
    "$closing" --repo "$repo" --title-env PR_TITLE --body-env PR_BODY \
    --commits-file "$tmp/clean-commits.txt" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "clean commits should pass (got $_rc)"

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

echo "==> an extensionless file citation counts as perishable"
for cite in 'Dockerfile:12 installs curl.' 'Makefile:8 is wrong.' 'See CODEOWNERS:3 for the owner.'; do
    [ "$(run_rot "$cite")" = 1 ] || fail "'$cite' should be flagged as perishable"
done

echo "==> a bare word before a number is not mistaken for a file citation"
for benign in 'The build runs at 10:30 every day.' 'Serve it on localhost:3000 to check.' 'See section 4:2 of the RFC.'; do
    [ "$(run_rot "$benign")" = 0 ] || fail "'$benign' should not be flagged"
done

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

echo "==> an EMPTY Verify heading does not clear the draft"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

')" = 1 ] || fail "a Verify heading with nothing under it should still fail"

echo "==> an unfilled <placeholder> under Verify does not count as a command"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

```sh
<command that re-checks it, and what its output means>
```
')" = 1 ] || fail "the unfilled skeleton should still fail"

echo "==> Issue Forms' '_No response_' under Verify does not count as a command"
# An optional Issue Forms field left blank renders exactly this, under an h3
# label — the shape every issue filed from .github/ISSUE_TEMPLATE arrives in.
[ "$(run_rot '### Summary

scripts/foo.sh:42 is stale.

### Verify

_No response_
')" = 1 ] || fail "an unfilled Issue Forms Verify field should still fail"

echo "==> other stand-ins for nothing do not count either"
for filler in 'N/A' 'TBD' 'TODO' 'None'; do
    [ "$(run_rot "scripts/foo.sh:42 is stale.

## Verify

${filler}
")" = 1 ] || fail "'${filler}' under Verify should not count as a command"
done

echo "==> a Verify section followed immediately by another heading fails"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

## Notes

Some prose.
')" = 1 ] || fail "an empty Verify before another heading should fail"

echo "==> prose under Verify counts — it need not be a code fence"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

Run `task test:hygiene`; a TEST FAIL means it is still live.
')" = 0 ] || fail "prose under Verify should count"

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
