#!/usr/bin/env bash
# Offline behavioral tests for claim/assets/claim-transaction.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

helper="$PWD/ai/skills/universal/claim/assets/claim-transaction.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
registry_snapshot="$tmp/default-branch-agent-registry.json"
cp agent-registry.json "$registry_snapshot"
stub="$tmp/bin"
mkdir -p "$stub"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

write_issue() {
    local expression="$1" value="$2" next
    next="${CLAIM_ISSUE_FILE}.next"
    jq --arg value "$value" "$expression" "$CLAIM_ISSUE_FILE" >"$next"
    mv "$next" "$CLAIM_ISSUE_FILE"
}

case "${1:-}" in
api)
    if [ "${2:-}" = user ]; then
        printf '%s\n' "${CLAIM_LOGIN:-evanharmon1}"
        exit 0
    fi
    if [[ " $* " == *"/timeline"* ]]; then
        [ ! -e "${CLAIM_TIMELINE_FAIL_FLAG:-/nonexistent}" ] || exit 1
        if [ -n "${CLAIM_MUTATE_TIMELINE_ON_READ:-}" ]; then
            count=0
            [ ! -f "$CLAIM_TIMELINE_READ_COUNT" ] || count="$(cat "$CLAIM_TIMELINE_READ_COUNT")"
            count=$((count + 1))
            printf '%s\n' "$count" >"$CLAIM_TIMELINE_READ_COUNT"
            if [ "$count" -eq "$CLAIM_MUTATE_TIMELINE_ON_READ" ]; then
                next="${CLAIM_TIMELINE_FILE}.next"
                jq --slurpfile events "$CLAIM_CONCURRENT_TIMELINE_EVENTS" '. + $events[0]' \
                    "$CLAIM_TIMELINE_FILE" >"$next"
                mv "$next" "$CLAIM_TIMELINE_FILE"
            fi
        fi
        printf '[%s]\n' "$(cat "$CLAIM_TIMELINE_FILE")"
        exit 0
    fi
    if [ -e "${CLAIM_COMMENTS_FAIL_FLAG:-/nonexistent}" ]; then
        exit 1
    fi
    if [ -n "${CLAIM_MUTATE_COMMENTS_ON_READ:-}" ]; then
        count=0
        [ ! -f "$CLAIM_COMMENTS_READ_COUNT" ] || count="$(cat "$CLAIM_COMMENTS_READ_COUNT")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$CLAIM_COMMENTS_READ_COUNT"
        if [ "$count" -eq "$CLAIM_MUTATE_COMMENTS_ON_READ" ]; then
            next="${CLAIM_COMMENTS_FILE}.next"
            jq --rawfile body "$CLAIM_CONCURRENT_RECORD" --arg login "${CLAIM_CONCURRENT_LOGIN:-collaborator}" \
                '. + [{id: ((map(.id) | max // 0) + 1), user:{login:$login}, author_association:"COLLABORATOR", body:($body | sub("\\n+$"; ""))}]' \
                "$CLAIM_COMMENTS_FILE" >"$next"
            mv "$next" "$CLAIM_COMMENTS_FILE"
        fi
    fi
    # The helper asks gh for --slurp output, so return one page.
    printf '[%s]\n' "$(cat "$CLAIM_COMMENTS_FILE")"
    ;;
