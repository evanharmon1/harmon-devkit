#!/usr/bin/env bash
# test-tier-inputs.sh — unit and end-to-end cases for tier-inputs.mjs, the
# consumer-side label translation /orchestrate and /implement run before
# devflow-policy.mjs resolve (harmon-devkit#1248).
#
# The unit cases pin the translation rules (stored Tier vs pin, the ambiguous
# pin, role-label conflicts, rigor/strategy label conflicts, Risk/Complexity
# from labels or fields). The end-to-end cases feed the translation to the
# vendored reader over the conformance corpus's base policy (which carries a
# [tier.matrix]) and check the resolved implementer tier, its source, and the
# PR-body disclosure lines — including the routed cases from the issue
# comments: a pin beats a scoped label (and the label is disclosed as
# overridden), a scoped label beats the derived Tier, and a leftover
# tier:adaptive label resolves as absent.
#
# Run from scripts/test-skills.sh (task test:skills).
set -euo pipefail

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
helper="$asset_dir/tier-inputs.mjs"
reader="$asset_dir/devflow-policy.mjs"
repo_root="$(git -C "$asset_dir" rev-parse --show-toplevel)"
base_policy="$repo_root/ai/schemas/fixtures/devflow-conformance/policy.toml"
fixture_dir_recipe="$repo_root/ai/schemas/fixtures/devflow-conformance"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/tier-inputs.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

failures=0
pass=0
fail() {
    echo "  ✗ $*" >&2
    failures=$((failures + 1))
    return 0
}
ok() {
    pass=$((pass + 1))
    return 0
}

# translate JSON → prints the helper's JSON output. The policy defaults to
# the corpus base policy; TRANSLATE_POLICY overrides it (an absent path is the
# built-in fallback).
translate() {
    printf '%s' "$1" | node "$helper" --policy "${TRANSLATE_POLICY:-$base_policy}"
}

# expect_args NAME INPUT EXPECTED_ARGS_JSON — exact argument vector.
expect_args() {
    local name="$1" input="$2" want="$3" got
    got="$(translate "$input" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(JSON.parse(s).args)))')"
    if [ "$got" = "$want" ]; then ok; else fail "$name: args $got, expected $want"; fi
}

# expect_warning NAME INPUT CODE [SUBSTRING...] — a warning with CODE whose
# message contains every SUBSTRING.
expect_warning() {
    local name="$1" input="$2" code="$3"
    shift 3
    local out
    out="$(translate "$input")"
    if ! node -e '
const out = JSON.parse(process.argv[1]);
const [code, ...subs] = process.argv.slice(2);
const w = out.warnings.find((x) => x.code === code);
process.exit(w && subs.every((s) => w.message.includes(s)) ? 0 : 1);
' "$out" "$code" "$@"; then
        fail "$name: no warning $code containing [$*] in $(printf '%s' "$out" | tr '\n' ' ')"
    else
        ok
    fi
}

echo "==> tier-inputs.mjs: translation rules"
expect_args "no policy labels" '{"labels":["bug","area:skills"]}' '[]'
expect_args "unqualified tier is the stored Tier" '{"labels":["tier:standard"]}' '["--stored-tier=standard"]'
expect_args "trusted pin" \
    '{"labels":["tier:pinned","tier:frontier"],"pin_provenance":{"marker_trusted":true,"value_trusted":true}}' \
    '["--pinned-tier=frontier","--pin-marker-trusted","--pin-value-trusted"]'
expect_args "unverified pin passes no trust flags" '{"labels":["tier:pinned","tier:frontier"]}' '["--pinned-tier=frontier"]'
expect_args "ambiguous pin passes no pinned Tier and keeps the classification" \
    '{"labels":["tier:pinned","tier:frontier","tier:standard","risk:high","complexity:m"],"pin_provenance":{"marker_trusted":true,"value_trusted":true}}' \
    '["--risk=high","--complexity=m"]'
expect_warning "ambiguous pin names both values" \
    '{"labels":["tier:pinned","tier:frontier","tier:standard"]}' pin-ambiguous "tier:frontier" "tier:standard"
expect_warning "a pin with no value is reported" '{"labels":["tier:pinned"]}' pin-without-tier
expect_args "two stored Tiers without a pin pass neither" '{"labels":["tier:local","tier:apex"]}' '[]'

echo "==> tier-inputs.mjs: ambiguity is counted over RAW values (review round 2, R2-1, and its property audit)"
pin_trust='"pin_provenance":{"marker_trusted":true,"value_trusted":true}'
expect_args "a malformed second Tier label makes a pin ambiguous" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:APEX\"],$pin_trust}" '[]'
expect_warning "the mixed-validity ambiguous pin names both values" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:APEX\"],$pin_trust}" pin-ambiguous "tier:apex" "tier:APEX"
expect_args "an empty Tier label still counts toward pin ambiguity" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:\"],$pin_trust}" '[]'
expect_args "a lone malformed pinned value is never forwarded" "{\"labels\":[\"tier:pinned\",\"tier:APEX\"],$pin_trust}" '[]'
expect_warning "a lone malformed pinned value is named" "{\"labels\":[\"tier:pinned\",\"tier:APEX\"],$pin_trust}" pin-value-invalid "tier:APEX"
expect_args "a malformed second stored Tier makes the cache ambiguous" '{"labels":["tier:apex","tier:APEX"]}' '[]'
expect_warning "the mixed-validity stored Tier is named" '{"labels":["tier:apex","tier:APEX"]}' stored-tier-ambiguous "tier:apex" "tier:APEX"
expect_args "an empty classification label passes the sentinel, never nothing" '{"labels":["risk:"]}' '["--risk=conflict"]'
expect_args "an empty classification label beside a valid one is a conflict" \
    '{"labels":["risk:high","risk:"]}' '["--risk=conflict"]'
