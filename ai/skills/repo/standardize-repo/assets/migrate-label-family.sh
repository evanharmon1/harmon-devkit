#!/usr/bin/env bash
# migrate-label-family.sh — rename or transfer a live label family end to
# end, preserving every issue/PR association.
#
# Why a script, not inline shell in a recipe doc: standardize-repo's
# mode-update.md rename recipe earned a P1 finding three review rounds
# running while it stayed prose — a `gh api -f` call that silently flips
# GitHub's default method to POST, a six-value inventory loop with no
# fail-fast on a broken page, and `gh api --paginate --slurp` misread as a
# flat item array when it is actually an array of PAGES (`jq '.[]'` on that
# yields page arrays, not issues — a loop built on it processes nothing and
# a completion check built on it is vacuously "clean"). Every one of those
# is a mechanical mistake a test would have caught immediately. This script
# IS the mechanism; mode-update.md keeps only the why and when.
#
# Usage:
#   migrate-label-family.sh inventory <old-prefix> --repo <owner/repo>
#   migrate-label-family.sh rename <old> <new> --repo <owner/repo> [--execute]
#   migrate-label-family.sh transfer <old> <new> --repo <owner/repo> [--execute]
#   migrate-label-family.sh verify <old-prefix> --repo <owner/repo>
#
# inventory <old-prefix>  Discover every live `<old-prefix>:*` label (case-
#                         insensitive), fetch every issue and PR carrying
#                         each one (paginated, no result-count ceiling), and
#                         report any item carrying MORE THAN ONE of them.
#                         The old family may have resolved such conflicts by
#                         rank; a renamed/merged destination family may not
#                         (see mode-update.md). Refuses (exit 3) while any
#                         conflict remains — resolve each to one label by
#                         hand (`gh issue edit <n> --remove-label
#                         <old-prefix>:<loser>`) before renaming or
#                         transferring anything under this prefix.
#
# rename <old> <new>      Case-insensitive discovery, then an
#                         association-preserving `gh label edit --name`.
#                         Refuses if <new> already exists live — that is a
#                         name collision `gh label edit` would itself
#                         reject; use `transfer` instead. A no-op (exit 0)
#                         if <old> is not live: already renamed, or never
#                         existed.
#
# transfer <old> <new>    For the partial state where <new> already exists
#                         (typically because a provisioning task created it
#                         before the rename ran). Adds <new> to every item
#                         that carries <old>, verifies each addition, and
#                         ONLY THEN deletes <old> — which removes it from
#                         every item still attached, so doing that before
#                         every addition is confirmed would lose data
#                         instead of migrating it. Aborts (exit 1) without
#                         deleting on the first failed add or verification.
#
# verify <old-prefix>     Asserts no live label still matches
#                         `<old-prefix>:*`, case-insensitively. Exit 4 if
#                         any remain.
#
# rename/transfer dry-run by default; pass --execute to write. inventory and
# verify are always read-only.
#
# Every GitHub read goes through --method GET, pinned explicitly — request
# fields (`-f`/`-F`) are never used, because their mere presence flips gh
# api's default method to POST (see ai/skills/universal/shepherd/assets/
# gh-ro.sh, the same guard in this codebase's read-only wrapper). Every read
# is fully paginated with no assumption about how many pages exist, and
# --paginate --slurp output is always flattened with `jq 'add // []'`
# (established elsewhere in this repo, e.g. track-work/assets/
# release-claim.sh) before anything indexes into it as a list of items.
#
# Exit codes:
#   0 = succeeded, or dry-run / read resolved cleanly
#   1 = a write failed (transfer: nothing deleted; rename: nothing renamed)
#   2 = usage/environment error, or rename found the destination already live
#   3 = inventory found item(s) carrying more than one <old-prefix> label
#   4 = verify found live label(s) still matching <old-prefix>
#
# Portable to macOS bash 3.2 (no mapfile, no associative arrays).
set -euo pipefail

# A single scratch file, reused by whichever one subcommand this process
# runs. `trap ... EXIT` set INSIDE a function registers a script-wide
# handler, not a function-local one — it fires when the whole script exits,
# by which point a `local` variable from the function that set it is long
# out of scope (unbound under `set -u`). Declaring `tmp` here, and trapping
# it once here, keeps the variable the trap references always in scope.
tmp=""
trap 'rm -f "$tmp"' EXIT

usage() {
    cat >&2 <<'USAGE'
Usage:
  migrate-label-family.sh inventory <old-prefix> --repo <owner/repo>
  migrate-label-family.sh rename <old> <new> --repo <owner/repo> [--execute]
  migrate-label-family.sh transfer <old> <new> --repo <owner/repo> [--execute]
  migrate-label-family.sh verify <old-prefix> --repo <owner/repo>
USAGE
    exit 2
}

