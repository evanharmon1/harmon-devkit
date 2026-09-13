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
    echo "TEST FAIL: $*" >&2 || true
    fails=$((fails + 1))
    return 0
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
if [ "${GUIDANCE_FAIL_ON_CALL:-}" = 1 ]; then
    exit 97
fi
if [ "${GUIDANCE_RETIRED_UPPERCASE:-}" = 1 ]; then
    printf '%s\n' '[{"name":"area:OLD","description":"Still live but retired by the manifest"}]'
    exit 0
fi
if [ "${GUIDANCE_PREFIX_UPPERCASE:-}" = 1 ]; then
    printf '%s\n' '[{"name":"Area:live","description":"Live area description"}]'
    exit 0
fi
if [ "${GUIDANCE_LONG_LABELS:-}" = 1 ]; then
    jq -n '[range(0; 1000) | {name: ("area:long-" + tostring), description: ("x" * 3000)}]'
    exit 0
fi
case "${1:-} ${2:-}" in
"label list")
    printf '%s\n' '[
      {"name":"area:live","description":"Live area description"},
      {"name":"area:literal","description":"Windows path C:\\temp and\ttab"},
      {"name":"area:old","description":"Still live but retired by the manifest"},
      {"name":"area:track-work","description":"Stale live area description"},
      {"name":"unsafe,comma","description":"Cannot pass authoring validation"},
      {"name":"unsafe|pipe","description":"Cannot pass authoring validation"},
      {"name":"claim:gpt","description":"Claimed by GPT"},
      {"name":"suggest:gpt","description":"Suggested for GPT"},
      {"name":"agent:legacy","description":"Legacy agent claim"},
      {"name":"foreman:claude","description":"Dispatch control"},
      {"name":"Rigor:deep","description":"Execution budget"},
      {"name":"tier:frontier","description":"Model routing"},
      {"name":"tier:implementer:frontier","description":"Scoped model routing"},
      {"name":"strategy:plan","description":"Execution topology"},
      {"name":"method:plan","description":"Retired execution topology"},
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
    jq -e 'select(.label | test("^(claim|suggest|agent|foreman|rigor|tier|strategy|method):"; "i"))' >/dev/null; then
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

echo "==> guidance: control-only open families do not require a live-label read"
jq '(.families[] | select(.family == "concern"))
      |= (.prefix = "rigor" | .open_values = true | .placeholder = "rigor:<value>" | .values = [])' \
    label-registry.json >"$guidance_tmp/control-open-family.json"
control_open_guidance="$(GUIDANCE_FAIL_ON_CALL=1 PATH="$guidance_bin:$PATH" "$guidance_helper" guidance "$guidance_tmp/control-open-family.json" testowner/testrepo)" ||
    fail "a control-only open family must not require a live-label read"
printf '%s\n' "$control_open_guidance" |
    jq -se 'any(.[]; .label == "area:track-work")' >/dev/null ||
    fail "a control-only open family should retain self-contained manifest guidance"

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
    jq -se 'length == 4 and all(.[]; .label == "area:live" or .label == "area:literal" or .label == "area:old" or .label == "area:track-work")' >/dev/null ||
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
    jq -se 'all(.[]; .family != "area" or (.label == "area:live" or .label == "area:literal" or .label == "area:old" or .label == "area:track-work"))' >/dev/null ||
    fail "open-value guidance should include only bounded live members"

echo "==> guidance: open-family prefixes use GitHub case-insensitive identity"
uppercase_prefix_guidance="$(GUIDANCE_PREFIX_UPPERCASE=1 PATH="$guidance_bin:$PATH" "$guidance_helper" guidance "$guidance_tmp/open-area.json" testowner/testrepo)" ||
    fail "open-value guidance should render an uppercase live prefix"
printf '%s\n' "$uppercase_prefix_guidance" |
    jq -se 'any(.[]; .label == "Area:live" and .family == "area")' >/dev/null ||
    fail "open-value guidance should match a live prefix case-insensitively"

echo "==> guidance: enumerated open members keep manifest descriptions"
jq '(.families[] | select(.family == "area"))
      |= (.open_values = true | .placeholder = "area:<value>")' \
    label-registry.json >"$guidance_tmp/open-enumerated-area.json"
open_enumerated_guidance="$(PATH="$guidance_bin:$PATH" "$guidance_helper" guidance "$guidance_tmp/open-enumerated-area.json" testowner/testrepo)" ||
    fail "enumerated open-family guidance should render"
printf '%s\n' "$open_enumerated_guidance" |
    jq -se 'any(.[]; .label == "area:track-work"
        and .description == "The track-work skill: issue authoring standards and PR/commit linkage; claims are session-flow")' >/dev/null ||
    fail "enumerated open-family members should retain manifest descriptions"

echo "==> guidance: retired open-family members are never reintroduced from live labels"
jq '(.families[] | select(.family == "area"))
      |= (.open_values = true | .placeholder = "area:<value>"
          | .values = [{"value": "old", "description": "Retired area", "retired": true}])' \
    label-registry.json >"$guidance_tmp/retired-open-area.json"
retired_open_guidance="$(GUIDANCE_RETIRED_UPPERCASE=1 PATH="$guidance_bin:$PATH" "$guidance_helper" guidance "$guidance_tmp/retired-open-area.json" testowner/testrepo)" ||
    fail "retired open-family guidance should render remaining live members"
if printf '%s\n' "$retired_open_guidance" |
    jq -e 'select(.label | ascii_downcase == "area:old")' >/dev/null; then
    fail "retired manifest members must not return through open-family live guidance"
fi

echo "==> guidance: bounded live label payloads do not pass through argv"
long_guidance="$guidance_tmp/long-guidance.jsonl"
GUIDANCE_LONG_LABELS=1 PATH="$guidance_bin:$PATH" "$guidance_helper" guidance "$guidance_tmp/open-area.json" testowner/testrepo >"$long_guidance" ||
    fail "large bounded live label payloads should render without an argv-size failure"
jq -se '(. as $all | [$all[] | select(.label | startswith("area:long-"))] | length == 1000)
        and any(.[]; .label == "area:long-999" and (.description | length) == 3000)' "$long_guidance" >/dev/null ||
    fail "large bounded live label payloads should retain the final live record"

echo "==> guidance: prefixless open families retain active manifest members"
jq '(.families[] | select(.family == "concern"))
      |= (.open_values = true | .placeholder = "<value>")' \
    label-registry.json >"$guidance_tmp/prefixless-open-concern.json"
prefixless_open_guidance="$($guidance_helper guidance "$guidance_tmp/prefixless-open-concern.json" testowner/testrepo)" ||
    fail "prefixless open-family guidance should render"
