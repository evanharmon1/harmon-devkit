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

cat >"$stub/status-helper" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
*' --show '*)
    printf 'status show\n' >>"$CLAIM_LOG"
    case "${CLAIM_STATUS_SHOW_RC:-0}" in
    0)
        printf 'Status=%s\nboard=%s\n' "${CLAIM_PRIOR_STATUS:-Ready}" "${CLAIM_BOARD:-Owner Project}"
        ;;
    *) exit "${CLAIM_STATUS_SHOW_RC}" ;;
    esac
    ;;
*)
    printf 'status write\n' >>"$CLAIM_LOG"
    exit "${CLAIM_STATUS_WRITE_RC:-0}"
    ;;
esac
STUB
chmod +x "$stub/status-helper"

issue_file="$tmp/issue.json"
comments_file="$tmp/comments.json"
comments_fail_flag="$tmp/comments.fail"
comments_read_count="$tmp/comments.read-count"
log="$tmp/actions.log"
record="$tmp/record.md"
err="$tmp/err"

scenario() {
    printf '%s' "$1" >"$issue_file"
    printf '%s' "${2:-[]}" >"$comments_file"
    : >"$log"
    rm -f "$comments_fail_flag"
    rm -f "$comments_read_count"
}

make_record() {
    local assignee="$1" label="$2" displaced="$3" chain_assignee="$4" chain_login="$5" chain_label="$6" chain_displaced="$7"
    local board="${8:-Owner Project}" prior="${9:-Ready}" branch="${10:-fix/test}"
    local family="${11:-gpt}" runtime_environment="${12:-coder}"
    cat >"$record" <<EOF
Claiming — starting implementation on branch $branch (session test-session).

Claim record (for \`/wrap\` — undo only what this claim added):
- harness: test
- model: test
- family: $family
- runtime environment: $runtime_environment
- session: test-session
- board: $board
- prior board status: $prior
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
        CLAIM_LOGIN="${RUN_LOGIN:-evanharmon1}" \
        "$helper" --repo evanharmon1/harmon-devkit --issue 543 \
        --record-file "$record" --status-helper "$stub/status-helper" "$@" \
        --family "${RUN_FAMILY:-gpt}" \
        --runtime-environment "${RUN_RUNTIME_ENVIRONMENT:-coder}" \
        >"$tmp/out" 2>"$err" || rc=$?
    printf '%s\n' "$rc"
}

empty_issue='{"assignees":[],"labels":[]}'

echo "==> successful claims order markers, record, then board"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(run_claim --claim-label claim:gpt)" = 0 ] || fail "successful claim should exit 0: $(cat "$err")"
[ "$(sed -n '1p' "$log")" = 'status show' ] || fail "prior board state must be read first"
sed -n '2p' "$log" | grep -q -- '--add-assignee evanharmon1' || fail "assignee must be the first write"
sed -n '3p' "$log" | grep -q -- '--add-label claim:gpt' || fail "label must be the second write"
[ "$(sed -n '4p' "$log")" = comment ] || fail "record must follow marker writes"
[ "$(sed -n '5p' "$log")" = 'status write' ] || fail "board must follow the record"

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
[ "$(cat "$log")" = 'status show' ] ||
    fail "metadata validation may read board provenance but must precede every write"

echo "==> a failed response that committed the exact record reconciles as success"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_COMMENT_MODE=commit_fail run_claim --claim-label claim:gpt)" = 0 ] || fail "committed ambiguous publication should continue"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "reconciled record must remain"
grep -q 'reconciliation confirmed the exact record committed' "$err" || fail "reconciliation must be reported"

echo "==> an unreadable reconciliation leaves visible partial markers"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_COMMENT_MODE=reconcile_fail run_claim --claim-label claim:gpt)" = 6 ] || fail "indeterminate publication should exit 6"
jq -e 'any(.assignees[]; .login == "evanharmon1") and any(.labels[]; .name == "claim:gpt")' "$issue_file" >/dev/null ||
    fail "indeterminate publication must leave markers visible"
if grep -q -- '--remove-' "$log"; then fail "indeterminate publication must not compensate"; fi

echo "==> a newer trusted claim before publication prevents a stale record commit"
scenario '{"assignees":[{"login":"collaborator"}],"labels":[]}'
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
concurrent_record="$tmp/concurrent-record.md"
cp "$record" "$concurrent_record"
result="$(RUN_MUTATE_COMMENTS_ON_READ=2 RUN_CONCURRENT_RECORD="$concurrent_record" \
    run_claim --claim-label claim:gpt)"
[ "$result" = 6 ] || fail "a changed predecessor before publication must exit 6: $(cat "$err")"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "the stale record must not be published"
[ "$(grep -c '^comment$' "$log" || true)" -eq 0 ] || fail "pre-publication lineage drift must stop before the comment write"
grep -q 'newer trusted claim or release appeared' "$err" || fail "lineage collision must be explained"

echo "==> confirmed absence never compensates markers adopted by a newer claim"
scenario '{"assignees":[{"login":"collaborator"}],"labels":[]}'
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
cp "$record" "$concurrent_record"
result="$(RUN_MUTATE_COMMENTS_ON_READ=3 RUN_CONCURRENT_RECORD="$concurrent_record" \
    CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt)"
[ "$result" = 6 ] || fail "a newer claim after failed publication must block compensation: $(cat "$err")"
grep -q 'refusing compensation' "$err" || fail "adopted tentative markers must be reported"
if grep -q -- '--remove-' "$log"; then fail "a newer committed claim must protect tentative markers from compensation"; fi

echo "==> confirmed record absence compensates only this attempt and restores displacement"
scenario '{"assignees":[],"labels":[{"name":"claim:claude"}]}'
make_record yes claim:gpt claim:claude yes evanharmon1 claim:gpt claim:claude
[ "$(CLAIM_COMMENT_MODE=absent_fail run_claim --claim-label claim:gpt --displaced-label claim:claude)" = 4 ] || fail "compensated absence should exit 4: $(cat "$err")"
jq -e '(.assignees | length) == 0 and ([.labels[].name] == ["claim:claude"])' "$issue_file" >/dev/null ||
    fail "compensation must restore the exact pre-write markers"
grep -q -- '--add-label claim:claude' "$log" || fail "displaced label was not restored"

echo "==> compensation failure is loud and leaves a partial recordless claim"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_COMMENT_MODE=absent_fail CLAIM_FAIL_EDIT_MATCH='--remove-label claim:gpt' run_claim --claim-label claim:gpt)" = 7 ] ||
    fail "failed compensation should exit 7"
grep -q 'partial recordless claim remains' "$err" || fail "partial recordless claim must be named"
jq -e 'any(.labels[]; .name == "claim:gpt")' "$issue_file" >/dev/null || fail "failed removal should remain visible"

echo "==> board failure retains the valid claim and reports the board gap"
scenario "$empty_issue"
make_record yes claim:gpt none yes evanharmon1 claim:gpt none
[ "$(CLAIM_STATUS_WRITE_RC=1 run_claim --claim-label claim:gpt)" = 5 ] || fail "board failure should exit 5"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "board failure must retain the durable record"
grep -q 'VALID CLAIM COMMITTED' "$err" || fail "valid-claim board gap must be explicit"

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

echo "==> repositories without labels or boards still get an assignee-backed record"
scenario "$empty_issue"
make_record yes n/a none yes evanharmon1 n/a none none none
[ "$(CLAIM_STATUS_SHOW_RC=3 CLAIM_STATUS_WRITE_RC=3 run_claim --claim-label none)" = 3 ] || fail "boardless label-less claim should exit benign 3"
jq -e 'any(.assignees[]; .login == "evanharmon1")' "$issue_file" >/dev/null || fail "label-less claim must be assignee-backed"
[ "$(jq 'length' "$comments_file")" -eq 1 ] || fail "label-less claim still requires a record"
if grep -q -- '--add-label' "$log"; then fail "label-less repository must not invent a label"; fi

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
if grep -q '^edit\|^comment$\|^status write$' "$log"; then fail "forged victim rejection must perform zero writes"; fi

echo "PASS: claim transaction semantics"
