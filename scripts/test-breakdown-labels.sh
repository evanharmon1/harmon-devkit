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
      "family":"priority","prefix":"priority","purpose":"Human priority","axis":"classification",
      "source":"inline","writers":["agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"123456","values":[{"value":"high","description":"High"}]
    },
    {
      "family":"priority-ai","prefix":"priority-ai","purpose":"Helper-derived priority","axis":"classification",
      "source":"inline","writers":["agent"],"readers":"humans","lifecycle":"durable",
      "exclusive":true,"provision":true,"color":"123456","values":[{"value":"p1","description":"High priority"}]
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
  {"name":"priority-ai:p1","description":"Helper-derived priority"},
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

if ! grep -qE 'area:missing|suggest:|claim:|phase:|gated:|foreman:|priority:|priority-ai:|effort:|tier:' \
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

real_registry="$tmproot/real-registry"
mkdir -p "$real_registry"
write_agent_registry "$real_registry"
cp "$repo/label-registry.json" "$real_registry/label-registry.json"
cp "$repo/label-registry.schema.json" "$real_registry/label-registry.schema.json"
cmp -s "$repo/label-registry.json" "$real_registry/label-registry.json" || exit 1
jq '[.families[] | . as $family | .values[] |
    {name:(if $family.prefix == null then .value else ($family.prefix + ":" + .value) end),
     description:(.description // "")}] | unique_by(.name)' "$real_registry/label-registry.json" >"$real_registry/labels.json"
if real_output="$(discover "$real_registry" 2>"$real_registry/error")" && jq -e '
    .mode == "registry" and .verified_semantics == true and
    any(.families[]; .source != "classification-helper" and (.labels | length) > 0)
' <<<"$real_output" >/dev/null; then
    ok "byte-copy real repository registry emits planning vocabulary despite excluded shared prefixes"
else
    bad "real repository registry discovery succeeds: $(cat "$real_registry/error")"
fi

# Byte-exact snapshot of harmon-init's label registry (cycle-3 compatibility regression).
# Embedded so the test needs no sibling checkout at runtime.
init_registry="$tmproot/init-registry"
mkdir -p "$init_registry"
write_agent_registry "$init_registry"
cp "$repo/label-registry.schema.json" "$init_registry/label-registry.schema.json"
cat >"$init_registry/label-registry.json" <<'HARMON_INIT_RATING_REGISTRY'
{
  "$schema": "./label-registry.schema.json",
  "schema_version": 1,
  "families": [
    {
      "family": "concern",
      "prefix": null,
      "purpose": "Cross-cutting concerns worth filtering on, color-coded as one family.",
      "axis": "concern",
      "source": "inline",
      "writers": ["human"],
      "writer_note": "humans, at triage",
      "readers": "humans, saved views",
      "lifecycle": "durable",
      "lifecycle_note": "applied when true, removed when not",
      "exclusive": false,
      "provision": true,
      "color": "5319E7",
      "values": [
        {
          "value": "sec",
          "description": "Security concern"
        },
        {
          "value": "a11y",
          "description": "Accessibility concern"
        },
        {
          "value": "perf",
          "description": "Performance concern"
        },
        {
          "value": "tech-debt",
          "description": "Technical debt"
        },
        {
          "value": "i18n",
          "description": "Internationalization"
        },
        {
          "value": "l10n",
          "description": "Localization"
        }
      ]
    },
    {
      "family": "provenance",
      "prefix": null,
      "purpose": "Where the work came from — durable provenance, never removed.",
      "axis": "provenance",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "whoever files or authors the work, human or agent",
      "readers": "humans, saved views",
      "lifecycle": "durable",
      "lifecycle_note": "durable provenance — never removed",
      "exclusive": false,
      "provision": true,
      "color": "EC4899",
      "values": [
        {
          "value": "customer-request",
          "description": "Requested by a customer"
        },
        {
          "value": "ai-generated",
          "description": "Created or authored by an AI agent"
        }
      ]
    },
    {
      "family": "initiative",
      "prefix": null,
      "purpose": "Parent issue horizon: a finite deliverable, a perennial area of ownership, or a human-task collector.",
      "axis": "meta",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "humans, at planning or grooming; agents when filing a (HUMAN)/(QA) collector or an approved breakdown",
      "readers": "humans, saved views",
      "lifecycle": "durable",
      "lifecycle_note": "applied to a parent while its role is current; removed or changed when its horizon changes",
      "exclusive": true,
      "provision": true,
      "color": "8250DF",
      "values": [
        {
          "value": "epic",
          "description": "Time-bound parent initiative with a defined future deliverable"
        },
        {
          "value": "umbrella",
          "description": "Open-ended parent for an enduring area, topic, or team, or a (HUMAN)/(QA) collector"
        }
      ]
    },
    {
      "family": "human-work",
      "prefix": null,
      "purpose": "Work only a human can do or verify, kept off the agent dispatch path.",
      "axis": "meta",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "whoever files the human-only issue, human or agent",
      "readers": "humans, saved views; agents, to skip dispatch",
      "lifecycle": "durable",
      "lifecycle_note": "applied while only a human can do the work; removed if it becomes dispatchable",
      "exclusive": false,
      "provision": true,
      "color": "FBCA04",
      "values": [
        {
          "value": "human",
          "description": "Human-only work: actions or QA; never dispatched to an agent"
        }
      ]
    },
    {
      "family": "workflow",
      "prefix": null,
      "purpose": "Transient triage and review-hand-off states; blocked is the non-issue-blocker flag.",
      "axis": "workflow",
      "source": "inline",
      "writers": ["human"],
      "writer_note": "humans, at triage",
      "readers": "humans, the Triage view",
      "lifecycle": "transient",
      "lifecycle_note": "transient — removed as soon as the state clears",
      "exclusive": false,
      "provision": true,
      "color": "E36209",
      "values": [
        {
          "value": "needs-triage",
          "description": "Awaiting triage",
          "writers": ["human", "agent", "tool:github-actions"],
          "writer_note": "humans, the issue forms, the triage skill, and the GitHub Actions classification reconciler (derived: added while classification is incomplete, removed once it is complete)",
          "lifecycle_note": "added freely at filing; removed only when classification is complete"
        },
        {
          "value": "needs-requirements",
          "description": "Requirements not yet defined"
        },
        {
          "value": "blocked",
          "description": "Blocked by a non-issue dependency (reason in a comment)"
        },
        {
          "value": "waiting",
          "description": "Waiting on an external party"
        },
        {
          "value": "needs-decision",
          "description": "Needs a decision before it can proceed"
        },
        {
          "value": "needs-response",
          "description": "Awaiting a response"
        },
        {
          "value": "needs-communication",
          "description": "An update needs to be communicated out"
        },
        {
          "value": "needs-review",
          "description": "PR ready for human review; out of the agent queue",
          "writers": ["human", "agent"],
          "writer_note": "the integration stage, at ready-for-review; humans",
          "readers": "humans, the review list; the agent queue, which excludes it",
          "lifecycle_note": "added at ready-for-review, when `claim:*` is removed; removed if review pulls the work back into fix rounds"
        }
      ]
    },
    {
      "family": "work-type",
      "prefix": null,
      "purpose": "Kind of work, on personal-account repos where native issue Type is unavailable; org repos set native Type instead.",
      "axis": "work-type",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "the issue forms on personal-account repos; humans or agents at triage",
      "readers": "humans, saved views",
      "lifecycle": "durable",
      "lifecycle_note": "durable classification — org repos use native issue Type and no work-type label",
      "exclusive": false,
      "provision": true,
      "values": [
        {
          "value": "bug",
          "description": "Something isn't working",
          "color": "D73A4A"
        },
        {
          "value": "feature",
          "description": "New feature or request",
          "color": "A2EEEF"
        },
        {
          "value": "task",
          "description": "General work: maintenance, chores, cleanup",
          "color": "6E7781"
        },
        {
          "value": "research",
          "description": "Produces a decision or written answer, not a code change",
          "color": "0E7C86"
        },
        {
          "value": "documentation",
          "description": "Improvements or additions to documentation",
          "color": "0075CA",
          "provision": false,
          "writer_note": "GitHub ships it at repo creation; humans or agents apply it at triage",
          "trust_note": "not provisioned — a GitHub repo-creation default adopted into the work-type vocabulary"
        },
        {
          "value": "question",
          "description": "Further information is requested",
          "color": "D876E3",
          "provision": false,
          "writer_note": "GitHub ships it at repo creation; humans or agents apply it at triage",
          "trust_note": "not provisioned — a GitHub repo-creation default adopted into the work-type vocabulary"
        },
        {
          "value": "dependencies",
          "provision": false,
          "writers": ["tool:renovate"],
          "writer_note": "Renovate, when it manages dependency updates",
          "trust_note": "not provisioned — Renovate creates it on demand; never deleted by setup",
          "lifecycle_note": "tool-managed by Renovate"
        },
        {
          "value": "enhancement",
          "description": "New feature or request",
          "color": "A2EEEF",
          "retired": true,
          "writer_note": "nobody — replaced by `feature`",
          "trust_note": "retired — the GitHub repo-creation default this vocabulary replaces with `feature`; never provisioned",
          "lifecycle_note": "use guarded `--prune` with `--migrate enhancement=feature`"
        }
      ]
    },
    {
      "family": "layer",
      "prefix": "layer",
      "purpose": "Stack slice the change lives in; the label family is the only surface for this taxonomy.",
      "axis": "classification",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "humans or agents, at triage",
      "readers": "humans, `gh issue list --label`",
      "lifecycle": "durable",
      "lifecycle_note": "durable classification; the label family is the only surface — there is no paired project field; `layer:none` records that the axis does not apply",
      "exclusive": true,
      "provision": true,
      "color": "1D76DB",
      "values": [
        {
          "value": "ui",
          "description": "Components, styling, interaction, tokens, a11y. No data change"
        },
        {
          "value": "logic",
          "description": "Business rules, handlers, calculation"
        },
        {
          "value": "data",
          "description": "Schema, indexes, validators, migrations"
        },
        {
          "value": "integration",
          "description": "External boundary: webhooks, API clients, credentials"
        },
        {
          "value": "infra",
          "description": "Hosts, networking, containers, provisioning — IaC and config rather than app code"
        },
        {
          "value": "none",
          "description": "Inapplicable: the work is not in a single stack slice"
        }
      ]
    },
    {
      "family": "domain",
      "prefix": "domain",
      "purpose": "Product capability the work serves (problem space); the label family is the only surface for this taxonomy.",
      "axis": "classification",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "humans or agents, at triage",
      "readers": "humans, `gh issue list --label`",
      "lifecycle": "durable",
      "lifecycle_note": "durable classification; the label family is the only surface — there is no paired project field; `domain:none` records that the axis does not apply",
      "exclusive": true,
      "provision": true,
      "color": "FBCA04",
      "values": [
        {
          "value": "template",
          "description": "Generating a new repo from the template — the copier copy journey"
        },
        {
          "value": "standardization",
          "description": "Keeping existing repos current — copier update, drift audits, migrations, adoption"
        },
        {
          "value": "dev-loop",
          "description": "The daily developer workflow: gates, hooks, tasks, worktrees, review stages"
        },
        {
          "value": "agent-workflow",
          "description": "AI-delegated work: foreman dispatch, claims, skills, Claude Actions"
        },
        {
          "value": "project-tracking",
          "description": "Issues, labels, boards, and the PM strategy"
        },
        {
          "value": "auth",
          "description": "Toolchain credentials and auth: gh, Claude, Codex, 1Password, tokens"
        },
        {
          "value": "delivery",
          "description": "Releases and versioning: release-please, tags, release guards, consumer pickup"
        },
        {
          "value": "environment",
          "description": "The ready-to-code environment: devcontainer, images, codespaces, editor setup"
        },
        {
          "value": "none",
          "description": "Inapplicable: the work serves no single product capability"
        },
        {
          "value": "platform",
          "retired": true,
          "writer_note": "nobody — retired at root",
          "trust_note": "retired — split across dev-loop/delivery/environment; never provisioned here",
          "lifecycle_note": "choose replacement domains per record, relabel each record, then use guarded `--prune` only after `domain:platform` reaches zero associations"
        },
        {
          "value": "billing",
          "retired": true,
          "writer_note": "nobody — retired at root",
          "trust_note": "retired — a generic starter value this repo never needed",
          "lifecycle_note": "choose the replacement, then use guarded `--prune` with `--migrate OLD=NEW`"
        }
      ]
    },
    {
      "family": "area",
      "prefix": "area",
      "purpose": "Codebase subsystem the work lives in (solution space); at most one per issue.",
      "axis": "classification",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "humans or agents, at triage",
      "readers": "humans, `gh issue list --label`",
      "lifecycle": "durable",
      "lifecycle_note": "durable classification; area = solution space, domain = problem space, layer = stack slice; `area:none` records that the axis does not apply",
      "exclusive": true,
      "provision": true,
      "color": "0E8A16",
      "values": [
        {
          "value": "copier",
          "description": "The templating engine: copier.yml, answers, validators, jinja, render matrix"
        },
        {
          "value": "devcontainer",
          "description": "Dev containers, images, features"
        },
        {
          "value": "ci",
          "description": "Repository-wide CI workflows and plumbing; subsystem workflows belong to that subsystem's area"
        },
        {
          "value": "tasks",
          "description": "Taskfile targets and scripts/ glue without a more specific area; security targets are area:security"
        },
        {
          "value": "tests",
          "description": "The shared test-*.sh suite and gates; a subsystem's own tests belong to its area"
        },
        {
          "value": "deps",
          "description": "Cross-cutting dependency automation and bumps; subsystem dependencies belong to its area"
        },
        {
          "value": "skills",
          "description": "Shared agent skills and skills sync; subsystem workflow skills belong to that subsystem's area"
        },
        {
          "value": "foreman",
          "description": "Foreman config, wrapper tasks, adapters"
        },
        {
          "value": "gauntlet",
          "description": "The challenge/review second-model stage: scripts, gates, and skill wiring"
        },
        {
          "value": "worktree",
          "description": "Worktree lifecycle tooling"
        },
        {
          "value": "release",
          "description": "release-please, tags, release guards"
        },
        {
          "value": "security",
          "description": "Scanners, secret handling, hardening"
        },
        {
          "value": "pm",
          "description": "Labels, projects, issue tooling, PM docs"
        },
        {
          "value": "docs",
          "description": "Documentation content and structure; a subsystem's own docs belong to that subsystem's area"
        },
        {
          "value": "none",
          "description": "Inapplicable: the work belongs to no single codebase subsystem"
        },
        {
          "value": "template",
          "retired": true,
          "writer_note": "nobody — renamed",
          "trust_note": "retired — renamed to `area:copier` (the engine was what it labeled)",
          "lifecycle_note": "use guarded `--prune` with `--migrate area:template=area:copier`"
        },
        {
          "value": "codex",
          "retired": true,
          "writer_note": "nobody — renamed",
          "trust_note": "retired — renamed to `area:gauntlet`; codex is the current backend, not the stage",
          "lifecycle_note": "use guarded `--prune` with `--migrate area:codex=area:gauntlet`"
        }
      ]
    },
    {
      "family": "impact",
      "prefix": "impact",
      "purpose": "Expected significance of completing the issue: core versus marginal benefit, not common versus uncommon path — a rare but severe bug can be high.",
      "axis": "classification",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "humans or agents, at triage or filing — agent-authored issues arrive with it set",
      "readers": "humans, saved views",
      "lifecycle": "durable",
      "lifecycle_note": "durable classification; required for an issue to count as triaged",
      "trust_note": "provisioned; **advisory** — a required axis for triaged; arms nothing",
      "exclusive": true,
      "provision": true,
      "color": "0052CC",
      "values": [
        {
          "value": "minimal",
          "description": "Impact: marginal benefit; most users would not notice it"
        },
        {
          "value": "low",
          "description": "Impact: small benefit to a few users or a narrow use case"
        },
        {
          "value": "medium",
          "description": "Impact: clear benefit to a meaningful share of users or goals"
        },
        {
          "value": "high",
          "description": "Impact: core benefit, or severe harm prevented even if rarely triggered"
        },
        {
          "value": "massive",
          "description": "Impact: transformative; current goals depend on it"
        }
      ]
    },
    {
      "family": "risk",
      "prefix": "risk",
      "purpose": "How consequential a failure is if the change is implemented incorrectly; for a bug fix, the danger of the fix — the harm it prevents belongs in Impact.",
      "axis": "classification",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "humans or agents, at triage or filing — agent-authored issues arrive with it set",
      "readers": "humans, saved views; the Tier derivation (Risk × Complexity)",
      "lifecycle": "durable",
      "lifecycle_note": "durable classification; required for triaged; whoever changes it re-derives the Tier in the same write",
      "trust_note": "provisioned; **read by agents** — an input to the derived Tier (Risk × Complexity); arms nothing",
      "exclusive": true,
      "provision": true,
      "color": "B60205",
      "values": [
        {
          "value": "trivial",
          "description": "Risk: a mistake is harmless and trivially reversible"
        },
        {
          "value": "low",
          "description": "Risk: a mistake is contained, caught quickly, and cheap to undo"
        },
        {
          "value": "medium",
          "description": "Risk: a mistake breaks a feature or needs a careful rollback"
        },
        {
          "value": "high",
          "description": "Risk: a mistake reaches many users or their data; recovery is costly"
        },
        {
          "value": "critical",
          "description": "Risk: a mistake risks data loss, security exposure, or an irreversible outage"
        }
      ]
    },
    {
      "family": "complexity",
      "prefix": "complexity",
      "purpose": "How difficult the work is to understand, design, implement, and verify correctly, including how likely it is to grow; set on every issue, never a time estimate.",
      "axis": "classification",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "humans or agents, at triage or filing — agent-authored issues arrive with it set",
      "readers": "humans, saved views; the Tier derivation (Risk × Complexity)",
      "lifecycle": "durable",
      "lifecycle_note": "durable classification; required for triaged; whoever changes it re-derives the Tier in the same write",
      "trust_note": "provisioned; **read by agents** — an input to the derived Tier (Risk × Complexity); arms nothing",
      "exclusive": true,
      "provision": true,
      "color": "F9D0C4",
      "values": [
        {
          "value": "xs",
          "description": "Complexity: a tiny, well-understood change with obvious verification"
        },
        {
          "value": "s",
          "description": "Complexity: small and local; a clear approach across a few files"
        },
        {
          "value": "m",
          "description": "Complexity: moderate; several components and some design choices"
        },
        {
          "value": "l",
          "description": "Complexity: large; cross-cutting, with real design and wide verification"
        },
        {
          "value": "xl",
          "description": "Complexity: very large or uncertain; likely to grow or need splitting"
        }
      ]
    },
    {
      "family": "priority",
      "prefix": "priority",
      "purpose": "The human's ranking of when to work the issue; never required — unset means an agent asks before starting.",
      "axis": "meta",
      "source": "inline",
      "writers": ["human"],
      "writer_note": "humans only — an agent never sets or changes it",
      "readers": "humans, saved views; the agent queue (an issue with no Priority is not queued)",
      "lifecycle": "durable",
      "lifecycle_note": "set by a human when ranking the work; changed as priorities move",
      "trust_note": "provisioned; **advisory** — orders the agent queue; arms nothing",
      "exclusive": true,
      "provision": true,
      "color": "FF7619",
      "values": [
        {
          "value": "urgent",
          "description": "Priority: work on this now, ahead of everything else"
        },
        {
          "value": "high",
          "description": "Priority: next up; schedule soon"
        },
        {
          "value": "medium",
          "description": "Priority: normal queue order"
        },
        {
          "value": "low",
          "description": "Priority: when nothing more pressing remains"
        }
      ]
    },
    {
      "family": "priority-ai",
      "prefix": "priority-ai",
      "purpose": "The AI's suggested priority, p0–p4; the human Priority overrides it, and for a bug it reads as severity (how bad, and how important to fix before a merge or deploy). Advisory.",
      "axis": "meta",
      "source": "inline",
      "writers": ["human", "agent"],
      "writer_note": "agents or humans — the AI's suggestion, never required; a review finding filed as an issue carries its adjudicated badge (P0→p0, P1→p1, P2→p2, P3→p3; nothing from a review maps to p4)",
      "readers": "humans, saved views; the effective priority, which is the human `priority` when set and else this suggestion",
      "lifecycle": "durable",
      "lifecycle_note": "written by an agent or human when classifying or filing the issue; changed as the AI learns more; the human `priority` overrides it without clearing it",
      "trust_note": "provisioned; **advisory** — the AI's suggestion, overridden by the human `priority` family; arms nothing",
      "exclusive": true,
      "provision": true,
      "values": [
        {
          "value": "p0",
          "description": "Priority (AI): blocks a merge or deploy — critical",
          "color": "B60205"
        },
        {
          "value": "p1",
          "description": "Priority (AI): a real defect or must-do; next",
          "color": "FF7619"
        },
        {
          "value": "p2",
          "description": "Priority (AI): worth doing, not blocking",
          "color": "FBCA04"
        },
        {
          "value": "p3",
          "description": "Priority (AI): cosmetic or informational",
          "color": "1D76DB"
        },
        {
          "value": "p4",
          "description": "Priority (AI): negligible",
          "color": "BFC5CB"
        }
      ]
    },
    {
      "family": "effort",
      "prefix": "effort",
      "purpose": "The human time estimate for work a human will do, on a modified Fibonacci ladder; human tasks only, never agent work.",
      "axis": "meta",
      "source": "inline",
      "writers": ["human"],
      "writer_note": "humans only, on a human task — agent work carries Complexity instead",
      "readers": "humans, saved views",
      "lifecycle": "durable",
      "lifecycle_note": "set by a human when estimating a human task; agent issues never carry it",
      "trust_note": "provisioned; **advisory** — a human estimate; arms nothing",
      "exclusive": true,
      "provision": true,
      "color": "C5DEF5",
      "values": [
        {
          "value": "1",
          "description": "Effort: 1, the smallest step on the modified Fibonacci ladder (human tasks only)"
        },
        {
          "value": "2",
          "description": "Effort: 2 on the modified Fibonacci ladder (human tasks only)"
        },
        {
          "value": "3",
          "description": "Effort: 3 on the modified Fibonacci ladder (human tasks only)"
        },
        {
          "value": "5",
          "description": "Effort: 5 on the modified Fibonacci ladder (human tasks only)"
        },
        {
          "value": "8",
          "description": "Effort: 8 on the modified Fibonacci ladder (human tasks only)"
        },
        {
          "value": "13",
          "description": "Effort: 13 on the modified Fibonacci ladder (human tasks only)"
        },
        {
          "value": "20",
          "description": "Effort: 20, the largest step on the modified Fibonacci ladder (human tasks only)"
        }
      ]
    },
    {
      "family": "rigor",
      "prefix": "rigor",
      "purpose": "How much confidence, effort, depth, and budget an agent works the issue under; values must match .devflow.toml's [rigor.*] tables.",
      "axis": "strategy",
      "source": "devflow",
      "writers": ["human"],
      "writer_note": "humans, at triage — **never an agent on itself**",
      "readers": "agents, when entering the Dev Loop",
      "lifecycle": "durable",
      "lifecycle_note": "set when the default rigor is wrong for the change; survives the work",
      "trust_note": "provisioned; **read by agents** — selects a rounds policy, five role tiers, and a breadth envelope; arms nothing",
      "exclusive": false,
      "provision": true,
      "color": "D4C5F9",
      "values": [
        {
          "value": "cursory",
          "description": "Rigor: one quick adversarial glance, economy elsewhere — near-zero-risk changes"
        },
        {
          "value": "light",
          "description": "Rigor: light rounds, frontier orchestrator/challenger, economy implementer"
        },
        {
          "value": "standard",
          "description": "Rigor: standard rounds and breadth, frontier challenger, standard implementer — the default"
        },
        {
          "value": "thorough",
          "description": "Rigor: thorough rounds, apex orchestrator/challenger, frontier reviewer"
        },
        {
          "value": "deep",
          "description": "Rigor: deep rounds, apex orchestrator/challenger, frontier implementer/reviewer"
        },
        {
          "value": "forensic",
          "description": "Rigor: maximum scrutiny at every role — irreversible failure modes, security, data paths"
        }
      ]
    },
    {
      "family": "tier",
      "prefix": "tier",
      "purpose": "The issue's model stratum, derived from Risk × Complexity and stored as a cache; a human pins one with tier:pinned.",
      "axis": "strategy",
      "source": "inline",
      "writers": ["human", "agent", "tool:github-actions"],
      "writer_note": "agents, in the write that sets Risk or Complexity, and the GitHub Actions reconciler; humans may set one, and pin it with `tier:pinned`",
      "readers": "humans and agents — the issue's derived (or pinned) Tier, an input to the implementer tier; models are classified in `agent-registry.json` (ADR 2026-09-30)",
      "lifecycle": "durable",
      "lifecycle_note": "a materialized cache — rewritten whenever Risk or Complexity changes and by the scheduled reconciler (daily on personal-account repositories, monthly on organization ones), recomputed by readers when absent; never rewritten while `tier:pinned` is present",
      "trust_note": "provisioned; **read by agents** — a pin outranks the derived Tier and both rank below an operator instruction; resolved against `.devflow.toml`'s `tier_order`; arms nothing",
      "exclusive": false,
      "provision": true,
      "color": "7057FF",
      "values": [
        {
          "value": "local",
          "description": "Model tier: work a small self-hosted model can do, possibly slowly"
        },
        {
          "value": "economy",
          "description": "Model tier: cheapest qualified hosted model first; escalation allowed"
        },
        {
          "value": "standard",
          "description": "Model tier: reliable general-purpose coding model first"
        },
        {
          "value": "frontier",
          "description": "Model tier: opus-class heavyweights; no warm-up on weaker models"
        },
        {
          "value": "apex",
          "description": "Model tier: mythos-class leading edge (fable, sol)"
        },
        {
          "value": "pinned",
          "description": "Tier pin: a human fixed this issue's tier; nothing automated rewrites it",
          "writers": ["human"],
          "writer_note": "humans only, from the GitHub UI, together with setting the Tier",
          "readers": "agents and automation — a pinned Tier is never rewritten",
          "lifecycle_note": "added with the Tier value; removed to hand the Tier back to derivation; a human pinning a different tier replaces the existing Tier label first, since two tier values at once is a conflict for the reader to resolve, never one a writer creates",
          "trust_note": "provisioned; **provenance-checked** — an interactive session confirms a pin the operator has not authorized, and unattended automation honors one only after verifying who applied it (ADR 2026-09-30 D5)"
        },
        {
          "value": "adaptive",
          "description": "Model tier: cheap preflight classifies, then chooses or escalates",
          "retired": true,
          "writer_note": "nobody — retired 2026-10-01",
          "readers": "humans — retired, see the derived Tier (`tier:<value>`)",
          "trust_note": "retired — no rung on the Tier scale (ADR 2026-09-30 D8); never provisioned",
          "lifecycle_note": "remove the label from each issue — it then resolves through its derived Tier — then use guarded `--prune`"
        }
      ]
    },
    {
      "family": "tier-role",
      "prefix": null,
      "purpose": "Role-scoped tier override: pins one role to a tier, refining (never replacing) the rigor profile for that role alone.",
      "axis": "strategy",
      "source": "inline",
      "writers": ["human"],
      "writer_note": "humans, at triage or planning — never an agent on itself",
      "readers": "humans and agents — targets exactly the role it names; models are classified in `agent-registry.json` (ADR 2026-08-16/2026-08-24), unlike the unqualified `tier:<value>`, which is the issue's stored Tier rather than a role override",
      "lifecycle": "durable",
      "lifecycle_note": "set when one role's tier should differ from the rigor's own profile; strongest-wins per role",
      "trust_note": "provisioned; **advisory** — resolved against `.devflow.toml`'s `tier_order`; arms nothing",
      "exclusive": false,
      "provision": true,
      "color": "7057FF",
      "values": [
        {
          "value": "tier:orchestrator:local",
          "description": "Tier override: pin the orchestrator to local — self-hosted endpoint first"
        },
        {
          "value": "tier:orchestrator:economy",
          "description": "Tier override: pin the orchestrator to economy — cheapest qualified hosted model"
        },
        {
          "value": "tier:orchestrator:standard",
          "description": "Tier override: pin the orchestrator to standard — reliable general-purpose coding model"
        },
        {
          "value": "tier:orchestrator:frontier",
          "description": "Tier override: pin the orchestrator to frontier — opus-class heavyweight, no warm-up"
        },
        {
          "value": "tier:orchestrator:apex",
          "description": "Tier override: pin the orchestrator to apex — mythos-class leading edge"
        },
        {
          "value": "tier:implementer:local",
          "description": "Tier override: pin the implementer to local — self-hosted endpoint first"
        },
        {
          "value": "tier:implementer:economy",
          "description": "Tier override: pin the implementer to economy — cheapest qualified hosted model"
        },
        {
          "value": "tier:implementer:standard",
          "description": "Tier override: pin the implementer to standard — reliable general-purpose coding model"
        },
        {
          "value": "tier:implementer:frontier",
          "description": "Tier override: pin the implementer to frontier — opus-class heavyweight, no warm-up"
        },
        {
          "value": "tier:implementer:apex",
          "description": "Tier override: pin the implementer to apex — mythos-class leading edge"
        },
        {
          "value": "tier:reviewer:local",
          "description": "Tier override: pin the reviewer to local — self-hosted endpoint first"
        },
        {
          "value": "tier:reviewer:economy",
          "description": "Tier override: pin the reviewer to economy — cheapest qualified hosted model"
        },
        {
          "value": "tier:reviewer:standard",
          "description": "Tier override: pin the reviewer to standard — reliable general-purpose coding model"
        },
        {
          "value": "tier:reviewer:frontier",
          "description": "Tier override: pin the reviewer to frontier — opus-class heavyweight, no warm-up"
        },
        {
          "value": "tier:reviewer:apex",
          "description": "Tier override: pin the reviewer to apex — mythos-class leading edge"
        },
        {
          "value": "tier:challenger:local",
          "description": "Tier override: pin the challenger to local — self-hosted endpoint first"
        },
        {
          "value": "tier:challenger:economy",
          "description": "Tier override: pin the challenger to economy — cheapest qualified hosted model"
        },
        {
          "value": "tier:challenger:standard",
          "description": "Tier override: pin the challenger to standard — reliable general-purpose coding model"
        },
        {
          "value": "tier:challenger:frontier",
          "description": "Tier override: pin the challenger to frontier — opus-class heavyweight, no warm-up"
        },
        {
          "value": "tier:challenger:apex",
          "description": "Tier override: pin the challenger to apex — mythos-class leading edge"
        },
        {
          "value": "tier:integrator:local",
          "description": "Tier override: pin the integrator to local — self-hosted endpoint first"
        },
        {
          "value": "tier:integrator:economy",
          "description": "Tier override: pin the integrator to economy — cheapest qualified hosted model"
        },
        {
          "value": "tier:integrator:standard",
          "description": "Tier override: pin the integrator to standard — reliable general-purpose coding model"
        },
        {
          "value": "tier:integrator:frontier",
          "description": "Tier override: pin the integrator to frontier — opus-class heavyweight, no warm-up"
        },
        {
          "value": "tier:integrator:apex",
          "description": "Tier override: pin the integrator to apex — mythos-class leading edge"
        }
      ]
    },
    {
      "family": "method",
      "prefix": "method",
      "purpose": "Retired: execution topology now lives in the `strategy` family (`.devflow.toml` `[strategy.*]`).",
      "axis": "strategy",
      "source": "inline",
      "writers": [],
      "writer_note": "nobody — renamed to strategy:*",
      "readers": "humans — retired, see `strategy:*`",
      "lifecycle": "durable",
      "lifecycle_note": "migrate each with guarded `--prune` and repeatable `--migrate method:<v>=strategy:<v>`",
      "trust_note": "retired — execution topology renamed to the `strategy` family; never provisioned",
      "exclusive": false,
      "provision": false,
      "retired": true,
      "values": [
        { "value": "oneshot" },
        { "value": "plan" },
        { "value": "plan-approved" },
        { "value": "orchestrate" },
        { "value": "council" },
        { "value": "human-led" }
      ]
    },
    {
      "family": "strategy",
      "prefix": "strategy",
      "purpose": "Which execution strategy in .devflow.toml [strategy.*] an agent works the issue under; conflicts are ambiguous, never ranked.",
      "axis": "strategy",
      "source": "devflow",
      "writers": ["human"],
      "writer_note": "humans, at triage or planning — never an agent on itself",
      "readers": "agents, when entering the Dev Loop — Foreman does not consume it yet (out of scope here)",
      "lifecycle": "durable",
      "lifecycle_note": "set when the default strategy is wrong for the change; survives the work",
      "trust_note": "provisioned; **read by agents** — selects an execution topology, arms nothing",
      "exclusive": true,
      "provision": true,
      "color": "BF3989",
      "values": [
        {
          "value": "oneshot",
          "description": "Strategy: single agent, no separate plan phase"
        },
        {
          "value": "plan",
          "description": "Strategy: agent plans then implements; no human plan gate"
        },
        {
          "value": "plan-approved",
          "description": "Strategy: plan requires human approval before implementation"
        },
        {
          "value": "orchestrate",
          "description": "Strategy: lead agent delegates bounded work to parallel workers"
        },
        {
          "value": "council",
          "description": "Strategy: independent proposals, judged; best or synthesis wins (2+ agents)"
        },
        {
          "value": "human-led",
          "description": "Strategy: human owns central decisions; AI does bounded pieces"
        }
      ]
    },
    {
      "family": "suggest",
      "prefix": "suggest",
      "purpose": "Retired: advisory family routing, superseded by the derived Tier (`tier:<value>`).",
      "axis": "model",
      "source": "agent-registry",
      "registry_set": "suggest",
      "writers": [],
      "writer_note": "nobody — superseded by the derived Tier",
      "readers": "humans — retired, see `tier:*`",
      "lifecycle": "durable",
      "lifecycle_note": "remove the label from each issue — it then resolves through its derived Tier — then use guarded `--prune` (no `--migrate`: nothing replaces a family suggestion one-to-one)",
      "trust_note": "retired — superseded by the derived Tier; never provisioned and no longer rendered from the agent registry",
      "exclusive": false,
      "provision": false,
      "retired": true,
      "placeholder": "<family>",
      "color": "BFD4F2",
      "values": []
    },
    {
      "family": "suggest-model",
      "prefix": "suggest",
      "purpose": "Retired: model-level refinement of a family suggestion, superseded by the derived Tier.",
      "axis": "model",
      "source": "tool-owned",
      "writers": [],
      "writer_note": "nobody — superseded by the derived Tier",
      "readers": "humans — retired, see `tier:*`",
      "lifecycle": "durable",
      "lifecycle_note": "remove the label from each issue, then use guarded `--prune`",
      "trust_note": "retired — never provisioned; no tool creates it any more",
      "exclusive": false,
      "provision": false,
      "retired": true,
      "open_values": true,
      "placeholder": "<family>:<model>",
      "color": "BFD4F2",
      "values": []
    },
    {
      "family": "claim",
      "prefix": "claim",
      "purpose": "Live ownership: which agent family is working the issue right now.",
      "axis": "model",
      "source": "agent-registry",
      "registry_set": "claim",
      "writers": ["agent"],
      "writer_note": "the agent itself — a vendored claim skill, or a Claude Actions run",
      "readers": "humans; the Claude Actions claim gate; `claim-release.yml` where the repo ships it",
      "lifecycle": "claim-release",
      "lifecycle_note": "added at claim, removed at release — by the workflow's `always()` step, or by `claim-release.yml` on close where the repo ships it",
      "trust_note": "provisioned from the registry; a **gate**, never a trigger",
      "exclusive": false,
      "provision": true,
      "placeholder": "<family>",
      "color": "006B75",
      "values": []
    },
    {
      "family": "claim-model",
      "prefix": "claim",
      "purpose": "Model-level refinement of a family claim; applied alongside the family label.",
      "axis": "model",
      "source": "tool-owned",
      "writers": ["agent"],
      "writer_note": "the agent itself",
      "readers": "humans; the Claude Actions claim gate; `claim-release.yml` where the repo ships it",
      "lifecycle": "claim-release",
      "lifecycle_note": "refines the family label; added at claim, removed at release",
      "trust_note": "**tool-owned, created on demand**",
      "exclusive": false,
      "provision": false,
      "open_values": true,
      "placeholder": "<family>:<model>",
      "color": "006B75",
      "values": []
    },
    {
      "family": "agent-legacy",
      "prefix": "agent",
      "purpose": "The retired pre-registry claim vocabulary; recognized by readers, never seeded.",
      "axis": "model",
      "source": "inline",
      "writers": [],
      "writer_note": "nobody — never seeded into a new repo",
      "readers": "claim skills (and `claim-release.yml` where present), which still recognize it",
      "lifecycle": "claim-release",
      "lifecycle_note": "after choosing the actual claim family, use guarded `--prune` with repeatable `--migrate OLD=NEW`",
      "trust_note": "legacy; inert",
      "exclusive": false,
      "provision": false,
      "retired": true,
      "open_values": true,
      "placeholder": "<harness>",
      "values": []
    },
    {
      "family": "foreman-arming",
      "prefix": "foreman",
      "purpose": "Arming selectors: dispatch this issue with the named backend. Rendered only for production-dispatchable adapters.",
      "axis": "foreman",
      "source": "agent-registry",
      "registry_set": "foreman-adapters",
      "writers": ["trusted-human"],
      "writer_note": "a trusted human, to arm an issue",
      "readers": "Foreman",
      "lifecycle": "durable",
      "lifecycle_note": "applied to arm; stays on the issue",
      "trust_note": "provisioned from the registry where the repo uses foreman (`--foreman`), for production-dispatchable adapters only; **actor-verified arming**",
      "exclusive": false,
      "arming": true,
      "provision": true,
      "gate": "foreman",
      "placeholder": "<adapter>",
      "color": "1D76DB",
      "values": []
    },
    {
      "family": "foreman-protocol",
      "prefix": "foreman",
      "purpose": "Foreman's own workflow-state protocol: the default-backend arming input, the hold override, and the dependency overrides.",
      "axis": "foreman",
      "source": "inline",
      "writers": ["human"],
      "readers": "Foreman",
      "lifecycle": "durable",
      "exclusive": false,
      "provision": true,
      "gate": "foreman",
      "values": [
        {
          "value": "approved",
          "description": "Arm with the repo default backend",
          "color": "1D76DB",
          "writers": ["trusted-human"],
          "writer_note": "a trusted human",
          "arming": true,
          "trust_note": "provisioned (`--foreman`); **actor-verified arming** with the repo default backend",
          "lifecycle_note": "applied to arm; stays on the issue"
        },
        {
          "value": "hold",
          "description": "Exclude from foreman dispatch (always wins)",
          "color": "D93F0B",
          "writer_note": "a human",
          "trust_note": "provisioned (`--foreman`); non-arming and always wins",
          "lifecycle_note": "applied to exclude, removed to re-include"
        },
        {
          "value": "satisfied",
          "description": "Human override: treat this dependency as satisfied",
          "color": "0E8A16",
          "writer_note": "a human",
          "readers": "Foreman's dependency graph",
          "trust_note": "provisioned (`--foreman`); non-arming dependency override",
          "lifecycle_note": "applied per dependency decision"
        },
        {
          "value": "external",
          "description": "External dependency: satisfied when closed as completed",
          "color": "BFDADC",
          "writer_note": "a human",
          "readers": "Foreman's dependency graph",
          "trust_note": "provisioned (`--foreman`); non-arming dependency override",
          "lifecycle_note": "applied per dependency decision"
        }
      ]
    },
    {
      "family": "foreman-lifecycle",
      "prefix": "foreman",
      "purpose": "Foreman's PR-side lifecycle outputs, written by Foreman itself.",
      "axis": "foreman",
      "source": "tool-owned",
      "writers": ["tool:foreman"],
      "readers": "Foreman, humans",
      "lifecycle": "tool-managed",
      "trust_note": "**tool-owned, auto-created**",
      "exclusive": false,
      "provision": false,
      "values": [
        {
          "value": "dispatched",
          "writer_note": "Foreman, on the draft PR it opens",
          "lifecycle_note": "added when the draft PR opens"
        },
        {
          "value": "ready-for-review",
          "writer_note": "Foreman, on passing its readiness gate",
          "lifecycle_note": "added at promotion; the hand-off to human review"
        }
      ],
      "gate": "foreman"
    },
    {
      "family": "type-override",
      "prefix": "type",
      "purpose": "Optional override of the native issue Type, read by Foreman for the unit's conventional-commit type.",
      "axis": "meta",
      "source": "inline",
      "writers": ["human"],
      "writer_note": "a human, optionally",
      "readers": "Foreman, to pick the unit's conventional-commit type",
      "lifecycle": "durable",
      "lifecycle_note": "applied when the native type is absent or wrong",
      "trust_note": "**not provisioned** — an optional override of the native issue `Type`",
      "exclusive": true,
      "provision": false,
      "open_values": true,
      "placeholder": "<commit-type>",
      "values": [],
      "gate": "foreman"
    },
    {
      "family": "autorelease",
      "prefix": null,
      "purpose": "release-please's own release-PR state; the space after the colon is deliberate — not the family:value convention.",
      "axis": "release",
      "source": "tool-owned",
      "writers": ["tool:release-please"],
      "writer_note": "release-please",
      "readers": "release-please",
      "lifecycle": "tool-managed",
      "lifecycle_note": "pending on the open release PR, tagged once the release is cut",
      "trust_note": "**tool-owned, auto-created**; note the space after the colon — not part of the `family:value` convention",
      "exclusive": false,
      "provision": false,
      "values": [
        {
          "value": "autorelease: pending"
        },
        {
          "value": "autorelease: tagged"
        }
      ],
      "gate": "release-please"
    },
    {
      "family": "github-defaults",
      "prefix": null,
      "purpose": "GitHub's repo-creation defaults that remain in the vocabulary; never provisioned and protected from maintenance pruning.",
      "axis": "meta",
      "source": "inline",
      "writers": ["human"],
      "writer_note": "GitHub, at repo creation",
      "readers": "humans",
      "lifecycle": "durable",
      "lifecycle_note": "adopted; leave in place — inventory reporting and guarded pruning exclude it",
      "trust_note": "not provisioned, never deleted by setup",
      "exclusive": false,
      "provision": false,
      "values": [
        {
          "value": "duplicate",
          "description": "This issue or pull request already exists",
          "color": "CFD3D7"
        },
        {
          "value": "good first issue",
          "description": "Good for newcomers",
          "color": "7057FF"
        },
        {
          "value": "help wanted",
          "description": "Extra attention is needed",
          "color": "008672"
        },
        {
          "value": "invalid",
          "description": "This doesn't seem right",
          "color": "E4E669"
        },
        {
          "value": "wontfix",
          "description": "This will not be worked on",
          "color": "FFFFFF"
        }
      ]
    }
  ]
}
HARMON_INIT_RATING_REGISTRY
jq '[.families[] | . as $family | .values[] |
    {name:(if $family.prefix == null then .value else ($family.prefix + ":" + .value) end),
     description:(.description // "")}] | unique_by(.name)' "$init_registry/label-registry.json" >"$init_registry/labels.json"
if init_output="$(discover "$init_registry" 2>"$init_registry/error")" && jq -e '
    .mode == "registry" and .verified_semantics == true and
    . as $result | all(["impact","risk","complexity"][]; . as $axis |
      [$result.families[] | select(.family == $axis)] as $ratings |
      ($ratings | length) == 1 and $ratings[0].source == "classification-helper")
' <<<"$init_output" >/dev/null; then
    ok "byte-copy harmon-init registry emits exactly one helper family per personal rating axis"
else
    bad "byte-copy harmon-init personal registry discovers: $(cat "$init_registry/error")"
fi

# A prefix-less custom family cannot disguise a model suggestion as planning vocabulary.
custom_suggest="$tmproot/custom-suggest"
mkdir -p "$custom_suggest"
write_agent_registry "$custom_suggest"
write_registry "$custom_suggest" api
write_labels "$custom_suggest" api
jq '.families |= map(select(.family != "suggest")) |
    .families += [{family:"custom",prefix:null,purpose:"Custom labels",axis:"classification",
      source:"inline",writers:["agent"],readers:"humans",lifecycle:"durable",
      exclusive:false,provision:true,color:"123456",
      values:[{value:"suggest:gpt:sol",description:"Disguised suggestion"}]}]' \
    "$custom_suggest/label-registry.json" >"$custom_suggest/updated.json"
mv "$custom_suggest/updated.json" "$custom_suggest/label-registry.json"
if discover "$custom_suggest" >"$custom_suggest/output" 2>"$custom_suggest/error"; then
    bad "prefix-less registry family cannot emit a suggestion label"
elif grep -qF 'planning-safe family custom declares reserved label suggest:gpt:sol' "$custom_suggest/error" &&
    [ ! -s "$custom_suggest/output" ]; then
    ok "prefix-less registry suggestion fails closed without a canonical suggestion family"
else
    bad "prefix-less registry suggestion has the reserved-label diagnostic"
fi

# Personal helper ratings match live labels case-insensitively in both modes.
mixed_ratings="$tmproot/mixed-ratings"
mkdir -p "$mixed_ratings"
write_agent_registry "$mixed_ratings"
write_registry "$mixed_ratings" api
write_labels "$mixed_ratings" api
jq 'map(if .name == "impact:high" then .name = "Impact:High"
        elif .name == "risk:low" then .name = "Risk:Low"
        elif .name == "complexity:m" then .name = "Complexity:M" else . end)' \
    "$mixed_ratings/labels.json" >"$mixed_ratings/updated.json"
mv "$mixed_ratings/updated.json" "$mixed_ratings/labels.json"
for rating_mode in registry live-label-fallback; do
    if [ "$rating_mode" = live-label-fallback ]; then
        mv "$mixed_ratings/label-registry.json" "$mixed_ratings/saved-registry.json"
    fi
    if mixed_output="$(discover "$mixed_ratings" 2>"$mixed_ratings/error")" && jq -e --arg mode "$rating_mode" '
        .mode == $mode and
        ([.families[] | select(.source == "classification-helper") | .labels[].name] | sort) ==
        ["Complexity:M","Impact:High","Risk:Low"]
    ' <<<"$mixed_output" >/dev/null; then
        ok "mixed-case personal ratings retain live spelling in $rating_mode"
    else
        bad "mixed-case personal ratings survive $rating_mode: $(cat "$mixed_ratings/error")"
    fi
done

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
touch "$init_registry/organization"
cp "$organization/fields.json" "$init_registry/fields.json"
if init_org_output="$(discover "$init_registry" 2>"$init_registry/error")" && jq -e '
    .owner_type == "Organization" and .classification.storage == "field" and
    (.issue_fields | keys) == ["complexity","impact","risk"] and
    .issue_fields == .classification.axes and
    . as $result | all(["impact","risk","complexity"][]; . as $axis |
      $result.issue_fields[$axis].provisioned and ($result.issue_fields[$axis].values | length) == 1) and
    ([.families[] | select(.family == "impact" or .family == "risk" or .family == "complexity")] | length) == 0
' <<<"$init_org_output" >/dev/null; then
    ok "byte-copy harmon-init organization registry uses only helper field vocabulary for ratings"
else
    bad "byte-copy harmon-init organization registry discovers: $(cat "$init_registry/error")"
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

# One table exercises the integration collision invariant across all surfaces.
for invariant_case in open-rating prefixless-model helper-id nonclassification-rating prefixless-rating bare-ratings open-model excluded-concrete; do
    invariant_fixture="$tmproot/invariant-$invariant_case"
    mkdir -p "$invariant_fixture"
    write_agent_registry "$invariant_fixture"
    write_registry "$invariant_fixture" api
    write_labels "$invariant_fixture" api
    case "$invariant_case" in
    open-rating)
        extra='[{"family":"rating-open","prefix":"risk","axis":"meta","source":"tool-owned","open_values":true,"placeholder":"risk:<value>","values":[]}]'
        sources='(rating-open.*classification-helper family risk|classification-helper family risk.*rating-open)'
        ;;
    prefixless-model)
        extra='[{"family":"hidden-model","prefix":null,"axis":"model","source":"inline","values":[{"value":"area:api"}]}]'
        sources='(hidden-model.*family\[0\] area|family\[0\] area.*hidden-model)'
        ;;
    helper-id)
        extra='[{"family":"risk","prefix":"custom-risk","axis":"meta","source":"inline","values":[{"value":"live"}]}]'
        sources='(manifest family.*risk.*classification-helper family risk|classification-helper family risk.*manifest family.*risk)'
        ;;
    nonclassification-rating)
        extra='[{"family":"impact","prefix":"impact","axis":"meta","source":"inline","values":[{"value":"high"}]}]'
        sources='(manifest family.*impact.*classification-helper family impact|classification-helper family impact.*manifest family.*impact)'
        ;;
    prefixless-rating)
        extra='[{"family":"disguised-rating","prefix":null,"axis":"classification","source":"inline","values":[{"value":"impact:high"}]}]'
        sources='(disguised-rating.*classification-helper family impact|classification-helper family impact.*disguised-rating)'
        ;;
    bare-ratings)
        extra='[{"family":"bare-ratings","prefix":null,"axis":"meta","source":"inline","values":[{"value":"risk"},{"value":"impact"},{"value":"complexity"}]}]'
        jq '. + [{name:"risk"},{name:"impact"},{name:"complexity"}]' "$invariant_fixture/labels.json" >"$invariant_fixture/labels-updated.json"
        mv "$invariant_fixture/labels-updated.json" "$invariant_fixture/labels.json"
        ;;
    open-model)
        extra='[{"family":"model-open","prefix":"area","axis":"model","source":"tool-owned","open_values":true,"placeholder":"area:<model>","values":[]}]'
        sources='family\[0\] area.*model-open'
        ;;
    excluded-concrete)
        extra='[{"family":"hidden-owner","prefix":null,"axis":"model","source":"inline","values":[{"value":"Ready"}]},{"family":"visible-owner","prefix":null,"axis":"meta","source":"inline","values":[{"value":"ready"}]}]'
        sources='(hidden-owner.*visible-owner|visible-owner.*hidden-owner)'
        jq '. + [{name:"Ready"}]' "$invariant_fixture/labels.json" >"$invariant_fixture/labels-updated.json"
        mv "$invariant_fixture/labels-updated.json" "$invariant_fixture/labels.json"
        ;;
    esac
    jq --argjson extra "$extra" '.families += ($extra | map(
        {purpose:"Collision invariant fixture", writers:["agent"], readers:"agents",
         lifecycle:"durable", exclusive:false, provision:false} + .))' "$invariant_fixture/label-registry.json" >"$invariant_fixture/updated.json"
    mv "$invariant_fixture/updated.json" "$invariant_fixture/label-registry.json"
    if invariant_output="$(discover "$invariant_fixture" 2>"$invariant_fixture/error")"; then
        if [ "$invariant_case" = bare-ratings ] && jq -e '
            ([.families[] | select(.family == "bare-ratings") | .labels[].name] | sort) ==
            ["complexity", "impact", "risk"]
        ' <<<"$invariant_output" >/dev/null; then
            ok "collision invariant table: bare rating names remain ordinary labels"
        else
            bad "collision invariant table: $invariant_case must fail closed"
        fi
    elif [ "$invariant_case" != bare-ratings ] && [ -z "$invariant_output" ] &&
        grep -q 'collision:' "$invariant_fixture/error" &&
        grep -qE "$sources" "$invariant_fixture/error"; then
        ok "collision invariant table: $invariant_case names both conflicting sources"
    else
        bad "collision invariant table: $invariant_case diagnostic: $(cat "$invariant_fixture/error")"
    fi