printf '%s\n' "$prefixless_open_guidance" |
    jq -se 'any(.[]; . == {record: "guidance", label: "sec", description: "Security concern", family: "concern", purpose: "Cross-cutting concerns worth filtering on, color-coded as one family."})' >/dev/null ||
    fail "prefixless open-family guidance should retain active enumerated members"

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
  case 'closed-devflow-family-without-values':
    family('rigor').values = []
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
rejects "a closed devflow-sourced family with no values" 'closed-devflow-family-without-values' \
    'closed devflow family'

# Inventory authorization must not depend on documentation order. Put the
# open model families before their agent-registry bases and require the same
# precise family prefixes—never the overly broad `suggest:` or `claim:`.
cp agent-registry.json "$mutation_tmp/agent-registry.json"
node --input-type=module - label-registry.json "$mutated_manifest" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const manifest = JSON.parse(await readFile(inputPath, 'utf8'))
for (const [openId, baseId] of [['suggest-model', 'suggest'], ['claim-model', 'claim']]) {
  const open = manifest.families.find((entry) => entry.family === openId)
  manifest.families = manifest.families.filter((entry) => entry.family !== openId)
  manifest.families.splice(manifest.families.findIndex((entry) => entry.family === baseId), 0, open)
}
await writeFile(outputPath, `${JSON.stringify(manifest, null, 2)}\n`)
NODE
reordered_inventory="$(node scripts/label-registry-render.mjs inventory "$mutated_manifest")" ||
    fail "inventory failed when open model families preceded their registry bases"
if grep -Eq '^prefix\|(suggest|claim):$' <<<"$reordered_inventory"; then
    fail "inventory widened protection when families were reordered"
fi
grep -Fqx 'prefix|suggest:gpt:' <<<"$reordered_inventory" ||
    fail "reordered inventory lost the suggest:gpt model prefix"
grep -Fqx 'prefix|claim:gpt:' <<<"$reordered_inventory" ||
    fail "reordered inventory lost the claim:gpt model prefix"

echo "==> migrated registry: devflow-sourced rigor/strategy + a retired method family"
# harmon-init#1047's target shape: rigor and the renamed strategy family are
# source: devflow (values still enumerated inline, same rules as source:
# inline — .devflow.toml is documentation of intent, not a second data
# source), and the retired method family keeps its record (empty values,
# provision: false) rather than being deleted outright.
migrated_manifest="$mutation_tmp/migrated-label-registry.json"
cat >"$migrated_manifest" <<'JSON'
{
  "$schema": "./label-registry.schema.json",
  "schema_version": 1,
  "families": [
    {
      "family":"rigor","prefix":"rigor","purpose":"Dev Loop round-cap level","axis":"strategy",
      "source":"devflow","writers":["human"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"D4C5F9",
      "values":[
        {"value":"trivial","description":"Trivial, low-blast-radius work"},
        {"value":"standard","description":"The default budget"}
      ]
    },
    {
      "family":"strategy","prefix":"strategy","purpose":"Execution topology","axis":"strategy",
      "source":"devflow","writers":["human","agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"BF3989",
      "values":[
        {"value":"plan","description":"Agent plans then implements"},
        {"value":"oneshot","description":"Single agent, no separate plan phase"}
      ]
    },
    {
      "family":"method","prefix":"method","purpose":"Retired execution topology","axis":"strategy",
      "source":"devflow","writers":[],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":false,"retired":true,"values":[]
    }
  ]
}
JSON
if ! "$guidance_helper" validate "$migrated_manifest" >/dev/null 2>&1; then
    fail "validate should accept source: devflow with the same enumerated-value rules as inline"
fi
migrated_records="$("$guidance_helper" render "$migrated_manifest")" ||
    fail "render should render a migrated (devflow-sourced) manifest"
grep -qxF 'value|strategy:plan|strategy|strategy|strategy|human,agent|true|devflow|false|false|false' \
    <<<"$migrated_records" ||
    fail "render should surface a devflow-sourced value exactly like an inline one"
grep -qxF 'value|rigor:standard|rigor|rigor|strategy|human|true|devflow|false|false|false' \
    <<<"$migrated_records" ||
    fail "render should surface a devflow-sourced rigor value exactly like an inline one"
if grep -q '^value|method:' <<<"$migrated_records"; then
    fail "the retired method family must not render any value records"
fi
grep -qxF 'family|method|method|strategy||true|devflow|false|true' \
    <<<"$migrated_records" ||
    fail "the retired method family record itself should still render (retired: true, values empty)"

# A devflow-sourced family follows the same closed-family rule as inline: no
# values, not open, not retired is still a validation error.
jq '(.families[] | select(.family == "strategy")).values = []' \
    "$migrated_manifest" >"$mutation_tmp/migrated-empty-strategy.json"
if "$guidance_helper" validate "$mutation_tmp/migrated-empty-strategy.json" >/dev/null 2>&1; then
    fail "a closed devflow family with no values should be rejected, same as source: inline"
fi

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
# The source template is now Jinja-rendered so Codex opt-outs can zero their
# stage caps/finders. Its rigor catalog is deliberately invariant and the
# fully opted-in render equals this root dogfood policy structurally, so the
# template label vocabulary is checked against the root catalog here; every
# rendered profile checks its own concrete .devflow.toml above.
[ "$template_mode" = 1 ] && check_rigor template/label-registry.json .devflow.toml

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
layer:infra|1D76DB|Hosts, networking, containers, provisioning — IaC and config rather than app code
rigor:cursory|D4C5F9|Rigor: one quick adversarial glance, economy elsewhere — near-zero-risk changes
rigor:light|D4C5F9|Rigor: light rounds, frontier orchestrator/challenger, economy implementer
rigor:standard|D4C5F9|Rigor: standard rounds and breadth, frontier challenger, standard implementer — the default
rigor:thorough|D4C5F9|Rigor: thorough rounds, apex orchestrator/challenger, frontier reviewer
rigor:deep|D4C5F9|Rigor: deep rounds, apex orchestrator/challenger, frontier implementer/reviewer
rigor:forensic|D4C5F9|Rigor: maximum scrutiny at every role — irreversible failure modes, security, data paths
tier:local|7057FF|Model tier: self-hosted endpoint first; may escalate to economy
tier:economy|7057FF|Model tier: cheapest qualified hosted model first; escalation allowed
tier:standard|7057FF|Model tier: reliable general-purpose coding model first
tier:frontier|7057FF|Model tier: opus-class heavyweights; no warm-up on weaker models
tier:apex|7057FF|Model tier: mythos-class leading edge (fable, sol)
tier:adaptive|7057FF|Model tier: cheap preflight classifies, then chooses or escalates
strategy:oneshot|BF3989|Strategy: single agent, no separate plan phase
strategy:plan|BF3989|Strategy: agent plans then implements; no human plan gate
strategy:plan-approved|BF3989|Strategy: plan requires human approval before implementation
strategy:orchestrate|BF3989|Strategy: lead agent delegates bounded work to parallel workers
strategy:council|BF3989|Strategy: independent proposals, judged; best or synthesis wins (2+ agents)
strategy:human-led|BF3989|Strategy: human owns central decisions; AI does bounded pieces"
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
area:ci|0E8A16|Repository-wide CI workflows and plumbing; subsystem workflows belong to that subsystem's area
area:tasks|0E8A16|Taskfile targets and scripts/ glue without a more specific area; security targets are area:security
area:tests|0E8A16|The shared test-*.sh suite and gates; a subsystem's own tests belong to its area
area:deps|0E8A16|Cross-cutting dependency automation and bumps; subsystem dependencies belong to its area
area:skills|0E8A16|Shared agent skills and skills sync; subsystem workflow skills belong to that subsystem's area
area:foreman|0E8A16|Foreman config, wrapper tasks, adapters
area:gauntlet|0E8A16|The challenge/review second-model stage: scripts, gates, and skill wiring
area:worktree|0E8A16|Worktree lifecycle tooling
area:release|0E8A16|release-please, tags, release guards
area:security|0E8A16|Scanners, secret handling, hardening
area:pm|0E8A16|Labels, projects, issue tooling, PM docs
area:docs|0E8A16|Documentation content and structure; a subsystem's own docs belong to that subsystem's area"
foreman_inline="foreman:approved|1D76DB|Arm with the repo default backend
foreman:hold|D93F0B|Exclude from foreman dispatch (always wins)
foreman:satisfied|0E8A16|Human override: treat this dependency as satisfied
foreman:external|BFDADC|External dependency: satisfied when closed as completed"

check_lockfile() {
    local manifest="$1" registry="$2" inline="$3" label="$4"
    local base_expect foreman_expect got_base got_foreman
    base_expect="$( (printf '%s\n' "$inline" &&
        node scripts/agent-registry-labels.mjs suggest-claim "$registry" &&
        node scripts/agent-registry-labels.mjs tier-roles "$registry") | sort)"
    foreman_expect="$( (printf '%s\n' "$inline" && printf '%s\n' "$foreman_inline" &&
        node scripts/agent-registry-labels.mjs suggest-claim "$registry" &&
        node scripts/agent-registry-labels.mjs foreman-adapters "$registry" &&
        node scripts/agent-registry-labels.mjs tier-roles "$registry") | sort)"
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
area:ci|0E8A16|Repository-wide CI workflows and plumbing; subsystem workflows belong to that subsystem's area
area:docs|0E8A16|Documentation content and structure; a subsystem's own docs belong to that subsystem's area
area:deps|0E8A16|Cross-cutting dependency automation and bumps; subsystem dependencies belong to its area
area:build|0E8A16|Shared build system and artifacts; subsystem builds belong to that subsystem's area
area:tests|0E8A16|The shared test suite and gates; a subsystem's own tests belong to its area
area:tasks|0E8A16|Taskfile targets and scripts/ glue without a more specific area
area:release|0E8A16|release-please, tags, release guards
area:devcontainer|0E8A16|Dev containers, images, features
area:pm|0E8A16|Labels, projects, issue tooling, PM docs
area:skills|0E8A16|Shared agent skills and skills sync; subsystem workflow skills belong to that subsystem's area
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
# Run the provisioning script with `gh` stubbed to record the label name and
# confirm it provisions exactly the renderer's set — both directions, so
# neither a dropped delegation nor a re-added hand-list can fork.
if [ -f scripts/setup-github-labels.sh ]; then
    grep -q 'label-registry-render.mjs' scripts/setup-github-labels.sh ||
        fail "setup-github-labels.sh does not render from the label registry (missing label-registry-render.mjs call)"
    if grep -Eq '^[a-z0-9][a-z0-9:. -]*\|[0-9A-Fa-f]{6}\|' scripts/setup-github-labels.sh; then
        fail "setup-github-labels.sh hard-lists a name|color|description label line — the vocabulary lives in label-registry.json"
    fi
    stub_dir="$(mktemp -d)"
    emitted_file="$stub_dir/emitted"
    cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = label ] && { shift 2; printf '%s\n' "$1" >>"$STUB_EMITTED"; exit 0; }
