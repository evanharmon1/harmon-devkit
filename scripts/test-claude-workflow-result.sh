#!/usr/bin/env bash
# Offline fixtures; GH writes are captured by a stub.
set -euo pipefail

# Hooks export GIT_DIR/GIT_WORK_TREE; left set, every `git` below would
# retarget the CALLING repository instead of the fixture.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Neutralize every out-of-tree source of git config so the fixture is hermetic
# (same sanitation as test-worktree.sh).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
git_config_count="${GIT_CONFIG_COUNT:-0}"
case "$git_config_count" in
'' | *[!0-9]*) git_config_count=0 ;;
esac
i=0
while [ "$i" -lt "$git_config_count" ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_ALTERNATE_OBJECT_DIRECTORIES

cd "$(dirname "$0")/.."
guard=${CLAUDE_RESULT_SCRIPT:-"$PWD/scripts/claude-workflow-result.sh"}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cat >"$scratch/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$COMMENT_CAPTURE"
exit "${COMMENT_EXIT:-0}"
STUB
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
export COMMENT_CAPTURE="$scratch/comment"
export GH_REPO=owner/repo TARGET=42
export GH_TOKEN=ghp_testcredential REDACT_PRIMARY=sk-ant-primary REDACT_ALT=sk-ant-alternate
export REDACT_APP_TOKEN=ghp_testgithub
export GITHUB_OUTPUT="$scratch/output" EXECUTION_FILE="$scratch/execution.json"

fail() { # shell-robustness: ok — this reporter always exits 1
    echo "TEST FAIL: $*" >&2
    exit 1
}

run() {
    expected_retry=$1
    expected_failed=$2
    export ACTION_OUTCOME=$3 HAS_ALT=$4
    : >"$GITHUB_OUTPUT"
    rm -f "$COMMENT_CAPTURE"
    "$guard" >"$scratch/log"
    [ "$(cat "$GITHUB_OUTPUT")" = "$(printf 'retry=%s\nfailed=%s' "$expected_retry" "$expected_failed")" ] ||
        fail "retry=$expected_retry failed=$expected_failed expected for $ACTION_OUTCOME / $HAS_ALT"
    if [ "$expected_failed" = true ]; then
        [ -s "$COMMENT_CAPTURE" ] || fail 'failure comment missing'
        [ -s "$scratch/log" ] || fail 'failure log missing'
    else
        [ ! -e "$COMMENT_CAPTURE" ] || fail 'success must not post a failure'
    fi
}

fixture() {
    printf '[{"type":"result","result":"OAuth token expired","subtype":"%s","is_error":%s,"total_cost_usd":%s,"modelUsage":%s}]\n' \
        "$1" "$2" "$3" "$4" >"$EXECUTION_FILE"
}

unset MAX_TURNS
fixture success true 0 '{}'
run true true failure true
grep -q 'OAuth token expired' "$scratch/log" || fail 'result text missing'
for field in subtype is_error total_cost_usd modelUsage; do
    grep -q "$field" "$COMMENT_CAPTURE" || fail "$field missing from comment"
done
run false true failure false
fixture success false 0 '{}'
run false false success true
# Turn-cap exceptions require explicit successful results and an exceeded cap.
turn_fixture() {
    fixture success "$2" 3.94 '{}'
    jq --argjson turns "$1" '.[0].num_turns = $turns' "$EXECUTION_FILE" >"$scratch/turns.json"
    mv "$scratch/turns.json" "$EXECUTION_FILE"
}
turn_fixture 73 false
MAX_TURNS=60 run false false failure true
grep -q '::warning::.*73.*60' "$scratch/log" || fail 'turn-cap warning missing counts'
echo 'PASS: successful 73-turn review above cap 60; no retry or comment, warning printed'
turn_fixture '"73"' false
MAX_TURNS=60 run false true failure true
warning_status=0
grep -q '^::warning::Claude succeeded after' "$scratch/log" || warning_status=$?
[ "$warning_status" = 1 ] || fail 'string turn count must not produce a turn-cap warning'
echo 'PASS: string num_turns remains failure without a turn-cap warning'
turn_fixture 73 false
MAX_TURNS=60 run false false success true
warning_status=0
grep -q '^::warning::Claude succeeded after' "$scratch/log" || warning_status=$?
[ "$warning_status" = 1 ] || fail 'successful action must not produce a turn-cap warning'
echo 'PASS: successful action above cap passes without a turn-cap warning'
turn_fixture 60 false
MAX_TURNS=60 run false true failure true
echo 'PASS: turns equal to cap remain failure'
turn_fixture 73 false
run false true failure true
echo 'PASS: unset MAX_TURNS remains failure'
turn_fixture 73 true
MAX_TURNS=60 run false true failure true
echo 'PASS: error result above cap remains failure'
turn_fixture 73 false
MAX_TURNS=invalid run false true failure true
echo 'PASS: non-numeric MAX_TURNS remains failure'
MAX_TURNS='' run false true failure true
echo 'PASS: empty MAX_TURNS remains failure'
MAX_TURNS=0 run false true failure true
echo 'PASS: zero MAX_TURNS remains failure'
unset MAX_TURNS
# A successful step must never retry even if its execution result is erroneous.
fixture success true 0 '{}'
run false true success true
fixture error true 1 '{}'
run false true failure true
fixture error true 0 '{"opus":{"inputTokens":1}}'
run false true failure true
fixture error true 0 null
run false true failure true
printf '[{"type":"result","is_error":true,"modelUsage":{}}]' >"$EXECUTION_FILE"
run false true failure true
# Only the last result controls the decision.
printf '[{"type":"result","is_error":true,"total_cost_usd":0,"modelUsage":{}},{"type":"result","subtype":"success","is_error":false}]' >"$EXECUTION_FILE"
run false false success true
printf '{broken' >"$EXECUTION_FILE"
run false true failure true
printf '[] []' >"$EXECUTION_FILE"
run false true failure true
printf '{"type":"result","is_error":true,"total_cost_usd":0,"modelUsage":{}}' >"$EXECUTION_FILE"
run false true failure true
printf '[{"type":"system"}]' >"$EXECUTION_FILE"
run false true failure true
rm "$EXECUTION_FILE"
run false true failure true
# Credential values, token patterns, and review mentions never leave the script.
fixture error true 0 '{}'
jq '.[0].result = "sk-ant-primary sk-ant-alternate ghp_testcredential ghp_testgithub sk-ant-unknown \u0040codex ``` ::error::injected"' \
    "$EXECUTION_FILE" >"$scratch/redacted.json"
mv "$scratch/redacted.json" "$EXECUTION_FILE"
run true true failure true
# Prove the detector matches the raw input, and require grep's no-match status.
grep -qiE 'sk-ant-|ghp_|@co[d]ex' "$EXECUTION_FILE" || fail 'leak detector did not match fixture'
leak_status=0
grep -qiE 'sk-ant-|ghp_|@co[d]ex' "$scratch/log" "$COMMENT_CAPTURE" || leak_status=$?
[ "$leak_status" = 1 ] || fail 'credential or review mention leaked, or grep failed'
grep -q '\[REDACTED\]' "$COMMENT_CAPTURE" || fail 'redaction absent'
# Comment delivery must never change a zero-usage failure decision.
fixture success true 0 '{}'
COMMENT_EXIT=1 run true true failure true
grep -q '::warning::Could not post' "$scratch/log" || fail 'comment failure warning missing'
# Retiring the primary output leaves the next inspection with no stale result.
fixture success true 0 '{}'
ARCHIVE_EXECUTION=true run true true failure true
[ ! -f "$EXECUTION_FILE" ] || fail 'primary execution file was not retired'
[ -f "$EXECUTION_FILE.primary" ] || fail 'archived primary file missing'
run false true failure true
grep -q 'Execution file missing' "$scratch/log" || fail 'alternate reported stale primary result'

# Local branch cleanup returns to the starting commit, never a remote branch.
export DEFAULT_BRANCH=main
mkdir "$scratch/repo"
(
    cd "$scratch/repo"
    git init -q
    git config user.name 'Fixture'
    git config user.email 'fixture@example.invalid'
    git checkout -q -b main
    git commit -q --allow-empty -m initial
    START_COMMIT=$(git rev-parse HEAD)
    export START_COMMIT
    git checkout -q -b claude/fixture
    git update-ref refs/remotes/origin/claude/fixture HEAD
    PRIMARY_BRANCH=claude/fixture "$guard" cleanup >/dev/null 2>&1
    if git show-ref --verify --quiet refs/heads/claude/fixture; then
        fail 'local Claude branch survived'
    fi
    [ "$(git rev-parse HEAD)" = "$START_COMMIT" ] || fail 'starting commit not restored'
    git show-ref --verify --quiet refs/remotes/origin/claude/fixture || fail 'remote ref was changed'
    PRIMARY_BRANCH=claude/absent "$guard" cleanup || fail 'absent branch should be inert'
    git checkout -q -b unrelated
    if PRIMARY_BRANCH=unrelated "$guard" cleanup >/dev/null 2>&1; then
        fail 'unrelated branch accepted for cleanup'
    fi
    git show-ref --verify --quiet refs/heads/unrelated || fail 'unrelated branch removed'
    git checkout -q -b claude/default
    if DEFAULT_BRANCH=claude/default PRIMARY_BRANCH=claude/default "$guard" cleanup >/dev/null 2>&1; then
        fail 'default branch accepted for cleanup'
    fi
    # Without a reported branch, cleanup leaves the current branch alone.
    PRIMARY_BRANCH='' "$guard" cleanup || fail 'empty branch output should be inert'
    git show-ref --verify --quiet refs/heads/claude/default || fail 'empty output removed the current branch'
    [ "$(git branch --show-current)" = claude/default ] || fail 'empty output changed checkout'
)
echo 'Claude workflow result: all cases passed'
