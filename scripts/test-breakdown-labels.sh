#!/usr/bin/env bash
# Hermetic tests for breakdown's registry-driven label discovery asset.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
asset="$repo/ai/skills/universal/breakdown/assets/discover-label-vocabulary.mjs"
skill="$repo/ai/skills/universal/breakdown/SKILL.md"
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

# Isolate the asset and its sibling helper; never replace the live triage skill.
mkdir -p "$tmproot/skills/breakdown/assets" "$tmproot/skills/triage/assets"
cp "$asset" "$tmproot/skills/breakdown/assets/discover-label-vocabulary.mjs"
cp "$repo/ai/skills/universal/breakdown/assets/validate-json-schema.mjs" "$tmproot/skills/breakdown/assets/validate-json-schema.mjs"
asset="$tmproot/skills/breakdown/assets/discover-label-vocabulary.mjs"
helper="$tmproot/skills/triage/assets/triage-apply.sh"
cat >"$helper" <<'FAKE_CLASSIFICATION'
#!/usr/bin/env bash
set -euo pipefail
fixture="${BREAKDOWN_LABEL_FIXTURE:?}"
[ "$*" = 'classification-axes --repo acme/project' ] || exit 2
[ "${GH_HOST:-}" = github.com ] || exit 2
if [ -f "$fixture/fields-denied" ]; then
    echo 'could not read provisioned issue fields' >&2
    exit 2
fi
if [ -f "$fixture/organization" ]; then
    # The shared reader owns filtering; emulate its documented on-scale result.
    jq -e '.data.repository.issueFields.pageInfo.hasNextPage == false'         "$fixture/fields.json" >/dev/null || exit 2
    jq -c '.data.repository.issueFields.nodes as $fields |
      {owner_type:"Organization",storage:"field",required:["impact","risk","complexity"],
       axes: {impact:{field:"Impact",scale:["minimal","low","medium","high","massive"]},
              risk:{field:"Risk",scale:["trivial","low","medium","high","critical"]},
              complexity:{field:"Complexity",scale:["xs","s","m","l","xl"]}}}
        | .axes |= with_entries(.value as $spec |
            ([$fields[] | select(.name == $spec.field)] | first) as $f |
            .value = {provisioned:($f != null), field:$spec.field,
              values:[$spec.scale[] | . as $v | select(any($f.options[]; .name == $v))]})'         "$fixture/fields.json"
else
    printf '%s\n' '{"owner_type":"User","storage":"label","required":["impact","risk","complexity"],"axes":{"impact":{"provisioned":true,"values":["high"]},"risk":{"provisioned":true,"values":["low"]},"complexity":{"provisioned":true,"values":["m"]}}}'
fi
FAKE_CLASSIFICATION
chmod +x "$helper"

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*" || true
    return 0
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2 || true
    return 0
}

mkdir -p "$tmproot/bin"
cat >"$tmproot/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

fixture="${BREAKDOWN_LABEL_FIXTURE:?}"
if [ "$1" = api ]; then
    joined="$*"
    if [[ "$joined" == *"graphql"* ]]; then
        echo 'ratings must come from the shared helper, never direct GraphQL' >&2
        exit 1
    elif [[ "$joined" == *"/contents/label-registry.json"* ]]; then
        if [ ! -f "$fixture/label-registry.json" ]; then
            echo "gh: Not Found (HTTP 404)" >&2
            exit 1
        fi
        file="$fixture/label-registry.json"
    elif [[ "$joined" == *"/contents/label-registry.schema.json"* ]]; then
        file="$fixture/label-registry.schema.json"
    elif [[ "$joined" == *"/contents/agent-registry.json"* ]]; then
        if [ ! -f "$fixture/agent-registry.json" ]; then
            echo "gh: Not Found (HTTP 404)" >&2
            exit 1
        fi
        file="$fixture/agent-registry.json"
    elif [[ "$joined" == *"/contents/agent-registry.schema.json"* ]]; then
        file="$fixture/agent-registry.schema.json"
    elif [[ "$joined" == *"/git/matching-refs/heads/"* ]]; then
        if [ -f "$fixture/empty-repository" ]; then
            echo "gh: Git Repository is empty. (HTTP 409)" >&2
            exit 1
        else
            printf '[{"ref":"refs/heads/trunk"}]\n'
        fi
        exit 0
    elif [[ "$joined" == *"/branches/"* ]]; then
        if [ -f "$fixture/empty-repository" ]; then
            echo "gh: Branch not found (HTTP 404)" >&2
            exit 1
        fi
        printf '{"commit":{"sha":"1111111111111111111111111111111111111111"}}\n'
        exit 0
    elif [[ "$joined" == *"/git/trees/"* ]]; then
        if [ -f "$fixture/tree-denied" ]; then
            echo "gh: Not Found (HTTP 404)" >&2
            exit 1
        fi
        if [ -f "$fixture/reject-recursive-tree" ] && [[ "$joined" == *"recursive=1"* ]]; then
            printf '{"truncated":true,"tree":[]}\n'
            exit 0
        fi
        printf '{"truncated":false,"tree":['
        comma=
        for path in label-registry.json label-registry.schema.json \
            agent-registry.json agent-registry.schema.json; do
            [ -f "$fixture/$path" ] || continue
            printf '%s{"path":"%s"}' "$comma" "$path"
            comma=,
        done
        printf ']}\n'
        exit 0
    elif [[ "$joined" == *"/labels"* ]]; then
        if [[ "$joined" != *"--paginate"* || "$joined" != *"--slurp"* ]]; then
            echo "live-label API call must be exhaustively paginated" >&2
            exit 1
        fi
        printf '['
        cat "$fixture/labels.json"
        printf ']\n'
        exit 0
    else
        if [ -f "$fixture/organization" ]; then
            printf '{"default_branch":"trunk","owner":{"type":"Organization"}}\n'
        else
            printf '{"default_branch":"trunk","owner":{"type":"User"}}\n'
        fi
        exit 0
    fi
    content="$(base64 <"$file" | tr -d '\n')"
    printf '{"type":"file","encoding":"base64","content":"%s"}\n' "$content"
    exit 0
fi
echo "unexpected fake gh call: $*" >&2
exit 2
FAKE_GH
chmod +x "$tmproot/bin/gh"

write_agent_registry() {
    local fixture="$1"
    cp "$repo/agent-registry.json" "$fixture/agent-registry.json"
    cp "$repo/agent-registry.schema.json" "$fixture/agent-registry.schema.json"
}

