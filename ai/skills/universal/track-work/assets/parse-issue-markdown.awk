# parse-issue-markdown.awk — the shared Markdown model behind the issue checks,
# restricted to a mechanically decidable authoring profile.
#
# Earlier revisions tried to answer "what does GitHub render?" for arbitrary
# Markdown, and thirteen adversarial review rounds each found the next
# CommonMark interaction the emulation missed — fences inside list containers,
# comment token boundaries, raw-tag scans reading comment interiors. The set of
# such interactions has no end, so this file no longer competes with a real
# CommonMark parser. It answers a smaller question exactly: is this draft
# inside the profile below, and if so, what structure does it carry?
#
# The invariant the profile buys: for every ACCEPTED input, the classification
# printed here equals GitHub's rendering, because every construct whose
# rendering depends on container state a line-oriented parser cannot hold —
# raw HTML, HTML comments, indented or list-nested fences, blockquoted
# structure, non-canonical task spacing, tab indentation — is refused outright
# rather than guessed at. A refusal names its line and reason on stderr and
# exits 3; callers map that to their safe direction (a contract violation for
# the draft gate, a refusal to write for the ticker, indeterminate for a read
# guard). Refusing is what keeps selectors honest: a task-looking line that
# were silently skipped would shift every later --index onto the wrong
# criterion, so anything task-shaped either enumerates or refuses.
#
# In profile, outside fenced code:
#   * blank lines and prose (anything matching no rule below is prose);
#   * ATX headings at up to three spaces of indent — such a heading renders as
#     a heading under every container state GFM allows (it interrupts
#     paragraphs, closes list items, and is a heading as item content), so it
#     needs no container context to classify;
#   * fenced code blocks whose opener sits at column 0 — column 0 closes every
#     open container, so the fence is document-level and its extent follows
#     from the delimiter lines alone (closer per CommonMark: same character,
#     at least the opener's run length, up to three spaces of indent, nothing
#     else on the line); interiors are opaque; an unclosed fence runs to end
#     of input exactly as GFM renders it;
#   * task items `- [ ] text` (also `*`, `+`, `1.`, `1)`) at column 0 with
#     exactly one space after the marker and after the box;
#   * one nesting level: `  - [ ] text` at exactly two spaces under an open
#     column-0 bullet item — two spaces is that parent's content column, which
#     GFM renders as a nested item unconditionally;
#   * plain (non-task) lists at any indent, `***`/`___` thematic breaks,
#     autolinks, and ordinary indented prose or code, none of which any
#     consumer reads as structure — GitHub may render a deep-indented plain
#     item as code instead of a list, and nothing here depends on which.
#
# The one stateful subtlety kept from CommonMark, because getting it wrong
# would enumerate a line GitHub renders as prose: an ordered marker other than
# 1 neither starts a list after an open paragraph nor interrupts another
# list's item — it only CONTINUES an open ordered list using the same
# delimiter. A canonical ordered task in any other position is refused, and a
# plain ordered item there is classified as the prose GitHub makes of it.
#
# No regex interval (`{m,n}`) appears anywhere in this file: mawk 1.3.4 — the
# default awk on Debian and Ubuntu — aborts compiling one with `REcompile() -
# panic`, taking the whole script down with exit 100.
#
# Modes (-v mode=…):
#   structure — every line verbatim, with fence delimiter and interior lines
#               replaced by a placeholder (blank interiors stay blank) so
#               section-emptiness checks still see occupied lines;
#   evidence  — every line verbatim, fences included (for the rot scan);
#   tasks     — "LINENO:line" for every rendered task item, ticked or not;
#   criteria  — "LINENO:line" for every UNTICKED rendered task item.
#
# Exit: 0 parsed, 2 usage, 3 the draft is outside the profile (diagnostics on
# stderr, one per offending line; stdout stays empty).

