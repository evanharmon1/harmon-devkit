#!/usr/bin/env bash
# Resolve the ownership label for a claim from trusted runtime identity.
#
# The caller obtains --harness, --runtime-family, and any --claim-model from the execution host,
# never from an issue, PR, repository file, or label. The registry validates a
# host-attested family; it never supplies one.
#
# Exit 0: a plan was emitted. For project_management=none|linear, or for a
# GitHub target whose unverifiable label-less state the user explicitly approved,
# target_label=n/a makes the assignee and claim comment authoritative. Exit 10:
# one different live claim
# needs explicit user approval to replace. Exit 11: several live claims block
# takeover. Exit 20: identity, project mode, or required vocabulary could not be
# verified.
set -euo pipefail

usage() {
    echo "Usage: $0 --harness SLUG [--registry FILE] --runtime-family SLUG [--claim-model SLUG] [--allow-unlabeled-github] --project-management github|linear|none --available-labels FILE --issue-labels FILE" >&2
    exit 20
}

harness=""
registry=""
runtime_family=""
claim_model=""
allow_unlabeled_github=false
project_management=""
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
    --allow-unlabeled-github)
        allow_unlabeled_github=true
        shift
        ;;
    --project-management)
        project_management="${2:-}"
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

[ -n "$harness" ] && [ -n "$runtime_family" ] && [ -n "$project_management" ] && [ -r "$available_labels" ] && [ -r "$issue_labels" ] || usage

case "$project_management" in
github | linear | none) ;;
*)
    echo "claim identity: invalid or unverified project_management '$project_management'" >&2
    exit 20
    ;;
esac

case "$runtime_family" in
'' | *[!a-z0-9-]* | -* | *- | *--*)
    echo "claim identity: invalid runtime family '$runtime_family'" >&2
    exit 20
    ;;
esac
case "$claim_model" in
*[!a-z0-9-]* | -* | *- | *--*)
    echo "claim identity: invalid trusted claim model '$claim_model'" >&2
    exit 20
    ;;
esac

family=""
legacy_labels=""
legacy_labels_for_pre_field_registry() {
    case "$1" in
    claude) printf '%s\n' agent:claude-code ;;
    gpt) printf '%s\n' agent:codex ;;
    gemini) printf '%s\n' agent:gemini-cli ;;
    kimi) printf '%s\n' agent:kimi-k2 ;;
    qwen) printf '%s\n' agent:qwen-code ;;
    esac
}
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
    if [ "$(jq -r --arg family "$family" '.families[] | select(.slug == $family) | has("legacy_claim_labels")' "$registry")" = true ]; then
        legacy_labels="$(jq -r --arg family "$family" '.families[] | select(.slug == $family) | .legacy_claim_labels[]' "$registry")"
    else
        # The claim skill is deliberately released before registry/provisioning
        # migrations. Keep the finite pre-field aliases with the skill so that
        # a freshly synced resolver can still claim a legacy-only repository.
        legacy_labels="$(legacy_labels_for_pre_field_registry "$family")"
    fi
else
    family="$runtime_family"
    # A target old enough to lack the registry may still expose the finite
    # pre-migration ownership vocabulary. Runtime family remains host-attested;
    # this table maps only that trusted family to its historical label.
    legacy_labels="$(legacy_labels_for_pre_field_registry "$family")"
fi

target="claim:$family"
[ -z "$claim_model" ] || target="${target}:$claim_model"
same=""
family_marker=""
conflicts=""
while IFS= read -r label; do
    case "$label" in
    claim:*)
        if [[ ! "$label" =~ ^claim:[a-z0-9]+(-[a-z0-9]+)*(:[a-z0-9]+(-[a-z0-9]+)*)?$ ]]; then
            echo "claim identity: malformed ownership label '$label'" >&2
            exit 20
        fi
        label_family="${label#claim:}"
        label_family="${label_family%%:*}"
        if [ "$label_family" != "$family" ]; then
            conflicts="${conflicts}${label}"$'\n'
        elif [ -n "$claim_model" ]; then
            if [ "$label" = "claim:$family" ]; then
                family_marker="$label"
            elif [ "$label" = "claim:$family:$claim_model" ]; then
                same="$label"
            else
                conflicts="${conflicts}${label}"$'\n'
            fi
        else
            same="$label"
        fi
        ;;
    agent:*)
        if [[ ! "$label" =~ ^agent:[a-z0-9]+([a-z0-9._-]*[a-z0-9])?$ ]]; then
            echo "claim identity: malformed ownership label '$label'" >&2
            exit 20
        fi
        if printf '%s\n' "$legacy_labels" | grep -Fqx "$label"; then
            if [ -z "$claim_model" ]; then
                same="$label"
            else
                # During migration, a registry-declared legacy alias is the
                # durable family marker for a model refinement too.
                family_marker="$label"
            fi
        elif [ -n "$claim_model" ]; then
            conflicts="${conflicts}${label}"$'\n'
        else
            conflicts="${conflicts}${label}"$'\n'
        fi
        ;;
    esac
done <"$issue_labels"

if [ -n "$claim_model" ] && [ -z "$family_marker" ]; then
    echo "claim identity: model claim '$target' requires the existing family marker 'claim:$family'" >&2
    exit 20
fi

if [ -n "$same" ] && [ -z "$conflicts" ]; then
    if [ -n "$claim_model" ]; then
        printf 'family=%s\ntarget_label=%s\nexisting_label=%s\nfamily_label=%s\nmodel_label=%s\n' \
            "$family" "$same" "$same" "$family_marker" "$same"
    else
        printf 'family=%s\ntarget_label=%s\nexisting_label=%s\nfamily_label=%s\nmodel_label=n/a\n' \
            "$family" "$same" "$same" "$same"
    fi
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
            case "$project_management" in
            github)
                if [ "$allow_unlabeled_github" = true ]; then
                    target="n/a"
                else
                    echo "claim identity: target lacks '$target' and no trusted legacy label is provisioned; explicit approval is required for an unlabeled GitHub claim" >&2
                    exit 20
                fi
                ;;
            linear | none)
                target="n/a"
                ;;
            esac
        else
            target="$selected_legacy"
        fi
    fi
else
    target="$same"
fi

conflict_count="$(printf '%s' "$conflicts" | sed '/^$/d' | wc -l | tr -d ' ')"
family_target="$target"
model_target="n/a"
if [ -n "$claim_model" ]; then
    family_target="$family_marker"
    model_target="$target"
fi
if [ "$conflict_count" -gt 0 ]; then
    printf 'family=%s\n' "$family"
    printf 'target_label=%s\nexisting_label=%s\nfamily_label=%s\nmodel_label=%s\nconflict_count=%s\n' \
        "$target" "$same" "$family_target" "$model_target" "$conflict_count"
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

printf 'family=%s\ntarget_label=%s\nexisting_label=%s\nfamily_label=%s\nmodel_label=%s\n' \
    "$family" "$target" "$same" "$family_target" "$model_target"