expect_warning "a malformed role-label rival is named in the conflict" \
    '{"labels":["tier:implementer:economy","tier:implementer:APEX"],"authorized_labels":["tier:implementer:economy","tier:implementer:APEX"]}' \
    tier-role-label-conflict "tier:implementer:APEX" "economy is the one passed"
expect_args "the valid role label still applies beside a malformed rival" \
    '{"labels":["tier:implementer:economy","tier:implementer:APEX"],"authorized_labels":["tier:implementer:economy","tier:implementer:APEX"]}' \
    '["--tier-labels=implementer=economy"]'
for bad_operator in '{"operator":{"rigor":"Deep"}}' '{"operator":{"strategy":"Plan"}}'; do
    if printf '%s' "$bad_operator" | node "$helper" --policy "$base_policy" >/dev/null 2>&1; then
        fail "a malformed operator value must be a usage error, never dropped: $bad_operator"
    else
        ok
    fi
done

echo "==> tier-inputs.mjs: the input document's shape and keys are validated (integration remediation 1)"
# expect_usage_error_input NAME INPUT — the helper exits 2 on INPUT.
expect_usage_error_input() {
    local name="$1" input="$2" rc=0
    printf '%s' "$input" | node "$helper" --policy "$base_policy" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then ok; else fail "$name: expected exit 2, got $rc"; fi
}
expect_usage_error_input "a null document (thread 4176257533)" 'null'
expect_usage_error_input "an array document (thread 4176257533)" '[]'
expect_usage_error_input "a string document (thread 4176257533)" '"oops"'
expect_usage_error_input "an unknown operator key (thread 4176257545)" '{"operator":{"rigour":"deep"}}'
expect_usage_error_input "an unknown top-level key (thread 4176257545)" '{"labelz":["tier:apex"]}'
expect_usage_error_input "a policy key inside the document" '{"policy":{"rigors":[],"strategies":[]}}'
expect_usage_error_input "an unknown fields key (integration remediation 2, thread 4178249112)" '{"fields":{"rsk":"critical"}}'
expect_args "the two known fields keys still apply" '{"fields":{"risk":"critical","complexity":"xl"}}' '["--risk=critical","--complexity=xl"]'
expect_warning "a non-slug classification value says it becomes the sentinel, not 'ignored'" \
    '{"labels":["risk:HIGH"]}' label-value-invalid "--risk=conflict"

echo "==> tier-inputs.mjs: pin_provenance keys and types (integration remediation 3, thread 4178487551)"
expect_usage_error_input "an unknown pin_provenance key" '{"pin_provenance":{"markerTrusted":true}}'
expect_usage_error_input "a non-boolean pin_provenance value" '{"pin_provenance":{"marker_trusted":"yes"}}'
expect_usage_error_input "a null pin_provenance value" '{"pin_provenance":{"value_trusted":null}}'

echo "==> tier-inputs.mjs: every path records the rigor and strategy source (thread 4178487553)"
# expect_source NAME INPUT AXIS SOURCE — translation inputs.<AXIS>.source.
expect_source() {
    local name="$1" input="$2" axis="$3" want="$4" got
    got="$(translate "$input" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const i=JSON.parse(s).inputs[process.argv[1]];console.log(i?i.source:"MISSING")})' "$axis")"
    if [ "$got" = "$want" ]; then ok; else fail "$name: inputs.$axis.source is $got, expected $want"; fi
}
expect_source "no strategy label: default" '{"labels":[]}' strategy default
expect_source "an authorized strategy label: label" '{"labels":["strategy:council"],"authorized_labels":["strategy:council"]}' strategy label
expect_source "an operator strategy: operator" '{"operator":{"strategy":"council"}}' strategy operator
expect_source "two strategy labels: default (ambiguous)" \
    '{"labels":["strategy:plan","strategy:council"],"authorized_labels":["strategy:plan","strategy:council"]}' strategy default
expect_source "an unknown strategy label: default" '{"labels":["strategy:bogus"],"authorized_labels":["strategy:bogus"]}' strategy default
expect_source "no rigor label: default" '{"labels":[]}' rigor default
expect_source "an authorized rigor label: label" '{"labels":["rigor:deep"],"authorized_labels":["rigor:deep"]}' rigor label
expect_source "an operator rigor: operator" '{"operator":{"rigor":"light"}}' rigor operator

