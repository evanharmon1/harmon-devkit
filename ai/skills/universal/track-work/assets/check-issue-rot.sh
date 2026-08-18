#!/usr/bin/env bash
# check-issue-rot.sh — refuse an issue draft whose perishable claims cannot be
# re-checked.
#
# Why: an issue that cites a repository path or `file:line`, records an observed
# date, or says "currently does X" is describing a snapshot. The snapshot goes
# stale — sometimes within a day, and a merged PR
# from the same session is enough to do it. State is not the problem; state a
# reader cannot re-verify is. So this does not ban `file:line` (you usually need
# it to find the thing) — it requires a `## Verify` section holding a command
# that re-establishes whether the claim still holds. With one, a reader re-checks
# in seconds. Without one, a stale citation is indistinguishable from a live one.
#
# See references/issue-authoring.md for the canonical Problem / Current
# violation / Acceptance criteria / Verify skeleton, and for the strongest
# form: where the repo has a test harness, ship a failing assertion instead of
# a description — it closes when the test passes and cannot rot, because the
# codebase evaluates it, not the reader.
#
# Usage:
#   check-issue-rot.sh [--repo-root PATH] [DRAFT_FILE]
#
# Draft comes from DRAFT_FILE, else stdin.
#
# Exit: 0 = ok (nothing perishable, or perishable with a Verify section),
#       1 = perishable claims with no Verify section, 2 = usage error.
set -euo pipefail

repo_root=""
draft_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
        echo "Usage: $0 [--repo-root PATH] [DRAFT_FILE]" >&2
        exit 2
        ;;
    --repo-root)
        [ "$#" -ge 2 ] || {
            echo "Usage: $0 [--repo-root PATH] [DRAFT_FILE]" >&2
            exit 2
        }
        repo_root="$2"
        shift 2
        ;;
    *)
        [ -z "$draft_file" ] || {
            echo "Usage: $0 [--repo-root PATH] [DRAFT_FILE]" >&2
            exit 2
        }
        draft_file="$1"
        shift
        ;;
    esac
done

if [ -n "$repo_root" ]; then
    [ -d "$repo_root" ] || {
        echo "check-issue-rot: repository root is not a directory: $repo_root" >&2
        exit 2
    }
    repo_root="$(cd "$repo_root" && pwd -P)" || exit 2
    git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "check-issue-rot: repository root is not a readable Git checkout" >&2
        exit 2
    }
fi

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT
draft_path="$tmp/draft.md"
if [ -n "$draft_file" ]; then
    [ -f "$draft_file" ] && [ -r "$draft_file" ] || {
        echo "check-issue-rot: no such file: $draft_file" >&2
        exit 2
    }
    cp "$draft_file" "$draft_path"
else
    cat >"$draft_path"
fi
asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
evidence="$tmp/evidence.md"
parse_rc=0
bash "$asset_dir/parse-issue-markdown.sh" --evidence "$draft_path" >"$evidence" || parse_rc=$?
if [ "$parse_rc" -eq 3 ]; then
    echo "check-issue-rot: draft is outside the mechanized authoring profile (see the lines above) — indeterminate" >&2
    exit 2
