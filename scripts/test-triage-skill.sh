#!/usr/bin/env bash
# test-triage-skill.sh — unit-test the triage skill's contract scripts. Fully
# offline: every `gh` call goes to a PATH-stubbed gh driven by fixture files,
# and the wrapper's model run goes to a PATH-stubbed claude.
#
# What this keeps honest (issue #455's [CI] criteria):
#   - the write-allowlist is computed from label-registry.json (agent-writable,
#     v1 scope, retired excluded) with the gh-label fallback
#   - the never-list refuses foreman:/rigor:/tier: (including scoped
#     tier:<role>:*)/strategy:/method: (retired, still reserved)/claim:/
#     suggest:/agent:* even when a hostile manifest grants them
#   - native issue Types are org-only, enabled-Type validated, dry-run by
#     default, execute-gated, and can complete needs-triage removal
#   - needs-triage is removed only when classification is complete
#   - --execute is inert without the wrapper-owned TRIAGE_EXECUTE=1 env gate
#   - the rolling report is idempotent, upserts only its marker-carrying
#     issue, and the scan excludes it from triage (self-exclusion)
#   - the classification and priority rubrics exist under references/ and
#     SKILL.md links both
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
    # shell-robustness: ok — always exits, so its status is never read
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
    # Organization issue fields (triage-apply.sh / triage-scan.sh). Fixtures
    # are kept simple and the GraphQL shapes are built here:
    #   issue-fields.json      [{id, name, options: [{id, name}]}] — the
    #                          repository's issue fields (absent: none)
    #   issue-fields-<n>.json  {"<Field name>": "<value>"} — one issue's
    #                          values (absent: none)
    # setIssueFieldValue arrives on stdin (--input -); it is logged to
    # field-mutations.log and applied to issue-fields-<n>.json.
    n=""
    prev=""
    for a in "$@"; do
        [ "$prev" != "-F" ] || case "$a" in n=*) n="${a#n=}" ;; esac
        prev="$a"
    done
    catalogue="[]"
    [ ! -f "${GH_STUB_DIR:?}/issue-fields.json" ] ||
        catalogue="$(cat "$GH_STUB_DIR/issue-fields.json")"
    field_values() {
        if [ -f "$GH_STUB_DIR/issue-fields-$1.json" ]; then
            cat "$GH_STUB_DIR/issue-fields-$1.json"
        else
            echo '{}'
        fi
        return 0
    }
    if grep -q -- '--input' <<<"$*"; then
        [ "${GH_STUB_FIELD_WRITE_FAIL:-0}" = 0 ] || {
            cat >/dev/null
            exit 1
        }
        body="$(cat)"
        printf '%s\n' "$body" >>"$GH_STUB_DIR/field-mutations.log"
        grep -q 'setIssueFieldValue' <<<"$body" || exit 98
        target="$(jq -r '.variables.issue | ltrimstr("I_")' <<<"$body")"
        jq -n --argjson cur "$(field_values "$target")" \
            --argjson cat "$catalogue" --argjson body "$body" '
          reduce $body.variables.fields[] as $w ($cur;
            ([$cat[] | select(.id == $w.fieldId)] | first) as $f
            | . + {($f.name): ([$f.options[]
                                | select(.id == $w.singleSelectOptionId)]
                               | first | .name)})' \
            >"$GH_STUB_DIR/issue-fields-$target.json.next"
        mv "$GH_STUB_DIR/issue-fields-$target.json.next" \
            "$GH_STUB_DIR/issue-fields-$target.json"
        [ "${GH_STUB_FIELDS_UNREADABLE_AFTER_WRITE:-0}" = 0 ] ||
            : >"$GH_STUB_DIR/fields-unreadable"
        echo '{"data":{"setIssueFieldValue":{"clientMutationId":null}}}'
    elif grep -q 'issueFields(first:' <<<"$*"; then
        [ "${GH_STUB_ISSUE_FIELDS:-}" != "ERROR" ] || exit 1
        jq -n --argjson c "$catalogue" '{data: {repository: {issueFields: {
            pageInfo: {hasNextPage: false}, nodes: $c}}}}' >"$GH_STUB_DIR/.gql"
        emit "$GH_STUB_DIR/.gql"
    elif grep -q 'issues(first:' <<<"$*" && grep -q 'issueFieldValues' <<<"$*"; then
        [ "${GH_STUB_OPEN_FIELDS:-}" != "ERROR" ] || exit 1
        # Every open issue is in the pass; its values come from
        # issue-fields-<n>.json (absent: none set).
        nodes="[]"
        for num in $(jq -r '.[].number' "$GH_STUB_DIR/issues-open.json"); do
            nodes="$(jq -c --argjson num "$num" \
                --argjson v "$(field_values "$num")" '
              . + [{number: $num, issueFieldValues: {
                pageInfo: {hasNextPage: false},
                nodes: [$v | to_entries[]
                        | {name: .value, field: {name: .key}}]}}]' \
                <<<"$nodes")"
        done
        jq -n --argjson nodes "$nodes" '{data: {repository: {issues: {
            pageInfo: {hasNextPage: false, endCursor: null},
            nodes: $nodes}}}}'
    elif grep -q 'issueFieldValues(first:' <<<"$*"; then
        [ ! -f "$GH_STUB_DIR/fields-unreadable" ] || exit 1
        [ "${GH_STUB_ISSUE_FIELD_VALUES:-}" != "ERROR" ] || exit 1
        # GH_STUB_FIELDS_CHANGE_ON_READ=K merges GH_STUB_FIELDS_CHANGE_JSON
        # into the issue's values on its K-th read: a person editing a field
        # between triage's first read and its pre-write re-read.
        if [ -n "${GH_STUB_FIELDS_CHANGE_ON_READ:-}" ]; then
            reads="$(cat "$GH_STUB_DIR/.field-reads-$n" 2>/dev/null || echo 0)"
            reads=$((reads + 1))
            echo "$reads" >"$GH_STUB_DIR/.field-reads-$n"
            if [ "$reads" -eq "$GH_STUB_FIELDS_CHANGE_ON_READ" ]; then
                jq -n --argjson cur "$(field_values "$n")" \
                    --argjson chg "${GH_STUB_FIELDS_CHANGE_JSON:?}" '$cur + $chg' \
                    >"$GH_STUB_DIR/issue-fields-$n.json"
            fi
        fi
        jq -n --arg n "${n:?}" --argjson v "$(field_values "$n")" '
          {data: {repository: {issue: {id: "I_\($n)", issueFieldValues: {
            pageInfo: {hasNextPage: false},
            nodes: [$v | to_entries[] | {name: .value, field: {name: .key}}]}}}}}' \
            >"$GH_STUB_DIR/.gql"
        emit "$GH_STUB_DIR/.gql"
    elif grep -q 'issueTypes(first:' <<<"$*"; then
        [ "${GH_STUB_ENABLED_NATIVE_TYPES:-}" = "ERROR" ] && exit 1
        if [ -n "${GH_STUB_ENABLED_NATIVE_TYPES_JSON:-}" ]; then
            printf '%s\n' "$GH_STUB_ENABLED_NATIVE_TYPES_JSON" |
                jq '.data.repository = .data.organization | del(.data.organization)' |
                jq -r "$q"
        else
            printf '%s\n' "${GH_STUB_ENABLED_NATIVE_TYPES:-Bug}"
        fi
    elif grep -q 'closedByPullRequestsReferences' <<<"$*"; then
        # triage-scan.sh delivery's combined issue-state + closing-refs read.
        # The issue number rides in the -F n=<value> arg; fixture file missing
        # simulates a read failure (cat/set -e exits nonzero).
        n=""
        prev=""
        for a in "$@"; do
            [ "$prev" != "-F" ] || case "$a" in n=*) n="${a#n=}" ;; esac
            prev="$a"
        done
        emit "${GH_STUB_DIR:?}/delivery-${n:?}.json"
    else
        [ "${GH_STUB_NATIVE_TYPE:-}" = "ERROR" ] && exit 1
        if [ -n "${GH_STUB_NATIVE_TYPE_FILE:-}" ]; then
            [ "$(cat "$GH_STUB_NATIVE_TYPE_FILE")" = "ERROR" ] && exit 1
            native_type="$(cat "$GH_STUB_NATIVE_TYPE_FILE")"
        else
            native_type="${GH_STUB_NATIVE_TYPE:-}"
        fi
        # GH_STUB_NATIVE_TYPE_CHANGE_ON_READ=K: from the K-th Type read on,
        # the Type is GH_STUB_NATIVE_TYPE_CHANGE_TO (a person typing the
        # issue between two of triage's writes).
        if [ -n "${GH_STUB_NATIVE_TYPE_CHANGE_ON_READ:-}" ]; then
            reads="$(cat "${GH_STUB_DIR:?}/.native-reads" 2>/dev/null || echo 0)"
            reads=$((reads + 1))
            echo "$reads" >"$GH_STUB_DIR/.native-reads"
            [ "$reads" -lt "$GH_STUB_NATIVE_TYPE_CHANGE_ON_READ" ] ||
                native_type="${GH_STUB_NATIVE_TYPE_CHANGE_TO:?}"
        fi
        if [ -n "$native_type" ]; then
            printf 'set:%s\n' "$native_type"
        else
            printf '%s\n' unset
        fi
    fi
    ;;
api\ repos/*/pulls/*)
    pr="${2##*/}"
    [ -f "${GH_STUB_DIR:?}/pull-$pr.json" ] || exit 1
    emit "${GH_STUB_DIR:?}/pull-$pr.json"
    ;;
api\ repos/*/issues/*/timeline)
    # triage-scan.sh delivery's bounded one-page timeline read.
    n="${2%/timeline}"
    n="${n##*/}"
    emit "${GH_STUB_DIR:?}/timeline-${n:?}.json"
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
    if grep -q "issueType" <<<"$*"; then
        [ -f "${GH_STUB_DIR:?}/issues-open-types.json" ] || exit 1
        emit "${GH_STUB_DIR:?}/issues-open-types.json"
    else
        emit "${GH_STUB_DIR:?}/issues-${state:?}.json"
    fi
    ;;
"issue view")
    issue_src="${GH_STUB_DIR:?}/issue-${3:?}.json"
    [ -z "${GH_STUB_RUN_ID:-}" ] ||
        [ ! -f "$GH_STUB_DIR/.overlay-$GH_STUB_RUN_ID-$3.json" ] ||
        issue_src="$GH_STUB_DIR/.overlay-$GH_STUB_RUN_ID-$3.json"
    # GH_STUB_LABELS_CHANGE_ON_READ=K adds the labels named in
    # GH_STUB_LABELS_CHANGE_ADD to the issue on its K-th read: a person
    # labelling it between triage's first read and its snapshot.
    if [ -n "${GH_STUB_LABELS_CHANGE_ON_READ:-}" ]; then
        reads="$(cat "$GH_STUB_DIR/.label-reads-$3" 2>/dev/null || echo 0)"
        reads=$((reads + 1))
        echo "$reads" >"$GH_STUB_DIR/.label-reads-$3"
        if [ "$reads" -eq "$GH_STUB_LABELS_CHANGE_ON_READ" ]; then
            jq --arg add "${GH_STUB_LABELS_CHANGE_ADD:?}" \
                '.labels += [$add | split(" ")[] | {name: .}]' \
                "$issue_src" >"$issue_src.next"
            mv "$issue_src.next" "$issue_src"
        fi
    fi
    emit "$issue_src"
    ;;
"repo view") printf '%s\n' "${GH_STUB_REPO:?}" ;;
# Only the body-carrying writes read stdin (--body-file -): drain just there,
# so a stubbed read call inside a caller's while-read loop cannot eat the
# loop's remaining input or hang on a never-closing stdin.
"issue edit")
    if grep -qx 'issue edit --help' <<<"$*"; then
        if [ "${GH_STUB_NO_TYPE_FLAG:-0}" = 0 ]; then
            printf '%s\n' '  --type string   Set the issue type by name'
        fi
        if [ -n "${GH_STUB_TYPE_CHANGES_BEFORE_WRITE:-}" ] &&
            [ -n "${GH_STUB_NATIVE_TYPE_FILE:-}" ]; then
            printf '%s\n' "$GH_STUB_TYPE_CHANGES_BEFORE_WRITE" >"$GH_STUB_NATIVE_TYPE_FILE"
        fi
        exit 0
    fi
    [ -t 0 ] || cat >/dev/null
    [ "${GH_STUB_EDIT_FAIL:-0}" = 0 ] || exit 1
    if [ "${GH_STUB_EDIT_FAIL_ON_REMOVE:-0}" = 1 ] &&
        grep -q -- '--remove-label' <<<"$*"; then
        exit 1
    fi
    if [ "${GH_STUB_EDIT_FAIL_ON_ADD:-0}" = 1 ] &&
        grep -q -- '--add-label' <<<"$*"; then
        exit 1
    fi
    if [ -n "${GH_STUB_NATIVE_TYPE_FILE:-}" ]; then
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--type" ]; then
                if [ "${GH_STUB_NATIVE_TYPE_UNREADABLE_AFTER_TYPE_WRITE:-0}" = 1 ]; then
                    printf '%s\n' ERROR >"$GH_STUB_NATIVE_TYPE_FILE"
                else
                    printf '%s\n' "$a" >"$GH_STUB_NATIVE_TYPE_FILE"
                fi
                break
            fi
            prev="$a"
        done
    fi
    # Within one run (GH_STUB_RUN_ID, set by run()), a label edit lands in a
    # per-run overlay of the issue, so a later read in the SAME call sees
    # the call's own writes while the fixture stays as every test wrote it.
    if [ -n "${GH_STUB_RUN_ID:-}" ]; then
        overlay="$GH_STUB_DIR/.overlay-$GH_STUB_RUN_ID-$3.json"
        src="$overlay"
        [ -f "$src" ] || src="$GH_STUB_DIR/issue-$3.json"
        add=""
        del=""
        prev=""
        for a in "$@"; do
            case "$prev" in
            --add-label) add="$a" ;;
            --remove-label) del="$a" ;;
            esac
            prev="$a"
        done
        if [ -n "$add$del" ] && [ -f "$src" ]; then
            jq --arg add "$add" --arg del "$del" '
              ($del | split(",")) as $d
              | .labels = ([.labels[] | select(.name as $n | $d | index($n) | not)]
                           + [$add | split(",")[] | select(. != "") | {name: .}]
                           | unique_by(.name))' \
                "$src" >"$overlay.next"
            mv "$overlay.next" "$overlay"
        fi
    fi
    ;;
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
    # run() is called inside $(...): $BASHPID differs per call, a counter
    # would not survive the subshell.
    GH_STUB_RUN_ID="r$BASHPID-$RANDOM" PATH="$tmp/bin:$PATH" "$@" >"$tmp/out" 2>&1 ||
        _rc=$?
    echo "$_rc"
}

# ── fixtures ─────────────────────────────────────────────────────────────────
manifest="$tmp/label-registry.json"
cat >"$manifest" <<'JSON'
{
  "$schema": "./label-registry.schema.json",
  "schema_version": 1,
  "families": [
    {"family": "workflow", "prefix": null,
     "purpose": "Fixture workflow labels", "axis": "workflow",
     "source": "inline", "writers": ["human"], "readers": "fixture",
     "lifecycle": "transient", "exclusive": false, "provision": false,
     "values": [
       {"value": "needs-triage", "writers": ["human", "agent"]},
       {"value": "blocked"}]},
    {"family": "work-type", "prefix": null,
     "purpose": "Fixture work types", "axis": "work-type",
     "source": "inline", "writers": ["human", "agent"],
     "readers": "fixture", "lifecycle": "durable", "exclusive": true,
     "provision": false,
     "values": [
       {"value": "bug"}, {"value": "feature"},
       {"value": "enhancement", "retired": true}]},
    {"family": "area", "prefix": "area",
     "purpose": "Fixture areas", "axis": "classification",
     "source": "inline", "writers": ["human", "agent"],
     "readers": "fixture", "lifecycle": "durable", "exclusive": true,
     "provision": false,
     "values": [{"value": "ci"}, {"value": "tasks"}, {"value": "none"}]},
    {"family": "layer", "prefix": "layer",
     "purpose": "Fixture layers", "axis": "classification",
     "source": "inline", "writers": ["human", "agent"],
     "readers": "fixture", "lifecycle": "durable", "exclusive": true,
     "provision": false,
     "values": [{"value": "ui"}, {"value": "api"}, {"value": "none"}]},
    {"family": "domain", "prefix": "domain",
     "purpose": "Fixture domains", "axis": "classification",
     "source": "inline", "writers": ["human", "agent"],
     "readers": "fixture", "lifecycle": "durable", "exclusive": true,
     "provision": false,
     "values": [{"value": "delivery"}, {"value": "auth"}, {"value": "none"}]},
    {"family": "rigor", "prefix": "rigor",
     "purpose": "Fixture rigor", "axis": "strategy", "source": "inline",
     "writers": ["human"], "readers": "fixture", "lifecycle": "durable",
     "exclusive": true, "provision": false, "values": [{"value": "deep"}]},
    {"family": "provenance", "prefix": null,
     "purpose": "Fixture provenance", "axis": "provenance",
     "source": "inline", "writers": ["human", "agent"],
     "readers": "fixture", "lifecycle": "durable", "exclusive": false,
     "provision": false, "values": [{"value": "ai-generated"}]},
    {"family": "claim", "prefix": "claim", "purpose": "Fixture claims",
     "axis": "model", "source": "inline", "writers": ["agent"],
     "readers": "fixture", "lifecycle": "claim-release", "exclusive": true,
     "provision": false, "values": [{"value": "claude"}]}
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
printf '%s\n' area:ci area:none area:tasks bug domain:auth domain:delivery \
    domain:none feature layer:api layer:none layer:ui needs-triage |
    sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 || fail "allowlist mismatch"

echo "==> human work: fixture manifest permits addition but never removal"
human_manifest="$tmp/human-registry.json"
jq '.families += [{"family":"human-work","prefix":null,
    "purpose":"Work primarily completed by a human","axis":"meta",
    "source":"inline","writers":["human","agent"],"readers":"fixture",
    "lifecycle":"durable","exclusive":false,"provision":false,
    "values":[{"value":"human"}]}]' "$manifest" >"$human_manifest"