exit 0
STUB
    chmod +x "$stub_dir/gh"
    STUB_EMITTED="$emitted_file" PATH="$stub_dir:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --foreman >/dev/null 2>&1
    emitted="$(sort "$emitted_file")"
    rm -rf "$stub_dir"
    want_names="$(node scripts/label-registry-render.mjs labels --foreman | sed 's/|.*//' | sort)"
    [ "$emitted" = "$want_names" ] || {
        fail "setup-github-labels.sh --foreman provisions a different set than the renderer:"
        diff <(printf '%s\n' "$want_names") <(printf '%s\n' "$emitted") >&2 || true
    }
else
    echo "note: scripts/setup-github-labels.sh not present in this profile — skipping the provisioning binding" >&2
fi

# ── 4b. maintenance modes: report, refuse, pagination, migration, prune ────
# The fixture returns two API pages and puts migration records on the second
# page. It also models pull requests through the repository issues endpoint,
# which is the REST surface the setup script uses for all-state associations.
if [ -f scripts/setup-github-labels.sh ]; then
    if bash scripts/setup-github-labels.sh --repo 'drift/check;touch' --report-unregistered >/dev/null 2>&1; then
        fail "maintenance mode accepted an unsafe repository argument"
    fi
    if bash scripts/setup-github-labels.sh --repo drift/check --migrate enhancement=feature >/dev/null 2>&1; then
        fail "--migrate was accepted without --prune"
    fi
    maintenance_stub="$(mktemp -d)"
    maintenance_log="$maintenance_stub/log"
    maintenance_state="$maintenance_stub/migrated"
    cat >"$maintenance_stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'gh %s\n' "$*" >>"$STUB_LOG"

