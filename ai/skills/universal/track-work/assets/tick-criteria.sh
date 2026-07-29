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
        selectors="${selectors}match:$2"$'\n'
        shift 2
        ;;
    --index)
        [ "$#" -ge 2 ] || usage
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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
before="$tmp/before.md"
after="$tmp/after.md"
recheck="$tmp/recheck.md"

read_body_or_die >"$before"

# Enumerate the unticked items as "lineno:text", in body order.
#
# The item pattern is the one check-closing-keywords.sh counts — unordered and
# ordered markers, any indentation, any whitespace run before the box, any depth
# of blockquote prefix — but fenced blocks are skipped, where that guard
# deliberately scans them. The bias inverts with the operation: a read-only guard
# is fail-closed, so a checkbox in an example counts as unfinished work; a
# command that writes must not treat an example as a criterion, or `--index 1`
# ticks a code sample and reports success while the real criterion stays open.
#
# Four-space-indented code blocks are *not* excluded: indistinguishable, without
# a full parser, from a checkbox nested under a list item, where ticking is
# right. Prefer `--match` when a body carries either.
items="$(awk '
BEGIN { infence = 0 }
{
    if (match($0, /^[ \t]*(```+|~~~+)/)) {
        marker = substr($0, RSTART, RLENGTH)
        gsub(/[ \t]/, "", marker)
        ch = substr(marker, 1, 1)
        len = length(marker)
        rest = substr($0, RSTART + RLENGTH)
        if (infence == 0) {
            infence = 1
            fence_ch = ch
            fence_len = len
        } else if (ch == fence_ch && len >= fence_len && rest ~ /^[ \t]*$/) {
            infence = 0
        }
        next
    }
    if (infence == 0 && $0 ~ /^[[:space:]]*(>[[:space:]]*)*([-*+]|[0-9]+[.)])[[:space:]]+\[[ \t]\]/) {
        print NR ":" $0
    }
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
        hits="$(printf '%s\n' "$items" | grep -iF -- "$value" || true)"
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