write_registry() {
    local fixture="$1" area="$2"
    cp "$repo/label-registry.schema.json" "$fixture/label-registry.schema.json"
    cat >"$fixture/label-registry.json" <<JSON
{
  "\$schema": "./label-registry.schema.json",
  "schema_version": 1,
  "families": [
    {
      "family":"area","prefix":"area","purpose":"Repository areas","axis":"classification",
      "source":"inline","writers":["human","agent"],"readers":"humans",
      "lifecycle":"durable","exclusive":true,"provision":true,"color":"123456",
      "values":[{"value":"$area","description":"Area"},{"value":"missing","description":"Not live"}]
    },
    {
      "family":"impact","prefix":"impact","purpose":"Effect of the work","axis":"classification",
      "source":"inline","writers":["agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"123456","values":[{"value":"high","description":"Broad effect"}]
    },
    {
      "family":"risk","prefix":"risk","purpose":"Failure consequences","axis":"classification",
      "source":"inline","writers":["agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"123456","values":[{"value":"low","description":"Limited risk"}]
    },
    {
      "family":"complexity","prefix":"complexity","purpose":"Reasoning difficulty","axis":"classification",
      "source":"inline","writers":["agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"123456","values":[{"value":"m","description":"Moderate work"}]
    },
    {
      "family":"priority","prefix":"priority","purpose":"Human priority","axis":"classification",
      "source":"inline","writers":["agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"123456","values":[{"value":"high","description":"High"}]
    },
    {
      "family":"effort","prefix":"effort","purpose":"Human estimate","axis":"classification",
      "source":"inline","writers":["agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"123456","values":[{"value":"high","description":"High"}]
    },
    {
      "family":"tier","prefix":"tier","purpose":"Derived model tier","axis":"model",
      "source":"inline","writers":["agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":false,"provision":true,"color":"123456","values":[{"value":"frontier","description":"Tier"},{"value":"pinned","description":"Pin"}]
    },
    {
      "family":"suggest","prefix":"suggest","purpose":"Advisory family routing","axis":"model",
      "source":"agent-registry","registry_set":"suggest","writers":["human","agent"],
      "readers":"humans","lifecycle":"durable","exclusive":false,"provision":true,
      "placeholder":"suggest:<family>","color":"BFD4F2","values":[]
    },
    {
      "family":"suggest-model","prefix":"suggest","purpose":"Advisory model refinement","axis":"model",
      "source":"tool-owned","writers":["human","agent"],"readers":"humans",
      "lifecycle":"durable","exclusive":false,"provision":false,"open_values":true,
      "placeholder":"suggest:<family>:<model>","values":[]
    },
    {
      "family":"override","prefix":"override","purpose":"Per-value overrides","axis":"meta",
      "source":"inline","writers":["human"],"readers":"humans","lifecycle":"durable",
      "exclusive":false,"provision":true,
      "values":[
        {"value":"agent-safe","writers":["agent"],"provision":false},
        {"value":"transient","description":"Transient","color":"123456","writers":["agent"],"lifecycle":"transient"},
        {"value":"retired","description":"Retired","color":"123456","writers":["agent"],"retired":true}
      ]
    },
    {
      "family":"custom","prefix":"custom","purpose":"Tool-owned live values","axis":"meta",
      "source":"tool-owned","writers":["agent"],"readers":"agents","lifecycle":"durable",
      "exclusive":false,"provision":false,"open_values":true,"placeholder":"custom:<value>","values":[]
    },
    {
      "family":"claim","prefix":"claim","purpose":"Ownership","axis":"model",
      "source":"agent-registry","registry_set":"claim","writers":["agent"],"readers":"agents",
      "lifecycle":"claim-release","exclusive":false,"provision":true,
      "placeholder":"claim:<family>","color":"006B75","values":[]
    },
    {
      "family":"claim-model","prefix":"claim","purpose":"Model ownership refinement","axis":"model",
      "source":"tool-owned","writers":["agent"],"readers":"agents",
      "lifecycle":"claim-release","exclusive":false,"provision":false,
      "open_values":true,"placeholder":"claim:<family>:<model>","values":[]
    },
    {
      "family":"workflow","prefix":"phase","purpose":"Transient state","axis":"workflow",
      "source":"inline","writers":["agent"],"readers":"agents","lifecycle":"transient",
      "exclusive":false,"provision":true,"color":"123456","values":[{"value":"temporary","description":"Temporary"}]
    },
    {
      "family":"gated","prefix":"gated","purpose":"Opt-in planning state","axis":"meta",
      "source":"inline","writers":["agent"],"readers":"agents","lifecycle":"durable",
      "exclusive":false,"provision":true,"gate":"release-please","color":"123456",
      "values":[{"value":"enabled","description":"Live but not proven applicable"}]
    },
    {
      "family":"arming","prefix":"foreman","purpose":"Execution trigger","axis":"foreman",
      "source":"inline","writers":["agent"],"readers":"foreman","lifecycle":"durable",
      "exclusive":false,"provision":true,"color":"123456",
      "values":[{"value":"approved","description":"Arm","arming":true}]
    }
  ]
}
JSON
}

write_labels() {
    local fixture="$1" area="$2"
    cat >"$fixture/labels.json" <<JSON
[
  {"name":"area:$area","description":"Live area"},
  {"name":"impact:high","description":"Broad effect"},
  {"name":"risk:low","description":"Limited risk"},
  {"name":"complexity:m","description":"Moderate work"},
  {"name":"priority:high","description":"Human priority"},
  {"name":"effort:high","description":"Human effort"},
  {"name":"tier:frontier","description":"Derived tier"},
  {"name":"tier:pinned","description":"Human pin"},
  {"name":"suggest:gpt","description":"Family suggestion"},
  {"name":"suggest:gpt:sol","description":"Model suggestion"},
  {"name":"suggest:gpt:ghost","description":"Unknown model"},
  {"name":"suggest:claude:opus","description":"Missing family pair"},
  {"name":"override:agent-safe","description":"Override"},
  {"name":"override:transient","description":"Transient override"},
  {"name":"override:retired","description":"Retired override"},
  {"name":"custom:live","description":"Created by its tool"},
  {"name":"claim:gpt","description":"Ownership"},
  {"name":"phase:temporary","description":"Transient"},
  {"name":"gated:enabled","description":"Stale gated label"},
  {"name":"foreman:approved","description":"Arming"}
]
JSON
}

# A harmon-init#1047-migrated registry pair: rigor/strategy families sourced
# from .devflow.toml (source: devflow, same enumerated-value shape as inline),
# a retired method family (the strategy:* rename leaves it in place, unused),
# and an agent-registry family to force the schema_version-3 fetch path.
# strategy/tier deliberately declare writers including "agent" (unlike their
# real-world human-only policy) so their exclusion below is attributable to
# the execution-control prefix filter and not just an absent "agent" writer.
write_migrated_label_registry() {
    local fixture="$1" area="$2"
    jq '(.["$defs"].family.properties.source.enum) |= (if index("devflow") then . else . + ["devflow"] end)' \
        "$repo/label-registry.schema.json" >"$fixture/label-registry.schema.json"
    cat >"$fixture/label-registry.json" <<JSON
{
  "\$schema": "./label-registry.schema.json",
  "schema_version": 1,
  "families": [
    {
      "family":"area","prefix":"area","purpose":"Repository areas","axis":"classification",
      "source":"inline","writers":["human","agent"],"readers":"humans",
      "lifecycle":"durable","exclusive":true,"provision":true,"color":"123456",
      "values":[{"value":"$area","description":"Area"}]
    },
    {
      "family":"rigor","prefix":"rigor","purpose":"Dev Loop round-cap level","axis":"strategy",
      "source":"devflow","writers":["human"],"readers":"humans",
      "lifecycle":"durable","exclusive":true,"provision":true,"color":"D4C5F9",
      "values":[{"value":"standard","description":"Default budget"}]
    },
    {
      "family":"strategy","prefix":"strategy","purpose":"Execution topology","axis":"strategy",
      "source":"devflow","writers":["human","agent"],"readers":"humans",
      "lifecycle":"durable","exclusive":true,"provision":true,"color":"BF3989",
      "values":[{"value":"plan","description":"Agent plans then implements"}]
    },
    {
      "family":"method","prefix":"method","purpose":"Retired execution topology","axis":"strategy",
      "source":"devflow","writers":[],"readers":"humans",
      "lifecycle":"durable","exclusive":true,"provision":false,"retired":true,"values":[]
    },
    {
      "family":"tier","prefix":"tier","purpose":"Model-routing stratum","axis":"model",
      "source":"devflow","writers":["human","agent"],"readers":"humans",
      "lifecycle":"durable","exclusive":true,"provision":true,"color":"7057FF",
      "values":[{"value":"frontier","description":"Opus-class"}]
    },
    {
      "family":"suggest","prefix":"suggest","purpose":"Advisory family routing","axis":"model",
      "source":"agent-registry","registry_set":"suggest","writers":["human","agent"],
      "readers":"humans","lifecycle":"durable","exclusive":false,"provision":true,
      "placeholder":"suggest:<family>","color":"BFD4F2","values":[]
    }
  ]
}
JSON
}

write_migrated_labels() {
    local fixture="$1" area="$2"
    cat >"$fixture/labels.json" <<JSON
[
  {"name":"area:$area","description":"Live area"},
  {"name":"rigor:standard","description":"Default budget"},
  {"name":"strategy:plan","description":"Agent plans then implements"},
  {"name":"tier:frontier","description":"Opus-class"}
]
JSON
}

discover() {
    local fixture="$1"
    BREAKDOWN_LABEL_FIXTURE="$fixture" PATH="$tmproot/bin:$PATH" \
        node "$asset" --repo acme/project
}

echo "==> breakdown registry label discovery"
first="$tmproot/first"
mkdir -p "$first"
write_agent_registry "$first"
write_registry "$first" api
write_labels "$first" api
if output="$(discover "$first")"; then
    ok "valid registry and complete paginated live inventory are discovered"
else
    bad "valid registry and complete paginated live inventory are discovered"
    output='{}'
fi

if jq -e '
    .mode == "registry" and .default_branch == "trunk" and
    .default_branch_commit == "1111111111111111111111111111111111111111" and
    .verified_semantics == true and
    .work_type_selection == "registry-semantics"
' \
    <<<"$output" >/dev/null; then
    ok "registry result is bound to the remote default branch"
else
    bad "registry result is bound to the remote default branch"
fi

names="$(jq -r '.families[].labels[].name' <<<"$output" | sort)"
expected=$'area:api\ncomplexity:m\ncustom:live\nimpact:high\noverride:agent-safe\nrisk:low'
if [ "$names" = "$expected" ]; then
    ok "only durable agent-writable non-arming live labels survive"
else
    bad "only durable agent-writable non-arming live labels survive (got: $names)"
fi

if jq -e '
    .families[] | select(.family == "area") |
    .purpose == "Repository areas" and .axis == "classification" and
    .exclusive == true and .labels[0].name == "area:api" and
    .labels[0].description == "Live area" and .labels[0].provision == true
' <<<"$output" >/dev/null; then
    ok "family purpose, axis, exclusivity, and live label metadata are preserved"
else
    bad "family purpose, axis, exclusivity, and live label metadata are preserved"
fi

if jq -e '
    .families[] | select(.family == "custom") |
    .exclusive == false and .labels[0].description == "Created by its tool"
' <<<"$output" >/dev/null; then
    ok "nonexclusive families retain independently selectable live descriptions"
else
    bad "nonexclusive families retain independently selectable live descriptions"
fi

if jq -e '
    .families[] | select(.family == "override") | .labels[0] |
    .writers == ["agent"] and .lifecycle == "durable" and .provision == false
' <<<"$output" >/dev/null; then
    ok "per-value semantic overrides take precedence"
else
    bad "per-value semantic overrides take precedence"
fi

if ! grep -qE 'area:missing|suggest:|claim:|phase:|gated:|foreman:|priority:|effort:|tier:' \
    <<<"$names"; then
    ok "missing, unknown, lifecycle, ownership, gated, and arming labels are excluded"
else
    bad "missing, unknown, lifecycle, ownership, gated, and arming labels are excluded"
fi

without_ratings="$tmproot/without-ratings"
mkdir -p "$without_ratings"
write_agent_registry "$without_ratings"
write_registry "$without_ratings" api
write_labels "$without_ratings" api
jq '.families |= map(select(.prefix != "impact" and .prefix != "risk" and .prefix != "complexity"))' "$without_ratings/label-registry.json" >"$without_ratings/updated.json"
mv "$without_ratings/updated.json" "$without_ratings/label-registry.json"
if helper_output="$(discover "$without_ratings")" && jq -e '
    .classification.storage == "label" and
    ([.families[] | select(.source == "classification-helper") | .labels[].name] |
    sort) == ["complexity:m","impact:high","risk:low"]
' <<<"$helper_output" >/dev/null; then
    ok "personal registry without rating families discovers helper-provisioned ratings"
else
    bad "personal rating discovery does not require manifest rating families"
fi
mv "$helper" "$helper.saved"
if discover "$first" >"$first/missing-helper-output" 2>"$first/missing-helper-error"; then
    bad "missing shared classification helper fails closed"
elif [ ! -s "$first/missing-helper-output" ] &&
    grep -q 'vendor the triage skill alongside breakdown' "$first/missing-helper-error"; then
    ok "missing shared classification helper fails closed with a vendoring diagnostic"
else
    bad "missing shared helper has an actionable diagnostic"
fi
mv "$helper.saved" "$helper"

# Both registry shapes must work while the claim contract remains required.
without_suggest="$tmproot/without-suggest"
mkdir -p "$without_suggest"
write_agent_registry "$without_suggest"
write_registry "$without_suggest" api
write_labels "$without_suggest" api
jq 'del(.labels.suggest)' "$without_suggest/agent-registry.json" >"$without_suggest/updated.json"
mv "$without_suggest/updated.json" "$without_suggest/agent-registry.json"
# Match the target's post-removal schema; do not use a legacy schema to certify it.
jq '.properties.labels.required |= map(select(. != "suggest")) |
    del(.properties.labels.properties.suggest)' "$without_suggest/agent-registry.schema.json" >"$without_suggest/schema.json"
mv "$without_suggest/schema.json" "$without_suggest/agent-registry.schema.json"
if no_suggest_output="$(discover "$without_suggest")" &&
    [ "$(jq -c .families <<<"$no_suggest_output")" = "$(jq -c .families <<<"$output")" ]; then
    ok "registries with and without labels.suggest yield identical planning vocabulary"
else
    bad "claim-only agent registry is accepted"
fi
jq 'del(.labels.claim)' "$without_suggest/agent-registry.json" >"$without_suggest/updated.json"
mv "$without_suggest/updated.json" "$without_suggest/agent-registry.json"
jq '.properties.labels.required = []' "$without_suggest/agent-registry.schema.json" >"$without_suggest/schema.json"
mv "$without_suggest/schema.json" "$without_suggest/agent-registry.schema.json"
if discover "$without_suggest" >"$without_suggest/output" 2>"$without_suggest/error"; then
    bad "claim namespace is still required"
elif grep -q 'labels.claim has an unsupported namespace contract' "$without_suggest/error"; then
    ok "claim namespace is still required by semantic validation"
else
    bad "missing claim must fail with a semantic diagnostic"
fi

organization="$tmproot/organization"
mkdir -p "$organization"
write_agent_registry "$organization"
write_registry "$organization" api
write_labels "$organization" api
touch "$organization/organization"
cat >"$organization/fields.json" <<'JSON'
{"data":{"repository":{"issueFields":{"pageInfo":{"hasNextPage":false},"nodes":[
  {"id":"I","name":"Impact","options":[{"id":"IH","name":"high"},{"id":"IO","name":"off-scale"}]},
  {"id":"R","name":"Risk","options":[{"id":"RL","name":"low"}]},
  {"id":"C","name":"Complexity","options":[{"id":"CM","name":"m"}]},
  {"id":"P","name":"Priority","options":[{"id":"PH","name":"high"}]},
  {"id":"E","name":"Effort","options":[{"id":"EH","name":"high"}]},
  {"id":"T","name":"Tier","options":[{"id":"TF","name":"frontier"}]}
]}}}}
JSON
if org_output="$(discover "$organization")" && jq -e '
    .owner_type == "Organization" and
    (.issue_fields | keys) == ["complexity", "impact", "risk"] and
    .issue_fields.impact.values == ["high"] and
    .issue_fields.risk.values == ["low"] and
    .issue_fields.complexity.values == ["m"] and
    ([.families[].labels[].name] | sort) == ["area:api", "custom:live", "override:agent-safe"]
' <<<"$org_output" >/dev/null; then
    ok "organization discovery emits rating fields and excludes personal ratings and human fields"
else
    bad "organization discovery uses issue fields for ratings: $org_output"
fi
if jq -e '(.classification.axes.impact.values | index("off-scale")) == null' <<<"$org_output" >/dev/null; then
    ok "off-scale organization option is excluded by the shared reader"
else
    bad "off-scale organization option cannot become a rating proposal"
fi
# Prefix-less values must obey the same owner-specific rating storage.
jq '(.families[] | select(.family == "risk")) |=
    (.prefix = null | .values[0].value = "risk:low")' "$organization/label-registry.json" >"$organization/updated.json"
mv "$organization/updated.json" "$organization/label-registry.json"
if org_rendered="$(discover "$organization")" && jq -e '
    (any(.families[].labels[]; .name == "risk:low") | not)
' <<<"$org_rendered" >/dev/null; then
    ok "prefix-less rating declarations cannot bypass organization field storage"
else
    bad "organization field storage also governs rendered concrete names"
fi
# Absence of a manifest must not turn org rating labels into candidates.
mv "$organization/label-registry.json" "$organization/saved-registry.json"
if org_fallback="$(discover "$organization")" && jq -e '
    .mode == "live-label-fallback" and (.issue_fields | keys | length) == 3 and
    (any(.labels[]; .name | test("^(impact|risk|complexity|priority|effort|tier):")) | not)
' <<<"$org_fallback" >/dev/null; then
    ok "organization live fallback retains fields and excludes inert rating labels"
else
    bad "organization live fallback keeps owner-appropriate rating storage"
fi
mv "$organization/saved-registry.json" "$organization/label-registry.json"
jq '.data.repository.issueFields.pageInfo.hasNextPage = true' "$organization/fields.json" >"$organization/updated.json"
mv "$organization/updated.json" "$organization/fields.json"
if discover "$organization" >"$organization/output" 2>"$organization/error"; then
    bad "truncated organization field vocabulary is not certified"
elif [ ! -s "$organization/output" ] && grep -q 'could not read provisioned Impact, Risk and Complexity' "$organization/error"; then
    ok "truncated organization field vocabulary fails closed"
else
    bad "truncated field discovery fails with a diagnostic"
fi
touch "$organization/fields-denied"
if discover "$organization" >"$organization/output" 2>"$organization/error"; then
    bad "unavailable organization fields cannot produce a verified vocabulary"
elif [ ! -s "$organization/output" ] && grep -q 'could not read provisioned Impact, Risk and Complexity' "$organization/error"; then
    ok "unavailable organization fields fail closed"
else
    bad "unavailable field discovery fails with a diagnostic"
fi

second="$tmproot/second"
mkdir -p "$second"
write_agent_registry "$second"
write_registry "$second" web
write_labels "$second" web
second_output="$(discover "$second")"
if jq -e '
    [.families[] | select(.family == "area") | .labels[].name] == ["area:web"]
' <<<"$second_output" >/dev/null && ! grep -q 'area:api' <<<"$second_output"; then
    ok "repository-specific area vocabularies do not leak across targets"
else
    bad "repository-specific area vocabularies do not leak across targets"
fi

large="$tmproot/large"
mkdir -p "$large"
write_agent_registry "$large"
write_registry "$large" api
write_labels "$large" api
touch "$large/reject-recursive-tree"
if large_output="$(discover "$large")" && jq -e '
    .mode == "registry" and
    [.families[] | select(.family == "area") | .labels[].name] == ["area:api"]
' <<<"$large_output" >/dev/null; then
    ok "registry discovery reads only the pinned root tree"
else
    bad "registry discovery reads only the pinned root tree"
fi

case_variant="$tmproot/case-variant"
mkdir -p "$case_variant"
write_agent_registry "$case_variant"
write_registry "$case_variant" api
write_labels "$case_variant" api
jq 'map(if .name == "area:api" then .name = "Area:api" else . end)' \
    "$case_variant/labels.json" >"$case_variant/labels-updated.json"
mv "$case_variant/labels-updated.json" "$case_variant/labels.json"
if case_output="$(discover "$case_variant")" && jq -e '
    [.families[] | select(.family == "area") | .labels[].name] == ["Area:api"]
' <<<"$case_output" >/dev/null; then
    ok "registry intersection follows GitHub case semantics and preserves live spelling"
else
    bad "registry intersection follows GitHub case semantics and preserves live spelling"
fi

fallback="$tmproot/fallback"
mkdir -p "$fallback"
cat >"$fallback/labels.json" <<'JSON'
[
  {"name":"feature","description":"Feature"},
  {"name":"area:api","description":"Area"},
  {"name":"priority:high","description":"Priority"},
  {"name":"Effort:high","description":"Human effort"},
  {"name":"tier:pinned","description":"Human pin"},
  {"name":"security","description":"Security"},
  {"name":"claim:gpt","description":"Claim"},
  {"name":"Claim:claude","description":"Case-varied claim"},
  {"name":"agent:codex","description":"Legacy claim"},
  {"name":"Foreman:approved","description":"Case-varied arm"},
  {"name":"strategy:plan","description":"Execution topology"},
  {"name":"rigor:standard","description":"Round-cap level"},
  {"name":"Tier:frontier","description":"Case-varied model tier"},
  {"name":"method:oneshot","description":"Retired execution topology"}
]
JSON
fallback_output="$(discover "$fallback")"
if jq -e '
    .mode == "live-label-fallback" and .verified_semantics == false and
    .work_type_selection == "human-confirmation-required" and
    ([.labels[].name] | sort) == ["area:api", "feature", "security"]
' <<<"$fallback_output" >/dev/null; then
    ok "missing registry leaves bounded live labels semantically unclassified"
else
    bad "missing registry leaves bounded live labels semantically unclassified: $fallback_output"
fi
if grep -qi '"name": *"strategy:\|"name": *"rigor:\|"name": *"tier:\|"name": *"method:' <<<"$fallback_output"; then
    bad "the no-registry live-label fallback must exclude execution-control labels (strategy/rigor/tier/method), case-insensitively, same as the registry path"
else
    ok "the no-registry live-label fallback excludes strategy/rigor/tier/method labels case-insensitively, same as the registry path"
fi

empty="$tmproot/empty"
mkdir -p "$empty"
touch "$empty/empty-repository"
printf '[{"name":"feature","description":"Feature"}]\n' >"$empty/labels.json"
if empty_output="$(discover "$empty")" && jq -e '
    .mode == "live-label-fallback" and .default_branch_commit == null and
    .work_type_selection == "human-confirmation-required" and
    [.labels[].name] == ["feature"]
' <<<"$empty_output" >/dev/null; then
    ok "a readable repository with no branch refs uses live-label fallback"
else
    bad "a readable repository with no branch refs uses live-label fallback"
fi

malformed="$tmproot/malformed"
mkdir -p "$malformed"
cp "$repo/label-registry.schema.json" "$malformed/label-registry.schema.json"
printf '{not json\n' >"$malformed/label-registry.json"
printf '[]\n' >"$malformed/labels.json"
if malformed_output="$(discover "$malformed" 2>"$malformed/error")"; then
    bad "present malformed registry fails closed"
elif [ -z "$malformed_output" ] && grep -q 'not valid JSON' "$malformed/error"; then
    ok "present malformed registry fails closed with a diagnostic"
else
    bad "present malformed registry fails closed with a diagnostic"
fi

schema_invalid="$tmproot/schema-invalid"
mkdir -p "$schema_invalid"
write_registry "$schema_invalid" api
write_labels "$schema_invalid" api
jq '.families[0].axis = 42' "$schema_invalid/label-registry.json" \
    >"$schema_invalid/invalid.json"
mv "$schema_invalid/invalid.json" "$schema_invalid/label-registry.json"
if discover "$schema_invalid" >"$schema_invalid/output" 2>"$schema_invalid/error"; then
    bad "schema-invalid registry metadata fails closed"
elif [ ! -s "$schema_invalid/output" ] && grep -q 'fails its schema' "$schema_invalid/error"; then
    ok "schema-invalid registry metadata fails closed with a diagnostic"
else
    bad "schema-invalid registry metadata fails closed with a diagnostic"
fi

semantic_axis_type="$tmproot/semantic-axis-type"
mkdir -p "$semantic_axis_type"
write_registry "$semantic_axis_type" api
write_labels "$semantic_axis_type" api
jq '.families[0].axis = 42' "$semantic_axis_type/label-registry.json" \
    >"$semantic_axis_type/registry.json"
mv "$semantic_axis_type/registry.json" "$semantic_axis_type/label-registry.json"
jq '.["$defs"].family.properties.axis = {}' "$semantic_axis_type/label-registry.schema.json" \
    >"$semantic_axis_type/schema.json"
mv "$semantic_axis_type/schema.json" "$semantic_axis_type/label-registry.schema.json"
if discover "$semantic_axis_type" >"$semantic_axis_type/output" 2>"$semantic_axis_type/error"; then
    bad "a target schema cannot certify a non-string axis"
elif [ ! -s "$semantic_axis_type/output" ] &&
    grep -q 'family\[0\]\.axis is unsupported: 42' "$semantic_axis_type/error"; then
    ok "non-string axes fail the asset's semantic validation"
else
    bad "non-string axes fail closed with a semantic diagnostic"
fi

semantic_axis_value="$tmproot/semantic-axis-value"
mkdir -p "$semantic_axis_value"
write_registry "$semantic_axis_value" api
write_labels "$semantic_axis_value" api
jq '.families[0].axis = "target-defined"' "$semantic_axis_value/label-registry.json" \
    >"$semantic_axis_value/registry.json"
mv "$semantic_axis_value/registry.json" "$semantic_axis_value/label-registry.json"
jq '.["$defs"].family.properties.axis = {}' "$semantic_axis_value/label-registry.schema.json" \
    >"$semantic_axis_value/schema.json"
mv "$semantic_axis_value/schema.json" "$semantic_axis_value/label-registry.schema.json"
if discover "$semantic_axis_value" >"$semantic_axis_value/output" 2>"$semantic_axis_value/error"; then
    bad "a target schema cannot extend the supported axis vocabulary"
elif [ ! -s "$semantic_axis_value/output" ] &&
    grep -q 'family\[0\]\.axis is unsupported: "target-defined"' \
        "$semantic_axis_value/error"; then
    ok "unknown axes fail the asset's semantic validation"
else
    bad "unknown axes fail closed with a semantic diagnostic"
fi

unsafe_schema="$tmproot/unsafe-schema"
mkdir -p "$unsafe_schema"
write_registry "$unsafe_schema" api
write_labels "$unsafe_schema" api
jq '.["$defs"].slug.pattern = "^(a+)+$"' "$unsafe_schema/label-registry.schema.json" \
    >"$unsafe_schema/schema.json"
mv "$unsafe_schema/schema.json" "$unsafe_schema/label-registry.schema.json"
if discover "$unsafe_schema" >"$unsafe_schema/output" 2>"$unsafe_schema/error"; then
    bad "target-controlled schema regexes are never evaluated"
elif [ ! -s "$unsafe_schema/output" ] && grep -q 'not a supported bounded registry pattern' "$unsafe_schema/error"; then
    ok "target-controlled schema regexes are never evaluated"
else
    bad "target-controlled schema regexes fail closed with a diagnostic"
fi

namespace_collision="$tmproot/namespace-collision"
mkdir -p "$namespace_collision"
write_agent_registry "$namespace_collision"
write_registry "$namespace_collision" api
write_labels "$namespace_collision" api
jq '.families += [{
    "family":"claim-open", "prefix":"claim", "purpose":"Unsafe overlap", "axis":"meta",
    "source":"tool-owned", "writers":["agent"], "readers":"agents",
    "lifecycle":"durable", "exclusive":false, "provision":false,
    "open_values":true, "placeholder":"claim:<value>", "values":[]
}]' "$namespace_collision/label-registry.json" >"$namespace_collision/registry.json"
mv "$namespace_collision/registry.json" "$namespace_collision/label-registry.json"
if discover "$namespace_collision" >"$namespace_collision/output" 2>"$namespace_collision/error"; then
    bad "excluded generated namespaces cannot be reclassified by open families"
elif [ ! -s "$namespace_collision/output" ] && grep -q 'overlaps prefix claim' "$namespace_collision/error"; then
    ok "excluded generated namespaces cannot be reclassified by open families"
else
    bad "excluded generated namespace overlap fails closed with a diagnostic"
fi

concrete_collision="$tmproot/concrete-collision"
mkdir -p "$concrete_collision"
write_agent_registry "$concrete_collision"
write_registry "$concrete_collision" api
write_labels "$concrete_collision" api
jq '.families += [{
    "family":"unsafe-area", "prefix":"area", "purpose":"Unsafe duplicate",
    "axis":"workflow", "source":"inline", "writers":["agent"], "readers":"agents",
    "lifecycle":"transient", "exclusive":false, "provision":false,
    "values":[{"value":"api"}]
}]' "$concrete_collision/label-registry.json" >"$concrete_collision/registry.json"
mv "$concrete_collision/registry.json" "$concrete_collision/label-registry.json"
if discover "$concrete_collision" >"$concrete_collision/output" 2>"$concrete_collision/error"; then
    bad "safe and unsafe families cannot declare the same concrete label"
elif [ ! -s "$concrete_collision/output" ] && grep -q 'declared by both family area and family unsafe-area' "$concrete_collision/error"; then
    ok "safe and unsafe families cannot declare the same concrete label"
else
    bad "cross-family concrete-label ambiguity fails closed with a diagnostic"
fi

case_duplicate="$tmproot/case-duplicate"
mkdir -p "$case_duplicate"
write_agent_registry "$case_duplicate"
write_registry "$case_duplicate" api
write_labels "$case_duplicate" api
jq '.families += [{
    "family":"case-duplicate", "prefix":null, "purpose":"Ambiguous case variants",
    "axis":"meta", "source":"inline", "writers":["agent"], "readers":"agents",
    "lifecycle":"durable", "exclusive":false, "provision":false,
    "values":[{"value":"Ready"},{"value":"ready","lifecycle":"transient"}]
}]' "$case_duplicate/label-registry.json" >"$case_duplicate/registry.json"
mv "$case_duplicate/registry.json" "$case_duplicate/label-registry.json"
if discover "$case_duplicate" >"$case_duplicate/output" 2>"$case_duplicate/error"; then
    bad "case-insensitive duplicates within one family cannot carry conflicting semantics"