initial_labels() {
    if [ "${STUB_SCENARIO:-}" = comma-name ]; then
        if [ "$1" -eq 12 ]; then
            printf '%s\n' 'legacy,comma'
        fi
        return 0
    fi
    case "$1" in
    1 | 2) printf '%s\n' ENHANCEMENT ;;
    3 | 4) printf '%s\n' custom-associated ;;
    41 | 42) printf '%s\n' ENHANCEMENT page-two-only ;;
    50) printf '%s\n' ENHANCEMENT discussion-page-two ;;
    esac
    if [ "${STUB_SCENARIO:-}" = broker-unresolved ]; then
        case "$1" in
        6) printf '%s\n' claim:copilot ;;
        7) printf '%s\n' claim:copilot:sol ;;
        8) printf '%s\n' suggest:copilot ;;
        9) printf '%s\n' suggest:copilot:sol ;;
        10) printf '%s\n' agent:github-copilot ;;
        11) printf '%s\n' agent:github-copilot:sol ;;
        esac
    fi
}
labels_json() {
    local kind="$1" number="$2"
    local state_file="${STUB_STATE}.${kind}.${number}"
    if [ -f "$state_file" ]; then
        jq -Rsc 'split("\n") | map(select(length > 0) | {name: .})' "$state_file"
    else
        case "${STUB_SCENARIO:-}" in
        all-safe | appears-before-delete | completed-migration | completed-migration-missing-destination) printf '%s\n' '[]' ;;
        *) initial_labels "$number" | jq -Rsc 'split("\n") | map(select(length > 0) | {name: .})' ;;
        esac
    fi
}
item_json() {
    local number="$1" labels kind=issue
    if [ "$number" -eq 2 ] || [ "$number" -eq 4 ] || [ "$number" -eq 7 ] ||
        [ "$number" -eq 9 ] || [ "$number" -eq 42 ]; then
        kind=pr
    fi
    labels="$(labels_json "$kind" "$number")"
    if [ "${STUB_SCENARIO:-}" = appears-before-delete ] &&
        [ -f "${STUB_STATE}.appeared" ] && [ "$number" -eq 5 ]; then
        labels='[{"name":"unknown-empty"}]'
    fi
    printf '{"number":%s,"labels":%s' "$number" "$labels"
    if [ "$number" -eq 2 ] || [ "$number" -eq 4 ] || [ "$number" -eq 7 ] ||
        [ "$number" -eq 9 ] || [ "$number" -eq 42 ]; then
        printf ',"pull_request":{}'
    fi
    printf '}\n'
}

