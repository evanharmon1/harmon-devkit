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

# translate JSON → prints the helper's JSON output
translate() {
    printf '%s' "$1" | node "$helper"
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
expect_warning "two stored Tiers without a pin warn" '{"labels":["tier:local","tier:apex"]}' stored-tier-ambiguous "tier:local" "tier:apex"
expect_args "role-label conflict takes the strongest" \
    '{"labels":["tier:implementer:economy","tier:implementer:frontier"]}' '["--tier-labels=implementer=frontier"]'
expect_warning "role-label conflict is disclosed" \
    '{"labels":["tier:implementer:economy","tier:implementer:frontier"]}' tier-role-label-conflict "frontier"
expect_args "a leftover tier:<role>:adaptive reaches the reader to be named retired" \
    '{"labels":["tier:reviewer:adaptive"]}' '["--tier-labels=reviewer=adaptive"]'
expect_args "rigor-label conflict takes the strongest" \
    '{"labels":["rigor:light","rigor:deep"]}' '["--rigor","deep","--rigor-source=label"]'
expect_args "operator rigor outranks a rigor label" \
    '{"labels":["rigor:deep"],"operator":{"rigor":"light"}}' '["--rigor","light","--rigor-source=operator"]'
expect_args "two strategy labels pass none" '{"labels":["strategy:plan","strategy:council"]}' '[]'
expect_warning "two strategy labels warn" '{"labels":["strategy:plan","strategy:council"]}' strategy-label-ambiguous
expect_args "operator tiers" '{"operator":{"tiers":{"implementer":"apex","reviewer":"frontier"}}}' \
    '["--tier-overrides=implementer=apex,reviewer=frontier"]'
expect_args "org fields are the classification" '{"fields":{"risk":"low","complexity":"xl"}}' '["--risk=low","--complexity=xl"]'
expect_args "a field wins over a disagreeing label" '{"labels":["risk:high"],"fields":{"risk":"low"}}' '["--risk=low"]'
expect_warning "a field/label disagreement warns" '{"labels":["risk:high"],"fields":{"risk":"low"}}' risk-field-label-mismatch
expect_args "conflicting risk labels pass neither" '{"labels":["risk:high","risk:low","complexity:s"]}' '["--complexity=s"]'
expect_args "a non-slug value never reaches the reader" '{"labels":["tier:--json"]}' '[]'
if printf '%s' '{"labels":"tier:standard"}' | node "$helper" >/dev/null 2>&1; then
    fail "malformed input must exit non-zero"
else
    ok
fi

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
    "{\"labels\":[\"tier:pinned\",\"tier:economy\",\"tier:implementer:frontier\"],$trusted}" economy pinned \
    "source: pinned" "pin: honored" "overridden: tier:implementer:frontier"
e2e "pin-caused invariant break is named" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\"],$trusted}" apex pinned \
    "pin-caused invariant break: challenger"
e2e "without the pin, the scoped label beats the derived Tier" \
    '{"labels":["tier:implementer:economy","risk:critical","complexity:xl"]}' economy label \
    "source: rigor" "issue Tier: derived apex"
e2e "ambiguous pin resolves through the derived Tier" \
    "{\"labels\":[\"tier:pinned\",\"tier:apex\",\"tier:local\",\"risk:low\",\"complexity:xs\"],$trusted}" local derived \
    "warning [pin-ambiguous]" "tier:apex" "tier:local" "source: derived"
e2e "untrusted pin resolves unpinned and says so" \
    '{"labels":["tier:pinned","tier:apex","risk:low","complexity:xs"]}' local derived \
    "pin: ignored (untrusted)" "warning [pin-untrusted]"
e2e "leftover tier:adaptive resolves as absent" '{"labels":["tier:adaptive"]}' standard rigor-profile \
    "source: default" "warning [tier-retired]"
e2e "no classification resolves to the default profile" '{"labels":[]}' standard rigor-profile "source: default"

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
