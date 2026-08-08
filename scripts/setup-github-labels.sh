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

if ! command -v gh >/dev/null 2>&1; then
    echo "Required tool not found: gh" >&2
    exit 1
fi

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
agent:claude-code|006B75|Claimed by Claude Code
agent:codex|006B75|Claimed by Codex
agent:gemini-cli|006B75|Claimed by Gemini CLI
agent:qwen-code|006B75|Claimed by Qwen Code
agent:deepseek|006B75|Claimed by DeepSeek
agent:kimi-k2|006B75|Claimed by Kimi K2
agent:glm|006B75|Claimed by GLM
agent:github-copilot|006B75|Claimed by GitHub Copilot
"

# Foreman arming labels (--foreman): human inputs for label-mode arming
# (ponderousdev/foreman). `foreman:<backend>` selects the backend and implies
# approval; the rest are foreman's own workflow-state protocol. Distinct from
# the `agent:*` claim family above: a claim says which agent IS working an
# issue, a `foreman:*` selector arms it for dispatch. Colors/descriptions
# mirror ponderousdev/foreman's own labels.
foreman_labels="
foreman:approved|1D76DB|Arm with the repo default backend
foreman:claude|1D76DB|Arm this issue for foreman dispatch with the claude backend
foreman:codex|1D76DB|Arm this issue for foreman dispatch with the codex backend
foreman:gemini|1D76DB|Arm this issue for foreman dispatch with the gemini backend
foreman:deepseek|1D76DB|Arm this issue for foreman dispatch with the deepseek backend
foreman:glm|1D76DB|Arm this issue for foreman dispatch with the glm backend
foreman:kimi|1D76DB|Arm this issue for foreman dispatch with the kimi backend
foreman:copilot|1D76DB|Arm this issue for foreman dispatch with the copilot backend
foreman:hold|D93F0B|Exclude from foreman dispatch (always wins)
foreman:satisfied|0E8A16|Human override: treat this dependency as satisfied
foreman:external|BFDADC|External dependency: satisfied when closed as completed
"
if [ "$foreman" = 1 ]; then
    labels="$labels$foreman_labels"
fi

printf '%s\n' "$labels" | while IFS='|' read -r name color desc; do
    [ -z "$name" ] && continue
    echo "==> label: $name"
    gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force
done

echo "==> Done — starter labels on $repo (existing labels left as-is)"
