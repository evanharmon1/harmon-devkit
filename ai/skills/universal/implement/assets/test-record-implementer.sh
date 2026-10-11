#!/usr/bin/env bash
# test-record-implementer.sh — offline tests for record-implementer.sh against a
# stubbed `gh`: registry validation refuses unknown values, the four values land
# as labels on the pull request on every owner type and as labels or issue
# fields on the issue by owner type, a second implementer replaces the first on
# the issue while each pull request keeps its own record, `claim:*` is never
# touched, and `check` gates promotion on a complete, valid record.
set -euo pipefail

asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
script="$asset_dir/record-implementer.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

pass_count=0
ok() {
    pass_count=$((pass_count + 1))
    return 0
}

registry="$tmp/agent-registry.json"
cat >"$registry" <<'EOF'
{
  "effort_ladder": ["minimal", "low", "medium", "high", "xhigh", "max"],
  "families": [
    {"slug": "claude", "models": [
      {"slug": "opus", "versions": [{"slug": "5.5", "retired": false}]},
      {"slug": "sonnet", "versions": [{"slug": "5.5", "retired": false}]}]},
    {"slug": "gpt", "models": [
      {"slug": "sol", "versions": [{"slug": "6.1", "retired": false}]}]},
    {"slug": "gemini", "models": [
      {"slug": "flash", "versions": [{"slug": "3.8", "retired": false},
                                      {"slug": "3.7", "retired": true}]}]}
  ],
  "harnesses": [
    {"slug": "claude-code", "family_constraint": {"kind": "fixed", "family": "claude"},
     "efforts": ["low", "medium", "high", "xhigh", "max"]},
    {"slug": "codex-cli", "family_constraint": {"kind": "fixed", "family": "gpt"},
     "efforts": ["minimal", "low", "medium", "high", "xhigh"]},
    {"slug": "antigravity", "family_constraint": {"kind": "fixed", "family": "gemini"},
     "efforts": []},
    {"slug": "opencode", "family_constraint": {"kind": "broker"},
     "efforts": ["low", "medium", "high"]}
  ]
}
EOF

# The stub keeps per-repository state under $GH_STATE: owner type, provisioned
# labels, one label file per issue or pull request, and one issue-field JSON
# object per organization issue. It answers the exact calls the script makes,
# applying --jq with the real jq so filters are exercised as written.
stub="$tmp/bin"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state="$GH_STATE"
printf '%s\n' "$*" >>"$state/calls"
[ "${1:-}" = api ] || exit 1
shift
method=GET jqf="" input=0 path="" fields=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --paginate) shift ;;
    --method | -X) method="$2"; shift 2 ;;
    --jq | -q) jqf="$2"; shift 2 ;;
    --input) input=1; shift 2 ;;
    -H) shift 2 ;;
    -f | -F) fields+=("$2"); shift 2 ;;
    *) path="$1"; shift ;;
    esac
done
out() {
    if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi
}
field() {
    local kv
    for kv in "${fields[@]}"; do
        case "$kv" in "$1="*) printf '%s\n' "${kv#*=}" ;; esac
    done
}
path="${path%%\?*}"
case "$path" in
graphql)
    query="$(field query)"
    n="$(field n)"
    if [ "$input" -eq 1 ]; then
        [ ! -e "$state/fail-mutation" ] || exit 1
        body="$(cat)"
        issue="$(jq -r '.variables.issue' <<<"$body")"
        n="${issue#ISSUE_}"
        f="$state/fields-$n.json"
        [ -e "$f" ] || echo '{}' >"$f"
        jq --argjson b "$body" --slurpfile cat "$state/catalogue.json" '
          reduce $b.variables.fields[] as $w (.;
            ($cat[0][] | select(.id == $w.fieldId)) as $field
            | if ($w.delete // false) then del(.[$field.name])
              else .[$field.name] = ($field.options[] | select(.id == $w.singleSelectOptionId) | .name)
              end)
        ' "$f" >"$f.new" && mv "$f.new" "$f"
        echo '{"data":{}}'
    elif grep -q issueFieldValues <<<"$query"; then
        f="$state/fields-$n.json"
        [ -e "$f" ] || echo '{}' >"$f"
        jq '{data: {repository: {issue: {issueFieldValues: {nodes:
              [to_entries[] | {name: .value, field: {name: .key}}]}}}}}' "$f" | out
    else
        jq --arg id "ISSUE_$n" '{data: {repository: {issue: {id: $id},
              issueFields: {pageInfo: {hasNextPage: false}, nodes: .}}}}' \
            "$state/catalogue.json" | out
    fi
    ;;
