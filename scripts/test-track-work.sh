#!/usr/bin/env bash
# test-track-work.sh — unit-test the track-work skill's checks and lifecycle
# helpers. Fully
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
metadata="$PWD/ai/skills/universal/track-work/assets/check-issue-metadata.sh"
tick="$PWD/ai/skills/universal/track-work/assets/tick-criteria.sh"
status_sh="./ai/skills/universal/track-work/assets/set-issue-status.sh"
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

# run_rot_repo BODY -> echoes the exit code with this checkout supplying the
# exact-path vocabulary.
run_rot_repo() {
    _rc=0
    printf '%s' "$1" | "$rot" --repo-root . >/dev/null 2>&1 || _rc=$?
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

echo "==> a bare repository path with no Verify section fails"
for path in 'scripts/foo.sh' 'README.md' 'bin/deploy' 'Dockerfile' '.gitignore'; do
    [ "$(run_rot "The defect is in $path.")" = 1 ] ||
        fail "bare path '$path' without Verify should fail"
done

echo "==> a product name with a dotted suffix is not guessed to be a path"
[ "$(run_rot 'Node.js remains supported by the generated project.')" = 0 ] ||
    fail "Node.js should remain ordinary prose without repository evidence"

echo "==> exact checkout paths survive punctuation, earlier URLs, and link fragments"
for prose in 'Update DESIGN.md.' \
    'See https://example.com first, then update DESIGN.md.' \
    'Review [DESIGN.md](https://example.com) before changing it.' \
    'Review [the design](DESIGN.md#goals) before changing it.'; do
    [ "$(run_rot_repo "$prose")" = 1 ] ||
        fail "the exact DESIGN.md path should require Verify: $prose"
done

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

echo "==> a repository file URL is not a bare local path citation"
for url in 'See https://github.com/org/repo/blob/main/README.md for docs.' \
    'See https://github.com/org/repo/blob/main/scripts/foo.sh:42 for docs.'; do
    [ "$(run_rot "$url")" = 0 ] || fail "'$url' should not be flagged as a local path"
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
for phrase in 'Currently it exits 0.' 'Today it exits 0.' 'As of the last run it exits 0.' \
    'Observed 2026-08-17, it exits 0.' 'Right now it exits 0.' \
    'The current behavior drops data.' 'On 2026-08-17 this failed.'; do
    [ "$(run_rot "$phrase")" = 1 ] || fail "'$phrase' should be flagged as perishable"
done

echo "==> an extensionless exact checkout path with a line locator is perishable"
rot_build_repo="$tmp/rot-build"
mkdir -p "$rot_build_repo"
git -C "$rot_build_repo" init -q
: >"$rot_build_repo/BUILD"
_rc=0
printf 'The defect is in BUILD:12.' | "$rot" --repo-root "$rot_build_repo" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "'BUILD:12' should be flagged against a checkout tracking BUILD (got $_rc)"

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

echo "==> an EMPTY tilde-fenced Verify section does not clear the draft either"
# Both fence delimiter spellings are in the authoring profile, so bare tilde
# delimiters must be as non-substantive as bare backtick ones.
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

~~~

~~~
')" = 1 ] || fail "an empty tilde fence under Verify should still fail"

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

echo "==> a hash glued to the heading text is heading text, not a closing sequence"
# CommonMark only strips closing hashes preceded by whitespace, so GitHub
# renders '## Verify#' as the heading 'Verify#' — which is not a Verify section.
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify#

task test:hygiene
')" = 1 ] || fail "'## Verify#' must not satisfy the Verify requirement"

echo "==> an indented heading is outside the profile — indeterminate, not guessed"
# An indented ATX heading renders as a heading, but its structural role is
# container-dependent (a list item can scope it), so canonical headings are
# pinned to column 0 and anything indented is refused.
[ "$(run_rot 'scripts/foo.sh:42 is stale.

   ## Verify

   task test:hygiene
')" = 2 ] || fail "an indented Verify heading should be indeterminate (exit 2)"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

  ## Notes

prose
')" = 2 ] || fail "an indented section heading should be indeterminate (exit 2)"

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

echo "==> a shell comment inside a fenced code block does not end the Verify section (backtick fence)"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

```sh
# check the thing
grep -n x foo.sh
```
')" = 0 ] || fail "a shell comment inside a backtick fence should not terminate the Verify section"

echo "==> a shell comment inside a tilde-fenced code block does not end the Verify section"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

~~~
# check the thing
grep -n x foo.sh
~~~
')" = 0 ] || fail "a shell comment inside a tilde fence should not terminate the Verify section"

echo "==> an indented fence delimiter is outside the profile — indeterminate, not guessed"
# CommonMark gives an indented delimiter a container-dependent meaning, so the
# profile pins fence delimiters to column 0 and the guard reports it cannot
# decide rather than guessing which container holds the fence.
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

   ```sh
   # check the thing
   grep -n x foo.sh
   ```
')" = 2 ] || fail "an indented fence delimiter should be indeterminate (exit 2)"

echo "==> a heading-like line inside a fenced script block is content, not a terminator"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

```sh
### Section
echo "starting"
```
')" = 0 ] || fail "an ATX-heading-like line inside a fence must not end the section"

echo "==> a real heading after a fenced Verify block still terminates the section (heading not swallowed)"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

```sh
```
## Notes

Some prose.
')" = 1 ] || fail "a real heading after the closing fence should still end the section"

echo "==> a real heading after a fenced Verify block with a command still terminates the section"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

```sh
# check the thing
grep -n x foo.sh
```

## Notes

Some prose.
')" = 0 ] || fail "a real heading after the closing fence should end the section but the command should count"

echo "==> a Verify-heading-like line inside a fenced block does not reset the parser"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

```sh
## Verify
echo "still captured"
```
')" = 0 ] || fail "a Verify heading inside a fenced block must not reset parser state"

echo "==> a four-backtick fence is not closed by a three-backtick line inside it"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

````sh
# the command
```
echo "three backticks inside, not a closer"
````
')" = 0 ] || fail "a shorter run of the same char must not close a longer fence"

echo "==> a four-backtick fence is closed by a four-backtick closer"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

````sh
# the command
echo "three backticks inside"
```
````
')" = 0 ] || fail "a matching-length closer should close the fence"

# --- check-issue-metadata.sh ------------------------------------------------

metadata_repo="$tmp/metadata-repo"
metadata_stub="$tmp/metadata-bin"
metadata_fallback="$tmp/metadata-fallback"
mkdir -p "$metadata_repo"
mkdir -p "$metadata_stub" "$metadata_fallback"
git -C "$metadata_repo" init -q
git -C "$metadata_repo" remote add personal https://github.com/testowner/testrepo.git
git -C "$metadata_repo" remote add organization git@github.com:testorg/testrepo.git
: >"$metadata_repo/component.vue"
git -C "$metadata_fallback" init -q
git -C "$metadata_fallback" remote add origin https://github.com/fallback/repo.git
cat >"$metadata_stub/gh" <<'STUB'
#!/bin/sh
if [ -n "${METADATA_GH_LOG:-}" ]; then printf '%s\n' "$*" >>"$METADATA_GH_LOG"; fi
case "${1:-} ${2:-}" in
"api repos/testowner/testrepo" | "api repos/fallback/repo") printf '%s\n' User ;;
"api repos/testorg/testrepo") printf '%s\n' Organization ;;
"api orgs/testorg/issue-types") printf '%s\n' Task Bug Feature Research ;;
"label list")
    if [ "${METADATA_GH_LABELS+x}" = x ]; then
        printf '%s\n' "$METADATA_GH_LABELS"
    else
        printf '%s\n' enhancement area:fixture domain:fixture ai-generated needs-triage 'Rigor:deep' type:fix
    fi
    ;;
*) exit 97 ;;
esac
STUB
chmod +x "$metadata_stub/gh"
PATH="$metadata_stub:$PATH"
export PATH
cp agent-registry.json "$metadata_repo/agent-registry.json"
jq '.families |= map(
      if .family == "area" then
        .values += [{"value":"fixture","description":"Fixture-only area"}]
      elif .family == "domain" then
        .values += [{"value":"fixture","description":"Fixture-only domain"}]
      elif .family == "concern" then
        .values += [{"value":"trusted-review","description":"Fixture trusted concern",
                     "writers":["trusted-human"]}]
      else . end
    )' label-registry.json >"$metadata_repo/label-registry.json"

valid_body="$tmp/metadata-valid.md"
cat >"$valid_body" <<'BODY'
## Problem

Make issue metadata deterministic before creation.

## Acceptance criteria

- [ ] [CI] The metadata checker accepts this draft

## Provenance

Authored for an offline contract test.
BODY

perishable_body="$tmp/metadata-perishable.md"
cat >"$perishable_body" <<'BODY'
## Problem

scripts/example.sh:12 currently returns the wrong result.

## Acceptance criteria

- [ ] [CI] The regression is covered
BODY

verified_body="$tmp/metadata-verified.md"
cat >"$verified_body" <<'BODY'
## Problem

scripts/example.sh:12 currently returns the wrong result.

## Acceptance criteria

- [ ] [CI] The regression is covered

## Verify

Run `task test:track-work`; a failure means the violation remains.
BODY

run_metadata() {
    _rc=0
    "$metadata" "$@" >"$tmp/metadata.out" 2>&1 || _rc=$?
    echo "$_rc"
}

run_personal() {
    _title="$1"
    _body="$2"
    shift 2
    run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
        --owner-type personal --title "$_title" --body-file "$_body" \
        --agent-authored --label feature --label area:fixture \
        --inapplicable layer --label domain:fixture --label ai-generated "$@"
}

run_organization() {
    _title="$1"
    _body="$2"
    shift 2
    PATH="$metadata_stub:$PATH" run_metadata --repo testorg/testrepo --repo-root "$metadata_repo" \
        --owner-type organization --issue-type Task --title "$_title" \
        --body-file "$_body" --agent-authored --label area:fixture \
        --inapplicable layer --label domain:fixture --label ai-generated "$@"
}

echo "==> metadata: a complete personal-account draft passes from the target root manifest"
if [ "$(run_personal 'Validate issue metadata before creation' "$valid_body")" != 0 ]; then
    # Re-run with the checker's debug dump so a CI-only failure carries the
    # vocabulary and toolchain it was judged against.
    CHECK_ISSUE_METADATA_DEBUG=1 run_personal 'Validate issue metadata before creation' \
        "$valid_body" >/dev/null
    fail "valid personal draft should pass: $(cat "$tmp/metadata.out")"
fi

echo "==> metadata: track-work works from a standalone vendored support bundle"
standalone_track_work="$tmp/standalone-track-work"
mkdir -p "$standalone_track_work"
cp -R ai/skills/universal/track-work "$standalone_track_work/track-work"
cp -R ai/skills/universal/label-registry-support \
    "$standalone_track_work/label-registry-support"
[ ! -e "$standalone_track_work/triage" ] ||
    fail "standalone track-work fixture must not contain triage"
standalone_metadata="$standalone_track_work/track-work/assets/check-issue-metadata.sh"
_rc=0
PATH="$metadata_stub:$PATH" "$standalone_metadata" \
    --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Validate standalone issue metadata' \
    --body-file "$valid_body" --agent-authored --label feature \
    --label area:fixture --inapplicable layer --label domain:fixture \
    --label ai-generated >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] ||
    fail "standalone track-work metadata should pass: $(cat "$tmp/metadata.out")"

echo "==> metadata: an organization draft uses native Issue Type and no work-type label"
[ "$(run_organization 'Validate organization issue metadata' "$valid_body")" = 0 ] ||
    fail "valid organization draft should pass: $(cat "$tmp/metadata.out")"

echo "==> metadata: owner type is verified against the target repository"
[ "$(PATH="$metadata_stub:$PATH" run_metadata --repo testorg/testrepo \
    --repo-root "$metadata_repo" --owner-type personal \
    --title 'Reject mismatched owner classification' --body-file "$valid_body" \
    --human-authored --label feature --inapplicable area --inapplicable layer \
    --inapplicable domain)" = 1 ] ||
    fail "an organization repository declared personal should fail"
[ "$(PATH="$metadata_stub:$PATH" run_metadata --repo testowner/testrepo \
    --repo-root "$metadata_repo" --owner-type organization --issue-type Task \
    --title 'Reject mismatched owner classification' --body-file "$valid_body" \
    --human-authored --label area:fixture --inapplicable layer \
    --inapplicable domain)" = 1 ] ||
    fail "a personal repository declared organization is a contract violation (1), not indeterminate"
grep -q 'does not match target repository owner type' "$tmp/metadata.out" ||
    fail "the owner mismatch should be the reported violation"

echo "==> metadata: exact title boundary is 70 Unicode code points"
title70="$(printf 'a%.0s' {1..70})"
title71="${title70}a"
[ "$(run_personal "$title70" "$valid_body")" = 0 ] || fail "70 code points should pass"
[ "$(run_personal "$title71" "$valid_body")" = 1 ] || fail "71 code points should fail"

echo "==> metadata: empty and prefixed titles fail"
[ "$(run_personal '' "$valid_body")" = 1 ] || fail "empty title should fail"
for title in '[Bug]: metadata is missing' 'Bug: metadata is missing' \
    'fix(track-work): add metadata' 'P1: metadata is missing'; do
    [ "$(run_personal "$title" "$valid_body")" = 1 ] || fail "prefixed title should fail: $title"
