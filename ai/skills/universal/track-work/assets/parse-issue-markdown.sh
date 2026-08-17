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
function advance(col, text,   i, ch) {
    for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (ch == "\t") col += 4 - (col % 4)
        else col++
    }
    return col
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
function has_raw_close(s, tag,   needle, rest, at, tail) {
    needle = "</" tag
    rest = s
    while ((at = index(rest, needle)) > 0) {
        tail = substr(rest, at + length(needle))
        if (tail ~ /^[ \t]*>/) return 1
        rest = substr(rest, at + length(needle))
    }
    return 0
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
    rest = original
    col = 0
    sp = 0
    quoted = 0
    while (1) {
        c = substr(rest, 1, 1)
        if (c == " " || c == "\t") {
            next_col = advance(col, c)
            sp += next_col - col
            col = next_col
            rest = substr(rest, 2)
            continue
        }
        if (c == ">" && sp < 4) {
            quoted++
            col++
            sp = 0
            rest = substr(rest, 2)
            if (substr(rest, 1, 1) == " ") {
                col++
                rest = substr(rest, 2)
            }
            continue
        }
        break
    }
    bare = rest
    blank = (bare ~ /^[ \t]*$/)

    # A fenced block ends with its container. Reconsider the first line outside
    # that container immediately: an unindented delimiter after a list-contained
    # fence is a new top-level opener, not the old fence closer.
    if (fence && !blank && (col < fence_col || quoted < fence_quoted)) fence = 0

    open_col = col
    open_sp = sp
    open_quoted = quoted
    after_marker = bare
    if (!fence) {
        while (1) {
            if (match(after_marker, /^([-*+]|[0-9]+[.)])[ \t]+/)) {
                open_col = advance(open_col, substr(after_marker, 1, RLENGTH))
                open_sp = 0
                after_marker = substr(after_marker, RLENGTH + 1)
                continue
            }
            if (substr(after_marker, 1, 1) == ">") {
                open_quoted++
                open_col++
                open_sp = 0
                after_marker = substr(after_marker, 2)
                if (substr(after_marker, 1, 1) == " ") {
                    open_col++
                    after_marker = substr(after_marker, 2)
                }
                continue
            }
            if (substr(after_marker, 1, 1) == " ") {
                open_col++
                open_sp++
                after_marker = substr(after_marker, 2)
                continue
            }
            break
        }
    }

    opens = (!fence && open_sp < 4 && match(after_marker, /^(```+|~~~+)/))
    if (opens && substr(after_marker, RSTART, 1) == "`" &&
        index(substr(after_marker, RSTART + RLENGTH), "`") > 0) opens = 0
    closes = (fence && sp <= 3 && match(bare, /^(```+|~~~+)/))
    if (opens || closes) {
        scan = closes ? bare : after_marker
        match(scan, /^(```+|~~~+)/)
        marker = substr(scan, RSTART, RLENGTH)
        ch = substr(marker, 1, 1)
        tail = substr(scan, RSTART + RLENGTH)
        if (!fence) {
            fence = 1
            fence_ch = ch
            fence_len = length(marker)
            fence_quoted = open_quoted
            fence_col = open_col - open_sp
        } else if (quoted == fence_quoted && ch == fence_ch &&
                   length(marker) >= fence_len && tail ~ /^[ \t]*$/) {
            fence = 0
        }
        if (mode == "--evidence") print original
        else print ""
        next
    }
    if (fence) {
        if (mode == "--evidence") print original
        else print ""
        next
    }

    candidate = fence_candidate(original)
    lower = tolower(original)
    if (raw1) {
        if (has_raw_close(lower, raw_tag)) {
            raw1 = 0
            raw_tag = ""
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
        if (has_raw_close(lower, raw_tag)) {
            raw1 = 0
            raw_tag = ""
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