echo "==> tier-inputs.mjs: extra-colon labels are counted, never dropped (integration remediation 1, thread 4176257550)"
expect_args "an extra-colon Risk label is the off-scale sentinel" '{"labels":["risk:high:typo"]}' '["--risk=conflict"]'
expect_args "an extra-colon Complexity label is the off-scale sentinel" \
    '{"labels":["risk:high","complexity:m:typo"]}' '["--risk=high","--complexity=conflict"]'
expect_args "an extra-colon Tier label makes a pin ambiguous" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:apex:old\"],$pin_trust}" '[]'
expect_warning "the extra-colon ambiguous pin names both values" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:apex:old\"],$pin_trust}" pin-ambiguous "tier:apex" "tier:apex:old"
expect_args "an extra-colon Tier label makes the stored Tier ambiguous" '{"labels":["tier:apex","tier:apex:old"]}' '[]'
expect_args "an unknown-role tier label still counts toward pin ambiguity" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:foo:bar\"],$pin_trust}" '[]'
expect_warning "an extra-colon role label is a named rival, never forwarded" \
    '{"labels":["tier:implementer:apex:x","tier:implementer:economy"],"authorized_labels":["tier:implementer:apex:x","tier:implementer:economy"]}' \
    tier-role-label-conflict "tier:implementer:apex:x" "economy is the one passed"
expect_args "an extra-colon role label is never forwarded" \
    '{"labels":["tier:implementer:apex:x","tier:implementer:economy"],"authorized_labels":["tier:implementer:apex:x","tier:implementer:economy"]}' \
    '["--tier-labels=implementer=economy"]'
expect_args "an extra-colon rigor label names nothing and is ignored" \
    '{"labels":["rigor:deep:x"],"authorized_labels":["rigor:deep:x"]}' '[]'
expect_args "an extra-colon strategy label names nothing and is ignored" \
    '{"labels":["strategy:plan:x"],"authorized_labels":["strategy:plan:x"]}' '[]'
expect_args "an unauthorized extra-colon role label is still gated" '{"labels":["tier:implementer:apex:x"]}' '[]'
expect_warning "two stored Tiers without a pin warn" '{"labels":["tier:local","tier:apex"]}' stored-tier-ambiguous "tier:local" "tier:apex"
expect_args "role-label conflict takes the strongest" \
    '{"labels":["tier:implementer:economy","tier:implementer:frontier"],"authorized_labels":["tier:implementer:economy","tier:implementer:frontier"]}' \
    '["--tier-labels=implementer=frontier"]'
expect_warning "role-label conflict is disclosed" \
    '{"labels":["tier:implementer:economy","tier:implementer:frontier"],"authorized_labels":["tier:implementer:economy","tier:implementer:frontier"]}' \
    tier-role-label-conflict "frontier"
expect_args "a leftover tier:<role>:adaptive reaches the reader to be named retired" \
    '{"labels":["tier:reviewer:adaptive"],"authorized_labels":["tier:reviewer:adaptive"]}' '["--tier-labels=reviewer=adaptive"]'
expect_args "rigor-label conflict takes the strongest" \
    '{"labels":["rigor:light","rigor:deep"],"authorized_labels":["rigor:light","rigor:deep"]}' '["--rigor","deep","--rigor-source=label"]'
expect_args "operator rigor outranks a rigor label" \
    '{"labels":["rigor:deep"],"authorized_labels":["rigor:deep"],"operator":{"rigor":"light"}}' '["--rigor","light","--rigor-source=operator"]'
expect_args "two strategy labels pass none" \
    '{"labels":["strategy:plan","strategy:council"],"authorized_labels":["strategy:plan","strategy:council"]}' '[]'
expect_warning "two strategy labels warn" \
    '{"labels":["strategy:plan","strategy:council"],"authorized_labels":["strategy:plan","strategy:council"]}' strategy-label-ambiguous
expect_args "operator tiers" '{"operator":{"tiers":{"implementer":"apex","reviewer":"frontier"}}}' \
    '["--tier-overrides=implementer=apex,reviewer=frontier"]'
expect_args "org fields are the classification" '{"fields":{"risk":"low","complexity":"xl"}}' '["--risk=low","--complexity=xl"]'
expect_args "a field wins over a disagreeing label" '{"labels":["risk:high"],"fields":{"risk":"low"}}' '["--risk=low"]'
expect_warning "a field/label disagreement warns" '{"labels":["risk:high"],"fields":{"risk":"low"}}' risk-field-label-mismatch
expect_args "conflicting risk labels pass the off-scale sentinel (review round 1, R1-1)" \
    '{"labels":["risk:high","risk:low","complexity:s"]}' '["--risk=conflict","--complexity=s"]'
expect_args "a non-slug classification value passes the sentinel, never nothing" '{"labels":["risk:HIGH"]}' '["--risk=conflict"]'
expect_args "a non-slug value never reaches the reader" '{"labels":["tier:--json"]}' '[]'
if printf '%s' '{"labels":"tier:standard"}' | node "$helper" --policy "$base_policy" >/dev/null 2>&1; then
    fail "malformed input must exit non-zero"
else
    ok
fi