done

echo "==> metadata: surrounding whitespace cannot smuggle a forbidden prefix"
for title in ' fix: repair metadata' 'Trailing space title '; do
    [ "$(run_personal "$title" "$valid_body")" = 1 ] ||
        fail "a title with surrounding whitespace should fail: '$title'"
done

echo "==> metadata: required headings must exist once, be nonempty, and stay ordered"
for case_name in missing-problem missing-acceptance duplicate-problem empty-problem out-of-order; do
    case "$case_name" in
    missing-problem) body='## Acceptance criteria

- [ ] [CI] Covered' ;;
    missing-acceptance) body='## Problem

Something is wrong.' ;;
    duplicate-problem) body='## Problem

One.

## Problem

Two.

## Acceptance criteria

- [ ] [CI] Covered' ;;
    empty-problem) body='## Problem

## Acceptance criteria

- [ ] [CI] Covered' ;;
    out-of-order) body='## Acceptance criteria

- [ ] [CI] Covered

## Problem

Something is wrong.' ;;
    esac
    printf '%s\n' "$body" >"$tmp/metadata-$case_name.md"
    [ "$(run_personal 'Validate the issue skeleton' "$tmp/metadata-$case_name.md")" = 1 ] ||
        fail "$case_name should fail"
done

echo "==> metadata: a list-wrapped skeleton cannot satisfy the canonical sections"
# GitHub scopes a two-space-indented heading and task to the wrapping list
# item, so a skeleton nested under `- wrapper` is not the top-level contract;
# the profile refuses the indented heading rather than deciding its container.
cat >"$tmp/metadata-list-wrapped.md" <<'BODY'
## Problem

Explain it.

- wrapper
  ## Acceptance criteria
  - [ ] [CI] This is nested under wrapper
BODY
[ "$(run_personal 'Reject list-wrapped skeletons' "$tmp/metadata-list-wrapped.md")" = 1 ] ||
    fail "a list-wrapped acceptance section must not satisfy the contract"

echo "==> metadata: a glued closing hash is heading text, so the heading is noncanonical"
cat >"$tmp/metadata-glued-hash.md" <<'BODY'
## Problem#

GitHub renders the hash as part of the heading text.

## Acceptance criteria

- [ ] [CI] Covered
BODY
[ "$(run_personal 'Reject glued closing hashes' "$tmp/metadata-glued-hash.md")" = 1 ] ||
    fail "'## Problem#' renders as 'Problem#' and must not count as canonical"

echo "==> metadata: the authoring profile refuses hidden or forged structure"
# Each fixture below is a construct an adversarial review round once used to
# hide, forge, or shift canonical structure while the checker emulated GFM
# rendering. The profile answers the whole class at once: every one is a
# named contract violation, never a guess about what GitHub renders.
cat >"$tmp/metadata-commented.md" <<'BODY'
<!--
## Problem

Hidden.

## Acceptance criteria

- [ ] [CI] Hidden criterion
-->
BODY
[ "$(run_personal 'Ignore hidden issue sections' "$tmp/metadata-commented.md")" = 1 ] ||
    fail "HTML-comment-hidden sections must not satisfy the body contract"
grep -q 'outside the authoring profile' "$tmp/metadata.out" ||
    fail "the refusal should name the authoring profile: $(cat "$tmp/metadata.out")"
grep -q 'HTML comment' "$tmp/metadata.out" ||
    fail "the refusal should name the offending construct"

cat >"$tmp/metadata-container-fence.md" <<'BODY'
## Problem

Keep examples out of the issue skeleton.

- ```markdown
  ## Problem

  - [ ] [CI] Example only
  ```

## Acceptance criteria

- [ ] [CI] The real criterion remains visible
BODY
[ "$(run_personal 'Refuse container-nested fences' \
    "$tmp/metadata-container-fence.md")" = 1 ] ||
    fail "a fence opened as list-item content is outside the profile: $(cat "$tmp/metadata.out")"

cat >"$tmp/metadata-raw-html.md" <<'BODY'
<pre>
## Problem
## Acceptance criteria
- [ ] [CI] Hidden example
</pre>

<div>
## Problem

## Problem

Ignore raw HTML examples.

## Acceptance criteria

- [ ] [CI] The real criterion remains visible
BODY
[ "$(run_personal 'Refuse raw HTML headings' "$tmp/metadata-raw-html.md")" = 1 ] ||
    fail "raw HTML blocks are outside the profile: $(cat "$tmp/metadata.out")"

cat >"$tmp/metadata-list-fence-boundary.md" <<'BODY'
- ```text
  Example inside the list item.
```
## Problem

Hidden by the new top-level fence.

## Acceptance criteria

- [ ] [CI] Hidden criterion
BODY
[ "$(run_personal 'Refuse list fence boundaries' \
    "$tmp/metadata-list-fence-boundary.md")" = 1 ] ||
    fail "a list-item fence whose extent depends on containers must be refused"

cat >"$tmp/metadata-malformed-pre-close.md" <<'BODY'
<pre>
Example rendered verbatim.
</pre invalid
## Problem

Still rendered inside the preformatted block.

## Acceptance criteria

- [ ] [CI] Hidden criterion
BODY
[ "$(run_personal 'Refuse malformed raw HTML' \
    "$tmp/metadata-malformed-pre-close.md")" = 1 ] ||
    fail "a malformed closing tag must not expose raw HTML contents"

cat >"$tmp/metadata-comment-boundary.md" <<'BODY'
#<!-- hidden --># Problem

Visible-looking prose.

#<!-- hidden --># Acceptance criteria

- [<!-- hidden --> ] [CI] Forged criterion
BODY
[ "$(run_personal 'Refuse comment token forgeries' \
    "$tmp/metadata-comment-boundary.md")" = 1 ] ||
    fail "inline comments must not forge headings or task syntax"

cat >"$tmp/metadata-html-container-end.md" <<'BODY'
## Problem

Keep visible structure outside an HTML container.

- <div>
  Example inside the list item.
## Acceptance criteria

- [ ] [CI] The top-level heading remains visible
BODY
[ "$(run_personal 'Refuse container-scoped raw HTML' \
    "$tmp/metadata-html-container-end.md")" = 1 ] ||
    fail "raw HTML whose extent depends on containers must be refused: $(cat "$tmp/metadata.out")"

echo "==> metadata: acceptance criteria are tagged rendered task-list items"
for case_name in untagged non-task; do
    if [ "$case_name" = untagged ]; then
        criterion='- [ ] The checker passes'
    else
        criterion='[CI] The checker passes'
    fi
    cat >"$tmp/metadata-$case_name.md" <<BODY
## Problem

Make metadata deterministic.

## Acceptance criteria

$criterion
BODY
    [ "$(run_personal 'Validate acceptance criteria' "$tmp/metadata-$case_name.md")" = 1 ] ||
        fail "$case_name criterion should fail"
done
cat >"$tmp/metadata-nested-untagged.md" <<'BODY'
## Problem

Validate nested criteria.

## Acceptance criteria

- [ ] [CI] Parent criterion
  - [ ] Untagged nested criterion
BODY
[ "$(run_personal 'Validate nested acceptance criteria' \
    "$tmp/metadata-nested-untagged.md")" = 1 ] ||
    fail "a nested untagged criterion should fail"
sed 's/\[ \] Untagged/\[ \] [HUMAN] Tagged/' "$tmp/metadata-nested-untagged.md" \
    >"$tmp/metadata-nested-tagged.md"
[ "$(run_personal 'Validate nested acceptance criteria' \
    "$tmp/metadata-nested-tagged.md")" = 0 ] ||
    fail "a canonical two-space nested tagged criterion should pass: $(cat "$tmp/metadata.out")"
cat >"$tmp/metadata-deep-nested.md" <<'BODY'
## Problem

Validate nesting depth.

## Acceptance criteria

- [ ] [CI] Parent criterion
    - [ ] [HUMAN] Four-space nested criterion
BODY
[ "$(run_personal 'Refuse non-canonical nesting depth' \
    "$tmp/metadata-deep-nested.md")" = 1 ] ||
    fail "nesting deeper than the canonical two spaces is outside the profile"
cat >"$tmp/metadata-inline-raw-task.md" <<'BODY'
## Problem

Preserve inline HTML in rendered criteria.

## Acceptance criteria

- [ ] [CI] Preserve the criterion <pre></pre>
BODY
[ "$(run_personal 'Refuse inline raw HTML tasks' \
    "$tmp/metadata-inline-raw-task.md")" = 1 ] ||
    fail "inline raw HTML in a criterion is outside the profile: $(cat "$tmp/metadata.out")"
for invalid_marker in '1234567890. [ ] [CI] Too many marker digits' \
    '-     [ ] [CI] Checkbox rendered as code'; do
    cat >"$tmp/metadata-nonrendered-task.md" <<BODY
## Problem

Reject task syntax that GFM does not render.

## Acceptance criteria

$invalid_marker
BODY
    [ "$(run_personal 'Reject non-rendered task markers' \
        "$tmp/metadata-nonrendered-task.md")" = 1 ] ||
        fail "a non-rendered task marker must fail: $invalid_marker"
done
cat >"$tmp/metadata-indented-code-task.md" <<'BODY'
## Problem

Reject criteria rendered as code.

## Acceptance criteria

- [ ] [CI] Visible criterion
      - [ ] [CI] Hidden as indented code
BODY
[ "$(run_personal 'Reject indented code criteria' \
    "$tmp/metadata-indented-code-task.md")" = 1 ] ||
    fail "task syntax rendered as indented code must not count as a criterion"
{
    printf '%s\n' '## Problem' '' 'Reject empty criteria.' '' '## Acceptance criteria' ''
    printf '%s \n' '- [ ] [CI]'
} >"$tmp/metadata-empty-criterion.md"
[ "$(run_personal 'Reject empty acceptance criteria' \
    "$tmp/metadata-empty-criterion.md")" = 1 ] ||
    fail "a tagged criterion with no descriptive text should fail"

echo "==> metadata: the existing perishable-fact checker is the Verify gate"
[ "$(run_personal 'Cover perishable issue facts' "$perishable_body")" = 1 ] ||
    fail "perishable facts without Verify should fail"
[ "$(run_personal 'Cover perishable issue facts' "$verified_body")" = 0 ] ||
    fail "perishable facts with Verify should pass: $(cat "$tmp/metadata.out")"
cat >"$tmp/metadata-bare-path.md" <<'BODY'
## Problem

The defect is in scripts/example.sh, observed 2026-08-17.

## Acceptance criteria

- [ ] [CI] The regression is covered
BODY
[ "$(run_personal 'Cover bare path observations' "$tmp/metadata-bare-path.md")" = 1 ] ||
    fail "a bare path and observed date without Verify should fail"
cat >"$tmp/metadata-repository-path.md" <<'BODY'
## Problem

component.vue contains the stale behavior.

## Acceptance criteria

- [ ] [CI] The stale behavior is removed
BODY
[ "$(run_personal 'Resolve exact repository paths' \
    "$tmp/metadata-repository-path.md")" = 1 ] ||
    fail "an exact target-checkout path without Verify should fail"
sed 's/component\.vue/[the component](component.vue)/' \
    "$tmp/metadata-repository-path.md" >"$tmp/metadata-linked-repository-path.md"
[ "$(run_personal 'Resolve linked repository paths' \
    "$tmp/metadata-linked-repository-path.md")" = 1 ] ||
    fail "an exact target-checkout path used as a link destination should require Verify"
sed 's/^## Verify$/### Verify/' "$verified_body" >"$tmp/metadata-wrong-verify-level.md"
[ "$(run_personal 'Require the canonical Verify heading' \
    "$tmp/metadata-wrong-verify-level.md")" = 1 ] ||
    fail "a perishable fact with only a noncanonical Verify heading should fail"
cat >"$tmp/metadata-current-no-verify.md" <<'BODY'
## Problem

Preserve a durable invariant.

## Current violation (observed 2026-08-17)

The target is stale.

## Acceptance criteria

- [ ] [CI] The target is refreshed
BODY
[ "$(run_personal 'Require Verify for observed violations' \
    "$tmp/metadata-current-no-verify.md")" = 1 ] ||
    fail "Current violation must require Verify even when rot patterns do not match its prose"
cat >"$tmp/metadata-fenced-comment.md" <<'BODY'
## Problem

```html
<!-- scripts/example.sh:12 currently fails -->
```

## Acceptance criteria

- [ ] [CI] Cover the visible stale citation
BODY
[ "$(run_personal 'Preserve fenced comment literals' \
    "$tmp/metadata-fenced-comment.md")" = 1 ] ||
    fail "a perishable citation inside a fenced comment literal should require Verify"

echo "==> metadata: labels must be known and exclusive families cannot conflict"
[ "$(run_personal 'Reject unknown labels' "$valid_body" --label unknown-label)" = 1 ] ||
    fail "unknown label should fail"
[ "$(run_personal 'Reject conflicting axes' "$valid_body" --label area:skills)" = 1 ] ||
    fail "two area labels should fail"

echo "==> metadata: agent-authored issues require ai-generated and agent-writable labels"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Require issue provenance' --body-file "$valid_body" \
    --agent-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture)" = 1 ] || fail "missing ai-generated should fail"
