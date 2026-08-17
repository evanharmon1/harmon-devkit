function advance(start, text,   i, c, out) {
    # Column after rendering `text` starting at column `start`. A tab moves to
    # the next four-column stop, so counting characters understates it — and a
    # container column that is too small keeps later lines inside a container
    # they have actually left.
    out = start
    for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (c == "\t") out = out + 4 - (out % 4)
        else out++
    }
    return out
}
function emit_nonstructural(line) {
    # Preserve that rendered, non-Markdown content occupies the section without
    # leaking heading/task syntax from code or raw HTML into structural checks.
    if (line ~ /^[ \t]*$/) print ""
    else print "__TRACK_WORK_NONSTRUCTURAL_CONTENT__"
}
function container_base(c, q,   k) {
    # Content column of the innermost open container a line at column `c` and
    # blockquote depth `q` still sits inside — the deepest one it reaches.
    for (k = nlist; k >= 1; k--) if (lqd[k] <= q && lcol[k] <= c) return lcol[k]
    return 0
}
function pop_containers(c, q) {
    # Close every container this line has LEFT: one it sits shallower than, or
    # one at a blockquote depth it no longer reaches. Quoting deeper nests
    # inside a container rather than ending it, hence `>` and not `!=`.
    while (nlist > 0 && (lqd[nlist] > q || c < lcol[nlist])) nlist--
}
function walk_containers(s, c, q, hc,   mk_col, pad_n, item_col) {
    # Open every container `s` spells out, starting at column `c` and blockquote
    # depth `q`. Markers and blockquote markers nest in any combination, so walk
    # them in the order they appear, exactly as the fence opener scan does.
    #
    # Sets, for the caller: `push_rest`, the line stripped of those markers;
    # `over`, whether what follows them is an indented code block rather than
    # content; and `html_open_col`/`html_open_quoted`, where a type-6 HTML block
    # opening on this line would live — `hc` is that default for a line that
    # opens nothing.
    push_rest = s
    over = 0
    html_open_col = hc
    html_open_quoted = q
    while (1) {
        if (substr(push_rest, 1, 1) == ">") {
            q++
            c++
            push_rest = substr(push_rest, 2)
            if (substr(push_rest, 1, 1) == " ") {
                c++
                push_rest = substr(push_rest, 2)
            }
            html_open_col = c
            html_open_quoted = q
            continue
        }
        if (!match(push_rest, /^([-*+]|[0-9]+[.)])([ \t]|$)/)) break
        match(push_rest, /^([-*+]|[0-9]+[.)])/)
        # GFM caps an ordered marker at nine digits, past which the line is not a
        # list item at all. Enforced here as well as at the item check below, or
        # `1234567890.` seeds a container that is not there and the code sample
        # under it measures as a nested criterion.
        if (substr(push_rest, 1, 1) ~ /[0-9]/ && RLENGTH - 1 > 9) break
        mk_col = advance(c, substr(push_rest, 1, RLENGTH))
        push_rest = substr(push_rest, RLENGTH + 1)
        pad_n = 0
        while (substr(push_rest, pad_n + 1, 1) == " " ||
               substr(push_rest, pad_n + 1, 1) == "\t") pad_n++
        item_col = advance(mk_col, substr(push_rest, 1, pad_n))
        # Past four columns of padding the content is an indented code block
        # inside the item, so the item content starts one column after the
        # marker and nothing further along the line is a container.
        over = (item_col - mk_col > 4 || substr(push_rest, pad_n + 1) == "")
        if (over) item_col = mk_col + 1
        nlist++
        lcol[nlist] = item_col
        lqd[nlist] = q
        c = item_col
        html_open_col = c
        html_open_quoted = q
        push_rest = substr(push_rest, pad_n + 1)
        if (over) break
    }
}
function thematic_break(s,   t) {
    # `- - -` is a horizontal rule, not three nested list items. The rule
    # outranks the list item its markers look like, so this is tested first.
    t = s
    gsub(/[ \t]/, "", t)
    return (t ~ /^(---+|\*\*\*+|___+)$/)
}
function atx_heading(s) {
    # An ATX heading: one to six `#` then a space, a tab, or end of line.
    #
    # Spelled as an alternation rather than the obvious `^#{1,6}([ \t]|$)`
    # because mawk 1.3.4 aborts compiling that interval outright — `REcompile()
    # - panic: values still on machine stack` — taking the whole script down
    # with exit 100. mawk is the default awk on Debian and Ubuntu, so the
    # interval form left this asset working under gawk and dead everywhere
    # else; it ships as a skill asset to machines whose awk we do not choose.
    #
    # The two forms accept exactly the same lines. Seven or more `#` match
    # neither: after any one-to-six-hash prefix the next character is a `#`,
    # which is not a space, a tab, or end of line.
    return (s ~ /^(#|##|###|####|#####|######)([ \t]|$)/)
}
function html_block_tag(s,   t, n, r) {
    # True when `s` opens a CommonMark HTML block of type 6 — `<tag`, or
    # `</tag`, from the known block-level set.
    if (substr(s, 1, 1) != "<") return 0
    t = substr(s, 2)
    if (substr(t, 1, 1) == "/") t = substr(t, 2)
    if (!match(t, /^[A-Za-z][A-Za-z0-9]*/)) return 0
    n = tolower(substr(t, 1, RLENGTH))
    r = substr(t, RLENGTH + 1)
    # The name has to END there. Matched as a prefix, an autolink like
    # <https://example.com> reads as <hr> and would hide the rest of the body.
    if (r != "" && r !~ /^([ \t]|\/?>)/) return 0
    return (n in htmlblock)
}
BEGIN {
    if (mode != "criteria" && mode != "tasks" &&
        mode != "structure" && mode != "evidence") exit 2
    infence = 0; incomment = 0; inpre = 0; fence_col = 0; fence_quoted = 0; prev_kind = "blank"; raw_tag = ""
    nlist = 0; incode = 0; code_quoted = 0; inhtml = 0; html_quoted = 0; html_base = 0
    comment_block = 0; pre_block = 0
    # CommonMark HTML block type 6, verbatim. Type 1 (pre, script, style,
    # textarea) is absent on purpose: it is closed by its closing tag, not by a
    # blank line, and is tracked separately below.
    split("address article aside base basefont blockquote body caption center " \
        "col colgroup dd details dialog dir div dl dt fieldset figcaption " \
        "figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr " \
        "html iframe legend li link main menu menuitem nav noframes ol " \
        "optgroup option p param search section summary table tbody td tfoot " \
        "th thead title tr track ul", html_names, " ")
    for (hn in html_names) htmlblock[html_names[hn]] = 1
}
{
    source_line = $0
    # Walk the container prefix once, in the order it appears: indentation,
    # blockquote markers, and (for a possible opener) list markers, which nest in
    # any combination — `- > ```text` is a fence inside a quote inside an item.
    #
    # Two columns come out of it, and keeping them apart is the whole trick.
    # `col` is the absolute column where content begins, counting quote markers,
    # and it is what container membership is measured in — every line inside a
    # container reaches the same `col`, however that container is spelled.
    # `sp` is the spaces since the last container marker, which is what
    # CommonMark caps at three for a fence delimiter. Comparing an indent in one
    # unit against a column in the other is what let quoted and indented fences
    # close early. (No apostrophes in here: the awk program is single-quoted
    # shell.)
    rest_line = $0
    col = 0
    sp = 0
    quoted = 0
    while (1) {
        c = substr(rest_line, 1, 1)
        if (c == " ") {
            col++
            sp++
            rest_line = substr(rest_line, 2)
            continue
        }
        if (c == "\t") {
            sp += advance(col, "\t") - col
            col = advance(col, "\t")
            rest_line = substr(rest_line, 2)
            continue
        }
        if (c == ">") {
            # A container marker carries at most three columns of indentation.
            # Four puts the line in an indented code block, where a `>` is
            # literal text: after a blank line, `    > - [ ] example` renders as
            # code, and consuming that `>` as a blockquote made the sample a
            # tickable criterion. Measured against the container, not column 0,
            # so `- item` holding `    > quoted` is still a real blockquote.
            marker_base = col - sp
            enclosing = container_base(col, quoted)
            if (enclosing > marker_base) marker_base = enclosing
            if (col - marker_base >= 4) break
            quoted++
            col++
            sp = 0
            rest_line = substr(rest_line, 2)
            if (substr(rest_line, 1, 1) == " ") {
                col++
                rest_line = substr(rest_line, 2)
            }
            continue
        }
        break
    }
    bare = rest_line
    # Blankness is judged AFTER the prefix, because every rule that turns on it
    # — a fence surviving a gap, a code block surviving a gap, an HTML block
    # closing, a paragraph ending — is a rule about the container. A lone `>` is
    # a blank line inside its blockquote; measuring `$0` instead calls it prose,
    # which ends nothing and starts nothing.
    blank = (bare ~ /^[ \t]*$/)

    # A fence ends where its CONTAINER ends: the first non-blank line that does
    # not reach the container content column, or that sits shallower than the
    # opener blockquote depth, closes it implicitly the way CommonMark does. That
    # line is then live again — it may be a new fence opener, or a criterion, so
    # this runs BEFORE the opener scan below: a sibling `- ```text` both ends the
    # previous item and opens its own fence, and a scan gated on the stale state
    # would never reconsider it.
    if (infence == 1 && blank == 0 &&
        (col < fence_col || quoted < fence_quoted)) {
        infence = 0
    }

    # A fence can also open as the content of a list item, where the delimiter
    # sits after the marker. Consume markers and any quotes they contain, in
    # encountered order. Only an opener may carry a marker: a marker on a later
    # line starts a new item, it does not close anything.
    had_marker = 0
    open_col = col
    open_sp = sp
    open_quoted = quoted
    after_marker = bare
    if (infence == 0) {
        while (1) {
            if (match(after_marker, /^([-*+]|[0-9]+[.)])[ \t]+/)) {
                had_marker = 1
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
            # A container marker consumes one following space; the rest is the
            # fence indentation, which still counts toward the three-space cap.
            # Left unconsumed, the anchored delimiter match simply failed and a
            # perfectly valid `- >   ``` ` never opened.
            if (substr(after_marker, 1, 1) == " ") {
                open_col++
                open_sp++
                after_marker = substr(after_marker, 2)
                continue
            }
            break
        }
    }

    opens = (infence == 0 && open_sp < 4 && match(after_marker, /^(```+|~~~+)/))
    # A backtick fence cannot carry backticks in its info string, so a line like
    # ``` followed by `quoted text` is not an opener at all. Treated as one, the
    # NEXT real fence reads as its closer and the sample inside becomes live.
    if (opens && substr(after_marker, RSTART, 1) == "`") {
        if (index(substr(after_marker, RSTART + RLENGTH), "`") > 0) opens = 0
    }
    # A closer carries no marker and, like an opener, at most three spaces since
    # its container. Unclosable is the safe direction: the enumeration ends,
    # selectors stop resolving, and the command refuses — where closing too early
    # would expose a code sample to a tick.
    closes = (infence == 1 && had_marker == 0 && sp <= 3 &&
        match(bare, /^(```+|~~~+)/))
    if (opens || closes) {
        scan = closes ? bare : after_marker
        match(scan, /^(```+|~~~+)/)
        marker = substr(scan, RSTART, RLENGTH)
        gsub(/[ \t]/, "", marker)
        ch = substr(marker, 1, 1)
        len = length(marker)
        rest_after = substr(scan, RSTART + RLENGTH)
        if (infence == 0) {
            infence = 1
            fence_ch = ch
            fence_len = len
            fence_quoted = open_quoted
            # The container content column, not the delimiter column: a document
            # fence indented one space still contains lines at column 0.
            fence_col = open_col - open_sp
        } else if (quoted == fence_quoted && ch == fence_ch && len >= fence_len && rest_after ~ /^[ \t]*$/) {
            # A closer has to sit in the same container as its opener: inside an
            # unquoted fence, a literal `> ``` ` is example text, not the end.
            infence = 0
        }
        # A delimiter line is still a line in the document, so it opens and
        # closes containers like any other. Returning without recording that
        # left the stack pointing at whatever preceded the fence: a top-level
        # fence after a list item did not end the item, and the indented code
        # block after the fence measured from that stale content column and was
        # offered as a nested criterion.
        pop_containers(col, quoted)
        if (thematic_break(bare) == 0 && bare ~ /^([-*+]|[0-9]+[.)])([ \t]|$)/) {
            walk_containers(bare, col, quoted, col - sp)
        }
        # A fence is a LEAF block, so no paragraph survives it. Returning with
        # `prev_kind` untouched left the paragraph before the opener looking
        # open: an item whose only block is a fence (`- ```text`) then granted
        # lazy continuation to the unindented prose after it, the container
        # stayed on the stack, and the indented code block after the next blank
        # line measured as a nested criterion.
        prev_kind = "leaf"
        if (mode == "structure") emit_nonstructural(source_line)
        else if (mode == "evidence") print source_line
        next
    }
    # Fence interior is code, not Markdown, so it reports no line kind of its
    # own either — classifying it would let prose inside a fence decide how the
    # line after the closing delimiter reads. Everything below is already gated
    # on `infence == 0`, so this only settles `prev_kind`.
    if (infence == 1) {
        prev_kind = "leaf"
        if (mode == "structure") emit_nonstructural(source_line)
        else if (mode == "evidence") print source_line
        next
    }
    # A live type-6 HTML block ends where its CONTAINER ends, not merely at a
    # blank line: a sibling list item closes the item holding it, and leaving
    # the blockquote closes it too. Tracked as the content column the block
    # opened at, so a line that dedents past it is live again. A DEEPER
    # blockquote does not close it — `> > text` inside `> <div>` is still raw
    # HTML — which is why this tests `<` and not `!=`.
    if (infence == 0 && inhtml == 1 &&
        (blank || quoted < html_quoted || col < html_base)) {
        inhtml = 0
    }

    # HTML comments hide their contents from every renderer, and issue templates
    # routinely ship commented-out example checklists. A line that begins inside
    # one is not a criterion — ticking it would edit invisible text and report
    # success while the first real criterion stayed open. Comment state is not
    # tracked inside a fence, where the delimiters are just characters.
    starts_hidden = incomment || inpre || inhtml
    starts_raw = inpre || inhtml
    # Whether the hiding started as a BLOCK — a comment or raw tag that opened
    # its own line — or inline, part way through a paragraph. Only the first
    # closes the paragraph; `Some prose <!--` leaves it open across the comment,
    # so what follows the `-->` is still that paragraph.
    hidden_block = inhtml || (incomment && comment_block) || (inpre && pre_block)
    if (infence == 0) {
        visible_line = ""
        comment_rest = $0
        opens_seen = 0
        while (1) {
            if (incomment) {
                at = index(comment_rest, "-->")
                if (at == 0) {
                    comment_rest = ""
                    break
                }
                visible_line = visible_line " "
                comment_rest = substr(comment_rest, at + 3)
                incomment = 0
            } else {
                at = index(comment_rest, "<!--")
                if (at == 0) {
                    visible_line = visible_line comment_rest
                    break
                }
                # A hidden comment is a token boundary, not deletion. Joining
                # its neighbours can forge `##` or `[ ]` syntax GFM never sees.
                visible_line = visible_line substr(comment_rest, 1, at - 1) " "
                comment_rest = substr(comment_rest, at + 4)
                incomment = 1
                # Only the FIRST comment on a line can be the one that opens it
                # as a block; a second `<!--` after a `-->` is mid-line by
                # construction. (No apostrophes here: single-quoted shell.)
                opens_seen++
                comment_block = (opens_seen == 1 && bare ~ /^<!--/)
            }
        }
        # Raw HTML renders its contents verbatim, so a task item inside one of
        # these blocks is example text, never a criterion. These four are the
        # CommonMark block type that suppresses Markdown parsing outright.
        rest_of_line = tolower($0)
        raw_opens_seen = 0
        pre_block = 0
        while (1) {
            if (inpre) {
                at = index(rest_of_line, "</" raw_tag)
                if (at == 0) break
                at_end = at + 2 + length(raw_tag)
                raw_tail = substr(rest_of_line, at_end)
                # The tag name has to END there. Matched as a prefix, a sample
                # mentioning </prevent> would leave the block early and expose
                # the rest of it. Whitespace without the final `>` is not a tag.
                if (match(raw_tail, /^[ \t]*>/)) {
                    rest_of_line = substr(raw_tail, RLENGTH + 1)
                    inpre = 0
                    raw_tag = ""
                } else {
                    rest_of_line = substr(rest_of_line, at_end)
                }
            } else {
                at = 0
                raw_hit = ""
                split("pre script style textarea", raw_names, " ")
                for (ri = 1; ri <= 4; ri++) {
                    ra = index(rest_of_line, "<" raw_names[ri])
                    if (ra == 0) continue
                    rafter = substr(rest_of_line, ra + 1 + length(raw_names[ri]), 1)
                    if (rafter != ">" && rafter != "" && rafter != " " && rafter != "\t" && rafter != "/") continue
                    if (at == 0 || ra < at) {
                        at = ra
                        raw_hit = raw_names[ri]
                    }
                }
                if (at == 0) break
                rest_of_line = substr(rest_of_line, at + 1 + length(raw_hit))
                inpre = 1
                raw_tag = raw_hit
                # Same distinction as the comment above: a `<pre>` that opens
                # the line is a block, one inside a sentence is inline HTML.
                raw_opens_seen++
                pre_block = (raw_opens_seen == 1 &&
                    tolower(bare) ~ /^<\/?(pre|script|style|textarea)([ \t>\/]|$)/)
            }
        }
    }
    raw_line = starts_raw || pre_block
    if (starts_hidden || raw_line) {
        # A line inside raw HTML or a comment is not Markdown, so it records NO
        # block structure. Letting it through leaves containers behind that
        # nothing ever opened: a list-looking line inside a `<div>` would
        # otherwise keep its phantom item after the block closes, and the code
        # sample under it would measure as a nested criterion.
        #
        # A BLOCK also closes the paragraph before it — raw HTML, a comment and
        # a `<pre>` are leaf blocks, so nothing is open once one starts, and
        # leaving `prev_kind` at "para" across one that ends by leaving its
        # container withheld the non-1 interruption rule from a line that was
        # starting a genuine ordered list.
        #
        # An INLINE comment closes nothing. `Some prose <!--` keeps its paragraph
        # open across the hidden lines, so the `2. [ ] example` after the `-->`
        # is lazy continuation text rather than a task item — clearing the state
        # for every hidden line offered that prose to `--index 1`.
        if (hidden_block) prev_kind = "leaf"
        else if (!starts_raw && raw_opens_seen > 0) prev_kind = "para"
        if (mode == "structure") {
            if (raw_line) emit_nonstructural(source_line)
            else print visible_line
        } else if (mode == "evidence") {
            if (raw_line) print source_line
            else print visible_line
        }
        next
    }

    # `bare` is $0 with the blockquote prefix and leading spaces already removed,
    # so the item pattern only has to describe the marker and the box.
    # Classify this line for the next one: blank, a thematic break, a list item
    # (which keeps an ordered marker in list context), or paragraph text.
    if (blank) {
        this_kind = "blank"
    } else if (thematic_break(bare) || atx_heading(bare)) {
        # Leaf blocks: a thematic break and an ATX heading both close any open
        # paragraph the way a blank line does, while being content a blank line
        # is not, and opening no container a list item would. Reading a heading
        # as a paragraph is what made `2.` under one fail to start its list —
        # the rule below only withholds a non-1 marker from interrupting a
        # PARAGRAPH, and a heading is not one.
        this_kind = "leaf"
    } else if (bare ~ /^[ \t]*([-*+]|[0-9]+[.)])([ \t]|$)/) {
        # A marker alone on its line is an EMPTY list item, and it still opens a
        # container: the indented line under a bare `-` is a child of that item,
        # so requiring a trailing space here would measure its criteria against
        # the document and bury them in a phantom code block. (No apostrophes in
        # here: the awk program is single-quoted shell.)
        this_kind = "list"
        # A marker that cannot interrupt a paragraph does not start a list, so
        # the paragraph continues through it. Classified on syntax alone, one
        # such line would hand the NEXT line a list context it never entered.
        if (prev_kind == "para" && match(bare, /^[ \t]*[0-9]+/)) {
            num_kind = substr(bare, RSTART, RLENGTH)
            sub(/^[ \t]*/, "", num_kind)
            if (num_kind + 0 != 1) this_kind = "para"
        }
    } else {
        this_kind = "para"
    }

    # Indented code blocks, and the list containment that makes them decidable.
    #
    # A checkbox four columns past its CONTAINER is an indented code block; a
    # checkbox four columns past the DOCUMENT is usually a criterion nested
    # under a list item, where ticking is right. The two are indistinguishable
    # from the line alone, which is what made this a known gap — the missing
    # piece is the content column of the innermost list item still open, and
    # that is a stack: pushed by every list marker, popped by the first line
    # that actually leaves it.
    lazy = 0
    # `push_rest` ends up holding this line stripped of its container markers,
    # and `over` whether what follows them is indented code. The HTML-block scan
    # below needs both, and for a line that opens no container they stay as
    # initialised here.
    push_rest = bare
    over = 0
    if (infence == 0 && blank == 0) {
        # A paragraph line under an OPEN paragraph is a lazy continuation: it
        # belongs to the innermost item however far it dedents, so it closes no
        # container. Popping on it loses the item, and a nested criterion after
        # the next blank line then measures against the document as code.
        # Only LEAVING a container closes it, which is why the quote test is `>`
        # and not `!=`. Quoting deeper nests inside the item rather than ending
        # it: `- outer` holding `  > - quoted` still has the outer item open,
        # and popping it there measures the next nested criterion against the
        # document and buries it in a phantom code block.
        if (this_kind != "para" || (prev_kind != "para" && prev_kind != "list")) {
            pop_containers(col, quoted)
        }
        # The innermost container this line sits in. `col - sp` is the column
        # just past the last blockquote marker — the same measurement the fence
        # opener uses — and the deeper of the two wins, because a blockquote
        # entered INSIDE a list item is the container from there on. Taking the
        # item unconditionally counts the quote marker as indentation, and
        # `- outer` holding `    > - [ ] criterion` then reads as four columns
        # of code rather than a task inside the quote.
        base = col - sp
        if (nlist > 0 && lcol[nlist] > base) base = lcol[nlist]
        # Where an HTML block opening on this line would live. The push walk
        # below overrides both when the line carries container markers, because
        # a `>` consumed AFTER a list marker raises the depth for the rest of
        # the line while the prefix `quoted` stays where it was.
        html_open_col = base
        html_open_quoted = quoted

        # A code block runs until a non-blank line comes back inside the
        # container. Blank lines belong to it, which is why this whole block is
        # gated on non-blank: a blank line between two indented lines must not
        # end it.
        if (incode == 1 && (quoted != code_quoted || col - base < 4)) incode = 0
        if (incode == 0 && col - base >= 4) {
            # Four columns past the container with a paragraph still open is a
            # LAZY CONTINUATION of that paragraph, not a code block — indented
            # code cannot interrupt a paragraph, and a list item begins one. It
            # renders as prose either way, so it is hidden either way; what
            # differs is the ending. A paragraph ends at the next blank line, a
            # code block survives it. Wrapped criteria depend on this: the
            # continuation lines of `- [ ] a criterion too long for one line`
            # sit exactly four columns past the item.
            if (prev_kind == "para" || prev_kind == "list") lazy = 1
            else {
                incode = 1
                code_quoted = quoted
            }
        }
        if (incode == 1) {
            # "code" is neither "para" nor "list", so a criterion on the first
            # line after the block is judged on its own merits.
            prev_kind = "code"
            if (mode == "structure") emit_nonstructural(source_line)
            else if (mode == "evidence") print source_line
            next
        }

        # A lazy continuation opens no container — it is prose that merely looks
        # indented — and a thematic break opens none either, which is why this
        # is gated on the classification rather than on the marker syntax.
        if (lazy == 0 && this_kind == "list") {
            walk_containers(bare, col, quoted, base)
            # Lazy continuation is a property of an open PARAGRAPH, not of a
            # list item, so an item whose content is a leaf block does not grant
            # one. `- # heading` is the case: the unindented prose under it
            # closes the item rather than continuing it, and treating the item
            # as still open kept a stale container that made the indented code
            # block after the next blank line look like a nested criterion.
            if (push_rest ~ /^[ \t]*$/ || over ||
                thematic_break(push_rest) || atx_heading(push_rest)) {
                this_kind = "leaf"
            }
        }
    }
    if (lazy == 1) {
        # Hidden, and it leaves its paragraph open, so the line after it is
        # judged against a paragraph and not against the list item the wrapped
        # text belongs to.
        prev_kind = "para"
        if (mode == "structure") emit_nonstructural(source_line)
        else if (mode == "evidence") print source_line
        next
    }

    # CommonMark HTML block type 6: a known block-level tag opening its own line
    # starts a block whose contents are raw HTML, so a task item inside one is
    # example text that GitHub renders as prose. It closes on a blank line or
    # the end of its container (above), never on a closing tag — which is what
    # keeps the common `<details>` / `<summary>` wrapper working, since the
    # blank line before the checklist ends the block and the criteria after it
    # are live.
    #
    # It opens as the CONTENT of its container, so the scan runs on the line
    # stripped of its list markers: `- <div>` opens a block inside the item, and
    # testing `bare` would miss it and leave the raw HTML after it tickable.
    # A marker padded past four columns opens none, because its content is an
    # indented code block rather than a tag.
    if (infence == 0 && blank == 0 && inhtml == 0 && over == 0 &&
        html_block_tag(push_rest)) {
        inhtml = 1
        # The container the block opens IN — measured after the markers on this
        # line, so a sibling item dedenting past it ends the block, and leaving
        # a blockquote entered mid-line (`- > <div>`) ends it too.
        html_base = html_open_col
        html_quoted = html_open_quoted
        # A leaf block, same as the hidden lines that follow it: whatever
        # paragraph preceded the opener is closed by it.
        prev_kind = "leaf"
        if (mode == "structure") emit_nonstructural(source_line)
        else if (mode == "evidence") print source_line
        next
    }

    if (infence == 0 && bare ~ /^[ \t]*([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\]([[:space:]]|$)/) {
        # GFM caps an ordered marker at nine digits; beyond that the line is not
        # a list item at all, so `1234567890. [ ] text` is prose. Counted here
        # rather than with a bounded repeat, which not every awk supports.
        item_ok = 1
        if (match(bare, /^[ \t]*[0-9]+/)) {
            digits = RLENGTH
            if (substr(bare, 1, 1) == " " || substr(bare, 1, 1) == "\t") digits--
            if (digits > 9) item_ok = 0
        }
        # A marker whose padding reaches five columns puts its content four
        # columns in, which is an indented code block inside the item — not a
        # checkbox. Measured in RENDERED columns, like every other width here:
        # counting characters instead misses `-\t\t[ ] example`, whose two tabs
        # are two characters but expand past the limit, and offers a code sample
        # as a criterion.
        if (match(bare, /^[ \t]*([-*+]|[0-9]+[.)])/)) {
            mark_end = advance(col, substr(bare, 1, RLENGTH))
            pad_start = RLENGTH + 1
            at_pad = pad_start
            while (substr(bare, at_pad, 1) == " " || substr(bare, at_pad, 1) == "\t") at_pad++
            if (advance(mark_end, substr(bare, pad_start, at_pad - pad_start)) - mark_end > 4) {
                item_ok = 0
            }
        }
        # Only an ordered marker starting at 1 may interrupt a paragraph, so
        # `2. [ ] text` directly under prose stays part of that prose. Tracked
        # with the previous line kind rather than a full block parse: inside a
        # list, `2.` continues the list and is a criterion as usual.
        if (item_ok && prev_kind == "para" && match(bare, /^[ \t]*[0-9]+/)) {
            num = substr(bare, RSTART, RLENGTH)
            sub(/^[ \t]*/, "", num)
            if (num + 0 != 1) item_ok = 0
        }
        if (item_ok && mode == "tasks") print NR ":" visible_line
        if (item_ok && mode == "criteria" &&
            bare ~ /^[ \t]*([-*+]|[0-9]+[.)])[[:space:]]+\[[ \t]\]([[:space:]]|$)/) {
            print NR ":" visible_line
        }
    }
    if (mode == "structure" || mode == "evidence") print visible_line
    prev_kind = this_kind
}
