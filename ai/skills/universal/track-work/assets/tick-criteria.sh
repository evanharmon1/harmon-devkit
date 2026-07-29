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
# Four-space-indented code blocks are *not* excluded: indistinguishable, without
# a full parser, from a checkbox nested under a list item, where ticking is
# right. Prefer `--match` when a body carries either.
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
BEGIN { infence = 0; incomment = 0; inpre = 0; fence_col = 0; fence_quoted = 0; prev_kind = "blank"; raw_tag = "" }
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

    # A fence ends where its CONTAINER ends: the first non-blank line that does
    # not reach the container content column, or that sits shallower than the
    # opener blockquote depth, closes it implicitly the way CommonMark does. That
    # line is then live again — it may be a new fence opener, or a criterion, so
    # this runs BEFORE the opener scan below: a sibling `- ```text` both ends the
    # previous item and opens its own fence, and a scan gated on the stale state
    # would never reconsider it.
    if (infence == 1 && $0 !~ /^[ \t]*$/ &&
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
        next
    }
    # HTML comments hide their contents from every renderer, and issue templates
    # routinely ship commented-out example checklists. A line that begins inside
    # one is not a criterion — ticking it would edit invisible text and report
    # success while the first real criterion stayed open. Comment state is not
    # tracked inside a fence, where the delimiters are just characters.
    starts_hidden = incomment || inpre
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
    if (starts_hidden) next

    # `bare` is $0 with the blockquote prefix and leading spaces already removed,
    # so the item pattern only has to describe the marker and the box.
    # Classify this line for the next one: blank, a list item (which keeps an
    # ordered marker in list context), or paragraph text.
    if ($0 ~ /^[ \t]*$/) {
        this_kind = "blank"
    } else if (bare ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/) {
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