[ "$(run_personal 'Respect label writers' "$valid_body" --label sec)" = 1 ] ||
    fail "an agent must not propose a human-only concern"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Allow true concern labels' --body-file "$valid_body" \
    --human-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture --label sec)" = 0 ] ||
    fail "a human-authored draft may carry a true concern: $(cat "$tmp/metadata.out")"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Reject tool-owned authoring state' \
    --body-file "$valid_body" --human-authored --label feature --label area:fixture \
    --inapplicable layer --label domain:fixture --label 'autorelease: pending')" = 1 ] ||
    fail "a human author must not propose a tool-owned label"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Require attributable trusted labels' \
    --body-file "$valid_body" --human-authored --label feature --label area:fixture \
    --inapplicable layer --label domain:fixture --label trusted-review)" = 2 ] ||
    fail "a self-asserted human author cannot authorize a trusted-human label"
grep -q 'actor-verifying trusted-human workflow' "$tmp/metadata.out" ||
    fail "trusted-human refusal should name the required verification path"

echo "==> metadata: manifest open-value families resolve proposed live labels"
: >"$tmp/metadata-gh.log"
_rc=0
METADATA_GH_LOG="$tmp/metadata-gh.log" "$metadata" \
    --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Allow a live open-value label' \
    --body-file "$valid_body" --human-authored --label feature \
    --label area:fixture --inapplicable layer --label domain:fixture \
    --label type:fix >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "a live open-value label should pass: $(cat "$tmp/metadata.out")"
[ "$(grep -c '^label list ' "$tmp/metadata-gh.log")" = 1 ] ||
    fail "open-value resolution should make one bounded label-list read"
grep -q 'label list.*--repo testowner/testrepo.*--limit 1000.*--json name' \
    "$tmp/metadata-gh.log" || fail "open-value label read must be repo-bound and bounded"
[ "$(run_personal 'Enforce open-value family writers' "$valid_body" --label type:fix)" = 1 ] ||
    fail "an agent must not write a human-only open-value label"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Reject an absent open-value label' \
    --body-file "$valid_body" --human-authored --label feature \
    --label area:fixture --inapplicable layer --label domain:fixture \
    --label type:missing)" = 1 ] || fail "an absent open-value label should remain unknown"

echo "==> metadata: open classification policy remains a track-work capability"
metadata_open_classification="$tmp/metadata-open-classification"
mkdir -p "$metadata_open_classification"
git -C "$metadata_open_classification" init -q
git -C "$metadata_open_classification" remote add origin \
    https://github.com/testowner/testrepo.git
jq '.families |= map(
      if .family == "area" then
        .open_values = true | .placeholder = "area:<value>" | .values = []
      else . end)' "$metadata_repo/label-registry.json" \
    >"$metadata_open_classification/label-registry.json"
_rc=0
PATH="$metadata_stub:$PATH" "$metadata" --repo testowner/testrepo \
    --repo-root "$metadata_open_classification" --owner-type personal \
    --title 'Allow an open classification family' --body-file "$valid_body" \
    --human-authored --label feature --label area:fixture \
    --inapplicable layer --label domain:fixture >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] ||
    fail "track-work should accept a live member of an open classification family: $(cat "$tmp/metadata.out")"

echo "==> metadata: a label matching two open-value families is ambiguous, not first-match"
metadata_ambiguous="$tmp/metadata-ambiguous"
mkdir -p "$metadata_ambiguous"
git -C "$metadata_ambiguous" init -q
git -C "$metadata_ambiguous" remote add origin https://github.com/testowner/testrepo.git
jq '.families += [{
      "family": "type-shadow", "prefix": "type",
      "purpose": "Fixture sibling family sharing the type prefix",
      "axis": "meta", "source": "inline", "writers": ["agent"],
      "readers": "fixture", "lifecycle": "durable", "exclusive": false,
      "provision": false, "open_values": true, "placeholder": "type:example",
      "values": []
    }]' "$metadata_repo/label-registry.json" >"$metadata_ambiguous/label-registry.json"
_rc=0
PATH="$metadata_stub:$PATH" "$metadata" --repo testowner/testrepo \
    --repo-root "$metadata_ambiguous" --owner-type personal \
    --title 'Reject ambiguous open-value prefixes' --body-file "$valid_body" \
    --human-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture --label type:fix >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "an ambiguous open-value label should be indeterminate (got $_rc): $(cat "$tmp/metadata.out")"
grep -q 'matches multiple open-value families' "$tmp/metadata.out" ||
    fail "the refusal should name the ambiguity"
grep -q 'type-override' "$tmp/metadata.out" && grep -q 'type-shadow' "$tmp/metadata.out" ||
    fail "the refusal should name both families"

echo "==> metadata: an enumerated open-value member absent from the live read fails as unknown"
metadata_enumerated="$tmp/metadata-enumerated"
mkdir -p "$metadata_enumerated"
git -C "$metadata_enumerated" init -q
git -C "$metadata_enumerated" remote add origin https://github.com/testowner/testrepo.git
jq '.families |= map(
      if .family == "type-override" then
        .values += [{"value": "stale-member",
                     "description": "Enumerated but absent from the live read"}]
      else . end)' "$metadata_repo/label-registry.json" \
    >"$metadata_enumerated/label-registry.json"
_rc=0
PATH="$metadata_stub:$PATH" "$metadata" --repo testowner/testrepo \
    --repo-root "$metadata_enumerated" --owner-type personal \
    --title 'Reject absent enumerated open members' --body-file "$valid_body" \
    --human-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture --label type:stale-member >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 1 ] ||
    fail "an enumerated open member missing live should fail as unknown (got $_rc): $(cat "$tmp/metadata.out")"
grep -q "label 'type:stale-member' does not exist" "$tmp/metadata.out" ||
    fail "the absent enumerated open member should be reported as unknown"

echo "==> metadata: the manifest is resolved from the checkout top level, not the subdirectory"
metadata_subdir_root="$tmp/metadata-subdir"
mkdir -p "$metadata_subdir_root/nested/deeper"
git -C "$metadata_subdir_root" init -q
git -C "$metadata_subdir_root" remote add origin https://github.com/testowner/testrepo.git
printf '{not json\n' >"$metadata_subdir_root/label-registry.json"
: >"$tmp/metadata-gh.log"
_rc=0
PATH="$metadata_stub:$PATH" METADATA_GH_LOG="$tmp/metadata-gh.log" \
    "$metadata" --repo testowner/testrepo --repo-root "$metadata_subdir_root/nested/deeper" \
    --owner-type personal --title 'Resolve the top-level manifest' \
    --body-file "$valid_body" --human-authored --label feature --inapplicable area \
    --inapplicable layer --inapplicable domain >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] ||
    fail "a subdirectory --repo-root must still find (and fail closed on) the top-level manifest (got $_rc)"
[ ! -s "$tmp/metadata-gh.log" ] ||
    fail "a bypassed top-level manifest must not fall through to gh"

echo "==> metadata: a strategy-axis family is authoring-forbidden whatever its prefix"
metadata_strategy="$tmp/metadata-strategy"
mkdir -p "$metadata_strategy"
git -C "$metadata_strategy" init -q
git -C "$metadata_strategy" remote add origin https://github.com/testowner/testrepo.git
jq '.families += [{
      "family": "route-hint", "prefix": "route",
      "purpose": "Fixture strategy family under an unlisted prefix",
      "axis": "strategy", "source": "inline", "writers": ["agent"],
      "readers": "fixture", "lifecycle": "durable", "exclusive": false,
      "provision": false,
      "values": [{"value": "fast", "description": "Fixture routing hint"}]
    }]' "$metadata_repo/label-registry.json" >"$metadata_strategy/label-registry.json"
_rc=0
PATH="$metadata_stub:$PATH" "$metadata" --repo testowner/testrepo \
    --repo-root "$metadata_strategy" --owner-type personal \
    --title 'Reject renamed strategy families' --body-file "$valid_body" \
    --agent-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture --label ai-generated --label route:fast \
    >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "a strategy-axis label under a new prefix should fail (got $_rc)"
grep -q "authoring-forbidden 'strategy' axis" "$tmp/metadata.out" ||
    fail "the rejection should name the strategy axis"

echo "==> metadata: needs-triage on a fully decided classification is stale"
[ "$(run_personal 'Reject stale triage labels' "$valid_body" --label needs-triage)" = 1 ] ||
    fail "needs-triage with every axis decided should fail"
grep -q 'every axis is decided' "$tmp/metadata.out" ||
    fail "the rejection should say the classification is decided"

echo "==> metadata: a retired open-family member is not resurrected by its live label"
metadata_retired="$tmp/metadata-retired"
mkdir -p "$metadata_retired"
git -C "$metadata_retired" init -q
git -C "$metadata_retired" remote add origin https://github.com/testowner/testrepo.git
jq '.families |= map(
      if .family == "type-override" then
        .values += [{"value": "fix", "description": "Retired fixture member",
                     "retired": true}]
      else . end)' "$metadata_repo/label-registry.json" \
    >"$metadata_retired/label-registry.json"
_rc=0
PATH="$metadata_stub:$PATH" "$metadata" --repo testowner/testrepo \
    --repo-root "$metadata_retired" --owner-type personal \
    --title 'Reject retired open members' --body-file "$valid_body" \
    --human-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture --label type:fix >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 1 ] ||
    fail "a retired open-family member should fail even with a live label (got $_rc): $(cat "$tmp/metadata.out")"
grep -q "label 'type:fix' is retired by the manifest" "$tmp/metadata.out" ||
    fail "the rejection should say the label is retired"

echo "==> metadata: a required section holding only an empty fence is empty"
cat >"$tmp/metadata-empty-fence-problem.md" <<'BODY'
## Problem

```sh
```

## Acceptance criteria

- [ ] [CI] Covered
BODY
[ "$(run_personal 'Reject empty fenced sections' \
    "$tmp/metadata-empty-fence-problem.md")" = 1 ] ||
    fail "a Problem section holding only an empty fence should fail"
cat >"$tmp/metadata-fenced-problem.md" <<'BODY'
## Problem

```text
the problem, stated inside a code block
```

## Acceptance criteria

- [ ] [CI] Covered
BODY
[ "$(run_personal 'Accept fenced problem content' \
    "$tmp/metadata-fenced-problem.md")" = 0 ] ||
    fail "a fence with real contents should still count as section content: $(cat "$tmp/metadata.out")"

echo "==> a rot remediation template matches the canonical skeleton"
_out="$(printf 'scripts/foo.sh:42 is stale.' | "$rot" 2>&1 || true)"
printf '%s\n' "$_out" | grep -q '## Problem' ||
    fail "the rot remediation should teach the canonical Problem skeleton"
printf '%s\n' "$_out" | grep -q '## Acceptance criteria' ||
    fail "the rot remediation should include Acceptance criteria"
if printf '%s\n' "$_out" | grep -q '## Invariant'; then
    fail "the rot remediation must not teach the legacy Invariant skeleton"
fi

echo "==> metadata: a concrete record shadowing an open family is ambiguous too"
metadata_shadowed="$tmp/metadata-shadowed"
mkdir -p "$metadata_shadowed"
git -C "$metadata_shadowed" init -q
git -C "$metadata_shadowed" remote add origin https://github.com/testowner/testrepo.git
jq '.families += [{
      "family": "type-concrete",
      "purpose": "Fixture concrete family enumerating a name the open family covers",
      "prefix": "type", "axis": "meta", "source": "inline", "writers": ["agent"],
      "readers": "fixture", "lifecycle": "durable", "exclusive": false,
      "provision": false,
      "values": [{"value": "fix", "description": "Fixture shadowing value"}]
    }]' "$metadata_repo/label-registry.json" >"$metadata_shadowed/label-registry.json"
_rc=0
PATH="$metadata_stub:$PATH" "$metadata" --repo testowner/testrepo \
    --repo-root "$metadata_shadowed" --owner-type personal \
    --title 'Reject shadowed open-value labels' --body-file "$valid_body" \
    --human-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture --label type:fix >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "an open label shadowed by a concrete family should be indeterminate (got $_rc): $(cat "$tmp/metadata.out")"
grep -q 'no unique policy' "$tmp/metadata.out" ||
    fail "the refusal should say the policy is not unique"
grep -q 'type-concrete' "$tmp/metadata.out" && grep -q 'type-override' "$tmp/metadata.out" ||
    fail "the refusal should name the concrete and open families"

echo "==> metadata: incomplete classification requires needs-triage and names the axis"
_rc="$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Keep incomplete classification visible' \
    --body-file "$valid_body" --agent-authored --label feature \
    --label area:fixture --inapplicable layer --label ai-generated)"
[ "$_rc" = 1 ] || fail "missing domain without needs-triage should fail"
grep -qi 'domain' "$tmp/metadata.out" || fail "the undecided domain axis should be named"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Keep incomplete classification visible' \
    --body-file "$valid_body" --agent-authored --label feature \
    --label area:fixture --inapplicable layer --label ai-generated \
    --label needs-triage)" = 0 ] ||
    fail "needs-triage should preserve an undecided axis: $(cat "$tmp/metadata.out")"

