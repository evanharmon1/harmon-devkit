#!/usr/bin/env bash
# test-label-registry.sh — the OFFLINE gate that binds label provisioning, the
# docs taxonomy table, and the status inventory to the machine-readable label
# registry (label-registry.json). Runs in `task verify` / `task ci`, next to
# test-registry-drift.sh (which owns the agent-registry bindings).
#
#   1. schema      — the manifest validates (validate-label-registry.mjs:
#                    structure, per-value overrides, arming confinement,
#                    GitHub's 50/100-char limits).
#   2. cross-file  — the rigor family's values match .devflow.toml's [rigor.*]
#                    levels, and the foreman protocol per-value colors
#                    reproduce the four upstream foreman label colors.
#   3. lockfile    — TEMPLATE repo only: the rendered provisioned set equals
#                    the reviewed expectation frozen below (the pre-manifest
#                    inline vocabulary plus the hand-seeded families) plus the
#                    live agent-registry render. A vocabulary change edits the
#                    manifest AND this lockfile in one PR — that is the point:
#                    the provisioned set changes deliberately or not at all.
#   4. provisioning— setup-github-labels.sh, run with `gh` stubbed, provisions
#                    exactly the renderer's set (no hand-list can fork).
#   5. status      — scripts/status.sh reads its expected-label inventory from
#                    the same renderer (no stale heredoc parse).
#   6. docs        — the taxonomy table between the label-taxonomy markers in
#                    docs/project-management.md is exactly `docs-table` output,
#                    per layer (the manifests legitimately diverge, so each
#                    layer renders its own expectation).
#
# TEMPLATE repository (template/label-registry.json exists): both layers are
# checked. GENERATED repository: the local manifest, script, status, and — when
# the render profile ships it — the docs table are checked; profile-dependent
# files are skipped loudly, like test-registry-drift.sh does.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fails=0
fail() {
    echo "TEST FAIL: $*" >&2
    fails=$((fails + 1))
}

for required in label-registry.json label-registry.schema.json \
    scripts/validate-label-registry.mjs scripts/label-registry-render.mjs \
    agent-registry.json scripts/agent-registry-labels.mjs; do
    [ -f "$required" ] || {
        echo "TEST FAIL: missing required label-registry asset: $required" >&2
        exit 1
    }
done
for tool in node jq python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "TEST FAIL: $tool is required to check the label registry" >&2
        exit 1
    }
done

# ── 0. read-only authoring guidance ─────────────────────────────────────────
# The support interpreter is the single discovery surface used by Track Work.
# Exercise both manifest and no-manifest modes here, where the registry fixtures
# already live, rather than duplicating a second label parser in its consumer.
guidance_helper="ai/skills/universal/label-registry-support/assets/label-registry.sh"
[ -x "$guidance_helper" ] || {
    echo "TEST FAIL: missing executable label guidance helper: $guidance_helper" >&2
    exit 1
}
guidance_tmp="$(mktemp -d)"
guidance_bin="$guidance_tmp/bin"
mkdir -p "$guidance_bin"
cat >"$guidance_bin/gh" <<'STUB'
#!/bin/sh
case "${1:-} ${2:-}" in
"label list")
    printf '%s\n' '[
      {"name":"area:live","description":"Live area description"},
      {"name":"area:literal","description":"Windows path C:\\temp and\ttab"},
      {"name":"claim:gpt","description":"Claimed by GPT"},
      {"name":"suggest:gpt","description":"Suggested for GPT"},
      {"name":"agent:legacy","description":"Legacy agent claim"},
      {"name":"foreman:claude","description":"Dispatch control"},
      {"name":"Rigor:deep","description":"Execution budget"},
      {"name":"tier:frontier","description":"Model routing"},
      {"name":"method:plan","description":"Execution topology"},
      {"name":"type:patch","description":"Foreman override"},
      {"name":"autorelease: pending","description":"Release automation state"}
    ]'
    ;;
