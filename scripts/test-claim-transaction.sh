#!/usr/bin/env bash
# Offline behavioral tests for claim/assets/claim-transaction.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

helper="$PWD/ai/skills/universal/claim/assets/claim-transaction.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
                '. + [{id: ((map(.id) | max // 0) + 1), user:{login:$login}, author_association:"OWNER", body:($body | sub("\\n+$"; ""))}]' \
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
comments_fail_flag="$tmp/comments.fail"
comments_read_count="$tmp/comments.read-count"
log="$tmp/actions.log"
record="$tmp/record.md"
err="$tmp/err"

scenario() {
    printf '%s' "$1" | jq '.state //= "OPEN"' >"$issue_file"
    printf '%s' "${2:-[]}" >"$comments_file"
    : >"$log"
    rm -f "$comments_fail_flag"
    rm -f "$comments_read_count"
}

make_record() {
    local assignee="$1" label="$2" displaced="$3" chain_assignee="$4" chain_login="$5" chain_label="$6" chain_displaced="$7"
    local branch="${10:-fix/test}"
    local family="${11:-gpt}" runtime_environment="${12:-coder}"
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

echo "==> trusted family and runtime metadata commit through the transaction"
scenario '{"assignees":[],"labels":[]}'
make_record yes claim:claude none yes evanharmon1 claim:claude none 'Owner Project' Ready fix/claude claude devcontainer
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
        'Owner Project' Ready fix/mismatch claude
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

echo "==> confirmed absence never compensates markers adopted by a newer claim"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
cp "$record" "$concurrent_record"
sed -i 's/test-session/concurrent-session/g' "$concurrent_record"
result="$(RUN_MUTATE_COMMENTS_ON_READ=3 RUN_CONCURRENT_RECORD="$concurrent_record" RUN_CONCURRENT_LOGIN=evanharmon1 \
    CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt)"
[ "$result" = 6 ] || fail "a newer claim after failed publication must block compensation: $(cat "$err")"
grep -q 'refusing compensation' "$err" || fail "adopted tentative markers must be reported"
if grep -q -- '--remove-' "$log"; then fail "a newer committed claim must protect tentative markers from compensation"; fi

echo "==> final compensation guard catches a claim committed after absence reconciliation"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
cp "$record" "$concurrent_record"
sed -i 's/test-session/concurrent-session/g' "$concurrent_record"
result="$(RUN_MUTATE_COMMENTS_ON_READ=4 RUN_CONCURRENT_RECORD="$concurrent_record" \
    RUN_CONCURRENT_LOGIN=evanharmon1 CLAIM_COMMENT_MODE=absent_fail \
    run_claim --claim-label claim:gpt)"
[ "$result" = 6 ] || fail "late claim adoption must block compensation: $(cat "$err")"
grep -q 'refusing compensation' "$err" || fail "late adoption must be reported"
if grep -q -- '--remove-' "$log"; then fail "final lineage guard must run before destructive compensation"; fi

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

echo "==> compensation failure is loud and leaves a partial recordless claim"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_COMMENT_MODE=absent_fail CLAIM_FAIL_EDIT_MATCH='--remove-label claim:gpt' run_claim --claim-label claim:gpt)" = 7 ] ||
    fail "failed compensation should exit 7"
grep -q 'partial recordless claim remains' "$err" || fail "partial recordless claim must be named"
jq -e 'any(.labels[]; .name == "claim:gpt")' "$issue_file" >/dev/null || fail "failed removal should remain visible"

echo "==> a failed label response never attributes changed state to this attempt"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_FAIL_EDIT_AFTER_APPLY_MATCH='--add-label claim:gpt' run_claim --claim-label claim:gpt)" = 6 ] ||
    fail "changed state after a failed label response must be indeterminate"
grep -q 'ambiguous provenance' "$err" || fail "ambiguous label provenance must be explicit"
jq -e 'any(.assignees[]; .login == "evanharmon1") and any(.labels[]; .name == "claim:gpt")' \
    "$issue_file" >/dev/null || fail "indeterminate marker state must remain visible"
if grep -q -- '--remove-' "$log"; then fail "ambiguous label state must never be compensated"; fi

echo "==> board metadata is non-authoritative and never affects claim commit"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none unknown unknown
awk '
    { print }
    /^- session:/ {
        print "- board: Owner Project"
        print "- prior board status: unknown"
        print "- prior board status owned by this claim chain: unknown"
    }