echo "==> tier-inputs.mjs: labels naming nothing in the policy are ignored (challenge round 1, C1-2)"
expect_args "an unknown strategy label is dropped" \
    '{"labels":["strategy:bogus"],"authorized_labels":["strategy:bogus"]}' '[]'
expect_warning "an unknown strategy label warns" \
    '{"labels":["strategy:bogus"],"authorized_labels":["strategy:bogus"]}' strategy-label-unknown "strategy:bogus"
expect_args "an unknown strategy label does not make a known one ambiguous" \
    '{"labels":["strategy:bogus","strategy:council"],"authorized_labels":["strategy:bogus","strategy:council"]}' '["--strategy","council"]'
expect_args "an unknown rigor label is dropped" '{"labels":["rigor:extreme"],"authorized_labels":["rigor:extreme"]}' '[]'
expect_warning "an unknown rigor label warns" \
    '{"labels":["rigor:extreme"],"authorized_labels":["rigor:extreme"]}' rigor-label-unknown "rigor:extreme"
expect_args "an operator strategy is never filtered" '{"operator":{"strategy":"bogus"}}' '["--strategy","bogus"]'
TRANSLATE_POLICY="$scratch/absent/.devflow.toml"
expect_args "absent policy: rigor:deep names nothing in the built-in fallback" \
    '{"labels":["rigor:deep"],"authorized_labels":["rigor:deep"]}' '[]'
expect_args "absent policy: rigor:standard is the fallback's own level" \
    '{"labels":["rigor:standard"],"authorized_labels":["rigor:standard"]}' '["--rigor","standard","--rigor-source=label"]'
expect_args "absent policy: strategy:council names nothing" \
    '{"labels":["strategy:council"],"authorized_labels":["strategy:council"]}' '[]'
expect_args "absent policy: strategy:plan is the fallback's own strategy" \
    '{"labels":["strategy:plan"],"authorized_labels":["strategy:plan"]}' '["--strategy","plan"]'
unset TRANSLATE_POLICY

echo "==> tier-inputs.mjs: execution-policy labels need verified provenance (challenge round 2, C2-1)"
expect_args "an unauthorized rigor label is dropped" '{"labels":["rigor:deep"]}' '[]'
expect_warning "an unauthorized rigor label is named" '{"labels":["rigor:deep"]}' policy-label-unauthorized "rigor:deep"
expect_args "an unauthorized strategy label is dropped" '{"labels":["strategy:council"]}' '[]'
expect_args "an unauthorized role label is dropped" '{"labels":["tier:implementer:apex"]}' '[]'
expect_warning "an unauthorized role label is named" '{"labels":["tier:implementer:apex"]}' policy-label-unauthorized "tier:implementer:apex"
expect_args "authorization is per label" \
    '{"labels":["rigor:deep","tier:implementer:apex"],"authorized_labels":["tier:implementer:apex"]}' '["--tier-labels=implementer=apex"]'
expect_args "authorizing a label the issue does not carry adds nothing" '{"labels":[],"authorized_labels":["rigor:deep"]}' '[]'
expect_args "classification and the stored Tier are never gated (ADR 2026-09-30 D3)" \
    '{"labels":["risk:high","complexity:m","tier:frontier"]}' '["--risk=high","--complexity=m","--stored-tier=frontier"]'
if printf '%s' '{"labels":[],"authorized_labels":"rigor:deep"}' | node "$helper" --policy "$base_policy" >/dev/null 2>&1; then
    fail "a non-array authorized_labels must exit non-zero"
else
    ok
fi
if printf '%s' '{"labels":[]}' | node "$helper" >/dev/null 2>&1; then
    fail "translating without --policy must be a usage error"
else
    ok
fi
printf 'schema_version = [\n' >"$scratch/broken.toml"
if printf '%s' '{"labels":[]}' | node "$helper" --policy "$scratch/broken.toml" >/dev/null 2>&1; then
    fail "an unparseable --policy must be refused, never treated as absent"
else
    ok
fi

echo "==> devflow-policy.mjs: a provenance flag never swallows a value (challenge round 1, C1-1)"
rc=0
node "$reader" resolve --policy "$base_policy" --json --pinned-tier apex --pin-marker-trusted false --pin-value-trusted \
    >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok; else fail "--pin-marker-trusted false must be a usage error (exit 2), got $rc"; fi
rc=0
node "$reader" resolve --policy "$base_policy" --json --pinned-tier apex --pin-value-trusted true --pin-marker-trusted \
    >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok; else fail "--pin-value-trusted true must be a usage error (exit 2), got $rc"; fi

echo "==> devflow-policy.mjs: an option a command does not name is refused (challenge round 2, C2-2)"
# expect_usage_error NAME ARG... — `resolve --policy <base> --json ARG...` exits 2.
expect_usage_error() {
    local name="$1" rc=0
    shift
    node "$reader" resolve --policy "$base_policy" --json "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then ok; else fail "$name: expected exit 2, got $rc"; fi
}
expect_usage_error "a misspelled tier option with =value" "--tier-lables=implementer=apex"
expect_usage_error "a misspelled tier option with a separate value" --pinned-teir apex
expect_usage_error "a stray positional" stray
expect_usage_error "a value after --json" --json stray
expect_usage_error "a tier option given twice" --risk high --risk low
expect_usage_error "a provenance flag given twice (challenge round 3, C3-1)" \
    --pinned-tier apex --pin-marker-trusted --pin-marker-trusted --pin-value-trusted