elif [ ! -s "$case_duplicate/output" ] && grep -q 'case-insensitive duplicate label ready' "$case_duplicate/error"; then
    ok "case-insensitive duplicates within one family fail closed"
else
    bad "same-family case ambiguity fails closed with a diagnostic"
fi

# A prefix-less family's rendered name is just its bare value — so a value
# that happens to spell out an execution-control label (no family.prefix
# for safe()'s own check to see) must be caught on the RENDERED name, same
# as claim:/agent:/foreman: already are just above.
execution_control_concrete="$tmproot/execution-control-concrete"
mkdir -p "$execution_control_concrete"
write_agent_registry "$execution_control_concrete"
write_registry "$execution_control_concrete" api
write_labels "$execution_control_concrete" api
jq '.families += [{
    "family":"safe-strategy-model", "prefix":null, "purpose":"Unpaired execution-control label",
    "axis":"meta", "source":"inline", "writers":["agent"], "readers":"agents",
    "lifecycle":"durable", "exclusive":false, "provision":false,
    "values":[{"value":"strategy:plan"}]
}]' "$execution_control_concrete/label-registry.json" >"$execution_control_concrete/registry.json"
mv "$execution_control_concrete/registry.json" "$execution_control_concrete/label-registry.json"
if discover "$execution_control_concrete" >"$execution_control_concrete/output" 2>"$execution_control_concrete/error"; then
    bad "a prefix-less family cannot smuggle an execution-control-shaped concrete label past the reserved-prefix check"
