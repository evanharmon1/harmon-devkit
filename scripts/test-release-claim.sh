#!/usr/bin/env bash
# test-release-claim.sh — offline behavioral tests for release-claim.sh's jq
# invocation: large API payloads must flow through jq via file, never argv
# (devkit#866), and a jq failure must be distinguishable from a `gh api`
# failure so it can never masquerade as "could not fetch comments".
set -euo pipefail
cd "$(dirname "$0")/.."

script="$PWD/ai/skills/universal/track-work/assets/release-claim.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

stub="$tmp/bin"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = api ]; then
    shift
    path=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --paginate | --slurp) shift ;;
        *) path="$1"; shift ;;
        esac
    done
    case "$path" in
    */timeline)
        [ ! -e "${RC_TIMELINE_FAIL_FLAG:-/nonexistent}" ] || exit 1
        cat "$RC_TIMELINE_FILE"
        ;;
    */comments)
        [ ! -e "${RC_COMMENTS_FAIL_FLAG:-/nonexistent}" ] || exit 1
        if [ -n "${RC_COMMENTS_MALFORMED:-}" ]; then
            printf 'not valid json\n'
        else
            cat "$RC_COMMENTS_FILE"
        fi
        ;;
    *)
        cat "$RC_ISSUE_FILE"
        ;;
    esac
    exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
    cat "$RC_ISSUE_FILE"
    exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
    if [ -n "${RC_PR_LIST_FILE:-}" ] && [ -e "$RC_PR_LIST_FILE" ]; then
        cat "$RC_PR_LIST_FILE"
    else
        printf '[]\n'
    fi
    exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    [ -z "${RC_PR_VIEW_FAIL:-}" ] || exit 1
    pr_num="${3:-}"
    if [ -n "${RC_PR_DIR:-}" ] && [ -e "$RC_PR_DIR/$pr_num.json" ]; then
        cat "$RC_PR_DIR/$pr_num.json"
    elif [ -n "${RC_PR_FILE:-}" ] && [ -e "$RC_PR_FILE" ]; then
        cat "$RC_PR_FILE"
    else
        printf '{"number":%s,"state":"OPEN","isCrossRepository":false,"headRefName":"fix/test","labels":[]}\n' "${pr_num:-1}"
    fi
    exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = edit ]; then
    [ -z "${RC_LOG:-}" ] || printf 'gh %s\n' "$*" >>"$RC_LOG"
    [ -z "${RC_FAIL_PR_EDIT:-}" ] || exit 1
    pr_num="${3:-}"
    target=""
    if [ -n "${RC_PR_DIR:-}" ] && [ -e "$RC_PR_DIR/$pr_num.json" ]; then
        target="$RC_PR_DIR/$pr_num.json"
    elif [ -n "${RC_PR_FILE:-}" ] && [ -e "$RC_PR_FILE" ]; then
        target="$RC_PR_FILE"
    fi
    if [ -n "$target" ] && [ -z "${RC_IGNORE_PR_REMOVE:-}" ]; then
        shift 3
        while [ "$#" -gt 0 ]; do
            case "$1" in
            --remove-label)
                jq --arg l "$2" '.labels |= map(select(.name != $l))' "$target" >"$target.next"
                mv "$target.next" "$target"
                shift 2
                ;;
            *) shift ;;
            esac
        done
    fi
    exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = comment ]; then
    [ -z "${RC_LOG:-}" ] || printf 'gh %s\n' "$*" >>"$RC_LOG"
    if [ -n "${RC_COMMENT_OUT:-}" ]; then
        cat >"$RC_COMMENT_OUT"
    else
        cat >/dev/null
    fi
    exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = edit ]; then
    [ -z "${RC_LOG:-}" ] || printf 'gh %s\n' "$*" >>"$RC_LOG"
    [ -z "${RC_FAIL_ISSUE_EDIT:-}" ] || exit 1
    if [ -n "${RC_MUTATE_ISSUE:-}" ]; then
        shift 3
        while [ "$#" -gt 0 ]; do
            case "$1" in
            --remove-label)
                jq --arg l "$2" '.labels |= map(select(.name != $l))' "$RC_ISSUE_FILE" >"$RC_ISSUE_FILE.next"
                mv "$RC_ISSUE_FILE.next" "$RC_ISSUE_FILE"
                shift 2
                ;;
            --add-label)
                jq --arg l "$2" '.labels += [{"name":$l}]' "$RC_ISSUE_FILE" >"$RC_ISSUE_FILE.next"
                mv "$RC_ISSUE_FILE.next" "$RC_ISSUE_FILE"
                shift 2
                ;;
            --remove-assignee)
                jq --arg a "$2" '.assignees |= map(select((.login | ascii_downcase) != ($a | ascii_downcase)))' "$RC_ISSUE_FILE" >"$RC_ISSUE_FILE.next"
                mv "$RC_ISSUE_FILE.next" "$RC_ISSUE_FILE"
                shift 2
                ;;
            *) shift ;;
            esac
        done
    fi
    exit 0
