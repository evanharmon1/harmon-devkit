#!/usr/bin/env bash
# test-closing-keywords.sh — offline behavior fixtures for the closing-keyword
# guard. The fixture directory replaces GitHub's read-only Issues API.
set -euo pipefail
cd "$(dirname "$0")/.."

guard="./scripts/check-closing-keywords.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/issues"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}
issue() { printf '%s\n' "$2" >"$tmp/issues/acme_repo__$1.md"; }
run() {
    title="$1"
    body="$2"
    commits="$3"
    printf '%s\n' "$commits" >"$tmp/commits"
    rc=0
    ISSUE_BODY_DIR="$tmp/issues" PR_TITLE="$title" PR_BODY="$body" \
        "$guard" --repo acme/repo --title-env PR_TITLE --body-env PR_BODY \
        --commits-file "$tmp/commits" >"$tmp/out" 2>"$tmp/err" || rc=$?
    echo "$rc"
}

issue 1 '- [x] completed'
issue 2 '- [ ] still open'

echo '==> rejects unfinished same-repo issues across title, body, and commits'
[ "$(run 'fix: closes #2' '' '')" = 1 ] || fail 'title closing reference must fail'
[ "$(run 'fix: x' 'Resolves #2' '')" = 1 ] || fail 'body closing reference must fail'
[ "$(run 'fix: x' '' $'chore: first\n\nFixes #2')" = 1 ] || fail 'commit closing reference must fail'

echo '==> a fully completed same-repo issue passes'
[ "$(run 'fix: closes #1' '' '')" = 0 ] || fail 'completed issue should pass'

echo '==> explicit same-repo references are evaluated'
[ "$(run 'fix: closes acme/repo#2' '' '')" = 1 ] || fail 'explicit same-repo reference must fail'
[ "$(run 'fix: x' 'Fixes https://github.com/acme/repo/issues/1' '')" = 0 ] ||
    fail 'completed same-repo issue URL should pass'

echo '==> case variants of same-repo references are evaluated'
[ "$(run 'fix: closes AcMe/RePo#2' '' '')" = 1 ] ||
    fail 'mixed-case same-repo shorthand must fail'
[ "$(run 'fix: x' 'Fixes https://GiThUb.CoM/AcMe/RePo/issues/2' '')" = 1 ] ||
    fail 'mixed-case GitHub URL must fail'

echo '==> explicit owner/repo references are informational, not queried'
[ "$(run 'fix: closes other/repo#99' 'Fixes https://github.com/other/repo/issues/100' '')" = 0 ] ||
    fail 'cross-repository references should be informational'
grep -q 'informational' "$tmp/out" || fail 'informational references should be reported'

echo '==> an unreadable same-repo issue fails distinctly'
[ "$(run 'fix: closes #404' '' '')" = 2 ] || fail 'unreadable issue should fail closed with exit 2'
grep -q 'could not verify' "$tmp/err" || fail 'unreadable issue needs a distinct message'

echo '==> no closing keyword is inert without issue metadata'
[ "$(run 'fix: x' 'Refs #404' '')" = 0 ] || fail 'non-closing reference should pass'

echo 'closing-keywords guard: all cases passed'