rc=0
node "$reader" resolve --policy "$base_policy" --json --json >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then ok; else fail "--json stays repeatable (expected 0 or 3), got $rc"; fi
rc=0
node "$reader" detect --policy "$base_policy" --risk high >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok; else fail "detect must refuse a resolve-only option (exit 2), got $rc"; fi

echo "==> tier-inputs.mjs + devflow-policy.mjs: end to end over the corpus base policy"
# e2e NAME INPUT IMPL_TIER IMPL_SOURCE [DISCLOSURE_SUBSTRING...]
e2e() {
    local name="$1" input="$2" want_tier="$3" want_source="$4"
    shift 4
    local tr="$scratch/$RANDOM-tr.json" res="$scratch/$RANDOM-res.json" lines rc=0
    translate "$input" >"$tr"
    local -a args=()
    while IFS= read -r a; do args+=("$a"); done < <(node -e 'for (const a of JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).args) console.log(a)' "$tr")
    node "$reader" resolve --policy "$base_policy" --json ${args[@]+"${args[@]}"} >"$res" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
        fail "$name: reader exited $rc"
        return 0
    fi
    local got
    got="$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(r.roles.implementer.tier+" "+r.roles.implementer.source)' "$res")"
    if [ "$got" != "$want_tier $want_source" ]; then
        fail "$name: implementer resolved $got, expected $want_tier $want_source"
        return 0
    fi
    lines="$(node "$helper" disclose --inputs "$tr" --resolved "$res")"
    local s
    for s in "$@"; do
        grep -qF -- "$s" <<<"$lines" || {
            fail "$name: disclosure lacks \"$s\":"$'\n'"$lines"
            return 0
        }
    done
    ok
}

trusted='"pin_provenance":{"marker_trusted":true,"value_trusted":true}'
e2e "derived Tier sets the implementer" '{"labels":["risk:critical","complexity:xl"]}' apex derived \
    "source: derived" "issue Tier: derived apex"
e2e "pin beats a scoped label, and the label is disclosed as overridden" \
    "{\"labels\":[\"tier:pinned\",\"tier:economy\",\"tier:implementer:frontier\"],\"authorized_labels\":[\"tier:implementer:frontier\"],$trusted}" economy pinned \
    "source: pinned" "pin: honored" "overridden: tier:implementer:frontier"
e2e "pin-caused invariant break is named" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\"],$trusted}" apex pinned \
    "pin-caused invariant break: challenger"
e2e "without the pin, the scoped label beats the derived Tier" \
    '{"labels":["tier:implementer:economy","risk:critical","complexity:xl"],"authorized_labels":["tier:implementer:economy"]}' economy label \
    "source: rigor" "issue Tier: derived apex"
e2e "an unauthorized scoped label leaves the derived Tier in charge, and says so" \
    '{"labels":["tier:implementer:economy","risk:critical","complexity:xl"]}' apex derived \
    "source: derived" "warning [policy-label-unauthorized]" "tier:implementer:economy"
e2e "ambiguous pin resolves through the derived Tier" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:local\",\"risk:low\",\"complexity:xs\"],$trusted}" local derived \
    "warning [pin-ambiguous]" "tier:apex" "tier:local" "source: derived"
e2e "untrusted pin resolves unpinned and says so" \
    '{"labels":["tier:pinned","tier:apex","risk:low","complexity:xs"]}' local derived \
    "pin: ignored (untrusted)" "warning [pin-untrusted]"
e2e "leftover tier:adaptive resolves as absent" '{"labels":["tier:adaptive"]}' standard rigor-profile \
    "source: default" "warning [tier-retired]"
e2e "no classification resolves to the default profile" '{"labels":[]}' standard rigor-profile "source: default"
e2e "a stale strategy label no longer blocks resolution" \
    '{"labels":["strategy:bogus"],"authorized_labels":["strategy:bogus"]}' standard rigor-profile \
    "warning [strategy-label-unknown]"

echo "==> disclosure lines match what the reader resolved (integration remediation 2)"
# disclose_lines INPUT — prints the PR-body disclosure lines for INPUT,
# resolved over the corpus base policy.
disclose_lines() {
    local tr="$scratch/$RANDOM-dl-tr.json" res="$scratch/$RANDOM-dl-res.json"
    translate "$1" >"$tr"
    local -a args=()
    while IFS= read -r a; do args+=("$a"); done < <(node -e 'for (const a of JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).args) console.log(a)' "$tr")
    node "$reader" resolve --policy "$base_policy" --json ${args[@]+"${args[@]}"} >"$res" 2>/dev/null || true
    node "$helper" disclose --inputs "$tr" --resolved "$res"
}
# Thread 4178249117: a REJECTED role label is disclosed once, as rejected,
# with the reader's reason — never also as "overridden" or as a second warning.
rejected_lines="$(disclose_lines '{"labels":["tier:reviewer:adaptive"],"authorized_labels":["tier:reviewer:adaptive"]}')"
if grep -qF "rejected: tier:reviewer:adaptive" <<<"$rejected_lines" &&
    grep -qF "retired" <<<"$rejected_lines" &&
    ! grep -qF "overridden:" <<<"$rejected_lines" &&
    ! grep -qF "warning [tier-retired]" <<<"$rejected_lines"; then
    ok
