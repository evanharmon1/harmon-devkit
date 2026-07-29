#!/usr/bin/env bash
# tick-criteria.sh — tick acceptance criteria on an issue, and refuse to do
# anything else to it.
#
# Why a script instead of `gh issue edit`: ticking has to happen *during*
# implementation, at the moment each criterion is verified, or it does not
# happen at all (SKILL.md §2, "Tick as you go"). But `gh issue edit` replaces
# the whole body, so the same command that ticks a box can retitle the issue,
# reword a criterion, or drop a section — which is why it cannot be pre-approved
# and why every tick would otherwise need a fresh approval. This narrows the
# operation to the one transition that is safe to authorise in advance:
# `- [ ]` -> `- [x]` on criteria you name, with every other byte of the body
# proven identical before the write.
#
# What it guarantees, and refuses to write without:
#   * every selector resolves to exactly one *unticked* item — an ambiguous or
#     already-ticked selector is an error, never a silent no-op;
#   * the new body differs from the old only on the selected lines, has the same
#     line count, and each changed line differs only by that one marker. A
#     criterion cannot be reworded while being ticked;
#   * the body has not changed since it was read. The window between that check
#     and the write is not detectable — GitHub offers no conditional update — so
#     this keeps it to a single command rather than pretending to close it.
#
# Checkboxes inside fenced code blocks are not criteria and are never touched.
# A failed edit is read back before it is reported, because GitHub can apply one
# and lose the response, and a retry would then find nothing left to tick.
#
# The issue must be assigned to the authenticated account. Being pre-approved,
# nothing in the permission layer scopes this command to the issue the user
# asked about — the claim is what scopes it.
#
# Usage:
#   tick-criteria.sh --repo owner/repo --issue N [--match TEXT]... [--index K]...
#                    [--dry-run]
#
#   --match TEXT   tick the one unticked item containing TEXT (case-insensitive)
#   --index K      tick the K-th unticked item, counting from 1
#   --dry-run      print what would be ticked; write nothing
#
# Set $ISSUE_BODY_DIR to read (and, in that mode, write) issue bodies as
# fixtures instead of calling the API: issue N of owner/repo is
# "$ISSUE_BODY_DIR/owner_repo__N.md". Offline tests only — it is reported on
# every run so it cannot silently swallow a real write.
#
# Exit: 0 = ticked (or dry run), 1 = refused to write (selector unresolved,
#       validation failed, or the body moved), 2 = usage/environment error.
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo --issue N [--match TEXT]... [--index K]... [--dry-run]" >&2
    exit 2
}

repo="${GH_REPO:-}"
issue=""
dry_run=""
selectors=""

# Selectors are accumulated into a newline-delimited stream of `kind:value`
# records, so a value containing a newline would parse as extra records — one
# documented `--match` smuggling in a second selector and ticking a criterion
# the caller never named.
reject_multiline() {
    case "$2" in
    *$'\n'*)
        echo "tick-criteria: $1 must be a single line" >&2
        exit 2
        ;;
    esac
}
while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help) usage ;;
    --repo)
        [ "$#" -ge 2 ] || usage
        repo="$2"
        shift 2
        ;;
    --issue)
        [ "$#" -ge 2 ] || usage
        issue="$2"
        shift 2
        ;;
    --match)
        [ "$#" -ge 2 ] || usage
        # An empty pattern matches every item, so on a one-criterion issue it
        # would tick without naming anything. A selector has to be a claim.
        [ -n "$2" ] || {
            echo "tick-criteria: --match needs text; an empty pattern names no criterion" >&2
            exit 2
        }
        reject_multiline --match "$2"
        selectors="${selectors}match:$2"$'\n'
        shift 2
        ;;
    --index)
        [ "$#" -ge 2 ] || usage
        reject_multiline --index "$2"
        selectors="${selectors}index:$2"$'\n'
        shift 2
        ;;
    --dry-run)
        dry_run=1
        shift
        ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] || {
    echo "tick-criteria: no repository — pass --repo owner/repo" >&2
    exit 2
}
case "$issue" in
'' | *[!0-9]*)
    echo "tick-criteria: --issue needs an issue number" >&2
    exit 2
    ;;