echo "==> metadata: owner type controls work classification"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Require a work type' --body-file "$valid_body" \
    --human-authored --label area:fixture --inapplicable layer --label domain:fixture)" = 1 ] ||
    fail "personal repo without a work type should fail"
[ "$(run_personal 'Reject stacked work types' "$valid_body" --label task)" = 1 ] ||
    fail "personal repo with two work types should fail"
[ "$(run_organization 'Reject labels in place of Issue Type' "$valid_body" --label feature)" = 1 ] ||
    fail "organization repo with a work-type label should fail"
[ "$(run_metadata --repo testorg/testrepo --repo-root "$metadata_repo" \
    --owner-type organization --title 'Require native Issue Type' --body-file "$valid_body" \
    --human-authored --label area:fixture --inapplicable layer --label domain:fixture)" = 1 ] ||
    fail "organization repo without Issue Type should fail"
[ "$(PATH="$metadata_stub:$PATH" run_metadata --repo testorg/testrepo \
    --repo-root "$metadata_repo" --owner-type organization \
    --issue-type 'Definitely Not A Real Type' --title 'Validate native Issue Types' \
    --body-file "$valid_body" --human-authored --label area:fixture --inapplicable layer \
    --label domain:fixture)" = 1 ] || fail "unknown native Issue Type should fail"

echo "==> metadata: authoring-time strategy, routing, claim, and Foreman labels are forbidden"
for label in rigor:deep tier:apex method:plan suggest:gpt claim:gpt foreman:approved agent:codex; do
    [ "$(run_personal 'Reject authoring-time control labels' "$valid_body" --label "$label")" = 1 ] ||
        fail "$label should be forbidden during authoring"
    grep -qF "$label" "$tmp/metadata.out" || fail "the rejection should name $label"
done

echo "==> metadata: an absent manifest falls back to one bounded label read"
: >"$tmp/metadata-gh.log"
_rc=0
PATH="$metadata_stub:$PATH" METADATA_GH_LOG="$tmp/metadata-gh.log" \
    "$metadata" --repo fallback/repo --repo-root "$metadata_fallback" \
    --owner-type personal --title 'Validate fallback metadata' \
    --body-file "$valid_body" --agent-authored --work-type-label enhancement \
    --label area:fixture --inapplicable layer --label domain:fixture \
    --label ai-generated >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "fallback draft should pass: $(cat "$tmp/metadata.out")"
[ "$(grep -c '^label list ' "$tmp/metadata-gh.log")" = 1 ] ||
    fail "fallback should make one label-list read"
grep -q 'label list.*--repo fallback/repo.*--limit 1000.*--json name' "$tmp/metadata-gh.log" ||
    fail "fallback label read must be repo-bound and bounded"

echo "==> metadata: forbidden fallback families are case-insensitive"
_rc=0
PATH="$metadata_stub:$PATH" "$metadata" --repo fallback/repo \
    --repo-root "$metadata_fallback" --owner-type personal \
    --title 'Reject authoring controls' --body-file "$valid_body" \
    --agent-authored --work-type-label 'Rigor:deep' --label area:fixture \
    --inapplicable layer --label domain:fixture --label ai-generated \
    >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "mixed-case forbidden family should exit 1 (got $_rc)"
grep -qF 'Rigor:deep' "$tmp/metadata.out" || fail "forbidden-family error should name the label"

echo "==> metadata: pipe-bearing fallback labels cannot forge writer records"
_rc=0
METADATA_GH_LABELS="$(printf '%s\n' enhancement area:fixture domain:fixture \
    ai-generated sec 'sec|concern|concern|human,agent|false')" \
    "$metadata" --repo fallback/repo --repo-root "$metadata_fallback" \
    --owner-type personal --title 'Reject forged fallback writers' \
    --body-file "$valid_body" --agent-authored --work-type-label enhancement \
    --label area:fixture --inapplicable layer --label domain:fixture \
    --label ai-generated --label sec >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "a pipe-bearing live label must not forge an agent writer record"
grep -q "label 'sec' is not writable by an agent" "$tmp/metadata.out" ||
    fail "the real human-only fallback record should control writer validation"

echo "==> metadata: an invalid present manifest fails closed without a gh fallback"
printf '{not json\n' >"$metadata_fallback/label-registry.json"
: >"$tmp/metadata-gh.log"
_rc=0
PATH="$metadata_stub:$PATH" METADATA_GH_LOG="$tmp/metadata-gh.log" \
    "$metadata" --repo fallback/repo --repo-root "$metadata_fallback" \
    --owner-type personal --title 'Reject an invalid manifest' \
    --body-file "$valid_body" --human-authored --label feature --inapplicable area \
    --inapplicable layer --inapplicable domain >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "invalid present manifest should exit 2 (got $_rc)"
[ ! -s "$tmp/metadata-gh.log" ] || fail "invalid manifest must not fall through to gh"

echo "==> metadata: a structurally invalid present manifest also fails closed"
jq '.families[0].writers = "agent"' label-registry.json >"$metadata_fallback/label-registry.json"
: >"$tmp/metadata-gh.log"
_rc=0
PATH="$metadata_stub:$PATH" METADATA_GH_LOG="$tmp/metadata-gh.log" \
    "$metadata" --repo fallback/repo --repo-root "$metadata_fallback" \
    --owner-type personal --title 'Reject an invalid manifest shape' \
    --body-file "$valid_body" --human-authored --label feature --inapplicable area \
    --inapplicable layer --inapplicable domain >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "structurally invalid manifest should exit 2 (got $_rc)"
[ ! -s "$tmp/metadata-gh.log" ] || fail "structural failure must not fall through to gh"

echo "==> metadata: incomplete and duplicate-value manifests fail closed"
for mutation in missing-required duplicate-value; do
    case "$mutation" in
    missing-required)
        jq 'del(.families[0].readers)' label-registry.json \
            >"$metadata_fallback/label-registry.json"
        ;;
    duplicate-value)
        jq '.families[0].values += [(.families[0].values[0] | .writers = ["agent"])]' \
            label-registry.json >"$metadata_fallback/label-registry.json"
        ;;
    esac
    _rc=0
    "$metadata" --repo fallback/repo --repo-root "$metadata_fallback" \
        --owner-type personal --title 'Reject invalid manifest records' \
        --body-file "$valid_body" --human-authored --label feature \
        --inapplicable area --inapplicable layer --inapplicable domain \
        >"$tmp/metadata.out" 2>&1 || _rc=$?
    [ "$_rc" = 2 ] || fail "$mutation manifest should exit 2 (got $_rc)"
done

echo "==> metadata: the portless ssh.github.com remote form binds the checkout"
# AGENTS.md documents four GitHub SSH remote spellings; the port-443 and
# portless ssh.github.com forms are distinct and both must normalize.
metadata_sshport="$tmp/metadata-sshport"
mkdir -p "$metadata_sshport"
git -C "$metadata_sshport" init -q
git -C "$metadata_sshport" remote add origin 'ssh://git@ssh.github.com/testowner/testrepo.git'
cp "$metadata_repo/label-registry.json" "$metadata_sshport/label-registry.json"
[ "$(PATH="$metadata_stub:$PATH" run_metadata --repo testowner/testrepo \
    --repo-root "$metadata_sshport" --owner-type personal \
    --title 'Bind portless ssh remotes' --body-file "$valid_body" \
    --human-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture)" = 0 ] ||
    fail "a portless ssh.github.com remote should bind: $(cat "$tmp/metadata.out")"

echo "==> metadata: the checkout remote must match the requested repository"
_rc=0
"$metadata" --repo another/repo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Bind the target checkout' --body-file "$valid_body" \
    --human-authored --label feature --inapplicable area --inapplicable layer \
    --inapplicable domain >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "mismatched repo-root should exit 2 (got $_rc)"

echo "==> metadata: help documents both owner-type examples and bad usage exits 2"
help="$($metadata --help 2>&1 || true)"
printf '%s\n' "$help" | grep -q 'Personal-account example' || fail "help needs a personal example"
printf '%s\n' "$help" | grep -q 'Organization example' || fail "help needs an organization example"
[ "$(run_metadata --repo testowner/testrepo --title x --body-file "$valid_body" \
    --owner-type personal --human-authored --label feature)" = 2 ] ||
    fail "missing repo-root should exit 2"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Require explicit authorship' --body-file "$valid_body" \
    --label feature --label area:fixture --inapplicable layer \
    --label domain:fixture)" = 2 ] || fail "omitted author type should exit 2"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Reject conflicting authorship' --body-file "$valid_body" \
    --agent-authored --human-authored --label feature --label area:fixture \
    --inapplicable layer --label domain:fixture --label ai-generated)" = 2 ] ||
    fail "conflicting author types should exit 2"

echo "==> metadata: delegation guidance preserves the concrete authoring contract"
for checker_path in \
    './ai/skills/universal/track-work/assets/check-issue-metadata.sh:*' \
    './.agents/skills/track-work/assets/check-issue-metadata.sh:*' \
    './.claude/skills/track-work/assets/check-issue-metadata.sh:*'; do
    grep -qF "Bash($checker_path)" ai/skills/universal/track-work/SKILL.md ||
        fail "skill frontmatter must allow the portable checker path $checker_path"
done
for doc in ai/skills/universal/track-work/SKILL.md \
    ai/skills/universal/track-work/references/issue-authoring.md; do
    normalized_doc="$(tr '\n' ' ' <"$doc")"
    printf '%s\n' "$normalized_doc" | grep -qi 'target repository' ||
        fail "$doc must carry the target repository"
    printf '%s\n' "$normalized_doc" | grep -qi 'title and body contract' ||
        fail "$doc must carry the title and body contract"
    printf '%s\n' "$normalized_doc" | grep -qi 'concrete labels or explicit *inapplicability' ||
        fail "$doc must carry concrete labels or explicit inapplicability"
    printf '%s\n' "$normalized_doc" | grep -qi 'created issue number' ||
        fail "$doc must require the created issue number"
    printf '%s\n' "$normalized_doc" | grep -qi 'unable to decide.*metadata' ||
        fail "$doc must define metadata uncertainty"
done

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

echo "==> inline raw HTML is outside the ticking profile — refused, nothing written"
write_issue 33 '## Acceptance criteria

- [ ] criterion <pre></pre>
'
[ "$(run_tick 33 --match 'criterion')" = 1 ] ||
    fail "a body carrying inline raw HTML should refuse the mechanized tick"
issue_is 33 '## Acceptance criteria

- [ ] criterion <pre></pre>
' || fail "a profile refusal must not write"
_out="$(env ISSUE_BODY_DIR="$ticks" GH_REPO="" \
    "$tick" --repo "$repo" --issue 33 --match 'criterion' 2>&1 || true)"
printf '%s\n' "$_out" | grep -q 'outside the mechanized ticking profile' ||
    fail "the refusal should say the body is outside the profile"
printf '%s\n' "$_out" | grep -q 'raw HTML tag' ||
    fail "the refusal should name the offending construct and line"

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

echo "==> quoted criteria and loose marker spacing are outside the profile"
write_issue 28 '> - [ ] quoted criterion
1. [ ] ordered criterion
*  [ ] loose marker
'
[ "$(run_tick 28 --index 1 --index 2 --index 3)" = 1 ] ||
    fail "quoted tasks and non-canonical spacing should refuse the mechanized tick"
issue_is 28 '> - [ ] quoted criterion
1. [ ] ordered criterion
*  [ ] loose marker
' || fail "a profile refusal must not write"

echo "==> the canonical marker spellings are tickable"
write_issue 30 '- [ ] dash criterion
* [ ] star criterion
+ [ ] plus criterion
'
[ "$(run_tick 30 --index 1 --index 2 --index 3)" = 0 ] || fail "canonical spellings should tick"
issue_is 30 '- [x] dash criterion
* [x] star criterion
+ [x] plus criterion
' || fail "every canonical marker spelling should be ticked in place"

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
# Its own directory: `$tmp/bin` already holds the closing-keyword stub, and two
# suites writing a `gh` into one directory means whichever ran last decides what
# the other sees.
stub_bin="$tmp/tickbin"
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

# --- profile refusals --------------------------------------------------------
# Every fixture below is an attack a review round once aimed at the GFM
# emulation this parser no longer attempts: constructs whose rendering depends
# on container state. The profile refuses each whole body, names the offending
# line, and writes nothing — the attack cannot tick the wrong box because
# nothing is ticked at all.

# refused_body NUM BODY — assert the mechanized tick refuses NUM's body
# untouched, for every selector shape.
refused_body() {
    write_issue "$1" "$2"
    [ "$(run_tick "$1" --index 1)" = 1 ] ||
        fail "issue $1 is outside the profile and must refuse --index"
    [ "$(run_tick "$1" --match 'criterion')" = 1 ] ||
        fail "issue $1 is outside the profile and must refuse --match"
    issue_is "$1" "$2" || fail "a profile refusal must not write (issue $1)"
}

echo "==> everything inside a column-0 fence is opaque, quoted delimiters included"
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

echo "==> quoted, list-nested, and indented fences are refused"
refused_body 61 '- ```text
  content
- ```text
  - [ ] example inside the sibling fence
  ```

- [ ] the real criterion
'
refused_body 60 '- >   ```text
  >   - [ ] example in an indented quoted fence
  >   ```

- [ ] the real criterion
'
refused_body 54 ' ```
    ```
- [ ] example after the false closer
 ```

