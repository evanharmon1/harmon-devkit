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

echo "==> a shell comment inside an indented fenced code block does not end the Verify section"
[ "$(run_rot 'scripts/foo.sh:42 is stale.

## Verify

   ```sh
   # check the thing
   grep -n x foo.sh
   ```
')" = 0 ] || fail "a shell comment inside an indented fence should not terminate the Verify section"

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
mkdir -p "$metadata_repo"
cp agent-registry.json "$metadata_repo/agent-registry.json"
jq '.families |= map(if .family == "area"
    then .values += [{"value":"fixture","description":"Fixture-only area"}]
    else . end)' label-registry.json >"$metadata_repo/label-registry.json"

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
        --inapplicable layer --label domain:platform --label ai-generated "$@"
}

run_organization() {
    _title="$1"
    _body="$2"
    shift 2
    run_metadata --repo testorg/testrepo --repo-root "$metadata_repo" \
        --owner-type organization --issue-type Task --title "$_title" \
        --body-file "$_body" --agent-authored --label area:fixture \
        --inapplicable layer --label domain:platform --label ai-generated "$@"
}

echo "==> metadata: a complete personal-account draft passes from the target root manifest"
[ "$(run_personal 'Validate issue metadata before creation' "$valid_body")" = 0 ] ||
    fail "valid personal draft should pass: $(cat "$tmp/metadata.out")"

echo "==> metadata: an organization draft uses native Issue Type and no work-type label"
[ "$(run_organization 'Validate organization issue metadata' "$valid_body")" = 0 ] ||
    fail "valid organization draft should pass: $(cat "$tmp/metadata.out")"

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

echo "==> metadata: the existing perishable-fact checker is the Verify gate"
[ "$(run_personal 'Cover perishable issue facts' "$perishable_body")" = 1 ] ||
    fail "perishable facts without Verify should fail"
[ "$(run_personal 'Cover perishable issue facts' "$verified_body")" = 0 ] ||
    fail "perishable facts with Verify should pass: $(cat "$tmp/metadata.out")"
sed 's/^## Verify$/### Verify/' "$verified_body" >"$tmp/metadata-wrong-verify-level.md"
[ "$(run_personal 'Require the canonical Verify heading' \
    "$tmp/metadata-wrong-verify-level.md")" = 1 ] ||
    fail "a perishable fact with only a noncanonical Verify heading should fail"

echo "==> metadata: labels must be known and exclusive families cannot conflict"
[ "$(run_personal 'Reject unknown labels' "$valid_body" --label unknown-label)" = 1 ] ||
    fail "unknown label should fail"
[ "$(run_personal 'Reject conflicting axes' "$valid_body" --label area:skills)" = 1 ] ||
    fail "two area labels should fail"

echo "==> metadata: agent-authored issues require ai-generated and agent-writable labels"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Require issue provenance' --body-file "$valid_body" \
    --agent-authored --label feature --label area:fixture --inapplicable layer \
    --label domain:platform)" = 1 ] || fail "missing ai-generated should fail"
[ "$(run_personal 'Respect label writers' "$valid_body" --label sec)" = 1 ] ||
    fail "an agent must not propose a human-only concern"
[ "$(run_metadata --repo testowner/testrepo --repo-root "$metadata_repo" \
    --owner-type personal --title 'Allow true concern labels' --body-file "$valid_body" \
    --label feature --label area:fixture --inapplicable layer \
    --label domain:platform --label sec)" = 0 ] ||
    fail "a human-authored draft may carry a true concern: $(cat "$tmp/metadata.out")"

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
    --label area:fixture --inapplicable layer --label domain:platform)" = 1 ] ||
    fail "personal repo without a work type should fail"
[ "$(run_personal 'Reject stacked work types' "$valid_body" --label task)" = 1 ] ||
    fail "personal repo with two work types should fail"
[ "$(run_organization 'Reject labels in place of Issue Type' "$valid_body" --label feature)" = 1 ] ||
    fail "organization repo with a work-type label should fail"
[ "$(run_metadata --repo testorg/testrepo --repo-root "$metadata_repo" \
    --owner-type organization --title 'Require native Issue Type' --body-file "$valid_body" \
    --label area:fixture --inapplicable layer --label domain:platform)" = 1 ] ||
    fail "organization repo without Issue Type should fail"