esac
[ -n "$selectors" ] || {
    echo "tick-criteria: nothing selected — pass --match TEXT or --index K" >&2
    exit 2
}

fixture=""
if [ -n "${ISSUE_BODY_DIR:-}" ]; then
    fixture="${ISSUE_BODY_DIR}/$(printf '%s' "$repo" | tr '/' '_')__${issue}.md"
fi

# read_body — print the issue body exactly as stored. Returns non-zero instead
# of exiting so the post-write reconciliation can read without dying.
#
# `--template` rather than `--jq`: jq terminates its output with a newline that
# is not in the body, and a body read that way and written back grows one blank
# line per tick — which is exactly the "changed more than the marker" this
# script exists to prevent. A Go template emits the field bytes and nothing else.
read_body() {
    if [ -n "$fixture" ]; then
        [ -f "$fixture" ] || return 1
        cat "$fixture"
        return 0
    fi
    gh issue view "$issue" --repo "$repo" --json body --template '{{.body}}'
}

# read_body_or_die — read_body, but a failed read is an environment error.
read_body_or_die() {
    read_body || {
        echo "tick-criteria: could not read $repo#$issue" >&2
        exit 2
    }
}

# The allowlist entry that makes this command pre-approved cannot constrain its
# arguments, so nothing in the permission layer ties a tick to the issue the
# user actually asked for — and issue text is untrusted input that must never be
# able to redirect a write. Bind it here instead: tick only an issue this
# account has claimed. Claiming is an ordinary write and still needs its own
# go-ahead (`/preflight` step 5 does it), so the assignment is a record that a
# human authorised work on this specific issue.
assert_claimed() {
    [ -n "$fixture" ] && return 0
    # Each lookup keeps its exit status: swallowed with `|| true`, an expired
    # token or a network blip reads as "unassigned" and the caller is told to
    # claim an issue they already hold.
    _me="$(gh api user --jq '.login' 2>/dev/null)" || {
        echo "tick-criteria: could not resolve the authenticated user" >&2
        exit 2
    }
    [ -n "$_me" ] || {
        echo "tick-criteria: could not resolve the authenticated user" >&2
        exit 2
    }
    _state="$(gh issue view "$issue" --repo "$repo" --json state \
        --jq '.state' 2>/dev/null)" || {
        echo "tick-criteria: could not read the state of $repo#$issue" >&2
        exit 2
    }
    case "$_state" in
    OPEN | open) ;;
    *)
        echo "tick-criteria: $repo#$issue is $_state, not open — nothing to tick during implementation" >&2
        exit 1
        ;;
    esac
    _assignees="$(gh issue view "$issue" --repo "$repo" --json assignees \
        --jq '[.assignees[].login] | join(" ")' 2>/dev/null)" || {
        echo "tick-criteria: could not read the assignees of $repo#$issue" >&2
        exit 2
    }
    case " $_assignees " in
    *" $_me "*) return 0 ;;
    esac
    echo "tick-criteria: $repo#$issue is not assigned to $_me — claim it before ticking it" >&2
    exit 1
}

assert_claimed

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
before="$tmp/before.md"
after="$tmp/after.md"
recheck="$tmp/recheck.md"

read_body_or_die >"$before"