- [ ] the real criterion
'
refused_body 55 '- > ```text
  > - [ ] example in a quoted list fence
  > ```

- [ ] the real criterion
'
refused_body 51 '- - ```text
    - [ ] example in a nested list fence
    ```

- [ ] the real criterion
'
refused_body 50 '> ```
- [ ] the real criterion
> ```
> - [ ] example inside the new quoted fence
'

echo "==> non-canonical task spacing and markers are refused"
refused_body 62 'Some ordinary paragraph text.
2. prose that cannot interrupt
3. [ ] example prose

- [ ] the real criterion
'
refused_body 58 'Some ordinary paragraph text.
2. [ ] example prose, still in the paragraph

- [ ] the real criterion
'
refused_body 56 '-     [ ] example indented into a code block

- [ ] the real criterion
'
refused_body 57 '-    [ ] four spaces of padding is not the canonical single space
'
refused_body 52 '1234567890. [ ] example prose, not a list item

- [ ] the real criterion
'
_tabbed="$(printf -- '-\t```text\n\t- [ ] first example\n  ```\n- [ ] example in the outer fence\n  ```\n\n- [ ] the real criterion\n')"
refused_body 63 "$_tabbed"

echo "==> raw script, style and textarea blocks are refused"
for raw in script style textarea; do
    refused_body 64 "$(printf '<%s>\n- [ ] example in raw html\n</%s>\n\n- [ ] the real criterion\n' "$raw" "$raw")"
done

echo "==> an ordered marker continuing a list is still a criterion"
write_issue 59 '1. [ ] first
2. [ ] second continues the list
'
[ "$(run_tick 59 --index 2)" = 0 ] || fail "2. should tick inside a list"
issue_is 59 '1. [ ] first
2. [x] second continues the list
' || fail "an ordered item in list context should tick"

echo "==> a nine-digit ordered marker is still a criterion"
write_issue 53 '123456789. [ ] a real ordered criterion
'
[ "$(run_tick 53 --index 1)" = 0 ] || fail "nine digits is within the GFM limit"
issue_is 53 '123456789. [x] a real ordered criterion
' || fail "a nine-digit ordered item should tick"

echo "==> a thematic break is a leaf block, so an ordered list may start above 1 after it"
write_issue 55 'Some prose before the rule.
***
2. [ ] ordered criterion after a thematic break
'
[ "$(run_tick 55 --index 1)" = 0 ] || fail "a break closes the paragraph, so 2. starts a list"
issue_is 55 'Some prose before the rule.
***
2. [x] ordered criterion after a thematic break
' || fail "the criterion after a thematic break should tick"

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

echo "==> list-item fences and raw <pre> bodies are refused"
refused_body 48 '- ```text
  - [ ] indented example
```
- [ ] example in the new outer fence
```

- [ ] the real criterion
'
refused_body 49 '<pre>
sample text </prevent> more
- [ ] example inside pre
</pre>

- [ ] the real criterion
'
refused_body 45 '- ```text
  - [ ] example inside a list-item fence
  ```

- [ ] the real criterion
'
refused_body 44 '<pre>
- [ ] example rendered verbatim
</pre>

- [ ] the real criterion
'

echo "==> a list marker on a later line does not close a fence"
# Inside a column-0 fence every line is opaque, marker-bearing or not.
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

echo "==> HTML comments are refused wherever they sit — the round-13 attack included"
# The r13 reproduction: a raw tag hidden inside a comment once made the
# emulation suppress every later rendered criterion. Under the profile the
# comment itself is the refusal, so the criterion can never silently vanish.
refused_body 41 '<!-- <pre> -->
- [ ] the real criterion
'
refused_body 42 '<!--
- [ ] example from the issue template
-->

- [ ] the real criterion
'
refused_body 40 '<!-- guidance --> text

- [ ] the real criterion
'

echo "==> task text GFM does not render is refused, never silently skipped"
# `- [ ]example` has no delimiter after the box, so GitHub renders it as
# prose. Skipping it would shift --index onto the wrong criterion; refusing
# keeps every selector honest.
refused_body 39 '- [ ]example prose, not a checkbox

- [ ] the real criterion
'

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

echo "==> blockquoted fences are refused at any depth"
refused_body 38 '> ```
> > ```
> > - [ ] example nested deeper
> > ```
> ```

- [ ] the real criterion
'
refused_body 33 '> ```
> - [ ] quoted example
> ```

- [ ] the real criterion
'

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

echo "==> indented task syntax is refused — code block, nesting depth, and lazy continuation alike"
# GitHub renders `    - [ ] x` as code under prose, as a nested item under a
# two-column parent, and as a continuation elsewhere; the profile refuses all
# of them instead of deciding, because a wrong decision ticks the wrong line.
refused_body 63 'Example:

    - [ ] example inside an indented code block

- [ ] the real criterion
'
refused_body 65 '- outer item

      - [ ] example indented into code inside the item

- [ ] the real criterion
'
refused_body 66 'Example:

    - [ ] first example line

    - [ ] second example line

- [ ] the real criterion
'
refused_body 67 '> Example:
>
>     - [ ] example inside a quoted indented code block

- [ ] the real criterion
'
refused_body 75 'Some prose
    - [ ] indented under a paragraph, which GitHub renders as prose

- [ ] the real criterion
'

echo "==> a checkbox nested exactly two spaces under a bullet parent is still a criterion"
write_issue 64 '- outer item
  - [ ] nested criterion
'
[ "$(run_tick 64 --index 1)" = 0 ] || fail "a canonical nested criterion should stay tickable"
issue_is 64 '- outer item
  - [x] nested criterion
' || fail "two spaces under a bullet item is canonical nesting"

echo "==> a wrapped criterion is still a criterion, and its continuation is not"
write_issue 74 '- [ ] a criterion too long for one line, wrapping onto
      a continuation indented four columns past the marker
- [ ] the second criterion
'
[ "$(run_tick 74 --index 2)" = 0 ] || fail "--index 2 should address the second criterion"
issue_is 74 '- [ ] a criterion too long for one line, wrapping onto
      a continuation indented four columns past the marker
- [x] the second criterion
' || fail "a wrapped continuation must not shift the index"

echo "==> quoted fences and raw HTML blocks are refused — div, table, details alike"
refused_body 73 '> ```text
>
> - [ ] example inside the quoted fence
> ```

- [ ] the real criterion
'
refused_body 68 '<div>
- [ ] example inside an html block
</div>

- [ ] the real criterion
'
refused_body 69 '<table>
<tr><td>
- [ ] example inside a table cell
</td></tr>
</table>

- [ ] the real criterion
'
refused_body 70 '<details>
<summary>Acceptance criteria</summary>

- [ ] the real criterion

</details>
'

echo "==> raw HTML in any position, bare markers, and hyphen-only lines are refused"
refused_body 76 '- <div>
  - [ ] example rendered as raw html
</div>

- [ ] the real criterion
'
refused_body 77 'Some prose
    <div>
- [ ] the real criterion
'
refused_body 78 '-     <div>
      - [ ] example indented into code

- [ ] the real criterion
'
refused_body 79 '-
    - [ ] child of an empty parent marker
'
refused_body 80 '- - -

    - [ ] example in an indented code block

- [ ] the real criterion
'

echo "==> quoted raw HTML, lazy nesting, and quoted list structure are all refused"
refused_body 81 '> <div>
> > - [ ] example inside the quoted html block

- [ ] the real criterion
'
refused_body 82 '- <div>
  raw content
- [ ] the real criterion
'
refused_body 83 '<div>
- item inside raw html

    - [ ] example in an indented code block
- [ ] the real criterion
'
refused_body 84 '- outer paragraph
continuation without indent

    - [ ] nested task item
'
refused_body 85 '- outer
  > - quoted

    - [ ] live criterion
'
refused_body 86 '- > <div>
  - [ ] live criterion in the outer item
'
refused_body 87 '> - item
- [ ] outside the quote
'
refused_body 88 '- outer
    > - [ ] quoted criterion nested under the item
'

echo "==> indented fences, deep indentation, and quoted structure keep refusing"
refused_body 89 '- item

```text
x
```

    - [ ] sample in an indented code block

- [ ] the real criterion
'
refused_body 90 '- item

  ```text
  x
  ```

  - [ ] nested criterion after a fence inside the item
'
refused_body 91 '1234567890. text

            - [ ] sample

- [ ] the real criterion
'
refused_body 92 '# Heading
2. parent
    - [ ] child
'
refused_body 93 'Some prose
2. not a list, the paragraph continues
    - [ ] still prose

- [ ] the real criterion
'
refused_body 94 'Example:

    > - [ ] example inside an indented code block

- [ ] the real criterion
'
refused_body 95 '- item
    > - [ ] quoted at two columns past the item content
'

echo "==> raw HTML, comments, tabs, and item-scoped leaf blocks are refused"
refused_body 96 'Some prose
- <div>
  raw content
2. [ ] real criterion
'
refused_body 97 "$(printf -- '-\t\t[ ] example indented into code by tabs\n\n- [ ] the real criterion\n')"
refused_body 98 "$(printf -- '-\t[ ] one tab instead of the canonical space\n')"
refused_body 99 '- # heading
following unindented prose

    - [ ] example

- [ ] the real criterion
'
refused_body 100 'Some prose <!--
hidden
-->
2. [ ] example

- [ ] the real criterion
'
refused_body 101 '<!--
- [ ] commented-out example
-->
2. [ ] real ordered criterion
'
refused_body 102 'Some prose <pre>
- [ ] inline pre content
</pre>
2. [ ] example

- [ ] the real criterion
'
refused_body 103 'Some prose
- ```text
  content
  ```
unindented prose

    - [ ] example

- [ ] the real criterion
'
refused_body 104 'Some prose
- ```text
content
```
unindented prose

- [ ] not a criterion, this is inside a container-dependent fence
'

echo "==> an autolink is not an HTML block opener"
write_issue 71 '<https://example.com/spec>
- [ ] the real criterion
'
[ "$(run_tick 71 --index 1)" = 0 ] || fail "an autolink must not hide what follows it"
issue_is 71 '<https://example.com/spec>
- [x] the real criterion
' || fail "<https://…> is an autolink, not <hr>"

echo "==> a type-6 tag inside a fence does not hide the criteria after it"
write_issue 72 '```html
<div>
```

- [ ] the real criterion
'
[ "$(run_tick 72 --index 1)" = 0 ] || fail "a fenced tag should not open an HTML block"
issue_is 72 '```html
<div>
```

- [x] the real criterion
' || fail "HTML block state must not be tracked inside a fence"

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

# --- set-issue-status.sh -----------------------------------------------------
# Fully offline: a stubbed `gh` answers the two GraphQL reads and records the
# mutation, so the field/option resolution is tested without a live board.

echo "==> set-issue-status usage errors exit 2"
for args in "--repo evanharmon1/harmon-devkit" "--issue 5 --status Todo" \
    "--repo evanharmon1/harmon-devkit --issue 5" \
    "--repo not-a-slug --issue 5 --status Todo" \
    "--repo evanharmon1/harmon-devkit --issue abc --status Todo" \
    "--repo evanharmon1/harmon-devkit --issue 5 --status"; do
    _rc=0
    # shellcheck disable=SC2086 # deliberate word splitting: each case is an argv
    "$status_sh" $args >/dev/null 2>&1 || _rc=$?
    [ "$_rc" = 2 ] || fail "'$args' should exit 2 (got $_rc)"
done

# board_stub ITEMS_JSON — a `gh` that returns ITEMS_JSON for the projectItems
# query, a fixed field set for the fields query, and logs any mutation.
board_stub() {
    cat >"$stub/gh" <<STUB
#!/bin/sh
case "\$*" in
*projectItems*) echo '$1' ;;
*ProjectV2SingleSelectField*)
    echo '{"data":{"node":{"fields":{"nodes":[{"id":"F_status","name":"Status","options":[{"id":"O_prog","name":"In Progress"},{"id":"O_todo","name":"Todo"}]},{"id":"F_agent","name":"Agent","options":[{"id":"O_cc","name":"Claude Code"}]}]}}}}'
    ;;
*updateProjectV2ItemFieldValue*)
    echo "\$*" >>"$tmp/mutations.log"
    echo '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"I_1"}}}}'
    ;;
*) exit 1 ;;
esac
STUB
    chmod +x "$stub/gh"
    : >"$tmp/mutations.log"
}

# run_status ARGS… -> echoes the exit code.
run_status() {
    _rc=0
    env PATH="$stub:$PATH" "$status_sh" --repo "$repo" "$@" >/dev/null 2>&1 || _rc=$?
    echo "$_rc"
}

on_board='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"I_1","project":{"id":"P_1","title":"evanharmon1 Project"}}]}}}}}'

echo "==> --show reports the card's current values without writing"
cat >"$stub/gh" <<STUB
#!/bin/sh
case "\$*" in
*projectItems*) echo '$on_board' ;;
*fieldValues*)
    echo '{"data":{"node":{"fieldValues":{"nodes":[{},{"name":"Ready","field":{"name":"Status"}},{"name":"Codex","field":{"name":"Agent"}}]}}}}'
    ;;
*) echo "\$*" >>"$tmp/mutations.log"; exit 1 ;;
esac
STUB
chmod +x "$stub/gh"
: >"$tmp/mutations.log"
show_out=$(env PATH="$stub:$PATH" "$status_sh" --repo "$repo" --issue 5 --show 2>/dev/null)
printf '%s\n' "$show_out" | grep -qx 'Status=Ready' || fail "--show must report the current Status (got: $show_out)"
printf '%s\n' "$show_out" | grep -qx 'Agent=Codex' || fail "--show must report the current Agent"
[ ! -s "$tmp/mutations.log" ] || fail "--show must not write"

echo "==> --show refuses to be combined with a write"
_rc=0
env PATH="$stub:$PATH" "$status_sh" --repo "$repo" --issue 5 --show --status Todo >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "--show with --status should exit 2 (got $_rc)"

echo "==> an issue on no board exits 3, not 1"
board_stub '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}'
[ "$(run_status --issue 5 --status "In Progress")" = 3 ] ||
    fail "no board is benign and must exit 3"

echo "==> a resolved field and option is written"
board_stub "$on_board"
[ "$(run_status --issue 5 --status "In Progress")" = 0 ] ||
    fail "a resolvable field should apply"
[ "$(grep -c 'F_status' "$tmp/mutations.log")" = 1 ] || fail "Status should be written once"
# The board_stub still exposes an Agent field, so this proves the script leaves
# the retired field alone even when a legacy board still carries it.
if grep -q 'F_agent' "$tmp/mutations.log"; then fail "the retired Agent field must never be written"; fi

echo "==> option names match case-insensitively (boards differ on 'In progress')"
board_stub "$on_board"
[ "$(run_status --issue 5 --status "in progress")" = 0 ] ||
    fail "option matching must be case-insensitive"

echo "==> an option the board lacks is skipped, not invented"
board_stub "$on_board"
[ "$(run_status --issue 5 --status "Ready to Merge")" = 3 ] ||
    fail "a missing option should exit 3"
[ ! -s "$tmp/mutations.log" ] || fail "a missing option must write nothing"

echo "==> --agent is retired: the removed flag is now an unknown-arg usage error (exit 2)"
board_stub "$on_board"
[ "$(run_status --issue 5 --status "Todo" --agent "Claude Code")" = 2 ] ||
    fail "the removed --agent flag must be rejected as a usage error"
[ ! -s "$tmp/mutations.log" ] || fail "a usage error must write nothing"

echo "==> a write that fails with nothing else applied is exit 1"
cat >"$stub/gh" <<STUB
#!/bin/sh
case "\$*" in
*projectItems*) echo '$on_board' ;;
*ProjectV2SingleSelectField*)
    echo '{"data":{"node":{"fields":{"nodes":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}}}}'
    ;;
*F_status*) exit 1 ;;
*) exit 1 ;;
esac
STUB
chmod +x "$stub/gh"
[ "$(run_status --issue 5 --status "Todo")" = 1 ] ||
    fail "a sole failed write should exit 1"

echo "==> --dry-run resolves without mutating"
board_stub "$on_board"
[ "$(run_status --issue 5 --status "In Progress" --dry-run)" = 0 ] ||
    fail "--dry-run should resolve cleanly"
[ ! -s "$tmp/mutations.log" ] || fail "--dry-run must not write"

echo "==> two boards without --project is ambiguous, not a guess"
board_stub '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"I_1","project":{"id":"P_1","title":"Board A"}},{"id":"I_2","project":{"id":"P_2","title":"Board B"}}]}}}}}'
[ "$(run_status --issue 5 --status "Todo")" = 2 ] ||
    fail "an ambiguous board must not be guessed"

echo "==> the owner's default board wins when the issue is on several"
board_stub '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"I_1","project":{"id":"P_1","title":"Board A"}},{"id":"I_2","project":{"id":"P_2","title":"evanharmon1 Project"}}]}}}}}'
[ "$(run_status --issue 5 --status "Todo")" = 0 ] ||
    fail "the '<owner> Project' board should be preferred"
grep -q 'P_2' "$tmp/mutations.log" || fail "the default board's item should be the one written"

echo "==> an unreadable projectItems query is exit 2, never a silent pass"
cat >"$stub/gh" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$stub/gh"
[ "$(run_status --issue 5 --status "Todo")" = 2 ] ||
    fail "a failed read could not verify and must exit 2"

# --- claim-record contract ---------------------------------------------------

echo "==> claim-record producer and consumers document operational metadata"
claim_skill="./ai/skills/universal/claim/SKILL.md"
claim_lifecycle="./ai/skills/universal/track-work/references/claim-lifecycle.md"
wrap_skill="./ai/skills/universal/wrap/SKILL.md"
for field in harness model family 'runtime environment' session; do
    grep -Fq -- "  - $field:" "$claim_skill" ||
        fail "/claim must write the $field field"
    grep -Fq -- "  - $field:" "$claim_lifecycle" ||
        fail "claim-lifecycle.md must document the $field field"
done
grep -Fq 'optional `harness`, `model`, `family`, `runtime' "$wrap_skill" ||
    fail "/wrap must accept the optional operational fields"