case "${1:-}" in
api)
    case "$*" in
    *"--method POST repos/drift/check/issues/"*"/labels --input -"*)
        path="$4"
        number="${path#repos/drift/check/issues/}"
        number="${number%%/*}"
        label="$(jq -er '.labels | select(length == 1) | .[0]')"
        kind=issue
        case "$number" in 2 | 4 | 7 | 9 | 42) kind=pr ;; esac
        state_file="${STUB_STATE}.${kind}.${number}"
        [ -f "$state_file" ] || initial_labels "$number" >"$state_file"
        grep -Fqx "$label" "$state_file" || printf '%s\n' "$label" >>"$state_file"
        printf '%s #%s add %s\n' "$kind" "$number" "$label" >>"$STUB_LOG"
        printf '%s\n' '[]'
        ;;
    *"--method DELETE repos/drift/check/issues/"*"/labels/"*)
        path="$4"
        number="${path#repos/drift/check/issues/}"
        number="${number%%/*}"
        encoded_label="${path##*/}"
        label="$(printf '%b' "${encoded_label//%/\\x}")"
        kind=issue
        case "$number" in 2 | 4 | 7 | 9 | 42) kind=pr ;; esac
        state_file="${STUB_STATE}.${kind}.${number}"
        [ -f "${STUB_STATE}.verified.${kind}.${number}" ] || exit 1
        if [ "${STUB_SCENARIO:-}" = verification-drift ] &&
            [ "${STUB_DRIFT_KIND:-}" = "$kind" ] &&
            [ "${STUB_DRIFT_NUMBER:-}" = "$number" ] &&
            [ -f "${STUB_STATE}.drifted.${kind}.${number}" ]; then
            printf 'unsafe-remove %s #%s %s (destination drifted)\n' "$kind" "$number" "$label" >>"$STUB_LOG"
            exit 1
        fi
        printf '%s #%s remove %s\n' "$kind" "$number" "$label" >>"$STUB_LOG"
        awk -v label="$label" 'tolower($0) != tolower(label)' "$state_file" >"${state_file}.tmp"
        mv "${state_file}.tmp" "$state_file"
        printf '%s\n' '{}'
        ;;
    *"discussions(first:100"*)
        if [ "${STUB_FAIL:-}" = discussions ]; then
            printf '%s\n' '{"data":{"repository":{"discussions":null}}}'
            exit 0
        fi
        discussion_labels="$(labels_json discussion 50)"
        if [ "${STUB_SCENARIO:-}" = all-safe ] || [ "${STUB_SCENARIO:-}" = appears-before-delete ] ||
            [ "${STUB_SCENARIO:-}" = completed-migration ] ||
            [ "${STUB_SCENARIO:-}" = completed-migration-missing-destination ] ||
            [ "${STUB_SCENARIO:-}" = comma-name ]; then
            discussion_labels='[]'
        fi
        jq -cn --argjson labels "$discussion_labels" '[
            {data:{repository:{discussions:{nodes:[],pageInfo:{hasNextPage:true,endCursor:"page-1"}}}}},
            {data:{repository:{discussions:{nodes:[{id:"D_50",number:50,labels:{nodes:$labels,pageInfo:{hasNextPage:false}}}],pageInfo:{hasNextPage:false,endCursor:null}}}}}
        ]'
        ;;
    *"node(id:\$id)"*)
        labels_json discussion 50 | jq -c '{data:{node:{labels:{nodes:.,pageInfo:{hasNextPage:false}}}}}'
        : >"${STUB_STATE}.verified.discussion.50"
        ;;
    *"addLabelsToLabelable"*)
        state_file="${STUB_STATE}.discussion.50"
        [ -f "$state_file" ] || initial_labels 50 >"$state_file"
        label_id=""
        for arg in "$@"; do
            case "$arg" in labelIds[]=*) label_id="${arg#labelIds[]=}" ;; esac
        done
        label="${label_id%-id}"
        [ -n "$label" ] || exit 2
        grep -Fqx "$label" "$state_file" || printf '%s\n' "$label" >>"$state_file"
        printf 'discussion #50 add %s\n' "$label" >>"$STUB_LOG"
        printf '%s\n' '{"data":{"addLabelsToLabelable":{"clientMutationId":null}}}'
        ;;
    *"removeLabelsFromLabelable"*)
        state_file="${STUB_STATE}.discussion.50"
        [ -f "${STUB_STATE}.verified.discussion.50" ] || exit 1
        label_id=""
        for arg in "$@"; do
            case "$arg" in labelIds[]=*) label_id="${arg#labelIds[]=}" ;; esac
        done
        label="${label_id%-id}"
        [ -n "$label" ] || exit 2
        awk 'tolower($0) != "enhancement"' "$state_file" >"${state_file}.tmp"
        mv "${state_file}.tmp" "$state_file"
        printf 'discussion #50 remove %s\n' "$label" >>"$STUB_LOG"
        printf '%s\n' '{"data":{"removeLabelsFromLabelable":{"clientMutationId":null}}}'
        ;;
    *"labels?per_page=100"*)
        if [ "${2:-}" != --paginate ] || [ "${3:-}" != --slurp ]; then
            exit 3
        fi
        if [ "${STUB_FAIL:-}" = labels ]; then
            printf '%s\n' '{not-json'
            exit 0
        fi
        if [ "${STUB_SCENARIO:-}" = broker-unresolved ]; then
            jq -cn '[
                [{"name":"enhancement"},{"name":"legacy-empty"},{"name":"custom-associated"},{"name":"unknown-empty"},{"name":"--legacy"},{"name":"question"},{"name":"documentation"}],
                [{"name":"dependencies"},{"name":"feature"},{"name":"suggest:gpt"},{"name":"suggest:gpt:sol"},{"name":"claim:gpt:sol"},{"name":"BUG"},{"name":"foreman:approved"},{"name":"autorelease: pending"},{"name":"claim:copilot"},{"name":"claim:copilot:sol"},{"name":"suggest:copilot"},{"name":"suggest:copilot:sol"},{"name":"agent:github-copilot"},{"name":"agent:github-copilot:sol"},{"name":"claim:mai"},{"name":"claim:mai:sol"},{"name":"suggest:mai"},{"name":"suggest:mai:sol"},{"name":"page-two-only"},{"name":"discussion-page-two"}]
            ]' | jq --arg created "$(test -f "${STUB_STATE}.created-label" && cat "${STUB_STATE}.created-label" || :)" --arg scenario "${STUB_SCENARIO:-}" '
                map(map(. + {color:"abcdef",description:"fixture",node_id:(.name + "-id")})) |
                (if $scenario == "comma-name" then .[0] += [{name:"legacy,comma",color:"abcdef",description:"fixture",node_id:"legacy,comma-id"}] else . end) |
                (if $scenario == "fixed-source" then .[1] += [{name:"agent:codex",color:"abcdef",description:"fixture",node_id:"agent:codex-id"},{name:"claim:codex",color:"abcdef",description:"fixture",node_id:"claim:codex-id"},{name:"Claim:Codex:Sol",color:"abcdef",description:"fixture",node_id:"Claim:Codex:Sol-id"}] else . end) |
                (if ($scenario == "completed-migration" or $scenario == "completed-migration-missing-destination") then map(map(select(.name != "enhancement"))) else . end) |
                (if $scenario == "completed-migration-missing-destination" then map(map(select(.name != "feature"))) else . end) |
                if $created == "" then . else .[1] += [{name:$created,color:"abcdef",description:"fixture",node_id:($created + "-id")}] end'
        else
            jq -cn '[
                [{"name":"enhancement"},{"name":"legacy-empty"},{"name":"custom-associated"},{"name":"unknown-empty"},{"name":"--legacy"},{"name":"question"},{"name":"documentation"}],
                [{"name":"dependencies"},{"name":"feature"},{"name":"type:feature"},{"name":"suggest:gpt"},{"name":"suggest:gpt:sol"},{"name":"claim:gpt:sol"},{"name":"BUG"},{"name":"foreman:approved"},{"name":"autorelease: pending"},{"name":"page-two-only"},{"name":"discussion-page-two"}]
            ]' | jq --arg created "$(test -f "${STUB_STATE}.created-label" && cat "${STUB_STATE}.created-label" || :)" --arg scenario "${STUB_SCENARIO:-}" '
                map(map(. + {color:"abcdef",description:"fixture",node_id:(.name + "-id")})) |
                (if $scenario == "comma-name" then .[0] += [{name:"legacy,comma",color:"abcdef",description:"fixture",node_id:"legacy,comma-id"}] else . end) |
                (if $scenario == "fixed-source" then .[1] += [{name:"agent:codex",color:"abcdef",description:"fixture",node_id:"agent:codex-id"},{name:"claim:codex",color:"abcdef",description:"fixture",node_id:"claim:codex-id"},{name:"Claim:Codex:Sol",color:"abcdef",description:"fixture",node_id:"Claim:Codex:Sol-id"}] else . end) |
                (if ($scenario == "completed-migration" or $scenario == "completed-migration-missing-destination") then map(map(select(.name != "enhancement"))) else . end) |
                (if $scenario == "completed-migration-missing-destination" then map(map(select(.name != "feature"))) else . end) |
                if $created == "" then . else .[1] += [{name:$created,color:"abcdef",description:"fixture",node_id:($created + "-id")}] end'
        fi
        ;;
    *"issues?state=all&per_page=100"*)
        if [ "${2:-}" != --paginate ] || [ "${3:-}" != --slurp ]; then
            exit 3
        fi
        if [ "${STUB_SCENARIO:-}" = appears-before-delete ]; then
            reads=0
            [ ! -f "${STUB_STATE}.association-reads" ] || reads="$(cat "${STUB_STATE}.association-reads")"
            reads=$((reads + 1))
            printf '%s\n' "$reads" >"${STUB_STATE}.association-reads"
            [ "$reads" -lt 2 ] || : >"${STUB_STATE}.appeared"
        fi
        page_one="$(
            number=1
            while [ "$number" -le 30 ]; do
                item_json "$number"
                number=$((number + 1))
            done | jq -s .
        )"
        page_two="$(
            number=31
            while [ "$number" -le 45 ]; do
                item_json "$number"
                number=$((number + 1))
            done | jq -s .
        )"
        jq -cn --argjson page_one "$page_one" --argjson page_two "$page_two" '[ $page_one, $page_two ]'
        ;;
    *)
        exit 2
        ;;
    esac
    ;;