# Enumerate the unticked items as "lineno:text", in body order.
#
# The item pattern is check-closing-keywords.sh's — unordered and ordered
# markers, any indentation, any whitespace run before the box, any depth of
# blockquote prefix — with two deliberate departures, both because this one
# writes. Fenced blocks are skipped, where that guard scans them. And the box
# must be followed by whitespace or the end of the line, as GFM requires to
# render a task item at all: `- [ ]example` is literal text, and ticking it
# would edit prose while the real criterion stayed open. The guard can safely
# over-count there; a mutation cannot. The bias inverts with the operation: a read-only guard
# is fail-closed, so a checkbox in an example counts as unfinished work; a
# command that writes must not treat an example as a criterion, or `--index 1`
# ticks a code sample and reports success while the real criterion stays open.
#
# Containment is modelled here rather than parsed — the script is deliberately
# dependency-free so consumers can vendor it with the skill, which rules out a
# CommonMark library. Modelled: fenced code blocks, indented code blocks,
# blockquotes, list items, HTML comments, and HTML blocks of CommonMark type 1
# (`pre`, `script`, `style`, `textarea`) and type 6 (the known block-tag set).
#
# Everywhere else this follows the CommonMark block algorithm, and a divergence
# is a bug rather than an accepted limit. These are the KNOWN DEPARTURES, named
# individually rather than waved at as "and other corners". State them this way
# round on purpose: two rounds of adversarial review each produced container
# kinds absent from an earlier attempt at an exhaustive list, so a claim that
# the list below is complete would not survive contact with a third.
#
#   - HTML blocks of types 3 (`<?…?>`), 4 (`<!LETTER`) and 5 (`<![CDATA[`).
#   - HTML block type 7 (any other complete tag alone on its line). Unlike
#     type 6 it cannot interrupt a paragraph, and recognising it needs a full
#     tag parse — attribute values may contain `>`.
#   - Blockquote lazy continuation: an unquoted line directly under a quoted
#     paragraph continues it, and is enumerated here as if it had left the
#     quote. Lazy continuation inside a LIST item is modelled.
#   - Setext heading underlines (`===`). ATX headings and thematic breaks are
#     recognised as leaf blocks that close a paragraph; an `===` underline is
#     still read as prose, so an ordered list starting above 1 directly under
#     one does not open its container.
#   - A fence whose interior is prose leaves that prose as the preceding line
#     kind, so an indented block on the line after the closing delimiter reads
#     as a lazy continuation instead of code. Both are hidden; only the ending
#     differs.
#
# The first three over-enumerate — they offer a line GitHub renders as
# something else — so prefer `--match` over `--index` on a body carrying one.
# The write gates downstream are what make any of this survivable: a mis-parse
# costs a refusal or a missed tick, never a body edited beyond one marker.
items="$(awk '
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
    infence = 0; incomment = 0; inpre = 0; fence_col = 0; fence_quoted = 0; prev_kind = "blank"; raw_tag = ""
    nlist = 0; incode = 0; code_quoted = 0; inhtml = 0; html_quoted = 0; html_base = 0
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
    if (infence == 0) {
        rest_of_line = $0
        while (1) {
            if (incomment) {
                at = index(rest_of_line, "-->")
                if (at == 0) break
                rest_of_line = substr(rest_of_line, at + 3)
                incomment = 0
            } else {
                at = index(rest_of_line, "<!--")
                if (at == 0) break
                rest_of_line = substr(rest_of_line, at + 4)
                incomment = 1
            }
        }
        # Raw HTML renders its contents verbatim, so a task item inside one of
        # these blocks is example text, never a criterion. These four are the
        # CommonMark block type that suppresses Markdown parsing outright.
        rest_of_line = tolower($0)
        while (1) {
            if (inpre) {
                at = index(rest_of_line, "</" raw_tag)
                if (at == 0) break
                at_end = at + 2 + length(raw_tag)
                after = substr(rest_of_line, at_end, 1)
                rest_of_line = substr(rest_of_line, at_end)
                # The tag name has to END there. Matched as a prefix, a sample
                # mentioning </prevent> would leave the block early and expose
                # the rest of it.
                if (after == ">" || after == "" || after == " " || after == "\t") {
                    inpre = 0
                    raw_tag = ""
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
            }
        }
    }
    if (starts_hidden) {
        # A line inside raw HTML or a comment is not Markdown, so it records NO
        # block structure. Letting it through leaves containers behind that
        # nothing ever opened: a list-looking line inside a `<div>` would
        # otherwise keep its phantom item after the block closes, and the code
        # sample under it would measure as a nested criterion.
        next
    }

    # `bare` is $0 with the blockquote prefix and leading spaces already removed,
    # so the item pattern only has to describe the marker and the box.
    # Classify this line for the next one: blank, a thematic break, a list item
    # (which keeps an ordered marker in list context), or paragraph text.
    if (blank) {
        this_kind = "blank"
    } else if (thematic_break(bare) || bare ~ /^#{1,6}([ \t]|$)/) {
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
            next
        }

        # A lazy continuation opens no container — it is prose that merely looks
        # indented — and a thematic break opens none either, which is why this
        # is gated on the classification rather than on the marker syntax.
        if (lazy == 0 && this_kind == "list") walk_containers(bare, col, quoted, base)
    }
    if (lazy == 1) {
        # Hidden, and it leaves its paragraph open, so the line after it is
        # judged against a paragraph and not against the list item the wrapped
        # text belongs to.
        prev_kind = "para"
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
        next
    }

    if (infence == 0 && bare ~ /^[ \t]*([-*+]|[0-9]+[.)])[[:space:]]+\[[ \t]\]([[:space:]]|$)/) {
        # GFM caps an ordered marker at nine digits; beyond that the line is not
        # a list item at all, so `1234567890. [ ] text` is prose. Counted here
        # rather than with a bounded repeat, which not every awk supports.
        item_ok = 1
        if (match(bare, /^[ \t]*[0-9]+/)) {
            digits = RLENGTH
            if (substr(bare, 1, 1) == " " || substr(bare, 1, 1) == "\t") digits--
            if (digits > 9) item_ok = 0
        }
        # A marker followed by five or more spaces puts its content four columns
        # in, which is an indented code block inside the item — not a checkbox.
        if (match(bare, /^[ \t]*([-*+]|[0-9]+[.)])/)) {
            pad = 0
            at_pad = RLENGTH + 1
            while (substr(bare, at_pad, 1) == " " || substr(bare, at_pad, 1) == "\t") {
                pad++
                at_pad++
            }
            if (pad > 4) item_ok = 0
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
        if (item_ok) print NR ":" $0
    }
    prev_kind = this_kind
}' "$before")"
[ -n "$items" ] || {
    echo "tick-criteria: $repo#$issue has no unticked items" >&2
    exit 1
}

