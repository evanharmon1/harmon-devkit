#!/usr/bin/env bash
# setup-github-labels.sh — idempotently create/update this repo's starter label
# set from the machine-readable taxonomy in label-registry.json.
#
# The MANIFEST is the source of truth, not this script: every label, color,
# description, and which families are opt-in comes out of
# `node scripts/label-registry-labels.mjs`. Nothing is hand-listed here, so the
# provisioned set and `task status`'s expected-label inventory cannot fork —
# those are the two consumers that read the manifest today. Add or retire a
# label in label-registry.json and re-run this; `task test:label-registry` and
# `task test:registry-drift` gate the bindings.
#
# The manifest carries more than those two need — `writers`, `lifecycle`,
# `exclusive`, `axis` — for consumers that are specified but NOT yet built: a
# triage skill (evanharmon1/harmon-devkit#455) and track-work's issue-metadata
# checker (#449), both of which read this file with a `gh label list` fallback.
# Until they land, editing those fields changes documentation and validation
# only; nothing else behaves differently.
#
# The manifest also records what this script deliberately does NOT provision:
# `tool-owned` values (release-please's `autorelease: *`, foreman's own
# `dispatched`/`ready-for-review` outputs) are created by their owning tool on
# demand, and `github-default` values (`bug`, `enhancement`, …) are seeded by
# GitHub itself. Both are documented, never provisioned, never deleted.
#
# The `layer:` and `domain:` families deliberately mirror the Layer and Domain
# single-select fields created by setup-github-issue-fields.sh (org) /
# setup-github-project.sh (personal account) — same vocabulary, so a label and a
# field value never disagree. Keep the manifest and the two field lists in step
# when you extend them.
#
# Labels are REPO-level in GitHub — there's no shared org label pool. Run this in
# each repo; org "default labels" (Settings → Repository, UI-only, no API) only
# seed NEW repos and don't touch existing ones. Non-destructive: `--force`
# creates-or-updates and it never deletes labels, so GitHub's defaults stay unless
# you prune them yourself. That cuts both ways: a repo seeded before the layer
# family became ui/logic/data/integration keeps its old `layer:frontend`,
# `layer:backend`, and `layer:infra` labels — re-map the issues and delete those
# three by hand if you want the one vocabulary.
#
# Usage: setup-github-labels.sh --repo <owner/repo> [--foreman]
# Needs: gh authed with repo write.
#
# --foreman additionally creates the arming axis — the `foreman:*` labels a
# human applies as inputs the foreman CLI reads but never auto-creates. The flag
# is passed by the Taskfile target when the repo uses foreman, keeping this
# script identical across repos that do and don't. The manifest marks that axis
# `arming`, which is what the renderer's `provision` / `foreman` split reads.
#
# NOTE: hits the live GitHub API, so it is not exercised by `task test:template`
# (guarded by shellcheck + shfmt only). Test it against a scratch repo.
set -euo pipefail

repo=""
foreman=0
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
labels_helper="$script_dir/label-registry-labels.mjs"
manifest="$script_dir/../label-registry.json"

for required in "$labels_helper" "$manifest"; do
    if [ ! -f "$required" ]; then
        echo "Required label-taxonomy asset not found: $required" >&2
        exit 1
    fi
done

# name|hex-color|description — one per line, rendered from label-registry.json.
# The renderer fails closed on GitHub's 50-char name and 100-char description
# limits and on any field that would corrupt this record stream, so the whole
# set is rejected before a partial run can reach GitHub.
#
# Two families in here are composed from agent-registry.json rather than listed
# in the label manifest: the model-centric `suggest:<family>` (advisory routing)
# and `claim:<family>` (live ownership), plus the `foreman:<adapter>` selectors
# under --foreman. The label renderer spawns agent-registry-labels.mjs for
# those, so the two manifests cannot fork (ADR 0005; test:registry-drift gates
# the chain). Only family-level labels are seeded — model-level
# `suggest:/claim:<family>:<model>` are created on demand.
#
# TRANSITION: this stops SEEDING the retired agent:* family but never deletes
# existing labels, so a repo that already has agent:claude-code keeps it and its
# claims keep working. The skill half of the cutover has shipped: the vendored
# /claim adds a claim:* label where the repo has that family and falls back to a
# live agent:* one only where provisioning has not migrated, while /wrap and
# release-claim.sh recognize BOTH families. That is exactly why this stays
# additive — seeding claim:* beside a surviving agent:* label strands no
# in-flight claim either way. What is left is a one-time, per-repo rename of the
# LIVE labels (`gh label edit agent:<harness> --name claim:<family>`, which
# preserves issue associations) — a human operator step in docs/CHECKLIST.md,
# deliberately not a permanent migration in this script. Until an operator runs
# it, a repo simply carries both families, which the readers above already
# tolerate.
#
# --foreman adds the arming axis: human inputs for foreman's label-mode arming
# (ponderousdev/foreman), plus foreman's own workflow-state protocol. Distinct
# from the `claim:*` family: a claim says which agent IS working an issue, a
# `foreman:*` selector arms it for dispatch. Adapter selectors are provisioned
# ONLY for adapters that exist in the pinned Foreman release — a selector with
# no production adapter can strand armed work (ADR 0005 D11) — which is why the
# renderer composes them from the agent registry instead of listing them.
#
# ONE render call, not two. `all` is `provision` followed by `foreman`, so
# concatenating two separate runs would produce the same lines — but the
# renderer's duplicate-name check runs per invocation, so a collision that
# spans the two halves (a bare value name that happens to equal a composed
# arming label) would pass both runs and then have `gh label create --force`
# silently overwrite the first record with the second.
label_mode=provision
if [ "$foreman" = 1 ]; then
    label_mode=all
fi
labels="$(node "$labels_helper" "$label_mode")"

printf '%s\n' "$labels" | while IFS='|' read -r name color desc; do
    [ -z "$name" ] && continue
    echo "==> label: $name"
    gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force
done

echo "==> Done — starter labels on $repo (existing labels left as-is)"