*) exit 97 ;;
esac
STUB
chmod +x "$guidance_bin/gh"

echo "==> guidance: manifest records include descriptions and compact family purpose only"
manifest_guidance="$("$guidance_helper" guidance label-registry.json testowner/testrepo)" ||
    fail "manifest-backed guidance should render"
printf '%s\n' "$manifest_guidance" |
    jq -se 'any(.[]; . == {record: "guidance", label: "area:track-work", description: "The track-work skill: issue authoring standards and PR/commit linkage; claims are session-flow", family: "area", purpose: "Codebase subsystem the work lives in (solution space); at most one per issue."})' >/dev/null ||
    fail "manifest-backed guidance should include value description and family purpose"
if printf '%s\n' "$manifest_guidance" |
    jq -e 'select(.label | test("^(claim|suggest|agent|foreman|rigor|tier|method):"; "i"))' >/dev/null; then
    fail "guidance must exclude claim, suggestion, legacy-agent, Foreman, and execution controls"
fi
printf '%s\n' "$manifest_guidance" |
    jq -se 'all(.[]; keys == ["description", "family", "label", "purpose", "record"] and .record == "guidance")' >/dev/null ||
    fail "guidance records must contain only label, description, family, purpose, and record"

echo "==> guidance: control namespaces stay excluded when family identifiers change"
jq '(.families[] | select(.family == "rigor")).family = "effort"' \
    label-registry.json >"$guidance_tmp/renamed-family.json"
renamed_guidance="$("$guidance_helper" guidance "$guidance_tmp/renamed-family.json" testowner/testrepo)" ||
    fail "guidance should render a schema-valid renamed family"
if printf '%s\n' "$renamed_guidance" |
    jq -e 'select(.label | test("^rigor:"; "i"))' >/dev/null; then
    fail "guidance must exclude controls by rendered namespace, not family identifier"
fi

echo "==> guidance: semantic execution axes stay excluded under custom prefixes"
jq '(.families[] | select(.family == "rigor"))
      |= (.family = "effort" | .prefix = "effort")' \
    label-registry.json >"$guidance_tmp/custom-prefix-control.json"
custom_prefix_guidance="$($guidance_helper guidance "$guidance_tmp/custom-prefix-control.json" testowner/testrepo)" ||
    fail "guidance should render a schema-valid custom-prefix control family"
if printf '%s\n' "$custom_prefix_guidance" |
    jq -e 'select(.label | test("^effort:"; "i"))' >/dev/null; then
    fail "guidance must exclude authoring-forbidden semantic axes under custom prefixes"
fi

echo "==> guidance: delegated agent-registry families remain on the shared exclusion boundary"
for control in claim:gpt suggest:gpt foreman:claude; do
    if printf '%s\n' "$manifest_guidance" |
        jq -e --arg control "$control" 'select(.label == $control)' >/dev/null; then
        fail "guidance must not surface delegated control $control"
    fi
done

echo "==> guidance: no manifest uses live names and descriptions without inferred family policy"
fallback_guidance="$(PATH="$guidance_bin:$PATH" "$guidance_helper" guidance "$guidance_tmp/missing.json" testowner/testrepo)" ||
    fail "no-manifest guidance should use the bounded live-label fallback"
printf '%s\n' "$fallback_guidance" |
    jq -se 'any(.[]; . == {record: "guidance", label: "area:live", description: "Live area description", family: null, purpose: null})' >/dev/null ||
    fail "no-manifest guidance should retain safe live names and descriptions, case-insensitively"
printf '%s\n' "$fallback_guidance" |
    jq -se 'any(.[]; . == {record: "guidance", label: "area:literal", description: "Windows path C:\\temp and\ttab", family: null, purpose: null})' >/dev/null ||
    fail "no-manifest guidance should preserve literal backslashes and tabs in live descriptions"
