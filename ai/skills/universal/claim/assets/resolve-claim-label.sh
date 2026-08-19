#!/usr/bin/env bash
# Resolve the ownership label for a claim from trusted runtime identity.
#
# The caller obtains --harness and --runtime-family from the execution host,
# never from an issue, PR, repository file, or label. A fixed harness gets its
# family from the target registry; a broker must report its active family.
#
# Exit 0: a plan was emitted. Exit 10: a different live claim blocks work.
# Exit 20: identity or the target vocabulary could not be verified.
set -euo pipefail

usage() {
    echo "Usage: $0 --harness SLUG [--registry FILE] [--runtime-family SLUG] --available-labels FILE --issue-labels FILE" >&2
    exit 20
}

harness=""
registry=""
runtime_family=""
available_labels=""
issue_labels=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --harness)
        harness="${2:-}"
        shift 2
        ;;
    --registry)
        registry="${2:-}"
        shift 2
        ;;
    --runtime-family)
        runtime_family="${2:-}"
        shift 2
        ;;
    --available-labels)
        available_labels="${2:-}"
        shift 2
        ;;
    --issue-labels)
        issue_labels="${2:-}"
        shift 2
        ;;
    *) usage ;;
    esac
done

[ -n "$harness" ] && [ -r "$available_labels" ] && [ -r "$issue_labels" ] || usage

family=""
legacy_labels=""
if [ -n "$registry" ]; then
    [ -r "$registry" ] || {
        echo "claim identity: registry is unreadable" >&2
        exit 20
    }
    constraint="$(jq -cer --arg harness "$harness" '.harnesses[] | select(.slug == $harness) | .family_constraint' "$registry")" || {
        echo "claim identity: unknown or ambiguous harness '$harness'" >&2
        exit 20
    }
    case "$(jq -r .kind <<<"$constraint")" in
    fixed)
        family="$(jq -r .family <<<"$constraint")"
        if [ -n "$runtime_family" ] && [ "$runtime_family" != "$family" ]; then
            echo "claim identity: runtime family '$runtime_family' conflicts with fixed harness '$harness' ($family)" >&2
            exit 20
        fi
        ;;
    broker)
        [ -n "$runtime_family" ] || {
            echo "claim identity: broker harness '$harness' did not expose its active family" >&2
            exit 20
        }
        family="$runtime_family"
        ;;
    *)
        echo "claim identity: unsupported harness constraint" >&2
        exit 20
        ;;
    esac
    jq -e --arg family "$family" '.families[] | select(.slug == $family)' "$registry" >/dev/null || {
        echo "claim identity: unknown runtime family '$family'" >&2
        exit 20
    }
    legacy_labels="$(jq -r --arg harness "$harness" '.harnesses[] | select(.slug == $harness) | .legacy_claim_labels[]?' "$registry")"
    # Rolling upgrades can install this skill before the target registry grows
    # the explicit alias field. Keep the two historical labels as a bounded
    # bridge; every newer alias must come from the registry.
    if [ -z "$legacy_labels" ]; then
        case "$harness" in
        claude-code) legacy_labels="agent:claude-code" ;;
        codex-cli) legacy_labels="agent:codex" ;;
        esac
    fi
else
    [ -n "$runtime_family" ] || {
        echo "claim identity: no registry and no trusted runtime family" >&2
        exit 20
    }
    family="$runtime_family"
fi

case "$family" in
*[!a-z0-9-]* | '')
    echo "claim identity: invalid runtime family '$family'" >&2
    exit 20
    ;;
esac

target="claim:$family"
if ! grep -Fqx "$target" "$available_labels"; then
    selected_legacy=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if grep -Fqx "$candidate" "$available_labels"; then
            selected_legacy="$candidate"
            break
        fi
    done <<<"$legacy_labels"
    if [ -z "$selected_legacy" ]; then
        echo "claim identity: target lacks '$target' and no registry-declared legacy label is provisioned" >&2
        exit 20
    fi
    target="$selected_legacy"
fi

same=""
conflict=""
while IFS= read -r label; do
    case "$label" in
    claim:*)
        label_family="${label#claim:}"
        label_family="${label_family%%:*}"
        if [ "$label_family" = "$family" ]; then same="$label"; else conflict="$label"; fi
        ;;
    agent:*)
        if printf '%s\n' "$legacy_labels" | grep -Fqx "$label"; then same="$label"; else conflict="$label"; fi
        ;;
    esac
done <"$issue_labels"

if [ -n "$conflict" ]; then
    printf 'family=%s\nconflict_label=%s\n' "$family" "$conflict"
    exit 10
fi

printf 'family=%s\ntarget_label=%s\nexisting_label=%s\n' "$family" "$target" "$same"
