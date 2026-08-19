#!/usr/bin/env bash
# Resolve the ownership label for a claim from trusted runtime identity.
#
# The caller obtains --harness, --runtime-family, and any --claim-model from the execution host,
# never from an issue, PR, repository file, or label. The registry validates a
# host-attested family; it never supplies one.
#
# Exit 0: a plan was emitted. Exit 10: one different live claim needs explicit
# user approval to replace. Exit 11: several live claims block takeover. Exit
# 20: identity or the target vocabulary could not be verified.
set -euo pipefail

usage() {
    echo "Usage: $0 --harness SLUG [--registry FILE] --runtime-family SLUG [--claim-model SLUG] --available-labels FILE --issue-labels FILE" >&2
    exit 20
}

harness=""
registry=""
runtime_family=""
claim_model=""
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
    --claim-model)
        claim_model="${2:-}"
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

[ -n "$harness" ] && [ -n "$runtime_family" ] && [ -r "$available_labels" ] && [ -r "$issue_labels" ] || usage

case "$runtime_family" in
*[!a-z0-9-]* | '')
    echo "claim identity: invalid runtime family '$runtime_family'" >&2
    exit 20
    ;;
esac
case "$claim_model" in
*[!a-z0-9-]*)
    echo "claim identity: invalid trusted claim model '$claim_model'" >&2
    exit 20
    ;;
esac

family=""
legacy_labels=""
if [ -n "$registry" ]; then
    [ -r "$registry" ] || {
        echo "claim identity: registry is unreadable" >&2
        exit 20
    }
    jq -e '
      def slug: type == "string" and test("^[a-z0-9]+(?:-[a-z0-9]+)*$");
      def alias: type == "string" and test("^agent:[a-z0-9]+(?:[a-z0-9._-]*[a-z0-9])?$");
      type == "object"
      and (.families | type == "array")
      and (.harnesses | type == "array")
      and ([.families[].slug] | all(slug) and length == (unique | length))
      and ([.harnesses[].slug] | all(slug) and length == (unique | length))
      and ([.families[].legacy_claim_labels[]?] | length == (unique | length))
      and all(.families[];
        type == "object" and (.slug | slug)
        and ((.legacy_claim_labels? // []) | type == "array" and all(.[]; alias)))
      and all(.harnesses[];
        type == "object" and (.slug | slug)
        and (.family_constraint | type == "object")
        and (.family_constraint.kind | . == "fixed" or . == "broker"))
    ' "$registry" >/dev/null || {
        echo "claim identity: registry or legacy alias grammar is invalid" >&2
        exit 20
    }
    constraint="$(jq -cer --arg harness "$harness" '.harnesses[] | select(.slug == $harness) | .family_constraint' "$registry")" || {
        echo "claim identity: unknown or ambiguous harness '$harness'" >&2
        exit 20
    }
    case "$(jq -r .kind <<<"$constraint")" in
    fixed)
        family="$(jq -er .family <<<"$constraint")" || {
            echo "claim identity: fixed harness '$harness' has no valid family" >&2
            exit 20
        }
        if [ "$runtime_family" != "$family" ]; then
            echo "claim identity: runtime family '$runtime_family' conflicts with fixed harness '$harness' ($family)" >&2
            exit 20
        fi
        ;;
    broker)
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
    if [ -n "$claim_model" ]; then
        jq -e --arg family "$family" --arg model "$claim_model" \
            '.families[] | select(.slug == $family) | .models[]? | select(.slug == $model)' \
            "$registry" >/dev/null || {
            echo "claim identity: trusted model '$claim_model' is not registered for family '$family'" >&2
            exit 20
        }
    fi
    legacy_labels="$(jq -r --arg family "$family" '.families[] | select(.slug == $family) | .legacy_claim_labels[]?' "$registry")"
else
    family="$runtime_family"
fi

target="claim:$family"
[ -z "$claim_model" ] || target="${target}:$claim_model"
same=""
conflicts=""
while IFS= read -r label; do
    case "$label" in
    claim:*)
        label_family="${label#claim:}"
        label_family="${label_family%%:*}"
        if [ "$label_family" != "$family" ]; then
            conflicts="${conflicts}${label}"$'\n'
        elif [ -n "$claim_model" ] && [ "$label" != "claim:$family:$claim_model" ]; then
            conflicts="${conflicts}${label}"$'\n'
        else
            same="$label"
        fi
        ;;
    agent:*)
        if [ -n "$claim_model" ]; then
            conflicts="${conflicts}${label}"$'\n'
        elif printf '%s\n' "$legacy_labels" | grep -Fqx "$label"; then
            same="$label"
        else
            conflicts="${conflicts}${label}"$'\n'
        fi
        ;;
    esac
done <"$issue_labels"

if [ -n "$same" ] && [ -z "$conflicts" ]; then
    printf 'family=%s\ntarget_label=%s\nexisting_label=%s\n' "$family" "$same" "$same"
    exit 0
fi

if [ -z "$same" ]; then
    if ! grep -Fqx "$target" "$available_labels"; then
        if [ -n "$claim_model" ]; then
            echo "claim identity: target lacks requested model claim '$target'" >&2
            exit 20
        fi
        selected_legacy=""
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            if grep -Fqx "$candidate" "$available_labels"; then
                selected_legacy="$candidate"
                break
            fi
        done <<<"$legacy_labels"
        if [ -z "$selected_legacy" ]; then
            echo "claim identity: target lacks '$target' and no trusted legacy label is provisioned" >&2
            exit 20
        fi
        target="$selected_legacy"
    fi
else
    target="$same"
fi

conflict_count="$(printf '%s' "$conflicts" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$conflict_count" -gt 0 ]; then
    printf 'family=%s\n' "$family"
    printf 'target_label=%s\nexisting_label=%s\nconflict_count=%s\n' "$target" "$same" "$conflict_count"
    while IFS= read -r conflict; do
        [ -n "$conflict" ] && printf 'conflict_label=%s\n' "$conflict"
    done <<<"$conflicts"
    if [ "$conflict_count" -gt 1 ]; then
        printf 'takeover=refused\n'
        exit 11
    fi
    printf 'takeover=requires-explicit-user-approval\n'
    exit 10
fi

printf 'family=%s\ntarget_label=%s\nexisting_label=%s\n' "$family" "$target" "$same"
