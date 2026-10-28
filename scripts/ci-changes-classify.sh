#!/usr/bin/env bash
# Classify only pull_request merge checkouts. All uncertainty means a full run.
# The merge ref's first parent is the CURRENT base tip: the event's base.sha
# can be stale and a two-dot diff from it can hide a PR's source revert.
#
# The sole allowlist is [gates].docs_only_paths in .devflow.toml. The minimal
# reader accepts a double-quoted array (inline or multiline, comments allowed).
# Multiline strings are unsupported; other gates keys must be simple strings.
# Unsupported TOML or glob syntax fails closed. Globs are repository-relative:
# * and ? do not cross /, so the shipped *.md matches only root Markdown.
# ** crosses / and **/ also matches zero directories when explicitly configured.
# Only literal letters/digits/_/./- and * / ? are supported. No shell expansion
# or evaluation of config or filenames occurs.
set -euo pipefail

full_run() {
    echo "docs-only classification: $*; running all gates" >&2
    echo 'docs_only=false'
    exit 0
}

[ "${GITHUB_EVENT_NAME:-}" = pull_request ] || full_run 'not a pull request'
[ -f .devflow.toml ] && [ -r .devflow.toml ] || full_run 'allowlist unreadable'
patterns="$(awk '
    function glob_regex(glob,    i, c, result) {
        result = "^"
        for (i = 1; i <= length(glob); i++) {
            c = substr(glob, i, 1)
            if (substr(glob, i, 3) == "**/") { result = result "(.*/)?"; i += 2 }
            else if (substr(glob, i, 2) == "**") { result = result ".*"; i++ }
            else if (c == "*") result = result "[^/]*"
            else if (c == "?") result = result "[^/]"
            else if (c == ".") result = result "\\."
            else result = result c
        }
        return result "$"
    }
    {
        # Reject multiline strings anywhere: their contents can spoof tables/keys.
        if (index($0, "\"\"\"") || index($0, sprintf("%c%c%c", 39, 39, 39))) bad = 1
        sub(/#.*/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 == "") next
        if ($0 ~ /^\[/ && !collecting) {
            if ($0 !~ /^\[[A-Za-z0-9_.-]+\]$/ && $0 !~ /^\[\[[A-Za-z0-9_.-]+\]\]$/) bad = 1
            gates = ($0 == "[gates]")
            if (gates && ++sections != 1) bad = 1
            next
        }
        if (gates && $0 ~ /^docs_only_paths[[:space:]]*=/) {
            if (++keys != 1 || collecting) bad = 1
            sub(/^docs_only_paths[[:space:]]*=[[:space:]]*/, "")
            collecting = 1
        } else if (!collecting) {
            # Never ignore an ambiguous line in the table authorizing a skip.
            if (gates && $0 !~ /^[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*"[^"\\]*"$/) bad = 1
            next
        }
        value = value $0
        if (index($0, "]")) collecting = 0
    }
    END {
        if (bad || collecting || keys != 1 || sections != 1) exit 1
        if (value !~ /^\[.*\]$/) exit 1
        sub(/^\[[[:space:]]*/, "", value)
        sub(/[[:space:]]*\]$/, "", value)
        while (length(value)) {
            if (!match(value, /^"[A-Za-z0-9_.*?\/-]+"/)) exit 1
            glob = substr(value, 2, RLENGTH - 2)
            regex[++count] = glob_regex(glob)
            value = substr(value, RLENGTH + 1)
            sub(/^[[:space:]]*/, "", value)
            if (value == "") break
            if (substr(value, 1, 1) != ",") exit 1
            value = substr(value, 2)
            sub(/^[[:space:]]*/, "", value)
        }
        if (!count) exit 1
        for (i = 1; i <= count; i++) print regex[i]
    }
' .devflow.toml)" || full_run 'allowlist parse failed or empty'
[ -n "$patterns" ] || full_run 'allowlist empty'

parents="$(git --no-replace-objects rev-list --parents -n 1 HEAD 2>/dev/null)" || full_run 'missing HEAD'
# Exactly two parents prove this is a merge checkout, not a head-only fallback.
read -r head base second extra <<<"$parents"
[ -n "${base:-}" ] && [ -n "${second:-}" ] && [ -z "${extra:-}" ] || full_run 'missing merge parents'
git --no-replace-objects cat-file -e "$base^{commit}" 2>/dev/null || full_run 'missing current base'
git --no-replace-objects cat-file -e "$second^{commit}" 2>/dev/null || full_run 'missing PR head'

diff="$(mktemp "${TMPDIR:-/tmp}/ci-changes.XXXXXX")" || full_run 'cannot capture diff'
trap 'rm -f "$diff"' EXIT
git --no-replace-objects diff --raw -z --no-renames --no-ext-diff --no-textconv \
    --ignore-submodules=none "$base" "$head" -- >"$diff" || full_run 'diff failed'
[ -s "$diff" ] || full_run 'empty diff'

while IFS= read -r -d '' record; do
    IFS= read -r -d '' path || full_run 'incomplete diff record'
    read -r old_mode new_mode old_oid new_oid status extra <<<"$record"
    [ -z "${extra:-}" ] || full_run 'unknown diff record'
    case "$status:$old_mode:$new_mode" in
    A::000000:100644 | A::000000:100755 | M::100644:100644 | M::100755:100755) ;;
    *) full_run 'rename, delete, symlink, mode change or unsupported status' ;;
    esac
    case "$path" in
    *$'\n'* | *$'\r'*) full_run 'unsupported filename' ;;
    esac
    # Infrastructure is always sensitive, even if the configured glob allows it.
    case "$path" in
    .github/actions/* | .github/workflows/* | Taskfile.yml | Taskfile.yaml | scripts/* | .devflow.toml)
        full_run 'CI infrastructure changed'
        ;;
    esac
    grep -Eq "$patterns" <<<"$path" || full_run 'path outside docs allowlist'
done <"$diff"

echo 'docs_only=true'