elif [ ! -s "$execution_control_concrete/output" ] &&
    grep -q 'reserved label strategy:plan' "$execution_control_concrete/error"; then
    ok "a prefix-less family's execution-control-shaped concrete value is refused, not only family.prefix"
else
    bad "an execution-control-shaped concrete label from a prefix-less family should fail closed with a diagnostic: $(cat "$execution_control_concrete/error")"
fi

agent_version="$tmproot/agent-version"
mkdir -p "$agent_version"
write_agent_registry "$agent_version"
write_registry "$agent_version" api
write_labels "$agent_version" api
# 2 and 3 are both supported (harmon-init#1047 bumped harnesses' schema to 3);
# 4 stays genuinely unsupported and exercises the same fail-closed path.
jq '.schema_version = 4' "$agent_version/agent-registry.json" >"$agent_version/agent-registry-updated.json"
mv "$agent_version/agent-registry-updated.json" "$agent_version/agent-registry.json"
jq '.properties.schema_version.const = 4' "$agent_version/agent-registry.schema.json" >"$agent_version/agent-schema-updated.json"
mv "$agent_version/agent-schema-updated.json" "$agent_version/agent-registry.schema.json"
if discover "$agent_version" >"$agent_version/output" 2>"$agent_version/error"; then
    bad "unsupported agent-registry versions cannot be certified"