issue)
    case "${2:-}" in
    view)
        cat "$CLAIM_ISSUE_FILE"
        ;;
    edit)
        printf 'edit' >>"$CLAIM_LOG"
        printf ' %q' "${@:3}" >>"$CLAIM_LOG"
        printf '\n' >>"$CLAIM_LOG"
        if [ -n "${CLAIM_FAIL_EDIT_MATCH:-}" ] && [[ " ${*:3} " == *"$CLAIM_FAIL_EDIT_MATCH"* ]]; then
            exit 1
        fi
        fail_after=0
        if [ -n "${CLAIM_FAIL_EDIT_AFTER_APPLY_MATCH:-}" ] &&
            [[ " ${*:3} " == *"$CLAIM_FAIL_EDIT_AFTER_APPLY_MATCH"* ]]; then
            fail_after=1
        fi
        shift 2
        while [ "$#" -gt 0 ]; do
            case "$1" in
            --add-assignee)
                write_issue '.assignees = ((.assignees + [{login:$value}]) | unique_by(.login))' "$2"
                shift 2
                ;;
            --remove-assignee)
                write_issue '.assignees = [.assignees[] | select(.login != $value)]' "$2"
                shift 2
                ;;
            --add-label)
                write_issue '.labels = ((.labels + [{name:$value}]) | unique_by(.name))' "$2"
                shift 2
                ;;
            --remove-label)
                write_issue '.labels = [.labels[] | select(.name != $value)]' "$2"
                shift 2
                ;;
            *) shift ;;
            esac
        done
        [ "$fail_after" -eq 0 ] || exit 1
        ;;
    comment)
        body_file=""
        shift 2
        while [ "$#" -gt 0 ]; do
            case "$1" in
            --body-file) body_file="$2"; shift 2 ;;
            *) shift ;;
            esac
        done
        printf 'comment\n' >>"$CLAIM_LOG"
        case "${CLAIM_COMMENT_MODE:-success}" in
        success | commit_fail)
            next="${CLAIM_COMMENTS_FILE}.next"
            jq --rawfile body "$body_file" --arg login "${CLAIM_LOGIN:-evanharmon1}" \
                '. + [{id: ((map(.id) | max // 0) + 1), user:{login:$login}, author_association:"OWNER",
                       created_at:"2026-08-20T12:00:00Z", body:($body | sub("\\n+$"; ""))}]' \
                "$CLAIM_COMMENTS_FILE" >"$next"
            mv "$next" "$CLAIM_COMMENTS_FILE"
            if [ "${CLAIM_CLOSE_AFTER_COMMENT:-false}" = true ]; then
                write_issue '.state = $value' CLOSED
            fi
            [ "${CLAIM_COMMENT_MODE:-success}" = success ] || exit 1
            ;;
        absent_fail) exit 1 ;;
        reconcile_fail)
            : >"$CLAIM_COMMENTS_FAIL_FLAG"
            exit 1
            ;;
        *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
    esac
    ;;
*) exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

issue_file="$tmp/issue.json"
comments_file="$tmp/comments.json"
timeline_file="$tmp/timeline.json"
comments_fail_flag="$tmp/comments.fail"
timeline_fail_flag="$tmp/timeline.fail"
timeline_read_count="$tmp/timeline.read-count"
comments_read_count="$tmp/comments.read-count"
log="$tmp/actions.log"
record="$tmp/record.md"
err="$tmp/err"

scenario() {
    printf '%s' "$1" | jq '.state //= "OPEN"' >"$issue_file"
    printf '%s' "${2:-[]}" | jq 'map(.created_at //= "2026-08-20T10:00:00Z")' >"$comments_file"
    printf '%s' "${3:-[]}" >"$timeline_file"
    : >"$log"
    rm -f "$comments_fail_flag"
    rm -f "$timeline_fail_flag"
    rm -f "$timeline_read_count"
    rm -f "$comments_read_count"
}