else
    fail "a rejected role label must be disclosed once, as rejected, with the reason:"$'\n'"$rejected_lines"
fi
# A VALID label that lost to a stronger rung is still "overridden".
e2e "a valid scoped label beaten by a pin is still disclosed as overridden" \
    "{\"labels\":[\"tier:pinned\",\"tier:economy\",\"tier:implementer:frontier\"],\"authorized_labels\":[\"tier:implementer:frontier\"],$trusted}" \
    economy pinned "overridden: tier:implementer:frontier"
# Thread 4178249123: an ambiguous pin drops the pin rung only — an authorized
# scoped label still decides, and no line claims the derived Tier decided.
e2e "an ambiguous pin plus an authorized scoped label resolves the label" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:local\",\"tier:implementer:economy\",\"risk:critical\",\"complexity:xl\"],\"authorized_labels\":[\"tier:implementer:economy\"],$trusted}" \
    economy label "warning [pin-ambiguous]" "the pin rung is dropped" "source: rigor"
ambiguous_lines="$(disclose_lines "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:local\",\"tier:implementer:economy\"],\"authorized_labels\":[\"tier:implementer:economy\"],$trusted}")"
if grep -qF "resolves through its derived Tier" <<<"$ambiguous_lines"; then
    fail "the ambiguous-pin disclosure must not claim the derived Tier decided:"$'\n'"$ambiguous_lines"
else
    ok
fi

echo "==> disclose names the selection sources from the translation (thread 4178487553)"
for case_def in \
    'label|{"labels":["strategy:council"],"authorized_labels":["strategy:council"]}|Strategy: council (source: label)' \
    'operator|{"operator":{"strategy":"council"}}|Strategy: council (source: operator)' \
    'default|{"labels":[]}|Strategy: plan (source: default)' \
    'ambiguous|{"labels":["strategy:plan","strategy:council"],"authorized_labels":["strategy:plan","strategy:council"]}|ambiguous between plan, council'; do
    case_name="${case_def%%|*}"
    rest="${case_def#*|}"
    case_input="${rest%|*}"
    case_want="${rest##*|}"
    case_lines="$(disclose_lines "$case_input")"
    if grep -qF -- "$case_want" <<<"$case_lines"; then ok; else fail "disclose ($case_name) lacks \"$case_want\":"$'\n'"$case_lines"; fi
done

echo "==> the documented step-0 trigger sees committed, staged, unstaged and untracked edits (thread 4178487547)"
# The trigger command block is EXTRACTED from dev-flow-support/SKILL.md (the
# first ```sh block after "When it applies"), so this tests the documented
# text itself, not a copy that could drift from it.
dfs_md="$repo_root/ai/skills/universal/dev-flow-support/SKILL.md"
trigger_cmd="$(awk '/When it applies:/{seen=1} seen && /```sh/{grab=1; next} grab && /```/{exit} grab{sub(/^[[:space:]]+/, ""); print}' "$dfs_md")"
if [ -z "$trigger_cmd" ]; then
    fail "could not extract the step-0 trigger command from dev-flow-support/SKILL.md"
