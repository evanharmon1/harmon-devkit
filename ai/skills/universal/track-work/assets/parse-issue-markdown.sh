#!/usr/bin/env bash
# parse-issue-markdown.sh — render the structural Markdown lines that issue
# authoring checks may inspect. Hidden constructs become blank lines so source
# line numbers remain stable.
set -euo pipefail

usage() {
    echo "Usage: $0 --structure|--evidence DRAFT_FILE" >&2
    exit 2
}

case "${1:-}" in
--structure | --evidence) ;;
*) usage ;;
esac
[ "$#" -eq 2 ] || usage
[ -f "$2" ] && [ -r "$2" ] || {
    echo "parse-issue-markdown: cannot read draft: $2" >&2
    exit 2
}

# This is the read-only subset of the block visibility model used by
# tick-criteria.sh. It deliberately emits no task-selection decisions: callers
# receive only lines GitHub parses as Markdown structure. Fenced code, HTML
# comments, raw type-1 HTML, and type-6 HTML blocks are blanked. Container
# markers are consumed only to find a nested fence; they remain in emitted
# lines, so a heading inside a quote/list cannot masquerade as a top-level one.
awk -v mode="$1" '
function trim3(s,   n) {
    n = 0
    while (n < 3 && substr(s, 1, 1) == " ") {
        s = substr(s, 2)
        n++
    }
    return s
}
function fence_candidate(s,   rest, changed) {
    rest = s
    rest = trim3(rest)
    while (1) {
        changed = 0
        if (sub(/^>[ \t]?/, "", rest)) changed = 1
        else if (sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", rest)) changed = 1
        if (!changed) break
        rest = trim3(rest)
    }
    return rest
}
function type6(s,   t, name, tail) {
    t = s
    t = trim3(t)
    if (substr(t, 1, 1) != "<") return 0
    t = substr(t, 2)
    if (substr(t, 1, 1) == "/") t = substr(t, 2)
    if (!match(t, /^[A-Za-z][A-Za-z0-9]*/)) return 0
    name = tolower(substr(t, 1, RLENGTH))
    tail = substr(t, RLENGTH + 1)
    if (tail != "" && tail !~ /^([ \t]|\/?>)/) return 0
    return (name in htmlblock)
}
BEGIN {
    split("address article aside base basefont blockquote body caption center " \
        "col colgroup dd details dialog dir div dl dt fieldset figcaption " \
        "figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr " \
        "html iframe legend li link main menu menuitem nav noframes ol " \
        "optgroup option p param search section summary table tbody td tfoot " \
        "th thead title tr track ul", names, " ")
    for (i in names) htmlblock[names[i]] = 1
}
{
    original = $0
    candidate = fence_candidate(original)

    if (fence) {
        if (match(candidate, /^(```+|~~~+)/)) {
            marker = substr(candidate, RSTART, RLENGTH)
            ch = substr(marker, 1, 1)
            tail = substr(candidate, RSTART + RLENGTH)
            if (ch == fence_ch && length(marker) >= fence_len && tail ~ /^[ \t]*$/) {
                fence = 0
            }
        }
        if (mode == "--evidence") print original
        else print ""
        next
    }
    if (match(candidate, /^(```+|~~~+)/)) {
        marker = substr(candidate, RSTART, RLENGTH)
        ch = substr(marker, 1, 1)
        tail = substr(candidate, RSTART + RLENGTH)
        if (ch != "`" || index(tail, "`") == 0) {
            fence = 1
            fence_ch = ch
            fence_len = length(marker)
            if (mode == "--evidence") print original
            else print ""
            next
        }
    }

    lower = tolower(original)
    if (raw1) {
        close_tag = "</" raw_tag
        at = index(lower, close_tag)
        if (at > 0) {
            after = substr(lower, at + length(close_tag), 1)
            if (after == ">" || after == " " || after == "\t" || after == "") {
                raw1 = 0
                raw_tag = ""
            }
        }
        if (mode == "--evidence") print original
        else print ""
        next
    }
    raw_open = ""
    probe = fence_candidate(lower)
    for (i = 1; i <= 4; i++) {
        tag = (i == 1 ? "pre" : i == 2 ? "script" : i == 3 ? "style" : "textarea")
        if (probe ~ ("^<" tag "([ \t>/]|$)")) { raw_open = tag; break }
    }
    if (raw_open != "") {
        raw1 = 1
        raw_tag = raw_open
        close_tag = "</" raw_tag
        at = index(lower, close_tag)
        if (at > 0) {
            after = substr(lower, at + length(close_tag), 1)
            if (after == ">" || after == " " || after == "\t" || after == "") {
                raw1 = 0
                raw_tag = ""
            }
        }
        if (mode == "--evidence") print original
        else print ""
        next
    }

    if (raw6) {
        if (original ~ /^[ \t]*$/) raw6 = 0
        if (mode == "--evidence") print original
        else print ""
        next
    }
    if (type6(candidate)) {
        raw6 = 1
        if (mode == "--evidence") print original
        else print ""
        next
    }

    line = original
    visible = ""
    while (1) {
        if (comment) {
            at = index(line, "-->")
            if (!at) { line = ""; break }
            line = substr(line, at + 3)
            comment = 0
        } else {
            at = index(line, "<!--")
            if (!at) { visible = visible line; break }
            visible = visible substr(line, 1, at - 1)
            line = substr(line, at + 4)
            comment = 1
        }
    }
    print visible
}
' "$2"
