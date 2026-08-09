#!/usr/bin/env bash
# audit-foreman-adapters.sh — compare the registry's declared Foreman adapter
# roster (agent-registry.json → foreman_adapters[].source_file) against the
# backend scripts the PINNED Foreman release actually ships.
#
# This is the LIVE half of the drift contract and it needs the network (it reads
# ponderousdev/foreman over the GitHub API), so it is deliberately NOT part of
# `task verify` / `task ci` — those stay offline and reproducible. The offline
# gate (test-registry-drift.sh) checks everything derivable from the registry
# alone; this task is what catches the registry lagging a new Foreman release.
# Run it after bumping FOREMAN_VERSION, or on demand:  task foreman:audit-adapters
#
# Exit: 0 agree · 1 the rosters differ (remediation printed) · 2 could not read
# the pinned release (indeterminate — not a pass).
set -euo pipefail

registry="agent-registry.json"
foreman_version=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --foreman-version)
        [ "$#" -ge 2 ] || {
            echo "Missing value for $1" >&2
            exit 2
        }
        foreman_version="$2"
        shift 2
        ;;
    --registry)
        [ "$#" -ge 2 ] || {
            echo "Missing value for $1" >&2
            exit 2
        }
        registry="$2"
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$foreman_version" ]; then
    echo "Usage: $0 --foreman-version <x.y.z> [--registry <path>]" >&2
    exit 2
fi
for tool in gh jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Required tool not found: $tool" >&2
        exit 2
    }
done
[ -f "$registry" ] || {
    echo "registry not found: $registry" >&2
    exit 2
}

ref="v${foreman_version}"
# The backend adapters are hermetic *.sh scripts under this path in the Foreman
# source tree; a recursive tree read avoids paging the contents API.
tree_json="$(gh api "repos/ponderousdev/foreman/git/trees/${ref}?recursive=1" 2>/dev/null)" || {
    echo "could not read Foreman tree at ${ref} — check the tag exists and gh is authenticated (indeterminate, not a pass)" >&2
    exit 2
}

# A truncated tree is a PARTIAL listing: GitHub caps recursive Trees responses,
# so an adapter could be silently absent and we would wrongly flag a live
# registry entry as stale. Refuse to compare against an incomplete list.
if [ "$(printf '%s' "$tree_json" | jq -r '.truncated')" = "true" ]; then
    echo "Foreman tree at ${ref} was truncated by the GitHub API — cannot enumerate adapters completely (indeterminate, not a pass)" >&2
    exit 2
fi

# Foreman's loader globs backends/*.sh NON-recursively, so nested helpers
# (e.g. lib/claude-common.sh) are shared code, not adapters — exclude any
# path that still contains a slash after the prefix strip.
shipped="$(printf '%s' "$tree_json" |
    jq -r '.tree[].path
           | select(startswith("src/foreman/backends/") and endswith(".sh"))
           | ltrimstr("src/foreman/backends/")
           | select(contains("/") | not)' | sort -u)"

if [ -z "$shipped" ]; then
    echo "no *.sh adapters found under src/foreman/backends/ at ${ref} — the path may have moved upstream (indeterminate, not a pass)" >&2
    exit 2
fi

declared="$(jq -r '.foreman_adapters[].source_file' "$registry" | sort -u)"

only_foreman="$(comm -23 <(printf '%s\n' "$shipped") <(printf '%s\n' "$declared"))"
only_registry="$(comm -13 <(printf '%s\n' "$shipped") <(printf '%s\n' "$declared"))"

if [ -z "$only_foreman" ] && [ -z "$only_registry" ]; then
    echo "Foreman ${ref} adapters match agent-registry.json foreman_adapters:"
    printf '%s\n' "$shipped" | sed 's/^/  /'
    exit 0
fi

echo "DRIFT: registry foreman_adapters disagree with Foreman ${ref}." >&2
if [ -n "$only_foreman" ]; then
    echo "  shipped by Foreman ${ref} but NOT in the registry:" >&2
    printf '%s\n' "$only_foreman" | sed 's/^/    /' >&2
    echo "    -> add each as a foreman_adapters entry in ${registry} (set classification/provision_label deliberately)." >&2
fi
if [ -n "$only_registry" ]; then
    echo "  declared in the registry but NOT shipped by Foreman ${ref}:" >&2
    printf '%s\n' "$only_registry" | sed 's/^/    /' >&2
    echo "    -> remove the stale entry from ${registry}, or bump FOREMAN_VERSION to a release that ships it." >&2
fi
exit 1