issue|pr)
    kind="$1"
    if [ "${2:-}" = view ]; then
        number="$3"
        [ "${4:-}" = --repo ] && [ "${5:-}" = "${STUB_REPO:-drift/check}" ] || exit 2
        [ "${6:-}" = --json ] && [ "${7:-}" = labels ] || exit 2
        printf '%s #%s view labels\n' "$kind" "$number" >>"$STUB_LOG"
        if [ "${STUB_FAIL:-}" = verify ]; then
            printf '%s\n' '{"labels":[]}'
        elif [ "${STUB_SCENARIO:-}" = verification-drift ] &&
            [ "${STUB_DRIFT_KIND:-}" = "$kind" ] &&
            [ "${STUB_DRIFT_NUMBER:-}" = "$number" ] &&
            [ -f "${STUB_STATE}.drifted.${kind}.${number}" ]; then
            labels_json "$kind" "$number" |
                jq -c 'map(select((.name | ascii_downcase) != "feature"))' |
                jq -c '{labels: .}'
        else
            labels_json "$kind" "$number" | jq -c '{labels: .}'
            if [ "${STUB_SCENARIO:-}" = verification-drift ] &&
                [ "${STUB_DRIFT_KIND:-}" = "$kind" ] &&
                [ "${STUB_DRIFT_NUMBER:-}" = "$number" ]; then
                : >"${STUB_STATE}.drifted.${kind}.${number}"
            fi
            : >"${STUB_STATE}.verified.${kind}.${number}"
        fi
        exit 0
    fi
    [ "${2:-}" = edit ] || exit 2
    number="$3"
    shift 3
    [ "${1:-}" = --repo ] && [ "${2:-}" = "${STUB_REPO:-drift/check}" ] || exit 2
    shift 2
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --add-label)
            [ "$2" = feature ] || exit 2
            printf '%s #%s add %s\n' "$kind" "$number" "$2" >>"$STUB_LOG"
            state_file="${STUB_STATE}.${kind}.${number}"
            if [ ! -f "$state_file" ]; then
                initial_labels "$number" >"$state_file"
            fi
            grep -Fqx "$2" "$state_file" || printf '%s\n' "$2" >>"$state_file"
            shift 2
            ;;
        --remove-label)
            [ "$2" = enhancement ] || exit 2
            state_file="${STUB_STATE}.${kind}.${number}"
            if [ ! -f "${STUB_STATE}.verified.${kind}.${number}" ]; then
                printf 'unsafe-remove %s #%s %s (not verified)\n' "$kind" "$number" "$2" >>"$STUB_LOG"
                exit 1
            fi
            if ! grep -Fqx feature "$state_file"; then
                printf 'unsafe-remove %s #%s %s (destination missing)\n' "$kind" "$number" "$2" >>"$STUB_LOG"
                exit 1
            fi
            if [ "${STUB_SCENARIO:-}" = verification-drift ] &&
                [ "${STUB_DRIFT_KIND:-}" = "$kind" ] &&
                [ "${STUB_DRIFT_NUMBER:-}" = "$number" ] &&
                [ -f "${STUB_STATE}.drifted.${kind}.${number}" ]; then
                printf 'unsafe-remove %s #%s %s (destination drifted)\n' "$kind" "$number" "$2" >>"$STUB_LOG"
                exit 1
            fi
            printf '%s #%s remove %s\n' "$kind" "$number" "$2" >>"$STUB_LOG"
            awk -v label="$2" 'tolower($0) != tolower(label)' "$state_file" >"${state_file}.tmp"
            mv "${state_file}.tmp" "$state_file"
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done
    ;;
label)
    if [ "${2:-}" = create ]; then
        printf '%s\n' "$3" >"${STUB_STATE}.created-label"
        printf 'create %s\n' "$3" >>"$STUB_LOG"
        exit 0
    fi
    [ "${2:-}" = delete ] || exit 2
    [ "${3:-}" = --repo ] && [ "${4:-}" = "${STUB_REPO:-drift/check}" ] || exit 2
    [ "${5:-}" = --yes ] && [ "${6:-}" = -- ] && [ -n "${7:-}" ] || exit 2
    printf 'delete %s\n' "$7" >>"$STUB_LOG"
    ;;
*)
    exit 2
    ;;