printf '%s\n' "$fallback_guidance" |
    jq -se 'length == 2 and all(.[]; .label == "area:live" or .label == "area:literal")' >/dev/null ||
    fail "no-manifest guidance should exclude every known stable control namespace"

echo "==> guidance: open-value authoring families combine live labels with manifest purpose"
jq '(.families[] | select(.family == "area"))
      |= (.open_values = true | .placeholder = "area:<value>" | .values = [])' \
    label-registry.json >"$guidance_tmp/open-area.json"
open_guidance="$(PATH="$guidance_bin:$PATH" "$guidance_helper" guidance "$guidance_tmp/open-area.json" testowner/testrepo)" ||
    fail "open-value guidance should make one bounded live-label read"
printf '%s\n' "$open_guidance" |
    jq -se 'any(.[]; . == {record: "guidance", label: "area:live", description: "Live area description", family: "area", purpose: "Codebase subsystem the work lives in (solution space); at most one per issue."})' >/dev/null ||
    fail "open-value guidance should combine live labels with manifest family purpose"
printf '%s\n' "$open_guidance" |
    jq -se 'all(.[]; .family != "area" or (.label == "area:live" or .label == "area:literal"))' >/dev/null ||
    fail "open-value guidance should not invent unlisted concrete labels"

echo "==> guidance: schema-valid prose with delimiters stays decodable"
jq '(.families[] | select(.family == "area").purpose) = "Solution | subsystem\nwith a second line"
    | (.families[] | select(.family == "area").values[] | select(.value == "track-work").description) = "Path C:\\temp | tab\t"
    | (.families[] | select(.family == "foreman").purpose) = "Excluded | control\rtext"' \
    label-registry.json >"$guidance_tmp/delimited-prose.json"
delimited_guidance="$($guidance_helper guidance "$guidance_tmp/delimited-prose.json" testowner/testrepo)" ||
    fail "schema-valid prose must not make manifest guidance unusable"
printf '%s\n' "$delimited_guidance" |
    jq -se 'any(.[]; .label == "area:track-work"
        and .description == "Path C:\\temp | tab\t"
        and .purpose == "Solution | subsystem\nwith a second line")' >/dev/null ||
    fail "JSON Lines guidance must preserve selected delimiter prose exactly"

echo "==> guidance: missing command arguments keep the usage exit contract"
_rc=0
"$guidance_helper" >"$guidance_tmp/out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] ||
    fail "guidance helper with no arguments should exit 2"

echo "==> guidance: a malformed manifest is indeterminate, not a live fallback"
printf '%s\n' '{"schema_version":999}' >"$guidance_tmp/malformed.json"
if "$guidance_helper" guidance "$guidance_tmp/malformed.json" testowner/testrepo >"$guidance_tmp/out" 2>&1; then
    fail "malformed manifest guidance should fail closed"
fi
grep -q 'manifest is invalid or unsupported' "$guidance_tmp/out" ||
    fail "malformed manifest guidance should name the indeterminate manifest"

echo "==> guidance: an unavailable manifest is indeterminate, not a live fallback"
ln -s "$guidance_tmp/no-target.json" "$guidance_tmp/unavailable.json"
if PATH="$guidance_bin:$PATH" "$guidance_helper" guidance "$guidance_tmp/unavailable.json" testowner/testrepo >"$guidance_tmp/out" 2>&1; then
    fail "unavailable manifest guidance should fail closed"
fi
grep -q 'manifest is not a readable regular file' "$guidance_tmp/out" ||
    fail "unavailable manifest guidance should name the indeterminate manifest"

template_mode=0
[ -f template/label-registry.json ] && template_mode=1

# ── 1. schema + semantic invariants ────────────────────────────────────────
node scripts/validate-label-registry.mjs label-registry.json ||
    fail "label-registry.json fails validation — fix it before the bindings can be trusted"