# Resolve every selector to a line number. Each must hit exactly one unticked
# item: zero means the criterion was already ticked or the text moved, more than
# one means the caller does not know which box they are ticking. Both are
# refusals, because the whole point is that a tick is a specific claim.
targets=""
while IFS= read -r selector; do
    [ -n "$selector" ] || continue
    kind="${selector%%:*}"
    value="${selector#*:}"
    case "$kind" in
    match)
        # Match the criterion text only. The records carry a "lineno:" prefix,
        # and matching through it lets `--match 12` resolve via the line number
        # of a criterion that never mentions 12 — a selector resolving on
        # metadata is not the claim the caller thinks they are making.
        hits="$(printf '%s\n' "$items" | awk -v pat="$value" '
            BEGIN { p = tolower(pat) }
            {
                i = index($0, ":")
                text = substr($0, i + 1)
                if (index(tolower(text), p) > 0) print
            }')"
        ;;
    index)
        case "$value" in
        '' | *[!0-9]* | 0)
            echo "tick-criteria: --index needs a positive number, got '$value'" >&2
            exit 2
            ;;
        esac
        hits="$(printf '%s\n' "$items" | sed -n "${value}p")"
        ;;
    esac
    count="$(printf '%s' "$hits" | grep -c . || true)"
    if [ "$count" -ne 1 ]; then
        echo "tick-criteria: --$kind '$value' matched $count unticked items; need exactly 1" >&2
        [ "$count" -eq 0 ] || printf '%s\n' "$hits" >&2
        exit 1
    fi
    targets="${targets}${hits%%:*}"$'\n'