[ "$(run "$apply" allowlist --manifest "$human_manifest")" = 0 ] ||
    fail "human manifest must be valid: $(cat "$tmp/out")"
grep -qx human "$tmp/out" || fail "human must be agent-addable"
for removal in human 'human,needs-triage'; do
    [ "$(run "$apply" label --repo "$repo" --issue 10 \
        --manifest "$human_manifest" --remove "$removal")" = 4 ] ||
        fail "human removal must use never-list refusal: $(cat "$tmp/out")"
done
[ "$(run "$apply" label --repo "$repo" --issue 10 \
    --manifest "$tmp/no-manifest.json" --remove human)" = 4 ] ||
    fail "no-manifest removal must also refuse human"

echo "==> allowlist: triage works from a standalone vendored support bundle"
standalone_triage="$tmp/standalone-triage"
mkdir -p "$standalone_triage"
cp -R ai/skills/universal/triage "$standalone_triage/triage"
cp -R ai/skills/universal/label-registry-support \
    "$standalone_triage/label-registry-support"
cp -R ai/skills/universal/issue-title-support \
    "$standalone_triage/issue-title-support"
[ ! -e "$standalone_triage/track-work" ] ||
    fail "standalone triage fixture must not contain track-work"
[ "$(run "$standalone_triage/triage/assets/triage-apply.sh" allowlist \
    --manifest "$manifest")" = 0 ] ||
    fail "standalone triage allowlist should succeed: $(cat "$tmp/out")"
sort "$tmp/out" >"$tmp/got"
diff -u "$tmp/want" "$tmp/got" >&2 ||
    fail "standalone triage allowlist mismatch"

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

echo "==> registry: prose delimiters pass while rendered delimiters refuse"
jq '.families[0].purpose = "Fixture | prose\nwith a second line"' \
    "$manifest" >"$tmp/prose-delimiters.json"
[ "$(run "$apply" axes --manifest "$tmp/prose-delimiters.json")" = 0 ] ||
    fail "non-rendered prose delimiters should remain schema-valid"
jq '.families[0].values[0].value = "forged|record"' \
    "$manifest" >"$tmp/rendered-delimiter.json"
[ "$(run "$apply" axes --manifest "$tmp/rendered-delimiter.json")" = 2 ] ||
    fail "a rendered record delimiter must fail closed"

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
printf '%s\n' area:ci area:none area:tasks domain:auth domain:delivery \
    domain:none layer:api layer:none layer:ui | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 || fail "axis-values mismatch"

echo "==> axes: an invalid registry is refused, never derived around"
jq '.families |= map(if .family == "area"
    then .axis = "classificaton" else . end)' "$manifest" >"$tmp/typo.json"
[ "$(run "$apply" axes --manifest "$tmp/typo.json")" = 2 ] ||
    fail "a mistyped axis must exit 2, not silently drop the family"
grep -q "cannot govern" "$tmp/out" || fail "refusal must say why"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --add layer:none --add domain:none \
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
cat >"$stub_dir/issue-15.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"},
            {"name": "area:ci"}, {"name": "domain:auth"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-16.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"},
            {"name": "area:ci"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-17.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"},
            {"name": "domain:auth"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-18.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"},
            {"name": "area:ci"}, {"name": "domain:auth"},
            {"name": "layer:ui"}, {"name": "layer:api"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-19.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"},
            {"name": "area:ci"}, {"name": "domain:auth"},
            {"name": "layer:legacy"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-20.json" <<'JSON'
{"labels": [], "body": "plain"}
JSON

echo "==> label: never-list refuses even what a hostile manifest grants"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add rigor:deep \
    --manifest "$evil")" = 4 ] || fail "rigor:deep must exit 4"
for l in foreman:approved tier:apex tier:implementer:frontier strategy:plan \
    method:plan claim:claude agent:claude-code tier:pinned \
    tier:reviewer:apex priority:high effort:3; do
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

echo "==> label: native Type is refused on a personal repo"
[ "$(run "$apply" label --repo "$repo" --issue 10 --native-type Bug \
    --manifest "$manifest")" = 5 ] ||
    fail "personal native Type must exit 5"

echo "==> label: native Type validates enabled organization Types"
GH_STUB_OWNER_TYPE="Organization"
export GH_STUB_ENABLED_NATIVE_TYPES_JSON='{"data":{"organization":{"issueTypes":{"totalCount":2,"nodes":[{"name":"Bug","isEnabled":true},{"name":"Task","isEnabled":false}]}}}}'
[ "$(run "$apply" label --repo "$repo" --issue 10 --native-type Feature \
    --manifest "$manifest")" = 4 ] ||
    fail "invalid native Type must exit 4"
[ "$(run "$apply" label --repo "$repo" --issue 10 --native-type Task \
    --manifest "$manifest")" = 4 ] ||
    fail "disabled native Type must exit 4"
unset GH_STUB_ENABLED_NATIVE_TYPES_JSON
GH_STUB_OWNER_TYPE="User"

echo "==> native-types: lists enabled organization Types for classification"
GH_STUB_OWNER_TYPE="Organization"
export GH_STUB_ENABLED_NATIVE_TYPES_JSON='{"data":{"organization":{"issueTypes":{"totalCount":2,"nodes":[{"name":"Bug","isEnabled":true},{"name":"Task","isEnabled":false}]}}}}'
[ "$(run "$apply" native-types --repo "$repo")" = 0 ] ||
    fail "native-types should list enabled Types: $(cat "$tmp/out")"
grep -qx 'Bug' "$tmp/out" || fail "native-types must include enabled Bug"
grep -qx 'Task' "$tmp/out" && fail "native-types must exclude disabled Task"
grep -q 'repository(owner: \$o, name: \$r)' "$GH_STUB_LOG" ||
    fail "native-types must query the target repository's available Types"
GH_STUB_OWNER_TYPE="User"
unset GH_STUB_ENABLED_NATIVE_TYPES_JSON

echo "==> label: native Type fills an empty slot but never replaces one"
GH_STUB_OWNER_TYPE="Organization"
export GH_STUB_ENABLED_NATIVE_TYPES_JSON='{"data":{"organization":{"issueTypes":{"totalCount":4,"nodes":[{"name":"Bug","isEnabled":true},{"name":"Feature","isEnabled":true},{"name":"none","isEnabled":true},{"name":"null","isEnabled":true}]}}}}'
export GH_STUB_NATIVE_TYPE="Bug"
: >"$GH_STUB_LOG"
[ "$(run "$apply" label --repo "$repo" --issue 10 --native-type Feature \
    --manifest "$manifest")" = 4 ] ||
    fail "existing Bug must not be replaced with Feature"
grep -q "issue edit" "$GH_STUB_LOG" &&
    fail "a rejected native Type replacement must not edit"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 10 \
    --native-type Bug --execute --manifest "$manifest")" = 0 ] ||
    fail "matching native Type must be an idempotent no-op: $(cat "$tmp/out")"
grep -q "nothing to do" "$tmp/out" ||
    fail "matching native Type must report no work"
grep -q "issue edit" "$GH_STUB_LOG" &&
    fail "matching native Type must not edit"
for sentinel_name in none null; do
    export GH_STUB_NATIVE_TYPE="$sentinel_name"
    : >"$GH_STUB_LOG"
    [ "$(run "$apply" label --repo "$repo" --issue 10 --native-type Bug \
        --manifest "$manifest")" = 4 ] ||
        fail "existing custom Type '$sentinel_name' must not be treated as unset"
    grep -q "issue edit" "$GH_STUB_LOG" &&
        fail "custom Type '$sentinel_name' must not be overwritten"
    [ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 10 \
        --native-type "$sentinel_name" --execute --manifest "$manifest")" = 0 ] ||
        fail "matching custom Type '$sentinel_name' must be an idempotent no-op"
done
unset GH_STUB_ENABLED_NATIVE_TYPES_JSON GH_STUB_NATIVE_TYPE
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
    --add layer:none --add domain:none \
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
    --add layer:none --add domain:none \
    --manifest "$tmp/human-only.json")" = 4 ] ||
    fail "human-only needs-triage removal must exit 4"

echo "==> label: --remove accepts only needs-triage"
[ "$(run "$apply" label --repo "$repo" --issue 10 --remove area:ci \
    --manifest "$manifest")" = 2 ] || fail "--remove area:ci must exit 2"

echo "==> label: needs-triage removal is refused on a conflicted axis"
[ "$(run "$apply" label --repo "$repo" --issue 12 --remove needs-triage \
    --add area:none --add layer:none \
    --manifest "$manifest")" = 6 ] || fail "conflicted axis must exit 6"

echo "==> label: needs-triage removal is refused without a work type"
[ "$(run "$apply" label --repo "$repo" --issue 10 --remove needs-triage \
    --add area:none --add layer:none --add domain:none \
    --manifest "$manifest")" = 6 ] || fail "missing work type must exit 6"

echo "==> label: needs-triage removal passes when classification is complete"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --add layer:none --add domain:none \
    --manifest "$manifest")" = 0 ] || fail "complete removal: $(cat "$tmp/out")"
grep -q "DRY-RUN would remove 'needs-triage'" "$tmp/out" ||
    fail "missing WOULD remove"
grep -q "DRY-RUN would add 'layer:none'" "$tmp/out" ||
    fail "the explicit none value must be applied, not attested"

echo "==> label: layer is required (ADR D6) — an absent layer keeps needs-triage"
[ "$(run "$apply" label --repo "$repo" --issue 15 --remove needs-triage \
    --manifest "$manifest")" = 6 ] ||
    fail "area+domain without layer must keep needs-triage: $(cat "$tmp/out")"
grep -q "layer (no layer:\* label" "$tmp/out" ||
    fail "the refusal must name the missing layer: $(cat "$tmp/out")"
[ "$(run "$apply" label --repo "$repo" --issue 15 --add layer:none \
    --manifest "$manifest")" = 0 ] ||
    fail "layer:none must complete the classification: $(cat "$tmp/out")"
grep -q "DRY-RUN would remove 'needs-triage'" "$tmp/out" ||
    fail "completing the required set must derive the needs-triage removal"

echo "==> label: missing domain or area still blocks removal"
[ "$(run "$apply" label --repo "$repo" --issue 16 --remove needs-triage \
    --manifest "$manifest")" = 6 ] || fail "missing domain must exit 6"
[ "$(run "$apply" label --repo "$repo" --issue 17 --remove needs-triage \
    --manifest "$manifest")" = 6 ] || fail "missing area must exit 6"

echo "==> label: present layer conflicts and unknowns still block removal"
[ "$(run "$apply" label --repo "$repo" --issue 18 --remove needs-triage \
    --manifest "$manifest")" = 6 ] || fail "layer conflict must exit 6"
[ "$(run "$apply" label --repo "$repo" --issue 19 --remove needs-triage \
    --manifest "$manifest")" = 6 ] || fail "unknown layer must exit 6"
grep -q "not in the active layer taxonomy" "$tmp/out" ||
    fail "unknown layer refusal must name the layer"

echo "==> label: an unknown axis value never satisfies the removal gate"
cat >"$stub_dir/issue-14.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"},
            {"name": "area:legacy"}], "body": "plain"}
JSON
[ "$(run "$apply" label --repo "$repo" --issue 14 --remove needs-triage \
    --add layer:none --add domain:none \
    --manifest "$manifest")" = 6 ] || fail "unknown area value must exit 6"
grep -q "not in the active area taxonomy" "$tmp/out" ||
    fail "refusal must name the unknown value: $(cat "$tmp/out")"

echo "==> label: an unprovisioned axis is never demanded (derived axes)"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --add layer:none --add domain:none \
    --manifest "$tmp/no-area.json")" = 0 ] ||
    fail "no-area manifest must not demand an area attestation: $(cat "$tmp/out")"
[ "$(run "$apply" label --repo "$repo" --issue 13 --add area:none \
    --manifest "$tmp/no-area.json")" = 4 ] ||
    fail "a none value of an inactive axis is not writable"

echo "==> label: --inapplicable is retired in favour of the explicit none value"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --manifest "$manifest")" = 2 ] ||
    fail "--inapplicable must exit 2"
grep -q "apply the axis's explicit" "$tmp/out" ||
    fail "the refusal must point at the none value: $(cat "$tmp/out")"

echo "==> label: org removal needs a native Type; unreadable Type refuses"
GH_STUB_OWNER_TYPE="Organization"
export GH_STUB_NATIVE_TYPE=""
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --add layer:none --add domain:none \
    --manifest "$manifest")" = 6 ] || fail "org without Type must exit 6"
export GH_STUB_NATIVE_TYPE="ERROR"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --add layer:none --add domain:none \
    --manifest "$manifest")" = 6 ] || fail "unreadable Type must exit 6"
export GH_STUB_NATIVE_TYPE="Bug"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --add layer:none --add domain:none \
    --manifest "$manifest")" = 0 ] || fail "org with Type should pass"
export GH_STUB_NATIVE_TYPE="none"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --add layer:none --add domain:none \
    --manifest "$manifest")" = 0 ] ||
    fail "org with a custom Type named none should pass"
unset GH_STUB_NATIVE_TYPE
GH_STUB_OWNER_TYPE="User"

echo "==> label: native Type dry-run is inert and reports its mutation"
GH_STUB_OWNER_TYPE="Organization"
: >"$GH_STUB_LOG"
[ "$(run "$apply" label --repo "$repo" --issue 13 --native-type Bug \
    --manifest "$manifest")" = 0 ] || fail "native Type dry-run failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would set native issue Type 'Bug'" "$tmp/out" ||
    fail "native Type dry-run must describe the mutation"
grep -q '^issue edit 13 ' "$GH_STUB_LOG" &&
    fail "native Type dry-run must not mutate an issue"

echo "==> label: native Type dry-run reports marker-first execution order"
[ "$(run "$apply" label --repo "$repo" --issue 20 --native-type Bug \
    --add needs-triage --manifest "$manifest")" = 0 ] ||
    fail "marker-first native Type dry-run failed: $(cat "$tmp/out")"
grep -n "DRY-RUN would add 'needs-triage'" "$tmp/out" | cut -d: -f1 \
    >"$tmp/marker-line"
grep -n "DRY-RUN would set native issue Type 'Bug'" "$tmp/out" | cut -d: -f1 \
    >"$tmp/type-line"
[ "$(cat "$tmp/marker-line")" -lt "$(cat "$tmp/type-line")" ] ||
    fail "dry-run must report the visibility marker before the native Type"

echo "==> label: native Type dry-run refuses an old gh before promising a write"
: >"$GH_STUB_LOG"
[ "$(run env GH_STUB_NO_TYPE_FLAG=1 "$apply" label --repo "$repo" --issue 13 \
    --native-type Bug --manifest "$manifest")" = 2 ] ||
    fail "old gh native Type dry-run must exit 2"
grep -q "DRY-RUN would set native issue Type" "$tmp/out" &&
    fail "old gh dry-run must not promise an unavailable Type write"

echo "==> label: native Type precedes and verifies needs-triage removal"
: >"$GH_STUB_LOG"
native_type_file="$tmp/native-type"
: >"$native_type_file"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NATIVE_TYPE_FILE="$native_type_file" \
    "$apply" label --repo "$repo" --issue 13 \
    --native-type Bug --remove needs-triage --add layer:none \
    --add domain:none --execute --manifest "$manifest")" = 0 ] ||
    fail "combined native Type/removal failed: $(cat "$tmp/out")"
grep -q "APPLIED native issue Type 'Bug'" "$tmp/out" ||
    fail "combined mutation must report the Type"
grep -q "APPLIED remove 'needs-triage'" "$tmp/out" ||
    fail "combined mutation must report removal"
[ "$(grep -c '^issue edit ' "$GH_STUB_LOG")" = 4 ] ||
    fail "combined mutation must check support then issue separate Type/add/removal edits"
grep -n -- "--type Bug" "$GH_STUB_LOG" | cut -d: -f1 >"$tmp/type-line"
grep -n -- "--remove-label needs-triage" "$GH_STUB_LOG" | cut -d: -f1 >"$tmp/remove-line"
[ "$(cat "$tmp/type-line")" -lt "$(cat "$tmp/remove-line")" ] ||
    fail "Type must be written before needs-triage removal"