echo "==> claim lifecycle consumers preserve chain-owned cleanup targets"
retro_skill="./ai/skills/universal/retro/SKILL.md"
grep -Fq 'deduplicated assignee-login set' "$claim_lifecycle" ||
    fail "claim lifecycle must preserve the full proven assignee ownership set"
grep -Fq -- '--remove-label <the chain-owned label' "$wrap_skill" ||
    fail "/wrap manual hand-back must remove the chain-owned label"
grep -Fq 'Discovery trust is deliberately read-only' "$retro_skill" ||
    fail "/retro must keep stale-claim discovery separate from cleanup trust"

# --- release-claim.sh --------------------------------------------------------
# Fully offline: a stubbed `gh` serves comment/issue JSON from scenario files
# and logs every write, so the claim parsing, trust gate, and provenance
# honouring are tested without touching a live issue.

release_sh="./ai/skills/universal/track-work/assets/release-claim.sh"
rc_bin="$tmp/rcbin"
mkdir -p "$rc_bin"
rc_comments="$tmp/rc-comments.json"
rc_issue="$tmp/rc-issue.json"
rc_log="$tmp/rc-writes.log"
rc_body="$tmp/rc-body.txt"
cat >"$rc_bin/gh" <<'STUB'
#!/bin/sh
# Scenario knobs via env: RC_COMMENTS_FILE (comment pages JSON), RC_ISSUE_FILE
# (issue JSON), RC_FAIL_MATCH (substring that forces a failure), RC_LOG,
# RC_BODY_OUT (where a posted comment body lands).
if [ -n "${RC_FAIL_MATCH:-}" ]; then
    case "$*" in
    *"$RC_FAIL_MATCH"*)
        echo "stub: forced failure for: $*" >&2
        exit 1
        ;;
    esac
fi
case "$*" in
*--slurp*comments*)
    # Two-phase mode: with RC_COMMENTS_FILE2 set, the first fetch serves
    # RC_COMMENTS_FILE and every later fetch serves RC_COMMENTS_FILE2 —
    # simulating ground that shifts between read and the pre-write re-read.
    if [ -n "${RC_COMMENTS_FILE2:-}" ] && [ -e "${RC_STATE:-/nonexistent}" ]; then
        cat "$RC_COMMENTS_FILE2"
    else
        if [ -n "${RC_STATE:-}" ]; then : >"$RC_STATE"; fi
        cat "$RC_COMMENTS_FILE"
    fi
    ;;
*"issue edit"*) echo "$*" >>"$RC_LOG" ;;
*"issue comment"*)
    echo "$*" >>"$RC_LOG"
    cat >"$RC_BODY_OUT"
    ;;
*"api repos/"*)
    # Same two-phase trick for the issue itself (state flips mid-run).
    if [ -n "${RC_ISSUE_FILE2:-}" ] && [ -e "${RC_STATE:-/nonexistent}" ]; then
        cat "$RC_ISSUE_FILE2"
    else
        cat "$RC_ISSUE_FILE"
    fi
    ;;
*)
    echo "stub: unexpected gh $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$rc_bin/gh"

# rc_scenario COMMENTS_JSON ISSUE_JSON — reset the logs and lay the fixtures.
rc_state="$tmp/rc-state"
rc_scenario() {
    printf '%s' "$1" >"$rc_comments"
    printf '%s' "$2" >"$rc_issue"
    : >"$rc_log"
    : >"$rc_body"
    rm -f "$rc_state"
}

# run_release ARGS… -> echoes the exit code.
run_release() {
    _rc=0
    env PATH="$rc_bin:$PATH" GH_REPO="" \
        RC_COMMENTS_FILE="$rc_comments" RC_ISSUE_FILE="$rc_issue" \
        RC_COMMENTS_FILE2="${RC_COMMENTS_FILE2:-}" \
        RC_ISSUE_FILE2="${RC_ISSUE_FILE2:-}" RC_STATE="$rc_state" \
        RC_FAIL_MATCH="${RC_FAIL_MATCH:-}" RC_LOG="$rc_log" RC_BODY_OUT="$rc_body" \
        "$release_sh" --repo "$repo" --issue 5 "$@" >/dev/null 2>&1 || _rc=$?
    echo "$_rc"
}

# Comment-page JSON builders (the --slurp shape: an array of pages).
rc_page() { jq -n '[$ARGS.positional]' --jsonargs "$@"; }
# rc_comment LOGIN BODY [ID] [CREATED_AT] [ASSOCIATION] [UPDATED_AT]
rc_comment() {
    _c="${4:-2026-01-01T00:00:00Z}"
    jq -n --arg l "$1" --arg b "$2" --arg i "${3:-1}" \
        --arg c "$_c" --arg a "${5:-OWNER}" --arg u "${6:-$_c}" \
        '{id: ($i | tonumber), created_at: $c, updated_at: $u,
          author_association: $a, user: {login: $l}, body: $b}'
}

body_v1='Claiming — starting implementation on branch b (session s).

Claim record (for `/wrap` — undo only what this claim added):
- board: none
- prior board status: none
- assignee added by this claim: yes
- `agent:` label added by this claim: agent:claude-code
- `agent:` label displaced by this claim: none'

issue_closed_full='{"state":"closed","labels":[{"name":"bug"},{"name":"agent:claude-code"}],"assignees":[{"login":"evanharmon1"}]}'

echo "==> release-claim usage errors exit 2"
for args in "--repo $repo" "--repo $repo --issue 5" "--repo bad --issue 5 --reason r" \
    "--repo $repo --issue abc --reason r"; do
    _rc=0
    # shellcheck disable=SC2086 # deliberate word splitting: each case is an argv
    "$release_sh" $args >/dev/null 2>&1 || _rc=$?
    [ "$_rc" = 2 ] || fail "release-claim '$args' should exit 2 (got $_rc)"
done

echo "==> a v1 record releases label, assignee, and posts the supersede comment"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")")" "$issue_closed_full"
[ "$(run_release --reason 'issue closed (completed)')" = 0 ] || fail "v1 full release should exit 0"
grep -q -- '--remove-label agent:claude-code' "$rc_log" || fail "v1 release must remove the recorded label"
grep -q -- '--remove-assignee evanharmon1' "$rc_log" || fail "v1 release must remove the claim author's assignment"
grep -q 'issue comment' "$rc_log" || fail "the supersede comment must be posted"

echo "==> the supersede comment's first line is the exact contract literal"
head -1 "$rc_body" | grep -Fxq 'Claim released — issue closed (completed). (Supersedes the claim record above.)' ||
    fail "release comment first line must match the contract (got: $(head -1 "$rc_body"))"

echo "==> a legacy 'yes' record removes the live agent:* labels"
body_legacy="$(printf '%s' "$body_v1" | sed 's/agent:claude-code$/yes/')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_legacy")")" \
    '{"state":"closed","labels":[{"name":"agent:claude-code"},{"name":"agent:codex"}],"assignees":[{"login":"evanharmon1"}]}'
[ "$(run_release --reason r)" = 0 ] || fail "legacy release should exit 0"
grep -q -- '--remove-label agent:claude-code' "$rc_log" || fail "legacy release must remove live agent labels"
grep -q -- '--remove-label agent:codex' "$rc_log" || fail "legacy release must remove every live agent label"

# --- claim:* vocabulary (the model-centric family replacing agent:*) ----------
# The rolling transition (harmon-init#620) migrates the live-claim label from
# `agent:*` to `claim:<family>[:<model>]`. release-claim.sh must recognize the
# new family exactly as it does the legacy one: a record naming a `claim:*`
# label at family level and with an optional model segment, and the `yes`
# fallback sweeping live `claim:*` labels alongside any legacy `agent:*` ones.
# body_v2 rewrites body_v1's field prefix and value to the new family.
body_v2="$(printf '%s' "$body_v1" | sed 's/`agent:` label/`claim:` label/g; s/agent:claude-code/claim:claude/')"
body_extended="$(printf '%s' "$body_v2" | awk '
    { print }
    /Claim record/ {
        print "- harness: Claude Code"
        print "- model: claude-opus-4-1"
        print "- family: claude"
        print "- runtime environment: devcontainer"
        print "- session: claim-record-fields-450"
    }
