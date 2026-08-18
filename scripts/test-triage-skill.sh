#!/usr/bin/env bash
# test-triage-skill.sh — unit-test the triage skill's contract scripts. Fully
# offline: every `gh` call goes to a PATH-stubbed gh driven by fixture files,
# and the wrapper's model run goes to a PATH-stubbed claude.
#
# What this keeps honest (issue #455's [CI] criteria):
#   - the write-allowlist is computed from label-registry.json (agent-writable,
#     v1 scope, retired excluded) with the gh-label fallback
#   - the never-list refuses foreman:/rigor:/tier:/method:/claim:/suggest:/
#     agent:* even when a hostile manifest grants them
#   - work-type labels are refused on org repos (native Type owns them there)
#   - needs-triage is removed only when classification is complete
#   - --execute is inert without the wrapper-owned TRIAGE_EXECUTE=1 env gate
#   - the rolling report is idempotent, upserts only its marker-carrying
#     issue, and the scan excludes it from triage (self-exclusion)
#
# Run via `task test:triage-skill`.
set -euo pipefail
cd "$(dirname "$0")/.."
# Deterministic stdin: a harness handing this suite a never-closing stdin
# would hang any stubbed call that drains it.
exec </dev/null

apply="./ai/skills/universal/triage/assets/triage-apply.sh"
scan="./ai/skills/universal/triage/assets/triage-scan.sh"
report="./ai/skills/universal/triage/assets/triage-report.sh"
wrapper="./scripts/triage.sh"
repo="testowner/testrepo"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub_dir="$tmp/fixtures"
mkdir -p "$tmp/bin" "$stub_dir"

# ── gh stub ──────────────────────────────────────────────────────────────────
# Emulates exactly the call shapes the triage scripts make. Fixture files live
# in GH_STUB_DIR; every invocation is appended to GH_STUB_LOG. Writes are
# logged, drained, and succeed.
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GH_STUB_LOG:?}"
q=""
state=""
prev=""
for a in "$@"; do
    case "$prev" in
    -q) q="$a" ;;
    --state) state="$a" ;;
    esac
    prev="$a"
done
emit() {
    if [ -n "$q" ]; then jq -r "$q" <"$1"; else cat "$1"; fi
}
case "${1:-} ${2:-}" in
"api user")
    printf '%s\n' "${GH_STUB_VIEWER:-testowner}"
    ;;
"api graphql")
    [ "${GH_STUB_NATIVE_TYPE:-}" = "ERROR" ] && exit 1
    printf '%s\n' "${GH_STUB_NATIVE_TYPE:-}"
    ;;
api\ repos/*/issues/*)
    n="${2##*/}"
    v="GH_STUB_ASSOC_$n"
    printf '%s\n' "${!v:-OWNER}"
    ;;
