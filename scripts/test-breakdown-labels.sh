#!/usr/bin/env bash
# Hermetic tests for breakdown's registry-driven label discovery asset.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
asset="$repo/ai/skills/universal/breakdown/assets/discover-label-vocabulary.mjs"
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
    elif [[ "$joined" == *"/branches/"* ]]; then
        printf '{"commit":{"sha":"1111111111111111111111111111111111111111"}}\n'
        exit 0
    elif [[ "$joined" == *"/git/trees/"* ]]; then
        if [ -f "$fixture/tree-denied" ]; then
            echo "gh: Not Found (HTTP 404)" >&2
            exit 1
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
    else
        printf '{"default_branch":"trunk"}\n'
        exit 0
    fi
    content="$(base64 <"$file" | tr -d '\n')"
    printf '{"type":"file","encoding":"base64","content":"%s"}\n' "$content"
    exit 0
fi
if [ "$1" = label ] && [ "$2" = list ]; then
    cat "$fixture/labels.json"
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
      "family":"workflow","prefix":"phase","purpose":"Transient state","axis":"workflow",
      "source":"inline","writers":["agent"],"readers":"agents","lifecycle":"transient",
      "exclusive":false,"provision":true,"color":"123456","values":[{"value":"temporary","description":"Temporary"}]
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
    ok "valid registry is discovered"
else
    bad "valid registry is discovered"
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
    .exclusive == true and .labels[0].provision == true
' <<<"$output" >/dev/null; then
    ok "family exclusivity and provision metadata are preserved"
else
    bad "family exclusivity and provision metadata are preserved"
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

if ! grep -qE 'area:missing|suggest:gpt:ghost|suggest:claude:opus|claim:|phase:|foreman:' \
    <<<"$names"; then
    ok "missing, unknown, lifecycle, ownership, and arming labels are excluded"
else
    bad "missing, unknown, lifecycle, ownership, and arming labels are excluded"
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

fallback="$tmproot/fallback"
mkdir -p "$fallback"
cat >"$fallback/labels.json" <<'JSON'
[
  {"name":"feature","description":"Feature"},
  {"name":"area:api","description":"Area"},
  {"name":"claim:gpt","description":"Claim"},
  {"name":"agent:codex","description":"Legacy claim"},
  {"name":"foreman:approved","description":"Arm"}
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
elif [ ! -s "$ambiguous/output" ] && grep -q 'ambiguous' "$ambiguous/error"; then
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

if [ "$fail" -gt 0 ]; then
    echo "test-breakdown-labels: $fail failure(s), $pass passing." >&2
    exit 1
fi
echo "test-breakdown-labels: $pass passing."