if [ "$template_mode" = 1 ]; then
    node scripts/validate-label-registry.mjs template/label-registry.json template/label-registry.schema.json ||
        fail "template/label-registry.json fails validation against its schema twin"
fi

# ── 1b. validator mutation tests ───────────────────────────────────────────
# The validator is only ever green against the two checked-in manifests above,
# so exercise its rejection branches the way test-agent-registry.sh does: a
# regression that silently accepts a broken manifest must fail here, not at
# provisioning time.
mutation_tmp="$(mktemp -d)"
trap 'rm -rf "$mutation_tmp" "$guidance_tmp"' EXIT
mutated_manifest="$mutation_tmp/label-registry.json"
cp label-registry.schema.json "$mutation_tmp/label-registry.schema.json"

rejects() {
    local description="$1" mutation="$2" expected="$3" output
    if ! node --input-type=module - label-registry.json "$mutated_manifest" "$mutation" <<'NODE'; then
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath, mutation] = process.argv.slice(2)
const manifest = JSON.parse(await readFile(inputPath, 'utf8'))
const family = (id) => manifest.families.find((entry) => entry.family === id)

switch (mutation) {
  case 'duplicate-family-id':
    manifest.families.push(structuredClone(manifest.families[0]))
    break
  case 'arming-outside-foreman':
    family('concern').arming = true
    break
  case 'provisioned-missing-description':
    delete family('concern').values[0].description
    break
  case 'agent-registry-with-values':
    family('suggest').values.push({ value: 'rogue', description: 'x', color: 'ABCDEF' })
    break
  case 'tool-owned-provisioned':
    family('suggest-model').provision = true
    break
  case 'cross-family-collision':
    family('provenance').values.push({ value: 'sec', description: 'collides', color: 'ABCDEF' })
    break
  case 'registry-family-without-color':
    delete family('suggest').color
    break
  case 'overlong-description':
    family('concern').values[0].description = 'X'.repeat(101)
    break
  case 'per-value-provision-true':
    family('work-type').values[0].provision = true
    break
  case 'closed-family-without-values':
    family('concern').values = []
    break
  default:
    throw new Error(`unknown mutation: ${mutation}`)
}

await writeFile(outputPath, `${JSON.stringify(manifest, null, 2)}\n`)
NODE
        fail "could not build mutation: $description"
        return
    fi
    if output="$(node scripts/validate-label-registry.mjs "$mutated_manifest" 2>&1)"; then
        fail "validator accepted mutation: $description"
        return
    fi
    case "$output" in
    *"$expected"*) ;;
    *) fail "$description failed for the wrong reason: $output" ;;
    esac
}

rejects "duplicate family ids" 'duplicate-family-id' 'duplicate family id'
rejects "arming outside the foreman namespace" 'arming-outside-foreman' \
    'arming outside the foreman:* namespace'
rejects "a provisioned value with no description" 'provisioned-missing-description' \
    'provisioned labels need a description'
rejects "inline values on an agent-registry family" 'agent-registry-with-values' \
    'values array must be empty'
rejects "a provisioned tool-owned family" 'tool-owned-provisioned' \
    'provisioning must leave them alone'
rejects "a name collision across families" 'cross-family-collision' \
    'already provisioned by family'
rejects "an agent-registry family without a color" 'registry-family-without-color' \
    'need a color'
rejects "a description over GitHub's 100-char limit" 'overlong-description' \
    'must contain at most 100 character(s)'
rejects "a per-value provision switched on" 'per-value-provision-true' \
    'must equal false'
rejects "a closed inline family with no values" 'closed-family-without-values' \
    'closed inline family'