elif [ ! -s "$agent_version/output" ] && grep -q 'schema_version must be 2 or 3' "$agent_version/error"; then
    ok "unsupported agent-registry contracts fail closed after schema validation"
else
    bad "unsupported agent-registry contract fails with a semantic diagnostic"
fi

scope_order="$tmproot/scope-order"
mkdir -p "$scope_order"
write_agent_registry "$scope_order"
write_registry "$scope_order" api
write_labels "$scope_order" api
jq '.labels.claim.scopes = ["model", "family"]' \
    "$scope_order/agent-registry.json" >"$scope_order/agent-registry-updated.json"
mv "$scope_order/agent-registry-updated.json" "$scope_order/agent-registry.json"
if scope_output="$(discover "$scope_order")" && jq -e '.verified_semantics == true' \
    <<<"$scope_output" >/dev/null; then
    ok "agent-registry namespace scopes are interpreted as an unordered set"
else
    bad "schema-equivalent agent-registry scope order is accepted"
fi

missing_agent_placeholder="$tmproot/missing-agent-placeholder"
mkdir -p "$missing_agent_placeholder"
write_agent_registry "$missing_agent_placeholder"
write_registry "$missing_agent_placeholder" api
write_labels "$missing_agent_placeholder" api
jq 'del(.families[] | select(.family == "claim") | .placeholder)' \
    "$missing_agent_placeholder/label-registry.json" >"$missing_agent_placeholder/registry.json"
