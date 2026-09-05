#!/usr/bin/env bash
# trusted-registry.sh — materialize agent-registry.json at a revision the
# change under review cannot alter.
#
# Sourced, never executed. Both the write broker and the cloud-review checker
# resolve a finder's entry through this, and neither accepts a registry FILE
# from its caller. That distinction is the whole point (#796 challenge round 3):
#
#   * The broker exists to make an integrator's GitHub writes mechanically
#     narrower than raw `gh api`. A caller-supplied registry path would let the
#     very party the broker constrains declare any trigger body or reviewer
#     login it liked and post it through the "narrow" door.
#   * The checker pins a finder profile into a cycle's state, and the readiness
#     gate then trusts that pin. A caller-supplied profile could name an
#     unrelated bot as the finder and pick a lenient verdict classifier, and so
#     satisfy a REQUIRED cycle without that finder ever reviewing the PR.
#
# So the caller names only a finder SLUG, and the revision is computed here.
# The revision is the merge base of the PR head with the REMOTE-TRACKING base
# branch — the same boundary AGENTS.md's "Self-modified policy is read from
# the merge base" draws for .devflow.toml, and scripts/devflow-policy.mjs
# --closure draws for the reader itself. A local `refs/heads/<base>` is
# deliberately NOT accepted: a branch can move a local ref, which would put the
# content back under the reviewed change's control.
#
# Every failure is a refusal. There is no fallback to the worktree copy: a
# trigger posted from an unverified registry is exactly what this exists to
# prevent.
#
# Requires: git, gh, jq (each already required by both callers).

# resolve_trusted_registry REPO PR DESTINATION
# Writes the trusted agent-registry.json to DESTINATION. Returns non-zero with
# a reason on stderr if it cannot.
resolve_trusted_registry() {
    local repo=$1 pr=$2 destination=$3
    local base_ref base_tracking merge_base

    local payload
    # The field is extracted with jq rather than `gh --jq`: this asks gh for
    # data and does the reading here, so the parse is this script's and not a
    # behaviour of whatever gh happens to do with a passthrough filter.
    payload="$(gh pr view "$pr" --repo "$repo" --json baseRefName 2>/dev/null)" || {
        printf 'trusted-registry: cannot read the base branch of %s#%s\n' "$repo" "$pr" >&2
        return 1
    }
    base_ref="$(printf '%s' "$payload" | jq -r '.baseRefName // empty' 2>/dev/null)" || base_ref=
    [ -n "$base_ref" ] || {
        printf 'trusted-registry: %s#%s reported no base branch\n' "$repo" "$pr" >&2
        return 1
    }

    base_tracking="refs/remotes/origin/${base_ref}"
    git rev-parse --verify --quiet "$base_tracking" >/dev/null || {
        printf 'trusted-registry: no %s in this checkout — fetch the base branch; a local refs/heads copy is not accepted, because the change under review could move it\n' \
            "$base_tracking" >&2
        return 1
    }

    merge_base="$(git merge-base "$base_tracking" HEAD 2>/dev/null)" || merge_base=
    [ -n "$merge_base" ] || {
        printf 'trusted-registry: HEAD shares no merge base with %s\n' "$base_tracking" >&2
        return 1
    }

    git show "${merge_base}:agent-registry.json" >"$destination" 2>/dev/null || {
        printf 'trusted-registry: no agent-registry.json at the merge base %s\n' "$merge_base" >&2
        return 1
    }
    [ -s "$destination" ] || {
        printf 'trusted-registry: the registry at merge base %s is empty\n' "$merge_base" >&2
        return 1
    }
    jq -e 'type == "object" and (.finders | type) == "array"' "$destination" >/dev/null 2>&1 || {
        printf 'trusted-registry: the registry at merge base %s is not a readable registry document\n' "$merge_base" >&2
        return 1
    }
}
