#!/usr/bin/env bash
# Hermetic tests for breakdown's registry-driven label discovery asset.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
asset="$repo/ai/skills/universal/breakdown/assets/discover-label-vocabulary.mjs"
skill="$repo/ai/skills/universal/breakdown/SKILL.md"
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*"
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2
}

mkdir -p "$tmproot/bin"
cat >"$tmproot/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

fixture="${BREAKDOWN_LABEL_FIXTURE:?}"
if [ "$1" = api ]; then
    joined="$*"
    if [[ "$joined" == *"/contents/label-registry.json"* ]]; then
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
        printf '{"default_branch":"trunk"}\n'
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
    .verified_semantics == true
' \
    <<<"$output" >/dev/null; then
    ok "registry result is bound to the remote default branch"
else
    bad "registry result is bound to the remote default branch"
fi

names="$(jq -r '.families[].labels[].name' <<<"$output" | sort)"
expected=$'area:api\ncustom:live\noverride:agent-safe\nsuggest:gpt\nsuggest:gpt:sol'
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

if jq -e '
    .families[] | select(.family == "suggest-model") | .labels[0] |
    .name == "suggest:gpt:sol" and .requires == ["suggest:gpt"]
' <<<"$output" >/dev/null; then
    ok "model suggestions require their live family suggestion"
else
    bad "model suggestions require their live family suggestion"
fi

if ! grep -qE 'area:missing|suggest:gpt:ghost|suggest:claude:opus|claim:|phase:|gated:|foreman:' \
    <<<"$names"; then
    ok "missing, unknown, lifecycle, ownership, gated, and arming labels are excluded"
else
    bad "missing, unknown, lifecycle, ownership, gated, and arming labels are excluded"
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
  {"name":"claim:gpt","description":"Claim"},
  {"name":"Claim:claude","description":"Case-varied claim"},
  {"name":"agent:codex","description":"Legacy claim"},
  {"name":"Foreman:approved","description":"Case-varied arm"}
]
JSON
fallback_output="$(discover "$fallback")"
if jq -e '
    .mode == "live-label-fallback" and .verified_semantics == false and
    ([.labels[].name] | sort) == ["area:api", "feature"]
' <<<"$fallback_output" >/dev/null; then
    ok "missing registry falls back to bounded non-arming live labels"
else
    bad "missing registry falls back to bounded non-arming live labels"
fi

empty="$tmproot/empty"
mkdir -p "$empty"
touch "$empty/empty-repository"
printf '[{"name":"feature","description":"Feature"}]\n' >"$empty/labels.json"
if empty_output="$(discover "$empty")" && jq -e '
    .mode == "live-label-fallback" and .default_branch_commit == null and
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

suggest_concrete="$tmproot/suggest-concrete"
mkdir -p "$suggest_concrete"
write_agent_registry "$suggest_concrete"
write_registry "$suggest_concrete" api
write_labels "$suggest_concrete" api
jq '.families += [{
    "family":"unsafe-suggest-model", "prefix":null, "purpose":"Reserved unsafe model label",
    "axis":"workflow", "source":"inline", "writers":["agent"], "readers":"agents",
    "lifecycle":"transient", "exclusive":false, "provision":false,
    "values":[{"value":"suggest:gpt:sol"}]
}]' "$suggest_concrete/label-registry.json" >"$suggest_concrete/registry.json"
mv "$suggest_concrete/registry.json" "$suggest_concrete/label-registry.json"
if suggest_output="$(discover "$suggest_concrete")" && jq -e '
    any(.families[].labels[]; .name == "suggest:gpt") and
    (any(.families[].labels[]; .name == "suggest:gpt:sol") | not)
' <<<"$suggest_output" >/dev/null; then
    ok "suggest-model cannot reclassify an unsafe concrete declaration"
else
    bad "suggest-model honors concrete-label reservations"
fi

safe_suggest_concrete="$tmproot/safe-suggest-concrete"
mkdir -p "$safe_suggest_concrete"
write_agent_registry "$safe_suggest_concrete"
write_registry "$safe_suggest_concrete" api
write_labels "$safe_suggest_concrete" api
jq '.families += [{
    "family":"safe-suggest-model", "prefix":null, "purpose":"Unpaired model label",
    "axis":"model", "source":"inline", "writers":["agent"], "readers":"agents",
    "lifecycle":"durable", "exclusive":false, "provision":false,
    "values":[{"value":"suggest:gpt:sol"}]
}]' "$safe_suggest_concrete/label-registry.json" >"$safe_suggest_concrete/registry.json"
mv "$safe_suggest_concrete/registry.json" "$safe_suggest_concrete/label-registry.json"
if discover "$safe_suggest_concrete" >"$safe_suggest_concrete/output" 2>"$safe_suggest_concrete/error"; then
    bad "planning-safe model-shaped suggestions cannot bypass family pairing"
elif [ ! -s "$safe_suggest_concrete/output" ] &&
    grep -q 'model-shaped suggestion suggest:gpt:sol outside the paired suggest-model path' \
        "$safe_suggest_concrete/error"; then
    ok "planning-safe model-shaped suggestions cannot bypass family pairing"
else
    bad "unpaired model-shaped suggestions fail closed with a diagnostic"
fi

agent_version="$tmproot/agent-version"
mkdir -p "$agent_version"
write_agent_registry "$agent_version"
write_registry "$agent_version" api
write_labels "$agent_version" api
jq '.schema_version = 3' "$agent_version/agent-registry.json" >"$agent_version/agent-registry-updated.json"
mv "$agent_version/agent-registry-updated.json" "$agent_version/agent-registry.json"
jq '.properties.schema_version.const = 3' "$agent_version/agent-registry.schema.json" >"$agent_version/agent-schema-updated.json"
mv "$agent_version/agent-schema-updated.json" "$agent_version/agent-registry.schema.json"
if discover "$agent_version" >"$agent_version/output" 2>"$agent_version/error"; then
    bad "unsupported agent-registry versions cannot be certified"
elif [ ! -s "$agent_version/output" ] && grep -q 'schema_version must be 2' "$agent_version/error"; then
    ok "unsupported agent-registry contracts fail closed after schema validation"
else
    bad "unsupported agent-registry contract fails with a semantic diagnostic"
fi

scope_order="$tmproot/scope-order"
mkdir -p "$scope_order"
write_agent_registry "$scope_order"
write_registry "$scope_order" api
write_labels "$scope_order" api
jq '.labels.suggest.scopes = ["model", "family"] | .labels.claim.scopes = ["model", "family"]' \
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
jq 'del(.families[] | select(.family == "suggest") | .placeholder)' \
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

if grep -qF 'On an organization-owned repository' "$skill" &&
    grep -qF 'do not duplicate or substitute it with a registry' "$skill" &&
    grep -qF 'personal-account repository' "$skill" &&
    grep -qF 'use an independently' "$skill"; then
    ok "breakdown distinguishes organization issue types from personal work-type labels"
else
    bad "breakdown distinguishes organization issue types from personal work-type labels"
fi

if [ "$fail" -gt 0 ]; then
    echo "test-breakdown-labels: $fail failure(s), $pass passing." >&2
    exit 1
fi
echo "test-breakdown-labels: $pass passing."