')"
body_extended_gpt="$(printf '%s' "$body_v2" | sed 's/claim:claude/claim:gpt/g' | awk '
    { print }
    /Claim record/ {
        print "- harness: Codex CLI"
        print "- model: gpt-5"
        print "- family: gpt"
        print "- runtime environment: host"
        print "- session: claim-runtime-identity-549"
    }
')"
body_extended_unknown="$(printf '%s' "$body_v2" | awk '
    { print }
    /Claim record/ {
        print "- family: claude"
        print "- runtime environment: unknown"
    }
')"
issue_closed_claim='{"state":"closed","labels":[{"name":"bug"},{"name":"claim:claude"}],"assignees":[{"login":"evanharmon1"}]}'

echo "==> a legacy claim:* record without operational metadata still releases"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v2")")" "$issue_closed_claim"
[ "$(run_release --reason 'issue closed (completed)')" = 0 ] || fail "a claim:* record release should exit 0"
grep -q -- '--remove-label claim:claude' "$rc_log" || fail "a claim:* record must remove the named claim: label"
grep -q -- '--remove-assignee evanharmon1' "$rc_log" || fail "a claim:* record must still remove the assignment"
cp "$rc_log" "$tmp/legacy-release-log"

echo "==> an extended claim record ignores operational metadata and releases"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_extended")")" "$issue_closed_claim"
[ "$(run_release --reason 'issue closed (completed)')" = 0 ] ||
    fail "an extended claim record release should exit 0"
grep -q -- '--remove-label claim:claude' "$rc_log" ||
    fail "operational metadata must not change the recorded label removal"
grep -q -- '--remove-assignee evanharmon1' "$rc_log" ||
    fail "operational metadata must not change the recorded assignee removal"
cmp -s "$tmp/legacy-release-log" "$rc_log" ||
    fail "Claude family and container metadata must leave cleanup exactly equivalent to a legacy record"

echo "==> GPT family and host metadata are ignored by cleanup"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_extended_gpt")")" \
    '{"state":"closed","labels":[{"name":"bug"},{"name":"claim:gpt"}],"assignees":[{"login":"evanharmon1"}]}'
[ "$(run_release --reason 'issue closed (completed)')" = 0 ] ||
    fail "a GPT extended claim record release should exit 0"
grep -q -- '--remove-label claim:gpt' "$rc_log" ||
    fail "family metadata must not override the actual recorded claim label"
grep -q -- '--remove-assignee evanharmon1' "$rc_log" ||
    fail "host metadata must not change the recorded assignee removal"

echo "==> unknown runtime metadata remains optional and non-authoritative"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_extended_unknown")")" "$issue_closed_claim"
[ "$(run_release --reason 'issue closed (completed)')" = 0 ] ||
    fail "an unknown runtime record should release"
grep -q -- '--remove-label claim:claude' "$rc_log" ||
    fail "the unknown fallback must not suppress marker cleanup"

echo "==> a family+model claim label (claim:claude:opus) is released verbatim"
body_model="$(printf '%s' "$body_v2" | sed 's/claim:claude/claim:claude:opus/g')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_model")")" \
    '{"state":"closed","labels":[{"name":"claim:claude:opus"}],"assignees":[{"login":"evanharmon1"}]}'
[ "$(run_release --reason r)" = 0 ] || fail "a model-segmented claim label should release"
grep -q -- '--remove-label claim:claude:opus' "$rc_log" || fail "the optional :model segment must be preserved in the removal"

echo "==> a legacy 'yes' record sweeps live claim:* labels too, not only agent:*"
body_yes_claim="$(printf '%s' "$body_v2" | sed 's/claim:claude$/yes/')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_yes_claim")")" \
    '{"state":"closed","labels":[{"name":"claim:claude"},{"name":"agent:codex"}],"assignees":[{"login":"evanharmon1"}]}'
[ "$(run_release --reason r)" = 0 ] || fail "a 'yes' record over claim:* labels should exit 0"
grep -q -- '--remove-label claim:claude' "$rc_log" || fail "the 'yes' fallback must sweep live claim:* labels"
grep -q -- '--remove-label agent:codex' "$rc_log" || fail "the 'yes' fallback must sweep legacy agent:* labels in the same pass"

echo "==> 'assignee added: no' leaves the assignee in place"
body_noassign="$(printf '%s' "$body_v1" | sed 's/^- assignee added by this claim: yes/- assignee added by this claim: no/')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_noassign")")" "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "no-assignee release should exit 0"
if grep -q -- '--remove-assignee' "$rc_log"; then fail "an assignee the claim did not add must stay"; fi

# A v2 leaf carries ownership across a refresh or crash-recovery takeover. Its
# direct fields deliberately say it added nothing: releasing it must use the
# claim-chain fields rather than strand the predecessor's markers (#533/#537).
body_chain_takeover="$(printf '%s' "$body_noassign" | sed 's/agent:claude-code$/no/')
- assignee owned by this claim chain: yes
- assignee login owned by this claim chain: evanharmon1
- agent: label owned by this claim chain: agent:claude-code
- agent: label displaced by this claim chain: none"
echo "==> a refreshed current record releases inherited predecessor ownership"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)" \
    "$(rc_comment evanharmon1 "$body_chain_takeover" 2)")" "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "a chain-owned refreshed claim should release"
grep -q -- '--remove-label agent:claude-code' "$rc_log" ||
    fail "the current chain record must remove the inherited label"
grep -q -- '--remove-assignee evanharmon1' "$rc_log" ||
    fail "the current chain record must remove the inherited assignee"

echo "==> a cross-account takeover releases the inherited assignee by recorded login"
body_chain_cross_account="$(printf '%s' "$body_chain_takeover" |
    sed 's/assignee login owned by this claim chain: evanharmon1/assignee login owned by this claim chain: collaborator/')"
rc_scenario "$(rc_page "$(rc_comment collaborator "$body_v1" 1)" \
    "$(rc_comment evanharmon1 "$body_chain_cross_account" 2)")" \
    '{"state":"closed","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"collaborator"}]}'
[ "$(run_release --reason r)" = 0 ] || fail "a cross-account chain claim should release"
grep -q -- '--remove-assignee collaborator' "$rc_log" ||
    fail "the recorded inherited assignee must be removed"
if grep -q -- '--remove-assignee evanharmon1' "$rc_log"; then
    fail "the replacement author must not replace the inherited assignee target"
fi

echo "==> a cross-account takeover releases both directly and inherited owned assignees"
body_chain_cross_both="$(printf '%s' "$body_v1" | sed 's/agent:claude-code$/no/')
- assignee owned by this claim chain: yes
- assignee login owned by this claim chain: collaborator
- agent: label owned by this claim chain: agent:claude-code
- agent: label displaced by this claim chain: none"
rc_scenario "$(rc_page "$(rc_comment collaborator "$body_v1" 1)" "$(rc_comment evanharmon1 "$body_chain_cross_both" 2)")" '{"state":"closed","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"collaborator"},{"login":"evanharmon1"},{"login":"unrelated"}]}'
[ "$(run_release --reason r)" = 0 ] || fail "both owned assignees should release"
grep -q -- '--remove-assignee collaborator' "$rc_log" || fail "inherited assignee must be removed"
grep -q -- '--remove-assignee evanharmon1' "$rc_log" || fail "direct assignee must be removed"
if grep -q -- '--remove-assignee unrelated' "$rc_log"; then fail "unrelated assignee must remain"; fi

echo "==> failed dual-assignee release restores both owned assignees"
rc_scenario "$(rc_page "$(rc_comment collaborator "$body_v1" 1)" "$(rc_comment evanharmon1 "$body_chain_cross_both" 2)")" '{"state":"closed","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"collaborator"},{"login":"evanharmon1"},{"login":"unrelated"}]}'
[ "$(RC_FAIL_MATCH='issue comment' run_release --reason r)" = 1 ] || fail "failed dual-assignee comment should exit 1"
grep -q -- '--add-assignee collaborator' "$rc_log" || fail "inherited assignee must be restored"
grep -q -- '--add-assignee evanharmon1' "$rc_log" || fail "direct assignee must be restored"
if grep -q -- '--add-assignee unrelated' "$rc_log"; then fail "unrelated assignee must not be restored"; fi

body_set_a="$body_v1
- assignee logins owned by this claim chain: alice
- agent: label owned by this claim chain: agent:claude-code
- agent: label displaced by this claim chain: none"
body_set_b="$(printf '%s' "$body_v1" | sed 's/agent:claude-code$/no/')
- assignee logins owned by this claim chain: alice,bob
- agent: label owned by this claim chain: agent:claude-code
- agent: label displaced by this claim chain: none"
body_set_c="$(printf '%s' "$body_v1" | sed 's/agent:claude-code$/no/')
- assignee logins owned by this claim chain: alice,bob,carol
- agent: label owned by this claim chain: agent:claude-code
- agent: label displaced by this claim chain: none"
abc_issue='{"state":"closed","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"alice"},{"login":"bob"},{"login":"carol"},{"login":"dave"}]}'

echo "==> A to B to C provenance releases every owned assignee and preserves unrelated D"
rc_scenario "$(rc_page "$(rc_comment alice "$body_set_a" 1 '' COLLABORATOR)" \
    "$(rc_comment bob "$body_set_b" 2 '' COLLABORATOR)" \
    "$(rc_comment carol "$body_set_c" 3 '' COLLABORATOR)")" "$abc_issue"
[ "$(run_release --reason r)" = 0 ] || fail "A+B+C set release should succeed"
for owned in alice bob carol; do
    grep -q -- "--remove-assignee $owned" "$rc_log" || fail "owned assignee $owned must be removed"
done
if grep -q -- '--remove-assignee dave' "$rc_log"; then fail "unrelated D must remain"; fi

echo "==> failed A+B+C supersede publication compensates every owned assignee only"
rc_scenario "$(rc_page "$(rc_comment alice "$body_set_a" 1 '' COLLABORATOR)" \
    "$(rc_comment bob "$body_set_b" 2 '' COLLABORATOR)" \
    "$(rc_comment carol "$body_set_c" 3 '' COLLABORATOR)")" "$abc_issue"
[ "$(RC_FAIL_MATCH='issue comment' run_release --reason r)" = 1 ] || fail "failed A+B+C comment should exit 1"
for owned in alice bob carol; do
    grep -q -- "--add-assignee $owned" "$rc_log" || fail "owned assignee $owned must be restored"
done
if grep -q -- '--add-assignee dave' "$rc_log"; then fail "unrelated D must never be compensation state"; fi

echo "==> a forged inherited assignee target fails closed with zero writes"
body_set_forged="$(printf '%s' "$body_set_c" | sed 's/alice,bob,carol$/alice,bob,carol,dave/')"
rc_scenario "$(rc_page "$(rc_comment alice "$body_set_a" 1 '' COLLABORATOR)" \
    "$(rc_comment bob "$body_set_b" 2 '' COLLABORATOR)" \
    "$(rc_comment carol "$body_set_forged" 3 '' COLLABORATOR)")" "$abc_issue"
[ "$(run_release --reason r)" = 2 ] || fail "forged inherited victim must fail closed"
[ ! -s "$rc_log" ] || fail "forged inherited victim must trigger zero writes"

echo "==> a failed refresh publish leaves the predecessor as the recoverable current record"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)")" "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] ||
    fail "without a published replacement, the predecessor must remain releasable"
grep -q -- '--remove-label agent:claude-code' "$rc_log" ||
    fail "a failed refresh must not lose the predecessor's label ownership"

echo "==> independently owned later markers stay protected by an unowned current chain"
body_chain_unowned="$(printf '%s' "$body_noassign" | sed 's/agent:claude-code$/no/')
- assignee owned by this claim chain: no
- assignee login owned by this claim chain: none
- agent: label owned by this claim chain: no
- agent: label displaced by this claim chain: none"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)" \
    "$(rc_comment evanharmon1 "$body_chain_unowned" 2)")" "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "an unowned current chain should still release its comment"
if grep -q -- '--remove-label\|--remove-assignee' "$rc_log"; then
    fail "markers no longer proven claim-owned must remain protected"
fi

echo "==> a partially written v2 ownership trio fails closed"
body_chain_partial="$(printf '%s' "$body_noassign" | sed 's/agent:claude-code$/no/')
- assignee owned by this claim chain: yes"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_chain_partial")")" "$issue_closed_full"
[ "$(run_release --reason r)" = 2 ] || fail "a partial chain-ownership record must fail closed"
[ ! -s "$rc_log" ] || fail "a partial chain-ownership record must trigger zero writes"

echo "==> a lone v2 assignee-login field fails closed"
body_chain_login_only="$(printf '%s' "$body_noassign" | sed 's/agent:claude-code$/no/')
- assignee login owned by this claim chain: collaborator"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_chain_login_only")")" "$issue_closed_full"
[ "$(run_release --reason r)" = 2 ] || fail "a lone chain-login field must fail closed"
[ ! -s "$rc_log" ] || fail "a lone chain-login field must trigger zero writes"

echo "==> 'label added: n/a' touches no label"
body_nolabel="$(printf '%s' "$body_v1" | sed 's/^- `agent:` label added by this claim: agent:claude-code/- `agent:` label added by this claim: n\/a, repo has no such label/')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_nolabel")")" "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "n/a-label release should exit 0"
if grep -q -- '--remove-label' "$rc_log"; then fail "n/a label must remove nothing"; fi

