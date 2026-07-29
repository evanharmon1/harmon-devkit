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
tick="$PWD/ai/skills/universal/track-work/assets/tick-criteria.sh"
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

echo "==> blockquoted task-list items are counted"
# A checklist carried over from another issue arrives as `> - [ ] …` and holds
# exactly the same unfinished work.
printf '## Carried over\n\n> - [ ] still unfinished\n' >"$fixtures/evanharmon1_harmon-devkit__21.md"
[ "$(run_closing 'Closes #21')" = 1 ] || fail "a blockquoted unchecked item should be counted"
printf '## Nested\n\n> > 1. [ ] still unfinished\n' >"$fixtures/evanharmon1_harmon-devkit__22.md"
[ "$(run_closing 'Closes #22')" = 1 ] || fail "a nested blockquoted item should be counted"

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

echo "==> a host or IP with a port is not a file citation"
# `.com:443` and `1.1:8080` are indistinguishable from `file.ext:line` by shape,
# so a citation now needs a real file cue.
for host in 'See https://example.com:443 for docs.' 'Reach it at 192.168.1.1:8080 now.' 'Check example.com:443 please.' 'The registry is ghcr.io:443 for pulls.'; do
    [ "$(run_rot "$host")" = 0 ] || fail "'$host' should not be flagged as a citation"
done

echo "==> real citations still register after the host-and-port fix"
for cite in 'scripts/foo.sh:42 is wrong.' 'The value in config.yml:8 is stale.' 'See template/x.yml.jinja:119 for it.' 'a/b/weird.xyz:3 is off.'; do
    [ "$(run_rot "$cite")" = 1 ] || fail "'$cite' should still be flagged"
done

echo "==> citations with unlisted extensions and dotfiles are caught"
# The host exclusion must not become an allowlist of known extensions — that
# silently drops every real citation the list forgot.
for cite in 'component.vue:12 is wrong.' 'Info.plist:8 is wrong.' 'See .gitignore:3 for it.' 'The .env:4 line is stale.' 'Chart.lock:7 drifted.'; do
    [ "$(run_rot "$cite")" = 1 ] || fail "'$cite' should be flagged"
done

echo "==> an unrecognised internet suffix is still not a citation"
[ "$(run_rot 'Use my.site:8080 to reach it.')" = 0 ] || fail "'my.site:8080' should not be flagged"

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

echo "==> a heading that merely starts with Verify is not a Verify section"
for heading in '## Verify later' '## Verify-notes' '## Verifying the fix'; do
    [ "$(run_rot "scripts/foo.sh:42 is stale.

${heading}

some prose that is not a command
")" = 1 ] || fail "'${heading}' should not satisfy the Verify requirement"
done

echo "==> 'Verification' and closing hashes are accepted spellings"
for heading in '## Verification' '## Verify ##' '##   Verify'; do
    [ "$(run_rot "scripts/foo.sh:42 is stale.

${heading}

task test:hygiene
")" = 0 ] || fail "'${heading}' should count as a Verify section"
done