# ── 2. cross-file checks ───────────────────────────────────────────────────
# rigor values ↔ .devflow.toml levels: the label selects a [rigor.*] table, so
# a value with no table (or a table with no label) strands one side.
check_rigor() {
    local manifest="$1" devflow="$2"
    [ -f "$devflow" ] || {
        echo "note: $devflow not present — skipping the rigor cross-check for $manifest" >&2
        return 0
    }
    local want got
    # tomllib, not a line regex: `[rigor.light] # comment` and quoted keys are
    # valid TOML that test-devflow-config.sh accepts, and this check must not
    # constrain syntax it does not own.
    want="$(python3 -c 'import sys, tomllib
print("\n".join(sorted((tomllib.load(open(sys.argv[1], "rb")).get("rigor") or {}).keys())))' "$devflow" | sed '/^$/d' | sort)"
    got="$(jq -r '.families[]
        | select(.family == "rigor" and .provision == true and .retired != true)
        | .values[] | select(.provision != false and .retired != true) | .value' "$manifest" | sort)"
    [ "$want" = "$got" ] ||
        fail "$manifest rigor values [$(echo "$got" | tr '\n' ' ')] != $devflow levels [$(echo "$want" | tr '\n' ' ')] — the label must select an existing round-cap table"
}
check_rigor label-registry.json .devflow.toml
[ "$template_mode" = 1 ] && check_rigor template/label-registry.json template/.devflow.toml

# The four foreman protocol labels ship four different colors upstream
# (ponderousdev/foreman); the per-value color overrides exist to reproduce
# them, so pin the mapping — a family-level color here would repaint the
# protocol on the next provisioning run.
check_foreman_colors() {
    local manifest="$1" got
    got="$(jq -r '.families[] | select(.family == "foreman-protocol") | .values[] | "\(.value)=\(.color)"' "$manifest" | sort | tr '\n' ' ')"
    local want="approved=1D76DB external=BFDADC hold=D93F0B satisfied=0E8A16 "
    [ "$got" = "$want" ] ||
        fail "$manifest foreman-protocol colors [$got] != upstream foreman colors [$want]"
}
check_foreman_colors label-registry.json
[ "$template_mode" = 1 ] && check_foreman_colors template/label-registry.json