else
    trig="$scratch/trigger-repo"
    git init -q -b main "$trig"
    git -C "$trig" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m base
    mkdir -p "$trig/ai/skills/universal/dev-flow-support/assets/lib"
    # The target repository is bound the way /implement step 1 binds it; the
    # probe finds the remote by URL and reads that remote's default branch.
    git -C "$trig" remote add origin https://github.com/Acme/Widget.git
    git -C "$trig" update-ref refs/remotes/origin/main HEAD
    git -C "$trig" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    git -C "$trig" checkout -q -b topic
    trig_repo="acme/widget"
    # run_trigger — defines the extracted step0_probe in $trig, runs the
    # documented call, and prints "rc=<n> <governing files>".
    run_trigger() {
        (cd "$trig" && repo="$trig_repo" && eval "$trigger_cmd" && printf 'rc=%s %s' "$rc" "$(printf '%s' "$governing" | tr '\n' ' ')") 2>/dev/null
    }
    # expect_trigger NAME applies|none|indeterminate [FILE] — the probe's rc is
    # 0, 1 or 2; for "applies", FILE must be among the governing files.
    expect_trigger() {
        local name="$1" want="$2" file="${3:-}" out want_rc
        case "$want" in applies) want_rc=0 ;; none) want_rc=1 ;; *) want_rc=2 ;; esac
        out="$(run_trigger)"
        if [ "${out%% *}" != "rc=$want_rc" ]; then
            fail "step-0 probe ($name): expected $want (rc=$want_rc), got: ${out:-<nothing>}"
        elif [ -n "$file" ] && ! grep -qF -- "$file" <<<"$out"; then
            fail "step-0 probe ($name): expected it to report $file, got: $out"
        else
            ok
        fi
    }
    printf 'x\n' >"$trig/README.md"
    expect_trigger "an untracked non-governing file" none
    printf 'schema_version = 2\n' >"$trig/.devflow.toml"
    expect_trigger "an untracked .devflow.toml" applies .devflow.toml
    git -C "$trig" add .devflow.toml
    expect_trigger "a staged-only .devflow.toml" applies .devflow.toml
    git -C "$trig" -c user.email=t@example.invalid -c user.name=t commit -q -m policy
    # Remediation 4 case 1: a branch editing a governing file, remote named origin.
    expect_trigger "a committed .devflow.toml, remote named origin (thread 4178657188, case 1)" applies .devflow.toml
    # Case 2: the same branch with the remote renamed — still reported.
    git -C "$trig" remote rename origin upstream
    expect_trigger "the same edit with the remote renamed (thread 4178657188, case 2)" applies .devflow.toml
    # Case 3: no resolvable merge base — the remote's default branch is an
    # unrelated history — stops indeterminate instead of reporting nothing.
    orphan="$(git -C "$trig" -c user.email=t@example.invalid -c user.name=t commit-tree -m unrelated "$(git -C "$trig" mktree </dev/null)")"
    upstream_tip="$(git -C "$trig" rev-parse refs/remotes/upstream/main)"
    git -C "$trig" update-ref refs/remotes/upstream/main "$orphan"
    expect_trigger "no resolvable merge base (thread 4178657188, case 3)" indeterminate
    git -C "$trig" update-ref refs/remotes/upstream/main "$upstream_tip"
    # Every other lookup fails closed the same way.
    trig_repo="other/repo"
    expect_trigger "no remote whose URL matches the target repository" indeterminate
    trig_repo="acme/widget"
    git -C "$trig" symbolic-ref --delete refs/remotes/upstream/HEAD
    expect_trigger "a remote with no default branch" indeterminate
    git -C "$trig" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/main
    # The remaining working-tree cases, under the renamed remote.
    git -C "$trig" update-ref refs/remotes/upstream/main HEAD
    expect_trigger "the policy already on the merge base" none
    printf 'schema_version = 3\n' >"$trig/.devflow.toml"
    expect_trigger "an unstaged edit to a tracked .devflow.toml" applies .devflow.toml
    git -C "$trig" checkout -q -- .devflow.toml
    printf '// helper\n' >"$trig/ai/skills/universal/dev-flow-support/assets/tier-inputs.mjs"
    expect_trigger "an untracked tier-inputs.mjs" applies tier-inputs.mjs
fi
# Thread 4178657188: the documented probe names no literal remote.
if grep -qw 'origin' <<<"$trigger_cmd"; then
    fail "the step-0 probe hard-codes a remote name (origin)"
else
    ok
fi

echo "==> the documented resolve recipe exits 0 (integration remediation 1, thread 4176257539)"
# The exact command shape dev-flow-support § "Resolving an issue's Tier" step 3
# documents — helper, the while-read argument loop, then `resolve` with
# --taskfile-dir . run from the repository root — over the fixture policy
# (whose gate and finder targets this repository's Taskfile defines). Without
# --taskfile-dir the gate-target check is indeterminate and resolve exits 3
# whatever the issue says; the control below proves the flag is what clears it.
recipe_dir="$scratch/recipe"
mkdir -p "$recipe_dir"
printf '%s' '{"labels":["risk:high","complexity:m"]}' >"$recipe_dir/tier-input.json"
recipe_rc=0
(
    cd "$repo_root" || exit 99
    node "$helper" --policy "$base_policy" --input "$recipe_dir/tier-input.json" >"$recipe_dir/tier-translation.json" || exit 98
    tier_args=()
    while IFS= read -r a; do tier_args+=("$a"); done \
        < <(node -e 'for (const a of JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).args) console.log(a)' "$recipe_dir/tier-translation.json")
    node "$reader" resolve --policy "$base_policy" \
        --registry "$fixture_dir_recipe/agent-registry.json" --taskfile-dir . \
        --json ${tier_args[@]+"${tier_args[@]}"} >"$recipe_dir/resolved.json" 2>"$recipe_dir/resolve.err"
) || recipe_rc=$?
if [ "$recipe_rc" -eq 0 ]; then ok; else fail "the documented recipe must exit 0, got $recipe_rc: $(head -3 "$recipe_dir/resolve.err" 2>/dev/null)"; fi
control_rc=0
node "$reader" resolve --policy "$base_policy" --registry "$fixture_dir_recipe/agent-registry.json" --json \
    --risk=high --complexity=m >/dev/null 2>&1 || control_rc=$?
if [ "$control_rc" -eq 3 ]; then ok; else fail "control: without --taskfile-dir resolve must exit 3 (indeterminate targets), got $control_rc"; fi