done <<EOF
$selectors
EOF

# Flip the marker on exactly those lines. The substitution is anchored to the
# box itself, so a literal "[ ]" elsewhere in the criterion text is untouched.
TICK_LINES="$(printf '%s' "$targets" | tr '\n' ' ')" awk '
BEGIN {
    n = split(ENVIRON["TICK_LINES"], picked, " ")
    for (i = 1; i <= n; i++) if (picked[i] != "") want[picked[i] + 0] = 1
}
{
    if (NR in want) sub(/\[[ \t]\]/, "[x]")
    print
}
' "$before" >"$after"

# awk terminates its last line whether or not the input did, so a body that did
# not end in a newline would come back one byte longer. Put it back as it was.
if [ -s "$before" ] && [ -n "$(tail -c1 "$before")" ]; then
    head -c "$(($(wc -c <"$after") - 1))" "$after" >"$after.trimmed"
    mv "$after.trimmed" "$after"
fi

# Prove the diff is only the ticks. This is the guarantee that lets the command
# be pre-approved: no reworded criterion, no dropped section, no new line.
if [ "$(wc -l <"$before")" -ne "$(wc -l <"$after")" ]; then
    echo "tick-criteria: refusing to write — line count changed" >&2
    exit 1
fi
changed="$(diff "$before" "$after" | grep -c '^<' || true)"
expected="$(printf '%s' "$targets" | grep -c . || true)"
if [ "$changed" -ne "$expected" ]; then
    echo "tick-criteria: refusing to write — $changed lines changed, expected $expected" >&2
    exit 1
fi
while IFS= read -r lineno; do
    [ -n "$lineno" ] || continue
    old="$(sed -n "${lineno}p" "$before")"
    new="$(sed -n "${lineno}p" "$after")"
    if [ "$(printf '%s' "$old" | sed 's/\[[ \t]\]/[x]/')" != "$new" ]; then
        echo "tick-criteria: refusing to write — line $lineno changed by more than its checkbox" >&2
        exit 1
    fi
    printf 'tick %s#%s line %s: %s\n' "$repo" "$issue" "$lineno" "$new"
done <<EOF
$targets
EOF

if [ -n "$dry_run" ]; then
    echo "tick-criteria: dry run, nothing written"
    exit 0
fi

# Re-assert the authorisation BEFORE the final read. The state can move during
# the read and the selector work — the issue closed, the assignment dropped —
# without the body changing, so the byte comparison alone would still pass on an
# issue this command is no longer entitled to touch. It goes first because its
# three API calls must not sit between the comparison and the write: that gap is
# the one the comparison exists to keep small.
assert_claimed

# Re-read and compare immediately before writing. A body that moved since the
# read has to be re-composed against the newer text, not overwritten.
read_body_or_die >"$recheck"
if ! cmp -s "$before" "$recheck"; then
    echo "tick-criteria: refusing to write — $repo#$issue changed since it was read; re-run" >&2
    exit 1
fi

if [ -n "$fixture" ]; then
    cat "$after" >"$fixture"
    echo "tick-criteria: wrote fixture $fixture (ISSUE_BODY_DIR set — no API call)"
    exit 0
fi

if gh issue edit "$issue" --repo "$repo" --body-file "$after" >/dev/null; then
    echo "tick-criteria: ticked $expected criterion(s) on $repo#$issue"
    exit 0
fi

# A failed edit is ambiguous: GitHub may have applied it and lost the response.
# Left as a plain failure it is also unrecoverable, because a retry's selectors
# would find the criteria already ticked and refuse. So read back and say which
# happened. (This is the one read after our own write that proves something —
# it is asking "did my change land", not "did I overwrite someone".)
if read_body >"$recheck" && cmp -s "$after" "$recheck"; then
    echo "tick-criteria: gh reported a failure but the tick is present on $repo#$issue"
    exit 0
fi
echo "tick-criteria: gh issue edit failed for $repo#$issue — nothing was ticked" >&2
exit 1