make_record() {
    local assignee="$1" label="$2" displaced="$3" chain_assignee="$4" chain_login="$5" chain_label="$6" chain_displaced="$7"
    local branch="${8:-fix/test}"
    local family="${9:-gpt}" runtime_environment="${10:-coder}"
    cat >"$record" <<EOF
Claiming — starting implementation on branch $branch (session test-session).

Claim record (for \`/wrap\` — undo only what this claim added):
- harness: test
- model: test
- family: $family
- runtime environment: $runtime_environment
- session: test-session
- assignee added by this claim: $assignee
- \`claim:\` label added by this claim: $label
- \`claim:\` label displaced by this claim: $displaced
- assignee logins owned by this claim chain: $([ "$chain_assignee" = yes ] && printf '%s' "$chain_login" || printf 'none')
- \`claim:\` label owned by this claim chain: $chain_label
- \`claim:\` label displaced by this claim chain: $chain_displaced
EOF
}

add_model_fields() {
    local direct_model="$1" chain_model="$2" next="$tmp/record-with-model.md"
    awk -v direct="$direct_model" -v chain="$chain_model" '
        { print }
        /- `claim:` label added by this claim:/ {
            print "- `claim:` model label added by this claim: " direct
        }
        /- `claim:` label owned by this claim chain:/ {
            print "- `claim:` model label owned by this claim chain: " chain
        }
    ' "$record" >"$next"
    mv "$next" "$record"
}

run_claim() {
    local rc=0
    env PATH="$stub:$PATH" \
        CLAIM_ISSUE_FILE="$issue_file" CLAIM_COMMENTS_FILE="$comments_file" \
        CLAIM_COMMENTS_FAIL_FLAG="$comments_fail_flag" CLAIM_LOG="$log" \
        CLAIM_TIMELINE_FILE="$timeline_file" CLAIM_TIMELINE_FAIL_FLAG="$timeline_fail_flag" \
        CLAIM_TIMELINE_READ_COUNT="$timeline_read_count" \
        CLAIM_MUTATE_TIMELINE_ON_READ="${RUN_MUTATE_TIMELINE_ON_READ:-}" \
        CLAIM_CONCURRENT_TIMELINE_EVENTS="${RUN_CONCURRENT_TIMELINE_EVENTS:-$timeline_file}" \
        CLAIM_COMMENTS_READ_COUNT="$comments_read_count" \
        CLAIM_MUTATE_COMMENTS_ON_READ="${RUN_MUTATE_COMMENTS_ON_READ:-}" \
        CLAIM_CONCURRENT_RECORD="${RUN_CONCURRENT_RECORD:-$record}" \
        CLAIM_CONCURRENT_LOGIN="${RUN_CONCURRENT_LOGIN:-collaborator}" \
        CLAIM_CLOSE_AFTER_COMMENT="${RUN_CLOSE_AFTER_COMMENT:-false}" \
        CLAIM_FAIL_EDIT_AFTER_APPLY_MATCH="${CLAIM_FAIL_EDIT_AFTER_APPLY_MATCH:-}" \
        CLAIM_LOGIN="${RUN_LOGIN:-evanharmon1}" \
        "$helper" --repo evanharmon1/harmon-devkit --issue 543 \
        --record-file "$record" "$@" \
        --family "${RUN_FAMILY:-gpt}" \
        --runtime-environment "${RUN_RUNTIME_ENVIRONMENT:-coder}" \
        --registry-snapshot "${RUN_REGISTRY_SNAPSHOT:-$registry_snapshot}" \
        >"$tmp/out" 2>"$err" || rc=$?
    printf '%s\n' "$rc"
}

empty_issue='{"assignees":[],"labels":[]}'

echo "==> successful claims commit markers then the durable record"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(run_claim --claim-label claim:gpt)" = 0 ] || fail "successful claim should exit 0: $(cat "$err")"
sed -n '1p' "$log" | grep -q -- '--add-assignee evanharmon1' || fail "assignee must be the first write"
sed -n '2p' "$log" | grep -q -- '--add-label claim:gpt' || fail "label must be the second write"
[ "$(sed -n '3p' "$log")" = comment ] || fail "record must follow marker writes"
[ "$(wc -l <"$log" | tr -d ' ')" = 3 ] || fail "transaction must perform no Project board operation"

echo "==> successful publication still requires a current live claim"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(RUN_CLOSE_AFTER_COMMENT=true run_claim --claim-label claim:gpt)" = 6 ] ||
    fail "a claim closed during successful publication must be indeterminate"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "the published record must remain visible"
grep -q 'published record is not the current live claim' "$err" ||
    fail "post-success live-state failure must be explicit"
if grep -q -- '--remove-' "$log"; then fail "post-success reconciliation must not compensate"; fi

scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
release_record="$tmp/success-release-record.md"
printf '%s\n' 'Claim released — concurrent release. (Supersedes the claim record above.)' >"$release_record"
[ "$(RUN_MUTATE_COMMENTS_ON_READ=3 RUN_CONCURRENT_RECORD="$release_record" \
    RUN_CONCURRENT_LOGIN=evanharmon1 run_claim --claim-label claim:gpt)" = 6 ] ||
    fail "a successful publication superseded before reconciliation must be indeterminate"
[ "$(jq 'length' "$comments_file")" -eq 2 ] || fail "both concurrent records must remain visible"
if grep -q -- '--remove-' "$log"; then fail "superseded successful publication must not compensate"; fi

echo "==> trusted family and runtime metadata commit through the transaction"
scenario '{"assignees":[],"labels":[]}'
make_record yes claim:claude none yes evanharmon1 claim:claude none fix/claude claude devcontainer
[ "$(RUN_FAMILY=claude RUN_RUNTIME_ENVIRONMENT=devcontainer run_claim --claim-label claim:claude)" = 0 ] ||
    fail "Claude/devcontainer metadata should commit through the transaction: $(cat "$err")"
jq -e '.[0].body | contains("- family: claude") and contains("- runtime environment: devcontainer")' \
    "$comments_file" >/dev/null || fail "the exact operational metadata must reach the durable record"

echo "==> metadata mismatch fails before any marker write"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(RUN_FAMILY=claude run_claim --claim-label claim:gpt)" = 2 ] ||
    fail "a record family not matching the trusted resolver output must fail"
[ ! -s "$log" ] || fail "a mismatched trusted family must fail before writes"

echo "==> closed issues and newly competing markers fail before writes"
scenario '{"state":"CLOSED","assignees":[],"labels":[]}'
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(run_claim --claim-label claim:gpt)" = 2 ] || fail "a closed issue must be rejected"
[ ! -s "$log" ] || fail "a closed issue must trigger zero writes"
scenario '{"assignees":[],"labels":[{"name":"claim:claude"}]}'
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(run_claim --claim-label claim:gpt)" = 2 ] || fail "an unapproved competing ownership label must be rejected"
[ ! -s "$log" ] || fail "a competing marker must trigger zero writes"

echo "==> trusted family rejects mismatched family and model-shaped claim labels"
for mismatched_label in claim:gpt claim:gpt:terra; do
    scenario "$empty_issue"
    make_record yes "$mismatched_label" none yes evanharmon1 "$mismatched_label" none \
        fix/mismatch claude
    [ "$(RUN_FAMILY=claude run_claim --claim-label "$mismatched_label")" = 2 ] ||
        fail "trusted family must reject mismatched claim label $mismatched_label"
    [ ! -s "$log" ] || fail "a mismatched family label must trigger zero writes"
done

echo "==> legacy aliases are bound to the trusted family"
scenario "$empty_issue"
make_record yes agent:codex none yes evanharmon1 agent:codex none
[ "$(run_claim --claim-label agent:codex)" = 0 ] ||
    fail "the registered gpt legacy alias must remain supported: $(cat "$err")"
scenario "$empty_issue"
make_record yes agent:claude-code none yes evanharmon1 agent:claude-code none
[ "$(run_claim --claim-label agent:claude-code)" = 2 ] ||
    fail "a foreign-family legacy alias must be rejected"
[ ! -s "$log" ] || fail "legacy family mismatch must fail before writes"

echo "==> legacy aliases use only the supplied trusted snapshot or finite fallback"
scenario "$empty_issue"
make_record yes agent:codex none yes evanharmon1 agent:codex none
[ "$(RUN_REGISTRY_SNAPSHOT=none run_claim --claim-label agent:codex)" = 0 ] ||
    fail "the finite pre-registry gpt alias must remain supported"
scenario "$empty_issue"
make_record yes agent:branch-injected none yes evanharmon1 agent:branch-injected none
[ "$(run_claim --claim-label agent:branch-injected)" = 2 ] ||
    fail "an alias absent from the fetched snapshot must be rejected"
[ ! -s "$log" ] || fail "untrusted branch alias must fail before writes"
scenario "$empty_issue"
make_record yes agent:codex none yes evanharmon1 agent:codex none
[ "$(RUN_REGISTRY_SNAPSHOT="$tmp/missing-registry.json" run_claim --claim-label agent:codex)" = 2 ] ||
    fail "an unreadable declared registry snapshot must fail closed"
[ ! -s "$log" ] || fail "unreadable registry snapshot must fail before writes"

echo "==> custom registry aliases remain family-only until canonical migration"
custom_registry="$tmp/custom-alias-registry.json"
jq '(.families[] | select(.slug == "gpt") | .legacy_claim_labels) += ["agent:custom-gpt"]' \
    "$registry_snapshot" >"$custom_registry"
scenario "$empty_issue"
make_record yes agent:custom-gpt none yes evanharmon1 agent:custom-gpt none
[ "$(RUN_REGISTRY_SNAPSHOT="$custom_registry" run_claim --claim-label agent:custom-gpt)" = 0 ] ||
    fail "a trusted custom alias must remain supported for a family-level claim: $(cat "$err")"
scenario "$empty_issue"
make_record yes agent:custom-gpt none yes evanharmon1 agent:custom-gpt none
add_model_fields claim:gpt:terra claim:gpt:terra
[ "$(RUN_REGISTRY_SNAPSHOT="$custom_registry" run_claim --claim-label agent:custom-gpt \
    --model-label claim:gpt:terra)" = 2 ] ||
    fail "an unreleasable custom-alias/model pairing must fail before writes"
[ ! -s "$log" ] || fail "a custom-alias/model pairing must perform zero writes"

echo "==> a same-family model-shaped primary marker remains a supported legacy plan"
scenario "$empty_issue"
make_record yes claim:gpt:terra none yes evanharmon1 claim:gpt:terra none
[ "$(run_claim --claim-label claim:gpt:terra)" = 0 ] ||
    fail "same-family model-shaped primary marker should commit: $(cat "$err")"

echo "==> inherited displacement requires predecessor proof"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt claim:claude
[ "$(run_claim --claim-label claim:gpt)" = 2 ] || fail "a forged inherited displacement must be rejected"
[ ! -s "$log" ] || fail "forged displacement must fail before writes"

echo "==> a failed response that committed the exact record reconciles as success"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_COMMENT_MODE=commit_fail run_claim --claim-label claim:gpt)" = 0 ] || fail "committed ambiguous publication should continue"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "reconciled record must remain"
grep -q 'reconciliation confirmed the exact current record committed' "$err" || fail "reconciliation must be reported"

echo "==> a reconciled exact record must still be the current live claim"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
release_record="$tmp/release-record.md"
printf '%s\n' 'Claim released — concurrent release. (Supersedes the claim record above.)' >"$release_record"
result="$(RUN_MUTATE_COMMENTS_ON_READ=3 RUN_CONCURRENT_RECORD="$release_record" \
    RUN_CONCURRENT_LOGIN=evanharmon1 CLAIM_COMMENT_MODE=commit_fail \
    run_claim --claim-label claim:gpt)"
[ "$result" = 6 ] ||
    fail "an exact record superseded before reconciliation must be indeterminate: $(cat "$err")"
grep -q 'already superseded' "$err" || fail "superseded exact-record reconciliation must be explicit"
if grep -q -- '--remove-' "$log"; then fail "superseded reconciliation must not compensate adopted markers"; fi

echo "==> an unreadable reconciliation leaves visible partial markers"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_COMMENT_MODE=reconcile_fail run_claim --claim-label claim:gpt)" = 6 ] || fail "indeterminate publication should exit 6"
jq -e 'any(.assignees[]; .login == "evanharmon1") and any(.labels[]; .name == "claim:gpt")' "$issue_file" >/dev/null ||
    fail "indeterminate publication must leave markers visible"
if grep -q -- '--remove-' "$log"; then fail "indeterminate publication must not compensate"; fi

echo "==> a newer trusted claim before publication prevents a stale record commit"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
concurrent_record="$tmp/concurrent-record.md"
cp "$record" "$concurrent_record"
sed -i 's/test-session/concurrent-session/g' "$concurrent_record"
result="$(RUN_MUTATE_COMMENTS_ON_READ=2 RUN_CONCURRENT_RECORD="$concurrent_record" RUN_CONCURRENT_LOGIN=evanharmon1 \
    run_claim --claim-label claim:gpt)"
[ "$result" = 6 ] || fail "a changed predecessor before publication must exit 6: $(cat "$err")"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "the stale record must not be published"
[ "$(grep -c '^comment$' "$log" || true)" -eq 0 ] || fail "pre-publication lineage drift must stop before the comment write"
grep -q 'newer trusted claim or release appeared' "$err" || fail "lineage collision must be explained"

echo "==> confirmed absence leaves visible markers without destructive recovery"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt)" = 6 ] ||
    fail "an absent record after marker writes must remain indeterminate: $(cat "$err")"
grep -q 'destructive recovery is unsafe' "$err" || fail "non-destructive recovery must be explicit"
jq -e 'any(.assignees[]; .login == "evanharmon1") and any(.labels[]; .name == "claim:gpt")' \
    "$issue_file" >/dev/null || fail "tentative markers must remain visible for recovery"
if grep -q -- '--remove-' "$log"; then fail "transaction recovery must never remove a marker"; fi

echo "==> routine helper rejects displacement before every write"
scenario '{"assignees":[],"labels":[{"name":"claim:gpt"},{"name":"claim:claude"}]}'
make_record yes no claim:claude yes evanharmon1 no claim:claude
[ "$(run_claim --claim-label claim:gpt --displaced-label claim:claude)" = 2 ] ||
    fail "routine helper must not accept a displacement flag"
[ ! -s "$log" ] || fail "exceptional displacement must remain outside the routine write boundary"

echo "==> routine helper rejects every label-less plan before every write"
scenario "$empty_issue"
make_record yes n/a none yes evanharmon1 n/a none
[ "$(run_claim --claim-label none)" = 2 ] || fail "routine helper must reject a label-less claim"
[ ! -s "$log" ] || fail "label-less exceptional flow must remain outside the routine write boundary"

echo "==> failed publication always leaves a visible partial recordless claim"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt)" = 6 ] ||
    fail "failed publication should remain indeterminate"
jq -e 'any(.labels[]; .name == "claim:gpt")' "$issue_file" >/dev/null || fail "partial marker must remain visible"
if grep -q -- '--remove-' "$log"; then fail "failed publication must never trigger destructive recovery"; fi

echo "==> a failed label response never attributes changed state to this attempt"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_FAIL_EDIT_AFTER_APPLY_MATCH='--add-label claim:gpt' run_claim --claim-label claim:gpt)" = 6 ] ||
    fail "changed state after a failed label response must be indeterminate"
grep -q 'ambiguous provenance' "$err" || fail "ambiguous label provenance must be explicit"
jq -e 'any(.assignees[]; .login == "evanharmon1") and any(.labels[]; .name == "claim:gpt")' \
    "$issue_file" >/dev/null || fail "indeterminate marker state must remain visible"
if grep -q -- '--remove-' "$log"; then fail "ambiguous label state must never be compensated"; fi

echo "==> an exact committed-record retry is a no-write idempotent success"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(run_claim --claim-label claim:gpt)" = 0 ] || fail "initial claim should commit before retry"
: >"$log"
[ "$(run_claim --claim-label claim:gpt)" = 0 ] || fail "exact record retry must recognize the committed claim"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "exact retry must not publish a duplicate record"
[ ! -s "$log" ] || fail "exact retry must perform no marker or comment write"

echo "==> an exact retry succeeds only while its issue and required markers remain live"
jq '.state = "CLOSED"' "$issue_file" >"$issue_file.next" && mv "$issue_file.next" "$issue_file"
: >"$log"
[ "$(run_claim --claim-label claim:gpt)" = 6 ] || fail "exact retry on a closed issue must fail closed"
[ ! -s "$log" ] || fail "closed exact retry must remain no-write"
jq '.state = "OPEN" | .labels = []' "$issue_file" >"$issue_file.next" && mv "$issue_file.next" "$issue_file"
[ "$(run_claim --claim-label claim:gpt)" = 6 ] || fail "exact retry missing its family marker must fail closed"
[ ! -s "$log" ] || fail "markerless exact retry must remain no-write"

make_record no no none yes evanharmon1 claim:gpt claim:claude
displaced_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
displaced_current="$(jq -n --argjson body "$displaced_body" '[{id:1,user:{login:"evanharmon1"},author_association:"OWNER",body:$body}]')"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"},{"name":"claim:claude"}]}' "$displaced_current"
[ "$(run_claim --claim-label claim:gpt)" = 6 ] || fail "exact retry must reject a reappeared displaced marker"
[ ! -s "$log" ] || fail "displaced-marker exact retry must remain no-write"

echo "==> pre-existing markers are never rewritten or removed"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}'
make_record no no none no none no none
[ "$(run_claim --claim-label claim:gpt)" = 0 ] || fail "pre-existing marker claim should succeed: $(cat "$err")"
if grep -q '^edit' "$log"; then fail "pre-existing markers must not be edited"; fi

echo "==> a model refinement preserves its family marker and commits transactionally"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none fix/family
family_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
family_predecessor="$(jq -n --argjson body "$family_body" '[{id:1,user:{login:"evanharmon1"},author_association:"OWNER",body:$body}]')"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$family_predecessor"
make_record no no none yes evanharmon1 claim:gpt none fix/model
add_model_fields claim:gpt:terra claim:gpt:terra
[ "$(run_claim --claim-label claim:gpt --model-label claim:gpt:terra)" = 0 ] ||
    fail "model refinement should commit through the claim transaction: $(cat "$err")"
grep -q -- '--add-label claim:gpt:terra' "$log" || fail "model refinement must add its exact model label"
if grep -q -- '--add-label claim:gpt\($\| \)' "$log"; then fail "model refinement must not rewrite the family marker"; fi
: >"$log"
jq '.labels = [.labels[] | select(.name != "claim:gpt:terra")]' "$issue_file" >"$issue_file.next" && mv "$issue_file.next" "$issue_file"
[ "$(run_claim --claim-label claim:gpt --model-label claim:gpt:terra)" = 6 ] ||
    fail "exact model retry missing its refinement marker must fail closed"
[ ! -s "$log" ] || fail "markerless exact model retry must remain no-write"

echo "==> failed model publication leaves the tentative refinement visible"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$family_predecessor"
make_record no no none yes evanharmon1 claim:gpt none fix/model
add_model_fields claim:gpt:terra claim:gpt:terra
[ "$(CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt --model-label claim:gpt:terra)" = 6 ] ||
    fail "confirmed absent model record should remain indeterminate: $(cat "$err")"
jq -e 'any(.labels[]; .name == "claim:gpt:terra")' "$issue_file" >/dev/null ||
    fail "tentative model refinement must remain visible"
if grep -q -- '--remove-label' "$log"; then fail "failed model publication must never remove labels"; fi

echo "==> a failed refresh leaves the predecessor current and markers untouched"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none fix/predecessor
predecessor_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
predecessor="$(jq -n --argjson body "$predecessor_body" '[{id:1,user:{login:"evanharmon1"},author_association:"OWNER",body:$body}]')"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$predecessor"
make_record no no none yes evanharmon1 claim:gpt none fix/refreshed
[ "$(CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt)" = 6 ] || fail "failed refresh should exit 6"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "failed refresh must preserve only the predecessor"
if grep -q '^edit' "$log"; then fail "failed refresh must not touch inherited markers"; fi

echo "==> removed and independently re-added labels do not carry predecessor ownership"
make_record no no none no none claim:gpt none
predecessor_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
predecessor="$(jq -n --argjson body "$predecessor_body" \
    '[{id:1,user:{login:"evanharmon1"},author_association:"OWNER",body:$body}]')"
label_readded_timeline='[{"event":"unlabeled","created_at":"2026-08-20T11:00:00Z","label":{"name":"claim:gpt"},"actor":{"login":"independent"}},{"event":"labeled","created_at":"2026-08-20T11:01:00Z","label":{"name":"claim:gpt"},"actor":{"login":"independent"}}]'
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' \
    "$predecessor" "$label_readded_timeline"
make_record no no none no none no none
[ "$(run_claim --claim-label claim:gpt)" = 0 ] ||
    fail "a re-added label must remain live without inherited cleanup authority: $(cat "$err")"
if grep -q '^edit' "$log"; then fail "a re-added live label must not be rewritten"; fi

echo "==> removed and independently re-added assignees do not carry predecessor ownership"
make_record yes no none yes evanharmon1 no none
predecessor_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
predecessor="$(jq -n --argjson body "$predecessor_body" \
    '[{id:1,user:{login:"evanharmon1"},author_association:"OWNER",body:$body}]')"
assignee_readded_timeline='[{"event":"unassigned","created_at":"2026-08-20T11:00:00Z","assignee":{"login":"evanharmon1"},"actor":{"login":"independent"}},{"event":"assigned","created_at":"2026-08-20T11:01:00Z","assignee":{"login":"evanharmon1"},"actor":{"login":"independent"}}]'
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' \
    "$predecessor" "$assignee_readded_timeline"
make_record no no none no none no none
[ "$(run_claim --claim-label claim:gpt)" = 0 ] ||
    fail "a re-added assignee must remain live without inherited cleanup authority: $(cat "$err")"
if grep -q '^edit' "$log"; then fail "a re-added live assignee must not be rewritten"; fi

echo "==> unreadable continuity evidence fails before inherited authority can be recorded"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$predecessor"
: >"$timeline_fail_flag"
make_record no no none yes evanharmon1 no none
[ "$(run_claim --claim-label claim:gpt)" = 2 ] || fail "an unreadable timeline must fail closed"
[ ! -s "$log" ] || fail "unreadable continuity must fail before writes"

echo "==> inherited marker continuity is revalidated immediately before publication"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
predecessor_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
predecessor="$(jq -n --argjson body "$predecessor_body" \
    '[{id:1,user:{login:"evanharmon1"},author_association:"OWNER",body:$body}]')"
continuity_break="$tmp/continuity-break.json"
printf '%s' "$label_readded_timeline" >"$continuity_break"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$predecessor"
make_record no no none yes evanharmon1 claim:gpt none
[ "$(RUN_MUTATE_TIMELINE_ON_READ=2 RUN_CONCURRENT_TIMELINE_EVENTS="$continuity_break" \
    run_claim --claim-label claim:gpt)" = 6 ] ||
    fail "continuity lost before publication must stop the stale append: $(cat "$err")"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "pre-publication continuity drift must not append"
grep -q 'continuity changed before publication' "$err" || fail "pre-publication continuity drift must be explicit"

echo "==> post-publication reconciliation revalidates original predecessor continuity"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$predecessor"
make_record no no none yes evanharmon1 claim:gpt none
[ "$(RUN_MUTATE_TIMELINE_ON_READ=3 RUN_CONCURRENT_TIMELINE_EVENTS="$continuity_break" \
    run_claim --claim-label claim:gpt)" = 6 ] ||
    fail "continuity lost during publication must fail reconciliation: $(cat "$err")"
[ "$(jq 'length' "$comments_file")" -eq 2 ] || fail "the published record remains visible for recovery"
grep -q 'published record is not the current live claim' "$err" || fail "post-publication continuity drift must be explicit"

echo "==> label-less repositories remain an explicit manual exception"
scenario "$empty_issue"
make_record yes n/a none yes evanharmon1 n/a none none none
[ "$(run_claim --claim-label none)" = 2 ] || fail "routine transaction must reject label-less repositories"
jq -e '(.assignees | length) == 0' "$issue_file" >/dev/null || fail "routine helper must not partially claim label-less issue"
[ "$(jq 'length' "$comments_file")" -eq 0 ] || fail "routine helper must not publish a label-less record"
[ ! -s "$log" ] || fail "routine helper must perform zero writes for label-less exception"

echo "==> A to B to C takeover retains the canonical predecessor ownership set"
make_record yes no none yes 'alice,bob' claim:gpt none fix/predecessor
predecessor_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
scenario '{"assignees":[{"login":"alice"},{"login":"bob"}],"labels":[{"name":"claim:gpt"}]}' \
    "$(jq -n --argjson body "$predecessor_body" '[{id:1,user:{login:"bob"},author_association:"COLLABORATOR",body:$body}]')"
make_record yes no none yes 'alice,bob,carol' claim:gpt none
[ "$(RUN_LOGIN=carol run_claim --claim-label claim:gpt)" = 0 ] || fail "C must retain A and B while adding itself: $(cat "$err")"
grep -Fq -- '- assignee logins owned by this claim chain: alice,bob,carol' "$record" || fail "record must carry the canonical A+B+C set"

echo "==> refresh reads bounded whitespace v3 but writes comma-canonical v3"
whitespace_predecessor_body="$(printf '%s' "$predecessor_body" | sed 's/alice,bob/alice bob/')"
scenario '{"assignees":[{"login":"alice"},{"login":"bob"}],"labels":[{"name":"claim:gpt"}]}' \
    "$(jq -n --argjson body "$whitespace_predecessor_body" '[{id:1,user:{login:"bob"},author_association:"COLLABORATOR",body:$body}]')"
make_record yes no none yes 'alice,bob,carol' claim:gpt none
[ "$(RUN_LOGIN=carol run_claim --claim-label claim:gpt)" = 0 ] ||
    fail "transitional whitespace predecessor should refresh into canonical v3: $(cat "$err")"
grep -Fq -- '- assignee logins owned by this claim chain: alice,bob,carol' "$record" ||
    fail "refreshed records must remain comma-canonical"

echo "==> the producer rejects a forged assignee outside predecessor plus direct ownership"
scenario '{"assignees":[{"login":"alice"},{"login":"bob"}],"labels":[{"name":"claim:gpt"}]}' \
    "$(jq -n --argjson body "$predecessor_body" '[{id:1,user:{login:"bob"},author_association:"COLLABORATOR",body:$body}]')"
make_record yes no none yes 'alice,bob,carol,dave' claim:gpt none
[ "$(RUN_LOGIN=carol run_claim --claim-label claim:gpt)" = 2 ] || fail "forged victim must fail before writes"
if grep -q '^edit\|^comment$' "$log"; then fail "forged victim rejection must perform zero writes"; fi

echo "PASS: claim transaction semantics"