echo "==> metadata: authoring-time strategy, routing, claim, and Foreman labels are forbidden"
for label in rigor:deep tier:apex method:plan suggest:gpt claim:gpt foreman:approved agent:codex; do
    [ "$(run_personal 'Reject authoring-time control labels' "$valid_body" --label "$label")" = 1 ] ||
        fail "$label should be forbidden during authoring"
    grep -qF "$label" "$tmp/metadata.out" || fail "the rejection should name $label"
done

metadata_stub="$tmp/metadata-bin"
metadata_fallback="$tmp/metadata-fallback"
mkdir -p "$metadata_stub" "$metadata_fallback"
cat >"$metadata_stub/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${METADATA_GH_LOG:?}"
if [ "${1:-} ${2:-}" = "label list" ]; then
    printf '%s\n' feature area:fixture domain:platform ai-generated needs-triage
    exit 0
fi
exit 97
STUB
chmod +x "$metadata_stub/gh"

echo "==> metadata: an absent manifest falls back to one bounded label read"
: >"$tmp/metadata-gh.log"
_rc=0
PATH="$metadata_stub:$PATH" METADATA_GH_LOG="$tmp/metadata-gh.log" \
    "$metadata" --repo fallback/repo --repo-root "$metadata_fallback" \
    --owner-type personal --title 'Validate fallback metadata' \
    --body-file "$valid_body" --agent-authored --label feature \
    --label area:fixture --inapplicable layer --label domain:platform \
    --label ai-generated >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "fallback draft should pass: $(cat "$tmp/metadata.out")"
[ "$(wc -l <"$tmp/metadata-gh.log" | tr -d ' ')" = 1 ] || fail "fallback should make one gh read"
grep -q 'label list.*--repo fallback/repo.*--limit 1000.*--json name' "$tmp/metadata-gh.log" ||
    fail "fallback label read must be repo-bound and bounded"

echo "==> metadata: an invalid present manifest fails closed without a gh fallback"
printf '{not json\n' >"$metadata_fallback/label-registry.json"
: >"$tmp/metadata-gh.log"
_rc=0
PATH="$metadata_stub:$PATH" METADATA_GH_LOG="$tmp/metadata-gh.log" \
    "$metadata" --repo fallback/repo --repo-root "$metadata_fallback" \
    --owner-type personal --title 'Reject an invalid manifest' \
    --body-file "$valid_body" --label feature --inapplicable area \
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
    --body-file "$valid_body" --label feature --inapplicable area \
    --inapplicable layer --inapplicable domain >"$tmp/metadata.out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "structurally invalid manifest should exit 2 (got $_rc)"
[ ! -s "$tmp/metadata-gh.log" ] || fail "structural failure must not fall through to gh"

echo "==> metadata: help documents both owner-type examples and bad usage exits 2"
help="$($metadata --help 2>&1 || true)"
printf '%s\n' "$help" | grep -q 'Personal-account example' || fail "help needs a personal example"
printf '%s\n' "$help" | grep -q 'Organization example' || fail "help needs an organization example"
[ "$(run_metadata --repo testowner/testrepo --title x --body-file "$valid_body" \
    --owner-type personal --label feature)" = 2 ] || fail "missing repo-root should exit 2"

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

echo "==> a sibling list-item fence both ends the previous one and opens its own"
write_issue 61 '- ```text
  content
- ```text
  - [ ] example inside the sibling fence
  ```