mv "$missing_agent_placeholder/registry.json" "$missing_agent_placeholder/label-registry.json"
if discover "$missing_agent_placeholder" >"$missing_agent_placeholder/output" \
    2>"$missing_agent_placeholder/error"; then
    bad "agent-registry families cannot omit their canonical placeholder"
elif [ ! -s "$missing_agent_placeholder/output" ] &&
    grep -q 'agent-registry families need a placeholder' "$missing_agent_placeholder/error"; then
    ok "agent-registry families require their canonical placeholder"
else
    bad "missing agent-registry placeholders fail closed with a diagnostic"
fi

reserved_concrete="$tmproot/reserved-concrete"
mkdir -p "$reserved_concrete"
write_agent_registry "$reserved_concrete"
write_registry "$reserved_concrete" api
write_labels "$reserved_concrete" api
jq '(.families |= map(select(.family != "claim"))) | .families += [{
    "family":"smuggled-claim", "prefix":null, "purpose":"Unsafe ownership marker",
    "axis":"meta", "source":"inline", "writers":["agent"], "readers":"agents",
    "lifecycle":"durable", "exclusive":false, "provision":false,
    "values":[{"value":"claim:gpt"}]
}]' "$reserved_concrete/label-registry.json" >"$reserved_concrete/registry.json"
mv "$reserved_concrete/registry.json" "$reserved_concrete/label-registry.json"
if discover "$reserved_concrete" >"$reserved_concrete/output" 2>"$reserved_concrete/error"; then
    bad "safe-looking concrete declarations cannot smuggle reserved labels"