echo "==> an already-superseded claim is exit 3 with zero writes"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")" \
    "$(rc_comment evanharmon1 'Claim released — merged. (Supersedes the claim record above.)')")" \
    "$issue_closed_full"
[ "$(run_release --reason r)" = 3 ] || fail "superseded claim should exit 3"
[ ! -s "$rc_log" ] || fail "superseded claim must write nothing"

echo "==> no claim comment at all is exit 3"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 'just a normal comment')")" "$issue_closed_full"
[ "$(run_release --reason r)" = 3 ] || fail "no claim should exit 3"

echo "==> claim -> release -> re-claim acts on the latest claim's record only"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")" \
    "$(rc_comment evanharmon1 'Claim released — done. (Supersedes the claim record above.)')" \
    "$(rc_comment evanharmon1 "$body_noassign")")" \
    "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "re-claimed release should exit 0"
if grep -q -- '--remove-assignee' "$rc_log"; then
    fail "the second claim's record (assignee: no) must win over the first's"
fi

echo "==> a displaced label is restored while the issue is open"
body_displaced="$(printf '%s' "$body_v1" | sed 's/^- `agent:` label displaced by this claim: none/- `agent:` label displaced by this claim: agent:codex/')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_displaced")")" \
    '{"state":"open","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"evanharmon1"}]}'
[ "$(run_release --reason 'PR #9 closed without merging')" = 0 ] || fail "open-issue release should exit 0"
grep -q -- '--add-label agent:codex' "$rc_log" || fail "the displaced label must be restored on an open issue"

echo "==> a displaced label is NOT restored onto a closed issue"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_displaced")")" "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "closed-issue release should exit 0"
if grep -q -- '--add-label' "$rc_log"; then fail "restoring a label onto a closed issue recreates the stale state"; fi
grep -q 'skipped restoring' "$rc_body" || fail "the skip must be recorded in the release comment"

echo "==> a claim authored by neither the owner nor an assignee is ignored"
rc_scenario "$(rc_page "$(rc_comment mallory "$body_v1")")" \
    '{"state":"closed","labels":[],"assignees":[{"login":"evanharmon1"}]}'
[ "$(run_release --reason r)" = 3 ] || fail "an untrusted claim should exit 3"
[ ! -s "$rc_log" ] || fail "an untrusted claim must trigger zero writes"

echo "==> a claim authored by a non-owner assignee IS trusted"
rc_scenario "$(rc_page "$(rc_comment collaborator "$body_v1")")" \
    '{"state":"closed","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"collaborator"}]}'
[ "$(run_release --reason r)" = 0 ] || fail "an assignee's claim should be honoured"
grep -q -- '--remove-assignee collaborator' "$rc_log" || fail "the claim author, not the runner, is unassigned"

echo "==> hostile record values fail closed with zero writes"
body_hostile="$(printf '%s' "$body_v1" | sed 's/^- `agent:` label added by this claim: agent:claude-code/- `agent:` label added by this claim: agent:x;rm -rf ~/')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_hostile")")" "$issue_closed_full"
[ "$(run_release --reason r)" = 2 ] || fail "an implausible label should fail closed with exit 2"
[ ! -s "$rc_log" ] || fail "a hostile record must trigger zero writes"

echo "==> a record with no parsable assignee line fails closed"
body_broken="$(printf '%s' "$body_v1" | sed 's/^- assignee added by this claim: yes/- assignee added by this claim: maybe/')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_broken")")" "$issue_closed_full"
[ "$(run_release --reason r)" = 2 ] || fail "an unreadable record should exit 2"
[ ! -s "$rc_log" ] || fail "an unreadable record must trigger zero writes"

echo "==> a claim with no record at all releases by comment only"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 'Claiming — starting work (session old).')")" "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "a recordless claim should release by comment"
[ "$(grep -c 'issue comment' "$rc_log")" = 1 ] || fail "exactly the comment should be written"
if grep -q 'issue edit' "$rc_log"; then fail "no record means no marker may be touched"; fi
grep -q 'no claim record survived' "$rc_body" || fail "the comment must say the markers were left"

echo "==> a failed marker write withholds the comment AND the assignee removal"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")")" "$issue_closed_full"
_rc4="$(RC_FAIL_MATCH='--remove-label' run_release --reason r)"
[ "$_rc4" = 4 ] || fail "a failed label removal should exit 4 (got $_rc4)"
if grep -q -- '--remove-assignee' "$rc_log"; then
    fail "the assignee is the retry's trust anchor — it must be left when an earlier write failed"
fi
if grep -q 'issue comment' "$rc_log"; then
    fail "a partial release must NOT post the supersede comment — a re-run would read it as settled"
fi

echo "==> a failed comment post is exit 1 and re-adds the assignee (trust anchor)"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")")" "$issue_closed_full"
_rc1="$(RC_FAIL_MATCH='issue comment' run_release --reason r)"
[ "$_rc1" = 1 ] || fail "a failed supersede post should exit 1 (got $_rc1)"
grep -q -- '--add-assignee evanharmon1' "$rc_log" ||
    fail "the compensation must re-add the removed assignee so the retry stays trusted"

echo "==> failed comment compensation restores the inherited assignee, not the takeover author"
rc_scenario "$(rc_page "$(rc_comment collaborator "$body_v1" 1)" \
    "$(rc_comment evanharmon1 "$body_chain_cross_account" 2)")" \
    '{"state":"closed","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"collaborator"}]}'
_rc_cross_comment="$(RC_FAIL_MATCH='issue comment' run_release --reason r)"
[ "$_rc_cross_comment" = 1 ] || fail "a failed cross-account supersede post should exit 1 (got $_rc_cross_comment)"
grep -q -- '--add-assignee collaborator' "$rc_log" ||
    fail "cross-account compensation must restore the inherited assignee"
if grep -q -- '--add-assignee evanharmon1' "$rc_log"; then
    fail "cross-account compensation must not add the takeover author"
fi

echo "==> a claim EDITED between read and write aborts with exit 3 (same id, new updated_at)"
comments_orig="$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)")"
printf '%s' "$(rc_page "$(rc_comment evanharmon1 "$body_noassign" 1 '2026-01-01T00:00:00Z' OWNER '2026-07-01T00:00:00Z')")" \
    >"$tmp/rc-comments-edited.json"
rc_scenario "$comments_orig" "$issue_closed_full"
_rce="$(RC_COMMENTS_FILE2="$tmp/rc-comments-edited.json" run_release --reason r)"
[ "$_rce" = 3 ] || fail "an edited claim body must not be acted on from the stale parse (got $_rce)"
[ ! -s "$rc_log" ] || fail "an edited claim must trigger zero writes"

echo "==> a claimant unassigned between read and write aborts with exit 3"
rc_scenario "$(rc_page "$(rc_comment collaborator "$body_v1" 1 '2026-01-01T00:00:00Z' COLLABORATOR)")" \
    '{"state":"closed","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"collaborator"}]}'
printf '%s' '{"state":"closed","labels":[{"name":"agent:claude-code"}],"assignees":[]}' \
    >"$tmp/rc-issue-unassigned.json"
_rcu="$(RC_ISSUE_FILE2="$tmp/rc-issue-unassigned.json" run_release --reason r)"
[ "$_rcu" = 3 ] || fail "a mid-run unassignment must drop trust before writing (got $_rcu)"
[ ! -s "$rc_log" ] || fail "a mid-run unassignment must trigger zero writes"

echo "==> an issue whose state flips between read and write aborts with exit 3"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")")" "$issue_closed_full"
printf '%s' '{"state":"open","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"evanharmon1"}]}' \
    >"$tmp/rc-issue-2.json"
_rcf="$(RC_ISSUE_FILE2="$tmp/rc-issue-2.json" run_release --reason r)"
[ "$_rcf" = 3 ] || fail "a state flip between read and write should exit 3 (got $_rcf)"
[ ! -s "$rc_log" ] || fail "a state flip must trigger zero writes"

echo "==> --dry-run resolves everything and writes nothing"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")")" "$issue_closed_full"
[ "$(run_release --reason r --dry-run)" = 0 ] || fail "--dry-run should exit 0"
[ ! -s "$rc_log" ] || fail "--dry-run must not write"

echo "==> a forged 'Claim released —' from an untrusted author does not suppress the release"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)" \
    "$(rc_comment mallory 'Claim released — lol. (Supersedes the claim record above.)' 2)")" \
    "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "an untrusted release comment must be invisible"
grep -q -- '--remove-label agent:claude-code' "$rc_log" || fail "the real claim must still be released"

echo "==> a forged newer 'Claiming —' from an untrusted author does not shadow the real claim"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)" \
    "$(rc_comment mallory 'Claiming — totally my issue now (session x).' 2)")" \
    "$issue_closed_full"
[ "$(run_release --reason r)" = 0 ] || fail "an untrusted claim comment must be invisible"
grep -q -- '--remove-assignee evanharmon1' "$rc_log" || fail "the trusted claim of record must be the one released"

echo "==> a claim newer than --not-after is left alone"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1 '2026-06-01T00:00:00Z')")" \
    "$issue_closed_full"
[ "$(run_release --reason r --not-after '2026-05-01T00:00:00Z')" = 3 ] ||
    fail "a claim postdating the event should exit 3"
[ ! -s "$rc_log" ] || fail "a post-event claim must trigger zero writes"

echo "==> a claim older than --not-after is released normally"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1 '2026-04-01T00:00:00Z')")" \
    "$issue_closed_full"
[ "$(run_release --reason r --not-after '2026-05-01T00:00:00Z')" = 0 ] ||
    fail "a pre-event claim should release under --not-after"

echo "==> a claim in the SAME second as --not-after fails safe (timestamps are second-precision)"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1 '2026-05-01T00:00:00Z')")" \
    "$issue_closed_full"
[ "$(run_release --reason r --not-after '2026-05-01T00:00:00Z')" = 3 ] ||
    fail "an equal-timestamp claim could postdate the event — it must be left"

echo "==> --require-closed refuses a stale close event on a reopened issue"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")")" \
    '{"state":"open","labels":[{"name":"agent:claude-code"}],"assignees":[{"login":"evanharmon1"}]}'
[ "$(run_release --reason r --require-closed)" = 3 ] ||
    fail "a reopened issue means the close event is stale — exit 3"
[ ! -s "$rc_log" ] || fail "a stale close event must trigger zero writes"

echo "==> an assignee WITHOUT write association is not trusted"
rc_scenario "$(rc_page "$(rc_comment outsider "$body_v1" 1 '2026-01-01T00:00:00Z' NONE)")" \
    '{"state":"closed","labels":[],"assignees":[{"login":"outsider"}]}'
[ "$(run_release --reason r)" = 3 ] || fail "assignment without write access must not be trusted"
[ ! -s "$rc_log" ] || fail "an unauthorized claim must trigger zero writes"

echo "==> --branch releases only the claim the closing PR owns"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")")" "$issue_closed_full"
[ "$(run_release --reason r --branch other-branch)" = 3 ] ||
    fail "a claim for a different branch is not this PR's to release"
[ ! -s "$rc_log" ] || fail "a branch mismatch must trigger zero writes"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1")")" "$issue_closed_full"
[ "$(run_release --reason r --branch b)" = 0 ] ||
    fail "the matching branch's claim should release"

echo "==> a record missing a field line fails closed"
body_truncated="$(printf '%s' "$body_v1" | grep -v 'label added by this claim')"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_truncated")")" "$issue_closed_full"
[ "$(run_release --reason r)" = 2 ] || fail "an incomplete record is unreadable provenance — exit 2"
[ ! -s "$rc_log" ] || fail "an incomplete record must trigger zero writes"

echo "==> the workflow's own bot-authored release comment supersedes on re-run"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)" \
    "$(rc_comment 'github-actions[bot]' 'Claim released — issue closed (completed). (Supersedes the claim record above.)' 2)")" \
    "$issue_closed_full"
_rcb="$(run_release --reason r)"
[ "$_rcb" = 3 ] || fail "a bot-authored release must be seen by the re-run (got $_rcb)"
[ ! -s "$rc_log" ] || fail "an already-released claim must trigger zero writes on re-run"

echo "==> a bot-authored 'Claiming —' comment is still not a trusted claim"
rc_scenario "$(rc_page "$(rc_comment 'github-actions[bot]' "$body_v1" 1)")" \
    '{"state":"closed","labels":[],"assignees":[]}'
[ "$(run_release --reason r)" = 3 ] || fail "bot trust is scoped to release comments only"
[ ! -s "$rc_log" ] || fail "a bot claim must trigger zero writes"

echo "==> a claim that changes between read and write aborts with exit 3"
comments_before="$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)")"
comments_after="$(rc_page "$(rc_comment evanharmon1 "$body_v1" 1)" \
    "$(rc_comment evanharmon1 "$body_v1" 9 '2026-07-01T00:00:00Z')")"
printf '%s' "$comments_after" >"$tmp/rc-comments-2.json"
rc_scenario "$comments_before" "$issue_closed_full"
_rcs="$(RC_COMMENTS_FILE2="$tmp/rc-comments-2.json" run_release --reason r)"
[ "$_rcs" = 3 ] || fail "a shifted claim of record should exit 3 (got $_rcs)"
[ ! -s "$rc_log" ] || fail "a shifted claim must trigger zero writes"

echo "✓ track-work checks behave"
