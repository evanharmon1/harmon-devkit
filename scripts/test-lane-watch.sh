#!/usr/bin/env bash
# Fixture-driven regression tests for the orchestrator lane watcher.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
watcher="$repo_root/ai/skills/universal/orchestrator/assets/lane-watch.sh"
test_tmp="$(mktemp -d -t lane-watch-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

bin_dir="$test_tmp/bin"
fixture_dir="$test_tmp/fixtures"
workspace_root="$test_tmp/workspaces"
state_file="$test_tmp/watcher.state"
registry="$test_tmp/agent-registry.json"
mkdir -p "$bin_dir" "$fixture_dir" \
    "$workspace_root/harmon-devkit/.worktrees/alpha" \
    "$workspace_root/harmon-devkit/.worktrees/beta" \
    "$workspace_root/harmon-devkit/.worktrees/gamma"

fail() {
    echo "FAIL: $*" >&2
    exit 1
    return 0
}

assert_line() {
    file=$1
    expected=$2
    grep -Fxq "$expected" "$file" || fail "missing line: $expected"
}

assert_count() {
    file=$1
    expected=$2
    pattern=$3
    actual="$(grep -Ec "$pattern" "$file" || true)"
    [ "$actual" -eq "$expected" ] || fail "expected $expected matches for $pattern, got $actual"
}

cat >"$registry" <<'JSON'
{"finders":[
  {"slug":"local","trusted_actor_id":null},
  {"slug":"codex-cloud","trusted_actor_id":"999"}
]}
JSON

cat >"$workspace_root/harmon-devkit/.worktrees/alpha/.lane-report.md" <<'EOF'
Implementation complete.
LANE-ALPHA-READY-n1
EOF

cat >"$bin_dir/herdr" <<'STUB'
#!/usr/bin/env bash
set -u
if [ -f "$WATCH_FIXTURES/hang-list" ] && [ "${1:-} ${2:-}" = "agent list" ]; then
    trap '' TERM
    sleep 5
fi
if [ "${1:-} ${2:-}" = "agent list" ]; then
    if [ -f "$WATCH_FIXTURES/malformed-list" ]; then
        printf '%s\n' '{"error":"temporarily unavailable"}'
        exit 0
    fi
    printf '%s\n' '{"result":{"agents":[{"name":"alpha","agent_status":"working"},{"name":"beta","agent_status":"idle"},{"name":"gamma","agent_status":"blocked"}]}}'
    exit 0
fi
if [ "${1:-} ${2:-}" = "agent read" ]; then
    lane=${3:-}
    source=${5:-}
    if [ "$source" = recent-unwrapped ]; then
        case "$lane" in
        beta) printf '%s\n' 'LANE-BETA-BLOCKED-n2' ;;
        gamma) printf '%s\n' 'Prompt says `LANE-GAMMA-BLOCKED-n3`; do not print it yet.' ;;
        esac
    elif [ "$source" = visible ] && [ "$lane" = beta ]; then
        if [ -f "$WATCH_FIXTURES/fail-visible-beta" ]; then
            exit 92
        fi
        printf '%s\n' 'Usage limit reached'
    fi
    exit 0
fi
exit 90
STUB

cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -u
if [ "${1:-} ${2:-}" = "repo view" ]; then
    printf '%s\n' "${WATCH_REPO:-evanharmon1/harmon-devkit}"
    exit 0