repos/*/*/issues/*/labels)
    n="${path#repos/*/*/issues/}"
    n="${n%/labels}"
    f="$state/labels-$n"
    if [ "$method" = GET ] && [ -e "$state/fail-read-$n" ]; then
        echo 'gh: Server Error (HTTP 502)' >&2
        exit 1
    fi
    touch "$f"
    if [ "$method" = POST ]; then
        [ ! -e "$state/fail-add" ] || exit 1
        jq -r '.labels[]' | cat "$f" - | awk '!seen[$0]++' >"$f.new" && mv "$f.new" "$f"
        echo '[]'
    else
        jq -Rn '[inputs | {name: .}]' "$f" | out
    fi
    ;;
repos/*/*/issues/*/labels/*)
    [ "$method" = DELETE ] || exit 1
    n="${path#repos/*/*/issues/}"
    name="$(printf '%s' "${n#*/labels/}" | sed 's/%3A/:/g')"
    n="${n%%/*}"
    f="$state/labels-$n"
    grep -vxF -- "$name" "$f" >"$f.new" || true
    mv "$f.new" "$f"
    ;;
repos/*/*/labels/*)
    name="$(printf '%s' "${path#repos/*/*/labels/}" | sed 's/%3A/:/g')"
    grep -qxF -- "$name" "$state/provisioned" || { echo 'HTTP 404' >&2; exit 1; }
    jq -n --arg n "$name" '{name: $n}' | out
    ;;