fi
exit 1
STUB
chmod +x "$stub/gh"

issue_file="$tmp/issue.json"
comments_file="$tmp/comments.json"
timeline_file="$tmp/timeline.json"

# A single trusted "Claiming —" comment from a currently-assigned collaborator,
# proven historical via a timeline "assigned" event before the comment's
# updated_at. This is the smallest fixture release-claim.sh can compute a
# verdict from; the large-fixture case pads the timeline and comments page
# around the exact same claim and must reach the exact same decision.
make_issue() {
    cat >"$issue_file" <<'EOF'
{"state":"OPEN","assignees":[{"login":"workerbot"}],"labels":[{"name":"claim:gpt"}]}
EOF
}

make_comment_body() {
    cat <<'EOF'
Claiming — starting implementation on branch fix/test (session test-session).

Preflight (§3):
assignee added by this claim: quoted phrase
`claim:` label added by this claim: quoted phrase
`claim:` label displaced by this claim: quoted phrase
assignee logins owned by this claim chain: quoted phrase
`claim:` label owned by this claim chain: quoted phrase
`claim:` label displaced by this claim chain: quoted phrase
assignee owned by this claim chain: quoted phrase
assignee login owned by this claim chain: quoted phrase
`claim:` model label added by this claim: quoted phrase
`claim:` model label owned by this claim chain: quoted phrase

Claim record (for `/wrap` — undo only what this claim added):
- harness: test
- model: test
- family: gpt
- runtime environment: coder
- session: test-session
- assignee added by this claim: yes
- `claim:` label added by this claim: claim:gpt
- `claim:` label displaced by this claim: none
- assignee logins owned by this claim chain: workerbot
- `claim:` label owned by this claim chain: claim:gpt
- `claim:` label displaced by this claim chain: none
EOF
}