echo "==> a Markdown-indented Verify heading counts"
# CommonMark allows up to three spaces before an ATX heading.
[ "$(run_rot 'scripts/foo.sh:42 is stale.

   ## Verify

   task test:hygiene
')" = 0 ] || fail "an indented Verify heading should be recognised"

echo "==> an indented following heading still ends the Verify section"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

  ## Notes

prose
')" = 1 ] || fail "an indented heading should terminate the Verify section"

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

# --- tick-criteria.sh -------------------------------------------------------
#
# The guarantee under test is narrowness: this is the one write the skill
# pre-approves, so every path that could turn a tick into an arbitrary body
# rewrite has to refuse instead. Fixtures double as the write destination when
# $ISSUE_BODY_DIR is set, so the round trip stays offline.

ticks="$fixtures/ticks"
mkdir -p "$ticks"

# write_issue NUM BODY — (re)create a tick fixture.
write_issue() {
    printf '%s' "$2" >"$ticks/${repo//\//_}__$1.md"
}

# issue_is NUM EXPECTED — is the fixture exactly EXPECTED? Both sides go through
# command substitution so a trailing newline cannot decide a test.
issue_is() {
    [ "$(cat "$ticks/${repo//\//_}__$1.md")" = "$(printf '%s' "$2")" ]
}

# run_tick NUM ARGS... -> echoes the exit code.
run_tick() {
    _rc=0
    _num="$1"
    shift
    env ISSUE_BODY_DIR="$ticks" GH_REPO="" \
        "$tick" --repo "$repo" --issue "$_num" "$@" >/dev/null 2>&1 || _rc=$?
    echo "$_rc"
}

body_three='## Acceptance

- [ ] first criterion
- [ ] second criterion
- [x] already done
'

echo "==> a matched criterion is ticked and nothing else moves"
write_issue 20 "$body_three"
[ "$(run_tick 20 --match 'second')" = 0 ] || fail "a unique --match should tick"
issue_is 20 '## Acceptance

- [ ] first criterion
- [x] second criterion
- [x] already done
' || fail "only the matched criterion should have changed"

echo "==> --index counts unticked items, not body lines"
write_issue 21 "$body_three"
[ "$(run_tick 21 --index 2)" = 0 ] || fail "--index 2 should tick the second unticked item"
issue_is 21 '## Acceptance

- [ ] first criterion
- [x] second criterion
- [x] already done
' || fail "--index should address unticked items in order"

echo "==> several selectors tick several criteria in one write"
write_issue 22 "$body_three"
[ "$(run_tick 22 --index 1 --match 'second')" = 0 ] || fail "two selectors should both apply"
issue_is 22 '## Acceptance

- [x] first criterion
- [x] second criterion
- [x] already done
' || fail "both selected criteria should be ticked"

echo "==> an ambiguous selector refuses rather than guessing"
write_issue 23 "$body_three"
[ "$(run_tick 23 --match 'criterion')" = 1 ] || fail "a selector matching 2 items should exit 1"
issue_is 23 "$body_three" || fail "an ambiguous selector must not write"

echo "==> a selector matching nothing refuses instead of no-opping"
write_issue 24 "$body_three"
[ "$(run_tick 24 --match 'no such text')" = 1 ] || fail "an unmatched selector should exit 1"
issue_is 24 "$body_three" || fail "an unmatched selector must not write"

echo "==> an already-ticked criterion is not a match"
write_issue 25 "$body_three"
[ "$(run_tick 25 --match 'already done')" = 1 ] || fail "a ticked item should not be selectable"
issue_is 25 "$body_three" || fail "a ticked selector must not write"

echo "==> an issue with nothing left to tick exits 1"
write_issue 26 '- [x] all done
'
[ "$(run_tick 26 --index 1)" = 1 ] || fail "a fully ticked issue should exit 1"

echo "==> --dry-run writes nothing"
write_issue 27 "$body_three"
[ "$(run_tick 27 --match 'first' --dry-run)" = 0 ] || fail "--dry-run should succeed"
issue_is 27 "$body_three" || fail "--dry-run must leave the body untouched"

echo "==> the alternate checkbox spellings are tickable"
write_issue 28 '> - [ ] quoted criterion
1. [ ] ordered criterion
*  [ ] loose marker
'
[ "$(run_tick 28 --index 1 --index 2 --index 3)" = 0 ] || fail "GFM spellings should tick"
issue_is 28 '> - [x] quoted criterion
1. [x] ordered criterion
*  [x] loose marker
' || fail "every GFM checkbox spelling should be ticked in place"

echo "==> a literal [ ] inside the criterion text is left alone"
write_issue 29 '- [ ] the parser accepts [ ] as input
'
[ "$(run_tick 29 --index 1)" = 0 ] || fail "should tick a criterion containing a bare box"
issue_is 29 '- [x] the parser accepts [ ] as input
' || fail "only the leading checkbox should flip"

# The live path, with `gh` stubbed on PATH: $ticks is deliberately unset here so
# the script takes its real read-modify-write branch. The stub serves the body
# from $STUB_BODY_1 on the first `issue view` and $STUB_BODY_2 on the second,
# which is what lets the race between the final read and the write be tested at
# all — and records any `issue edit` body at $STUB_EDIT.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${STUB_LOG:-}" ] && printf '%s %s\n' "${1:-}" "${2:-}" >>"$STUB_LOG"
if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
    [ -n "${STUB_FAIL_META:-}" ] && exit 1
    printf '%s' "${STUB_LOGIN:-tester}"
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ] && printf '%s ' "$@" | grep -q -- '--json state'; then
    printf '%s' "${STUB_STATE_NAME:-OPEN}"
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ] && printf '%s ' "$@" | grep -q -- '--json assignees'; then
    printf '%s' "${STUB_ASSIGNEES-tester}"
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
    # Once an edit has been accepted, that is the server's state — which is what
    # makes "the edit applied but the response was lost" testable.
    if [ -f "${STUB_STATE:-/nonexistent}" ]; then cat "$STUB_STATE"; exit 0; fi
    n=0
    [ -f "$STUB_COUNT" ] && n="$(cat "$STUB_COUNT")"
    n=$((n + 1))
    printf '%s' "$n" >"$STUB_COUNT"
    if [ "$n" -eq 1 ]; then cat "$STUB_BODY_1"; else cat "${STUB_BODY_2:-$STUB_BODY_1}"; fi
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--body-file" ]; then
            cp "$2" "$STUB_EDIT"
            [ -n "${STUB_STATE:-}" ] && cp "$2" "$STUB_STATE"
        fi
        shift
    done
    # STUB_EDIT_LOST: the edit applied, then the response was lost.
    [ -n "${STUB_EDIT_LOST:-}" ] && exit 1
    exit 0
fi
exit 1
STUB
chmod +x "$stub_bin/gh"

# run_tick_live ARGS... -> echoes the exit code, with the stub on PATH.
run_tick_live() {
    _rc=0
    env PATH="$stub_bin:$PATH" ISSUE_BODY_DIR="" GH_REPO="" \
        STUB_COUNT="$tmp/count" STUB_BODY_1="$tmp/b1" STUB_BODY_2="$tmp/b2" \
        STUB_EDIT="$tmp/edited" STUB_STATE="$tmp/state" \
        "$tick" --repo "$repo" --issue 30 "$@" >/dev/null 2>&1 || _rc=$?
    echo "$_rc"
}

echo "==> the live path sends the ticked body to gh issue edit"
printf '%s' "$body_three" >"$tmp/b1"
printf '%s' "$body_three" >"$tmp/b2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
[ "$(run_tick_live --match 'first')" = 0 ] || fail "the live path should tick"
[ "$(cat "$tmp/edited")" = "$(printf '%s' '## Acceptance

- [x] first criterion
- [ ] second criterion
- [x] already done
')" ] || fail "gh issue edit should receive exactly the ticked body"

echo "==> a body that moves between the final read and the write is refused"
printf '%s' "$body_three" >"$tmp/b1"
printf '%s' '## Acceptance

- [ ] first criterion
- [ ] second criterion, reworded by someone else
- [x] already done
' >"$tmp/b2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
[ "$(run_tick_live --match 'first')" = 1 ] || fail "a body that changed under us should exit 1"
[ ! -f "$tmp/edited" ] || fail "a changed body must not be overwritten"

echo "==> the body is written back byte for byte, with no newline added"
# `gh issue view --jq` appends a newline the body does not have; read that way
# and written back, every tick would grow the body by a blank line.
printf '%s' '- [ ] no trailing newline here' >"$tmp/b1"
cp "$tmp/b1" "$tmp/b2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
[ "$(run_tick_live --index 1)" = 0 ] || fail "should tick a body with no trailing newline"
printf '%s' '- [x] no trailing newline here' >"$tmp/expected"
cmp -s "$tmp/edited" "$tmp/expected" || fail "the written body must differ only by the marker"

echo "==> an edit that applied but reported failure is recognised, not retried"
printf '%s' "$body_three" >"$tmp/b1"
printf '%s' "$body_three" >"$tmp/b2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
_rc=0
env PATH="$stub_bin:$PATH" ISSUE_BODY_DIR="" GH_REPO="" \
    STUB_COUNT="$tmp/count" STUB_BODY_1="$tmp/b1" STUB_BODY_2="$tmp/b2" \
    STUB_EDIT="$tmp/edited" STUB_STATE="$tmp/state" STUB_EDIT_LOST=1 \
    "$tick" --repo "$repo" --issue 30 --match 'first' >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "a lost response over an applied edit should succeed (got $_rc)"

echo "==> an unreadable issue on the live path exits 2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
_rc=0
env PATH="$stub_bin:$PATH" ISSUE_BODY_DIR="" GH_REPO="" \
    STUB_COUNT="$tmp/count" STUB_BODY_1="$tmp/does-not-exist" \
    STUB_EDIT="$tmp/edited" \
    "$tick" --repo "$repo" --issue 30 --index 1 >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "an unreadable issue should exit 2 (got $_rc)"

echo "==> a tick is refused on an issue this account has not claimed"
# The allowlist cannot constrain arguments, so the claim is what scopes the
# pre-approved write to work a human actually authorised.
printf '%s' "$body_three" >"$tmp/b1"
cp "$tmp/b1" "$tmp/b2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
_rc=0
env PATH="$stub_bin:$PATH" ISSUE_BODY_DIR="" GH_REPO="" \
    STUB_COUNT="$tmp/count" STUB_BODY_1="$tmp/b1" STUB_BODY_2="$tmp/b2" \
    STUB_EDIT="$tmp/edited" STUB_STATE="$tmp/state" STUB_ASSIGNEES="someone-else" \
    "$tick" --repo "$repo" --issue 30 --match 'first' >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "an unclaimed issue should exit 1 (got $_rc)"
[ ! -f "$tmp/edited" ] || fail "an unclaimed issue must not be written to"

echo "==> an issue claimed alongside others is still tickable"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
_rc=0
env PATH="$stub_bin:$PATH" ISSUE_BODY_DIR="" GH_REPO="" \
    STUB_COUNT="$tmp/count" STUB_BODY_1="$tmp/b1" STUB_BODY_2="$tmp/b2" \
    STUB_EDIT="$tmp/edited" STUB_STATE="$tmp/state" STUB_ASSIGNEES="someone-else tester" \
    "$tick" --repo "$repo" --issue 30 --match 'first' >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "a co-assigned issue should tick (got $_rc)"

echo "==> a closed issue is not tickable"
printf '%s' "$body_three" >"$tmp/b1"
cp "$tmp/b1" "$tmp/b2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
_rc=0
env PATH="$stub_bin:$PATH" ISSUE_BODY_DIR="" GH_REPO="" \
    STUB_COUNT="$tmp/count" STUB_BODY_1="$tmp/b1" STUB_BODY_2="$tmp/b2" \
    STUB_EDIT="$tmp/edited" STUB_STATE="$tmp/state" STUB_STATE_NAME="CLOSED" \
    "$tick" --repo "$repo" --issue 30 --match 'first' >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "a closed issue should exit 1 (got $_rc)"
[ ! -f "$tmp/edited" ] || fail "a closed issue must not be written to"

echo "==> a multiline selector value cannot smuggle in a second selector"
write_issue 36 "$body_three"
[ "$(run_tick 36 --match "$(printf 'first\nindex:2')")" = 2 ] || fail "a multiline --match should exit 2"
issue_is 36 "$body_three" || fail "a multiline --match must not write"

echo "==> a blockquoted fence inside a fenced example does not close it"
write_issue 37 '````
> ```
> - [ ] quoted example inside an outer fence
> ```
````

- [ ] the real criterion
'
[ "$(run_tick 37 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 37 '````
> ```
> - [ ] quoted example inside an outer fence
> ```
````

- [x] the real criterion
' || fail "an inner quoted fence must not close the outer one"

echo "==> an ordered marker other than 1 cannot interrupt a paragraph"
write_issue 58 'Some ordinary paragraph text.
2. [ ] example prose, still in the paragraph

- [ ] the real criterion
'
[ "$(run_tick 58 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 58 'Some ordinary paragraph text.
2. [ ] example prose, still in the paragraph

- [x] the real criterion
' || fail "an ordered marker under prose must not be tickable"

echo "==> an ordered marker continuing a list is still a criterion"
write_issue 59 '1. [ ] first
2. [ ] second continues the list
'
[ "$(run_tick 59 --index 2)" = 0 ] || fail "2. should tick inside a list"
issue_is 59 '1. [ ] first
2. [x] second continues the list
' || fail "an ordered item in list context should tick"

echo "==> fence indentation after a quote marker still opens the fence"
write_issue 60 '- >   ```text
  >   - [ ] example in an indented quoted fence
  >   ```

- [ ] the real criterion
'
[ "$(run_tick 60 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 60 '- >   ```text
  >   - [ ] example in an indented quoted fence
  >   ```

- [x] the real criterion
' || fail "permitted fence indentation after a quote must still open the fence"

echo "==> an indented opener still caps its closer at three spaces"
write_issue 54 ' ```
    ```
- [ ] example after the false closer
 ```

- [ ] the real criterion
'
[ "$(run_tick 54 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 54 ' ```
    ```
- [ ] example after the false closer
 ```

- [x] the real criterion
' || fail "a four-space delimiter is content, not a closer"

echo "==> mixed list and blockquote containers hide a fence"
write_issue 55 '- > ```text
  > - [ ] example in a quoted list fence
  > ```

- [ ] the real criterion
'
[ "$(run_tick 55 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 55 '- > ```text
  > - [ ] example in a quoted list fence
  > ```

- [x] the real criterion
' || fail "a fence inside a quote inside a list item must hide its contents"

echo "==> a marker padded past four spaces is code, not a criterion"
write_issue 56 '-     [ ] example indented into a code block

- [ ] the real criterion
'
[ "$(run_tick 56 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 56 '-     [ ] example indented into a code block

- [x] the real criterion
' || fail "five spaces of padding must not be tickable"

echo "==> four spaces of marker padding is still a criterion"
write_issue 57 '-    [ ] four spaces is still a criterion
'
[ "$(run_tick 57 --index 1)" = 0 ] || fail "four spaces is within the limit"
issue_is 57 '-    [x] four spaces is still a criterion
' || fail "a four-space padded item should tick"

echo "==> a fence under nested list markers hides its contents"
write_issue 51 '- - ```text
    - [ ] example in a nested list fence
    ```

- [ ] the real criterion
'
[ "$(run_tick 51 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 51 '- - ```text
    - [ ] example in a nested list fence
    ```

- [x] the real criterion
' || fail "nested list markers must not hide the fence"

echo "==> an ordered marker over nine digits is prose, not a criterion"
write_issue 52 '1234567890. [ ] example prose, not a list item

- [ ] the real criterion
'
[ "$(run_tick 52 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 52 '1234567890. [ ] example prose, not a list item

- [x] the real criterion
' || fail "a ten-digit ordered marker must not be tickable"

echo "==> a nine-digit ordered marker is still a criterion"
write_issue 53 '123456789. [ ] a real ordered criterion
'
[ "$(run_tick 53 --index 1)" = 0 ] || fail "nine digits is within the GFM limit"
issue_is 53 '123456789. [x] a real ordered criterion
' || fail "a nine-digit ordered item should tick"

echo "==> leaving a blockquote ends the fence it opened"
write_issue 50 '> ```
- [ ] the real criterion
> ```
> - [ ] example inside the new quoted fence
'
[ "$(run_tick 50 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 50 '> ```
- [x] the real criterion
> ```
> - [ ] example inside the new quoted fence
' || fail "an unquoted line must end a fence opened inside a blockquote"

echo "==> a backtick line whose info string holds backticks is not an opener"
write_issue 47 '``` `not an opener`
```
- [ ] example inside the real fence
```

- [ ] the real criterion
'
[ "$(run_tick 47 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 47 '``` `not an opener`
```
- [ ] example inside the real fence
```

- [x] the real criterion
' || fail "a non-opener must not shift the fence boundaries"

echo "==> leaving a list container ends the fence it opened"
write_issue 48 '- ```text
  - [ ] indented example
```
- [ ] example in the new outer fence
```

- [ ] the real criterion
'
[ "$(run_tick 48 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 48 '- ```text
  - [ ] indented example
```
- [ ] example in the new outer fence
```

- [x] the real criterion
' || fail "an unindented delimiter opens a new fence, it is not just a closer"

echo "==> a closing-tag-shaped word does not end a <pre> block"
write_issue 49 '<pre>
sample text </prevent> more
- [ ] example inside pre
</pre>

- [ ] the real criterion
'
[ "$(run_tick 49 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 49 '<pre>
sample text </prevent> more
- [ ] example inside pre
</pre>

- [x] the real criterion
' || fail "</prevent> must not end preformatted mode"

echo "==> a fence opened as a list item hides its contents"
write_issue 45 '- ```text
  - [ ] example inside a list-item fence
  ```

- [ ] the real criterion
'
[ "$(run_tick 45 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 45 '- ```text
  - [ ] example inside a list-item fence
  ```

- [x] the real criterion
' || fail "a checkbox inside a list-item fence must be left alone"

echo "==> a list marker on a later line does not close a fence"
# A marker starts a new item; only an opener may carry one. Failing to close is
# the safe direction — the command refuses rather than ticking a code sample.
write_issue 46 '```
- ``` still inside
- [ ] example
```

- [ ] the real criterion
'
[ "$(run_tick 46 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 46 '```
- ``` still inside
- [ ] example
```

- [x] the real criterion
' || fail "only the real criterion should tick"

echo "==> a task item inside raw <pre> HTML is not a criterion"
write_issue 44 '<pre>
- [ ] example rendered verbatim
</pre>

- [ ] the real criterion
'
[ "$(run_tick 44 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 44 '<pre>
- [ ] example rendered verbatim
</pre>

- [x] the real criterion
' || fail "a task item inside <pre> must be left alone"

echo "==> the closing-keyword guard points at the narrowed ticker"
_out="$(printf '%s' 'Closes #5' |
    env ISSUE_BODY_DIR="$fixtures" GH_REPO="" "$closing" --repo "$repo" 2>&1 || true)"
case "$_out" in
*/assets/tick-criteria.sh*) ;;
*) fail "the guard should print a runnable path, not a bare command name" ;;
esac
case "$_out" in
*"gh issue edit"*) fail "the guard should no longer recommend gh issue edit" ;;
esac

echo "==> the body comparison is the last thing before the write"
# The claim re-check makes three API calls; between the comparison and the edit
# they would widen the window the comparison exists to keep small.
printf '%s' "$body_three" >"$tmp/b1"
cp "$tmp/b1" "$tmp/b2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state" "$tmp/log"
_rc=0
env PATH="$stub_bin:$PATH" ISSUE_BODY_DIR="" GH_REPO="" \
    STUB_COUNT="$tmp/count" STUB_BODY_1="$tmp/b1" STUB_BODY_2="$tmp/b2" \
    STUB_EDIT="$tmp/edited" STUB_STATE="$tmp/state" STUB_LOG="$tmp/log" \
    "$tick" --repo "$repo" --issue 30 --match 'first' >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "the ordering probe should tick (got $_rc)"
[ "$(grep -c . "$tmp/log")" -gt 2 ] || fail "the probe should have logged calls"
[ "$(tail -2 "$tmp/log" | head -1)" = "issue view" ] || fail "the body read must be second to last"
[ "$(tail -1 "$tmp/log")" = "issue edit" ] || fail "the edit must immediately follow the body read"

echo "==> a fence delimiter indented four spaces does not close a block"
write_issue 43 '```
    ```
- [ ] still inside the code block
```

- [ ] the real criterion
'
[ "$(run_tick 43 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 43 '```
    ```
- [ ] still inside the code block
```

- [x] the real criterion
' || fail "an over-indented delimiter must not close the fence"

echo "==> a checklist hidden in an HTML comment is not a criterion"
write_issue 41 '<!--
- [ ] example from the issue template
-->

- [ ] the real criterion
'
[ "$(run_tick 41 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 41 '<!--
- [ ] example from the issue template
-->

- [x] the real criterion
' || fail "a commented-out example must be left alone"

echo "==> a single-line HTML comment does not hide what follows it"
write_issue 42 '<!-- guidance --> text

- [ ] the real criterion
'
[ "$(run_tick 42 --index 1)" = 0 ] || fail "a closed comment must not swallow the rest"
issue_is 42 '<!-- guidance --> text

- [x] the real criterion
' || fail "only the real criterion should tick"

echo "==> text GFM does not render as a task item is not a criterion"
# `- [ ]example` has no delimiter after the box, so GitHub renders it as prose.
write_issue 39 '- [ ]example prose, not a checkbox

- [ ] the real criterion
'
[ "$(run_tick 39 --match 'example')" = 1 ] || fail "un-rendered task text should not be selectable"
[ "$(run_tick 39 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 39 '- [ ]example prose, not a checkbox

- [x] the real criterion
' || fail "prose that looks like a task item must be left alone"

echo "==> an empty criterion at end of line is still a criterion"
write_issue 40 '- [ ]
'
[ "$(run_tick 40 --index 1)" = 0 ] || fail "a bare box at end of line should tick"

echo "==> a failed metadata lookup is an environment error, not 'unassigned'"
printf '%s' "$body_three" >"$tmp/b1"
cp "$tmp/b1" "$tmp/b2"
rm -f "$tmp/count" "$tmp/edited" "$tmp/state"
_rc=0
env PATH="$stub_bin:$PATH" ISSUE_BODY_DIR="" GH_REPO="" \
    STUB_COUNT="$tmp/count" STUB_BODY_1="$tmp/b1" STUB_BODY_2="$tmp/b2" \
    STUB_EDIT="$tmp/edited" STUB_STATE="$tmp/state" STUB_FAIL_META=1 \
    "$tick" --repo "$repo" --issue 30 --match 'first' >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "a failed metadata lookup should exit 2 (got $_rc)"
[ ! -f "$tmp/edited" ] || fail "a failed metadata lookup must not write"

echo "==> a deeper fence inside a quoted fenced block does not close it"
write_issue 38 '> ```
> > ```
> > - [ ] example nested deeper
> > ```
> ```

- [ ] the real criterion
'
[ "$(run_tick 38 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 38 '> ```
> > ```
> > - [ ] example nested deeper
> > ```
> ```

- [x] the real criterion
' || fail "a deeper fence must not close a shallower one"

echo "==> a checkbox inside a blockquoted fence is not a criterion"
write_issue 33 '> ```
> - [ ] quoted example
> ```

- [ ] the real criterion
'
[ "$(run_tick 33 --index 1)" = 0 ] || fail "--index 1 should skip the quoted example"
issue_is 33 '> ```
> - [ ] quoted example
> ```

- [x] the real criterion
' || fail "a checkbox inside a blockquoted fence must be left alone"

echo "==> --match resolves on criterion text, never the line number"
write_issue 34 '








- [ ] alpha
- [ ] beta
'
[ "$(run_tick 34 --match '9')" = 1 ] || fail "a line number must not resolve a --match"

echo "==> an empty --match is a usage error, not a blind tick"
write_issue 35 '- [ ] the only criterion
'
[ "$(run_tick 35 --match '')" = 2 ] || fail "an empty --match should exit 2"
issue_is 35 '- [ ] the only criterion
' || fail "an empty --match must not write"

echo "==> a checkbox inside a fenced code block is not a criterion"
write_issue 31 '## Verify

```sh
grep -n "^- \[ \] example" file.md
```

- [ ] the real criterion
'
[ "$(run_tick 31 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 31 '## Verify

```sh
grep -n "^- \[ \] example" file.md
```

- [x] the real criterion
' || fail "the fenced example must be left alone"

echo "==> a longer or tilde fence is tracked too"
write_issue 32 '~~~
- [ ] tilde-fenced
~~~

````
- [ ] backtick-fenced
````

- [ ] the real criterion
'
[ "$(run_tick 32 --index 1)" = 0 ] || fail "only one item should be selectable"
issue_is 32 '~~~
- [ ] tilde-fenced
~~~

````
- [ ] backtick-fenced
````

- [x] the real criterion
' || fail "checkboxes in either fence style must be left alone"

echo "==> usage errors exit 2"
[ "$(run_tick 20)" = 2 ] || fail "no selector should exit 2"
[ "$(run_tick 20 --index 0)" = 2 ] || fail "--index 0 should exit 2"
[ "$(run_tick 20 --index abc)" = 2 ] || fail "a non-numeric --index should exit 2"
_rc=0
env ISSUE_BODY_DIR="$ticks" GH_REPO="" "$tick" --repo "$repo" --issue x --index 1 >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "a non-numeric issue number should exit 2 (got $_rc)"
_rc=0
env ISSUE_BODY_DIR="$ticks" GH_REPO="" "$tick" --issue 20 --index 1 >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "a missing --repo should exit 2 (got $_rc)"
[ "$(run_tick 999 --index 1)" = 2 ] || fail "an unreadable issue should exit 2"

echo "✓ track-work checks behave"
