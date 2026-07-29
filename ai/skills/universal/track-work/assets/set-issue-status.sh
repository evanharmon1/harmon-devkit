#!/usr/bin/env bash
# set-issue-status.sh — move an issue's card on the GitHub Project (V2) board.
#
# Why: an agent that starts work leaves no trace anyone else can see. The
# assignee is buried in the issue page, and a claim comment is one entry in a
# thread. The board is where the work is actually watched, and the taxonomy
# already has the two fields that answer "is someone on this, and who": the
# `Status` pipeline (`In Progress`, `In Review`, `Ready to Merge`) and the
# `Agent` single-select (`Claude Code`, `Codex`, …). Nothing wrote them — the
# only implementation lived inside the org-only `claude-implement.yml` workflow,
# so a local agent session moved nothing. This is that logic, usable by hand and
# on personal accounts too.
#
# Deliberately does ONE thing: sets single-select project fields on an item
# already on a board. It does not add items to boards, create fields, or invent
# options — a board whose vocabulary differs is reported, not rewritten.
#
# Not covered: on a GitHub **organization**, `Agent` is an org *issue field*
# (`orgs/{org}/issue-fields`, public preview), not a project field. This script
# only writes project fields, so `--agent` is reported as skipped there and the
# `agent:*` label carries the signal instead. `Status` is a project field on both
# owner types and always works.
#
# Usage:
#   set-issue-status.sh --repo owner/repo --issue N
#                       [--status NAME] [--agent NAME]
#                       [--project TITLE] [--dry-run]
#
# At least one of --status / --agent is required. Names match case-insensitively
# ("In Progress" and "In progress" are the same option) because boards differ.
# When the issue sits on more than one board, --project TITLE disambiguates;
# otherwise the owner's default board ("<owner> Project") is preferred.
#
# Needs the `project` token scope: gh auth refresh -s read:project,project
#
# Exit: 0 = every requested field applied (or resolved cleanly under --dry-run),
#       1 = a field resolved but the write failed,
#       2 = usage/environment error (could not verify — treat as unsafe),
#       3 = nothing to do: the issue is on no board, or no requested field or
#           option exists on it. Benign — the caller carries on.
#       4 = partial: some requested fields applied and some were skipped. Kept
#           distinct from 0 so a Status that never moved cannot hide behind an
#           Agent that did — the caller must not report a claim it did not make.
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo --issue N [--status NAME] [--agent NAME] [--project TITLE] [--dry-run]" >&2
    exit 2
}

repo="${GH_REPO:-}"
issue=""
status=""
agent=""
project_title=""
dry_run=0
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
    --agent)
        [ "$#" -ge 2 ] || usage
        agent="$2"
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
    -h | --help) usage ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] && [ -n "$issue" ] || usage
[ -n "$status" ] || [ -n "$agent" ] || usage
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

# shellcheck disable=SC2016 # $p is a GraphQL variable, not shell
if ! fields=$(gh api graphql \
    -f query='query($p:ID!){node(id:$p){... on ProjectV2{fields(first:50){nodes{... on ProjectV2SingleSelectField{id name options{id name}}}}}}}' \
    -F p="$project_id" 2>&1); then
    echo "could not read the fields of board '$board':" >&2
    echo "$fields" >&2
    exit 2
fi

requested=0
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

rc=0
if [ -n "$status" ]; then
    requested=$((requested + 1))
    apply_field "Status" "$status" || rc=1
fi
if [ -n "$agent" ]; then
    requested=$((requested + 1))
    apply_field "Agent" "$agent" || rc=1
fi

if [ "$rc" -ne 0 ]; then
    exit 1
fi
if [ "$applied" -eq "$requested" ]; then
    exit 0
fi
if [ "$applied" -gt 0 ]; then
    # Partial. Counting any single success as "applied" would let a skipped
    # Status hide behind a written Agent, and the caller would report a claim
    # for a card that never moved. Distinguish it so the caller can say which
    # half landed.
    echo "applied $applied of $requested requested field(s) — see the skips above" >&2
    exit 4
fi
# Everything requested was skipped — the board exists but does not speak this
# vocabulary. Benign: the label and assignee still carry the claim.
exit 3