done

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
  {"name":"Priority-AI:p1","description":"Helper-derived priority"},
  {"name":"Suggest:gpt","description":"Legacy advisory model family"},
  {"name":"suggest:gpt:sol","description":"Legacy advisory model refinement"},
  {"name":"Effort:high","description":"Human effort"},
  {"name":"tier:pinned","description":"Human pin"},
  {"name":"security","description":"Security"},
  {"name":"risk","description":"Ordinary bare label"},
  {"name":"impact","description":"Ordinary bare label"},
  {"name":"complexity","description":"Ordinary bare label"},
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
    ([.labels[].name] | sort) == ["area:api", "complexity", "feature", "impact", "risk", "security"]
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

if jq -e '(any(.families[].labels[]; .name | test("^priority-ai:"; "i")) | not)' <<<"$output" >/dev/null &&
    jq -e '(any(.labels[]; .name | test("^(priority-ai|suggest):"; "i")) | not)' <<<"$fallback_output" >/dev/null; then
    ok "Priority (AI) is excluded in registry and fallback; fallback also excludes suggestions"
else
    bad "helper-owned Priority (AI) and legacy fallback suggestions are never proposed"
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
elif [ ! -s "$namespace_collision/output" ] && grep -Eq 'collision: prefix claim.*claim.*claim-open|declares reserved label claim:gpt' "$namespace_collision/error"; then
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
elif [ ! -s "$concrete_collision/output" ] && grep -q 'collision: prefix area.*area.*unsafe-area' "$concrete_collision/error"; then
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
elif [ ! -s "$unsafe_open_overlap/output" ] && grep -q 'collision: prefix area.*area.*unsafe-area-open' "$unsafe_open_overlap/error"; then
    ok "unsafe open-family prefix overlaps fail closed"
