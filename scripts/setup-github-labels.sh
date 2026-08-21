#!/usr/bin/env bash
# setup-github-labels.sh — idempotently create/update this repo's starter label
# set. The vocabulary is NOT listed here: every family, value, color, and
# description lives in label-registry.json (the machine-readable taxonomy
# manifest — see docs/project-management.md for the human-facing table, which is
# generated from the same file), and this script provisions whatever
# scripts/label-registry-render.mjs renders from it. The agent families
# (suggest:/claim:/foreman:<adapter>) come from agent-registry.json via the same
# renderer, so provisioning, docs, and both registries cannot fork
# (test-label-registry.sh and test-registry-drift.sh gate them together).
#
# Labels are REPO-level in GitHub — there's no shared org label pool. Run this in
# each repo; org "default labels" (Settings → Repository, UI-only, no API) only
# seed NEW repos and don't touch existing ones. Non-destructive: `--force`
# creates-or-updates and it never deletes labels, so GitHub's defaults stay
# unless you prune them yourself. That cuts both ways: a value renamed or
# retired in the manifest leaves its live label (and its issue associations)
# behind — re-map the issues and rename with `gh label edit <old> --name <new>`
# (association-preserving), or delete by hand, per the manifest's retirement
# note. The retired `agent:*` family is the standing example: never seeded,
# still recognized by the claim readers until an operator finishes the rename.
#
# Usage: setup-github-labels.sh --repo <owner/repo> [--foreman] [--release-please]
# Needs: gh authed with repo write; node (the renderer).
#
# --foreman additionally provisions the families the manifest gates on foreman
# (the arming selectors rendered from the agent registry, and foreman's own
# workflow-state protocol labels — human inputs the foreman CLI reads but never
# auto-creates). The flag is passed by the Taskfile target when the repo uses
# foreman, keeping this script identical across repos that do and don't.
#
# NOTE: hits the live GitHub API, so it is not exercised by `task test:template`
# (guarded by shellcheck + shfmt only). Test it against a scratch repo.
set -euo pipefail

repo=""
foreman=0
release_please=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        repo="${2:-}"
        shift 2
        ;;
    --foreman)
        foreman=1
        shift
        ;;
    --release-please)
        release_please=1
        shift
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$repo" ]; then
    echo "Usage: $0 --repo <owner/repo>" >&2
    exit 2
fi

for tool in gh node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
renderer="$script_dir/label-registry-render.mjs"
OUTPUT_FD=2
# shellcheck source=scripts/lib/output.sh
. "$script_dir/lib/output.sh"

action_banner setup "GitHub labels" "Registry-driven taxonomy with non-destructive updates"
kv "Repository" "$repo"

render_args=(labels)
if [ "$foreman" = 1 ]; then
    render_args+=(--foreman)
fi
if [ "$release_please" = 1 ]; then
    render_args+=(--release-please)
fi

# Render first, then provision: the renderer fails closed (bad manifest, name
# or description over GitHub's limits, registry color drift) BEFORE any label
# reaches GitHub, so a bad vocabulary never half-provisions.
labels="$(node "$renderer" "${render_args[@]}")"

while IFS='|' read -r name color desc; do
    [ -z "$name" ] && continue
    if gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force >/dev/null; then
        checkline ok "Label" "$name"
    else
        rc=$?
        checkline no "Label" "$name (exit $rc)"
        exit "$rc"
    fi
done < <(printf '%s\n' "$labels")

output_summary "Label provisioning"
output_done "Starter labels are ready on $repo (existing labels left as-is)"