echo "==> label: a native Type mutation failure cannot remove needs-triage"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_EDIT_FAIL=1 "$apply" \
    label --repo "$repo" --issue 13 --native-type Bug --remove needs-triage \
    --add layer:none --add domain:none --execute \
    --manifest "$manifest")" = 1 ] || fail "native Type mutation failure must exit 1"
grep -q "APPLIED native issue Type" "$tmp/out" &&
    fail "failed native Type mutation must not report success"
grep -q -- "--remove-label needs-triage" "$GH_STUB_LOG" &&
    fail "failed native Type mutation must not remove needs-triage"

echo "==> label: a later label failure discloses the already-applied Type"
: >"$GH_STUB_LOG"
: >"$native_type_file"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NATIVE_TYPE_FILE="$native_type_file" \
    GH_STUB_EDIT_FAIL_ON_REMOVE=1 "$apply" label --repo "$repo" --issue 13 \
    --native-type Bug --remove needs-triage --add layer:none \
    --add domain:none --execute --manifest "$manifest")" = 1 ] ||
    fail "later label failure must exit 1"
grep -q "APPLIED native issue Type 'Bug'" "$tmp/out" ||
    fail "later label failure must disclose the applied Type"
grep -q -- "--remove-label needs-triage" "$GH_STUB_LOG" ||
    fail "later label failure must attempt the label mutation after Type success"

echo "==> label: a failed add preserves needs-triage after Type success"
: >"$GH_STUB_LOG"
: >"$native_type_file"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NATIVE_TYPE_FILE="$native_type_file" \
    GH_STUB_EDIT_FAIL_ON_ADD=1 "$apply" label --repo "$repo" --issue 13 \
    --native-type Bug --add domain:auth --remove needs-triage \
    --add layer:none --execute --manifest "$manifest")" = 1 ] ||
    fail "failed add after Type success must exit 1"
grep -q "APPLIED native issue Type 'Bug'" "$tmp/out" ||
    fail "failed add must disclose the applied Type"
grep -q -- "--remove-label needs-triage" "$GH_STUB_LOG" &&
    fail "failed add must preserve needs-triage"

echo "==> label: a failed needs-triage add prevents a native Type write"
: >"$GH_STUB_LOG"
: >"$native_type_file"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NATIVE_TYPE_FILE="$native_type_file" \
    GH_STUB_EDIT_FAIL_ON_ADD=1 "$apply" label --repo "$repo" --issue 20 \
    --native-type Bug --add needs-triage --execute --manifest "$manifest")" = 1 ] ||
    fail "failed needs-triage add must exit 1"
grep -q -- "--add-label needs-triage" "$GH_STUB_LOG" ||
    fail "an untyped marker-free issue must attempt needs-triage before Type"
grep -q -- "--type Bug" "$GH_STUB_LOG" &&
    fail "a failed needs-triage add must prevent the Type write"
[ ! -s "$native_type_file" ] ||
    fail "a failed needs-triage add must leave the native Type unset"

echo "==> label: an unreadable post-Type verification is indeterminate"
: >"$GH_STUB_LOG"
: >"$native_type_file"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NATIVE_TYPE_FILE="$native_type_file" \
    GH_STUB_NATIVE_TYPE_UNREADABLE_AFTER_TYPE_WRITE=1 "$apply" label --repo "$repo" \
    --issue 13 --native-type Bug --add domain:auth --remove needs-triage \
    --add layer:none --execute --manifest "$manifest")" = 2 ] ||
    fail "unreadable post-Type verification must be indeterminate"
grep -q 'write indeterminate: native issue Type may have applied' "$tmp/out" ||
    fail "indeterminate Type write must be surfaced"
grep -q -- '--add-label\|--remove-label' "$GH_STUB_LOG" &&
    fail "indeterminate Type write must not mutate labels"

echo "==> label: an indeterminate Type write reports an established visibility marker"
: >"$GH_STUB_LOG"
: >"$native_type_file"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NATIVE_TYPE_FILE="$native_type_file" \
    GH_STUB_NATIVE_TYPE_UNREADABLE_AFTER_TYPE_WRITE=1 "$apply" label --repo "$repo" \
    --issue 20 --native-type Bug --add needs-triage --execute \
    --manifest "$manifest")" = 2 ] ||
    fail "indeterminate Type write after marker add must exit 2"
grep -q "APPLIED add 'needs-triage'" "$tmp/out" ||
    fail "indeterminate Type write must disclose the established marker"
grep -q 'no remaining labels or needs-triage removal were attempted' "$tmp/out" ||
    fail "indeterminate Type write must distinguish the earlier marker add"
[ "$(grep -c -- '--add-label needs-triage' "$GH_STUB_LOG")" = 1 ] ||
    fail "indeterminate Type path must establish the marker exactly once"

echo "==> label: a concurrent Type change refuses before any mutation"
: >"$GH_STUB_LOG"
: >"$native_type_file"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NATIVE_TYPE_FILE="$native_type_file" \
    GH_STUB_TYPE_CHANGES_BEFORE_WRITE=Feature "$apply" label --repo "$repo" \
    --issue 13 --native-type Bug --execute --manifest "$manifest")" = 4 ] ||
    fail "concurrent Type change must refuse"
[ "$(grep -c '^issue edit ' "$GH_STUB_LOG")" = 1 ] ||
    fail "concurrent Type change must stop before the Type mutation"

echo "==> label: native Type contract states the remaining non-CAS race"
grep -q 'best-effort fill' "$apply" ||
    fail "native Type script contract must state best-effort behavior"
grep -q 'does not expose a conditional Type mutation' \
    ./ai/skills/universal/triage/SKILL.md ||
    fail "triage skill must disclose the non-CAS Type write window"
grep -q 'never overwritten' "$apply" &&
    fail "native Type script must not promise absolute overwrite prevention"

echo "==> label: an old gh without --type refuses before mutation"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NO_TYPE_FLAG=1 "$apply" \
    label --repo "$repo" --issue 13 --native-type Bug --execute \
    --manifest "$manifest")" = 2 ] || fail "old gh must exit 2"
[ "$(grep -c '^issue edit ' "$GH_STUB_LOG")" = 1 ] ||
    fail "old gh must only receive the help probe"
GH_STUB_OWNER_TYPE="User"

echo "==> label: --execute is inert without TRIAGE_EXECUTE=1"
: >"$GH_STUB_LOG"
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

echo "==> native-type: keeps state separate from sentinel-shaped names"
export GH_STUB_NATIVE_TYPE=""
[ "$(run "$apply" native-type --repo "$repo" --issue 10)" = 0 ] ||
    fail "native-type failed"
jq -e '.state == "unset" and .name == null' "$tmp/out" >/dev/null ||
    fail "unset native Type must return explicit state"
for sentinel_name in none null; do
    export GH_STUB_NATIVE_TYPE="$sentinel_name"
    [ "$(run "$apply" native-type --repo "$repo" --issue 10)" = 0 ] ||
        fail "native-type failed for custom Type '$sentinel_name'"
    jq -e --arg name "$sentinel_name" \
        '.state == "set" and .name == $name' "$tmp/out" >/dev/null ||
        fail "custom Type '$sentinel_name' must remain distinct from unset"
done
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
grep -q "(triage): Track backlog findings" "$tmp/out" ||
    fail "report creation must use the canonical scoped title"
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
{"labels": [], "title": "Triage report", "body": "$marker\nold body"}
JSON
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$report" sync --repo "$repo" \
    --entries-file "$entries" --execute)" = 0 ] ||
    fail "marker-carrying update failed: $(cat "$tmp/out")"
grep -q "issue edit 99" "$GH_STUB_LOG" || fail "edit of #99 not issued"
grep -q -- "--title (triage): Track backlog findings" "$GH_STUB_LOG" ||
    fail "the marker-owned report must be retitled to the canonical format"

echo "==> report sync: a malformed requested report title is refused"
: >"$GH_STUB_LOG"
nbsp="$(printf '\302\240')"
invalid_report_titles=(
    'Legacy triage report'
    "(${nbsp}scope): Repair metadata"
    "(scope${nbsp}): Repair metadata"
    "(scope): ${nbsp}Repair metadata"
    "(scope): Repair metadata${nbsp}"
    $'(scope): Repair\tmetadata'
    $'(scope): Repair\001metadata'
)
for title in "${invalid_report_titles[@]}"; do
    [ "$(run "$report" sync --repo "$repo" --entries-file "$entries" \
        --title "$title")" = 2 ] ||
        fail "report must reject Unicode boundary whitespace and controls: '$title'"
done
grep -qE "issue (edit|create)" "$GH_STUB_LOG" &&
    fail "invalid report title must not write"

echo "==> report sync: standalone triage carries the shared title predicate"
standalone_report="$standalone_triage/triage/assets/triage-report.sh"
[ "$(run "$standalone_report" sync --repo "$repo" \
    --entries-file "$entries")" = 0 ] ||
    fail "standalone report should resolve its shared title module"
[ "$(run "$standalone_report" sync --repo "$repo" \
    --entries-file "$entries" --title "(scope): ${nbsp}Repair metadata")" = 2 ] ||
    fail "standalone report must enforce Unicode boundary whitespace"

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
jq -n --rawfile b "$tmp/livebody" \
    '{"labels": [], "title": "(triage): Track backlog findings", "body": $b}' \
    >"$stub_dir/issue-99.json"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 TRIAGE_NOW=2026-02-02 "$report" sync \
    --repo "$repo" --entries-file "$entries" --execute)" = 0 ] ||
    fail "unchanged sync failed: $(cat "$tmp/out")"
grep -q "skipping edit" "$tmp/out" || fail "unchanged body must skip the edit"
grep -q "issue edit" "$GH_STUB_LOG" && fail "unchanged body must not edit"

echo "==> report sync: will not retitle a bot-authored issue"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "body": "$marker", "author": {"login": "app/renovate", "type": "Bot"}}]
JSON
jq -n --rawfile b "$tmp/livebody" \
    '{"labels": [], "title": "Dependency Dashboard", "body": $b, "author": {"login": "app/renovate", "type": "Bot"}}' \
    >"$stub_dir/issue-99.json"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 TRIAGE_NOW=2026-02-02 "$report" sync \
    --repo "$repo" --entries-file "$entries" --execute)" = 4 ] ||
    fail "bot-authored report issue must be refused (exit 4): $(cat "$tmp/out")"
grep -q "refused: will not retitle bot-authored issue" "$tmp/out" ||
    fail "bot-authored report issue must explain refusal: $(cat "$tmp/out")"
grep -q "issue edit" "$GH_STUB_LOG" && fail "bot-authored issue must not edit"