echo "==> tier-inputs.mjs + devflow-policy.mjs: an ambiguous classification is indeterminate, never absent (review round 1, R1-1)"
# Resolved WITH the fixture registry and task-target list, so cross-validation
# is determinate and exit 3 can only come from the derived Tier.
fixture_dir="$repo_root/ai/schemas/fixtures/devflow-conformance"
# expect_indeterminate NAME INPUT — exit 3, issue_tier indeterminate, and the
# reader's own indeterminate names the derived Tier.
expect_indeterminate() {
    local name="$1" input="$2" tr="$scratch/$RANDOM-ind-tr.json" res="$scratch/$RANDOM-ind-res.json" rc=0
    translate "$input" >"$tr"
    local -a args=()
    while IFS= read -r a; do args+=("$a"); done < <(node -e 'for (const a of JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).args) console.log(a)' "$tr")
    node "$reader" resolve --policy "$base_policy" --registry "$fixture_dir/agent-registry.json" \
        --task-targets "$fixture_dir/task-targets.json" --json ${args[@]+"${args[@]}"} >"$res" 2>/dev/null || rc=$?
    if [ "$rc" -ne 3 ]; then
        fail "$name: expected exit 3, got $rc"
        return 0
    fi
    if ! node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const ok = r.issue_tier.status === "indeterminate" && r.cross_validation.indeterminate.some((i) => i.includes("derived Tier"));
process.exit(ok ? 0 : 1);
' "$res"; then
        fail "$name: issue_tier is not indeterminate on the derived Tier: $(head -c 400 "$res")"
        return 0
    fi
    ok
}
expect_indeterminate "both axes conflicting" '{"labels":["risk:high","risk:low","complexity:s","complexity:xl"]}'
expect_indeterminate "risk conflicting, complexity absent" '{"labels":["risk:high","risk:low"]}'
expect_indeterminate "risk conflicting, complexity clean" '{"labels":["risk:high","risk:low","complexity:m"]}'
expect_indeterminate "a mixed-validity ambiguous pin resolves through the (indeterminate) derived Tier" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:APEX\",\"risk:high\",\"risk:low\"],$pin_trust}"

echo "==> devflow-policy.mjs: with no [tier.matrix], exit 3 only when the derived rung decides (review round 2, R2-2)"
no_matrix_policy="$scratch/no-matrix-r22.toml"
awk '/^\[tier\.matrix\]/{skip=1; next} skip && /^\[/{skip=0} !skip' "$base_policy" >"$no_matrix_policy"
# nm_resolve EXPECTED_RC EXPECTED_SOURCE NAME ARG... — resolve a classified
# issue with no matrix and check the exit code and the implementer's source.
nm_resolve() {
    local want_rc="$1" want_source="$2" name="$3" rc=0
    shift 3
    node "$reader" resolve --policy "$no_matrix_policy" --registry "$fixture_dir/agent-registry.json" \
        --task-targets "$fixture_dir/task-targets.json" --json --risk=high --complexity=m "$@" \
        >"$scratch/nm-r22.json" 2>/dev/null || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        fail "$name: expected exit $want_rc, got $rc"
        return 0
    fi
    if node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.exit(r.issue_tier.status === "indeterminate" && r.roles.implementer.source === process.argv[2] ? 0 : 1);
' "$scratch/nm-r22.json" "$want_source"; then ok; else fail "$name: expected issue_tier indeterminate and implementer source $want_source"; fi
}
nm_resolve 3 rigor-profile "the derived rung decides: indeterminate, exit 3"
nm_resolve 0 pinned "an honored pin decides: exit 0, issue_tier still indeterminate" \
    --pinned-tier frontier --pin-marker-trusted --pin-value-trusted
nm_resolve 0 label "a scoped implementer label decides: exit 0" --tier-labels implementer=economy
nm_resolve 0 rigor-profile "a chosen rigor decides: exit 0" --rigor deep --rigor-source label
# Control: a clean classification under the same inputs resolves determinately.
rc=0
node "$reader" resolve --policy "$base_policy" --registry "$fixture_dir/agent-registry.json" \
    --task-targets "$fixture_dir/task-targets.json" --json --risk=high --complexity=m >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then ok; else fail "control: a clean classification must exit 0 with the fixture registry and targets, got $rc"; fi

echo "==> devflow-policy.mjs: no [tier.matrix] means indeterminate, never a guess"
no_matrix="$scratch/no-matrix.toml"
awk '/^\[tier\.matrix\]/{skip=1; next} skip && /^\[/{skip=0} !skip' "$base_policy" >"$no_matrix"
if grep -q '^\[tier\.matrix\]' "$no_matrix"; then
    fail "could not strip [tier.matrix] from the base policy fixture"
else
    rc=0
    node "$reader" resolve --policy "$no_matrix" --json --risk=high --complexity=m >"$scratch/nm.json" 2>/dev/null || rc=$?
    if [ "$rc" -ne 3 ]; then
        fail "a classified issue under a policy with no [tier.matrix] must exit 3, got $rc"
    elif ! grep -q 'derived Tier cannot be computed' "$scratch/nm.json"; then
        fail "the indeterminate must name the derived Tier"
    else
        ok
    fi
fi

if [ "$failures" -ne 0 ]; then
    echo "test-tier-inputs: $failures failure(s), $pass passed" >&2
    exit 1
fi
echo "  ✓ tier-inputs: $pass case(s) passed"