# ── 3. migration lockfile (template repo only) ─────────────────────────────
# The reviewed provisioned set per layer: the pre-manifest inline vocabulary,
# plus (root) the families hand-seeded on 2026-08-13 with their exact
# names/colors, plus the work-type labels the issue forms apply (#852). The
# agent families are NOT frozen here — they render live from agent-registry.json
# (test-registry-drift.sh gates that renderer), so a registry change does not
# invalidate this lockfile.
shared_inline="sec|5319E7|Security concern
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
bug|D73A4A|Something isn't working
feature|A2EEEF|New feature or request
task|6E7781|General work: maintenance, chores, cleanup
research|0E7C86|Produces a decision or written answer, not a code change
layer:ui|1D76DB|Components, styling, interaction, tokens, a11y. No data change
layer:logic|1D76DB|Business rules, handlers, calculation
layer:data|1D76DB|Schema, indexes, validators, migrations
layer:integration|1D76DB|External boundary: webhooks, API clients, credentials
rigor:light|D4C5F9|Dev Loop caps: trivial, low-blast-radius change
rigor:standard|D4C5F9|Dev Loop caps: the default budget
rigor:deep|D4C5F9|Dev Loop caps: security, migrations, irreversible paths
tier:local|7057FF|Model tier: self-hosted endpoint first; may escalate to economy
tier:economy|7057FF|Model tier: cheapest qualified hosted model first; escalation allowed
tier:standard|7057FF|Model tier: reliable general-purpose coding model first
tier:frontier|7057FF|Model tier: opus-class heavyweights; no warm-up on weaker models
tier:apex|7057FF|Model tier: mythos-class leading edge (fable, sol)
tier:adaptive|7057FF|Model tier: cheap preflight classifies, then chooses or escalates
method:oneshot|BF3989|Execution: single agent, no separate plan phase
method:plan|BF3989|Execution: agent plans then implements; no human plan gate
method:plan-approved|BF3989|Execution: plan requires human approval before implementation
method:orchestrate|BF3989|Execution: conductor session drives subagents, possibly across related issues
method:council|BF3989|Execution: N independent implementations; judged, best or synthesis wins
method:human-led|BF3989|Execution: human owns central decisions; AI does bounded pieces"
root_only_inline="domain:template|FBCA04|Generating a new repo from the template — the copier copy journey
domain:standardization|FBCA04|Keeping existing repos current — copier update, drift audits, migrations, adoption
domain:dev-loop|FBCA04|The daily developer workflow: gates, hooks, tasks, worktrees, review stages
domain:agent-workflow|FBCA04|AI-delegated work: foreman dispatch, claims, skills, Claude Actions
domain:project-tracking|FBCA04|Issues, labels, boards, and the PM strategy
domain:auth|FBCA04|Toolchain credentials and auth: gh, Claude, Codex, 1Password, tokens
domain:delivery|FBCA04|Releases and versioning: release-please, tags, release guards, consumer pickup
domain:environment|FBCA04|The ready-to-code environment: devcontainer, images, codespaces, editor setup
area:copier|0E8A16|The templating engine: copier.yml, answers, validators, jinja, render matrix
area:devcontainer|0E8A16|Dev containers, images, features
area:ci|0E8A16|GitHub Actions workflows and CI plumbing
area:tasks|0E8A16|Taskfile targets and scripts/ glue
area:tests|0E8A16|The test-*.sh suite and gate assertions
area:deps|0E8A16|Renovate, version pins, dependency bumps
area:skills|0E8A16|Vendored/authored agent skills and the skills sync
area:foreman|0E8A16|Foreman config, wrapper tasks, adapters
area:gauntlet|0E8A16|The challenge/review second-model stage: scripts, gates, and skill wiring
area:worktree|0E8A16|Worktree lifecycle tooling
area:release|0E8A16|release-please, tags, release guards
area:security|0E8A16|Scanners, secret handling, hardening
area:pm|0E8A16|Labels, projects, issue tooling, PM docs
area:docs|0E8A16|Documentation content and structure"
foreman_inline="foreman:approved|1D76DB|Arm with the repo default backend
foreman:hold|D93F0B|Exclude from foreman dispatch (always wins)
foreman:satisfied|0E8A16|Human override: treat this dependency as satisfied
foreman:external|BFDADC|External dependency: satisfied when closed as completed"

check_lockfile() {
    local manifest="$1" registry="$2" inline="$3" label="$4"
    local base_expect foreman_expect got_base got_foreman
    base_expect="$( (printf '%s\n' "$inline" &&
        node scripts/agent-registry-labels.mjs suggest-claim "$registry") | sort)"
    foreman_expect="$( (printf '%s\n' "$inline" && printf '%s\n' "$foreman_inline" &&
        node scripts/agent-registry-labels.mjs suggest-claim "$registry" &&
        node scripts/agent-registry-labels.mjs foreman-adapters "$registry") | sort)"
    got_base="$(node scripts/label-registry-render.mjs labels "$manifest" | sort)"
    got_foreman="$(node scripts/label-registry-render.mjs labels --foreman "$manifest" | sort)"
    if [ "$got_base" != "$base_expect" ]; then
        fail "$label: rendered label set (no --foreman) differs from the reviewed lockfile:"
        diff <(printf '%s\n' "$base_expect") <(printf '%s\n' "$got_base") >&2 || true
    fi
    if [ "$got_foreman" != "$foreman_expect" ]; then
        fail "$label: rendered label set (--foreman) differs from the reviewed lockfile:"
        diff <(printf '%s\n' "$foreman_expect") <(printf '%s\n' "$got_foreman") >&2 || true
    fi
}
if [ "$template_mode" = 1 ]; then
    check_lockfile label-registry.json agent-registry.json \
        "$shared_inline