api\ repos/*)
    printf '%s\n' "${GH_STUB_OWNER_TYPE:?}"
    ;;
"label list") emit "${GH_STUB_DIR:?}/labels.json" ;;
"issue list")
    # A --json field set naming issueType emulates the bulk native-Type read:
    # newer gh serves it from issues-open-types.json, older gh (no fixture)
    # rejects the field.
    if printf '%s' "$*" | grep -q "issueType"; then
        [ -f "${GH_STUB_DIR:?}/issues-open-types.json" ] || exit 1
        emit "${GH_STUB_DIR:?}/issues-open-types.json"
    else
        emit "${GH_STUB_DIR:?}/issues-${state:?}.json"
    fi
    ;;
"issue view") emit "${GH_STUB_DIR:?}/issue-${3:?}.json" ;;
"repo view") printf '%s\n' "${GH_STUB_REPO:?}" ;;
# Only the body-carrying writes read stdin (--body-file -): drain just there,
# so a stubbed read call inside a caller's while-read loop cannot eat the
# loop's remaining input or hang on a never-closing stdin.
"issue edit") [ -t 0 ] || cat >/dev/null ;;
"issue create")
    [ -t 0 ] || cat >/dev/null
    printf '%s\n' "https://github.com/stub/stub/issues/321"
    ;;
*)
    echo "gh stub: unexpected call: $*" >&2
    exit 97
    ;;
esac
STUB
# claude stub for the wrapper test: record argv and the env gate's value.
cat >"$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
    echo "  --setting-sources <sources>"
    exit 0
fi
printf '%s\n' "ARGS: $*" >>"${GH_STUB_LOG:?}"
printf '%s\n' "TRIAGE_EXECUTE=${TRIAGE_EXECUTE:-unset}" >>"${GH_STUB_LOG:?}"
printf '%s\n' "TRIAGE_REPO=${TRIAGE_REPO:-unset}" >>"${GH_STUB_LOG:?}"
printf '%s\n' "TRIAGE_SCRATCH=${TRIAGE_SCRATCH:-unset}" >>"${GH_STUB_LOG:?}"
STUB
chmod +x "$tmp/bin/gh" "$tmp/bin/claude"

export GH_STUB_DIR="$stub_dir"
export GH_STUB_LOG="$tmp/gh.log"
export GH_STUB_OWNER_TYPE="User"
: >"$GH_STUB_LOG"

# run CMD... -> echoes the exit code; output lands in $tmp/out.
run() {
    _rc=0
    PATH="$tmp/bin:$PATH" "$@" >"$tmp/out" 2>&1 || _rc=$?
    echo "$_rc"
}

# ── fixtures ─────────────────────────────────────────────────────────────────
manifest="$tmp/label-registry.json"
cat >"$manifest" <<'JSON'
{
  "$schema": "./label-registry.schema.json",
  "schema_version": 1,
  "families": [
    {"family": "workflow", "prefix": null, "axis": "workflow",
     "writers": ["human"],
     "values": [
       {"value": "needs-triage", "writers": ["human", "agent"]},
       {"value": "blocked"}]},
    {"family": "work-type", "prefix": null, "axis": "work-type",
     "writers": ["human", "agent"],
     "values": [
       {"value": "bug"}, {"value": "feature"},
       {"value": "enhancement", "retired": true}]},
    {"family": "area", "prefix": "area", "axis": "classification",
     "writers": ["human", "agent"], "exclusive": true,
     "values": [{"value": "ci"}, {"value": "tasks"}]},
    {"family": "layer", "prefix": "layer", "axis": "classification",
     "writers": ["human", "agent"], "exclusive": true,
     "values": [{"value": "ui"}]},
    {"family": "domain", "prefix": "domain", "axis": "classification",
     "writers": ["human", "agent"], "exclusive": true,
     "values": [{"value": "delivery"}, {"value": "auth"}]},
    {"family": "rigor", "prefix": "rigor", "axis": "strategy",
     "writers": ["human"], "values": [{"value": "deep"}]},
    {"family": "provenance", "prefix": null, "axis": "provenance",
     "writers": ["human", "agent"], "values": [{"value": "ai-generated"}]},
    {"family": "claim", "prefix": "claim", "axis": "model",
     "writers": ["agent"], "values": [{"value": "claude"}]}
  ]
}
JSON
# A hostile manifest that grants agents rigor:* — scope + never-list must hold.
evil="$tmp/evil-registry.json"
jq '.families |= map(if .family == "rigor"
    then .writers = ["human", "agent"] else . end)' \
    "$manifest" >"$evil"

echo "==> allowlist: manifest mode computes agent-writable v1 scope"
[ "$(run "$apply" allowlist --manifest "$manifest")" = 0 ] ||
    fail "allowlist should succeed: $(cat "$tmp/out")"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' area:ci area:tasks bug domain:auth domain:delivery feature \
    layer:ui needs-triage | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 || fail "allowlist mismatch"

echo "==> allowlist: excludes retired, human-only, and out-of-scope values"
for absent in enhancement rigor:deep blocked ai-generated claim:claude; do
    grep -qx "$absent" "$tmp/got" && fail "$absent must not be allowlisted"
done

echo "==> allowlist: a hostile manifest cannot widen the v1 scope"
[ "$(run "$apply" allowlist --manifest "$evil")" = 0 ] || fail "evil allowlist ran"
grep -qx "rigor:deep" "$tmp/out" && fail "rigor:deep leaked into the allowlist"

echo "==> allowlist: gh fallback = axis prefixes + fixed work-type vocabulary"
cat >"$stub_dir/labels.json" <<'JSON'
[{"name": "area:ci", "description": ""}, {"name": "layer:ui", "description": ""},
 {"name": "rigor:deep", "description": ""}, {"name": "bug", "description": ""},
 {"name": "enhancement", "description": ""},
 {"name": "needs-triage", "description": ""}]
JSON
[ "$(run "$apply" allowlist --repo "$repo" --manifest "$tmp/nope.json")" = 0 ] ||
    fail "fallback allowlist should succeed: $(cat "$tmp/out")"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' area:ci bug layer:ui needs-triage | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 ||
    fail "fallback mismatch (enhancement/rigor must be out)"

echo "==> axes: derived from the manifest's classification families"
[ "$(run "$apply" axes --manifest "$manifest")" = 0 ] || fail "axes failed"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' area domain layer | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 || fail "axes mismatch"

echo "==> axes: a repo that provisions only some axes derives only those"
jq '.families |= map(select(.family != "area"))' "$manifest" \
    >"$tmp/no-area.json"
[ "$(run "$apply" axes --manifest "$tmp/no-area.json")" = 0 ] ||
    fail "no-area axes failed"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' domain layer | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 || fail "no-area axes mismatch"

echo "==> axes: fallback derives the default prefixes present in live labels"
[ "$(run "$apply" axes --repo "$repo" --manifest "$tmp/nope.json")" = 0 ] ||
    fail "fallback axes failed"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' area layer | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 ||
    fail "fallback axes must be defaults ∩ live prefixes (no domain here)"
[ "$(run "$apply" axes --manifest "$tmp/nope.json")" = 2 ] ||
    fail "fallback axes without --repo must exit 2"

echo "==> axes: only exclusive classification families become axes"
jq '.families |= map(if .family == "area"
    then .exclusive = false else . end)' "$manifest" >"$tmp/nonexcl.json"
[ "$(run "$apply" axes --manifest "$tmp/nonexcl.json")" = 0 ] ||
    fail "non-exclusive axes failed"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' domain layer | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 ||
    fail "a non-exclusive classification family must not be an axis"
[ "$(run "$apply" allowlist --manifest "$tmp/nonexcl.json")" = 0 ] ||
    fail "non-exclusive allowlist failed"
grep -q "^area:" "$tmp/out" &&
    fail "a non-axis classification family must not be writable"

echo "==> axes: string-typed booleans are refused, never silently dropped"
jq '.families |= map(if .family == "area"
    then .exclusive = "true" else . end)' "$manifest" >"$tmp/strbool.json"
[ "$(run "$apply" axes --manifest "$tmp/strbool.json")" = 2 ] ||
    fail "a string-typed exclusive must exit 2"
jq '.families |= map(if .family == "area"
    then .retired = "false" else . end)' "$manifest" >"$tmp/strret.json"
[ "$(run "$apply" axes --manifest "$tmp/strret.json")" = 2 ] ||
    fail "a string-typed retired must exit 2, not skip its own validation"
jq '.families |= map(if .family == "area"
    then del(.exclusive) else . end)' "$manifest" >"$tmp/noexcl.json"
[ "$(run "$apply" axes --manifest "$tmp/noexcl.json")" = 2 ] ||
    fail "a classification family without exclusive must exit 2"

echo "==> axes: an unsupported schema_version is refused before deriving"
jq '.schema_version = 2' "$manifest" >"$tmp/v2.json"
[ "$(run "$apply" axes --manifest "$tmp/v2.json")" = 2 ] ||
    fail "schema_version 2 must exit 2"
jq 'del(.schema_version)' "$manifest" >"$tmp/nover.json"
[ "$(run "$apply" axes --manifest "$tmp/nover.json")" = 2 ] ||
    fail "an absent schema_version must exit 2"
jq '.schema_version = "1"' "$manifest" >"$tmp/strver.json"
[ "$(run "$apply" axes --manifest "$tmp/strver.json")" = 2 ] ||
    fail "a string schema_version must exit 2 (typed compare, no coercion)"
jq 'del(."$schema")' "$manifest" >"$tmp/noschema.json"
[ "$(run "$apply" axes --manifest "$tmp/noschema.json")" = 2 ] ||
    fail "an absent \$schema must exit 2"
jq '.families |= (map({(.family): .}) | add)' "$manifest" >"$tmp/objfam.json"
[ "$(run "$apply" axes --manifest "$tmp/objfam.json")" = 2 ] ||
    fail "an object families collection must exit 2"

echo "==> axes: a reserved prefix never becomes a classification axis"
jq '.families |= map(if .family == "area"
    then .prefix = "rigor" else . end)' "$manifest" >"$tmp/reserved.json"
[ "$(run "$apply" axes --manifest "$tmp/reserved.json")" = 2 ] ||
    fail "a never-list prefix on a classification family must exit 2"

echo "==> axis-values: non-exclusive classification values are not recognized"
[ "$(run "$apply" axis-values --manifest "$tmp/nonexcl.json")" = 0 ] ||
    fail "nonexcl axis-values failed"
grep -q "^area:" "$tmp/out" &&
    fail "a non-axis family's values must not satisfy recognition"

echo "==> axis-values: manifest mode lists the active taxonomy, retired out"
jq '.families |= map(if .family == "area"
    then .values += [{"value": "old", "retired": true}] else . end)' \
    "$manifest" >"$tmp/retired-value.json"
[ "$(run "$apply" axis-values --manifest "$tmp/retired-value.json")" = 0 ] ||
    fail "axis-values failed"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' area:ci area:tasks domain:auth domain:delivery layer:ui |
    sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 || fail "axis-values mismatch"

echo "==> axes: an invalid registry is refused, never derived around"
jq '.families |= map(if .family == "area"
    then .axis = "classificaton" else . end)' "$manifest" >"$tmp/typo.json"
[ "$(run "$apply" axes --manifest "$tmp/typo.json")" = 2 ] ||
    fail "a mistyped axis must exit 2, not silently drop the family"
grep -q "cannot govern" "$tmp/out" || fail "refusal must say why"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$tmp/typo.json")" = 2 ] ||
    fail "removal under an invalid registry must exit 2"

echo "==> axes: an open-values classification family is refused, not governed"
jq '.families |= map(if .family == "area"
    then .open_values = true | .values = [] else . end)' \
    "$manifest" >"$tmp/open-area.json"
for sub in axes axis-values allowlist; do
    [ "$(run "$apply" "$sub" --repo "$repo" \
        --manifest "$tmp/open-area.json")" = 2 ] ||
        fail "$sub must refuse an open-values classification family"
done
jq '.families |= map(if .family == "area"
    then .open_values = "false" else . end)' \
    "$manifest" >"$tmp/open-str.json"
[ "$(run "$apply" axes --manifest "$tmp/open-str.json")" = 2 ] ||
    fail "a non-boolean open_values must refuse (errs closed)"

echo "==> axes: an ERE-metacharacter prefix is refused, never compiled"
jq '.families |= map(if .family == "area"
    then .prefix = "x)|(.+" else . end)' \
    "$manifest" >"$tmp/evil-prefix.json"
[ "$(run "$apply" axes --manifest "$tmp/evil-prefix.json")" = 2 ] ||
    fail "a non-slug prefix must exit 2"
[ "$(run "$apply" allowlist --repo "$repo" \
    --manifest "$tmp/evil-prefix.json")" = 2 ] ||
    fail "allowlist under a non-slug prefix must exit 2"

# Issue fixtures for the label subcommand.
cat >"$stub_dir/issue-10.json" <<'JSON'
{"labels": [{"name": "needs-triage"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-11.json" <<'JSON'
{"labels": [{"name": "area:tasks"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-12.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "domain:auth"},
            {"name": "domain:delivery"}, {"name": "bug"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-13.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"}, {"name": "area:ci"}],
 "body": "plain"}
JSON

echo "==> label: never-list refuses even what a hostile manifest grants"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add rigor:deep \
    --manifest "$evil")" = 4 ] || fail "rigor:deep must exit 4"
for l in foreman:approved tier:apex method:plan claim:claude suggest:claude \
    agent:claude-code; do
    [ "$(run "$apply" label --repo "$repo" --issue 10 --add "$l" \
        --manifest "$manifest")" = 4 ] || fail "$l must exit 4"
done

echo "==> label: off-allowlist labels are refused"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add ai-generated \
    --manifest "$manifest")" = 4 ] || fail "ai-generated must exit 4"

echo "==> label: dry-run prints WOULD lines and writes nothing"
: >"$GH_STUB_LOG"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add area:ci --add bug \
    --manifest "$manifest")" = 0 ] || fail "dry-run failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'area:ci'" "$tmp/out" || fail "missing WOULD area:ci"
grep -q "DRY-RUN would add 'bug'" "$tmp/out" || fail "missing WOULD bug"
grep -q "issue edit" "$GH_STUB_LOG" && fail "dry-run must not edit"

echo "==> label: work-type on an org repo is refused, axes still pass"
GH_STUB_OWNER_TYPE="Organization"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add bug \
    --manifest "$manifest")" = 5 ] || fail "org work-type must exit 5"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add area:ci \
    --manifest "$manifest")" = 0 ] || fail "org axis add must pass"
GH_STUB_OWNER_TYPE="User"

echo "==> label: a second work-type label is refused (triage fills, never stacks)"
[ "$(run "$apply" label --repo "$repo" --issue 13 --add feature \
    --manifest "$manifest")" = 4 ] || fail "feature over bug must exit 4"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add bug --add feature \
    --manifest "$manifest")" = 4 ] || fail "two work-types in one call must exit 4"

echo "==> label: a mismatched --repo is refused when the run is bound"
[ "$(run env TRIAGE_REPO="$repo" "$apply" label --repo other/elsewhere \
    --issue 10 --add area:ci)" = 4 ] ||
    fail "unbound repo write must exit 4"
[ "$(run env TRIAGE_REPO="$repo" "$apply" label --repo "$repo" --issue 10 \
    --add area:ci)" = 0 ] ||
    fail "bound repo write must pass (fallback allowlist)"

echo "==> label: a bound run refuses a caller-chosen manifest"
[ "$(run env TRIAGE_REPO="$repo" "$apply" label --repo "$repo" --issue 10 \
    --add area:ci --manifest "$manifest")" = 4 ] ||
    fail "bound run with custom manifest must exit 4"
[ "$(run env TRIAGE_REPO="$repo" "$apply" allowlist --repo "$repo" \
    --manifest "$evil")" = 4 ] ||
    fail "bound allowlist with custom manifest must exit 4"
[ "$(run env TRIAGE_REPO="$repo" "$scan" --repo "$repo" \
    --manifest "$manifest")" = 4 ] ||
    fail "bound scan with custom manifest must exit 4"

echo "==> label: comma-bearing labels are refused (gh splits them into two)"
jq '.families |= map(if .family == "area"
    then .values += [{"value": "ci,blocked"}] else . end)' \
    "$manifest" >"$tmp/comma.json"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add "area:ci,blocked" \
    --manifest "$tmp/comma.json")" = 4 ] || fail "comma label must exit 4"

echo "==> work-types: recognition is wider than writability"
jq '.families |= map(if .family == "work-type"
    then .writers = ["human"] else . end)' "$manifest" >"$tmp/human-wt.json"
[ "$(run "$apply" allowlist --manifest "$tmp/human-wt.json")" = 0 ] ||
    fail "human-wt allowlist failed"
grep -qx "bug" "$tmp/out" && fail "human-only bug must not be writable"
[ "$(run "$apply" work-types --manifest "$tmp/human-wt.json")" = 0 ] ||
    fail "work-types failed"
grep -qx "bug" "$tmp/out" || fail "human-only bug must still be recognized"

echo "==> label: removal accepts a human-applied work-type as classification"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$tmp/human-wt.json")" = 0 ] ||
    fail "human-applied bug must satisfy the removal gate: $(cat "$tmp/out")"

echo "==> label: --issue must be a plain number (URLs bypass the repo binding)"
[ "$(run "$apply" label --repo "$repo" \
    --issue "https://github.com/other/elsewhere/issues/5" \
    --add area:ci --manifest "$manifest")" = 2 ] ||
    fail "URL issue must exit 2"
[ "$(run "$apply" native-type --repo "$repo" \
    --issue "https://github.com/other/elsewhere/issues/5")" = 2 ] ||
    fail "URL issue on native-type must exit 2"

echo "==> label: exclusive axes refuse a second value"
[ "$(run "$apply" label --repo "$repo" --issue 11 --add area:ci \
    --manifest "$manifest")" = 4 ] || fail "second area label must exit 4"

echo "==> label: removal is refused where the manifest withholds needs-triage"
jq '.families |= map(if .family == "workflow"
    then .values |= map(if .value == "needs-triage"
                        then .writers = ["human"] else . end)
    else . end)' "$manifest" >"$tmp/human-only.json"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$tmp/human-only.json")" = 4 ] ||
    fail "human-only needs-triage removal must exit 4"

echo "==> label: --remove accepts only needs-triage"
[ "$(run "$apply" label --repo "$repo" --issue 10 --remove area:ci \
    --manifest "$manifest")" = 2 ] || fail "--remove area:ci must exit 2"

echo "==> label: needs-triage removal is refused on a conflicted axis"
[ "$(run "$apply" label --repo "$repo" --issue 12 --remove needs-triage \
    --inapplicable area --inapplicable layer \
    --manifest "$manifest")" = 6 ] || fail "conflicted axis must exit 6"

echo "==> label: needs-triage removal is refused without a work type"
[ "$(run "$apply" label --repo "$repo" --issue 10 --remove needs-triage \
    --inapplicable area --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 6 ] || fail "missing work type must exit 6"

echo "==> label: needs-triage removal passes when classification is complete"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 0 ] || fail "complete removal: $(cat "$tmp/out")"
grep -q "DRY-RUN would remove 'needs-triage'" "$tmp/out" ||
    fail "missing WOULD remove"
grep -q "attested inapplicable: layer" "$tmp/out" || fail "missing attestation"

echo "==> label: an unknown axis value never satisfies the removal gate"
cat >"$stub_dir/issue-14.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"},
            {"name": "area:legacy"}], "body": "plain"}
JSON
[ "$(run "$apply" label --repo "$repo" --issue 14 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 6 ] || fail "unknown area value must exit 6"
grep -q "not in the active area taxonomy" "$tmp/out" ||
    fail "refusal must name the unknown value: $(cat "$tmp/out")"

echo "==> label: an unprovisioned axis is never demanded (derived axes)"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$tmp/no-area.json")" = 0 ] ||
    fail "no-area manifest must not demand an area attestation: $(cat "$tmp/out")"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable area --inapplicable layer --inapplicable domain \
    --manifest "$tmp/no-area.json")" = 2 ] ||
    fail "--inapplicable for an inactive axis must exit 2"

echo "==> label: org removal needs a native Type; unreadable Type refuses"
GH_STUB_OWNER_TYPE="Organization"
export GH_STUB_NATIVE_TYPE=""
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 6 ] || fail "org without Type must exit 6"
export GH_STUB_NATIVE_TYPE="ERROR"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 6 ] || fail "unreadable Type must exit 6"
export GH_STUB_NATIVE_TYPE="Bug"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 0 ] || fail "org with Type should pass"
unset GH_STUB_NATIVE_TYPE
GH_STUB_OWNER_TYPE="User"

echo "==> label: --execute is inert without TRIAGE_EXECUTE=1"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add area:ci --execute \
    --manifest "$manifest")" = 2 ] || fail "--execute without env must exit 2"
grep -q "issue edit" "$GH_STUB_LOG" && fail "gated execute must not edit"

echo "==> label: --execute with the env gate edits and reports APPLIED"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 10 \
    --add area:ci --execute --manifest "$manifest")" = 0 ] ||
    fail "gated execute failed: $(cat "$tmp/out")"
grep -q "APPLIED add 'area:ci'" "$tmp/out" || fail "missing APPLIED"
grep -q -- "--add-label area:ci" "$GH_STUB_LOG" || fail "edit not issued"

echo "==> native-type: prints none for an unset Type"
export GH_STUB_NATIVE_TYPE=""
[ "$(run "$apply" native-type --repo "$repo" --issue 10)" = 0 ] ||
    fail "native-type failed"
grep -qx "none" "$tmp/out" || fail "expected none"
unset GH_STUB_NATIVE_TYPE

# ── report ───────────────────────────────────────────────────────────────────
marker='<!-- harmon-triage-report -->'
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 90, "body": "no marker here", "author": {"login": "testowner"}},
 {"number": 99, "body": "$marker\nrolling report",
  "author": {"login": "testowner"}}]
JSON

echo "==> report find: locates the marker-carrying issue"
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "find failed"
grep -qx "99" "$tmp/out" || fail "expected 99, got: $(cat "$tmp/out")"

echo "==> report find: none without a marker; ambiguous refuses"
cat >"$stub_dir/issues-open.json" <<'JSON'
[{"number": 90, "body": "no marker", "author": {"login": "testowner"}}]
JSON
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "find(none) failed"
grep -qx "none" "$tmp/out" || fail "expected none"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 98, "body": "$marker", "author": {"login": "testowner"}},
 {"number": 99, "body": "$marker", "author": {"login": "testowner"}}]
JSON
[ "$(run "$report" find --repo "$repo")" = 2 ] || fail "ambiguous must exit 2"

echo "==> report find: an untrusted author's forged marker is not the report"
export GH_STUB_ASSOC_66="NONE"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 66, "body": "$marker forged", "author": {"login": "attacker"}},
 {"number": 99, "body": "$marker", "author": {"login": "testowner"}}]
JSON
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "forged find failed"
grep -qx "99" "$tmp/out" || fail "forged marker must be ignored, want 99"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 66, "body": "$marker forged", "author": {"login": "attacker"}}]
JSON
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "forged-only find failed"
grep -qx "none" "$tmp/out" || fail "a forged-only marker must read as none"

echo "==> report find: a MEMBER-authored report stays visible to other runners"
export GH_STUB_ASSOC_66="MEMBER"
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "member find failed"
grep -qx "66" "$tmp/out" || fail "member-authored report must be found"
unset GH_STUB_ASSOC_66

entries="$tmp/entries.md"
cat >"$entries" <<'MD'
### #12 — axis-conflict: two domain labels
<!-- triage-entry:12 -->
- Evidence: domain:auth and domain:delivery both applied.
- Suggested action: keep one; needs-triage retained.

## Title violations

- #30 — some: prefixed title
MD

echo "==> report sync: malformed entries (heading without key) are refused"
printf '### #7 — broken\nno key line\n' >"$tmp/bad.md"
[ "$(run "$report" sync --repo "$repo" --entries-file "$tmp/bad.md")" = 2 ] ||
    fail "malformed entries must exit 2"

echo "==> report sync: dry-run assembles the body and writes nothing"
cat >"$stub_dir/issues-open.json" <<'JSON'
[{"number": 90, "body": "no marker", "author": {"login": "testowner"}}]
JSON
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$entries")" = 0 ] || fail "sync dry-run: $(cat "$tmp/out")"
grep -q "DRY-RUN would create" "$tmp/out" || fail "expected create path"
grep -qF "$marker" "$tmp/out" || fail "body must carry the marker"
grep -q "triage-entry:12" "$tmp/out" || fail "body must carry the entry key"
grep -qE "issue (edit|create)" "$GH_STUB_LOG" && fail "dry-run must not write"

echo "==> report sync: re-runs are idempotent (same entries, same body)"
run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$entries" >/dev/null
cp "$tmp/out" "$tmp/body1"
run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$entries" >/dev/null
diff -u "$tmp/body1" "$tmp/out" >&2 || fail "sync is not idempotent"

echo "==> report sync: updates only a live marker-carrying issue"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "body": "$marker", "author": {"login": "testowner"}}]
JSON
cat >"$stub_dir/issue-99.json" <<'JSON'
{"labels": [], "body": "marker was edited away"}
JSON
[ "$(run env TRIAGE_EXECUTE=1 "$report" sync --repo "$repo" \
    --entries-file "$entries" --execute)" = 4 ] ||
    fail "marker-less live body must exit 4"
cat >"$stub_dir/issue-99.json" <<JSON
{"labels": [], "body": "$marker\nold body"}
JSON
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$report" sync --repo "$repo" \
    --entries-file "$entries" --execute)" = 0 ] ||
    fail "marker-carrying update failed: $(cat "$tmp/out")"
grep -q "issue edit 99" "$GH_STUB_LOG" || fail "edit of #99 not issued"

echo "==> report sync: --execute without the env gate is refused"
[ "$(run "$report" sync --repo "$repo" --entries-file "$entries" \
    --execute)" = 2 ] || fail "sync --execute without env must exit 2"

echo "==> report sync: an oversized entries file truncates at a section boundary"
{
    i=1
    while [ "$i" -le 500 ]; do
        printf '### #%d — noise: filler entry\n<!-- triage-entry:%d -->\n- Evidence: %s\n- Suggested action: none\n\n' \
            "$i" "$i" "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        i=$((i + 1))
    done
} >"$tmp/huge.md"
[ "$(run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$tmp/huge.md")" = 0 ] ||
    fail "oversized sync failed: $(head -3 "$tmp/out")"
body_len="$(sed -n '/^DRY-RUN body follows:$/,$p' "$tmp/out" | tail -n +2 | wc -c)"
[ "$body_len" -lt 65536 ] || fail "body must stay under 65536 (got $body_len)"
grep -q "## Report truncated" "$tmp/out" || fail "truncation must be announced"
{
    printf '## Giant section\n\n'
    i=1
    while [ "$i" -le 700 ]; do
        printf -- '- %s\n' \
            "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"
        i=$((i + 1))
    done
} >"$tmp/giant.md"
[ "$(run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$tmp/giant.md")" = 0 ] ||
    fail "giant-section sync failed: $(head -3 "$tmp/out")"
body_len="$(sed -n '/^DRY-RUN body follows:$/,$p' "$tmp/out" | tail -n +2 | wc -c)"
[ "$body_len" -lt 65536 ] ||
    fail "one giant section must still respect the cap (got $body_len)"

echo "==> report sync: a mismatched --repo is refused when the run is bound"
[ "$(run env TRIAGE_REPO="$repo" "$report" sync --repo other/elsewhere \
    --entries-file "$entries")" = 4 ] || fail "unbound repo sync must exit 4"

echo "==> report sync: an entries file outside the bound scratch is refused"
mkdir -p "$tmp/scratch"
[ "$(run env TRIAGE_SCRATCH="$tmp/scratch" "$report" sync --repo "$repo" \
    --entries-file "$entries")" = 4 ] ||
    fail "entries outside scratch must exit 4"
cp "$entries" "$tmp/scratch/entries.md"
[ "$(run env TRIAGE_SCRATCH="$tmp/scratch" "$report" sync --repo "$repo" \
    --entries-file "$tmp/scratch/entries.md")" = 0 ] ||
    fail "entries inside scratch must pass: $(cat "$tmp/out")"

echo "==> report sync: an unchanged report body skips the edit (timestamp aside)"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "body": "$marker", "author": {"login": "testowner"}}]
JSON
run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$entries" >/dev/null
sed -n '/^DRY-RUN body follows:$/,$p' "$tmp/out" | tail -n +2 >"$tmp/livebody"
jq -n --rawfile b "$tmp/livebody" '{"labels": [], "body": $b}' \
    >"$stub_dir/issue-99.json"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 TRIAGE_NOW=2026-02-02 "$report" sync \
    --repo "$repo" --entries-file "$entries" --execute)" = 0 ] ||
    fail "unchanged sync failed: $(cat "$tmp/out")"
grep -q "skipping edit" "$tmp/out" || fail "unchanged body must skip the edit"
grep -q "issue edit" "$GH_STUB_LOG" && fail "unchanged body must not edit"

# ── scan ─────────────────────────────────────────────────────────────────────
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "title": "Triage report", "body": "$marker",
  "author": {"login": "testowner"},
  "labels": [], "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z", "assignees": []},
 {"number": 23, "title": "Typed but one axis missing",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 20, "title": "gauntlet: something is broken in the gate",
  "labels": [{"name": "claim:claude"}, {"name": "needs-triage"}],
  "createdAt": "2020-01-01T00:00:00Z", "updatedAt": "2020-01-02T00:00:00Z",
  "assignees": [{"login": "someone"}], "body": ""},
 {"number": 21, "title": "Short title",
  "labels": [{"name": "bug"}, {"name": "domain:auth"},
             {"name": "domain:delivery"}, {"name": "area:ci"},
             {"name": "layer:ui"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 22, "title": "Fully classified and quiet",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 24, "title": "Carries a retired area value",
  "labels": [{"name": "bug"}, {"name": "area:legacy"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 25, "title": "Recognized and stray area values together",
  "labels": [{"name": "bug"}, {"name": "needs-triage"}, {"name": "area:ci"},
             {"name": "area:legacy"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 27, "title": "Stray beside recognized, queue label lost",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "area:legacy"},
             {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 26, "title": "Axes done, classified only by native Type",
  "labels": [{"name": "needs-triage"}, {"name": "area:ci"},
             {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 28, "title": "Legacy label, no native Type, axes done",
  "labels": [{"name": "bug"}, {"name": "needs-triage"}, {"name": "area:ci"},
             {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""}]
JSON
cat >"$stub_dir/issues-closed.json" <<'JSON'
[{"number": 40, "title": "done but unticked", "stateReason": "COMPLETED",
  "closedAt": "2026-01-01T00:00:00Z", "labels": [],
  "body": "- [x] one\n- [ ] two\n- [ ] three"},
 {"number": 41, "title": "dup close", "stateReason": "DUPLICATE",
  "closedAt": "2026-01-01T00:00:00Z", "labels": [], "body": "closed as dup"},
 {"number": 42, "title": "clean close", "stateReason": "COMPLETED",
  "closedAt": "2026-01-01T00:00:00Z", "labels": [], "body": "- [x] all done"},
 {"number": 43, "title": "other GFM forms", "stateReason": "COMPLETED",
  "closedAt": "2026-01-01T00:00:00Z", "labels": [],
  "body": "1. [ ] ordered\n> - [ ] quoted\n-  [ ] wide gap"}]
JSON

echo "==> scan: emits facts, flags, and excludes the report issue"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "scan failed: $(cat "$tmp/out")"
scan_out="$tmp/scan.json"
cp "$tmp/out" "$scan_out"
jq -e '.report_issue == 99' "$scan_out" >/dev/null || fail "report_issue"
jq -e '[.open[].number] | index(99) == null' "$scan_out" >/dev/null ||
    fail "report issue must be excluded from open"
jq -e '[.closed_flagged[].number] | index(99) == null' "$scan_out" \
    >/dev/null || fail "report issue must be excluded from closed"
jq -e '.open[] | select(.number == 20) | .flags | index("stale-claim-candidate")' \
    "$scan_out" >/dev/null || fail "stale claim flag missing"
jq -e '.open[] | select(.number == 20) | .flags | index("title-prefixed")' \
    "$scan_out" >/dev/null || fail "title-prefixed flag missing"
jq -e '.open[] | select(.number == 21) | .axis_state.domain == "conflict"' \
    "$scan_out" >/dev/null || fail "domain conflict missing"
jq -e '.open[] | select(.number == 21) | .flags | index("axis-conflict:domain")' \
    "$scan_out" >/dev/null || fail "axis-conflict flag missing"
jq -e '[.open[].number] | index(22) == null' "$scan_out" >/dev/null ||
    fail "quiet issue must be filtered without --all"
jq -e '.closed_flagged | length == 3' "$scan_out" >/dev/null ||
    fail "expected exactly three flagged closed issues"
jq -e '.closed_flagged[] | select(.number == 43) | .unticked_criteria == 3' \
    "$scan_out" >/dev/null ||
    fail "ordered/quoted/wide-gap GFM checkboxes must all count"
jq -e '.closed_flagged[] | select(.number == 40) | .unticked_criteria == 2' \
    "$scan_out" >/dev/null || fail "unticked count wrong"
jq -e '.work_type_values | sort == ["bug", "feature"]' "$scan_out" \
    >/dev/null || fail "work_type_values wrong"

echo "==> scan: axes are emitted and axis maps follow them"
jq -e '.axes | sort == ["area", "domain", "layer"]' "$scan_out" >/dev/null ||
    fail "scan must emit the active axes"
jq -e '.open[] | select(.number == 23) | .axis_state
       | keys | sort == ["area", "domain", "layer"]' "$scan_out" >/dev/null ||
    fail "axis_state must be keyed by the active axes"

echo "==> scan: an unrecognized axis value reads unknown, never classified"
jq -e '.open[] | select(.number == 24) | .axis_state.area == "unknown"' \
    "$scan_out" >/dev/null || fail "area:legacy must read unknown"
jq -e '.open[] | select(.number == 24) | .flags
       | index("axis-unknown-value:area")' "$scan_out" >/dev/null ||
    fail "axis-unknown-value flag missing"
jq -e '.open[] | select(.number == 24) | .flags
       | index("axis-missing:area") == null' "$scan_out" >/dev/null ||
    fail "an unknown value is not a bare missing axis"
jq -e '.open[] | select(.number == 24) | .flags
       | index("missing-needs-triage")' "$scan_out" >/dev/null ||
    fail "an unknown value must requeue needs-triage"
jq -e '.open[] | select(.number == 24)
       | .unknown_labels.area == ["area:legacy"]' "$scan_out" >/dev/null ||
    fail "the scan must name the unknown label"
jq -e '.open[] | select(.number == 23) | .unknown_labels == {}' \
    "$scan_out" >/dev/null ||
    fail "unknown_labels must be empty where every value is recognized"

echo "==> axes: a possibly-truncated live label fetch refuses fallback"
cp "$stub_dir/labels.json" "$tmp/labels-small.json"
jq '[range(1000)] | map({name: ("bulk-\(.)"), description: ""})' -n \
    >"$stub_dir/labels.json"
[ "$(run "$apply" axes --repo "$repo" --manifest "$tmp/nope.json")" = 2 ] ||
    fail "a 1000-label page must refuse fallback derivation"
cp "$tmp/labels-small.json" "$stub_dir/labels.json"
jq -e '.open[] | select(.number == 27)
       | (.axis_state.area == "ok")
         and (.flags | index("missing-needs-triage") != null)' \
    "$scan_out" >/dev/null ||
    fail "a stray label beside a recognized value must still requeue"

echo "==> scan: an unknown value beside a recognized one still flags"
jq -e '.open[] | select(.number == 25) | .axis_state.area == "ok"
       and (.flags | index("axis-unknown-value:area") != null)' \
    "$scan_out" >/dev/null ||
    fail "area:ci beside area:legacy must read ok AND flag the stray label"
jq -e '.open[] | select(.number == 25)
       | (.flags | index("needs-triage-removable") == null)
         and (.flags | index("partially-classified") != null)' \
    "$scan_out" >/dev/null ||
    fail "a stray label blocks removal, so the scan must not badge removable"

echo "==> scan: a bare missing axis does not re-add needs-triage"
jq -e '.open[] | select(.number == 23)
       | (.flags | index("axis-missing:area") != null)
         and (.flags | index("missing-needs-triage") == null)' \
    "$scan_out" >/dev/null ||
    fail "typed issue missing one axis must not be needs-triage-worthy"
jq -e '.open[] | select(.number == 21) | .flags | index("missing-needs-triage")' \
    "$scan_out" >/dev/null || fail "a conflicted axis must still re-add"

echo "==> scan: org repos never re-add needs-triage for a missing work-type label"
GH_STUB_OWNER_TYPE="Organization"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "org scan failed: $(cat "$tmp/out")"
jq -e '[.open[] | select(.work_type == []) | .flags[]]
       | index("missing-needs-triage") == null' "$tmp/out" >/dev/null ||
    fail "org repo must not flag missing-needs-triage on empty work-type"

echo "==> scan: org issues with a legacy work-type label stay visible"
jq -e '.open[] | select(.number == 23)
       | .flags | index("legacy-work-type-label")' "$tmp/out" >/dev/null ||
    fail "org issue with a work-type label must carry legacy-work-type-label"
jq -e '.native_type_mode == "per-issue"' "$tmp/out" >/dev/null ||
    fail "an old gh must report per-issue native-Type mode"

echo "==> scan: bulk native Type quiets natively-typed org issues"
# The bulk read rides in the same list request as the issues (one snapshot,
# no join), so the fixture is the open list plus issueType per issue.
jq 'map(.issueType = (if .number == 23 or .number == 26
                      then {name: "Bug"} else null end))' \
    "$stub_dir/issues-open.json" >"$stub_dir/issues-open-types.json"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "org bulk scan failed: $(cat "$tmp/out")"
jq -e '.native_type_mode == "bulk"' "$tmp/out" >/dev/null ||
    fail "bulk-capable gh must report bulk mode"
jq -e '.open[] | select(.number == 23) | .native_type == "Bug"' \
    "$tmp/out" >/dev/null || fail "native_type must carry the bulk-read Type"
jq -e '.open[] | select(.number == 23) | .flags
       | index("legacy-work-type-label") == null' "$tmp/out" >/dev/null ||
    fail "a natively-typed issue must not read as legacy-labeled"
jq -e '.open[] | select(.number == 24) | .native_type == "none"
       and (.flags | index("legacy-work-type-label") != null)' \
    "$tmp/out" >/dev/null ||
    fail "an untyped org issue with a work-type label stays flagged"
jq -e '.open[] | select(.number == 26)
       | (.flags | index("needs-triage-removable") != null)
         and (.flags | index("partially-classified") == null)' \
    "$tmp/out" >/dev/null ||
    fail "a natively-typed issue with finished axes must read removable"
jq -e '.open[] | select(.number == 28)
       | (.flags | index("needs-triage-removable") == null)
         and (.flags | index("partially-classified") != null)' \
    "$tmp/out" >/dev/null ||
    fail "a legacy label without a native Type must not read removable on an org"
jq -e '.open[] | select(.number == 22) | .flags
       | index("missing-needs-triage")' "$tmp/out" >/dev/null ||
    fail "a bulk-proven untyped org issue must requeue needs-triage"
rm "$stub_dir/issues-open-types.json"
GH_STUB_OWNER_TYPE="User"

echo "==> scan: a mismatched --repo is refused when the run is bound"
[ "$(run env TRIAGE_REPO="$repo" "$scan" --repo other/elsewhere \
    --manifest "$manifest")" = 4 ] || fail "unbound scan must exit 4"

echo "==> scan: an incomplete needs-triage issue is flagged partially-classified"
jq -e '.open[] | select(.number == 20) | .flags | index("partially-classified")' \
    "$scan_out" >/dev/null || fail "partially-classified flag missing on #20"
jq -e '.open[] | select(.number == 23)
       | .flags | index("partially-classified") == null' \
    "$scan_out" >/dev/null ||
    fail "an issue without needs-triage is not partially-classified"

echo "==> scan: --out writes the file itself and refuses paths outside scratch"
mkdir -p "$tmp/scanscratch"
[ "$(run env TRIAGE_SCRATCH="$tmp/scanscratch" "$scan" --repo "$repo" \
    --manifest "$manifest" --out "$tmp/outside.json")" = 4 ] ||
    fail "out path outside scratch must exit 4"
[ "$(run env TRIAGE_SCRATCH="$tmp/scanscratch" "$scan" --repo "$repo" \
    --manifest "$manifest" --out "$tmp/scanscratch/scan.json")" = 0 ] ||
    fail "out inside scratch must pass: $(cat "$tmp/out")"
jq -e '.repo == "testowner/testrepo"' "$tmp/scanscratch/scan.json" \
    >/dev/null || fail "--out file must carry the scan"

echo "==> scan: reports truncation when a page fills its window"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest" --limit 5)" = 0 ] ||
    fail "truncation scan failed"
jq -e '.truncated_open == true' "$tmp/out" >/dev/null ||
    fail "a full page must set truncated_open"
jq -e '.truncated_open == false and .truncated_closed == false' "$scan_out" \
    >/dev/null || fail "an unfilled page must not read as truncated"

echo "==> scan: --all includes the quiet issue"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest" --all)" = 0 ] ||
    fail "scan --all failed"
jq -e '[.open[].number] | index(22) != null' "$tmp/out" >/dev/null ||
    fail "--all must include the quiet issue"

# ── wrapper ──────────────────────────────────────────────────────────────────
export GH_STUB_REPO="$repo"

echo "==> wrapper: dry-run forces TRIAGE_EXECUTE=0 and a DRY-RUN prompt"
: >"$GH_STUB_LOG"
[ "$(run "$wrapper")" = 0 ] || fail "wrapper dry-run failed: $(cat "$tmp/out")"
grep -q "TRIAGE_EXECUTE=0" "$GH_STUB_LOG" || fail "env gate not forced to 0"
grep -q "TRIAGE_REPO=$repo" "$GH_STUB_LOG" || fail "run must be repo-bound"
grep -q "DRY-RUN" "$GH_STUB_LOG" || fail "prompt must state DRY-RUN"
grep -q -- "--model haiku" "$GH_STUB_LOG" || fail "default model must be haiku"
grep -q -- "--setting-sources" "$GH_STUB_LOG" ||
    fail "worker must run with settings isolated"
grep -q "TRIAGE_SCRATCH=/" "$GH_STUB_LOG" || fail "run must bind a scratch dir"
grep -q -- "Write(//" "$GH_STUB_LOG" ||
    fail "worker Write grant must be scratch-scoped"
grep -q -- "Read(//" "$GH_STUB_LOG" ||
    fail "worker Read grant must be path-scoped"
grep -qE "ARGS: .*(Glob|Grep)" "$GH_STUB_LOG" &&
    fail "worker must not be granted Glob/Grep"
grep -q -- "--tools Read,Write,Bash" "$GH_STUB_LOG" ||
    fail "worker must run with a restricted built-in tool set"

echo "==> wrapper: --execute without a terminal is refused"
[ "$(run "$wrapper" --execute)" = 2 ] ||
    fail "non-interactive --execute must exit 2"

echo "All triage skill tests passed."