elif [ "$parse_rc" -ne 0 ]; then
    echo "check-issue-rot: could not parse draft evidence" >&2
    exit 2
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
BARE_FILES='(Dockerfile|Containerfile|Makefile|Taskfile|Justfile|Procfile|Gemfile|Rakefile|Brewfile|Vagrantfile|Jenkinsfile|CODEOWNERS|LICENSE|NOTICE|README\.md|CHANGELOG\.md|CONTRIBUTING\.md|SECURITY\.md)'
REPO_DIRS='(ai|bin|config|docs|lib|scripts|src|specs|template|test|tests|tools|vendor|\.agents|\.claude|\.github)'
DOTTED_FILE='[A-Za-z0-9_.-]*[A-Za-z0-9_-]\.[A-Za-z][A-Za-z0-9]{0,9}'
# Four shapes: a path with a directory separator; a bare filename whose extension
# is neither an internet suffix nor all-digits (which would be an IPv4 octet); a
# dotfile (`.gitignore:3`); and the common extensionless filenames.
CITATION="((^|[^A-Za-z0-9_./:-])[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*[A-Za-z0-9_-]\\.[A-Za-z0-9]{1,10}:[0-9]+\
|(^|[^A-Za-z0-9_./-])[A-Za-z0-9_.-]*[A-Za-z0-9_-]\\.[A-Za-z][A-Za-z0-9]{0,9}:[0-9]+\
|(^|[^A-Za-z0-9_./-])\\.[A-Za-z][A-Za-z0-9_-]*:[0-9]+\
|(^|[^A-Za-z0-9_-])${BARE_FILES}:[0-9]+)"
# A path is perishable even without a line suffix. Recognize a bare dotted
# filename, a dotted/dotfile/conventional name under any directory, and an
# extensionless path under an explicit or conventional repository directory.
# The leading boundary prevents matching a suffix of an HTTP(S) URL.
PATH_REFERENCE="(^|[^A-Za-z0-9_./:-])(${BARE_FILES}|\\.[A-Za-z][A-Za-z0-9_-]*\
|([A-Za-z0-9_.-]+/)+(${DOTTED_FILE}|\\.[A-Za-z][A-Za-z0-9_-]*|${BARE_FILES})\
|((\\.{1,2}|${REPO_DIRS})/)[A-Za-z0-9_./-]*[A-Za-z0-9_.-])"
# Applied after matching, because grep -E has no negative lookahead. Two shapes
# are dropped: anything carrying a URL scheme (the boundary above also prevents
# matching a suffix after that scheme), and a SLASHLESS match ending in an
# internet suffix. The slashless condition matters — `a/b/weird.xyz:3` is a
# real path even though `xyz` is also a TLD, so a directory separator settles it.
# Records are "<lineno>:<match>", hence the leading `[0-9]+:`.
NOT_A_CITATION="(://|^[0-9]+:[^/]*\\.${HOST_TLD}(:[0-9]+)?\$)"
# A bounded lexicon, not a natural-language oracle: the canonical home for a
# dated observation is the `Current violation (observed …)` section, which the
# metadata gate ties to Verify structurally. These patterns catch the common
# drive-by spellings — including a bare ISO date, which in an issue body is
# nearly always an observation timestamp.
TEMPORAL='(currently|today|as of|[0-9]{4}-[0-9]{2}-[0-9]{2}|right now|at present|at the moment|current[[:space:]]+(behaviou?r|state|implementation|version|output|result))'
perishable="$(grep -noiE "(${CITATION}|${PATH_REFERENCE}|(^|[^A-Za-z0-9_-])${TEMPORAL})" "$evidence" |
    grep -viE "${NOT_A_CITATION}" || true)"