$root_only_inline" "root layer"
    template_only_inline="domain:auth|FBCA04|Authentication and authorization
domain:billing|FBCA04|Billing and payments
domain:platform|FBCA04|CI, build, test infra, and tooling in this repo
area:ci|0E8A16|GitHub Actions workflows and CI plumbing
area:docs|0E8A16|Documentation content and structure
area:deps|0E8A16|Renovate, version pins, dependency bumps
area:build|0E8A16|Build system and artifacts
area:tests|0E8A16|The test suite and gate assertions
area:tasks|0E8A16|Taskfile targets and scripts/ glue
area:release|0E8A16|release-please, tags, release guards
area:devcontainer|0E8A16|Dev containers, images, features
area:pm|0E8A16|Labels, projects, issue tooling, PM docs
area:skills|0E8A16|Vendored/authored agent skills and the skills sync
area:gauntlet|0E8A16|The challenge/review second-model stage: scripts, gates, and skill wiring"
    check_lockfile template/label-registry.json template/agent-registry.json \
        "$shared_inline
$template_only_inline" "template layer"

    # The manifests are an allowlisted dogfood-parity divergence, but the
    # divergence is now exactly the per-layer area/domain values — everything
    # else is shared semantics generated repos must not lag on (writers,
    # lifecycle, gates, notes, and the tier/method families, fleet-wide as of
    # #913). Compare canonically with those values emptied, so a root-side edit
    # to a shared record fails here instead of shipping stale.
    strip_per_layer='(.families[] | select(.family == "area" or .family == "domain") | .values) = []'
    if ! diff \
        <(jq -S "$strip_per_layer" label-registry.json) \
        <(jq -S "$strip_per_layer" template/label-registry.json) >&2; then
        fail "template/label-registry.json drifted from the root manifest outside the per-layer surfaces (area/domain values) — shared family metadata and every other family (including tier/method) must match"
    fi
else
    echo "note: not the template repository — skipping the migration lockfile" >&2
fi

# ── 4. provisioning-script binding ─────────────────────────────────────────
# Run the provisioning script with `gh` stubbed to echo the label name and
# confirm it provisions exactly the renderer's set — both directions, so
# neither a dropped delegation nor a re-added hand-list can fork.
if [ -f scripts/setup-github-labels.sh ]; then
    grep -q 'label-registry-render.mjs' scripts/setup-github-labels.sh ||
        fail "setup-github-labels.sh does not render from the label registry (missing label-registry-render.mjs call)"
    if grep -Eq '^[a-z0-9][a-z0-9:. -]*\|[0-9A-Fa-f]{6}\|' scripts/setup-github-labels.sh; then
        fail "setup-github-labels.sh hard-lists a name|color|description label line — the vocabulary lives in label-registry.json"
    fi
    stub_dir="$(mktemp -d)"
    cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = label ] && { shift 2; printf '%s\n' "$1"; exit 0; }
exit 0
STUB
    chmod +x "$stub_dir/gh"
    emitted="$(PATH="$stub_dir:$PATH" bash scripts/setup-github-labels.sh --repo drift/check --foreman 2>/dev/null | grep -v '^==>' | sort)"
    rm -rf "$stub_dir"
    want_names="$(node scripts/label-registry-render.mjs labels --foreman | sed 's/|.*//' | sort)"
    [ "$emitted" = "$want_names" ] || {
        fail "setup-github-labels.sh --foreman provisions a different set than the renderer:"
        diff <(printf '%s\n' "$want_names") <(printf '%s\n' "$emitted") >&2 || true
    }
else
    echo "note: scripts/setup-github-labels.sh not present in this profile — skipping the provisioning binding" >&2
fi

# ── 5. status inventory binding ────────────────────────────────────────────
if [ -f scripts/status.sh ]; then
    grep -q 'label-registry-render.mjs' scripts/status.sh ||
        fail "scripts/status.sh does not read its expected-label inventory from label-registry-render.mjs — an unseeded family would grade green"
