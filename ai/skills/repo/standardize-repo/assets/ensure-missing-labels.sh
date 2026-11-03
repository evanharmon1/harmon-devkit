#!/usr/bin/env bash
# Parent-owned additive provisioning from the updated target checkout.
# Requires explicit operator approval outside this helper. Never reconciles
# existing metadata; the target's post-merge setup task still owns that work.
set -euo pipefail

repo="" checkout="." gh_bin="gh" dry_run=false
# Keep the array nonempty for Bash 3.2's nounset behavior.
renderer_args=(labels)
usage() {
    echo 'Usage: ensure-missing-labels.sh --repo OWNER/NAME [--checkout DIR] [--gh-bin FILE] [--dry-run] [--foreman] [--release-please]' >&2
}
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --checkout | --gh-bin)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            usage
            exit 2
        fi
        case "$1" in
        --repo) repo="$2" ;;
        --checkout) checkout="$2" ;;
        --gh-bin) gh_bin="$2" ;;
        esac
        shift 2
        ;;
    --dry-run)
        dry_run=true
        shift
        ;;
    --foreman | --release-please)
        renderer_args+=("$1")
        shift
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
    esac
done
if [[ ! "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
    usage
    exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
created='[]' already_present='[]' would_create='[]' refused='[]'
summary() {
    jq -cn --argjson created "$created" --argjson already_present "$already_present" \
        --argjson would_create "$would_create" --argjson refused "$refused" \
        '{created:$created,already_present:$already_present,would_create:$would_create,refused:$refused}'
}
refuse() {
    refused="$(jq -cn --argjson prior "$refused" --arg name "$1" --arg reason "$2" \
        '$prior + [{name:$name,reason:$reason}]')"
    summary
    exit 1
}
renderer="$checkout/scripts/label-registry-render.mjs"
[ -f "$renderer" ] || refuse '' 'missing target scripts/label-registry-render.mjs'
if ! node "$renderer" "${renderer_args[@]}" >"$tmp/rendered"; then
    refuse '' 'target label renderer failed'
fi
# Validate the complete vocabulary before the first API write. Descriptions may
# contain pipes; name/color are the first two fields in the renderer contract.
if ! jq -Rn '[inputs | (capture("^(?<name>[^|]+)\\|(?<color>[a-fA-F0-9]{6})\\|(?<description>.*)$") // error("invalid renderer record"))]
    | if length > 0 and all(.[]; (.name | test("^[^[:cntrl:]]+$")))
        and ([.[].name | ascii_downcase] | length == (unique | length))
      then . else error("invalid or duplicate label vocabulary") end' \
    <"$tmp/rendered" >"$tmp/vocabulary"; then
    refuse '' 'invalid target label vocabulary'
fi
# gh paginates up to this explicit ceiling. Equality is ambiguous (there may
# be another page), so refuse even an exactly-full list rather than guessing.
limit=10000
if ! "$gh_bin" label list --repo "$repo" --limit "$limit" --json name,color,description >"$tmp/live"; then
    refuse '' 'live label listing failed'
fi
if ! jq -e --argjson limit "$limit" 'type == "array" and length < $limit
    and all(.[]; (.name | type == "string" and length > 0))' "$tmp/live" >/dev/null; then
    refuse '' 'invalid or potentially truncated live label listing'
fi
jq -c '.[]' "$tmp/vocabulary" >"$tmp/rows"
while IFS= read -r label; do
    name="$(jq -r '.name' <<<"$label")"
    if jq -e --arg name "$name" 'any(.[]; (.name | ascii_downcase) == ($name | ascii_downcase))' "$tmp/live" >/dev/null; then
        already_present="$(jq -cn --argjson prior "$already_present" --arg name "$name" '$prior + [$name]')"
    elif [ "$dry_run" = true ]; then
        would_create="$(jq -cn --argjson prior "$would_create" --arg name "$name" '$prior + [$name]')"
    else
        color="$(jq -r '.color' <<<"$label")"
        description="$(jq -r '.description' <<<"$label")"
        if ! "$gh_bin" label create "$name" --repo "$repo" --color "$color" --description "$description" >&2; then
            refuse "$name" 'label create failed; inspect live state before retrying'
        fi
        created="$(jq -cn --argjson prior "$created" --arg name "$name" '$prior + [$name]')"
    fi
done <"$tmp/rows"
summary
