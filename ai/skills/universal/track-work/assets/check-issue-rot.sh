#!/usr/bin/env bash
# check-issue-rot.sh — refuse an issue draft whose perishable claims cannot be
# re-checked.
#
# Why: an issue that cites `file:line` or says "currently does X" is describing a
# snapshot. The snapshot goes stale — sometimes within a day, and a merged PR
# from the same session is enough to do it. State is not the problem; state a
# reader cannot re-verify is. So this does not ban `file:line` (you usually need
# it to find the thing) — it requires a `## Verify` section holding a command
# that re-establishes whether the claim still holds. With one, a reader re-checks
# in seconds. Without one, a stale citation is indistinguishable from a live one.
#
# See references/issue-authoring.md for the Invariant / Current violation /
# Verify structure, and for the strongest form: where the repo has a test
# harness, ship a failing assertion instead of a description — it closes when the
# test passes and cannot rot, because the codebase evaluates it, not the reader.
#
# Usage:
#   check-issue-rot.sh [DRAFT_FILE]
#
# Draft comes from DRAFT_FILE, else stdin.
#
# Exit: 0 = ok (nothing perishable, or perishable with a Verify section),
#       1 = perishable claims with no Verify section, 2 = usage error.
set -euo pipefail

case "${1:-}" in
-h | --help)
    echo "Usage: $0 [DRAFT_FILE]" >&2
    exit 2
    ;;
esac

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [DRAFT_FILE]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    [ -f "$1" ] || {
        echo "check-issue-rot: no such file: $1" >&2
        exit 2
    }
    draft="$(cat "$1")"
else
    draft="$(cat)"
fi

# A `path.ext:123` citation, or a phrase that anchors the text to the moment it
# was written. The leading group is a portable word boundary (BSD and GNU grep
# disagree on \b). Fenced code blocks are scanned too: a file:line inside one is
# just as perishable as a file:line in prose.
CITATION='[A-Za-z0-9_./-]*[A-Za-z0-9_-]\.[A-Za-z0-9]{1,10}:[0-9]+'
TEMPORAL='(currently|today|as of|right now|at present|at the moment)'
perishable="$(printf '%s\n' "$draft" |
    grep -noiE "(${CITATION}|(^|[^A-Za-z0-9_-])${TEMPORAL})" || true)"

if [ -z "$perishable" ]; then
    echo "check-issue-rot: no perishable claims — ok"
    exit 0
fi

if printf '%s\n' "$draft" | grep -qiE '^#{1,6}[[:space:]]*Verify'; then
    echo "check-issue-rot: perishable claims are covered by a Verify section — ok"
    exit 0
fi

cat >&2 <<EOF
check-issue-rot: this draft makes claims that go stale, with no way to re-check them.

A reader months from now cannot tell whether these still hold:

$(printf '%s\n' "$perishable" | sed 's/^\([0-9][0-9]*\):/  line \1: /')

Fix: add a Verify section holding a command that re-establishes the claim.

    ## Invariant
    <what must be true — does not rot>

    ## Current violation (observed $(date -u +%Y-%m-%d))
    <file:line, behaviour — perishable; a lead, not a fact>

    ## Verify
    \`\`\`sh
    <command that re-checks it, and what its output means>
    \`\`\`

Stronger, where the repo has a test harness: ship a failing assertion instead of
a description. It closes when the test passes and cannot rot.
EOF
exit 1
