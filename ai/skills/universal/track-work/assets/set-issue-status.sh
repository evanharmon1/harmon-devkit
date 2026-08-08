#!/usr/bin/env bash
# set-issue-status.sh — move an issue's card on the GitHub Project (V2) board.
#
# Why: an agent that starts work leaves no trace anyone else can see. The
# assignee is buried in the issue page, and a claim comment is one entry in a
# thread. The board is where the work is actually watched, and the `Status`
# pipeline (`In Progress`, `In Review`, `Ready to Merge`) is the field that
# answers "is someone on this". Nothing wrote it — the only implementation
# lived inside the org-only `claude-implement.yml` workflow, so a local agent
# session moved nothing. This is that logic, usable by hand and on personal
# accounts too.
#
# The retired `Agent` single-select is deliberately NOT written here. Live
# ownership is the model-centric `claim:*` label and advisory routing is
# `suggest:*` (see ../references/claim-lifecycle.md); the `Agent` field is gone
# from the taxonomy. `--show` still reports whatever single-select values a card
# holds, so a legacy `Agent` value stays visible during the rolling transition —
# but nothing here sets it.
#
# Deliberately does ONE thing: sets the `Status` single-select on an item
# already on a board. It does not add items to boards, create fields, or invent
# options — a board whose vocabulary differs is reported, not rewritten.
#
# Usage:
#   set-issue-status.sh --repo owner/repo --issue N --status NAME
#                       [--project TITLE] [--dry-run]
#   set-issue-status.sh --repo owner/repo --issue N --show
#
# --show reads instead of writing: it prints the card's current single-select
# values as `<field>=<value>` lines (plus `board=<title>`) and exits. Call it
# BEFORE a claim — the write destroys the previous Status and nothing else
# records it, so a hand-back cannot restore what was never read.
#
# --status is required (for a write). Names match case-insensitively
# ("In Progress" and "In progress" are the same option) because boards differ.
# When the issue sits on more than one board, --project TITLE disambiguates;
# otherwise the owner's default board ("<owner> Project") is preferred.
#
# Needs the `project` token scope: gh auth refresh -s read:project,project
#
# Exit: 0 = the Status write applied (or resolved cleanly under --dry-run),
#       1 = the field resolved but the write failed,
#       2 = usage/environment error (could not verify — treat as unsafe),
#       3 = nothing to do: the issue is on no board, or the Status field or the
#           requested option does not exist on it. Benign — the caller carries
#           on.
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo --issue N --status NAME [--project TITLE] [--dry-run]" >&2
    echo "       $0 --repo owner/repo --issue N --show" >&2
    exit 2
}

repo="${GH_REPO:-}"
issue=""
status=""
project_title=""
dry_run=0
show=0
while [ "$#" -gt 0 ]; do
    case "$1" in
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
    --status)
        [ "$#" -ge 2 ] || usage
        status="$2"
        shift 2
        ;;
    --project)
        [ "$#" -ge 2 ] || usage
        project_title="$2"
        shift 2
        ;;
    --dry-run)
        dry_run=1
        shift
        ;;
    --show)
        show=1
        shift
        ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] && [ -n "$issue" ] || usage
if [ "$show" -eq 1 ]; then
    { [ -n "$status" ] || [ "$dry_run" -eq 1 ]; } && usage
else
    [ -n "$status" ] || usage
fi
case "$issue" in
'' | *[!0-9]*)
    echo "--issue must be a number, got: $issue" >&2
    exit 2
    ;;
esac

owner="${repo%%/*}"
name="${repo#*/}"
if [ -z "$owner" ] || [ -z "$name" ] || [ "$owner" = "$repo" ]; then
    echo "--repo must be owner/repo, got: $repo" >&2
    exit 2
fi

for tool in gh jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is required but not installed" >&2
        exit 2
    }
done

# ── Which board is this issue on? ────────────────────────────────────────────
# Asked from the issue outward rather than by walking every item on the board:
# one repo-scoped query instead of paging a project that may hold thousands.
# shellcheck disable=SC2016 # $o/$r/$n are GraphQL variables, not shell
if ! items=$(gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){projectItems(first:20){nodes{id project{id title}}}}}}' \
    -f o="$owner" -f r="$name" -F n="$issue" 2>&1); then
    echo "could not read project items for $repo#$issue:" >&2
    echo "$items" >&2
    case "$items" in
    *read:project* | *scope* | *INSUFFICIENT*)
        echo "hint: gh auth refresh -s read:project,project" >&2
        ;;
    esac
    exit 2
fi

nodes=$(printf '%s' "$items" | jq -c '.data.repository.issue.projectItems.nodes // []')
if [ "$(printf '%s' "$nodes" | jq 'length')" -eq 0 ]; then
    echo "$repo#$issue is on no project board — nothing to move" >&2
    echo "hint: add it to the board, or enable the project's Auto-add workflow" >&2
    exit 3
fi

if [ -n "$project_title" ]; then
    selected=$(printf '%s' "$nodes" | jq -c --arg t "$project_title" \
        'map(select((.project.title | ascii_downcase) == ($t | ascii_downcase)))')