fi
if [ "${1:-} ${2:-}" = "pr list" ]; then
    branch=
    previous=
    for arg in "$@"; do
        if [ "$previous" = --head ]; then branch=$arg; fi
        previous=$arg
    done
    if [ "$branch" != branch-alpha ]; then
        printf '%s\n' '[]'
        exit 0
    fi
    count_file="$WATCH_FIXTURES/pr-count"
    count=0
    [ ! -f "$count_file" ] || count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    printf '%s\n' "$count" >"$WATCH_FIXTURES/phase"
    case "$count" in
    1) printf '%s\n' '[{"number":77,"isDraft":true,"state":"OPEN","headRepositoryOwner":{"login":"'"${WATCH_HEAD_OWNER:-evanharmon1}"'"}}]' ;;
    2 | 3) printf '%s\n' '[{"number":77,"isDraft":false,"state":"OPEN","headRepositoryOwner":{"login":"'"${WATCH_HEAD_OWNER:-evanharmon1}"'"}}]' ;;
    *) printf '%s\n' '[{"number":77,"isDraft":false,"state":"MERGED","headRepositoryOwner":{"login":"'"${WATCH_HEAD_OWNER:-evanharmon1}"'"}}]' ;;
    esac
    exit 0
fi

if [ "${1:-}" = api ]; then
    endpoint=${*: -1}
    phase=0
    [ ! -f "$WATCH_FIXTURES/phase" ] || phase="$(<"$WATCH_FIXTURES/phase")"
    if [ -f "$WATCH_FIXTURES/fail-api" ] && [ "$phase" -eq 2 ]; then
        exit 92
    fi
    if [ "$phase" -lt 3 ]; then
        printf '%s\n' '[]'
        exit 0
    fi
    case "$endpoint" in
    */events?per_page=100)
        printf '%s\n' '[{"id":401,"event":"ready_for_review","created_at":"2098-01-01T00:00:00Z","actor":{"id":111,"login":"maintainer","type":"User"}}]'
        ;;
    */reviews?per_page=100)
        printf '%s\n' '[{"id":501,"submitted_at":"2098-01-01T00:00:01Z","user":{"id":999,"login":"trusted-codex","type":"Bot"}}]'
        ;;
    */issues/*/comments?per_page=100)
        printf '%s\n' '[{"id":601,"created_at":"2098-01-01T00:00:00Z","user":{"id":111,"login":"maintainer","type":"User"}}]'
        ;;
    */pulls/*/comments?per_page=100)
        printf '%s\n' '[{"id":701,"created_at":"2098-01-01T00:00:03Z","user":{"id":222,"login":"untrusted-bot","type":"Bot"}}]'
        ;;
    *) exit 91 ;;
    esac
    exit 0
fi
exit 90
STUB
chmod +x "$bin_dir/herdr" "$bin_dir/gh"

export PATH="$bin_dir:$PATH"
export WATCH_FIXTURES="$fixture_dir"

common_args=(
    --state-file "$state_file"
    --registry "$registry"
    --workspace-root "$workspace_root"
    --interval-seconds 0
    --post-promotion-seconds 900
    --timeout-seconds 1
    2099-01-01T00:00:00Z
    alpha:branch-alpha:n1:evanharmon1/harmon-devkit
    beta:branch-beta:n2
    gamma:branch-gamma:n3
)

primary_out="$test_tmp/primary.out"
bash "$watcher" --iterations 4 "${common_args[@]}" >"$primary_out"

# Three independently quoted specs pin the zsh word-splitting regression.
assert_line "$primary_out" 'AGENT alpha: init -> working'
assert_line "$primary_out" 'AGENT beta: init -> idle'
assert_line "$primary_out" 'AGENT gamma: init -> blocked'

# Report-file results win; pane-only results are tagged and prompt prose cannot match.
assert_line "$primary_out" 'SENTINEL alpha: LANE-ALPHA-READY-n1'
assert_line "$primary_out" 'SENTINEL beta: LANE-BETA-BLOCKED-n2 (pane only)'
assert_count "$primary_out" 0 '^SENTINEL gamma:'
assert_count "$primary_out" 1 '^SENTINEL alpha:'
assert_count "$primary_out" 1 '^SENTINEL beta:'

assert_line "$primary_out" 'PR alpha: #77 draft=true OPEN'
assert_line "$primary_out" 'PR alpha: #77 draft=false OPEN'
assert_line "$primary_out" 'PR alpha: #77 draft=false MERGED'
assert_line "$primary_out" 'POST-PROMOTION-ACTIVITY alpha: trusted-codex review 501'
assert_line "$primary_out" 'POST-PROMOTION-ACTIVITY alpha: maintainer comment 601'
assert_count "$primary_out" 0 'untrusted-bot'
assert_count "$primary_out" 1 '^USAGE-PAUSED beta$'

# A fresh process adopts state and does not re-emit either sentinel.
restart_out="$test_tmp/restart.out"
touch "$fixture_dir/fail-visible-beta"
bash "$watcher" --iterations 1 "${common_args[@]}" >"$restart_out"
rm "$fixture_dir/fail-visible-beta"
assert_count "$restart_out" 0 '^SENTINEL '
assert_count "$restart_out" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$restart_out" 0 '^USAGE-PAUSED beta$'
usage_recovery_out="$test_tmp/usage-recovery.out"
bash "$watcher" --iterations 1 "${common_args[@]}" >"$usage_recovery_out"
assert_count "$usage_recovery_out" 0 '^USAGE-PAUSED beta$'

# A hanging external call times out without fabricating an absent transition.
touch "$fixture_dir/hang-list"
hang_out="$test_tmp/hang.out"
timeout 8 bash "$watcher" --iterations 1 \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$hang_out" || fail 'watcher did not degrade a hanging herdr call'
assert_count "$hang_out" 0 '^AGENT delta:'
rm "$fixture_dir/hang-list"

# A syntactically valid Herdr error envelope is indeterminate, not absence.
touch "$fixture_dir/malformed-list"
malformed_out="$test_tmp/malformed-list.out"
bash "$watcher" --iterations 1 --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$malformed_out"
assert_count "$malformed_out" 0 '^AGENT delta:'
rm "$fixture_dir/malformed-list"

# An expired activity window survives a failed final snapshot and closes only
# after a successful retry, so activity during an API outage is not lost.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
touch "$fixture_dir/fail-api"
retry_out="$test_tmp/activity-retry.out"
bash "$watcher" --iterations 3 --state-file "$test_tmp/retry.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$retry_out"
assert_line "$retry_out" 'POST-PROMOTION-ACTIVITY alpha: trusted-codex review 501'
assert_line "$retry_out" 'POST-PROMOTION-ACTIVITY alpha: maintainer comment 601'
rm "$fixture_dir/fail-api"

# A fork-owned head is accepted when it is the unique branch match, and a
# first observation after promotion still opens the timestamp-bound window.
printf '%s\n' 1 >"$fixture_dir/pr-count"
rm -f "$fixture_dir/phase"
fork_out="$test_tmp/fork-ready.out"
WATCH_HEAD_OWNER=contributor bash "$watcher" --iterations 2 \
    --state-file "$test_tmp/fork.state" --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$fork_out"
assert_line "$fork_out" 'PR alpha: #77 draft=false OPEN'
assert_line "$fork_out" 'POST-PROMOTION-ACTIVITY alpha: trusted-codex review 501'

# The same asset resolves the repository root and registry in the flattened
# consumer layout, and a three-field spec derives that consumer repository.
flattened_root="$test_tmp/consumer"
flattened_watcher="$flattened_root/.agents/skills/orchestrator/assets/lane-watch.sh"
mkdir -p "$(dirname "$flattened_watcher")" "$flattened_root/.worktrees/alpha"
cp "$watcher" "$flattened_watcher"
cp "$registry" "$flattened_root/agent-registry.json"
cp "$workspace_root/harmon-devkit/.worktrees/alpha/.lane-report.md" \
    "$flattened_root/.worktrees/alpha/.lane-report.md"
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
flattened_out="$test_tmp/flattened.out"
WATCH_REPO=evanharmon1/consumer bash "$flattened_watcher" --iterations 1 \
    --state-file "$test_tmp/flattened.state" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1 >"$flattened_out"
assert_line "$flattened_out" 'SENTINEL alpha: LANE-ALPHA-READY-n1'

# A watcher launched from a linked worktree still finds reports in sibling
# worktrees under the primary checkout.
linked_parent="$test_tmp/linked"
linked_main="$linked_parent/repo"
mkdir -p "$linked_main"
git -C "$linked_main" init -q -b main
git -C "$linked_main" config user.name test
git -C "$linked_main" config user.email test@example.invalid
mkdir -p "$linked_main/ai/skills/universal/orchestrator/assets"
cp "$watcher" "$linked_main/ai/skills/universal/orchestrator/assets/lane-watch.sh"
cp "$registry" "$linked_main/agent-registry.json"
git -C "$linked_main" add .
git -C "$linked_main" commit -qm initial
git -C "$linked_main" worktree add -q -b monitor "$linked_main/.worktrees/monitor"
mkdir -p "$linked_main/.worktrees/alpha"
cp "$workspace_root/harmon-devkit/.worktrees/alpha/.lane-report.md" \
    "$linked_main/.worktrees/alpha/.lane-report.md"
linked_watcher="$linked_main/.worktrees/monitor/ai/skills/universal/orchestrator/assets/lane-watch.sh"
linked_out="$test_tmp/linked.out"
WATCH_REPO=evanharmon1/repo bash "$linked_watcher" --iterations 1 \
    --state-file "$test_tmp/linked.state" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1 >"$linked_out"
assert_line "$linked_out" 'SENTINEL alpha: LANE-ALPHA-READY-n1'

# Nonces use a literal-safe identity alphabet rather than regex syntax.
invalid_nonce_err="$test_tmp/invalid-nonce.err"
bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z 'alpha:branch-alpha:n[1' \
    >/dev/null 2>"$invalid_nonce_err"
assert_line "$invalid_nonce_err" 'lane-watch: invalid sentinel nonce in spec: alpha:branch-alpha:n[1'

# Requested durable state fails loudly when its destination cannot be created.
state_parent="$test_tmp/state-parent"
printf '%s\n' occupied >"$state_parent"
state_failure_err="$test_tmp/state-failure.err"
if bash "$watcher" --iterations 1 --state-file "$state_parent/watcher.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >/dev/null 2>"$state_failure_err"; then
    fail 'watcher accepted an unpersistable requested state file'
fi
assert_line "$state_failure_err" "lane-watch: could not persist state to $state_parent/watcher.state"

# The watcher state implementation stays compatible with macOS Bash 3.2.
assert_count "$watcher" 0 'declare -A'

# The warning uses the documented WALLCLOCK shape.
wallclock_out="$test_tmp/wallclock.out"
near_deadline="$(date -u -d '10 minutes' +%Y-%m-%dT%H:%M:%SZ)"
bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    "$near_deadline" epsilon:branch-epsilon:n5:evanharmon1/harmon-devkit \
    >"$wallclock_out"
assert_line "$wallclock_out" "WALLCLOCK run: 30 min to $near_deadline cap"

# Every emitted line belongs to one of the stable event grammars.
if grep -Ev '^(AGENT [^:]+: [^ ]+ -> [^ ]+|SENTINEL [^:]+: LANE-[A-Z0-9-]+-(READY|BLOCKED)-[^ ]+( \(pane only\))?|PR [^:]+: #[0-9]+ draft=(true|false) (OPEN|CLOSED|MERGED)|POST-PROMOTION-ACTIVITY [^:]+: [^ ]+ (review|comment|inline) [0-9]+|USAGE-PAUSED [^ ]+|WALLCLOCK (run|[^:]+): .+)$' \
    "$primary_out" "$restart_out" "$usage_recovery_out" "$hang_out" "$retry_out" \
    "$malformed_out" "$fork_out" "$flattened_out" "$linked_out" "$wallclock_out"; then
    fail 'watcher emitted a line outside the documented event grammar'
fi

echo 'lane-watch tests passed'
