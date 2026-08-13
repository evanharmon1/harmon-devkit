#!/usr/bin/env bash
# setup-github-labels.sh — idempotently create/update this repo's starter label
# set (docs/project-management.md). Colors are grouped by family (concerns=purple,
# source=pink, workflow=orange, layer=blue, domain=yellow).
#
# The `layer:` and `domain:` families deliberately mirror the Layer and Domain
# single-select fields created by setup-github-issue-fields.sh (org) /
# setup-github-project.sh (personal account) — same vocabulary, so a label and a
# field value never disagree. Keep the three lists in step when you extend them.
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
# --foreman additionally creates the foreman arming labels (human inputs the
# foreman CLI reads but never auto-creates). The flag is passed by the
# Taskfile target when the repo uses foreman, keeping this script identical
# across repos that do and don't.
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
labels_helper="$script_dir/agent-registry-labels.mjs"

# name|hex-color|description — one per line. Color encodes the family.
labels="
sec|5319E7|Security concern
a11y|5319E7|Accessibility concern
perf|5319E7|Performance concern
tech-debt|5319E7|Technical debt
i18n|5319E7|Internationalization
l10n|5319E7|Localization
customer-request|EC4899|Requested by a customer
ai-generated|EC4899|Created or authored by an AI agent
needs-triage|E36209|Awaiting triage
needs-requirements|E36209|Requirements not yet defined
blocked|E36209|Blocked by a non-issue dependency (reason in a comment)
waiting|E36209|Waiting on an external party
needs-decision|E36209|Needs a decision before it can proceed
needs-response|E36209|Awaiting a response
needs-communication|E36209|An update needs to be communicated out
layer:ui|1D76DB|Components, styling, interaction, tokens, a11y. No data change
layer:logic|1D76DB|Business rules, handlers, calculation
layer:data|1D76DB|Schema, indexes, validators, migrations
layer:integration|1D76DB|External boundary: webhooks, API clients, credentials
domain:auth|FBCA04|Authentication and authorization
domain:billing|FBCA04|Billing and payments
domain:platform|FBCA04|CI, build, test infra, and tooling in this repo
rigor:light|D4C5F9|Dev Loop caps: trivial, low-blast-radius change
rigor:standard|D4C5F9|Dev Loop caps: the default budget
rigor:deep|D4C5F9|Dev Loop caps: security, migrations, irreversible paths
"

# The `rigor:*` family selects which round-cap tier in `.devflow.toml` an agent
# works an issue under (AGENTS.md, "Round caps are resolved, not stated here").
# It is an input an agent READS and never applies to itself. It is advisory,
# not an authenticated gate: nothing verifies who applied it, and GitHub's
# triage role can label an issue with no push access at all — so a budget can
# be retuned by someone who could not edit `.devflow.toml`. AGENTS.md requires
# any cap resolving below `default_rigor` to be stated in the PR body, which
# keeps a reduced budget visible to the human reviewer.
# Labels are multi-select and nothing stops two being applied, so AGENTS.md
# resolves per stage by taking the HIGHEST cap present: a conflict can only
# ever buy more review, never less, and no ranking of tier names is needed.

# The model-centric agent vocabulary — `suggest:<family>` (advisory routing) and
# `claim:<family>` (live ownership) — is rendered from the machine-readable agent
# registry (agent-registry.json), NOT hand-listed here, so this script and the
# registry cannot fork (ADR 0005; test:registry-drift gates the two together).
# The retired `agent:*` family is intentionally gone; only family-level labels
# are seeded (model-level `suggest:/claim:<family>:<model>` are created on demand).
#
# TRANSITION: this stops SEEDING agent:* but never deletes existing labels, so a
# repo that already has agent:claude-code keeps it and its claims keep working.
# The skill half of the cutover has shipped: the vendored /claim adds a claim:*
# label where the repo has that family and falls back to a live agent:* one only
# where provisioning has not migrated, while /wrap and release-claim.sh recognize
# BOTH families. That is exactly why this stays additive — seeding claim:* beside
# a surviving agent:* label strands no in-flight claim either way.
# What is left is a one-time, per-repo rename of the LIVE labels
# (`gh label edit agent:<harness> --name claim:<family>`, which preserves issue
# associations) — a human operator step in docs/CHECKLIST.md, deliberately not a
# permanent migration in this script. Until an operator runs it, a repo simply
# carries both families, which the readers above already tolerate.
labels="$labels
$(node "$labels_helper" suggest-claim)"

# Foreman arming labels (--foreman): human inputs for label-mode arming
# (ponderousdev/foreman). The `foreman:<adapter>` SELECTORS are rendered from the
# agent registry below — provisioned ONLY for adapters that exist in the pinned
# Foreman release (a selector with no production adapter can strand armed work,
# ADR 0005 D11). The labels here are foreman's own workflow-state protocol, not
# adapter selectors, so they are registry-independent. Distinct from the
# `claim:*` family above: a claim says which agent IS working an issue, a
# `foreman:*` selector arms it for dispatch. Colors/descriptions mirror
# ponderousdev/foreman's own labels.
foreman_labels="
foreman:approved|1D76DB|Arm with the repo default backend
foreman:hold|D93F0B|Exclude from foreman dispatch (always wins)
foreman:satisfied|0E8A16|Human override: treat this dependency as satisfied
foreman:external|BFDADC|External dependency: satisfied when closed as completed
"
if [ "$foreman" = 1 ]; then
    labels="$labels$foreman_labels
$(node "$labels_helper" foreman-adapters)"
fi

printf '%s\n' "$labels" | while IFS='|' read -r name color desc; do
    [ -z "$name" ] && continue
    echo "==> label: $name"
    gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force
done

echo "==> Done — starter labels on $repo (existing labels left as-is)"