else
    selected="$nodes"
    if [ "$(printf '%s' "$nodes" | jq 'length')" -gt 1 ]; then
        # Prefer the owner's default board — one project per owner is the
        # convention, so extra boards are usually incidental.
        preferred=$(printf '%s' "$nodes" | jq -c --arg t "$owner Project" \
            'map(select((.project.title | ascii_downcase) == ($t | ascii_downcase)))')
        [ "$(printf '%s' "$preferred" | jq 'length')" -eq 1 ] && selected="$preferred"
    fi
fi

n_selected=$(printf '%s' "$selected" | jq 'length')
if [ "$n_selected" -eq 0 ]; then
    echo "no board titled '$project_title' holds $repo#$issue; it is on:" >&2
    printf '%s' "$nodes" | jq -r '.[] | "  - " + .project.title' >&2
    exit 3
fi
if [ "$n_selected" -gt 1 ]; then
    echo "$repo#$issue is on $n_selected boards — pass --project TITLE to pick one:" >&2
    printf '%s' "$selected" | jq -r '.[] | "  - " + .project.title' >&2
    exit 2
fi

item_id=$(printf '%s' "$selected" | jq -r '.[0].id')
project_id=$(printf '%s' "$selected" | jq -r '.[0].project.id')
board=$(printf '%s' "$selected" | jq -r '.[0].project.title')

# ── --show: report what the card holds now, and stop ─────────────────────────
# A claim overwrites Status, and nothing else remembers what was there. Without
# a way to read the current value first, "restore it on hand-back" is not
# implementable — so this mode exists to be called before the write.
if [ "$show" -eq 1 ]; then
    # shellcheck disable=SC2016 # $i is a GraphQL variable, not shell
    if ! values=$(gh api graphql \
        -f query='query($i:ID!){node(id:$i){... on ProjectV2Item{fieldValues(first:50){nodes{... on ProjectV2ItemFieldSingleSelectValue{name field{... on ProjectV2FieldCommon{name}}}}}}}}' \
        -F i="$item_id" 2>&1); then
        echo "could not read the current field values of $repo#$issue:" >&2
        echo "$values" >&2
        exit 2
    fi
    # `<field>=<value>` per line, so a caller can read one without parsing JSON.
    # A field the card has not been given a value for simply does not appear.
    printf '%s' "$values" | jq -r '
        .data.node.fieldValues.nodes[]?
        | select(.field?.name? and .name?)
        | "\(.field.name)=\(.name)"'
    echo "board=$board"
    exit 0
fi

# shellcheck disable=SC2016 # $p is a GraphQL variable, not shell
if ! fields=$(gh api graphql \
    -f query='query($p:ID!){node(id:$p){... on ProjectV2{fields(first:50){nodes{... on ProjectV2SingleSelectField{id name options{id name}}}}}}}' \
    -F p="$project_id" 2>&1); then
    echo "could not read the fields of board '$board':" >&2
    echo "$fields" >&2
    exit 2
fi

applied=0

# Resolve one field + option and write it. A field or option the board does not
# have is reported and skipped, never created: the vocabulary is the project's
# to define, and inventing an option here would silently fork it.
apply_field() {
    local field_name="$1" option_name="$2" field option_id field_id available

    field=$(printf '%s' "$fields" | jq -c --arg f "$field_name" \
        'first(.data.node.fields.nodes[]? | select(((.name // "") | ascii_downcase) == ($f | ascii_downcase))) // empty')
    if [ -z "$field" ]; then
        echo "board '$board' has no single-select field '$field_name' — skipping" >&2
        return 0
    fi

    option_id=$(printf '%s' "$field" | jq -r --arg o "$option_name" \
        'first(.options[]? | select((.name | ascii_downcase) == ($o | ascii_downcase)) | .id) // empty')
    if [ -z "$option_id" ]; then
        available=$(printf '%s' "$field" | jq -r '[.options[].name] | join(", ")')
        echo "field '$field_name' has no option '$option_name' — skipping" >&2
        echo "  available: $available" >&2
        return 0
    fi

    if [ "$dry_run" -eq 1 ]; then
        echo "would set $field_name = $option_name on '$board' ($repo#$issue)"
        applied=$((applied + 1))
        return 0
    fi

    field_id=$(printf '%s' "$field" | jq -r '.id')
    # shellcheck disable=SC2016 # $p/$i/$f/$v are GraphQL variables, not shell
    gh api graphql \
        -f query='mutation($p:ID!,$i:ID!,$f:ID!,$v:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$v}}){projectV2Item{id}}}' \
        -F p="$project_id" -F i="$item_id" -F f="$field_id" -F v="$option_id" >/dev/null || return 1

    echo "set $field_name = $option_name on '$board' ($repo#$issue)"
    applied=$((applied + 1))
}

# One writable field (`Status`), so the outcomes are simple: apply_field
# returns non-zero only when the field resolved but the mutation failed (exit
# 1); a board that lacks the field or option is a skip that leaves `applied` at
# 0 (exit 3); a successful write or dry-run sets `applied` to 1 (exit 0).
if apply_field "Status" "$status"; then
    [ "$applied" -eq 1 ] && exit 0
    # The board exists but lacks the Status field or the requested option.
    # Benign: the label and assignee still carry the claim.
    exit 3
fi
exit 1