# ── scan ─────────────────────────────────────────────────────────────────────
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "title": "Triage report", "body": "$marker",
  "author": {"login": "testowner"},
  "labels": [], "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z", "assignees": []},
 {"number": 23, "title": "(classification): Resolve one missing axis",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 15, "title": "(classification): Complete without a stack layer",
  "author": {"login": "testowner"},
  "labels": [{"name": "needs-triage"}, {"name": "bug"},
             {"name": "area:ci"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 16, "title": "(classification): Missing domain",
  "author": {"login": "testowner"},
  "labels": [{"name": "needs-triage"}, {"name": "bug"},
             {"name": "area:ci"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 17, "title": "(classification): Missing area",
  "author": {"login": "testowner"},
  "labels": [{"name": "needs-triage"}, {"name": "bug"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 18, "title": "(classification): Conflicting stack layers",
  "author": {"login": "testowner"},
  "labels": [{"name": "needs-triage"}, {"name": "bug"},
             {"name": "area:ci"}, {"name": "domain:auth"},
             {"name": "layer:ui"}, {"name": "layer:api"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 19, "title": "(classification): Unknown stack layer",
  "author": {"login": "testowner"},
  "labels": [{"name": "needs-triage"}, {"name": "bug"},
             {"name": "area:ci"}, {"name": "domain:auth"},
             {"name": "layer:legacy"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 20, "title": "gauntlet: something is broken in the gate",
  "labels": [{"name": "claim:claude"}, {"name": "needs-triage"}],
  "createdAt": "2020-01-01T00:00:00Z", "updatedAt": "2020-01-02T00:00:00Z",
  "assignees": [{"login": "someone"}], "body": ""},
 {"number": 21, "title": "(classification): Resolve conflicting domains",
  "labels": [{"name": "bug"}, {"name": "domain:auth"},
             {"name": "domain:delivery"}, {"name": "area:ci"},
             {"name": "layer:ui"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 22, "title": "(classification): Keep the backlog quiet",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 29, "title": "(classification):Missing exact separator",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 30, "title": "(\u00a0scope): Repair metadata",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "assignees": [], "body": ""},
 {"number": 31, "title": "(scope\u00a0): Repair metadata",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "assignees": [], "body": ""},
 {"number": 32, "title": "(scope): \u00a0Repair metadata",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "assignees": [], "body": ""},
 {"number": 33, "title": "(scope): Repair metadata\u00a0",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "assignees": [], "body": ""},
 {"number": 34, "title": "(scope): Repair\tmetadata",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "assignees": [], "body": ""},
 {"number": 35, "title": "(scope): Repair\u0001metadata",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "assignees": [], "body": ""},
 {"number": 24, "title": "(classification): Remove a retired area value",
  "labels": [{"name": "bug"}, {"name": "area:legacy"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 25, "title": "(classification): Resolve a stray area value",
  "labels": [{"name": "bug"}, {"name": "needs-triage"}, {"name": "area:ci"},
             {"name": "area:legacy"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 27, "title": "(classification): Requeue a stray area value",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "area:legacy"},
             {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 26, "title": "(classification): Use the native issue type",
  "labels": [{"name": "needs-triage"}, {"name": "area:ci"},
             {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 28, "title": "(classification): Replace a legacy work label",
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
jq -e '.open[] | select(.number == 20) | .flags | index("title-malformed")' \
    "$scan_out" >/dev/null || fail "title-malformed flag missing"
jq -e '.open[] | select(.number == 23) | .flags
       | index("title-malformed") == null' "$scan_out" >/dev/null ||
    fail "a canonical scoped title must not be flagged"
jq -e '.open[] | select(.number == 29) | .flags | index("title-malformed")' \
    "$scan_out" >/dev/null || fail "a malformed scoped separator must be flagged"
jq -e '[.open[] | select(.number >= 30 and .number <= 35)
        | .flags | index("title-malformed")] | all' "$scan_out" >/dev/null ||
    fail "scan must reject NBSP boundaries and internal C0 controls"
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

echo "==> scan: layer is required (ADR D6) — no layer keeps needs-triage"
jq -e '.open[] | select(.number == 15)
       | (.axis_state.layer == "none")
         and (.required_missing == ["layer"])
         and (.flags | index("needs-triage-removable") == null)
         and (.flags | index("partially-classified") != null)
         and ([.flags[] | select(. == "axis-missing:layer")] | length == 1)' \
    "$scan_out" >/dev/null || fail "a missing layer must keep the issue incomplete"

echo "==> scan: missing area or domain remains incomplete"
jq -e '.open[] | select(.number == 16)
       | (.axis_state.domain == "none")
         and (.flags | index("partially-classified") != null)
         and (.flags | index("needs-triage-removable") == null)' \
    "$scan_out" >/dev/null || fail "missing domain must remain incomplete"
jq -e '.open[] | select(.number == 17)
       | (.axis_state.area == "none")
         and (.flags | index("partially-classified") != null)
         and (.flags | index("needs-triage-removable") == null)' \
    "$scan_out" >/dev/null || fail "missing area must remain incomplete"

echo "==> scan: present layer conflicts and unknowns remain incomplete"
jq -e '.open[] | select(.number == 18)
       | (.axis_state.layer == "conflict")
         and (.flags | index("partially-classified") != null)' \
    "$scan_out" >/dev/null || fail "layer conflict must remain incomplete"
jq -e '.open[] | select(.number == 19)
       | (.axis_state.layer == "unknown")
         and (.flags | index("axis-unknown-value:layer") != null)
         and (.flags | index("partially-classified") != null)' \
    "$scan_out" >/dev/null || fail "unknown layer must remain incomplete"

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

echo "==> scan: needs-triage is derived — a missing axis requeues it"
jq -e '.open[] | select(.number == 23)
       | (.flags | index("axis-missing:area") != null)
         and (.required_missing == ["area"])
         and (.flags | index("missing-needs-triage") != null)' \
    "$scan_out" >/dev/null ||
    fail "an issue missing a required axis must be flagged missing-needs-triage"
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
jq 'map(.issueType = (if .number == 23 then {name: "none"}
                      elif .number == 26 then {name: "null"}
                      else null end))' \
    "$stub_dir/issues-open.json" >"$stub_dir/issues-open-types.json"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "org bulk scan failed: $(cat "$tmp/out")"
jq -e '.native_type_mode == "bulk"' "$tmp/out" >/dev/null ||
    fail "bulk-capable gh must report bulk mode"
jq -e '.open[] | select(.number == 23)
       | .native_type_state == "set" and .native_type == "none"' \
    "$tmp/out" >/dev/null ||
    fail "native_type must carry a sentinel-shaped bulk-read Type"
jq -e '.open[] | select(.number == 23) | .flags
       | index("legacy-work-type-label") == null' "$tmp/out" >/dev/null ||
    fail "a natively-typed issue must not read as legacy-labeled"
jq -e '.open[] | select(.number == 24)
       | .native_type_state == "unset" and .native_type == null
         and (.flags | index("legacy-work-type-label") != null)' \
    "$tmp/out" >/dev/null ||
    fail "an untyped org issue with a work-type label stays flagged"
jq -e '.open[] | select(.number == 26)
       | .native_type_state == "set" and .native_type == "null"
         and (.flags | index("needs-triage-removable") != null)
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

# ── completion candidates (issue #671) ──────────────────────────────────────
: >"$GH_STUB_LOG"
# Backticks would be command substitutions in this unquoted heredoc.
fence='```'
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "title": "Triage report", "body": "$marker",
  "author": {"login": "testowner"},
  "labels": [], "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z", "assignees": []},
 {"number": 50, "title": "(gauntlet): Retire the ci mirror step",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n- [x] [CI] one\n- [x] [ci] two\n- [ ] [HUMAN] needs a human"},
 {"number": 51, "title": "(gauntlet): All criteria are checked",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n- [x] [CI] one\n- [X] [Human] two"},
 {"number": 52, "title": "(gauntlet): A CI criterion is still outstanding",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n- [ ] [CI] one\n- [x] [HUMAN] two"},
 {"number": 58, "title": "(gauntlet): Task lists outside the section",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Problem\n\n- [x] a ticked todo in prose\n\n## Verify\n\n${fence}\n- [x] [CI] fenced example\n${fence}\n"},
 {"number": 72, "title": "(gauntlet): Comment opener inside a fence",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n${fence}html\n<!-- literal\n${fence}\n- [x] [CI] still counted\n\n# Appendix\n\n- [ ] [CI] not a criterion\n1234567890. [ ] [CI] prose"},
 {"number": 68, "title": "(gauntlet): Commented-out template",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Problem\n\n<!--\n## Acceptance criteria\n\n- [x] [CI] placeholder\n-->\ntext <!-- - [x] [CI] inline --> more"},
 {"number": 69, "title": "(gauntlet): Heading nested in a list",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "- item\n  ## Acceptance criteria\n- [x] [CI] sibling"},
 {"number": 70, "title": "(gauntlet): No space after the checkbox",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n- [x][CI] not rendered as a task"},
 {"number": 71, "title": "(gauntlet): Backtick in a fence info string",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n${fence}bad${fence}info\n- [x] [CI] still rendered"},
 {"number": 67, "title": "(gauntlet): Only nested checked items",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n- options:\n  - [x] [CI] nested one\n   - [x] [CI] nested two"},
 {"number": 63, "title": "(gauntlet): Only untagged boxes",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n- [x] done\n- [x] also done"},
 {"number": 59, "title": "(gauntlet): Fenced sample inside the section",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance Criteria ##\n\n${fence}md\n${fence}markdown\n- [ ] [CI] sample\n${fence}\n- [x] [CI] real\n- [x] untagged ticked box\n- alternatives:\n  - [ ] [CI] nested child\n> - [ ] [CI] quoted example\n    - [ ] [CI] indented code sample\n\n## Out of scope\n\n- [ ] [CI] not a criterion"}]
JSON
cat >"$stub_dir/issues-closed.json" <<'JSON'
[]
JSON

echo "==> scan: all-criteria-checked flags an all-ticked open issue"
# --all: #52 (outstanding [CI], no completion flag) carries no OTHER flag
# either, so it would otherwise be filtered out before its absence of a
# completion flag could even be asserted.
[ "$(run "$scan" --repo "$repo" --manifest "$manifest" --all)" = 0 ] ||
    fail "completion-candidate scan failed: $(cat "$tmp/out")"
cc_scan="$tmp/cc-scan.json"
cp "$tmp/out" "$cc_scan"
jq -e '.open[] | select(.number == 51)
       | .criteria == {total: 2, unticked: 0, unticked_ci: 0,
                        unticked_human: 0, unticked_untagged: 0}
         and (.completion_reasons
              == ["completion-candidate:all-criteria-checked"])
         and (.flags
              | index("completion-candidate:all-criteria-checked") != null)' \
    "$cc_scan" >/dev/null || fail "#51 must read all-criteria-checked"

echo "==> scan: human-only-remaining flags the #1080 shape"
jq -e '.open[] | select(.number == 50)
       | .criteria == {total: 3, unticked: 1, unticked_ci: 0,
                        unticked_human: 1, unticked_untagged: 0}
         and (.completion_reasons
              == ["completion-candidate:human-only-remaining"])
         and (.flags
              | index("completion-candidate:human-only-remaining") != null)' \
    "$cc_scan" >/dev/null || fail "#50 must read human-only-remaining"
jq -e '.open[] | select(.number == 50)
       | .flags | index("completion-candidate:all-criteria-checked") == null' \
    "$cc_scan" >/dev/null ||
    fail "the two completion flags must be mutually exclusive"

echo "==> scan: checkboxes outside the Acceptance criteria section are not criteria"
jq -e '.open[] | select(.number == 58)
       | .criteria.total == 0 and (.completion_reasons == [])' \
    "$tmp/cc-scan.json" >/dev/null ||
    fail "#58 has no acceptance-criteria section, so it has no criteria"
jq -e '.open[] | select(.number == 59)
       | .criteria == {total: 1, unticked: 0, unticked_ci: 0,
                       unticked_human: 0, unticked_untagged: 0}
         and (.completion_reasons
              == ["completion-candidate:all-criteria-checked"])' \
    "$tmp/cc-scan.json" >/dev/null ||
    fail "#59 must count only the unfenced tagged item inside its section"
jq -e '.open[] | select(.number == 63)
       | .criteria.total == 0 and (.completion_reasons == [])' \
    "$tmp/cc-scan.json" >/dev/null ||
    fail "#63 has only untagged boxes, which are not criteria"
jq -e '.open[] | select(.number == 67)
       | .criteria.total == 0 and (.completion_reasons == [])' \
    "$tmp/cc-scan.json" >/dev/null ||
    fail "#67 has only nested items, which are not top-level criteria"
jq -e '[.open[] | select(.number == 68 or .number == 69 or .number == 70)]
       | length == 3 and all(.criteria.total == 0 and .completion_reasons == [])' \
    "$tmp/cc-scan.json" >/dev/null ||
    fail "#68/#69/#70 (HTML comment, nested heading, no-space box) are not criteria"
jq -e '.open[] | select(.number == 71)
       | .criteria.total == 1
         and (.completion_reasons == ["completion-candidate:all-criteria-checked"])' \
    "$tmp/cc-scan.json" >/dev/null ||
    fail "#71: a backtick-bearing info string is prose, not a fence opener"
jq -e '.open[] | select(.number == 72)
       | .criteria.total == 1 and .criteria.unticked == 0
         and (.completion_reasons == ["completion-candidate:all-criteria-checked"])' \
    "$tmp/cc-scan.json" >/dev/null ||
    fail "#72: fenced <!-- is literal, an H1 ends the section, ten-digit markers are prose"

echo "==> scan: an outstanding [CI] criterion carries no completion flag"
jq -e '.open[] | select(.number == 52)
       | (.completion_reasons == [])
         and ([.flags[] | select(startswith("completion-candidate"))] == [])' \
    "$cc_scan" >/dev/null || fail "#52 must not read as a completion candidate"

# delivery: harmon-init#1080's exact shape — a Refs-linked PR, so
# closedByPullRequestsReferences is empty and the only trusted signal is the
# cross-referenced timeline event with a non-null merged_at.
cat >"$stub_dir/delivery-50.json" <<JSON
{"data": {"repository": {"issue": {"number": 50, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON
cat >"$stub_dir/timeline-50.json" <<JSON
[{"event": "cross-referenced", "source": {"type": "issue", "issue": {
   "number": 1107, "state": "closed",
   "repository": {"full_name": "$repo"},
   "pull_request": {"url": "https://api.github.com/repos/$repo/pulls/1107",
     "html_url": "https://github.com/$repo/pull/1107",
     "diff_url": "https://github.com/$repo/pull/1107.diff",
     "patch_url": "https://github.com/$repo/pull/1107.patch",
     "merged_at": "2026-08-29T14:44:42Z"}}}}]
JSON

cat >"$stub_dir/pull-1107.json" <<'JSON'
{"number": 1107, "title": "feat: deliver it", "body": "Refs testowner/testrepo#50\n\nDelivers the thing."}
JSON

echo "==> delivery: the #1080/#1107 shape reads merged-delivery via cross-reference"
[ "$(run "$scan" delivery --repo "$repo" --issue 50)" = 0 ] ||
    fail "delivery #50 failed: $(cat "$tmp/out")"
jq -e --arg repo "$repo" '
  .verdict == "merged-delivery" and .state == "OPEN"
  and (.evidence == [{pr: 1107,
                       url: ("https://github.com/" + $repo + "/pull/1107"),
                       merged_at: "2026-08-29T14:44:42Z",
                       via: "cross-reference"}])
' "$tmp/out" >/dev/null || fail "delivery #50 must report cross-reference evidence"

# delivery: partial delivery — the cross-referencing same-repo PR is still
# open (merged_at null), so it is not trusted evidence.
cat >"$stub_dir/delivery-53.json" <<JSON
{"data": {"repository": {"issue": {"number": 53, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON
cat >"$stub_dir/timeline-53.json" <<JSON
[{"event": "cross-referenced", "source": {"type": "issue", "issue": {
   "number": 900, "state": "open",
   "repository": {"full_name": "$repo"},
   "pull_request": {"url": "https://api.github.com/repos/$repo/pulls/900",
     "html_url": "https://github.com/$repo/pull/900",
     "merged_at": null}}}}]
JSON

echo "==> delivery: an open same-repo cross-referencing PR is not trusted evidence"
[ "$(run "$scan" delivery --repo "$repo" --issue 53)" = 0 ] ||
    fail "delivery #53 failed: $(cat "$tmp/out")"
jq -e '.verdict == "none" and (.evidence == [])' "$tmp/out" >/dev/null ||
    fail "delivery #53 must not trust an unmerged PR"

# delivery: an unrelated merged PR from a DIFFERENT repository, plus a
# commit-reference event and a comment — none of these are trusted evidence.
cat >"$stub_dir/delivery-54.json" <<JSON
{"data": {"repository": {"issue": {"number": 54, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON
cat >"$stub_dir/timeline-54.json" <<'JSON'
[{"event": "referenced", "commit_id": "abc123"},
 {"event": "commented", "body": "looks done to me!"},
 {"event": "cross-referenced", "source": {"type": "issue", "issue": {
   "number": 42, "state": "closed",
   "repository": {"full_name": "someoneelse/otherrepo"},
   "pull_request": {
     "url": "https://api.github.com/repos/someoneelse/otherrepo/pulls/42",
     "html_url": "https://github.com/someoneelse/otherrepo/pull/42",
     "merged_at": "2026-08-01T00:00:00Z"}}}}]
JSON

echo "==> delivery: a merged PR from a different repository is not trusted evidence"
[ "$(run "$scan" delivery --repo "$repo" --issue 54)" = 0 ] ||
    fail "delivery #54 failed: $(cat "$tmp/out")"
jq -e '.verdict == "none" and (.evidence == [])' "$tmp/out" >/dev/null ||
    fail "delivery #54 must ignore a cross-repo PR, a commit ref, and a comment"

# delivery: the closing-reference (closedByPullRequestsReferences) path —
# MERGED and same-repo is trusted; OPEN and same-repo is not.
cat >"$stub_dir/delivery-55.json" <<JSON
{"data": {"repository": {"issue": {"number": 55, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": [
    {"number": 661, "state": "MERGED",
     "mergedAt": "2026-08-28T13:40:53Z",
     "repository": {"nameWithOwner": "$repo"},
     "url": "https://github.com/$repo/pull/661"}]}}}}}
JSON
cat >"$stub_dir/timeline-55.json" <<JSON
[{"event": "cross-referenced", "source": {"type": "issue", "issue": {
   "number": 661, "state": "closed",
   "repository": {"full_name": "$repo"},
   "pull_request": {"html_url": "https://github.com/$repo/pull/661",
     "merged_at": "2026-08-28T13:40:53Z"}}}}]
JSON
cat >"$stub_dir/pull-661.json" <<'JSON'
{"number": 661, "title": "fix: x", "body": "Closes #55"}
JSON

echo "==> delivery: a merged closing reference on an open issue is context, not evidence"
[ "$(run "$scan" delivery --repo "$repo" --issue 55)" = 0 ] ||
    fail "delivery #55 failed: $(cat "$tmp/out")"
jq -e --arg repo "$repo" '
  .verdict == "none" and (.evidence == [])
  and (.closing_references == [{pr: 661,
                       url: ("https://github.com/" + $repo + "/pull/661"),
                       merged_at: "2026-08-28T13:40:53Z"}])
' "$tmp/out" >/dev/null ||
    fail "delivery #55 must surface but never trust a closing reference"

cat >"$stub_dir/delivery-56.json" <<JSON
{"data": {"repository": {"issue": {"number": 56, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": [
    {"number": 700, "state": "OPEN", "mergedAt": null,
     "repository": {"nameWithOwner": "$repo"},
     "url": "https://github.com/$repo/pull/700"}]}}}}}
JSON
cat >"$stub_dir/timeline-56.json" <<'JSON'
[]
JSON

echo "==> delivery: an open same-repo closing reference is not trusted evidence"
[ "$(run "$scan" delivery --repo "$repo" --issue 56)" = 0 ] ||
    fail "delivery #56 failed: $(cat "$tmp/out")"
jq -e '.verdict == "none" and (.evidence == []) and (.closing_references == [])' \
    "$tmp/out" >/dev/null ||
    fail "delivery #56 must not list an open closing-reference PR"

# delivery: a missing timeline fixture simulates a failed read — indeterminate
# (never "none"), and still exit 0 so the calling model can list it under
# "## Unverified candidates".
cat >"$stub_dir/delivery-57.json" <<JSON
{"data": {"repository": {"issue": {"number": 57, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON

echo "==> delivery: a failed timeline read reports indeterminate, not none"
[ "$(run "$scan" delivery --repo "$repo" --issue 57)" = 0 ] ||
    fail "delivery #57 (indeterminate) must still exit 0: $(cat "$tmp/out")"
jq -e '.verdict == "indeterminate" and .state == null and (.evidence == [])
       and ((.reason | length) > 0)' "$tmp/out" >/dev/null ||
    fail "delivery #57 must report indeterminate with a reason"

# delivery: the issue was reopened AFTER its delivery merged — a human
# decision, so the earlier evidence no longer counts.
cat >"$stub_dir/delivery-60.json" <<JSON
{"data": {"repository": {"issue": {"number": 60, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON
cat >"$stub_dir/timeline-60.json" <<JSON
[{"event": "closed", "created_at": "2026-08-01T00:00:00Z"},
 {"event": "reopened", "created_at": "2026-08-02T00:00:00Z"},
 {"event": "cross-referenced", "created_at": "2026-08-01T00:00:00Z",
  "source": {"type": "issue", "issue": {
   "number": 800, "state": "closed",
   "repository": {"full_name": "$repo"},
   "pull_request": {"html_url": "https://github.com/$repo/pull/800",
     "merged_at": "2026-08-01T00:00:00Z"}}}}]
JSON

cat >"$stub_dir/pull-800.json" <<'JSON'
{"number": 800, "title": "fix: earlier delivery", "body": "Refs #60"}
JSON

echo "==> delivery: evidence merged before a later reopen is not trusted"
[ "$(run "$scan" delivery --repo "$repo" --issue 60)" = 0 ] ||
    fail "delivery #60 failed: $(cat "$tmp/out")"
jq -e '.verdict == "none" and (.evidence == [])
       and (.reason | test("reopened"))' "$tmp/out" >/dev/null ||
    fail "delivery #60 must discard evidence that predates the reopen"

# delivery: the candidate closed between the scan and this read.
cat >"$stub_dir/delivery-61.json" <<JSON
{"data": {"repository": {"issue": {"number": 61, "state": "CLOSED",
  "closedByPullRequestsReferences": {"nodes": [
    {"number": 801, "state": "MERGED", "mergedAt": "2026-08-01T00:00:00Z",
     "repository": {"nameWithOwner": "$repo"},
     "url": "https://github.com/$repo/pull/801"}]}}}}}
JSON
cat >"$stub_dir/timeline-61.json" <<'JSON'
[]
JSON

echo "==> delivery: a closed issue is never a completion candidate"
[ "$(run "$scan" delivery --repo "$repo" --issue 61)" = 0 ] ||
    fail "delivery #61 failed: $(cat "$tmp/out")"
jq -e '.verdict == "none" and .state == "CLOSED"
       and (.reason | test("not open"))' "$tmp/out" >/dev/null ||
    fail "delivery #61 must report none for a closed issue"

# delivery: a full 100-event page with nothing on it is not a proven
# negative — later pages were never read.
cat >"$stub_dir/delivery-62.json" <<JSON
{"data": {"repository": {"issue": {"number": 62, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON
jq -n --arg repo "$repo" '[range(99) | {event: "commented", created_at: "2026-08-01T00:00:00Z"}]
  + [{event: "cross-referenced", source: {type: "issue", issue: {
       number: 950, state: "closed", repository: {full_name: $repo},
       pull_request: {html_url: "x", merged_at: "2026-08-01T00:00:00Z"}}}}]' \
    >"$stub_dir/timeline-62.json"
# no pull-950.json on purpose: a truncated page must never spend PR reads

echo "==> delivery: a truncated timeline with no evidence is indeterminate"
[ "$(run "$scan" delivery --repo "$repo" --issue 62)" = 0 ] ||
    fail "delivery #62 failed: $(cat "$tmp/out")"
jq -e '.verdict == "indeterminate" and .timeline_truncated == true
       and (.reason | test("truncated"))' "$tmp/out" >/dev/null ||
    fail "delivery #62 must not read a truncated empty page as none"

# delivery: the merged PR only mentioned the issue in a COMMENT — the
# timeline event looks identical, but the PR's own title/body never names
# the issue, so it is not evidence.
cat >"$stub_dir/delivery-64.json" <<JSON
{"data": {"repository": {"issue": {"number": 64, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON
cat >"$stub_dir/timeline-64.json" <<JSON
[{"event": "cross-referenced", "source": {"type": "issue", "issue": {
   "number": 900, "state": "closed",
   "repository": {"full_name": "$repo"},
   "pull_request": {"html_url": "https://github.com/$repo/pull/900",
     "merged_at": "2026-08-01T00:00:00Z"}}}}]
JSON
cat >"$stub_dir/pull-900.json" <<'JSON'
{"number": 900, "title": "chore: unrelated", "body": "Refs #640 only"}
JSON

echo "==> delivery: a cross-reference from a PR comment is not trusted evidence"
[ "$(run "$scan" delivery --repo "$repo" --issue 64)" = 0 ] ||
    fail "delivery #64 failed: $(cat "$tmp/out")"
jq -e '.verdict == "none" and (.evidence == [])
       and (.reason | test("do not name this issue"))' "$tmp/out" >/dev/null ||
    fail "delivery #64 must require the PR body/title to name the issue"

# delivery: the candidate PR itself could not be read — indeterminate.
cat >"$stub_dir/delivery-65.json" <<JSON
{"data": {"repository": {"issue": {"number": 65, "state": "OPEN",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON
cat >"$stub_dir/timeline-65.json" <<JSON
[{"event": "cross-referenced", "source": {"type": "issue", "issue": {
   "number": 901, "state": "closed",
   "repository": {"full_name": "$repo"},
   "pull_request": {"html_url": "https://github.com/$repo/pull/901",
     "merged_at": "2026-08-01T00:00:00Z"}}}}]
JSON

echo "==> delivery: an unreadable candidate PR is indeterminate, not none"
[ "$(run "$scan" delivery --repo "$repo" --issue 65)" = 0 ] ||
    fail "delivery #65 failed: $(cat "$tmp/out")"
jq -e '.verdict == "indeterminate" and (.reason | test("could not read"))' \
    "$tmp/out" >/dev/null || fail "delivery #65 must be indeterminate"

# delivery: a closed issue whose timeline is unreadable is still settled by
# the first read — none, with its known state, not indeterminate.
cat >"$stub_dir/delivery-66.json" <<JSON
{"data": {"repository": {"issue": {"number": 66, "state": "CLOSED",
  "closedByPullRequestsReferences": {"nodes": []}}}}}
JSON

echo "==> delivery: a closed issue with an unreadable timeline is none, not indeterminate"
[ "$(run "$scan" delivery --repo "$repo" --issue 66)" = 0 ] ||
    fail "delivery #66 failed: $(cat "$tmp/out")"
jq -e '.verdict == "none" and .state == "CLOSED"' "$tmp/out" >/dev/null ||
    fail "delivery #66 must return none with its known state"

echo "==> delivery: refuses a mismatched --repo when the run is bound"
[ "$(run env TRIAGE_REPO="$repo" "$scan" delivery --repo other/elsewhere \
    --issue 50)" = 4 ] || fail "bound delivery repo mismatch must exit 4"

echo "==> delivery: refuses a non-numeric --issue"
[ "$(run "$scan" delivery --repo "$repo" --issue abc)" = 2 ] ||
    fail "non-numeric delivery --issue must exit 2"

echo "==> completion candidates: scan + delivery never mutate anything"
grep -qE '(issue edit|issue close|issue comment|label (create|edit|delete))' \
    "$GH_STUB_LOG" &&
    fail "completion-candidate scan/delivery calls must never mutate anything"

echo "==> scan: a resolved completion candidate disappears from a re-scan"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "title": "Triage report", "body": "$marker",
  "author": {"login": "testowner"},
  "labels": [], "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z", "assignees": []},
 {"number": 51, "title": "(gauntlet): All criteria are checked",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [],
  "body": "## Acceptance criteria\n\n- [x] [CI] one\n- [X] [Human] two"}]
JSON
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "re-scan after #50 closed failed: $(cat "$tmp/out")"
jq -e '[.open[].number] | index(50) == null' "$tmp/out" >/dev/null ||
    fail "#50 must no longer appear once it is gone from the open list"

echo "==> report sync: a completion candidate no longer in scope leaves the body"
cc_entries="$tmp/cc-entries.md"
cat >"$cc_entries" <<'MD'
### #51 — possible completion: all criteria checked, issue still open
<!-- triage-entry:51 -->
- Evidence: all 2 criteria ticked, issue still open.
- Suggested action: confirm delivery; close as completed, or untick what is
  not actually done.
MD
[ "$(run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$cc_entries")" = 0 ] ||
    fail "completion-candidate report sync failed: $(cat "$tmp/out")"
grep -q "triage-entry:51" "$tmp/out" ||
    fail "surviving completion candidate must stay in the report body"
grep -q "triage-entry:50" "$tmp/out" &&
    fail "a completion candidate no longer present must not linger in the body"

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
grep -q '^TRIAGE_SCRATCH=/' "$GH_STUB_LOG" || fail "run must bind a scratch dir"
scratch_val="$(grep -m1 '^TRIAGE_SCRATCH=' "$GH_STUB_LOG" | cut -d= -f2-)"
expected_grant="Edit(//${scratch_val#/}/**)"
# Anchored on the leading comma the wrapper always emits before the grant
# (tools="$tools,Edit(...)"), so a MultiEdit(...)/NotebookEdit(...) grant —
# which has no comma directly before "Edit(" — cannot satisfy this on its
# own; no separate denylist needed (challenge round 2 finding).
grep -qF -- ",$expected_grant" "$GH_STUB_LOG" ||
    fail "worker Edit grant must be exactly scratch-scoped"
grep -q -- "Write(//" "$GH_STUB_LOG" &&
    fail "worker must not be granted a Write(path) rule (Claude Code does not honor it)"
grep -q -- "Read(//" "$GH_STUB_LOG" ||
    fail "worker Read grant must be path-scoped"
grep -qE "ARGS: .*(Glob|Grep)" "$GH_STUB_LOG" &&
    fail "worker must not be granted Glob/Grep"
grep -q -- "--tools Read,Write,Bash" "$GH_STUB_LOG" ||
    fail "worker must run with a restricted built-in tool set"
grep -q 'labels, native Issue Types, and the rolling report' "$wrapper" ||
    fail "execute confirmation must disclose native Issue Type writes"
grep -q 'native Issue Types: <n> applied|would-apply' \
    ai/skills/universal/triage/SKILL.md ||
    fail "final summary must account for native Issue Type writes"

echo "==> wrapper: --execute without a terminal is refused"
[ "$(run "$wrapper" --execute)" = 2 ] ||
    fail "non-interactive --execute must exit 2"

# ── references ───────────────────────────────────────────────────────────────
# ── Impact / Risk / Complexity / Priority (AI) / Tier (harmon-devkit#1250) ────
# The fixture vocabulary is built here: harmon-devkit's own registry does not
# provision these families, and the target repository's live labels (personal
# accounts) or issue fields (organizations) are what triage reads.
cp "$stub_dir/labels.json" "$tmp/labels-before-classification.json"
jq -n '[("needs-triage", "bug", "feature",
         "area:ci", "area:tasks", "area:none", "layer:ui", "layer:api",
         "layer:none", "domain:auth", "domain:delivery", "domain:none",
         ("minimal", "low", "medium", "high", "massive" | "impact:\(.)"),
         ("trivial", "low", "medium", "high", "critical" | "risk:\(.)"),
         ("xs", "s", "m", "l", "xl" | "complexity:\(.)"),
         ("p0", "p1", "p2", "p3", "p4" | "priority-ai:\(.)"),
         ("urgent", "high", "medium", "low" | "priority:\(.)"),
         ("local", "economy", "standard", "frontier", "apex" | "tier:\(.)"),
         "tier:pinned")
        | {name: ., description: ""}]' >"$stub_dir/labels.json"
# A policy WITH [tier.matrix] (the conformance corpus base), one without it,
# and one that does not exist (the built-in fallback derives no Tier).
policy="ai/schemas/fixtures/devflow-conformance/policy.toml"
[ -f "$policy" ] || fail "the conformance base policy fixture is missing"
no_matrix_policy="$tmp/no-matrix.toml"
awk '/^\[tier\.matrix\]/{skip=1; next} skip && /^\[/{skip=0} !skip' \
    "$policy" >"$no_matrix_policy"
grep -q '^\[tier\.matrix\]' "$no_matrix_policy" &&
    fail "could not strip [tier.matrix] from the policy fixture"

# issue_fixture N LABEL... — one issue's labels.
issue_fixture() {
    local n="$1"
    shift
    jq -n '{labels: [$ARGS.positional[] | {name: .}], body: "plain"}' \
        --args "$@" >"$stub_dir/issue-$n.json"
}
classified="bug area:ci layer:ui domain:auth"
# shellcheck disable=SC2086 # word-split on purpose: the label list
issue_fixture 60 $classified needs-triage
# shellcheck disable=SC2086
issue_fixture 61 $classified needs-triage tier:pinned tier:local
# shellcheck disable=SC2086
issue_fixture 62 $classified impact:low complexity:m tier:local
# shellcheck disable=SC2086
issue_fixture 63 bug
# shellcheck disable=SC2086
issue_fixture 64 $classified impact:low risk:low complexity:s tier:economy
# shellcheck disable=SC2086
issue_fixture 65 $classified impact:low risk:low complexity:s priority-ai:p2
# shellcheck disable=SC2086
issue_fixture 66 $classified impact:low complexity:s priority-ai:p2
# shellcheck disable=SC2086
issue_fixture 67 $classified impact:low complexity:s priority-ai:p2 priority:high
# shellcheck disable=SC2086
issue_fixture 68 $classified needs-triage priority:medium
# shellcheck disable=SC2086
issue_fixture 69 $classified impact:low risk:low complexity:s needs-triage

echo "==> classification-axes: a personal repo provisions its axes as labels"
[ "$(run "$apply" classification-axes --repo "$repo")" = 0 ] ||
    fail "classification-axes failed: $(cat "$tmp/out")"
jq -e '.storage == "label" and .required == ["impact", "risk", "complexity"]
       and .axes.risk.values == ["trivial", "low", "medium", "high", "critical"]
       and .axes["priority-ai"].provisioned
       and .tier_values == ["local", "economy", "standard", "frontier", "apex"]' \
    "$tmp/out" >/dev/null || fail "personal classification-axes: $(cat "$tmp/out")"

echo "==> label: personal repo writes the axes as labels and derives the Tier"
: >"$GH_STUB_LOG"
[ "$(run "$apply" label --repo "$repo" --issue 60 --impact high --risk high \
    --complexity m --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "personal axes dry-run failed: $(cat "$tmp/out")"
for l in impact:high risk:high complexity:m tier:frontier; do
    grep -q "DRY-RUN would add '$l' to $repo#60" "$tmp/out" ||
        fail "personal dry-run must add $l: $(cat "$tmp/out")"
done
grep -q "tier: derived 'frontier' from Risk high × Complexity m" "$tmp/out" ||
    fail "the derivation must be reported"
grep -q "DRY-RUN would remove 'needs-triage'" "$tmp/out" ||
    fail "a complete required set must derive the needs-triage removal"
grep -q "issue field" "$tmp/out" && fail "a personal repo has no issue fields"
grep -q "issue edit" "$GH_STUB_LOG" && fail "dry-run must not edit"
: >"$GH_STUB_LOG"
rm -f "$stub_dir/field-mutations.log"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 60 \
    --impact high --risk high --complexity m --execute \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "personal axes execute failed: $(cat "$tmp/out")"
grep -qx "issue edit 60 --repo $repo --add-label impact:high,risk:high,complexity:m,tier:frontier" \
    "$GH_STUB_LOG" || fail "one label edit must carry the axes and the Tier: $(cat "$GH_STUB_LOG")"
grep -qx "issue edit 60 --repo $repo --remove-label needs-triage" "$GH_STUB_LOG" ||
    fail "the derived needs-triage removal must be its own, last edit"
[ ! -e "$stub_dir/field-mutations.log" ] ||
    fail "a personal repo must never call setIssueFieldValue"

echo "==> label: --add <axis>:<value> takes the same owner-type path"
[ "$(run "$apply" label --repo "$repo" --issue 60 --add impact:high \
    --add risk:high --add complexity:m --manifest "$manifest" \
    --policy "$policy")" = 0 ] || fail "--add axis form failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'tier:frontier'" "$tmp/out" ||
    fail "the --add form must derive the Tier like the flag form"
[ "$(run "$apply" label --repo "$repo" --issue 60 --add risk:high \
    --risk low --manifest "$manifest")" = 2 ] ||
    fail "two different values for one axis must exit 2"

echo "==> label: tier:pinned — the Tier is never written, needs-triage still is"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 61 \
    --impact high --risk high --complexity m --execute \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "pinned execute failed: $(cat "$tmp/out")"
grep -q "carries tier:pinned — the Tier label is left as it is" "$tmp/out" ||
    fail "the pinned skip must be reported"
grep -q -- "tier:" "$GH_STUB_LOG" &&
    fail "a pinned issue must never have a tier label written or removed: $(cat "$GH_STUB_LOG")"
grep -qx "issue edit 61 --repo $repo --remove-label needs-triage" "$GH_STUB_LOG" ||
    fail "a pinned issue still has needs-triage derived"

echo "==> label: a pin applied before the snapshot holds the Tier"
rm -f "$stub_dir"/.label-reads-*
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_LABELS_CHANGE_ON_READ=2 \
    GH_STUB_LABELS_CHANGE_ADD="tier:pinned" "$apply" label --repo "$repo" \
    --issue 60 --impact high --risk high --complexity m --execute \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "mid-call pin execute failed: $(cat "$tmp/out")"
grep -q "carries tier:pinned — the Tier label is left as it is" "$tmp/out" ||
    fail "the snapshot must see a pin set after the first read: $(cat "$tmp/out")"
grep -q -- "tier:frontier" "$GH_STUB_LOG" &&
    fail "a pin landing mid-call must stop the Tier write"
grep -q -- "--add-label impact:high,risk:high,complexity:m" "$GH_STUB_LOG" ||
    fail "the axes are still written when the Tier is skipped"
rm -f "$stub_dir"/.label-reads-*
# shellcheck disable=SC2086 # restore #60 (the knob edited its fixture)
issue_fixture 60 $classified needs-triage

echo "==> label: a stale derived Tier is replaced, never stacked"
[ "$(run "$apply" label --repo "$repo" --issue 62 --risk high \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "stale tier dry-run failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'tier:frontier'" "$tmp/out" ||
    fail "the derived Tier must be added"
grep -q "DRY-RUN would remove 'tier:local' from $repo#62" "$tmp/out" ||
    fail "the stale Tier label must be removed in the same call"

echo "==> label: an underivable Tier is reported and the axes are still written"
[ "$(run "$apply" label --repo "$repo" --issue 62 --risk high \
    --manifest "$manifest" --policy "$no_matrix_policy")" = 0 ] ||
    fail "no-matrix dry-run failed: $(cat "$tmp/out")"
grep -q "tier: not written — the governing policy has no \[tier.matrix\]" \
    "$tmp/out" || fail "a missing matrix must be reported: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'risk:high'" "$tmp/out" ||
    fail "the axis is still written without a Tier"
grep -q "DRY-RUN would add 'tier:" "$tmp/out" &&
    fail "no Tier may be written without a matrix"
[ "$(run "$apply" label --repo "$repo" --issue 62 --risk high \
    --manifest "$manifest" --policy "$tmp/absent.toml")" = 0 ] ||
    fail "absent-policy dry-run failed: $(cat "$tmp/out")"
grep -q "tier: not written — no .devflow.toml" "$tmp/out" ||
    fail "an absent policy derives no Tier: $(cat "$tmp/out")"
grep -q 'devflow-policy.mjs' "$apply" ||
    fail "triage-apply.sh must derive the Tier by calling devflow-policy.mjs"
grep -qE 'xs.*local.*local.*economy' "$apply" &&
    fail "triage-apply.sh must not carry its own copy of the matrix"
[ "$(run "$standalone_triage/triage/assets/triage-apply.sh" label \
    --repo "$repo" --issue 62 --risk high --manifest "$manifest" \
    --policy "$policy")" = 0 ] ||
    fail "standalone triage without dev-flow-support must still apply: $(cat "$tmp/out")"
grep -q "tier: not written — the dev-flow-support skill is not vendored" \
    "$tmp/out" || fail "a missing resolver must be reported: $(cat "$tmp/out")"

echo "==> label: the axes are filled, never re-rated, and stay on the scale"
[ "$(run "$apply" label --repo "$repo" --issue 64 --risk high \
    --manifest "$manifest" --policy "$policy")" = 4 ] ||
    fail "a different existing Risk must exit 4"
grep -q "never re-rates" "$tmp/out" || fail "the refusal must say why"
[ "$(run "$apply" label --repo "$repo" --issue 64 --risk low \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "the same value must be a no-op"
grep -q "nothing to do" "$tmp/out" || fail "the same value writes nothing"
[ "$(run "$apply" label --repo "$repo" --issue 63 --risk extreme \
    --manifest "$manifest")" = 4 ] || fail "an off-scale value must exit 4"
jq 'map(select(.name != "risk:critical"))' "$stub_dir/labels.json" \
    >"$tmp/labels-full.json"
cp "$stub_dir/labels.json" "$tmp/labels-keep.json"
cp "$tmp/labels-full.json" "$stub_dir/labels.json"
[ "$(run "$apply" label --repo "$repo" --issue 63 --risk critical \
    --manifest "$manifest")" = 4 ] || fail "an unprovisioned value must exit 4"
cp "$tmp/labels-keep.json" "$stub_dir/labels.json"
[ "$(run "$apply" label --repo "$repo" --issue 63 --add tier:standard \
    --manifest "$manifest")" = 4 ] || fail "a caller-chosen Tier must exit 4"
grep -q "the Tier is derived" "$tmp/out" || fail "the refusal must say why"

echo "==> label: a possibly-truncated live label list refuses, never derives"
cp "$stub_dir/labels.json" "$tmp/labels-keep.json"
jq -n '[range(1000)] | map({name: ("bulk-\(.)"), description: ""})' \
    >"$stub_dir/labels.json"
[ "$(run "$apply" label --repo "$repo" --issue 69 --add area:ci \
    --manifest "$manifest")" = 2 ] ||
    fail "a 1000-label page must refuse, not read the axes as unprovisioned"
grep -q "DRY-RUN would remove 'needs-triage'" "$tmp/out" &&
    fail "a truncated vocabulary must never derive a needs-triage removal"
cp "$tmp/labels-keep.json" "$stub_dir/labels.json"

echo "==> label: needs-triage is derived from the required set"
[ "$(run "$apply" label --repo "$repo" --issue 63 --add area:ci \
    --manifest "$manifest")" = 0 ] || fail "derived add failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'needs-triage' to $repo#63" "$tmp/out" ||
    fail "an incomplete issue without needs-triage must have it derived"
grep -q "needs-triage: derived — missing: .*impact (unset)" "$tmp/out" ||
    fail "the derivation must name what is missing: $(cat "$tmp/out")"
[ "$(run "$apply" label --repo "$repo" --issue 64 --add needs-triage \
    --manifest "$manifest")" = 6 ] ||
    fail "an explicit add on a complete issue must exit 6"
[ "$(run "$apply" label --repo "$repo" --issue 60 --remove needs-triage \
    --manifest "$manifest")" = 6 ] ||
    fail "a removal with Impact/Risk/Complexity unset must exit 6"
grep -q "risk (unset)" "$tmp/out" || fail "the refusal must name the axis"
[ "$(run "$apply" label --repo "$repo" --issue 69 --remove needs-triage \
    --manifest "$manifest")" = 0 ] ||
    fail "a removal on a complete issue must pass: $(cat "$tmp/out")"

echo "==> label: --reconcile writes only the derived needs-triage and Tier"
[ "$(run "$apply" label --repo "$repo" --issue 63 \
    --manifest "$manifest")" = 2 ] ||
    fail "a call with no request and no --reconcile must still exit 2"
[ "$(run "$apply" label --repo "$repo" --issue 63 --reconcile \
    --manifest "$manifest")" = 0 ] || fail "reconcile add failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'needs-triage' to $repo#63" "$tmp/out" ||
    fail "an incomplete, unmarked issue must get needs-triage from --reconcile"
[ "$(grep -c "DRY-RUN" "$tmp/out")" = 1 ] ||
    fail "--reconcile must write nothing else here: $(cat "$tmp/out")"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 69 \
    --reconcile --execute --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "reconcile removal failed: $(cat "$tmp/out")"
grep -qx "issue edit 69 --repo $repo --remove-label needs-triage" "$GH_STUB_LOG" ||
    fail "a complete, marked issue must lose needs-triage through --reconcile"
grep -qx "issue edit 69 --repo $repo --add-label tier:economy" "$GH_STUB_LOG" ||
    fail "--reconcile must also write the missing derived Tier: $(cat "$GH_STUB_LOG")"

echo "==> label: a missing or stale Tier is derived when Risk and Complexity are set"
# shellcheck disable=SC2086
issue_fixture 74 $classified impact:low risk:high complexity:m tier:local
[ "$(run "$apply" label --repo "$repo" --issue 74 --reconcile \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "stale-tier reconcile failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'tier:frontier' to $repo#74" "$tmp/out" &&
    grep -q "DRY-RUN would remove 'tier:local' from $repo#74" "$tmp/out" ||
    fail "a stale Tier must be repaired without writing an axis: $(cat "$tmp/out")"
[ "$(run "$apply" label --repo "$repo" --issue 74 --add priority-ai:p2 \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "stale-tier beside another write failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'tier:frontier'" "$tmp/out" ||
    fail "any call that leaves Risk and Complexity set repairs the Tier"
# shellcheck disable=SC2086
issue_fixture 75 $classified impact:low risk:high complexity:m tier:local tier:pinned
[ "$(run "$apply" label --repo "$repo" --issue 75 --reconcile \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "pinned reconcile failed: $(cat "$tmp/out")"
grep -q "would add 'tier:\|would remove 'tier:" "$tmp/out" &&
    fail "--reconcile must never touch a pinned Tier"
grep -q "carries tier:pinned" "$tmp/out" || fail "the pin must be reported"

echo "==> label: the snapshot sees a personal label set after the first read"
# shellcheck disable=SC2086
issue_fixture 78 $classified impact:low risk:high complexity:m
rm -f "$stub_dir"/.label-reads-*
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_LABELS_CHANGE_ON_READ=2 \
    GH_STUB_LABELS_CHANGE_ADD="tier:apex" "$apply" label --repo "$repo" \
    --issue 78 --reconcile --execute --manifest "$manifest" \
    --policy "$policy")" = 0 ] || fail "snapshot tier run failed: $(cat "$tmp/out")"
grep -qx "issue edit 78 --repo $repo --add-label tier:frontier --remove-label tier:apex" \
    "$GH_STUB_LOG" ||
    fail "an unpinned tier label added before the snapshot must be replaced: $(cat "$GH_STUB_LOG")"
# shellcheck disable=SC2086
issue_fixture 79 $classified impact:low complexity:m needs-triage
rm -f "$stub_dir"/.label-reads-*
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_LABELS_CHANGE_ON_READ=2 \
    GH_STUB_LABELS_CHANGE_ADD="risk:low" "$apply" label --repo "$repo" \
    --issue 79 --risk high --execute --manifest "$manifest" \
    --policy "$policy")" = 4 ] ||
    fail "a written personal axis set before the snapshot must refuse: $(cat "$tmp/out")"
grep -q "risk:\* labels changed while triage was preparing its write" "$tmp/out" ||
    fail "the refusal must name the axis: $(cat "$tmp/out")"
grep -q "issue edit" "$GH_STUB_LOG" && fail "no write may follow the refusal"
rm -f "$stub_dir"/.label-reads-*

echo "==> label: the derived Tier write removes every other unqualified tier label"
# shellcheck disable=SC2086
issue_fixture 88 $classified impact:low risk:high complexity:m tier:adaptive
[ "$(run "$apply" label --repo "$repo" --issue 88 --reconcile \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "lone tier:adaptive reconcile failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'tier:frontier' to $repo#88" "$tmp/out" &&
    grep -q "DRY-RUN would remove 'tier:adaptive' from $repo#88" "$tmp/out" ||
    fail "a lone retired tier:adaptive must give way to the derived Tier: $(cat "$tmp/out")"
# shellcheck disable=SC2086
issue_fixture 89 $classified impact:low risk:high complexity:m tier:adaptive \
    tier:local tier:reviewer:apex
[ "$(run "$apply" label --repo "$repo" --issue 89 --reconcile \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "tier:adaptive beside a rung reconcile failed: $(cat "$tmp/out")"
for l in tier:adaptive tier:local; do
    grep -q "DRY-RUN would remove '$l' from $repo#89" "$tmp/out" ||
        fail "$l must be removed beside the derived Tier: $(cat "$tmp/out")"
done
grep -q "DRY-RUN would add 'tier:frontier' to $repo#89" "$tmp/out" ||
    fail "the derived Tier must be added"
grep -q "tier:reviewer:apex" "$tmp/out" &&
    fail "a scoped tier:<role>:* override is never touched"

echo "==> label: a comma-bearing label read back into a removal is refused"
# shellcheck disable=SC2086
issue_fixture 93 $classified impact:low complexity:s "priority-ai:x,tier:pinned"
: >"$GH_STUB_LOG"
[ "$(run "$apply" label --repo "$repo" --issue 93 --risk high \
    --priority-ai p1 --manifest "$manifest" --policy "$policy")" = 4 ] ||
    fail "a comma-bearing removal must exit 4: $(cat "$tmp/out")"
grep -q "contains a comma — gh would split its removal" "$tmp/out" ||
    fail "the refusal must say why: $(cat "$tmp/out")"
grep -q "issue edit" "$GH_STUB_LOG" && fail "no write may follow the refusal"

echo "==> label: replacement may never indirectly drop human through a comma label"
# shellcheck disable=SC2086
issue_fixture 93 $classified impact:low complexity:s human "priority-ai:x,human"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 93 \
    --risk high --priority-ai p1 --execute --manifest "$manifest" --policy "$policy")" = 4 ] ||
    fail "replacement that could split off human must refuse: $(cat "$tmp/out")"
grep -q '^issue edit' "$GH_STUB_LOG" && fail "unsafe human replacement must make no writes"

echo "==> label: a conflicting Priority (AI) keeps the requested value, removes the rest"
# shellcheck disable=SC2086
issue_fixture 94 $classified impact:low complexity:s priority-ai:p1 \
    priority-ai:p3 needs-triage
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 94 \
    --risk high --priority-ai p1 --execute --manifest "$manifest" \
    --policy "$policy")" = 0 ] || fail "PAI conflict replace failed: $(cat "$tmp/out")"
pai_edit="$(grep '^issue edit 94 .*--remove-label' "$GH_STUB_LOG" |
    grep -v -- '--remove-label needs-triage$' || true)"
[ -n "$pai_edit" ] || fail "the replacement must remove a label: $(cat "$GH_STUB_LOG")"
removed="${pai_edit##*--remove-label }"
added="${pai_edit#*--add-label }"
added="${added%% --remove-label*}"
[ ",$removed," = ",priority-ai:p3," ] ||
    fail "only the other value p3 may be removed, never p1: $pai_edit"
grep -q ',priority-ai:p1,' <<<",$added," ||
    fail "the requested p1 must be added or kept: $pai_edit"
grep -qx "issue edit 94 --repo $repo --remove-label needs-triage" "$GH_STUB_LOG" ||
    fail "the call completes: the re-plan sees exactly one priority-ai label"

echo "==> label: Priority (AI) — set with the axes, kept, replaced, never human"
[ "$(run "$apply" label --repo "$repo" --issue 60 --impact high --risk high \
    --complexity m --priority-ai p1 --manifest "$manifest" \
    --policy "$policy")" = 0 ] || fail "PAI dry-run failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'priority-ai:p1'" "$tmp/out" ||
    fail "Priority (AI) must be set alongside the axes"
[ "$(run "$apply" label --repo "$repo" --issue 63 --priority-ai p1 \
    --manifest "$manifest")" = 6 ] ||
    fail "Priority (AI) without complete classification must exit 6"
[ "$(run "$apply" label --repo "$repo" --issue 65 --priority-ai p1 \
    --manifest "$manifest")" = 0 ] || fail "PAI keep failed: $(cat "$tmp/out")"
grep -q "Priority (AI) 'p2' kept on $repo#65 — this call did not change the classification" \
    "$tmp/out" || fail "an unchanged classification keeps Priority (AI)"
grep -q "would add 'priority-ai" "$tmp/out" && fail "a kept PAI is not written"
[ "$(run "$apply" label --repo "$repo" --issue 66 --risk high \
    --priority-ai p1 --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "PAI replace failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'priority-ai:p1'" "$tmp/out" &&
    grep -q "DRY-RUN would remove 'priority-ai:p2'" "$tmp/out" ||
    fail "a changed classification with no human Priority replaces PAI: $(cat "$tmp/out")"
[ "$(run "$apply" label --repo "$repo" --issue 67 --risk high \
    --priority-ai p1 --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "PAI human-present failed: $(cat "$tmp/out")"
grep -q "human Priority 'high' is set on $repo#67 — reported, not changed" \
    "$tmp/out" || fail "a human Priority must be reported"
grep -q "Priority (AI) 'p2' kept on $repo#67 — a human Priority is set" \
    "$tmp/out" || fail "a human Priority keeps Priority (AI)"
grep -q "'priority:" "$tmp/out" && fail "the human Priority is never written"
[ "$(run "$apply" label --repo "$repo" --issue 68 --impact high --risk high \
    --complexity m --priority-ai p2 --manifest "$manifest" \
    --policy "$policy")" = 0 ] || fail "PAI beside human failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'priority-ai:p2'" "$tmp/out" &&
    grep -q "human Priority 'medium' is set on $repo#68" "$tmp/out" ||
    fail "an unset PAI is set and the human Priority reported: $(cat "$tmp/out")"

echo "==> never-list: suggest:* is gone from the vocabulary"
grep -q 'suggest' "$apply" && fail "triage-apply.sh must not mention suggest:*"
grep -q 'suggest:' ai/skills/universal/triage/SKILL.md &&
    fail "SKILL.md must not mention suggest:*"

# ── organization: issue fields, never the same-named labels ──────────────────
GH_STUB_OWNER_TYPE="Organization"
export GH_STUB_NATIVE_TYPE="Bug"
field_opts() {
    jq -n --arg p "$1" '[$ARGS.positional[] | {id: "\($p)_\(.)", name: .}]' \
        --args "${@:2}"
}
jq -n --argjson impact "$(field_opts OI minimal low medium high massive)" \
    --argjson risk "$(field_opts OR trivial low medium high critical)" \
    --argjson complexity "$(field_opts OC xs s m l xl)" \
    --argjson pai "$(field_opts OP p0 p1 p2 p3 p4)" \
    --argjson human "$(field_opts OH Urgent High Medium Low)" '[
      {id: "F_impact", name: "Impact", options: $impact},
      {id: "F_risk", name: "Risk", options: $risk},
      {id: "F_complexity", name: "Complexity", options: $complexity},
      {id: "F_pai", name: "Priority (AI)", options: $pai},
      {id: "F_priority", name: "Priority", options: $human}]' \
    >"$stub_dir/issue-fields.json"
# Stray same-named labels on an org: inert, never counted, never written.
issue_fixture 70 area:ci layer:ui domain:auth needs-triage risk:high \
    impact:high complexity:m
issue_fixture 72 area:ci layer:ui domain:auth needs-triage tier:pinned \
    tier:economy
issue_fixture 73 area:ci layer:ui domain:auth needs-triage
echo '{"Priority": "High"}' >"$stub_dir/issue-fields-73.json"
rm -f "$stub_dir"/issue-fields-70.json "$stub_dir"/issue-fields-72.json

echo "==> classification-axes: an organization provisions its axes as fields"
[ "$(run "$apply" classification-axes --repo "$repo")" = 0 ] ||
    fail "org classification-axes failed: $(cat "$tmp/out")"
jq -e '.storage == "field" and .required == ["impact", "risk", "complexity"]
       and .axes.impact.field == "Impact"
       and .axes.complexity.values == ["xs", "s", "m", "l", "xl"]' \
    "$tmp/out" >/dev/null || fail "org classification-axes: $(cat "$tmp/out")"

echo "==> label: an org stray axis label never counts as the axis being set"
[ "$(run "$apply" label --repo "$repo" --issue 70 --remove needs-triage \
    --manifest "$manifest")" = 6 ] ||
    fail "stray labels must not satisfy the required set on an org"
grep -q "impact (unset)" "$tmp/out" || fail "the refusal must name the field"

echo "==> label: an org writes the axes as issue fields, the Tier as a label"
[ "$(run "$apply" label --repo "$repo" --issue 70 --impact high \
    --add risk:high --complexity m --manifest "$manifest" \
    --policy "$policy")" = 0 ] || fail "org dry-run failed: $(cat "$tmp/out")"
for f in "Impact' to 'high" "Risk' to 'high" "Complexity' to 'm"; do
    grep -q "DRY-RUN would set issue field '$f'" "$tmp/out" ||
        fail "org dry-run must set the field $f: $(cat "$tmp/out")"
done
grep -qE "would add '(impact|risk|complexity):" "$tmp/out" &&
    fail "an org must never write the inert axis labels"
grep -q "DRY-RUN would add 'tier:frontier'" "$tmp/out" ||
    fail "the Tier is a label on an org too"
: >"$GH_STUB_LOG"
rm -f "$stub_dir/field-mutations.log"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 70 \
    --impact high --risk high --complexity m --execute \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "org execute failed: $(cat "$tmp/out")"
[ "$(wc -l <"$stub_dir/field-mutations.log")" = 1 ] ||
    fail "every org axis write must be ONE setIssueFieldValue mutation"
jq -e '.variables.issue == "I_70"
       and (.variables.fields | sort_by(.fieldId)) == [
         {fieldId: "F_complexity", singleSelectOptionId: "OC_m"},
         {fieldId: "F_impact", singleSelectOptionId: "OI_high"},
         {fieldId: "F_risk", singleSelectOptionId: "OR_high"}]' \
    "$stub_dir/field-mutations.log" >/dev/null ||
    fail "the mutation must carry the three fields: $(cat "$stub_dir/field-mutations.log")"
jq -e '. == {"Impact": "high", "Risk": "high", "Complexity": "m"}' \
    "$stub_dir/issue-fields-70.json" >/dev/null || fail "the fields were not set"
grep -q "APPLIED issue field 'Risk' = 'high' on $repo#70" "$tmp/out" ||
    fail "the verified field write must be reported"
grep -qx "issue edit 70 --repo $repo --add-label tier:frontier" "$GH_STUB_LOG" ||
    fail "the org label edit carries only the Tier: $(cat "$GH_STUB_LOG")"
grep -qx "issue edit 70 --repo $repo --remove-label needs-triage" "$GH_STUB_LOG" ||
    fail "a complete org issue has needs-triage derived away"

echo "==> label: an org pinned issue gets its fields, never a Tier label"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 72 \
    --impact high --risk high --complexity m --execute \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "org pinned execute failed: $(cat "$tmp/out")"
grep -q -- "tier:" "$GH_STUB_LOG" && fail "an org pin must hold the Tier"
grep -q "APPLIED issue field 'Impact' = 'high' on $repo#72" "$tmp/out" ||
    fail "a pinned org issue still gets its fields"

echo "==> label: an org human Priority field is reported and never written"
rm -f "$stub_dir/field-mutations.log"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 73 \
    --impact low --risk low --complexity s --priority-ai p2 --execute \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "org PAI execute failed: $(cat "$tmp/out")"
grep -q "human Priority 'High' is set on $repo#73 — reported, not changed" \
    "$tmp/out" || fail "the org human Priority must be reported"
grep -q '"F_priority"' "$stub_dir/field-mutations.log" &&
    fail "the human Priority field must never be written"
jq -e '.["Priority (AI)"] == "p2" and .Priority == "High"' \
    "$stub_dir/issue-fields-73.json" >/dev/null ||
    fail "Priority (AI) set, human Priority untouched"

echo "==> label: an unreadable org Type still adds needs-triage when something is missing"
issue_fixture 76 area:ci
[ "$(run env GH_STUB_NATIVE_TYPE=ERROR "$apply" label --repo "$repo" \
    --issue 76 --reconcile --manifest "$manifest")" = 0 ] ||
    fail "indeterminate-Type reconcile failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'needs-triage' to $repo#76" "$tmp/out" ||
    fail "a known gap must add needs-triage even when the Type is unreadable"
[ "$(run env GH_STUB_NATIVE_TYPE=ERROR "$apply" label --repo "$repo" \
    --issue 76 --remove needs-triage --manifest "$manifest")" = 6 ] ||
    fail "a removal still needs the Type proven"

echo "==> label: an org field changed before the mutation refuses (fill-only)"
rm -f "$stub_dir/issue-fields-70.json" "$stub_dir"/.field-reads-*
: >"$GH_STUB_LOG"
rm -f "$stub_dir/field-mutations.log"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_FIELDS_CHANGE_ON_READ=2 \
    GH_STUB_FIELDS_CHANGE_JSON='{"Risk": "low"}' "$apply" label \
    --repo "$repo" --issue 70 --impact high --risk high --complexity m \
    --execute --manifest "$manifest" --policy "$policy")" = 4 ] ||
    fail "a field set between the reads must refuse: $(cat "$tmp/out")"
grep -q "issue field 'Risk' changed while triage was preparing its write" \
    "$tmp/out" || fail "the refusal must name the field"
[ ! -e "$stub_dir/field-mutations.log" ] ||
    fail "no mutation may follow a changed field"
grep -q -- "--add-label\|--remove-label" "$GH_STUB_LOG" &&
    fail "no label may follow a changed field"
issue_fixture 77 area:ci layer:ui domain:auth
echo '{"Impact": "low", "Complexity": "s", "Priority (AI)": "p2"}' \
    >"$stub_dir/issue-fields-77.json"
rm -f "$stub_dir"/.field-reads-* "$stub_dir/field-mutations.log"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_FIELDS_CHANGE_ON_READ=2 \
    GH_STUB_FIELDS_CHANGE_JSON='{"Priority": "High"}' "$apply" label \
    --repo "$repo" --issue 77 --risk high --priority-ai p1 --execute \
    --manifest "$manifest" --policy "$policy")" = 4 ] ||
    fail "a human Priority set before a PAI replacement must refuse: $(cat "$tmp/out")"
grep -q "human Priority was set on $repo#77" "$tmp/out" ||
    fail "the refusal must name the human Priority"
[ ! -e "$stub_dir/field-mutations.log" ] ||
    fail "no mutation may follow the human Priority appearing"
rm -f "$stub_dir"/.field-reads-* "$stub_dir/issue-fields-77.json"

echo "==> label: an unwritten org field cleared before the snapshot keeps needs-triage"
issue_fixture 71 area:ci layer:ui domain:auth needs-triage tier:economy
echo '{"Impact": "low", "Risk": "low", "Complexity": "s"}' \
    >"$stub_dir/issue-fields-71.json"
rm -f "$stub_dir"/.field-reads-*
[ "$(run "$apply" label --repo "$repo" --issue 71 --reconcile \
    --manifest "$manifest" --policy "$policy")" = 0 ] ||
    fail "complete org reconcile dry-run failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would remove 'needs-triage'" "$tmp/out" ||
    fail "the first read is complete, so a removal is planned"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_FIELDS_CHANGE_ON_READ=2 \
    GH_STUB_FIELDS_CHANGE_JSON='{"Complexity": null}' "$apply" label \
    --repo "$repo" --issue 71 --reconcile --execute --manifest "$manifest" \
    --policy "$policy")" = 0 ] || fail "cleared-field reconcile failed: $(cat "$tmp/out")"
grep -q -- "--remove-label needs-triage" "$GH_STUB_LOG" &&
    fail "a field cleared before the snapshot must keep needs-triage: $(cat "$GH_STUB_LOG")"
rm -f "$stub_dir"/.field-reads-* "$stub_dir/issue-fields-71.json"

echo "==> label: a fresh read before every org mutation catches a change between writes"
# (1) tier:pinned set between the field mutation and the label edit.
issue_fixture 85 area:ci layer:ui domain:auth needs-triage
rm -f "$stub_dir"/.label-reads-* "$stub_dir"/.field-reads-* \
    "$stub_dir/field-mutations.log" "$stub_dir/issue-fields-85.json"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_LABELS_CHANGE_ON_READ=3 \
    GH_STUB_LABELS_CHANGE_ADD="tier:pinned" "$apply" label --repo "$repo" \
    --issue 85 --impact high --risk high --complexity m --execute \
    --manifest "$manifest" --policy "$policy")" = 4 ] ||
    fail "a pin set between org writes must refuse: $(cat "$tmp/out")"
grep -q "tier:pinned was added to $repo#85 between triage's writes" "$tmp/out" ||
    fail "the refusal must name the pin: $(cat "$tmp/out")"
[ "$(wc -l <"$stub_dir/field-mutations.log")" = 1 ] ||
    fail "the field mutation before the pin was the one write made"
grep -q -- "--add-label\|--remove-label" "$GH_STUB_LOG" &&
    fail "no label write may follow the pin: $(cat "$GH_STUB_LOG")"
# (2) a field value set between the needs-triage marker and the field write.
issue_fixture 86 area:ci layer:ui
rm -f "$stub_dir"/.label-reads-* "$stub_dir"/.field-reads-* \
    "$stub_dir/field-mutations.log" "$stub_dir/issue-fields-86.json"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_FIELDS_CHANGE_ON_READ=3 \
    GH_STUB_FIELDS_CHANGE_JSON='{"Risk": "low"}' "$apply" label --repo "$repo" \
    --issue 86 --impact high --risk high --complexity m --execute \
    --manifest "$manifest" --policy "$policy")" = 4 ] ||
    fail "a field set between org writes must refuse: $(cat "$tmp/out")"
grep -qx "issue edit 86 --repo $repo --add-label needs-triage" "$GH_STUB_LOG" ||
    fail "the marker was the one write made before the change"
[ ! -e "$stub_dir/field-mutations.log" ] ||
    fail "no field mutation may follow the change"
[ "$(grep -c '^issue edit 86' "$GH_STUB_LOG")" = 1 ] ||
    fail "no later label write may follow the change: $(cat "$GH_STUB_LOG")"
# (3) a native Type set between the needs-triage marker and the Type write.
issue_fixture 87 area:ci
rm -f "$stub_dir"/.label-reads-* "$stub_dir"/.field-reads-* "$stub_dir/.native-reads"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_NATIVE_TYPE="" \
    GH_STUB_NATIVE_TYPE_CHANGE_ON_READ=3 GH_STUB_NATIVE_TYPE_CHANGE_TO=Feature \
    "$apply" label --repo "$repo" --issue 87 --native-type Bug --execute \
    --manifest "$manifest")" = 4 ] ||
    fail "a Type set between org writes must refuse: $(cat "$tmp/out")"
grep -qx "issue edit 87 --repo $repo --add-label needs-triage" "$GH_STUB_LOG" ||
    fail "the marker was the one write made before the Type change: $(cat "$GH_STUB_LOG")"
grep -q -- "--type Bug" "$GH_STUB_LOG" &&
    fail "no Type write may follow a Type set by someone else"
rm -f "$stub_dir"/.label-reads-* "$stub_dir"/.field-reads-* "$stub_dir/.native-reads" \
    "$stub_dir/field-mutations.log" "$stub_dir"/issue-fields-8[56].json

echo "==> label: a write reverted between org mutations refuses (no Tier, no removal)"
issue_fixture 92 area:ci layer:ui domain:auth needs-triage
rm -f "$stub_dir"/.field-reads-* "$stub_dir/field-mutations.log" \
    "$stub_dir/issue-fields-92.json"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_FIELDS_CHANGE_ON_READ=4 \
    GH_STUB_FIELDS_CHANGE_JSON='{"Risk": null}' "$apply" label --repo "$repo" \
    --issue 92 --impact high --risk high --complexity m --execute \
    --manifest "$manifest" --policy "$policy")" = 4 ] ||
    fail "a Risk cleared after the field mutation must refuse: $(cat "$tmp/out")"
grep -q "a write it already made was reverted (field:risk=high)" "$tmp/out" ||
    fail "the refusal must name the reverted write: $(cat "$tmp/out")"
[ "$(wc -l <"$stub_dir/field-mutations.log")" = 1 ] ||
    fail "the field mutation was the one write made"
grep -q -- "tier:" "$GH_STUB_LOG" && fail "no Tier write may follow a reverted Risk"
grep -q -- "--remove-label needs-triage" "$GH_STUB_LOG" &&
    fail "no needs-triage removal may follow a reverted Risk"
rm -f "$stub_dir"/.field-reads-* "$stub_dir/field-mutations.log" \
    "$stub_dir/issue-fields-92.json"

echo "==> label: an unreadable org issue-field catalogue fails closed, actionably"
[ "$(run env GH_STUB_ISSUE_FIELDS=ERROR "$apply" label --repo "$repo" \
    --issue 73 --add area:ci --manifest "$manifest")" = 2 ] ||
    fail "a plain org label call must exit 2 without the catalogue: $(cat "$tmp/out")"
grep -q "GraphQL-Features: issue_fields" "$tmp/out" &&
    grep -q "token needs" "$tmp/out" ||
    fail "the error must name the preview and the access it needs: $(cat "$tmp/out")"

echo "==> label: an org field write failure or unverifiable write stops the labels"
rm -f "$stub_dir/issue-fields-70.json"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_FIELD_WRITE_FAIL=1 "$apply" label \
    --repo "$repo" --issue 70 --impact high --risk high --complexity m \
    --execute --manifest "$manifest" --policy "$policy")" = 1 ] ||
    fail "a failed field write must exit 1"
grep -q -- "--add-label\|--remove-label" "$GH_STUB_LOG" &&
    fail "a failed field write must not edit labels"
rm -f "$stub_dir/issue-fields-70.json" "$stub_dir/fields-unreadable"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 GH_STUB_FIELDS_UNREADABLE_AFTER_WRITE=1 \
    "$apply" label --repo "$repo" --issue 70 --impact high --risk high \
    --complexity m --execute --manifest "$manifest" --policy "$policy")" = 2 ] ||
    fail "an unverifiable field write must be indeterminate"
grep -q "write indeterminate: the issue fields may have applied" "$tmp/out" ||
    fail "the indeterminate write must be surfaced"
grep -q -- "--add-label\|--remove-label" "$GH_STUB_LOG" &&
    fail "an unverifiable field write must not edit labels"
rm -f "$stub_dir/fields-unreadable" "$stub_dir/issue-fields-70.json"

# ── scan: Impact/Risk/Complexity/Tier facts on both owner types ──────────────
cat >"$stub_dir/issues-open.json" <<'JSON'
[{"number": 80, "title": "(classification): Fully classified",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}, {"name": "impact:high"},
             {"name": "risk:high"}, {"name": "complexity:m"},
             {"name": "tier:frontier"}, {"name": "priority-ai:p1"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 81, "title": "(classification): Missing risk, pinned",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:none"},
             {"name": "domain:auth"}, {"name": "impact:low"},
             {"name": "complexity:s"}, {"name": "tier:apex"},
             {"name": "tier:pinned"}, {"name": "needs-triage"},
             {"name": "priority:high"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 82, "title": "(classification): Conflicting risk labels",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}, {"name": "impact:low"},
             {"name": "risk:low"}, {"name": "risk:high"},
             {"name": "complexity:s"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 83, "title": "(classification): Complete but still queued",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}, {"name": "impact:low"},
             {"name": "risk:low"}, {"name": "complexity:s"},
             {"name": "needs-triage"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 90, "title": "(classification): Two Priority (AI) labels",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}, {"name": "impact:low"},
             {"name": "risk:low"}, {"name": "complexity:s"},
             {"name": "tier:economy"}, {"name": "priority-ai:p1"},
             {"name": "priority-ai:p3"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 95, "title": "(classification): Only a retired tier label",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}, {"name": "impact:low"},
             {"name": "risk:low"}, {"name": "complexity:s"},
             {"name": "priority-ai:p2"}, {"name": "tier:adaptive"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 84, "title": "(classification): Two tier labels",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}, {"name": "impact:low"},
             {"name": "risk:low"}, {"name": "complexity:s"},
             {"name": "priority-ai:p2"}, {"name": "tier:local"},
             {"name": "tier:apex"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""}]
JSON
echo '[]' >"$stub_dir/issues-closed.json"
GH_STUB_OWNER_TYPE="User"
unset GH_STUB_NATIVE_TYPE

echo "==> scan: a personal repo reads the axes, Tier and pin from labels"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest" --all)" = 0 ] ||
    fail "classification scan failed: $(cat "$tmp/out")"
cp "$tmp/out" "$tmp/class-scan.json"
jq -e '.classification_axes.storage == "label" and .fields_mode == "n/a"' \
    "$tmp/class-scan.json" >/dev/null || fail "personal storage must be label"
jq -e '.open[] | select(.number == 80)
       | .classification == {storage: "label",
           impact: {state: "set", value: "high"},
           risk: {state: "set", value: "high"},
           complexity: {state: "set", value: "m"},
           priority_ai: {state: "set", value: "p1"},
           priority: null, tier: ["frontier"], tier_pinned: false}
         and .required_missing == [] and .flags == []' \
    "$tmp/class-scan.json" >/dev/null ||
    fail "#80 classification facts: $(jq -c '.open[] | select(.number == 80)' "$tmp/class-scan.json")"
jq -e '.open[] | select(.number == 81)
       | .classification.risk.state == "unset"
         and .classification.tier == ["apex"] and .classification.tier_pinned
         and .classification.priority == "high"
         and .required_missing == ["risk"]
         and (.flags | index("classification-missing:risk") != null)
         and (.flags | index("partially-classified") != null)' \
    "$tmp/class-scan.json" >/dev/null ||
    fail "#81 must report the missing Risk and the pin"
jq -e '.open[] | select(.number == 82)
       | .classification.risk.state == "conflict"
         and (.flags | index("classification-conflict:risk") != null)
         and (.flags | index("missing-needs-triage") != null)' \
    "$tmp/class-scan.json" >/dev/null || fail "#82 risk conflict must be flagged"
jq -e '.open[] | select(.number == 83)
       | .required_missing == []
         and (.flags | index("needs-triage-removable") != null)' \
    "$tmp/class-scan.json" >/dev/null || fail "#83 must read removable"
jq -e '(.open[] | select(.number == 84)
        | (.flags | index("tier-conflict") != null)
          and (.flags | index("tier-missing") == null)
          and (.flags | index("priority-ai-missing") == null))
       and (.open[] | select(.number == 81)
            | .flags | index("tier-conflict") == null)' \
    "$tmp/class-scan.json" >/dev/null ||
    fail "tier-conflict: more than one tier label on an unpinned issue only"
jq -e '(.open[] | select(.number == 90)
        | (.flags | index("priority-ai-invalid") != null)
          and .required_missing == [])
       and (.open[] | select(.number == 84)
            | .flags | index("priority-ai-invalid") == null)
       and ([.open[] | .flags[] | select(. == "native-type-unknown")]
            | length == 0)' \
    "$tmp/class-scan.json" >/dev/null ||
    fail "priority-ai-invalid: a conflicting Priority (AI), never required"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "default classification scan failed: $(cat "$tmp/out")"
jq -e '(.open[] | select(.number == 95)
        | (.flags | index("tier-invalid") != null)
          and (.flags | index("tier-missing") == null)
          and .required_missing == [])
       and (.open[] | select(.number == 84) | .flags | index("tier-invalid") == null)
       and (.open[] | select(.number == 81) | .flags | index("tier-invalid") == null)' \
    "$tmp/out" >/dev/null ||
    fail "a lone unpinned tier:adaptive must be flagged tier-invalid and stay in the default scan"
jq -e '(.open[] | select(.number == 83) | .flags | index("priority-ai-missing") != null)
       and (.open[] | select(.number == 80) | .flags | index("priority-ai-missing") == null)
       and (.open[] | select(.number == 81) | .flags | index("priority-ai-missing") == null)' \
    "$tmp/class-scan.json" >/dev/null ||
    fail "priority-ai-missing: classified, Priority (AI) provisioned and unset only"
jq -e '(.open[] | select(.number == 83) | .flags | index("tier-missing") != null)
       and (.open[] | select(.number == 80) | .flags | index("tier-missing") == null)
       and (.open[] | select(.number == 81) | .flags | index("tier-missing") == null)' \
    "$tmp/class-scan.json" >/dev/null ||
    fail "tier-missing: only Risk+Complexity set, unpinned, with no tier label"

echo "==> scan: an organization reads the axes from issue fields only"
GH_STUB_OWNER_TYPE="Organization"
jq 'map(.issueType = {name: "Bug"})' "$stub_dir/issues-open.json" \
    >"$stub_dir/issues-open-types.json"
echo '{"Impact": "High", "Risk": "high", "Complexity": "m", "Priority": "Low"}' \
    >"$stub_dir/issue-fields-80.json"
rm -f "$stub_dir"/issue-fields-8[23].json
echo '{"Impact": "huge", "Risk": "low", "Complexity": "s"}' \
    >"$stub_dir/issue-fields-81.json"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest" --all)" = 0 ] ||
    fail "org classification scan failed: $(cat "$tmp/out")"
jq -e '.classification_axes.storage == "field" and .fields_mode == "bulk"' \
    "$tmp/out" >/dev/null || fail "org storage must be field, read in bulk"
jq -e '.open[] | select(.number == 80)
       | .classification.impact == {state: "set", value: "high"}
         and .classification.priority == "Low"
         and .classification.priority_ai.state == "unset"
         and .required_missing == []' "$tmp/out" >/dev/null ||
    fail "#80 org facts must come from the fields: $(jq -c '.open[] | select(.number == 80)' "$tmp/out")"
jq -e '.open[] | select(.number == 83)
       | .required_missing == ["impact", "risk", "complexity"]
         and (.flags | index("needs-triage-removable") == null)
         and (.flags | index("partially-classified") != null)' \
    "$tmp/out" >/dev/null ||
    fail "#83: stray org labels must not count as the axes being set"
jq -e '.open[] | select(.number == 81)
       | .classification.tier_pinned and .classification.tier == ["apex"]' \
    "$tmp/out" >/dev/null || fail "the Tier and pin are labels on an org too"
jq -e '.open[] | select(.number == 81)
       | .classification.impact == {state: "unknown", value: "huge"}
         and .required_missing == ["impact"]
         and (.flags | index("classification-unknown-value:impact") != null)
         and (.flags | index("needs-triage-removable") == null)' \
    "$tmp/out" >/dev/null ||
    fail "an off-scale field value read must count as missing, as apply does"

echo "==> scan: per-issue native Type mode keeps every org issue in the scan"
mv "$stub_dir/issues-open-types.json" "$tmp/issues-open-types.keep"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "per-issue org scan failed: $(cat "$tmp/out")"
jq -e '.native_type_mode == "per-issue"
       and ([.open[].number] | sort) == [80, 81, 82, 83, 84, 90, 95]
       and ([.open[] | .flags | index("native-type-unknown") != null] | all)' \
    "$tmp/out" >/dev/null ||
    fail "an undecided native Type must flag native-type-unknown on every issue"
mv "$tmp/issues-open-types.keep" "$stub_dir/issues-open-types.json"

echo "==> scan: an unreadable org issue-field catalogue fails closed, actionably"
[ "$(run env GH_STUB_ISSUE_FIELDS=ERROR "$scan" --repo "$repo" \
    --manifest "$manifest")" = 2 ] ||
    fail "the scan must exit 2 without the catalogue: $(cat "$tmp/out")"
grep -q "GraphQL-Features: issue_fields" "$tmp/out" ||
    fail "the scan error must name the preview: $(cat "$tmp/out")"

echo "==> scan: an unreadable org field pass is unknown, never unset"
[ "$(run env GH_STUB_OPEN_FIELDS=ERROR "$scan" --repo "$repo" \
    --manifest "$manifest")" = 0 ] ||
    fail "org scan with unreadable fields failed: $(cat "$tmp/out")"
jq -e '([.open[].number] | sort) == [80, 81, 82, 83, 84, 90, 95]
       and ([.open[] | .flags | index("classification-unreadable") != null]
            | all)' "$tmp/out" >/dev/null ||
    fail "every issue whose fields were not read must stay in open[], flagged"
jq -e '.fields_mode == "unknown"
       and ([.open[] | .classification.risk.state] | unique) == ["unknown"]
       and ([.open[] | .flags[] | select(. == "needs-triage-removable"
             or startswith("classification-missing:"))] | length == 0)' \
    "$tmp/out" >/dev/null ||
    fail "unread fields must not read as missing or removable"
rm -f "$stub_dir/issues-open-types.json" "$stub_dir"/issue-fields-*.json
unset GH_STUB_NATIVE_TYPE
GH_STUB_OWNER_TYPE="User"
cp "$tmp/labels-before-classification.json" "$stub_dir/labels.json"

echo "==> SKILL.md: rubric first, and none applied explicitly"
grep -q 'Read `references/classification-rubric.md`' \
    ai/skills/universal/triage/SKILL.md ||
    fail "SKILL.md must tell the model to read the classification rubric first"
grep -q 'Read `references/priority-rubric.md`' \
    ai/skills/universal/triage/SKILL.md ||
    fail "SKILL.md must tell the model to read the priority rubric first"
grep -q 'apply its explicit `none` value' ai/skills/universal/triage/SKILL.md ||
    fail "SKILL.md must tell the model to apply none rather than omit an axis"
grep -q 'flags `missing-needs-triage`, `needs-triage-removable`,' \
    ai/skills/universal/triage/SKILL.md &&
    grep -q '`tier-conflict` (more than one Tier label, not pinned)' \
        ai/skills/universal/triage/SKILL.md ||
    fail "SKILL.md must issue the reconcile call for tier-missing too"
grep -q -- '--issue <n> --reconcile' ai/skills/universal/triage/SKILL.md ||
    fail "SKILL.md must issue the reconcile call for needs-triage-only issues"
grep -q 'treat no issue flagged `classification-unreadable`' \
    ai/skills/universal/triage/SKILL.md ||
    fail "SKILL.md must say an unread field set is not classified"

grep -q '^### The native Type reader' ai/skills/universal/triage/SKILL.md ||
    fail "SKILL.md must document the per-issue native Type reader"
grep -q 'native-type` (see 2c)\|reader from step 2c' \
    ai/skills/universal/triage/SKILL.md &&
    fail "SKILL.md cross-references must point at the native Type reader"

echo "==> references: both rubrics exist and SKILL.md links them"
for rubric in classification-rubric priority-rubric; do
    [ -s "ai/skills/universal/triage/references/$rubric.md" ] ||
        fail "references/$rubric.md must exist and be non-empty"
    grep -qF "(references/$rubric.md)" ai/skills/universal/triage/SKILL.md ||
        fail "SKILL.md must link references/$rubric.md"
done

echo "==> human work: scan recommendation and combined apply preserve the add-only rule"
cat >"$stub_dir/issues-open.json" <<'JSON'
[{"number":601,"title":"(accounts): Approve access","labels":[],
  "updatedAt":"2026-01-01T00:00:00Z","assignees":[],
  "body":"## Acceptance criteria\n\n- [ ] [HUMAN] Approve access\n- [x] [HUMAN] Choose account"},
 {"number":602,"title":"(agent): Implement feature","labels":[],
  "updatedAt":"2026-01-01T00:00:00Z","assignees":[],
  "body":"## Acceptance criteria\n\n- [ ] [CI] Test feature\n- [ ] [CI] Ship feature\n- [ ] [HUMAN] Try by hand"},
 {"number":603,"title":"(QA): Verify shipped work by hand",
  "labels":[{"name":"human"},{"name":"umbrella"}],
  "updatedAt":"2026-01-01T00:00:00Z","assignees":[],"body":""},
 {"number":604,"title":"(agent): Implement dispatchable feature",
  "labels":[{"name":"human"}],"updatedAt":"2026-01-01T00:00:00Z",
  "assignees":[],"body":"## Acceptance criteria\n\n- [ ] [CI] Test feature"},
 {"number":605,"title":"(QA): Restore collector metadata",
  "labels":[{"name":"human"}],"updatedAt":"2026-01-01T00:00:00Z",
  "assignees":[],"body":""},
 {"number":606,"title":"(HUMAN): Restore collector metadata",
  "labels":[{"name":"human"}],"updatedAt":"2026-01-01T00:00:00Z",
  "assignees":[],"body":"## Acceptance criteria\n\n- [ ] [CI] Test feature"},
 {"number":607,"title":"(QA): Keep completed QA in the standing queue",
  "labels":[{"name":"human"}],"updatedAt":"2026-01-01T00:00:00Z",
  "assignees":[],"body":"## Acceptance criteria\n\n- [x] [HUMAN] Verify release"},
 {"number":608,"title":"(HUMAN): Complete manual setup",
  "labels":[{"name":"human"},{"name":"umbrella"}],
  "updatedAt":"2026-01-01T00:00:00Z","assignees":[],
  "body":"## Acceptance criteria\n\n- [x] [HUMAN] Approve access"},
 {"number":609,"title":"(agent): Implement legacy feature",
  "labels":[],"updatedAt":"2026-01-01T00:00:00Z","assignees":[],
  "body":"## Acceptance criteria\n\n- [ ] [HUMAN] Try by hand\n- [ ] Implement feature\n- [x] Test feature"},
 {"number":610,"title":"(accounts): Complete human setup","labels":[],
  "updatedAt":"2026-01-01T00:00:00Z","assignees":[],
  "body":"## Acceptance criteria\n\n- [ ] [CI] Prepare setup\n  - [ ] [HUMAN] Approve access\n  - [x] [HUMAN] Choose account"},
 {"number":611,"title":"(agent): Implement nested feature","labels":[],
  "updatedAt":"2026-01-01T00:00:00Z","assignees":[],
  "body":"## Acceptance criteria\n\n- [ ] [HUMAN] Try by hand\n  - [ ] [CI] Implement feature\n  - [x] [CI] Test feature"},
 {"number":612,"title":"(accounts): Complete star parent setup","labels":[],
  "updatedAt":"2026-01-01T00:00:00Z","assignees":[],
  "body":"## Acceptance criteria\n\n* [ ] [CI] Prepare setup\n  - [ ] [HUMAN] Approve access\n  - [x] [HUMAN] Choose account"},
 {"number":613,"title":"(accounts): Complete plus parent setup","labels":[],
  "updatedAt":"2026-01-01T00:00:00Z","assignees":[],
  "body":"## Acceptance criteria\n\n+ [ ] [CI] Prepare setup\n  - [ ] [HUMAN] Approve access\n  - [x] [HUMAN] Choose account"}]
JSON
[ "$(run "$scan" --repo "$repo" --manifest "$human_manifest" --all)" = 0 ] ||
    fail "human scan must pass: $(cat "$tmp/out")"
human_scan="$tmp/human-scan.json"
cp "$tmp/out" "$human_scan"
jq -e '.open[] | select(.number == 601) | .human_work.recommendation == "human"
    and .human_work.human_criteria == 2 and .human_work.total_criteria == 2
    and (.flags | index("human-label-missing") != null)' "$human_scan" >/dev/null ||
    fail "HUMAN-only criteria must recommend human (checked criteria included)"
jq -e '.open[] | select(.number == 602) | .human_work.recommendation == "review"
    and (.flags | index("human-label-missing") == null)' "$human_scan" >/dev/null ||
    fail "one human box must not recommend human on primarily agent work"
jq -e '.open[] | select(.number == 609) | .human_work.recommendation == "review"
    and .human_work.human_criteria == 1 and .human_work.total_criteria == 3
    and (.flags | index("human-label-missing") == null)' "$human_scan" >/dev/null ||
    fail "one human box among two untagged boxes must not recommend human"
nested_failures=0
for number in 610 611 612 613; do
    if [ "$number" != 611 ]; then
        expected=human
        human_count=2
    else
        expected=review
        human_count=1
    fi
    if ! jq -e --argjson n "$number" --arg expected "$expected" \
        --argjson human_count "$human_count" '.open[] | select(.number == $n)
        | .human_work.recommendation == $expected
          and .human_work.total_criteria == 3
          and .human_work.human_criteria == $human_count
          and ((.flags | index("human-label-missing") != null) == ($expected == "human"))' \
        "$human_scan" >/dev/null; then
        echo "nested majority fixture $number failed: expected $expected with total 3" >&2
        nested_failures=1
    fi
done
[ "$nested_failures" = 0 ] || fail "nested criteria must count in both human majority directions"
jq -e '.open[] | select(.number == 603) | .human_work.collector
    and (.flags | index("human-removal-candidate") == null)' "$human_scan" >/dev/null ||
    fail "collector must not become a removal candidate"
jq -e '.open[] | select(.number == 604) | .flags
    | index("human-removal-candidate") != null' "$human_scan" >/dev/null ||
    fail "dispatchable human-labelled issue must be reported, not removed"
for number in 605 606; do
    jq -e --argjson n "$number" '.open[] | select(.number == $n)
        | .human_work.collector and .human_work.recommendation == "human"
          and (.flags | index("collector-umbrella-missing") != null)
          and (.flags | index("human-removal-candidate") == null)' \
        "$human_scan" >/dev/null ||
        fail "collector title alone must report missing umbrella, never human removal"
done
jq -e '.open[] | select(.number == 607)
    | .human_work.collector and .criteria.total == 1 and .criteria.unticked == 0
      and (.flags | index("collector-umbrella-missing") != null)
      and ([.flags[] | select(startswith("completion-candidate:"))] | length == 0)
      and (.completion_reasons | length == 0)' "$human_scan" >/dev/null ||
    fail "fully ticked QA without umbrella must report metadata, never completion"
jq -e '.open[] | select(.number == 608)
    | .human_work.collector and .criteria.total == 1 and .criteria.unticked == 0
      and (.flags | index("completion-candidate:all-criteria-checked") != null)
      and (.completion_reasons == ["completion-candidate:all-criteria-checked"])' \
    "$human_scan" >/dev/null ||
    fail "fully ticked HUMAN collector must remain a completion candidate"
for number in 601 602 603 604; do
    jq --argjson n "$number" '.[] | select(.number == $n)' \
        "$stub_dir/issues-open.json" >"$stub_dir/issue-$number.json"
    human_add=()
    if jq -e --argjson n "$number" '.open[] | select(.number == $n)
        | .human_work.recommendation == "human" and (.human_work.labelled | not)' \
        "$human_scan" >/dev/null; then
        human_add=(--add human)
    fi
    : >"$GH_STUB_LOG"
    [ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue "$number" \
        --manifest "$human_manifest" --add bug --add area:ci --add layer:ui \
        --add domain:auth "${human_add[@]+"${human_add[@]}"}" --execute)" = 0 ] ||
        fail "human decision must share classification call: $(cat "$tmp/out")"
    if [ "$number" = 601 ]; then
        grep -q "APPLIED add 'human'" "$tmp/out" || fail "human-only work must get human"
        [ "$(grep -c '^issue edit' "$GH_STUB_LOG")" = 1 ] ||
            fail "human and axes must share the label mutation"
    elif [ "$number" = 602 ]; then
        grep -q "APPLIED add 'human'" "$tmp/out" && fail "agent issue must not get human"
    fi
    grep -q -- '--remove-label.*human' "$GH_STUB_LOG" && fail "human must never be removed"
    if [ "$number" = 603 ]; then
        [ "$(run "$apply" label --repo "$repo" --issue "$number" \
            --manifest "$human_manifest" --reconcile)" = 0 ] || fail "collector reconcile"
        grep -qE "would remove '(human|umbrella)'" "$tmp/out" && fail "collector labels must stay"
    fi
done

echo "All triage skill tests passed."