die() {
    local code="$1"
    shift
    echo "migrate-label-family: $*" >&2
    exit "$code"
}

# A label/prefix value must survive unencoded inside a `?labels=` query
# string. Colons are fine there (RFC 3986 pchar); refuse rather than
# silently mis-encode anything that would not be.
assert_query_safe() {
    case "$1" in
    *[!a-zA-Z0-9:_-]*)
        die 2 "'$1' contains a character this script does not know how to" \
            "place safely in a query string (only [a-zA-Z0-9:_-] are allowed)"
        ;;
    esac
}

# Every GitHub read in this script goes through here. --method GET is
# pinned explicitly and no -f/-F is ever passed to a `gh api` call anywhere
# in this file — see the file header for why that combination matters.
# --paginate --slurp yields an ARRAY OF PAGES, not a flat array of items
# (`gh api --paginate --slurp X | jq 'type,length,(.[0]|type)'` against any
# multi-page endpoint shows this directly): `add // []` concatenates the
# pages into one flat array. Do not replace this with `.[]` — that yields
# page arrays, not items, and every caller here assumes flat items.
paginated_get() {
    gh api --method GET --paginate --slurp "$1" | jq 'add // []'
}

# Every live label, case-insensitively searchable, paginated with no
# assumption about how many labels the repo carries.
list_labels() {
    local repo="$1"
    paginated_get "/repos/$repo/labels?per_page=100"
}

# Print the exact live spelling of $2 within $1 (the output of list_labels),
# or nothing (empty string, exit 0) if it is not live.
find_label_exact() {
    local labels="$1" wanted="$2"
    printf '%s' "$labels" | jq -r --arg wanted "$wanted" \
        '(.[] | select((.name | ascii_downcase) == ($wanted | ascii_downcase)) | .name) // empty'
}

# Print every live label matching ^<prefix>: case-insensitively, one per
# line, from the output of list_labels.
list_prefix_values() {
    local labels="$1" prefix="$2"
    printf '%s' "$labels" | jq -r --arg prefix "$prefix" \
        '.[] | select((.name | ascii_downcase) | startswith(($prefix | ascii_downcase) + ":")) | .name'
}

# Every issue and PR carrying the exact live label $2 in repo $1, as
# {number, is_pr} JSON lines (one object per line via jq -c). state=all so
# closed/merged items are not silently dropped from the inventory.
fetch_items_for_label() {
    local repo="$1" label="$2"
    assert_query_safe "$label"
    paginated_get "/repos/$repo/issues?labels=$label&state=all&per_page=100" |
        jq -c '.[] | {number: .number, is_pr: (.pull_request != null)}'
}

# gh issue/pr edit and gh issue/pr view both take the same shape; dispatch
# on is_pr so callers never have to.
gh_kind() {
    [ "$1" = "true" ] && echo pr || echo issue
}

cmd_inventory() {
    local prefix="" repo=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        -*) usage ;;
        *)
            [ -z "$prefix" ] || usage
            prefix="$1"
            shift
            ;;
        esac
    done
    [ -n "$prefix" ] && [ -n "$repo" ] || usage

    # Captured to the script-global $tmp rather than streamed, so a mid-loop
    # failure (fetch_items_for_label die()s under set -e on a broken page)
    # is never partially reported as a clean inventory — there is nothing
    # to report at all in that case, because the script has already exited.
    local labels values
    labels="$(list_labels "$repo")"
    values="$(list_prefix_values "$labels" "$prefix")"
    if [ -z "$values" ]; then
        echo "migrate-label-family: no live $prefix:* labels — nothing to inventory"
        return 0
    fi

    tmp="$(mktemp)"
    local value
    while IFS= read -r value; do
        [ -n "$value" ] || continue
        fetch_items_for_label "$repo" "$value" |
            jq -c --arg value "$value" '. + {value: $value}' >>"$tmp"
    done <<EOF
$values
EOF

    local conflicts
    conflicts="$(jq -s '
        group_by(.number)
        | map(select(length > 1)
              | {number: .[0].number, is_pr: .[0].is_pr, values: [.[].value]})
    ' "$tmp")"
    local conflict_count
    conflict_count="$(printf '%s' "$conflicts" | jq 'length')"
    if [ "$conflict_count" -eq 0 ]; then
        echo "migrate-label-family: $prefix:* is clean — no item carries more than one"
        return 0
    fi

    echo "migrate-label-family: $conflict_count item(s) carry more than one $prefix:* label:" >&2
    printf '%s' "$conflicts" | jq -r '.[] | "  #\(.number) (\(if .is_pr then "PR" else "issue" end)): \(.values | join(", "))"' >&2
    echo "migrate-label-family: resolve each to one value before renaming or transferring $prefix:*" >&2
    exit 3
}