else
    bad "unsafe open-family overlap fails with a diagnostic"
fi

model_open_overlap="$tmproot/model-open-overlap"
mkdir -p "$model_open_overlap"
write_agent_registry "$model_open_overlap"
write_registry "$model_open_overlap" api
write_labels "$model_open_overlap" api
jq '.families += [{
    "family":"model-area-open", "prefix":"area", "purpose":"Excluded model namespace",
    "axis":"model", "source":"tool-owned", "writers":["agent"], "readers":"agents",
    "lifecycle":"durable", "exclusive":false, "provision":false,
    "open_values":true, "placeholder":"area:<model>", "values":[]
}]' "$model_open_overlap/label-registry.json" >"$model_open_overlap/updated.json"
mv "$model_open_overlap/updated.json" "$model_open_overlap/label-registry.json"
if discover "$model_open_overlap" >"$model_open_overlap/output" 2>"$model_open_overlap/error"; then
    bad "excluded open model families cannot share a planning area namespace"
elif [ ! -s "$model_open_overlap/output" ] &&
    grep -q 'collision: prefix area.*area.*model-area-open' "$model_open_overlap/error"; then
    ok "open model family under area fails the overlap refusal"
else
    bad "open model overlap fails closed with the expected diagnostic"
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
    grep -q 'collision: label area:api.*area.*unsafe-area-open' \
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
elif [ ! -s "$ambiguous/output" ] && grep -q 'collision: prefix shared.*first.*second' "$ambiguous/error"; then
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