make_model_comment_body() {
    local family_label="${1:-claim:gpt}" model_label="${2:-claim:gpt:gpt-5}"
    cat <<EOF
Claiming — starting implementation on branch fix/test (session test-session).

Claim record (for \`/wrap\` — undo only what this claim added):
- harness: test
- model: test
- family: gpt
- runtime environment: coder
- session: test-session
- assignee added by this claim: yes
- \`claim:\` label added by this claim: $family_label
- \`claim:\` model label added by this claim: $model_label
- \`claim:\` label displaced by this claim: none
- assignee logins owned by this claim chain: workerbot
- \`claim:\` label owned by this claim chain: $family_label
- \`claim:\` model label owned by this claim chain: $model_label
- \`claim:\` label displaced by this claim chain: none
EOF
}

make_legacy_comment_body() {
    cat <<'EOF'
Claiming — starting implementation on branch fix/test (session test-session).

Preflight (§3):
assignee added by this claim: quoted phrase
label added by this claim: quoted phrase
label displaced by this claim: quoted phrase
assignee owned by this claim chain: quoted phrase
assignee login owned by this claim chain: quoted phrase
label owned by this claim chain: quoted phrase
label displaced by this claim chain: quoted phrase

Claim record (for `/wrap` — undo only what this claim added):
- assignee added by this claim: yes
- `claim:` label added by this claim: claim:gpt
- `claim:` label displaced by this claim: none
EOF
}

# comments/timeline pages are `gh api --paginate --slurp` output: an array
# whose single element is the one page's own array of items.
make_comments_file() {
    local pad_comments="$1"
    jq -n --arg body "$(make_comment_body)" --argjson pad "$pad_comments" '
        [(
            [{id: 1, user: {login: "workerbot"}, author_association: "COLLABORATOR",
              created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z",
              body: $body}]
            + [range($pad) | {id: (100 + .), user: {login: "rando"},
                               author_association: "NONE",
                               created_at: "2026-01-02T00:00:00Z",
                               body: ("padding comment " * 50)}]
        )]
    ' >"$comments_file"
}

make_timeline_file() {
    local pad_events="$1"
    jq -n --argjson pad "$pad_events" '
        [(
            [{event: "assigned", created_at: "2026-01-01T00:00:00Z",
              assignee: {login: "workerbot"}}]
            + [range($pad) | {event: "labeled", label: {name: ("padding-" * 20)}}]
        )]
    ' >"$timeline_file"
}

run_release() {
    local rc=0
    env PATH="$stub:$PATH" \
        RC_ISSUE_FILE="$issue_file" RC_COMMENTS_FILE="$comments_file" \
        RC_TIMELINE_FILE="$timeline_file" \
        RC_TIMELINE_FAIL_FLAG="${RUN_TIMELINE_FAIL_FLAG:-}" \
        RC_COMMENTS_FAIL_FLAG="${RUN_COMMENTS_FAIL_FLAG:-}" \
        RC_COMMENTS_MALFORMED="${RUN_COMMENTS_MALFORMED:-}" \
        "$script" --repo test-owner/test-repo --issue 1 --reason "test" --dry-run \
        >"$tmp/out" 2>"$tmp/err" || rc=$?
    printf '%s\n' "$rc"
}

echo "==> 1. a large timeline (>256KB) and comments page (>128KB) reach the same verdict as small fixtures"
make_issue

# Both structured and legacy record grammars must ignore record-shaped phrases
# in the free-form preflight block. The heading-less legacy record remains
# readable under its historical whole-body grammar.
make_comments_file 0
make_timeline_file 0
[ "$(run_release)" = 0 ] || fail "new-format record with quoted preflight phrases must release: $(cat "$tmp/err")"
make_legacy_comments_file() {
    jq -n --arg body "$(make_legacy_comment_body)" '[([{id: 1, user: {login: "workerbot"}, author_association: "COLLABORATOR", created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z", body: $body}])]' >"$comments_file"
}
make_legacy_comments_file
[ "$(run_release)" = 0 ] || fail "legacy record with quoted preflight phrases must release: $(cat "$tmp/err")"
grep -q 'remove-label claim:gpt' "$tmp/err" || fail "legacy record must retain the expected release plan"

# A heading-less older record keeps its prior behavior (whole-body legacy scan).
make_legacy_comments_file
jq '.[0][0].body |= sub("Claim record \\(for `/wrap` — undo only what this claim added\\):\\n"; "")' "$comments_file" >"$tmp/comments.no-heading"
cp "$tmp/comments.no-heading" "$comments_file"
[ "$(run_release)" = 0 ] || fail "heading-less legacy record behavior changed: $(cat "$tmp/err")"
if grep -Eq -- '--remove-(label|assignee)' "$tmp/err"; then
    fail "heading-less record must leave live markers untouched: $(cat "$tmp/err")"
fi

make_comments_file 0
make_timeline_file 0
[ "$(run_release)" = 0 ] || fail "small fixture should release cleanly: $(cat "$tmp/err")"
cp "$tmp/err" "$tmp/err.small"

make_comments_file 400
make_timeline_file 4000
[ "$(wc -c <"$timeline_file" | tr -d ' ')" -gt 262144 ] || fail "timeline fixture must exceed 256 KB"
[ "$(wc -c <"$comments_file" | tr -d ' ')" -gt 131072 ] || fail "comments fixture must exceed 128 KB"
[ "$(run_release)" = 0 ] || fail "large fixture should release cleanly, not fail on argument size: $(cat "$tmp/err")"
# The #477 author_association diagnostic reports every value it actually saw,
# so it necessarily differs between fixtures once padding comments (NONE) join
# the single real comment (COLLABORATOR) — that line is excluded from the
# verdict comparison; everything else must still match exactly.
grep -v 'author_association values seen' "$tmp/err.small" >"$tmp/err.small.filtered"
grep -v 'author_association values seen' "$tmp/err" >"$tmp/err.filtered"
diff "$tmp/err.small.filtered" "$tmp/err.filtered" >/dev/null || fail "large fixture reached a different verdict than the small fixture"

echo "==> 2. static: the script never passes trusted/timeline through jq argv again"
if grep -q -- '--argjson trusted' "$script" || grep -q -- '--argjson timeline' "$script"; then
    fail "release-claim.sh must not pass \$trusted_json/\$lineage_timeline via --argjson (devkit#866)"
fi

echo "==> 3. a forced jq failure reports jq's own message, not 'could not fetch comments'"
make_comments_file 0
make_timeline_file 0
rc="$(RUN_COMMENTS_MALFORMED=1 run_release)"
[ "$rc" = 2 ] || fail "a jq failure must fail closed with exit 2, got $rc: $(cat "$tmp/err")"
grep -q "could not fetch comments" "$tmp/err" && fail "a jq failure must not masquerade as a fetch failure: $(cat "$tmp/err")"
grep -qi "jq" "$tmp/err" || fail "a jq failure must name jq: $(cat "$tmp/err")"

echo "==> 4. an oversized issue body (>128KB) reaches the same verdict as a small one"
# The #477 any-claiming check feeds $issue_json to jq — a second large input
# alongside the timeline/comments pages above. A long issue body must not
# reintroduce the class of bug #868 just removed for the other two.
jq -n '{state: "OPEN", assignees: [{login: "workerbot"}], labels: [{name: "claim:gpt"}],
        body: ("padding issue body " * 10000)}' >"$issue_file"
[ "$(wc -c <"$issue_file" | tr -d ' ')" -gt 131072 ] || fail "issue fixture must exceed 128 KB"
make_comments_file 0
make_timeline_file 0
[ "$(run_release)" = 0 ] || fail "an oversized issue body must not fail on argument size: $(cat "$tmp/err")"
make_issue

echo "==> 5. a forced failure evaluating claim-protocol evidence fails closed, never falls through to exit 3"
# #477 exit 5 depends on $any_claiming_file being populated; before this test
# was added, an unguarded jq failure there left the file empty and exit-5's
# consumer silently fell through to the benign exit 3 with markers still
# surviving (Codex cloud review, round 1) — the exact bug class #868 removed
# elsewhere in this same function, reintroduced here. Malformed comments
# break this step (it parses the same comments page) before the later
# trusted/timeline step ever runs, so the message below proves it is this
# step's own guard that caught it, not a coincidence of ordering.
make_comments_file 0
make_timeline_file 0
rc="$(RUN_COMMENTS_MALFORMED=1 run_release)"
[ "$rc" = 2 ] || fail "a claim-protocol-evidence jq failure must fail closed with exit 2, got $rc: $(cat "$tmp/err")"
[ "$rc" != 3 ] || fail "a claim-protocol-evidence jq failure must never fall through to the benign exit 3"
grep -qi "claim-protocol evidence" "$tmp/err" || fail "the failure must name what step broke: $(cat "$tmp/err")"

echo "==> 6. an unreachable gh api still reports the original fetch-failure message"
: >"$tmp/comments.fail"
rc="$(RUN_COMMENTS_FAIL_FLAG="$tmp/comments.fail" run_release)"
[ "$rc" = 2 ] || fail "a gh api failure must fail closed with exit 2, got $rc: $(cat "$tmp/err")"
grep -q "could not fetch comments" "$tmp/err" || fail "a gh api failure must report 'could not fetch comments': $(cat "$tmp/err")"

echo "==> 7. claim release removes claim:* and leaves the implementer record in place (#1269)"
# The four implementer values are a record of fact, not a claim marker: the
# release plan removes the claim label and never names a model-* label.
jq -n '{state: "OPEN", assignees: [{login: "workerbot"}],
        labels: ([{name: "claim:gpt"}] + ([("model-family:gpt", "model:sol",
                  "model-version:6.1", "model-effort:high")] | map({name: .})))}' >"$issue_file"
make_comments_file 0
make_timeline_file 0
[ "$(run_release)" = 0 ] || fail "an issue carrying the implementer record must release cleanly: $(cat "$tmp/err")"
grep -qF -- "--remove-label claim:gpt" "$tmp/err" || fail "the release plan must remove claim:gpt: $(cat "$tmp/err")"
if grep -E -- '--remove-label model(-family|-version|-effort)?:' "$tmp/err"; then
    fail "claim release must never remove an implementer label"
fi
make_issue

echo "==> 8. a handoff retry accepts only the exact prior release with its key and cleared markers"
key="$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update("test-handoff").digest("hex"))')"
make_issue
jq -n --arg claim "$(make_comment_body)" --arg key "$key" '[[(
    {id: 1, user: {login: "workerbot"}, author_association: "COLLABORATOR",
     created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z", body: $claim},
    {id: 2, user: {login: "github-actions[bot]"}, author_association: "NONE",
     created_at: "2026-01-03T00:00:00Z", updated_at: "2026-01-03T00:00:00Z",
     body: ("Claim released — plan-revise handoff key=" + $key + ". (Supersedes the claim record above.)")}
)]]' >"$comments_file"
jq -n '[[(
    {event: "assigned", created_at: "2026-01-01T00:00:00Z", assignee: {login: "workerbot"}}
)]]' >"$timeline_file"
cat >"$issue_file" <<'EOF'
{"state":"OPEN","assignees":[],"labels":[]}
EOF
run_idempotent_release() {
    local rc=0
    env PATH="$stub:$PATH" \
        RC_ISSUE_FILE="$issue_file" RC_COMMENTS_FILE="$comments_file" \
        RC_TIMELINE_FILE="$timeline_file" \
        "$script" --repo test-owner/test-repo --issue 1 \
        --reason "plan-revise handoff key=$key" --branch fix/test \
        --idempotency-key "$key" --dry-run >"$tmp/out" 2>"$tmp/err" || rc=$?
    printf '%s\n' "$rc"
}
[ "$(run_idempotent_release)" = 0 ] || fail "a completed exact handoff release must be an idempotent success: $(cat "$tmp/err")"
grep -q 'idempotent retry' "$tmp/err" || fail "idempotent success must say it verified the prior release"
cat >"$issue_file" <<'EOF'
{"state":"OPEN","assignees":[],"labels":[{"name":"claim:gpt"}]}
EOF
[ "$(run_idempotent_release)" = 3 ] || fail "a surviving claim marker must prevent idempotent success"
grep -q 'cannot be proven complete' "$tmp/err" || fail "partial release refusal must explain the surviving marker"

echo "==> 9. release-claim removes claim labels from issue and every open same-repo delivery PR"
pr_dir="$tmp/prs"
pr_list_file="$tmp/pr-list.json"
rc_log="$tmp/rc.log"
rc_comment="$tmp/rc-comment.txt"
mkdir -p "$pr_dir"
cat >"$issue_file" <<'EOF'
{"state":"OPEN","assignees":[{"login":"workerbot"}],"labels":[{"name":"claim:gpt"},{"name":"claim:gpt:gpt-5"},{"name":"bug"}],"closedByPullRequestsReferences":[{"number":10},{"number":11}]}
EOF
cat >"$pr_list_file" <<'EOF'
[{"number":12,"headRefName":"fix/test","isCrossRepository":false},{"number":13,"headRefName":"fix/test","isCrossRepository":true}]
EOF
cat >"$pr_dir/10.json" <<'EOF'
{"number":10,"state":"OPEN","isCrossRepository":false,"headRefName":"fix/test","labels":[{"name":"claim:gpt"},{"name":"claim:gpt:gpt-5"},{"name":"needs-review"}]}
EOF
cat >"$pr_dir/11.json" <<'EOF'
{"number":11,"state":"CLOSED","isCrossRepository":false,"headRefName":"fix/test","labels":[{"name":"claim:gpt"}]}
EOF
cat >"$pr_dir/12.json" <<'EOF'
{"number":12,"state":"OPEN","isCrossRepository":false,"headRefName":"fix/test","labels":[{"name":"claim:gpt"}]}
EOF
cat >"$pr_dir/13.json" <<'EOF'
{"number":13,"state":"OPEN","isCrossRepository":true,"headRefName":"fix/test","labels":[{"name":"claim:gpt"}]}
EOF
jq -n --arg claim "$(make_model_comment_body claim:gpt claim:gpt:gpt-5)" '[[(
    {id: 1, user: {login: "workerbot"}, author_association: "COLLABORATOR",
     created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z", body: $claim}
)]]' >"$comments_file"
: >"$rc_log"
env PATH="$stub:$PATH" \
    RC_ISSUE_FILE="$issue_file" RC_COMMENTS_FILE="$comments_file" \
    RC_TIMELINE_FILE="$timeline_file" RC_PR_DIR="$pr_dir" \
    RC_PR_LIST_FILE="$pr_list_file" RC_LOG="$rc_log" \
    RC_MUTATE_ISSUE=1 RC_COMMENT_OUT="$rc_comment" \
    "$script" --repo test-owner/test-repo --issue 1 \
    --reason "plan-revise handoff key=$key" --branch fix/test >"$tmp/out" 2>"$tmp/err" ||
    fail "PR mirror release should succeed: $(cat "$tmp/err")"
jq -e '([.labels[].name] | sort) == ["bug"] and (.assignees | length) == 0' "$issue_file" >/dev/null ||
    fail "issue claim labels or assignee not cleared: $(cat "$issue_file")"
jq -e '([.labels[].name] | sort) == ["needs-review"]' "$pr_dir/10.json" >/dev/null ||
    fail "open PR #10 claim labels not cleared: $(cat "$pr_dir/10.json")"
jq -e '.labels == []' "$pr_dir/12.json" >/dev/null ||
    fail "open branch PR #12 claim labels not cleared: $(cat "$pr_dir/12.json")"
jq -e '.labels | length == 1' "$pr_dir/11.json" >/dev/null || fail "closed PR #11 should stay untouched"
jq -e '.labels | length == 1' "$pr_dir/13.json" >/dev/null || fail "cross-repo PR #13 should stay untouched"
grep -q '^Claim released — ' "$rc_comment" || fail "supersede comment must post after verification"

echo "==> 10. non-sticking PR removal fails exit 4, keeps assignee and withholds comment, then retry finishes"
cat >"$issue_file" <<'EOF'
{"state":"OPEN","assignees":[{"login":"workerbot"}],"labels":[{"name":"claim:gpt"}],"closedByPullRequestsReferences":[{"number":10}]}
EOF
cat >"$pr_dir/10.json" <<'EOF'
{"number":10,"state":"OPEN","isCrossRepository":false,"headRefName":"fix/test","labels":[{"name":"claim:gpt"}]}
EOF
printf '[]\n' >"$pr_list_file"
jq -n --arg claim "$(make_comment_body)" '[[(
    {id: 1, user: {login: "workerbot"}, author_association: "COLLABORATOR",
     created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z", body: $claim}
)]]' >"$comments_file"
rm -f "$rc_comment"
rc_fail=0
env PATH="$stub:$PATH" \
    RC_ISSUE_FILE="$issue_file" RC_COMMENTS_FILE="$comments_file" \
    RC_TIMELINE_FILE="$timeline_file" RC_PR_DIR="$pr_dir" \
    RC_PR_LIST_FILE="$pr_list_file" RC_IGNORE_PR_REMOVE=1 \
    RC_MUTATE_ISSUE=1 RC_COMMENT_OUT="$rc_comment" \
    "$script" --repo test-owner/test-repo --issue 1 \
    --reason "plan-revise handoff key=$key" --branch fix/test >"$tmp/out" 2>"$tmp/err" || rc_fail=$?
[ "$rc_fail" = 4 ] || fail "non-sticking PR write must exit 4 (got $rc_fail): $(cat "$tmp/err")"
[ ! -e "$rc_comment" ] || fail "supersede comment must be withheld on PR verification failure"
jq -e '(.assignees | length) == 1' "$issue_file" >/dev/null ||
    fail "assignee must stay live for trusted retry after PR mirror failure"

env PATH="$stub:$PATH" \
    RC_ISSUE_FILE="$issue_file" RC_COMMENTS_FILE="$comments_file" \
    RC_TIMELINE_FILE="$timeline_file" RC_PR_DIR="$pr_dir" \
    RC_PR_LIST_FILE="$pr_list_file" RC_MUTATE_ISSUE=1 RC_COMMENT_OUT="$rc_comment" \
    "$script" --repo test-owner/test-repo --issue 1 \
    --reason "plan-revise handoff key=$key" --branch fix/test >"$tmp/out" 2>"$tmp/err" ||
    fail "retry after partial PR failure should complete: $(cat "$tmp/err")"
jq -e '.labels == []' "$pr_dir/10.json" >/dev/null || fail "retry must clear remaining PR #10 label"
jq -e '(.assignees | length) == 0' "$issue_file" >/dev/null || fail "retry must clear assignee"
grep -q '^Claim released — ' "$rc_comment" || fail "retry must post supersede comment"

echo "==> 11. idempotent retry refuses if an open delivery PR still carries a claim label"
jq -n --arg claim "$(make_comment_body)" --arg key "$key" '[[(
    {id: 1, user: {login: "workerbot"}, author_association: "COLLABORATOR",
     created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z", body: $claim},
    {id: 2, user: {login: "github-actions[bot]"}, author_association: "NONE",
     created_at: "2026-01-03T00:00:00Z", updated_at: "2026-01-03T00:00:00Z",
     body: ("Claim released — plan-revise handoff key=" + $key + ". (Supersedes the claim record above.)")}
)]]' >"$comments_file"
cat >"$issue_file" <<'EOF'
{"state":"OPEN","assignees":[],"labels":[],"closedByPullRequestsReferences":[{"number":10}]}
EOF
cat >"$pr_dir/10.json" <<'EOF'
{"number":10,"state":"OPEN","isCrossRepository":false,"headRefName":"fix/test","labels":[{"name":"claim:gpt"}]}
EOF
rc_pr_left=0
env PATH="$stub:$PATH" \
    RC_ISSUE_FILE="$issue_file" RC_COMMENTS_FILE="$comments_file" \
    RC_TIMELINE_FILE="$timeline_file" RC_PR_DIR="$pr_dir" \
    RC_PR_LIST_FILE="$pr_list_file" \
    "$script" --repo test-owner/test-repo --issue 1 \
    --reason "plan-revise handoff key=$key" --branch fix/test \
    --idempotency-key "$key" >"$tmp/out" 2>"$tmp/err" || rc_pr_left=$?
[ "$rc_pr_left" = 3 ] || fail "surviving PR claim label must prevent idempotent success (got $rc_pr_left)"
cat >"$pr_dir/10.json" <<'EOF'
{"number":10,"state":"OPEN","isCrossRepository":false,"headRefName":"fix/test","labels":[]}
EOF
env PATH="$stub:$PATH" \
    RC_ISSUE_FILE="$issue_file" RC_COMMENTS_FILE="$comments_file" \
    RC_TIMELINE_FILE="$timeline_file" RC_PR_DIR="$pr_dir" \
    RC_PR_LIST_FILE="$pr_list_file" \
    "$script" --repo test-owner/test-repo --issue 1 \
    --reason "plan-revise handoff key=$key" --branch fix/test \
    --idempotency-key "$key" >"$tmp/out" 2>"$tmp/err" ||
    fail "idempotent retry must succeed once both issue and PR are clear"

echo "ALL PASS"