' "$record" >"$tmp/legacy-board-record.md"
mv "$tmp/legacy-board-record.md" "$record"
[ "$(run_claim --claim-label claim:gpt)" = 0 ] || fail "board metadata must not gate a durable claim"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "durable record must commit independently of board metadata"
if grep -q '^status ' "$log"; then fail "transaction must never read or write Project status"; fi

echo "==> an exact committed-record retry is a no-write idempotent success"
: >"$log"
[ "$(run_claim --claim-label claim:gpt)" = 0 ] || fail "exact record retry must recognize the committed claim"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "exact retry must not publish a duplicate record"
[ ! -s "$log" ] || fail "exact retry must perform no marker, comment, or board write"

echo "==> pre-existing markers are never rewritten or compensated"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}'
make_record no no none no none no none
[ "$(run_claim --claim-label claim:gpt)" = 0 ] || fail "pre-existing marker claim should succeed: $(cat "$err")"
if grep -q '^edit' "$log"; then fail "pre-existing markers must not be edited"; fi

echo "==> a model refinement preserves its family marker and commits transactionally"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none 'Owner Project' Ready fix/family
family_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
family_predecessor="$(jq -n --argjson body "$family_body" '[{id:1,user:{login:"evanharmon1"},author_association:"OWNER",body:$body}]')"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$family_predecessor"
make_record no no none yes evanharmon1 claim:gpt none 'Owner Project' Ready fix/model
add_model_fields claim:gpt:terra claim:gpt:terra
[ "$(run_claim --claim-label claim:gpt --model-label claim:gpt:terra)" = 0 ] ||
    fail "model refinement should commit through the claim transaction: $(cat "$err")"
grep -q -- '--add-label claim:gpt:terra' "$log" || fail "model refinement must add its exact model label"
if grep -q -- '--add-label claim:gpt\($\| \)' "$log"; then fail "model refinement must not rewrite the family marker"; fi

echo "==> failed model publication removes only the tentative model refinement"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$family_predecessor"
make_record no no none yes evanharmon1 claim:gpt none 'Owner Project' Ready fix/model
add_model_fields claim:gpt:terra claim:gpt:terra
[ "$(CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt --model-label claim:gpt:terra)" = 4 ] ||
    fail "confirmed absent model record should compensate: $(cat "$err")"
grep -q -- '--remove-label claim:gpt:terra' "$log" || fail "compensation must remove the tentative model label"
if grep -q -- '--remove-label claim:gpt\($\| \)' "$log"; then fail "compensation must preserve the pre-existing family marker"; fi

echo "==> a failed refresh leaves the predecessor current and markers untouched"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none 'Owner Project' Ready fix/predecessor
predecessor_body="$(jq -Rs 'sub("\\n+$"; "")' "$record")"
predecessor="$(jq -n --argjson body "$predecessor_body" '[{id:1,user:{login:"evanharmon1"},author_association:"OWNER",body:$body}]')"
scenario '{"assignees":[{"login":"evanharmon1"}],"labels":[{"name":"claim:gpt"}]}' "$predecessor"
make_record no no none yes evanharmon1 claim:gpt none 'Owner Project' Ready fix/refreshed
[ "$(CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt)" = 4 ] || fail "failed refresh should exit 4"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "failed refresh must preserve only the predecessor"
if grep -q '^edit' "$log"; then fail "failed refresh must not touch inherited markers"; fi

echo "==> label-less repositories remain an explicit manual exception"
scenario "$empty_issue"
make_record yes n/a none yes evanharmon1 n/a none none none
[ "$(run_claim --claim-label none)" = 2 ] || fail "routine transaction must reject label-less repositories"
jq -e '(.assignees | length) == 0' "$issue_file" >/dev/null || fail "routine helper must not partially claim label-less issue"
[ "$(jq 'length' "$comments_file")" -eq 0 ] || fail "routine helper must not publish a label-less record"
[ ! -s "$log" ] || fail "routine helper must perform zero writes for label-less exception"

echo "==> A to B to C takeover retains the canonical predecessor ownership set"
make_record yes no none yes 'alice,bob' claim:gpt none 'Owner Project' Ready fix/predecessor
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