repos/*/*)
    jq -n --arg t "$(cat "$state/owner")" '{owner: {type: $t}}' | out
    ;;
*) exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

provision() {
    {
        for f in claude gpt gemini; do echo "model-family:$f"; done
        for m in opus sonnet sol flash; do echo "model:$m"; done
        for v in 5.5 6.1 3.8 3.7; do echo "model-version:$v"; done
        for e in minimal low medium high xhigh max; do echo "model-effort:$e"; done
        echo claim:claude
    } >"$GH_STATE/provisioned"
    jq -n '
      def opts($xs): [$xs[] as $x | {id: "OPT_\($x)", name: $x}];
      [{id: "F_family", name: "Model family", options: opts(["claude","gpt","gemini"])},
       {id: "F_model", name: "Model", options: opts(["opus","sonnet","sol","flash"])},
       {id: "F_version", name: "Model version", options: opts(["5.5","6.1","3.8","3.7"])},
       {id: "F_effort", name: "Model effort", options: opts(["minimal","low","medium","high","xhigh","max"])}]
    ' >"$GH_STATE/catalogue.json"
}

new_state() {
    GH_STATE="$tmp/state-$1"
    rm -rf "$GH_STATE"
    mkdir -p "$GH_STATE"
    printf '%s\n' "$2" >"$GH_STATE/owner"
    : >"$GH_STATE/calls"
    export GH_STATE
    provision
}

run() {
    PATH="$stub:$PATH" "$script" "$@"
}

expect_refused() {
    local label="$1" pattern="$2" rc=0 err
    shift 2
    err="$(run "$@" 2>&1 >/dev/null)" || rc=$?
    [ "$rc" -eq 1 ] || fail "$label: expected exit 1, got $rc ($err)"
    grep -qF -- "$pattern" <<<"$err" || fail "$label: expected '$pattern' in: $err"
    ok
}

labels_of() {
    LC_ALL=C sort "$GH_STATE/labels-$1" 2>/dev/null | paste -sd ' ' -
}

claude_opus=(--harness claude-code --family claude --model opus --version 5.5 --effort medium)
gpt_sol=(--harness codex-cli --family gpt --model sol --version 6.1 --effort high)

# --- validate -----------------------------------------------------------------
out="$(run validate --registry "$registry" "${claude_opus[@]}")" || fail "valid tuple refused"
[ "$out" = "$(printf 'model-family:claude\nmodel:opus\nmodel-version:5.5\nmodel-effort:medium')" ] ||
    fail "validate printed: $out"
ok
run validate --registry "$registry" --harness opencode --family gpt --model sol \
    --version 6.1 --effort low >/dev/null || fail "a broker harness must admit any family"
ok

v=(validate --registry "$registry")
expect_refused "unknown family" 'model family "mistral"' "${v[@]}" --harness opencode \
    --family mistral --model opus --version 5.5 --effort low
expect_refused "line of another family" 'model line "sol" is not a line of family "claude"' \
    "${v[@]}" --harness claude-code --family claude --model sol --version 6.1 --effort low
expect_refused "unknown version" 'model version "9.9"' "${v[@]}" --harness claude-code \
    --family claude --model opus --version 9.9 --effort low
expect_refused "retired version" 'is retired' "${v[@]}" --harness opencode --family gemini \
    --model flash --version 3.7 --effort low
expect_refused "fixed harness family" 'runs only family "claude"' "${v[@]}" \
    --harness claude-code --family gpt --model sol --version 6.1 --effort low
expect_refused "unknown harness" 'harness "nope"' "${v[@]}" --harness nope --family claude \
    --model opus --version 5.5 --effort low
expect_refused "undeclared effort" 'effort "minimal" is not one harness "claude-code" declares' \
    "${v[@]}" --harness claude-code --family claude --model opus --version 5.5 --effort minimal

# A harness that declares no efforts records the other three values and no
# effort, saying why (maintainer ruling on #1269, 2026-10-11).
err="$(run validate --registry "$registry" --harness antigravity --family gemini --model flash \
    --version 3.8 2>&1 >"$tmp/validate.out")" || fail "an efforts-free harness must validate: $err"
[ "$(cat "$tmp/validate.out")" = "$(printf 'model-family:gemini\nmodel:flash\nmodel-version:3.8')" ] ||
    fail "an efforts-free harness must record no effort: $(cat "$tmp/validate.out")"
grep -qF 'model-effort not recorded: harness antigravity declares no verified efforts' <<<"$err" ||
    fail "the omitted effort must be explained: $err"
ok
expect_refused "retired version on an efforts-free harness" 'is retired' "${v[@]}" \
    --harness antigravity --family gemini --model flash --version 3.7
rc=0
run validate --registry "$registry" --harness claude-code --family claude --model opus \
    --version 5.5 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a harness that declares efforts must still require one (exit 2), got $rc"
ok

rc=0
run validate --registry "$tmp/missing.json" "${claude_opus[@]}" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "an unreadable registry must be indeterminate (exit 2), got $rc"
ok

# --- personal account: PR and issue labels, last implementer wins -------------
new_state personal User
printf 'claim:claude\nbug\n' >"$GH_STATE/labels-7"
run apply --repo me/proj --pr 10 --issue 7 --registry "$registry" "${claude_opus[@]}" >/dev/null ||
    fail "personal apply failed"
[ "$(labels_of 10)" = "model-effort:medium model-family:claude model-version:5.5 model:opus" ] ||
    fail "personal PR labels: $(labels_of 10)"
[ "$(labels_of 7)" = "bug claim:claude model-effort:medium model-family:claude model-version:5.5 model:opus" ] ||
    fail "personal issue labels: $(labels_of 7)"
ok

# A second implementer opens its own PR for the same issue: the issue's values
# are replaced; the first PR keeps its record; claim:* stays.
run apply --repo me/proj --pr 11 --issue 7 --registry "$registry" "${gpt_sol[@]}" >/dev/null ||
    fail "second personal apply failed"
[ "$(labels_of 7)" = "bug claim:claude model-effort:high model-family:gpt model-version:6.1 model:sol" ] ||
    fail "second implementer did not replace the first on the issue: $(labels_of 7)"
[ "$(labels_of 10)" = "model-effort:medium model-family:claude model-version:5.5 model:opus" ] ||
    fail "the first PR lost its record: $(labels_of 10)"
[ "$(labels_of 11)" = "model-effort:high model-family:gpt model-version:6.1 model:sol" ] ||
    fail "second PR labels: $(labels_of 11)"
! grep -q 'labels/claim' "$GH_STATE/calls" || fail "a claim label was touched"
ok

# A third implementer on a harness that declares no efforts: three values
# replace the second's, and its effort is cleared rather than left behind.
run apply --repo me/proj --pr 12 --issue 7 --registry "$registry" --harness antigravity \
    --family gemini --model flash --version 3.8 >/dev/null 2>"$tmp/apply.err" ||
    fail "an efforts-free personal apply failed: $(cat "$tmp/apply.err")"
grep -qF 'model-effort not recorded' "$tmp/apply.err" || fail "the omitted effort must be explained"
[ "$(labels_of 7)" = "bug claim:claude model-family:gemini model-version:3.8 model:flash" ] ||
    fail "an efforts-free implementer must clear the earlier effort on the issue: $(labels_of 7)"
[ "$(labels_of 12)" = "model-family:gemini model-version:3.8 model:flash" ] ||
    fail "an efforts-free PR must carry three labels: $(labels_of 12)"
ok

# A refused tuple writes nothing.
before="$(wc -l <"$GH_STATE/calls")"
expect_refused "apply refuses before writing" 'is retired' apply --repo me/proj \
    --pr 14 --issue 7 --registry "$registry" --harness antigravity --family gemini \
    --model flash --version 3.7
[ "$(wc -l <"$GH_STATE/calls")" -eq "$before" ] || fail "a refused tuple reached GitHub"
ok

# A failed read of the personal-account issue's labels stops before any write:
# the pull request is left unchanged.
: >"$GH_STATE/fail-read-7"
rc=0
run apply --repo me/proj --pr 15 --issue 7 --registry "$registry" "${claude_opus[@]}" \
    >/dev/null 2>"$tmp/apply.err" || rc=$?
[ "$rc" -eq 2 ] || fail "a failed issue-label read must be indeterminate (exit 2), got $rc: $(cat "$tmp/apply.err")"
grep -qF 'could not read the labels of me/proj#7' "$tmp/apply.err" ||
    fail "the failed read must be named: $(cat "$tmp/apply.err")"
! grep -E -- '--method (POST|DELETE) repos/me/proj/issues/15/' "$GH_STATE/calls" >/dev/null ||
    fail "PR 15 was written before the issue-label read failed"
[ ! -s "$GH_STATE/labels-15" ] || fail "PR 15 carries labels after a failed preflight: $(labels_of 15)"
rm "$GH_STATE/fail-read-7"
ok

# An unprovisioned label is refused rather than created by the add endpoint.
grep -vxF 'model-version:6.1' "$GH_STATE/provisioned" >"$GH_STATE/p" && mv "$GH_STATE/p" "$GH_STATE/provisioned"
expect_refused "unprovisioned label" "label 'model-version:6.1' is not provisioned" apply \
    --repo me/proj --pr 13 --registry "$registry" "${gpt_sol[@]}"
[ ! -e "$GH_STATE/labels-13" ] || fail "an unprovisioned label was written"
ok

# --- organization: PR labels, issue fields, last implementer wins -------------
new_state org Organization
printf 'claim:claude\n' >"$GH_STATE/labels-7"
run apply --repo org/proj --pr 20 --issue 7 --registry "$registry" "${claude_opus[@]}" >/dev/null ||
    fail "organization apply failed"
[ "$(labels_of 20)" = "model-effort:medium model-family:claude model-version:5.5 model:opus" ] ||
    fail "organization PR labels: $(labels_of 20)"
[ "$(labels_of 7)" = "claim:claude" ] || fail "an organization issue must not get labels: $(labels_of 7)"
jq -e '. == {"Model family":"claude","Model":"opus","Model version":"5.5","Model effort":"medium"}' \
    "$GH_STATE/fields-7.json" >/dev/null || fail "organization issue fields: $(cat "$GH_STATE/fields-7.json")"
ok
run apply --repo org/proj --pr 21 --issue 7 --registry "$registry" "${gpt_sol[@]}" >/dev/null ||
    fail "second organization apply failed"
jq -e '. == {"Model family":"gpt","Model":"sol","Model version":"6.1","Model effort":"high"}' \
    "$GH_STATE/fields-7.json" >/dev/null || fail "second implementer did not replace the fields: $(cat "$GH_STATE/fields-7.json")"
[ "$(labels_of 20)" = "model-effort:medium model-family:claude model-version:5.5 model:opus" ] ||
    fail "the first organization PR lost its record: $(labels_of 20)"
ok

# An efforts-free implementer on an organization issue records three fields
# and deletes the earlier Model effort value.
run apply --repo org/proj --pr 23 --issue 7 --registry "$registry" --harness antigravity \
    --family gemini --model flash --version 3.8 >/dev/null 2>&1 ||
    fail "an efforts-free organization apply failed"
jq -e '. == {"Model family":"gemini","Model":"flash","Model version":"3.8"}' \
    "$GH_STATE/fields-7.json" >/dev/null || fail "the earlier Model effort was not cleared: $(cat "$GH_STATE/fields-7.json")"
[ "$(labels_of 23)" = "model-family:gemini model-version:3.8 model:flash" ] ||
    fail "efforts-free organization PR labels: $(labels_of 23)"
ok

# A missing option refuses before the mutation.
jq 'map(if .name == "Model version" then .options |= map(select(.name != "6.1")) else . end)' \
    "$GH_STATE/catalogue.json" >"$GH_STATE/c" && mv "$GH_STATE/c" "$GH_STATE/catalogue.json"
expect_refused "missing field option" 'has no option "6.1"' apply --repo org/proj --pr 22 \
    --issue 8 --registry "$registry" "${gpt_sol[@]}"
[ ! -e "$GH_STATE/fields-8.json" ] || fail "a field write ran despite a missing option"
# The issue preflight runs before the first write, so the pull request is
# untouched too: no label POST or DELETE for it.
! grep -E -- '--method (POST|DELETE) repos/org/proj/issues/22/' "$GH_STATE/calls" >/dev/null ||
    fail "PR 22 was written before the issue preflight refused"
[ ! -s "$GH_STATE/labels-22" ] || fail "PR 22 carries labels after a refused apply: $(labels_of 22)"
ok

# --- check --------------------------------------------------------------------
run check --repo org/proj --pr 21 --registry "$registry" --harness codex-cli >/dev/null ||
    fail "check refused a valid record"
run check --repo org/proj --pr 21 --registry "$registry" >/dev/null ||
    fail "check without --harness refused a valid record"
ok
printf 'model-family:gpt\nmodel:sol\nmodel-version:6.1\nmodel-effort:turbo\n' >"$GH_STATE/labels-33"
expect_refused "check: effort that no longer exists" 'effort "turbo" is not on the registry effort_ladder' \
    check --repo org/proj --pr 33 --registry "$registry" --harness opencode
expect_refused "check: unknown harness" 'harness "nope" is not in the agent registry' check \
    --repo org/proj --pr 21 --registry "$registry" --harness nope
printf 'model-family:claude\nmodel:opus\nmodel-version:5.5\n' >"$GH_STATE/labels-30"
run check --repo org/proj --pr 30 --registry "$registry" >/dev/null ||
    fail "check without --harness must accept a record with no effort (an efforts-free harness writes none)"
ok
printf 'model-family:claude\nmodel:opus\nmodel-version:5.5\nmodel-effort:low\nmodel-effort:high\n' >"$GH_STATE/labels-36"
expect_refused "check: two efforts" 'carries 2 model-effort labels' check --repo org/proj \
    --pr 36 --registry "$registry"
printf 'model-family:claude\nmodel-family:gpt\nmodel:opus\nmodel-version:5.5\nmodel-effort:low\n' >"$GH_STATE/labels-31"
expect_refused "check: two families" 'carries 2 model-family labels' check --repo org/proj \
    --pr 31 --registry "$registry"
# Promotion is existence-only: a version retired since the draft passes, a
# value that no longer exists blocks.
printf 'model-family:gemini\nmodel:flash\nmodel-version:3.7\nmodel-effort:low\n' >"$GH_STATE/labels-32"
run check --repo org/proj --pr 32 --registry "$registry" --harness opencode >/dev/null ||
    fail "check must pass a version retired since the draft"
ok
printf 'model-family:gemini\nmodel:flash\nmodel-version:3.5\nmodel-effort:low\n' >"$GH_STATE/labels-34"
expect_refused "check: missing version" 'model version "3.5" is not a version of gemini/flash' check \
    --repo org/proj --pr 34 --registry "$registry"
printf 'model-family:gemini\nmodel:pro\nmodel-version:3.8\nmodel-effort:low\n' >"$GH_STATE/labels-35"
expect_refused "check: missing line" 'model line "pro"' check --repo org/proj --pr 35 --registry "$registry"
# No effort label: passes for an efforts-free harness, blocks for one that
# declares efforts.
run check --repo org/proj --pr 23 --registry "$registry" --harness antigravity >/dev/null ||
    fail "check must pass an efforts-free record for an efforts-free harness"
ok
expect_refused "check: effort owed" 'carries no model-effort label, and harness codex-cli declares efforts' \
    check --repo org/proj --pr 23 --registry "$registry" --harness codex-cli

echo "test-record-implementer: all $pass_count checks passed"
