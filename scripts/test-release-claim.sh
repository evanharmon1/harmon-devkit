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
if [ "${1:-}" = issue ] && [ "${2:-}" = comment ]; then
    cat >/dev/null
    exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = edit ]; then
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

echo "ALL PASS"