function atx(s) {
    # One to six hashes then a space, a tab, or end of line. Spelled as an
    # alternation because mawk cannot compile the interval form.
    return (s ~ /^(#|##|###|####|#####|######)([ \t]|$)/)
}
function list_marker(s) {
    # A list marker at the start of `s`: bullet, or an ordered marker of at
    # most nine digits — GFM reads ten or more as prose, and such a line
    # reaches the task net or the prose fallthrough instead.
    if (s ~ /^[-*+]([ \t]|$)/) return 1
    if (match(s, /^[0-9]+/) && RLENGTH <= 9 &&
        substr(s, RLENGTH + 1) ~ /^[.)]([ \t]|$)/) return 1
    return 0
}
function canonical_task(s,   d) {
    # Marker at the start of `s`, exactly one space, box, one space or EOL.
    if (s ~ /^[-*+] \[[ xX]\]( |$)/) return 1
    if (match(s, /^[0-9]+/) && RLENGTH <= 9) {
        d = substr(s, RLENGTH + 1)
        if (d ~ /^[.)] \[[ xX]\]( |$)/) return 1
    }
    return 0
}
function tasklike(s) {
    # Anything pairing a list marker with a box, however spaced or padded.
    # Canonical forms are matched before this net runs, so a hit here is a
    # non-canonical spelling.
    return (s ~ /^[ ]*([-*+]|[0-9]+[.)])[ \t]*\[[ xX\t]\]/)
}
function ordered_number(s) {
    # The numeric value of an ordered marker at the start of `s`, or -1.
    if (match(s, /^[0-9]+/) && RLENGTH <= 9 &&
        substr(s, RLENGTH + 1) ~ /^[.)]/) return substr(s, 1, RLENGTH) + 0
    return -1
}
function ordered_delim(s) {
    match(s, /^[0-9]+/)
    return substr(s, RLENGTH + 1, 1)
}
function ordered_continues(s) {
    # Can an ordered marker with number != 1 be a rendered list item HERE? Only
    # by continuing an open ordered list of the same delimiter; anywhere else
    # GFM reads the line as prose (it cannot interrupt an open paragraph, a
    # bullet item, or an ordered list punctuated differently).
    if (prev_kind == "blank" || prev_kind == "leaf") return 1
    return (context == "ordered" && context_delim == ordered_delim(s))
}
function item_content(s,   u) {
    # `s` stripped of its leading list marker and padding.
    u = s
    sub(/^([-*+]|[0-9]+[.)])[ \t]*/, "", u)
    return u
}
function structural_content(u) {
    # Would `u`, as a list item's content, scope a fence, heading, or
    # blockquote to that item? Those change meaning with the container, so an
    # item carrying one is refused wherever it appears.
    return (u ~ /^(```|~~~)/ || atx(u) || u ~ /^>/)
}
function mask_code_spans(s,   res, len, i, j, k, ch, run_len, close_pos, close_len, span_len, spaces) {
    # Replace balanced inline code spans with whitespace of equal length so that
    # any angle-bracket placeholder or HTML-like token inside code is ignored,
    # while leaving prose and unclosed/unbalanced spans intact (fail closed).
    len = length(s)
    if (index(s, "`") == 0 || len == 0) return s
    res = ""
    i = 1
    while (i <= len) {
        ch = substr(s, i, 1)
        if (ch == "`") {
            run_len = 1
            while (i + run_len <= len && substr(s, i + run_len, 1) == "`") {
                run_len++
            }
            close_pos = 0
            j = i + run_len
            while (j <= len) {
                if (substr(s, j, 1) == "`") {
                    close_len = 1
                    while (j + close_len <= len && substr(s, j + close_len, 1) == "`") {
                        close_len++
                    }
                    if (close_len == run_len) {
                        close_pos = j
                        break
                    }
                    j += close_len
                } else {
                    j++
                }
            }
            if (close_pos > 0) {
                span_len = (close_pos + run_len) - i
                spaces = ""
                for (k = 1; k <= span_len; k++) spaces = spaces " "
                res = res spaces
                i = close_pos + run_len
            } else {
                res = res substr(s, i, run_len)
                i += run_len
            }
        } else {
            res = res ch
            i++
        }
    }
    return res
}
function refuse(reason) {
    nbad++
    bad[nbad] = "line " NR ": " reason
}
function emit(kind, text) {
    # One record per input line, in order. Refusals abort all output, so on
    # success record i IS source line i and the enumeration prints real line
    # numbers.
    nout++
    out_kind[nout] = kind
    out_text[nout] = text
}
function unticked(s,   u) {
    u = s
    sub(/^  /, "", u)
    sub(/^([-*+]|[0-9]+[.)]) /, "", u)
    return (substr(u, 1, 3) == "[ ]")
}
BEGIN {
    if (mode != "criteria" && mode != "tasks" &&
        mode != "structure" && mode != "evidence") exit 2
    infence = 0
    # prev_kind: what the previous line was — "blank", "prose", "list" (a
    # column-0 list or task item), or "leaf" (heading, fence, break). The
    # ordered-continuation rule above reads it. Indented and blockquoted lines
    # count as prose: each leaves (or may leave) a paragraph open, which is
    # the conservative state.
    prev_kind = "blank"
    # context: "bullet" while a column-0 bullet item is the innermost open
    # list, "ordered" for an ordered one (context_delim holding its "." or
    # ")"), "" otherwise. Set by column-0 list items; kept through blank and
    # indented lines; cleared by every other column-0 line. GFM's lazy
    # continuation can keep a list open across a column-0 prose line where
    # this model closes it — which is exactly why a nested task without model
    # context is refused rather than classified: the model's "open" is always
    # truly open, but its "closed" may not be.
    context = ""
    context_delim = ""
    nbad = 0
    nout = 0
    NONSTRUCTURAL = "__TRACK_WORK_NONSTRUCTURAL_CONTENT__"
}
{
    line = $0

    # --- fenced code ---------------------------------------------------------
    if (infence) {
        # A closer may sit at up to three spaces of indent. Indent is tested
        # separately and stripping is spelled `^ +` because mawk's sub is not
        # obliged to take the longest optional-space match.
        t = line
        if (t !~ /^    /) sub(/^ +/, "", t)
        if (match(t, /^(`+|~+)/) &&
            substr(t, 1, 1) == fence_ch && RLENGTH >= fence_len &&
            substr(t, RLENGTH + 1) ~ /^[ \t]*$/) {
            infence = 0
        }
        emit("fence", line)
        prev_kind = "leaf"
        next
    }

    if (line ~ /^[ \t]*$/) {
        emit("blank", line)
        prev_kind = "blank"
        next
    }

    # --- profile gate: constructs whose rendering needs a real parser --------
    if (line ~ /^[ ]*\t/) {
        refuse("tab in indentation or list padding - indent with spaces")
        next
    }
    prose_line = mask_code_spans(line)
    if (index(prose_line, "<!") || index(prose_line, "-->") || index(prose_line, "<?")) {
        refuse("HTML comment or declaration - remove it, or move the example into a fenced code block")
        next
    }
    if (prose_line ~ /<\/?[A-Za-z][A-Za-z0-9-]*([ \t\/>]|$)/) {
        refuse("raw HTML tag - GitHub may hide or reflow its contents; move the example into a fenced code block")
        next
    }
    if (line ~ /^ ? ? ?(=+|-+|\*|\+)[ \t]*$/) {
        # `=` and `-` runs are setext underlines after a paragraph; a lone
        # bullet is an empty list item. `***`/`___` stay available for rules.
        refuse("bare underline or empty list marker - ambiguous between a setext heading and an empty item; use *** for a thematic break or rephrase")
        next
    }
    if (line ~ /^ ? ? ?>/) {
        t = line
        gsub(/[ \t>]/, "", t)
        u = line
        sub(/^[ >\t]+/, "", u)
        if (index(t, "```") || index(t, "~~~") || atx(u) ||
            list_marker(u) || line ~ /\[[ xX]\]/) {
            refuse("structural syntax inside a blockquote - quoted headings, lists, tasks, and fences are outside the profile")
            next
        }
        emit("prose", line)
        context = ""
        prev_kind = "prose"
        next
    }
    if (line ~ /^(```|~~~)/) {
        # A backtick fence cannot carry backticks in its info string; such a
        # line is a paragraph holding a code span, not an opener.
        match(line, /^(`+|~+)/)
        if (substr(line, 1, 1) == "`" &&
            index(substr(line, RLENGTH + 1), "`") > 0) {
            emit("prose", line)
            context = ""
            prev_kind = "prose"
            next
        }
        infence = 1
        fence_ch = substr(line, 1, 1)
        fence_len = RLENGTH
        emit("fence", line)
        context = ""
        prev_kind = "leaf"
        next
    }
    if (line ~ /^ / && line ~ /^ *(```|~~~)/) {
        refuse("indented fence delimiter - fence delimiters open at column 0 in this profile")
        next
    }

    # --- headings ------------------------------------------------------------
    # Canonical headings live at column 0. An indented heading still renders
    # as a heading, but its STRUCTURAL role is container-dependent: two-space
    # indent under an open list item nests the heading inside that item, so a
    # skeleton wrapped in a list would satisfy section checks GitHub scopes
    # to the item. Refusing every indented heading keeps the section model
    # container-free. (Stripping is spelled `^ +`, not `^ ? ? ?`: mawk's sub
    # is not obliged to take the longest optional-space match and strips one.)
    if (line ~ /^#/ && atx(line)) {
        emit("prose", line)
        context = ""
        prev_kind = "leaf"
        next
    }
    if (line ~ /^ /) {
        u = line
        sub(/^ +/, "", u)
        if (atx(u)) {
            refuse("indented heading - canonical headings start at column 0; GitHub may scope an indented heading to a list item or render it as code")
            next
        }
        if (line ~ /^    / && u ~ /^>/) {
            refuse("indented structural syntax - GitHub may render it as code or a lazy continuation; keep quotes at column 0")
            next
        }
    }
    if (line ~ /^ ? ? ?(\*\*\*+|___+)[ \t]*$/) {
        # The profile's thematic-break spellings are leaf blocks: they close
        # the paragraph, so an ordered list starting above 1 may follow one.
        emit("prose", line)
        context = ""
        prev_kind = "leaf"
        next
    }

    # --- task items ----------------------------------------------------------
    if (canonical_task(line)) {
        n = ordered_number(line)
        if (n > 1 && !ordered_continues(line)) {
            refuse("ordered task marker cannot interrupt here - GitHub renders it as prose; insert a blank line before the list or renumber from 1")
            next
        }
        emit("task", line)
        if (line ~ /^[-*+]/) {
            context = "bullet"
            context_delim = ""
        } else {
            context = "ordered"
            context_delim = ordered_delim(line)
        }
        prev_kind = "list"
        next
    }
    if (substr(line, 1, 2) == "  " && substr(line, 3, 1) != " " &&
        canonical_task(substr(line, 3))) {
        if (context != "bullet" || substr(line, 3, 1) !~ /[-*+]/) {
            refuse("nested task item without a canonical parent - nest exactly two spaces under a column-0 '- ' item")
            next
        }
        emit("task", line)
        prev_kind = "list"
        next
    }
    if (tasklike(line)) {
        refuse("non-canonical task syntax - write '- [ ] text' at column 0, or '  - [ ] text' nested two spaces under a '- ' parent")
        next
    }

    # --- plain lists and everything else -------------------------------------
    if (list_marker(line)) {
        if (structural_content(item_content(line))) {
            refuse("fence, heading, or blockquote as list-item content - GitHub scopes it to the item; restructure it to column 0")
            next
        }
        n = ordered_number(line)
        if (n > 1 && !ordered_continues(line)) {
            # GitHub reads this line as prose continuing the open paragraph,
            # and so does this model: no list opens and no context is set.
            emit("prose", line)
            prev_kind = "prose"
            next
        }
        emit("prose", line)
        if (line ~ /^[-*+]/) {
            context = "bullet"
            context_delim = ""
        } else {
            context = "ordered"
            context_delim = ordered_delim(line)
        }
        prev_kind = "list"
        next
    }
    if (line ~ /^ /) {
        # An indented plain list item is harmless — it renders as a nested
        # item or as code, and no consumer reads either as structure — but an
        # item whose content is a fence, heading, or quote is not. Indented
        # lines count as prose for the interruption rule: a wrapped criterion
        # or item continuation leaves its paragraph open.
        u = line
        sub(/^ +/, "", u)
        if (list_marker(u) && structural_content(item_content(u))) {
            refuse("fence, heading, or blockquote as list-item content - GitHub scopes it to the item; restructure it to column 0")
            next
        }
        emit("prose", line)
        prev_kind = "prose"
        next
    }
    emit("prose", line)
    context = ""
    prev_kind = "prose"
}
END {
    if (mode != "criteria" && mode != "tasks" &&
        mode != "structure" && mode != "evidence") exit 2
    if (nbad > 0) {
        for (i = 1; i <= nbad; i++) print "parse-issue-markdown: " bad[i] > "/dev/stderr"
        exit 3
    }
    for (i = 1; i <= nout; i++) {
        kind = out_kind[i]
        text = out_text[i]
        if (mode == "evidence") print text
        else if (mode == "structure") {
            if (kind != "fence") print text
            else if (text ~ /^[ \t]*$/) print ""
            else print NONSTRUCTURAL
        } else if (kind == "task") {
            if (mode == "tasks") print i ":" text
            else if (unticked(text)) print i ":" text
        }
    }
}