fi

# ── 6. docs taxonomy table ─────────────────────────────────────────────────
# The local document is compared against a PROFILE-AWARE render: gated
# families appear only where their opt-in's render-time marker file exists
# (the same presence checks status.sh and the Taskfile use), because copier
# dropped those rows from the rendered doc on profiles without the opt-in.
# The template twin is compared against the --jinja render, whose copier
# conditionals are what produced those per-profile documents.
extract_taxonomy() {
    awk '/<!-- label-taxonomy:begin -->/{found=1; next} /<!-- label-taxonomy:end -->/{exit} found' "$1"
}
check_docs() {
    local doc="$1" manifest="$2"
    shift 2
    if ! grep -q 'label-taxonomy:begin' "$doc"; then
        fail "$doc has no label-taxonomy markers — the taxonomy table must be generated, not hand-edited"
        return
    fi
    local want got
    want="$(node scripts/label-registry-render.mjs docs-table "$@" "$manifest")"
    got="$(extract_taxonomy "$doc")"
    [ "$got" = "$want" ] || {
        fail "$doc taxonomy table drifted from $manifest — regenerate with: node scripts/label-registry-render.mjs docs-table $* $manifest"
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
    }
}
profile_flags=""
[ -f taskfiles/foreman.yml ] && profile_flags="--foreman"
[ -f release-please-config.json ] && profile_flags="$profile_flags --release-please"
# Which document Copier rendered at docs/project-management.md depends on the
# project_management answer — the linear variant lives at the SAME path with
# no taxonomy markers, so a presence-only check fails every linear render.
# Resolve the tracker the way test-registry-docs.sh does: the answers file
# (env only outside the template repo), setup-github-project.sh as fallback,
# fail closed on anything unrecognized.
tracker="github"
if [ "$template_mode" = 0 ]; then
    answers=""
    for candidate in "${COPIER_ANSWERS_FILE:-}" .copier-answers.yml .copier-answers.yaml; do
        [ -n "$candidate" ] && [ -f "$candidate" ] && answers="$candidate" && break
    done
    tracker=""
    if [ -n "$answers" ]; then
        tracker="$(sed -n 's/^project_management:[[:space:]]*//p' "$answers" |
            sed 's/[[:space:]]*#.*$//' | tr -d "\"'" |
            sed 's/[[:space:]]*$//' | head -n1)"
    fi
    if [ -z "$tracker" ]; then
        if [ -f scripts/setup-github-project.sh ]; then tracker="github"; else tracker="none"; fi
        echo "note: no project_management answer found; inferred '$tracker' from scripts/setup-github-project.sh" >&2
    fi
    case "$tracker" in
    github | linear | none) : ;;
    *)
        fail "unrecognized project_management value '$tracker' — refusing to skip the docs gate on it"
        tracker="github"
        ;;
    esac
fi
if [ "$tracker" != "github" ]; then
    echo "note: project_management=$tracker renders no GitHub taxonomy document — skipping the docs binding" >&2
elif [ -f docs/project-management.md ]; then
    # shellcheck disable=SC2086  # profile_flags is deliberately word-split
    check_docs docs/project-management.md label-registry.json $profile_flags
else
    echo "note: docs/project-management.md not present in this profile — skipping the docs binding" >&2
fi
if [ "$template_mode" = 1 ]; then
    template_doc="template/docs/[% if project_management == 'github' %]project-management.md[% endif %].jinja"
    if [ -f "$template_doc" ]; then
        check_docs "$template_doc" template/label-registry.json --jinja
    else
        fail "the template project-management.md twin is missing — the generated taxonomy table would ship stale"
    fi
fi

if [ "$fails" -ne 0 ]; then
    echo "test-label-registry: $fails failure(s) above." >&2
    exit 1
fi
echo "test-label-registry: manifest, provisioning, status inventory, and docs table agree."
