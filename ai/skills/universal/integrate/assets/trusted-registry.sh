#!/usr/bin/env bash
# trusted-registry.sh — materialize agent-registry.json at a revision the
# change under review cannot alter.
#
# Sourced, never executed. Both the write broker and the cloud-review checker
# resolve a finder's entry through this, and neither accepts a registry FILE
# from its caller. That distinction is the whole point (#804, trust constraints
# 1–3 from #796 challenge rounds 3 and 5):
#
#   C1: A caller-supplied --registry/--profile FILE hands the party the
#       broker constrains exactly the authority it removes: an integrator that
#       can write a temp file could declare any trigger body, reviewer login,
#       trusted actor and verdict classifier.
#   C2: Resolving the registry at the merge base via a local tracking ref
#       (refs/remotes/origin/<base>) is not a boundary: git update-ref can
#       move it, and the merge base becomes the PR head.
#   C3: Pinning the resolved profile into the cycle's own state file moves
#       the problem: the state is caller-writable, and the readiness gate
#       then takes the actor id from it.
#
# So the caller names only a finder SLUG. The revision is the PR's base
# commit, content-addressed from GitHub via `gh pr view --json baseRefOid` —
# the same boundary AGENTS.md's "Self-modified policy is read from the merge
# base" draws, but resolved from GitHub rather than a local ref. The registry
# is then read at that commit through the GitHub API, never from the worktree
# or a local object.
#
# Every failure is a refusal. There is no fallback to the worktree copy: a
# trigger posted from an unverified registry is exactly what this exists to
# prevent.
#
# Requires: gh, jq (each already required by both callers).

# resolve_trusted_registry REPO PR DESTINATION
# Writes the trusted agent-registry.json to DESTINATION. Returns non-zero with
# a reason on stderr if it cannot.
resolve_trusted_registry() {
    local repo=$1 pr=$2 destination=$3
    local base_oid registry_b64

    base_oid="$(gh pr view "$pr" --repo "$repo" --json baseRefOid --jq .baseRefOid 2>/dev/null)" || {
        printf 'trusted-registry: cannot read baseRefOid of %s#%s\n' "$repo" "$pr" >&2
        return 1
    }
    [ -n "$base_oid" ] || {
        printf 'trusted-registry: %s#%s reported no baseRefOid\n' "$repo" "$pr" >&2
        return 1
    }
    printf '%s' "$base_oid" | grep -Eq '^[0-9a-f]{40}$' || {
        printf 'trusted-registry: %s#%s baseRefOid is not a 40-hex SHA: %s\n' \
            "$repo" "$pr" "$base_oid" >&2
        return 1
    }

    registry_b64="$(gh api "repos/$repo/contents/agent-registry.json?ref=$base_oid" \
        --jq .content 2>/dev/null)" || {
        printf 'trusted-registry: cannot read agent-registry.json at %s in %s\n' \
            "$base_oid" "$repo" >&2
        return 1
    }
    [ -n "$registry_b64" ] || {
        printf 'trusted-registry: agent-registry.json is empty at %s in %s\n' \
            "$base_oid" "$repo" >&2
        return 1
    }

    printf '%s' "$registry_b64" | base64 -d >"$destination" 2>/dev/null || {
        printf 'trusted-registry: cannot decode agent-registry.json at %s\n' "$base_oid" >&2
        return 1
    }
    [ -s "$destination" ] || {
        printf 'trusted-registry: decoded registry at %s is empty\n' "$base_oid" >&2
        return 1
    }
    jq -e 'type == "object" and (.finders | type) == "array"' "$destination" >/dev/null 2>&1 || {
        printf 'trusted-registry: the registry at %s is not a readable registry document\n' \
            "$base_oid" >&2
        return 1
    }
}

# resolve_finder_profile REGISTRY_PATH SLUG DESTINATION
# Extracts a single finder entry from a trusted registry and writes it to
# DESTINATION. Returns non-zero if the slug is absent, ambiguous, or missing
# required fields for a cloud finder.
resolve_finder_profile() {
    local registry=$1 slug=$2 destination=$3
    local count

    [ -f "$registry" ] || {
        printf 'finder-profile: registry file does not exist: %s\n' "$registry" >&2
        return 1
    }

    count="$(jq --arg slug "$slug" '[.finders[] | select(.slug == $slug)] | length' "$registry")" || {
        printf 'finder-profile: cannot parse registry\n' >&2
        return 1
    }
    [ "$count" -eq 1 ] || {
        printf 'finder-profile: slug "%s" matched %s entries (expected 1)\n' "$slug" "$count" >&2
        return 1
    }

    jq --arg slug "$slug" '.finders[] | select(.slug == $slug)' "$registry" >"$destination" || {
        printf 'finder-profile: extraction failed for slug "%s"\n' "$slug" >&2
        return 1
    }

    jq -e '
        (.trusted_actor_id | type) == "string" and (.trusted_actor_id | length) > 0 and
        (.trusted_actor_login | type) == "string" and (.trusted_actor_login | length) > 0 and
        (.collection.protocol | type) == "string" and
        (.collection.trigger.mechanism | type) == "string"
    ' "$destination" >/dev/null 2>&1 || {
        printf 'finder-profile: slug "%s" is missing required fields (trusted_actor_id, trusted_actor_login, collection.protocol, collection.trigger.mechanism)\n' \
            "$slug" >&2
        return 1
    }

    local mechanism
    mechanism="$(jq -r '.collection.trigger.mechanism' "$destination")"
    case "$mechanism" in
    review-comment)
        jq -e '(.collection.trigger.body | type) == "string" and (.collection.trigger.body | length) > 0' \
            "$destination" >/dev/null 2>&1 || {
            printf 'finder-profile: review-comment finder "%s" has no trigger body\n' "$slug" >&2
            return 1
        }
        ;;
    requested-reviewer)
        jq -e '(.collection.trigger.reviewer_login | type) == "string" and (.collection.trigger.reviewer_login | length) > 0' \
            "$destination" >/dev/null 2>&1 || {
            printf 'finder-profile: requested-reviewer finder "%s" has no reviewer_login\n' "$slug" >&2
            return 1
        }
        ;;
    *)
        printf 'finder-profile: unknown trigger mechanism "%s" for slug "%s"\n' "$mechanism" "$slug" >&2
        return 1
        ;;
    esac
}