# With a target checkout, exact repository paths supplement the conservative
# syntax rules above. This distinguishes root files such as `component.vue`
# from prose such as `Node.js` without pretending every dotted token is a path.
if [ -n "$repo_root" ]; then
    paths="$tmp/repository-paths"
    git -C "$repo_root" ls-files --cached --others --exclude-standard >"$paths" 2>/dev/null || {
        echo "check-issue-rot: could not read repository paths" >&2
        exit 2
    }
    repository_hits="$(awk '
      NR == FNR { if (length($0) > 1) paths[$0]=1; next }
      function trim_candidate(value,   leading, trailing) {
        leading="[(`\"{" sprintf("%c", 39)
        trailing=")]}>`\",;!?" sprintf("%c", 39)
        while (length(value) && index(leading, substr(value, 1, 1)))
          value=substr(value, 2)
        while (length(value) && index(trailing, substr(value, length(value), 1)))
          value=substr(value, 1, length(value)-1)
        # A sentence-ending period is punctuation unless the complete token is
        # itself a repository path. This preserves real dotfiles and names
        # ending in a period while recognizing ordinary `DESIGN.md.` prose.
        if (!(value in paths)) sub(/\.$/, "", value)
        # A fragment or line locator is not part of the path: both
        # `component.vue#L12` and the extensionless `BUILD:12` still cite the
        # tracked root file. Each strip is guarded the same way as the
        # period, so a tracked name that really contains the character keeps
        # matching exactly.
        if (!(value in paths)) sub(/#.*$/, "", value)
        if (!(value in paths)) sub(/:[0-9]+$/, "", value)
        return value
      }
      function record_candidate(value) {
        value=trim_candidate(value)
        if (value ~ /:\/\//) return
        if (value in paths && !seen[value]) {
          printf "%d:%s\n", FNR, value
          seen[value]=1
        }
      }
      {
        for (i=1; i<=NF; i++) {
          token=$i
          link_at=index(token, "](")
          if (link_at > 0) {
            # Inspect both halves: the visible label can name a path, and the
            # destination commonly carries the only exact checkout path.
            record_candidate(substr(token, link_at + 2))
            token=substr(token, 1, link_at - 1)
          }
          record_candidate(token)
        }
      }
    ' "$paths" "$evidence")"
    if [ -n "$repository_hits" ]; then
        perishable="${perishable}${perishable:+$'\n'}${repository_hits}"
    fi
fi

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
structure="$tmp/structure.md"
bash "$asset_dir/parse-issue-markdown.sh" --structure "$draft_path" >"$structure" || {
    echo "check-issue-rot: could not parse draft structure" >&2
    exit 2
}
# `[[:space:]]+` after the hashes, because `##Verify` with no space is prose to
# GitHub, and a heading pattern that matched it would satisfy the gate with a
# line readers never see as a heading.
verify_bounds="$(awk '
    tolower($0) ~ /^ ? ? ?#+[[:space:]]+verif(y|ication)([[:space:]]+#+)?[[:space:]]*$/ {
        if (!start) start=NR
        next
    }
    start && /^ ? ? ?#+[[:space:]]/ { print start, NR; done=1; exit }
    END { if (start && !done) print start, 2147483647 }
' "$structure")"
verify_content=""
if [ -n "$verify_bounds" ]; then
    verify_start="${verify_bounds%% *}"
    verify_end="${verify_bounds#* }"
    verify_content="$(awk -v start="$verify_start" -v end="$verify_end" \
        'NR > start && NR < end { print }' "$evidence")"
fi

# None of these is a command: blank lines, bare code fences, an unfilled
# <placeholder>, or a stand-in for "nothing here". `_No response_` matters most —
# it is exactly what GitHub Issue Forms render for an optional field left blank,
# so without it the check would pass every issue filed from a form with the
# Verify field skipped.
substantive="$(printf '%s\n' "$verify_content" |
    grep -vE '^[[:space:]]*$' |
    grep -vE '^[[:space:]]*(`{3,}|~{3,})' |
    grep -vE '^[[:space:]]*<[^>]*>[[:space:]]*$' |
    grep -viE '^[[:space:]]*(_?no response_?|n/?a|tbd|todo|none)[[:space:]]*\.?$' || true)"

if [ -n "$substantive" ]; then
    echo "check-issue-rot: perishable claims are covered by a Verify section — ok"
    exit 0
fi

if [ -n "$verify_content" ] || grep -qiE '^ ? ? ?#+[[:space:]]+verif(y|ication)([[:space:]]+#+)?[[:space:]]*$' "$structure"; then
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

Fix: add a Verify section holding a command that re-establishes the claim,
inside the canonical authoring skeleton:

    ## Problem
    <the durable invariant, impact, and why the work matters>

    ## Current violation (observed $(date -u +%Y-%m-%d))
    <file:line, behaviour — perishable; a lead, not a fact>

    ## Acceptance criteria

    - [ ] [CI] <criterion proved by an automated check>

    ## Verify
    \`\`\`sh
    <command that re-checks it, and what its output means>
    \`\`\`

Stronger, where the repo has a test harness: ship a failing assertion instead of
a description. It closes when the test passes and cannot rot.
EOF
exit 1