- [ ] the real criterion
'
[ "$(run_tick 61 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 61 '- ```text
  content
- ```text
  - [ ] example inside the sibling fence
  ```

- [x] the real criterion
' || fail "the boundary line must be reconsidered as an opener"

echo "==> a marker that cannot interrupt a paragraph keeps paragraph state"
write_issue 62 'Some ordinary paragraph text.
2. prose that cannot interrupt
3. [ ] example prose

- [ ] the real criterion
'
[ "$(run_tick 62 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 62 'Some ordinary paragraph text.
2. prose that cannot interrupt
3. [ ] example prose

- [x] the real criterion
' || fail "an ordered-looking line must not fabricate list context"

echo "==> a tabbed list prefix is measured in rendered columns"
printf -- '-\t```text\n\t- [ ] first example\n  ```\n- [ ] example in the outer fence\n  ```\n\n- [ ] the real criterion\n' >"$ticks/${repo//\//_}__63.md"
[ "$(run_tick 63 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
[ "$(cat "$ticks/${repo//\//_}__63.md" | tail -1)" = '- [x] the real criterion' ] || fail "a tab must advance to the next four-column stop"

echo "==> task text in script, style and textarea blocks is not a criterion"
for raw in script style textarea; do
    printf '<%s>\n- [ ] example in raw html\n</%s>\n\n- [ ] the real criterion\n' "$raw" "$raw" >"$ticks/${repo//\//_}__64.md"
    [ "$(run_tick 64 --index 1)" = 0 ] || fail "--index 1 should address the real criterion (<$raw>)"
    [ "$(cat "$ticks/${repo//\//_}__64.md" | tail -1)" = '- [x] the real criterion' ] || fail "a checkbox inside <$raw> must be left alone"
done

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

echo "==> a checkbox in a four-space indented code block is not a criterion"
write_issue 63 'Example:

    - [ ] example inside an indented code block

- [ ] the real criterion
'
[ "$(run_tick 63 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 63 'Example:

    - [ ] example inside an indented code block

- [x] the real criterion
' || fail "an indented code block must hide its checkbox"

echo "==> a checkbox nested under a list item is still a criterion"
write_issue 64 '- outer item
    - [ ] nested criterion
'
[ "$(run_tick 64 --index 1)" = 0 ] || fail "a nested criterion should stay tickable"
issue_is 64 '- outer item
    - [x] nested criterion
' || fail "four spaces under a list item is nesting, not code"

echo "==> an indented code block is measured from its list container, not column 0"
write_issue 65 '- outer item

      - [ ] example indented into code inside the item

- [ ] the real criterion
'
[ "$(run_tick 65 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 65 '- outer item

      - [ ] example indented into code inside the item

- [x] the real criterion
' || fail "six columns inside a two-column item is a code block"

echo "==> a blank line does not end an indented code block"
write_issue 66 'Example:

    - [ ] first example line

    - [ ] second example line

- [ ] the real criterion
'
[ "$(run_tick 66 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 66 'Example:

    - [ ] first example line

    - [ ] second example line

- [x] the real criterion
' || fail "an interior blank line must not reopen the block"

echo "==> a quoted indented code block hides its checkbox too"
write_issue 67 '> Example:
>
>     - [ ] example inside a quoted indented code block

- [ ] the real criterion
'
[ "$(run_tick 67 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 67 '> Example:
>
>     - [ ] example inside a quoted indented code block

- [x] the real criterion
' || fail "indentation inside a quote is measured from the quote content column"

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

echo "==> a lazy continuation under a paragraph is not a criterion"
write_issue 75 'Some prose
    - [ ] indented under a paragraph, which GitHub renders as prose

- [ ] the real criterion
'
[ "$(run_tick 75 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 75 'Some prose
    - [ ] indented under a paragraph, which GitHub renders as prose

- [x] the real criterion
' || fail "an over-indented line under prose continues the paragraph"

echo "==> a bare > line is a blank line, not prose that ends a quoted fence"
write_issue 73 '> ```text
>
> - [ ] example inside the quoted fence
> ```

- [ ] the real criterion
'
[ "$(run_tick 73 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 73 '> ```text
>
> - [ ] example inside the quoted fence
> ```

- [x] the real criterion
' || fail "a gap inside a quote must not close the fence it holds"

echo "==> a checkbox inside a type-6 HTML block is not a criterion"
write_issue 68 '<div>
- [ ] example inside an html block
</div>

- [ ] the real criterion
'
[ "$(run_tick 68 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 68 '<div>
- [ ] example inside an html block
</div>

- [x] the real criterion
' || fail "a type-6 HTML block must hide its checkbox"

echo "==> a table is a type-6 HTML block as much as a div"
write_issue 69 '<table>
<tr><td>
- [ ] example inside a table cell
</td></tr>
</table>

- [ ] the real criterion
'
[ "$(run_tick 69 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 69 '<table>
<tr><td>
- [ ] example inside a table cell
</td></tr>
</table>

- [x] the real criterion
' || fail "the whole known block-tag set must hide its contents"

echo "==> a blank line ends a type-6 block, so a <details> checklist stays live"
write_issue 70 '<details>
<summary>Acceptance criteria</summary>

- [ ] the real criterion

</details>
'
[ "$(run_tick 70 --index 1)" = 0 ] || fail "a details-wrapped criterion should stay tickable"
issue_is 70 '<details>
<summary>Acceptance criteria</summary>

- [x] the real criterion

</details>
' || fail "the blank line after <summary> ends the HTML block"

echo "==> a type-6 block opened as list-item content still hides its contents"
write_issue 76 '- <div>
  - [ ] example rendered as raw html
</div>

- [ ] the real criterion
'
[ "$(run_tick 76 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 76 '- <div>
  - [ ] example rendered as raw html
</div>

- [x] the real criterion
' || fail "the scan must see past the list marker to the tag"

echo "==> a lazy continuation that looks like a tag opens no HTML block"
write_issue 77 'Some prose
    <div>
- [ ] the real criterion
'
[ "$(run_tick 77 --index 1)" = 0 ] || fail "a paragraph continuation must not hide the next line"
issue_is 77 'Some prose
    <div>
- [x] the real criterion
' || fail "an HTML block needs at most three columns of indentation"

echo "==> a marker padded past four spaces opens no HTML block either"
write_issue 78 '-     <div>
      - [ ] example indented into code

- [ ] the real criterion
'
[ "$(run_tick 78 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 78 '-     <div>
      - [ ] example indented into code

- [x] the real criterion
' || fail "content past four columns of padding is code, not a tag"

echo "==> an empty list marker still opens a container for its children"
write_issue 79 '-
    - [ ] child of an empty parent marker
'
[ "$(run_tick 79 --index 1)" = 0 ] || fail "a child of an empty parent should stay tickable"
issue_is 79 '-
    - [x] child of an empty parent marker
' || fail "a bare marker opens a list item, so its child is not code"

echo "==> a thematic break is a rule, not three nested list containers"
write_issue 80 '- - -

    - [ ] example in an indented code block

- [ ] the real criterion
'
[ "$(run_tick 80 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 80 '- - -

    - [ ] example in an indented code block

- [x] the real criterion
' || fail "a thematic break must open no container"

echo "==> a deeper blockquote stays inside the HTML block holding it"
write_issue 81 '> <div>
> > - [ ] example inside the quoted html block

- [ ] the real criterion
'
[ "$(run_tick 81 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 81 '> <div>
> > - [ ] example inside the quoted html block

- [x] the real criterion
' || fail "quoting deeper must not close the block"

echo "==> a sibling list item ends the HTML block inside its predecessor"
write_issue 82 '- <div>
  raw content
- [ ] the real criterion
'
[ "$(run_tick 82 --index 1)" = 0 ] || fail "a sibling item should be live again"
issue_is 82 '- <div>
  raw content
- [x] the real criterion
' || fail "an HTML block ends where its container ends"

echo "==> a list-looking line inside raw HTML leaves no container behind"
write_issue 83 '<div>
- item inside raw html

    - [ ] example in an indented code block
- [ ] the real criterion
'
[ "$(run_tick 83 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 83 '<div>
- item inside raw html

    - [ ] example in an indented code block
- [x] the real criterion
' || fail "raw HTML must record no block structure"

echo "==> an unindented lazy continuation keeps its list item open"
write_issue 84 '- outer paragraph
continuation without indent

    - [ ] nested task item
'
[ "$(run_tick 84 --index 1)" = 0 ] || fail "the nested task item should stay tickable"
issue_is 84 '- outer paragraph
continuation without indent

    - [x] nested task item
' || fail "a lazy continuation closes no container"

echo "==> quoting deeper nests inside a list item rather than ending it"
write_issue 85 '- outer
  > - quoted

    - [ ] live criterion
'
[ "$(run_tick 85 --index 1)" = 0 ] || fail "the outer item should survive the quoted sub-list"
issue_is 85 '- outer
  > - quoted

    - [x] live criterion
' || fail "only leaving a container closes it"

echo "==> leaving a blockquote entered after a list marker ends its HTML block"
write_issue 86 '- > <div>
  - [ ] live criterion in the outer item
'
[ "$(run_tick 86 --index 1)" = 0 ] || fail "leaving the quote should end the block"
issue_is 86 '- > <div>
  - [x] live criterion in the outer item
' || fail "the block depth is the one the markers reached, not the line prefix"

echo "==> leaving a blockquote still closes the list it held"
write_issue 87 '> - item
- [ ] outside the quote
'
[ "$(run_tick 87 --index 1)" = 0 ] || fail "an unquoted sibling should be tickable"
issue_is 87 '> - item
- [x] outside the quote
' || fail "a shallower line must still pop the quoted container"

echo "==> a blockquote inside a list item is the container, not indentation"
write_issue 88 '- outer
    > - [ ] quoted criterion nested under the item
'
[ "$(run_tick 88 --index 1)" = 0 ] || fail "a quoted nested criterion should be tickable"
issue_is 88 '- outer
    > - [x] quoted criterion nested under the item
' || fail "the quote marker column must not count as indentation"

echo "==> a top-level fence ends the list item before it"
write_issue 89 '- item

```text
x
```

    - [ ] sample in an indented code block

- [ ] the real criterion
'
[ "$(run_tick 89 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 89 '- item

```text
x
```

    - [ ] sample in an indented code block

- [x] the real criterion
' || fail "a fence delimiter closes the containers it has left"

echo "==> a fence inside a list item leaves that item open"
write_issue 90 '- item

  ```text
  x
  ```

  - [ ] nested criterion after a fence inside the item
'
[ "$(run_tick 90 --index 1)" = 0 ] || fail "the item should survive its own fenced block"
issue_is 90 '- item

  ```text
  x
  ```

  - [x] nested criterion after a fence inside the item
' || fail "a fence at the item content column closes nothing"

echo "==> an ordered marker over nine digits opens no container either"
write_issue 91 '1234567890. text

            - [ ] sample

- [ ] the real criterion
'
[ "$(run_tick 91 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 91 '1234567890. text

            - [ ] sample

- [x] the real criterion
' || fail "a ten-digit marker is prose, so it seeds no container"

echo "==> a heading is a leaf block, so an ordered list under it starts a list"
write_issue 92 '# Heading
2. parent
    - [ ] child
'
[ "$(run_tick 92 --index 1)" = 0 ] || fail "a list under a heading should open its container"
issue_is 92 '# Heading
2. parent
    - [x] child
' || fail "a heading is not a paragraph a marker has to interrupt"

echo "==> under a real paragraph the non-1 marker rule still holds"
write_issue 93 'Some prose
2. not a list, the paragraph continues
    - [ ] still prose

- [ ] the real criterion
'
[ "$(run_tick 93 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 93 'Some prose
2. not a list, the paragraph continues
    - [ ] still prose

- [x] the real criterion
' || fail "only an ordered marker at 1 may interrupt a paragraph"

echo "==> a blockquote marker four columns in is code, not a container"
write_issue 94 'Example:

    > - [ ] example inside an indented code block

- [ ] the real criterion
'
[ "$(run_tick 94 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 94 'Example:

    > - [ ] example inside an indented code block

- [x] the real criterion
' || fail "a container marker carries at most three columns of indentation"

echo "==> a quote three columns past its container is still a container"
write_issue 95 '- item
    > - [ ] quoted at two columns past the item content
'
[ "$(run_tick 95 --index 1)" = 0 ] || fail "a quoted nested criterion should be tickable"
issue_is 95 '- item
    > - [x] quoted at two columns past the item content
' || fail "the cap is measured against the container, not column 0"

echo "==> an HTML block closes the paragraph before it"
write_issue 96 'Some prose
- <div>
  raw content
2. [ ] real criterion
'
[ "$(run_tick 96 --index 1)" = 0 ] || fail "the ordered criterion after the block should be tickable"
issue_is 96 'Some prose
- <div>
  raw content
2. [x] real criterion
' || fail "raw HTML is a leaf block, so no paragraph survives it"

echo "==> marker padding is measured in rendered columns, so tabs count fully"
write_issue 97 "$(printf -- '-\t\t[ ] example indented into code by tabs\n\n- [ ] the real criterion\n')"
[ "$(run_tick 97 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 97 "$(printf -- '-\t\t[ ] example indented into code by tabs\n\n- [x] the real criterion\n')" ||
    fail "two tabs expand past four columns, so that item is code"

echo "==> one tab of marker padding is still within the limit"
write_issue 98 "$(printf -- '-\t[ ] one tab is within the limit\n')"
[ "$(run_tick 98 --index 1)" = 0 ] || fail "one tab should stay a criterion"
issue_is 98 "$(printf -- '-\t[x] one tab is within the limit\n')" ||
    fail "a single tab reaches column four, which is the cap and not past it"

echo "==> a list item holding a leaf block grants no lazy continuation"
write_issue 99 '- # heading
following unindented prose

    - [ ] example

- [ ] the real criterion
'
[ "$(run_tick 99 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 99 '- # heading
following unindented prose

    - [ ] example

- [x] the real criterion
' || fail "prose under a heading-only item closes that item"

echo "==> an inline comment leaves its paragraph open across the hidden lines"
write_issue 100 'Some prose <!--
hidden
-->
2. [ ] example

- [ ] the real criterion
'
[ "$(run_tick 100 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 100 'Some prose <!--
hidden
-->
2. [ ] example

- [x] the real criterion
' || fail "a mid-paragraph comment is inline HTML and closes no paragraph"

echo "==> a comment that opens its own line still closes the paragraph"
write_issue 101 '<!--
- [ ] commented-out example
-->
2. [ ] real ordered criterion
'
[ "$(run_tick 101 --index 1)" = 0 ] || fail "the ordered criterion after a comment block should tick"
issue_is 101 '<!--
- [ ] commented-out example
-->
2. [x] real ordered criterion
' || fail "a type-2 comment block is a leaf block"

echo "==> an inline <pre> leaves its paragraph open too"
write_issue 102 'Some prose <pre>
- [ ] inline pre content
</pre>
2. [ ] example

- [ ] the real criterion
'
[ "$(run_tick 102 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 102 'Some prose <pre>
- [ ] inline pre content
</pre>
2. [ ] example

- [x] the real criterion
' || fail "the block/inline distinction applies to raw tags as well"

echo "==> a fence is a leaf block, so no paragraph survives it"
write_issue 103 'Some prose
- ```text
  content
  ```
unindented prose

    - [ ] example

- [ ] the real criterion
'
[ "$(run_tick 103 --index 1)" = 0 ] || fail "--index 1 should address the real criterion"
issue_is 103 'Some prose
- ```text
  content
  ```
unindented prose

    - [ ] example

- [x] the real criterion
' || fail "an item holding only a fence grants no lazy continuation"

echo "==> an unterminated fence swallows the rest of the body, and that is correct"
write_issue 104 'Some prose
- ```text
content
```
unindented prose

- [ ] not a criterion, this is inside the reopened fence
'
[ "$(run_tick 104 --index 1)" = 1 ] || fail "an unterminated fence should refuse, not guess"
issue_is 104 'Some prose
- ```text
content
```
unindented prose

- [ ] not a criterion, this is inside the reopened fence
' || fail "a refusal must not write"

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
issue_closed_claim='{"state":"closed","labels":[{"name":"bug"},{"name":"claim:claude"}],"assignees":[{"login":"evanharmon1"}]}'

echo "==> a claim:* record releases the named claim label (family level)"
rc_scenario "$(rc_page "$(rc_comment evanharmon1 "$body_v2")")" "$issue_closed_claim"
[ "$(run_release --reason 'issue closed (completed)')" = 0 ] || fail "a claim:* record release should exit 0"
grep -q -- '--remove-label claim:claude' "$rc_log" || fail "a claim:* record must remove the named claim: label"
grep -q -- '--remove-assignee evanharmon1' "$rc_log" || fail "a claim:* record must still remove the assignment"

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
