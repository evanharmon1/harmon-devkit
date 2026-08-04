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
#
# A citation needs a file cue, not just "dotted thing, colon, digits" — by shape
# alone `example.com:443` and `192.168.1.1:8080` are indistinguishable from
# `foo.sh:42`, and treating them as citations demanded a Verify section for a URL.
#
# The discriminator is a DENYLIST of internet suffixes, not an allowlist of code
# extensions: an allowlist silently drops every real citation it forgot
# (`component.vue:12`, `Info.plist:8`), and the set of file extensions has no end.
# The denylist is short, stable, and deliberately excludes every suffix that is
# also a plausible extension — `.md` (Moldova), `.sh`, `.ts`, `.rs`, `.pl` are
# country TLDs and must keep working as files.
HOST_TLD='(com|org|net|dev|app|edu|gov|mil|int|info|biz|xyz|cloud|tech|online|site|io|co|me)'
BARE_FILES='(Dockerfile|Containerfile|Makefile|Taskfile|Justfile|Procfile|Gemfile|Rakefile|Brewfile|Vagrantfile|Jenkinsfile|CODEOWNERS|LICENSE|NOTICE)'
# Four shapes: a path with a directory separator; a bare filename whose extension
# is neither an internet suffix nor all-digits (which would be an IPv4 octet); a
# dotfile (`.gitignore:3`); and the common extensionless filenames.
CITATION="([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*[A-Za-z0-9_-]\\.[A-Za-z0-9]{1,10}:[0-9]+\
|(^|[^A-Za-z0-9_./-])[A-Za-z0-9_.-]*[A-Za-z0-9_-]\\.[A-Za-z][A-Za-z0-9]{0,9}:[0-9]+\
|(^|[^A-Za-z0-9_./-])\\.[A-Za-z][A-Za-z0-9_-]*:[0-9]+\
|(^|[^A-Za-z0-9_-])${BARE_FILES}:[0-9]+)"
# Applied after matching, because grep -E has no negative lookahead. Two shapes
# are dropped: anything carrying a URL scheme, and a SLASHLESS match ending in an
# internet suffix. The slashless condition matters — `a/b/weird.xyz:3` is a real
# path even though `xyz` is also a TLD, so a directory separator settles it.
# Records are "<lineno>:<match>", hence the leading `[0-9]+:`.
NOT_A_CITATION="(://|^[0-9]+:[^/]*\\.${HOST_TLD}:[0-9]+\$)"
TEMPORAL='(currently|today|as of|right now|at present|at the moment)'
perishable="$(printf '%s\n' "$draft" |
    grep -noiE "(${CITATION}|(^|[^A-Za-z0-9_-])${TEMPORAL})" |
    grep -viE "${NOT_A_CITATION}" || true)"

if [ -z "$perishable" ]; then
    echo "check-issue-rot: no perishable claims — ok"
    exit 0
fi

# Collect the Verify section: everything between its heading and the next heading
# (or EOF). A heading on its own is not a Verify section — the command under it is
# the entire point, and an empty one is easy to reach from both the skeleton below
# and the optional Verify field on the issue forms.
# CommonMark allows up to three spaces of indent before an ATX heading, so the
# `#` is not necessarily in column 1.
verify_content="$(printf '%s\n' "$draft" | awk '
    tolower($0) ~ /^ ? ? ?#+[[:space:]]*verif(y|ication)[[:space:]]*#*[[:space:]]*$/ { if (!inv) in_fence = 0; inv = 1; next }
    inv && match($0, /^ ? ? ?(`{3,}|~{3,})/) {
        seq = substr($0, RSTART, RLENGTH); sub(/^ +/, "", seq)
        fc = substr(seq, 1, 1)
        rest = substr($0, RSTART + RLENGTH)
        if (!in_fence) { in_fence = 1; fence_char = fc; fence_len = length(seq) }
        else if (fc == fence_char && length(seq) >= fence_len && rest ~ /^[[:space:]]*$/) { in_fence = 0; fence_char = ""; fence_len = 0 }
    }
    inv && !in_fence && /^ ? ? ?#+[[:space:]]/ { inv = 0 }
    inv { print }
')"

# None of these is a command: blank lines, bare code fences, an unfilled
# <placeholder>, or a stand-in for "nothing here". `_No response_` matters most —
# it is exactly what GitHub Issue Forms render for an optional field left blank,
# so without it the check would pass every issue filed from a form with the
# Verify field skipped.
substantive="$(printf '%s\n' "$verify_content" |
    grep -vE '^[[:space:]]*$' |
    grep -vE '^[[:space:]]*`{3,}' |
    grep -vE '^[[:space:]]*<[^>]*>[[:space:]]*$' |
    grep -viE '^[[:space:]]*(_?no response_?|n/?a|tbd|todo|none)[[:space:]]*\.?$' || true)"

if [ -n "$substantive" ]; then
    echo "check-issue-rot: perishable claims are covered by a Verify section — ok"
    exit 0
fi

if [ -n "$verify_content" ] || printf '%s\n' "$draft" | grep -qiE '^ ? ? ?#+[[:space:]]*verif(y|ication)[[:space:]]*#*[[:space:]]*$'; then
    cat >&2 <<EOF
check-issue-rot: the Verify section is empty, so the perishable claims below are
still unverifiable. A heading on its own re-checks nothing — put the command under it.

$(printf '%s\n' "$perishable" | sed 's/^\([0-9][0-9]*\):/  line \1: /')

    ## Verify
    \`\`\`sh
    <command that re-checks it, and what its output means>
    \`\`\`
EOF
    exit 1
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