esac
STUB
    chmod +x "$maintenance_stub/gh"
    reset_maintenance() {
        rm -f "$maintenance_log" "$maintenance_state" "$maintenance_state".*
        : >"$maintenance_log"
    }

    report_log="$maintenance_stub/report.log"
    report_out="$(STUB_LOG="$report_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --report-unregistered 2>&1)" ||
        fail "--report-unregistered failed against the paginated fixture"
    case "$report_out" in
    *"Unregistered label: enhancement (issues: 2, PRs: 2, discussions: 1)"*) ;;
    *) fail "report did not print separate issue/PR counts for the retired label: $report_out" ;;
    esac
    case "$report_out" in
    *"Unregistered label: page-two-only (issues: 1, PRs: 1, discussions: 0)"*) ;;
    *) fail "report did not count the page-two-only issue and PR association: $report_out" ;;
    esac
    case "$report_out" in
    *"Unregistered label: discussion-page-two (issues: 0, PRs: 0, discussions: 1)"*) ;;
    *) fail "report did not count the page-two discussion association: $report_out" ;;
    esac
    case "$report_out" in
    *"Unregistered label: question"* | *"Unregistered label: documentation"* | *"Unregistered label: dependencies"*)
        fail "report flagged an adopted/never-delete label: $report_out"
        ;;
    esac
    case "$report_out" in
    *"Unregistered label: suggest:gpt:sol"* | *"Unregistered label: claim:gpt:sol"* | *"Unregistered label: BUG"*)
        fail "report flagged a recognized family or provisioned label: $report_out"
        ;;
    esac
    case "$report_out" in
    *"Unregistered label: foreman:approved"* | *"Unregistered label: autorelease:"*)
        fail "report exposed a gated tool label without its opt-in flag: $report_out"
        ;;
    esac
    if grep -Eq '^(issue|pr|delete) ' "$report_log"; then
        fail "--report-unregistered performed a write:"
        cat "$report_log" >&2
    fi

    reset_maintenance
    if confirm_out="$(printf 'y\n' | STUB_SCENARIO=all-safe STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune 2>&1)"; then
        fail "--prune accepted piped confirmation without explicit --yes"
    fi
    case "$confirm_out" in
    *"requires a TTY"*"--yes explicitly"*) ;;
    *) fail "non-TTY confirmation did not explain the explicit --yes requirement: $confirm_out" ;;
    esac
    ! grep -Eq '^(issue|pr|delete) ' "$maintenance_log" ||
        fail "non-TTY confirmation refusal reached a write path"

    reset_maintenance
    if prune_out="$(STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes 2>&1)"; then
        fail "--prune returned success while refusing associated labels"
    fi
    case "$prune_out" in
    *"Refused: enhancement (issues: 2, PRs: 2, discussions: 1)"*) ;;
    *) fail "--prune did not refuse enhancement by name: $prune_out" ;;
    esac
    case "$prune_out" in
    *"Refused: custom-associated (issues: 1, PRs: 1, discussions: 0)"*) ;;
    *) fail "--prune did not refuse custom-associated by name: $prune_out" ;;
    esac
    ! grep -Eq '^(issue|pr|delete) ' "$maintenance_log" ||
        fail "--prune partially mutated labels after preflight found associated candidates"
    ! grep -Eq '^delete (foreman:approved|autorelease: pending)$' "$maintenance_log" ||
        fail "--prune treated a gated tool label as an unregistered deletion candidate"

    reset_maintenance
    if safe_prune_out="$(STUB_SCENARIO=all-safe STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes 2>&1)"; then
        :
    else
        fail "--prune rejected a fixture with no label associations: $safe_prune_out"
    fi
    case "$safe_prune_out" in
    *"Prune confirmed by explicit --yes"*) ;;
    *) fail "--yes did not communicate explicit destructive confirmation: $safe_prune_out" ;;
    esac
    case "$safe_prune_out" in
    *quiescen* | *concurrent* | *"label writer"* | *"label updates paused"*) ;;
    *) fail "destructive confirmation did not communicate the quiescence precondition: $safe_prune_out" ;;
    esac
    for expected in 'delete enhancement' 'delete legacy-empty' 'delete custom-associated' 'delete unknown-empty' 'delete --legacy' 'delete page-two-only' 'delete discussion-page-two'; do
        grep -Fqx "$expected" "$maintenance_log" ||
            fail "successful prune missed an unregistered zero-association label: $expected"
    done

    for fixed_case in \
        'agent:codex=claim:claude|claim:gpt' \
        'claim:codex=suggest:gpt|claim:gpt' \
        'Claim:Codex:Sol=suggest:gpt:sol|claim:gpt:Sol'; do
        fixed_spec="${fixed_case%%|*}"
        fixed_destination="${fixed_case#*|}"
        fixed_source="${fixed_spec%%=*}"
        reset_maintenance
        if fixed_out="$(STUB_SCENARIO=fixed-source STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
            bash scripts/setup-github-labels.sh --repo drift/check --prune --yes --migrate "$fixed_spec" 2>&1)"; then
            fail "noncanonical fixed migration was accepted: $fixed_spec"
        fi
        case "$fixed_out" in
        *"migration source '$fixed_source' has authoritative destination '$fixed_destination'"*) ;;
        *) fail "fixed-source refusal did not name its authoritative destination: $fixed_out" ;;
        esac
        ! grep -Eq '^(issue|pr|discussion|delete|create) ' "$maintenance_log" ||
            fail "noncanonical fixed migration reached a write path: $fixed_spec"
    done

    reset_maintenance
    if flat_destination_out="$(STUB_SCENARIO=all-safe STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes --migrate legacy-empty=type:feature 2>&1)"; then
        :
    else
        fail "existing flat-prefix destination incorrectly required a bare parent label: $flat_destination_out"
    fi
    ! grep -Fqx 'create type:feature' "$maintenance_log" ||
        fail "existing flat-prefix destination was recreated"
    ! grep -Eq '^delete (foreman:approved|autorelease: pending)$' "$maintenance_log" ||
        fail "successful prune deleted a gated tool label without its opt-in flag"

    reset_maintenance
    if migrate_out="$(STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate enhancement=feature --migrate legacy-empty=feature 2>&1)"; then
        fail "migrate-then-prune returned success while refusing custom-associated"
    fi
    case "$migrate_out" in
    *"Refused: custom-associated (issues: 1, PRs: 1, discussions: 0)"*) ;;
    *) fail "migrate-then-prune did not refuse the associated label by name: $migrate_out" ;;
    esac
    for expected in \
        'issue #1 add feature' 'issue #1 view labels' 'issue #1 remove enhancement' \
        'pr #2 add feature' 'pr #2 view labels' 'pr #2 remove enhancement' \
        'issue #41 add feature' 'issue #41 view labels' 'issue #41 remove enhancement' \
        'pr #42 add feature' 'pr #42 view labels' 'pr #42 remove enhancement' \
        'discussion #50 add feature' 'discussion #50 remove enhancement'; do
        grep -Fqx "$expected" "$maintenance_log" || fail "migration missed paginated record: $expected"
    done
    ! grep -Eq '^delete ' "$maintenance_log" ||
        fail "migrate-then-prune partially deleted labels after preflight found custom-associated"

    for broker_case in \
        'claim:copilot|claim:mai' \
        'claim:copilot:sol|claim:mai:sol' \
        'suggest:copilot|suggest:mai' \
        'suggest:copilot:sol|suggest:mai:sol' \
        'agent:github-copilot|claim:mai' \
        'agent:github-copilot:sol|claim:mai:sol'; do
        broker_old="${broker_case%%|*}"
        broker_new="${broker_case#*|}"
        reset_maintenance
        if broker_out="$(STUB_SCENARIO=broker-unresolved STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
            bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
            --migrate "$broker_old=$broker_new" 2>&1)"; then
            fail "broker-derived migration source was accepted: $broker_old"
        fi
        case "$broker_out" in
        *"migration source '$broker_old' is broker-derived and has no trustworthy single destination"*) ;;
        *) fail "broker-source refusal did not emit the exact diagnostic for $broker_old: $broker_out" ;;
        esac
        case "$broker_out" in
        *"Prune confirmed by explicit --yes"*)
            fail "broker-source validation reached destructive confirmation for $broker_old"
            ;;
        esac
        ! grep -Eq '^gh (issue|pr) (edit|close|reopen|delete) ' "$maintenance_log" ||
            fail "broker-source refusal reached an issue/PR mutation for $broker_old"
        ! grep -Eq '^gh label delete ' "$maintenance_log" ||
            fail "broker-source refusal reached label deletion for $broker_old"
    done

    reset_maintenance
    if broker_fixed_out="$(STUB_SCENARIO=broker-unresolved STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate enhancement=feature 2>&1)"; then
        fail "fixed migration unexpectedly succeeded while unresolved broker labels remained"
    fi
    for expected in \
        'issue #1 add feature' 'issue #1 view labels' 'issue #1 remove enhancement' \
        'pr #2 add feature' 'pr #2 view labels' 'pr #2 remove enhancement' \
        'issue #41 add feature' 'issue #41 view labels' 'issue #41 remove enhancement' \
        'pr #42 add feature' 'pr #42 view labels' 'pr #42 remove enhancement'; do
        grep -Fqx "$expected" "$maintenance_log" ||
            fail "fixed migration did not preserve the exact issue/PR operation: $expected"
    done
    ! grep -Eq '^(issue|pr) #(6|7|8|9|10|11) ' "$maintenance_log" ||
        fail "fixed migration touched a broker-derived source"
    ! grep -Eq '^delete ' "$maintenance_log" ||
        fail "fixed migration deleted labels while unresolved broker sources remained"

    reset_maintenance
    if ambiguous_out="$(STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate 'legacy=source=feature' 2>&1)"; then
        fail "ambiguous migration encoding was accepted"
    fi
    case "$ambiguous_out" in
    *"OLD=NEW is ambiguous"*"relabel those records manually"*) ;;
    *) fail "ambiguous migration refusal was not actionable: $ambiguous_out" ;;
    esac
    ! grep -Eq '^(issue|pr|discussion|delete|create) ' "$maintenance_log" ||
        fail "ambiguous migration encoding reached a write path"

    reset_maintenance
    if empty_suffix_out="$(STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate 'enhancement=claim:gpt:' 2>&1)"; then
        fail "empty model suffix was accepted"
    fi
    case "$empty_suffix_out" in
    *"migration destination 'claim:gpt:' is not covered by the registry inventory"*) ;;
    *) fail "empty model suffix refusal was not exact: $empty_suffix_out" ;;
    esac
    ! grep -Eq '^(issue|pr|discussion|delete|create) ' "$maintenance_log" ||
        fail "empty model suffix reached a write path"

    reset_maintenance
    if comma_out="$(STUB_SCENARIO=comma-name STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate 'legacy,comma=feature' 2>&1)"; then
        :
    else
        fail "exact comma-bearing label migration failed: $comma_out"
    fi
    grep -Fqx 'issue #12 add feature' "$maintenance_log" ||
        fail "comma-bearing migration did not add the exact destination"
    grep -Fqx 'issue #12 remove legacy,comma' "$maintenance_log" ||
        fail "comma-bearing migration did not remove the exact source"

    reset_maintenance
    if completed_out="$(STUB_SCENARIO=completed-migration STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate enhancement=feature 2>&1)"; then
        :
    else
        fail "completed migration was not idempotent: $completed_out"
    fi
    case "$completed_out" in
    *"Migration already complete: enhancement -> feature (source label is absent)"*) ;;
    *) fail "completed migration did not report its no-op disposition: $completed_out" ;;
    esac
    ! grep -Eq '^(issue|pr|discussion).* (add|remove) (enhancement|feature)$' "$maintenance_log" ||
        fail "completed migration repeated association mutations"
    ! grep -Fqx 'delete enhancement' "$maintenance_log" ||
        fail "completed migration attempted to delete its already-absent source"

    reset_maintenance
    if missing_destination_out="$(STUB_SCENARIO=completed-migration-missing-destination STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate enhancement=feature 2>&1)"; then
        fail "completed migration accepted an absent destination"
    fi
    case "$missing_destination_out" in
    *"migration source 'enhancement' is absent but destination 'feature' is not live"*"run label setup first"*) ;;
    *) fail "absent completed-migration destination refusal was not actionable: $missing_destination_out" ;;
    esac
    ! grep -Eq '^(issue|pr|discussion|delete|create) ' "$maintenance_log" ||
        fail "absent completed-migration destination reached a write path"

    reset_maintenance
    if STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate enhancement=suggest:gpt:new-model \
        --migrate legacy-empty=suggest:gpt:new-model >/dev/null 2>&1; then
        fail "model-destination fixture unexpectedly completed"
    fi
    grep -Fqx 'create suggest:gpt:new-model' "$maintenance_log" ||
        fail "recognized missing model destination was not created after confirmation"
    [ "$(grep -Fxc 'create suggest:gpt:new-model' "$maintenance_log")" -eq 1 ] ||
        fail "shared missing model destination was created more than once"
    grep -Fqx 'issue #1 add suggest:gpt' "$maintenance_log" ||
        fail "model migration did not preserve the family-level association"
    grep -Fqx 'issue #1 add suggest:gpt:new-model' "$maintenance_log" ||
        fail "model migration did not add the qualified destination"
    create_line="$(grep -nE '^create suggest:gpt:new-model$' "$maintenance_log" | cut -d: -f1)"
    first_edit_line="$(grep -nE '^issue #1 add ' "$maintenance_log" | sed -n '1{s/:.*//;p;}')"
    [ -n "$first_edit_line" ] && [ "$create_line" -lt "$first_edit_line" ] ||
        fail "model destination was not created before association migration"

    reset_maintenance
    if appears_out="$(STUB_SCENARIO=appears-before-delete STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes 2>&1)"; then
        fail "prune succeeded after an association appeared before deletion"
    fi
    case "$appears_out" in
    *"Refused: unknown-empty"* | *"association drift detected for 'unknown-empty'"*) ;;
    *) fail "prune did not re-read and refuse the label that became associated: $appears_out" ;;
    esac
    ! grep -Eq '^delete ' "$maintenance_log" ||
        fail "bounded preflight partially deleted labels after association drift"
    ! grep -Fqx 'delete unknown-empty' "$maintenance_log" ||
        fail "prune deleted a label after its association appeared"

    reset_maintenance
    if STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" STUB_FAIL=verify PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate enhancement=feature >/dev/null 2>&1; then
        fail "migration accepted an unverified destination label"
    fi
    grep -Fqx 'issue #1 add feature' "$maintenance_log" ||
        fail "destination-verification fixture never reached the add step"
    ! grep -Fqx 'issue #1 remove enhancement' "$maintenance_log" ||
        fail "migration removed the source after destination verification failed"

    reset_maintenance
    if drift_out="$(STUB_SCENARIO=verification-drift STUB_DRIFT_KIND=pr STUB_DRIFT_NUMBER=2 \
        STUB_LOG="$maintenance_log" STUB_STATE="$maintenance_state" PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes \
        --migrate enhancement=feature 2>&1)"; then
        fail "migration succeeded after the verified destination drifted"
    fi
    grep -Fqx 'pr #2 add feature' "$maintenance_log" ||
        fail "post-verification-drift fixture never reached the PR add step"
    grep -Fqx 'pr #2 view labels' "$maintenance_log" ||
        fail "post-verification-drift fixture never verified the PR destination"
    ! grep -Fqx 'pr #2 remove enhancement' "$maintenance_log" ||
        fail "migration removed the PR source after destination drift"
    ! grep -Fqx 'unsafe-remove pr #2 enhancement (destination drifted)' "$maintenance_log" ||
        fail "migration reached the destructive PR removal after destination drift"

    fail_log="$maintenance_stub/fail.log"
    reset_maintenance
    if STUB_LOG="$fail_log" STUB_STATE="$maintenance_state" STUB_FAIL=labels PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --report-unregistered >/dev/null 2>&1; then
        fail "maintenance mode accepted an indeterminate label read"
    fi
    ! grep -Eq '^(issue|pr|delete) ' "$fail_log" ||
        fail "indeterminate read reached a write path"
    reset_maintenance
    if STUB_LOG="$fail_log" STUB_STATE="$maintenance_state" STUB_FAIL=discussions PATH="$maintenance_stub:$PATH" \
        bash scripts/setup-github-labels.sh --repo drift/check --prune --yes >/dev/null 2>&1; then
        fail "maintenance mode accepted an indeterminate discussion read"
    fi
    ! grep -Eq '^(issue|pr|discussion|create|delete) ' "$fail_log" ||
        fail "indeterminate discussion read reached a write path"
    rm -rf "$maintenance_stub"
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
            sed 's/[[:space:]]*$//' | sed -n '1p')"
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