proposal_section="$(sed -n '/^## 6\./,/^## 7\./p' "$skill")"
execution_section="$(sed -n '/^## 7\./,/^## 8\./p' "$skill")"
if grep -qF 'Impact, Risk and Complexity per chunk' <<<"$proposal_section" &&
    grep -qF 'a one-line reason' <<<"$proposal_section"; then
    ok "proposal section requires each chunk's three ratings and one-line reasons"
else
    bad "proposal section requires per-chunk ratings and one-line reasons"
fi
if grep -qF 'check-issue-metadata.sh' <<<"$execution_section" &&
    grep -qF 'using the **agent-authored** path' <<<"$execution_section"; then
    ok "execution section runs the agent-authored metadata preflight"
else
    bad "execution section runs the agent-authored metadata preflight"
fi
if grep -qF 'check-issue-metadata.sh --required-axes --repo' <<<"$proposal_section" &&
    grep -qF 'every axis in the `--required-axes`' <<<"$execution_section" &&
    grep -qF 'never derive' <<<"$proposal_section" &&
    grep -qF 'required axes from discovery `families`' <<<"$proposal_section" &&
    grep -qF 'If `agent_writable_value` is false' <<<"$proposal_section" &&
    grep -qF 'before approval; never turn it' <<<"$proposal_section" &&
    ! grep -qF 'Derive the required axes from the target manifest' "$skill" &&
    ! grep -qF '(`axis`, `exclusive`, `prefix`, and `family`)' <<<"$proposal_section"; then
    ok "breakdown consumes preflight required axes and reports unwriteable axes before approval"