elif [ ! -s "$reserved_concrete/output" ] && grep -q 'declares reserved label claim:gpt' "$reserved_concrete/error"; then
    ok "reserved concrete ownership namespaces fail closed"
else
    bad "reserved concrete namespace fails with a diagnostic"
fi

unsafe_open_overlap="$tmproot/unsafe-open-overlap"
mkdir -p "$unsafe_open_overlap"
write_agent_registry "$unsafe_open_overlap"
write_registry "$unsafe_open_overlap" api
write_labels "$unsafe_open_overlap" api
jq '.families += [{
    "family":"unsafe-area-open", "prefix":"area", "purpose":"Conflicting unsafe namespace",
    "axis":"workflow", "source":"tool-owned", "writers":["agent"], "readers":"agents",
    "lifecycle":"transient", "exclusive":false, "provision":false,
    "open_values":true, "placeholder":"area:<value>", "values":[]
}]' "$unsafe_open_overlap/label-registry.json" >"$unsafe_open_overlap/registry.json"
mv "$unsafe_open_overlap/registry.json" "$unsafe_open_overlap/label-registry.json"
if discover "$unsafe_open_overlap" >"$unsafe_open_overlap/output" 2>"$unsafe_open_overlap/error"; then
    bad "unsafe open families cannot overlap planning-safe closed families"
elif [ ! -s "$unsafe_open_overlap/output" ] && grep -q 'overlaps prefix area' "$unsafe_open_overlap/error"; then
    ok "unsafe open-family prefix overlaps fail closed"
else
    bad "unsafe open-family overlap fails with a diagnostic"
fi

prefix_null_open_overlap="$tmproot/prefix-null-open-overlap"
mkdir -p "$prefix_null_open_overlap"
write_agent_registry "$prefix_null_open_overlap"
write_registry "$prefix_null_open_overlap" api
write_labels "$prefix_null_open_overlap" api
jq '(.families[] | select(.family == "area")) |=
      (.prefix = null | .values[0].value = "area:api" | .values[1].value = "area:missing") |
    .families += [{
      "family":"unsafe-area-open", "prefix":"area", "purpose":"Conflicting unsafe namespace",
      "axis":"workflow", "source":"tool-owned", "writers":["agent"], "readers":"agents",
      "lifecycle":"transient", "exclusive":false, "provision":false,
      "open_values":true, "placeholder":"area:<value>", "values":[]
    }]' "$prefix_null_open_overlap/label-registry.json" \
    >"$prefix_null_open_overlap/registry.json"
mv "$prefix_null_open_overlap/registry.json" "$prefix_null_open_overlap/label-registry.json"
if discover "$prefix_null_open_overlap" >"$prefix_null_open_overlap/output" \
    2>"$prefix_null_open_overlap/error"; then
    bad "prefix-null concrete labels cannot bypass unsafe open-family overlap"