cmd_rename() {
    local old="" new="" repo="" execute=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --execute)
            execute=1
            shift
            ;;
        -*) usage ;;
        *)
            if [ -z "$old" ]; then
                old="$1"
            elif [ -z "$new" ]; then
                new="$1"
            else
                usage
            fi
            shift
            ;;
        esac
    done
    [ -n "$old" ] && [ -n "$new" ] && [ -n "$repo" ] || usage

    local labels old_exact new_exact
    labels="$(list_labels "$repo")"
    old_exact="$(find_label_exact "$labels" "$old")"
    if [ -z "$old_exact" ]; then
        echo "migrate-label-family: $old is not live — nothing to rename"
        return 0
    fi
    new_exact="$(find_label_exact "$labels" "$new")"
    if [ -n "$new_exact" ]; then
        die 2 "refused: '$new_exact' already exists live — a rename onto it" \
            "would collide; run 'transfer $old $new --repo $repo' instead"
    fi

    if [ "$execute" -eq 0 ]; then
        echo "DRY-RUN would rename '$old_exact' to '$new' in $repo"
        return 0
    fi
    gh label edit "$old_exact" --repo "$repo" --name "$new" >/dev/null ||
        die 1 "rename failed: gh label edit $old_exact --repo $repo --name $new"
    echo "migrate-label-family: renamed '$old_exact' to '$new' in $repo"
}

cmd_transfer() {
    local old="" new="" repo="" execute=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --execute)
            execute=1
            shift
            ;;
        -*) usage ;;
        *)
            if [ -z "$old" ]; then
                old="$1"
            elif [ -z "$new" ]; then
                new="$1"
            else
                usage
            fi
            shift
            ;;
        esac
    done
    [ -n "$old" ] && [ -n "$new" ] && [ -n "$repo" ] || usage

    local labels old_exact
    labels="$(list_labels "$repo")"
    old_exact="$(find_label_exact "$labels" "$old")"
    if [ -z "$old_exact" ]; then
        echo "migrate-label-family: $old is not live — nothing to transfer"
        return 0
    fi

    tmp="$(mktemp)"
    fetch_items_for_label "$repo" "$old_exact" >"$tmp"
    local count
    count="$(wc -l <"$tmp" | tr -d ' ')"

    if [ "$execute" -eq 0 ]; then
        echo "DRY-RUN would transfer $count item(s) from '$old_exact' to '$new', then delete '$old_exact'"
        return 0
    fi

    local number is_pr kind
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        number="$(printf '%s' "$line" | jq -r '.number')"
        is_pr="$(printf '%s' "$line" | jq -r '.is_pr')"
        kind="$(gh_kind "$is_pr")"
        gh "$kind" edit "$number" --repo "$repo" --add-label "$new" >/dev/null ||
            die 1 "transfer aborted, nothing deleted: could not add '$new' to" \
                "$kind #$number"
        gh "$kind" view "$number" --repo "$repo" --json labels -q '.labels[].name' |
            grep -qxF "$new" ||
            die 1 "transfer aborted, nothing deleted: '$new' did not verify on" \
                "$kind #$number after the add reported success"
    done <"$tmp"

    gh label delete "$old_exact" --repo "$repo" --yes ||
        die 1 "every item was transferred to '$new' but deleting '$old_exact'" \
            "failed — remove it by hand"
    echo "migrate-label-family: transferred $count item(s) from '$old_exact' to '$new' and deleted '$old_exact'"
}

cmd_verify() {
    local prefix="" repo=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        -*) usage ;;
        *)
            [ -z "$prefix" ] || usage
            prefix="$1"
            shift
            ;;
        esac
    done
    [ -n "$prefix" ] && [ -n "$repo" ] || usage

    local labels values
    labels="$(list_labels "$repo")"
    values="$(list_prefix_values "$labels" "$prefix")"
    if [ -z "$values" ]; then
        echo "migrate-label-family: verified — no live $prefix:* labels remain in $repo"
        return 0
    fi
    echo "migrate-label-family: $prefix:* labels still remain in $repo:" >&2
    printf '%s\n' "$values" | sed 's/^/  /' >&2
    exit 4
}

[ "$#" -ge 1 ] || usage
command="$1"
shift
case "$command" in
inventory) cmd_inventory "$@" ;;
rename) cmd_rename "$@" ;;
transfer) cmd_transfer "$@" ;;
verify) cmd_verify "$@" ;;
*) usage ;;
esac