else
    bad "breakdown must consume --required-axes instead of deriving its own axis list"
fi
if grep -qF 'then immediately call triage' <<<"$execution_section" &&
    grep -qF 'triage-apply.sh label' <<<"$execution_section" &&
    grep -qF 'independently re-read the stored ratings' <<<"$execution_section"; then
    ok "create-time classification uses the shared helper and re-reads its result"
else
    bad "create-time classification uses the shared helper and re-reads its result"
fi

if grep -qF 'GH_HOST="$target_host" TRIAGE_EXECUTE=1' <<<"$execution_section" &&
    grep -qF '<triage-skill-dir>/assets/triage-apply.sh label --repo <owner/repo> … --execute' <<<"$execution_section" &&
    grep -qF 'same target host passed to discovery' <<<"$execution_section"; then
    ok "post-create helper write binds the discovery host and authorizes execution"
else
    bad "post-create helper write requires both discovery host and execution bindings"
fi

if [ "$(grep -cF 'human either pauses the' <<<"$execution_section")" -eq 2 ] &&
    grep -qF 'signal the mandatory classification helper writes' <<<"$execution_section" &&
    grep -qF '`tier:*` label, or the absence of `needs-triage`' <<<"$execution_section" &&
    grep -qF 'Keep classification mandatory and in this order' <<<"$execution_section"; then
    ok "helper-owned gating inputs require a human race decision without skipping classification"
else
    bad "both gating and create clauses cover helper-owned dispatch signals"
fi
if grep -qF '(dependencies and sub-issue parent) against the approved chunk' <<<"$execution_section" &&
    grep -qF 'Regardless of classification' <<<"$execution_section" &&
    grep -qF 'completeness, attach any missing relationship edges, then verify them by' <<<"$execution_section" &&
    grep -qF 'Skip a matched issue only when both its' <<<"$execution_section" &&
    grep -qF 'classification and relationship edges have been re-read and match the approved' <<<"$execution_section" &&
    grep -qF 'never re-create the issue to recover' <<<"$execution_section"; then
    ok "recovery verifies and repairs relationship edges even when classification is complete"
else
    bad "recovery skips only after classification and relationship read-back match"
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