elif [ ! -s "$prefix_null_open_overlap/output" ] &&
    grep -q 'concrete label area:api from family area overlaps open family unsafe-area-open' \
        "$prefix_null_open_overlap/error"; then
    ok "prefix-null concrete labels cannot bypass unsafe open-family overlap"
else
    bad "prefix-null concrete/open-family overlap fails closed with a diagnostic"
fi

ambiguous="$tmproot/ambiguous"
mkdir -p "$ambiguous"
cp "$repo/label-registry.schema.json" "$ambiguous/label-registry.schema.json"
cat >"$ambiguous/label-registry.json" <<'JSON'
{
  "$schema":"./label-registry.schema.json",
  "schema_version":1,
  "families":[
    {"family":"first","prefix":"shared","purpose":"First","axis":"meta","source":"tool-owned","writers":["agent"],"readers":"agents","lifecycle":"durable","exclusive":false,"provision":false,"open_values":true,"placeholder":"shared:<x>","values":[]},
    {"family":"second","prefix":"shared","purpose":"Second","axis":"meta","source":"tool-owned","writers":["agent"],"readers":"agents","lifecycle":"durable","exclusive":false,"provision":false,"open_values":true,"placeholder":"shared:<x>","values":[]}
  ]
}
JSON
printf '[{"name":"shared:x","description":"Ambiguous"}]\n' >"$ambiguous/labels.json"
if discover "$ambiguous" >"$ambiguous/output" 2>"$ambiguous/error"; then
    bad "ambiguous registry interpretation fails closed"
elif [ ! -s "$ambiguous/output" ] && grep -Eq 'ambiguous|overlaps prefix shared' "$ambiguous/error"; then
    ok "ambiguous registry interpretation fails closed with a diagnostic"
else
    bad "ambiguous registry interpretation fails closed with a diagnostic"
fi

inaccessible="$tmproot/inaccessible"
mkdir -p "$inaccessible"
write_registry "$inaccessible" api
write_labels "$inaccessible" api
touch "$inaccessible/tree-denied"
if discover "$inaccessible" >"$inaccessible/output" 2>"$inaccessible/error"; then
    bad "inaccessible contents cannot masquerade as an absent registry"
elif [ ! -s "$inaccessible/output" ] && grep -q 'absence cannot be established' "$inaccessible/error"; then
    ok "inaccessible contents fail closed instead of falling back"
else
    bad "inaccessible contents fail closed instead of falling back"
fi

if grep -qF 'add it in the arming step instead' "$skill" ||
    grep -qF 'and apply that signal last' "$skill"; then
    bad "breakdown never retains a path that writes an arming signal"
elif grep -qF 'withhold it for the entire breakdown run' "$skill" &&
    grep -qF 'Do not add it later in this skill' "$skill"; then
    ok "breakdown never retains a path that writes an arming signal"
else
    bad "breakdown documents the trusted arming handoff"
fi

if grep -qF "family's \`purpose\` and" "$skill" &&
    grep -qF "candidate's live \`description\`" "$skill" &&
    grep -qF 'Copy the candidate' "$skill" &&
    grep -qF 'independently applicable to the chunk' "$skill" &&
    grep -qF 'Every emitted `requires` entry is a companion label' "$skill"; then
    ok "breakdown selects labels from emitted semantics and honors family constraints"
else
    bad "breakdown selects labels from emitted semantics and honors family constraints"
fi

if grep -qF 'On an organization-owned repository, choose exactly one valid native issue' \
    "$skill" &&
    grep -qF 'Do not duplicate or substitute it with a registry family' "$skill" &&
    grep -qF 'On a personal-account repository' "$skill" &&
    grep -qF 'choose exactly one `work-type` label' "$skill" &&
    grep -qF 'In `mode: registry`' "$skill" &&
    grep -qF 'In `mode: live-label-fallback`' "$skill" &&
    grep -qF 'work_type_selection: human-confirmation-required' "$skill" &&
    grep -qF 'Do not infer, rank, or nominate a' "$skill" &&
    grep -qF 'ask the human to name' "$skill" &&
    grep -qF 'The checker validates admissibility; it is not a work-type' "$skill" &&
    grep -qF 'Choose the single best match for the chunk' "$skill" &&
    grep -qF 'stop before approval or writes and ask the' "$skill" &&
    grep -qF 'never omit the classification or apply multiple candidates' "$skill"; then
    ok "breakdown enforces exactly one repository-appropriate work classification"
else
    bad "breakdown enforces exactly one repository-appropriate work classification"
fi

echo "==> migrated registry (harmon-init#1047: devflow source, schema_version 3)"
migrated="$tmproot/migrated"
mkdir -p "$migrated"
# This repo's own agent-registry.json/.schema.json are schema_version 3 as of
# #635 — real, not simulated — so the same copy write_agent_registry uses for
# the plain-discovery test above also exercises this fetch path.
write_agent_registry "$migrated"
write_migrated_label_registry "$migrated" api
write_migrated_labels "$migrated" api
if migrated_output="$(discover "$migrated" 2>"$migrated/error")"; then
    ok "a devflow-sourced registry with an agent-registry schema_version-3 pair is accepted"
else
    bad "a devflow-sourced registry with an agent-registry schema_version-3 pair is accepted: $(cat "$migrated/error")"
    migrated_output='{}'
fi

if jq -e '[.families[].family] | index("rigor") | not' <<<"$migrated_output" >/dev/null; then
    ok "a devflow-sourced human-only family (rigor) is filtered the same as an inline one"
else
    bad "a devflow-sourced human-only family (rigor) is filtered the same as an inline one"
fi

# strategy/rigor/tier/method are execution-control families: track-work's
# check-issue-metadata.sh rejects them unconditionally at authoring time
# (FORBIDDEN_RE, regardless of what a manifest's writers say), so breakdown
# must never emit them as planning candidates — even devflow-sourced,
# exclusive, and (for strategy/tier here) declaring "agent" as a writer.
for excluded_family in strategy rigor tier; do
    if jq -e --arg family "$excluded_family" \
        '[.families[].family] | index($family) | not' \
        <<<"$migrated_output" >/dev/null; then
        ok "the execution-control $excluded_family family is never emitted as planning vocabulary"
    else
        bad "the execution-control $excluded_family family is never emitted as planning vocabulary"
    fi
done

if ! grep -q '"name":"method:' <<<"$migrated_output" &&
    ! grep -q '"name": "method:' <<<"$migrated_output"; then
    ok "the retired method family contributes no labels"
else
    bad "the retired method family contributes no labels"
fi

if [ "$fail" -gt 0 ]; then
    echo "test-breakdown-labels: $fail failure(s), $pass passing." >&2
    exit 1
fi
echo "test-breakdown-labels: $pass passing."
