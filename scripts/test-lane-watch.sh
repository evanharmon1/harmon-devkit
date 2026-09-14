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
        gamma) printf '%s\n' 'When complete, print:' 'LANE-GAMMA-BLOCKED-n3' 'Continue with the task.' ;;
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
if [ "${1:-} ${2:-}" = "pr list" ]; then
    if [ -f "$WATCH_FIXTURES/hang-pr-list" ]; then
        sleep 3
    fi
    if [ -f "$WATCH_FIXTURES/fail-pr-list" ]; then
        exit 92
    fi
    if [ -f "$WATCH_FIXTURES/malformed-pr-list" ]; then
        printf '%s\n' '[{"error":"partial response"}]'
        exit 0
    fi
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
    1) printf '%s\n' '[{"number":77,"isDraft":true,"state":"OPEN","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' ;;
    2) if [ -f "$WATCH_FIXTURES/skip-ready" ]; then
        printf '%s\n' '[{"number":77,"isDraft":false,"state":"MERGED","headRefOid":"aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]'
    else
        printf '%s\n' '[{"number":77,"isDraft":true,"state":"OPEN","headRefOid":"aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]'
    fi ;;
    3 | 4) printf '%s\n' '[{"number":77,"isDraft":false,"state":"OPEN","headRefOid":"aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' ;;
    *) printf '%s\n' '[{"number":77,"isDraft":false,"state":"MERGED","headRefOid":"aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' ;;
    esac
    exit 0
fi

if [ "${1:-}" = api ]; then
    endpoint=${*: -1}
    if [ -f "$WATCH_FIXTURES/tail-activity-at" ]; then
        case "$endpoint" in
        */reviews?per_page=100)
            tail_at="$(<"$WATCH_FIXTURES/tail-activity-at")"
            printf '%s\n' "[{\"id\":901,\"submitted_at\":\"$tail_at\",\"user\":{\"id\":999,\"login\":\"trusted-codex\",\"type\":\"Bot\"}}]"
            ;;
        *) printf '%s\n' '[]' ;;
        esac
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/cold-resolve-since" ]; then
        case "$endpoint" in
        */events?per_page=100)
            cold_since="$(<"$WATCH_FIXTURES/cold-resolve-since")"
            printf '%s\n' "[{\"id\":401,\"event\":\"ready_for_review\",\"created_at\":\"$cold_since\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}]"
            ;;
        */reviews?per_page=100)
            cold_activity="$(<"$WATCH_FIXTURES/cold-resolve-activity-at")"
            printf '%s\n' "[{\"id\":901,\"submitted_at\":\"$cold_activity\",\"user\":{\"id\":999,\"login\":\"trusted-codex\",\"type\":\"Bot\"}}]"
            ;;
        *) printf '%s\n' '[]' ;;
        esac
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/cold-never-resolves" ]; then
        case "$endpoint" in
        */events?per_page=100) printf '%s\n' '[]' ;;
        *)
            printf '%s\n' "$endpoint" >>"$WATCH_FIXTURES/cold-never-resolves-calls"
            printf '%s\n' '[]'
            ;;
        esac
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/fast-path-expected" ]; then
        printf '%s\n' "$endpoint" >>"$WATCH_FIXTURES/fast-path-calls"
        printf '%s\n' '[]'
        exit 0
    fi
    phase=0
    [ ! -f "$WATCH_FIXTURES/phase" ] || phase="$(<"$WATCH_FIXTURES/phase")"
    activity_phase=3
    [ ! -f "$WATCH_FIXTURES/skip-ready" ] || activity_phase=2
    if [ -f "$WATCH_FIXTURES/fail-api" ] && [ "$phase" -eq "$activity_phase" ]; then
        exit 92
    fi
    if [ "$phase" -lt "$activity_phase" ]; then
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
        printf '%s\n' '[{"id":601,"created_at":"2097-12-31T23:59:00Z","updated_at":"2098-01-01T00:00:02Z","user":{"id":111,"login":"maintainer","type":"User"}}]'
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
    beta:branch-beta:n2:evanharmon1/harmon-devkit
    gamma:branch-gamma:n3:evanharmon1/harmon-devkit
)

primary_out="$test_tmp/primary.out"
bash "$watcher" --iterations 5 "${common_args[@]}" >"$primary_out"

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

assert_line "$primary_out" 'PR alpha: #77 draft=true OPEN head=aaaaaaaa'
assert_count "$primary_out" 2 '^PR alpha: #77 draft=true OPEN head=aaaaaaaa$'
assert_line "$primary_out" 'PR alpha: #77 draft=false OPEN head=aaaaaaaa'
assert_line "$primary_out" 'PR alpha: #77 draft=false MERGED head=aaaaaaaa'
assert_line "$primary_out" 'POST-PROMOTION-ACTIVITY alpha: trusted-codex review 501'
assert_line "$primary_out" 'POST-PROMOTION-ACTIVITY alpha: maintainer comment 601'
assert_count "$primary_out" 1 '^POST-PROMOTION-ACTIVITY alpha: maintainer comment 601$'
assert_count "$primary_out" 0 'untrusted-bot'
assert_count "$primary_out" 1 '^USAGE-PAUSED beta$'

# A promotion and merge entirely between polls still opens the authoritative
# ready-for-review activity window before the merged transition is emitted.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
touch "$fixture_dir/skip-ready"
skipped_ready_out="$test_tmp/skipped-ready.out"
bash "$watcher" --iterations 2 \
    --state-file "$test_tmp/skipped-ready.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$skipped_ready_out"
rm "$fixture_dir/skip-ready"
assert_line "$skipped_ready_out" 'PR alpha: #77 draft=true OPEN head=aaaaaaaa'
assert_line "$skipped_ready_out" 'PR alpha: #77 draft=false MERGED head=aaaaaaaa'
assert_line "$skipped_ready_out" 'POST-PROMOTION-ACTIVITY alpha: trusted-codex review 501'

# A pre-head snapshot still opens the post-promotion activity window after an upgrade.
printf '%s\n' 2 >"$fixture_dir/pr-count"
printf 'PR\talpha\t#77 draft=true OPEN\t\nWALLCLOCK\trun\t0\t\n' \
    >"$test_tmp/legacy-draft.state"
legacy_draft_out="$test_tmp/legacy-draft.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/legacy-draft.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$legacy_draft_out"
assert_line "$legacy_draft_out" 'PR alpha: #77 draft=false OPEN head=aaaaaaaa'
assert_line "$legacy_draft_out" 'POST-PROMOTION-ACTIVITY alpha: maintainer comment 601'

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
test_timeout="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$test_timeout" ] || fail 'GNU timeout (timeout or gtimeout) is required'
"$test_timeout" --kill-after=2 8 bash "$watcher" --iterations 1 \
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

# A syntactically valid but incomplete PR object is indeterminate, so
# persistent supervision re-arms instead of persisting a #null transition.
touch "$fixture_dir/malformed-pr-list"
github_failure_err="$test_tmp/github-failure.err"
if bash "$watcher" --iterations 1 --registry "$registry" \
    --state-file "$test_tmp/github-failure.state" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >/dev/null 2>"$github_failure_err"; then
    fail 'watcher accepted a malformed GitHub PR observation'
fi
assert_line "$github_failure_err" 'lane-watch: GitHub PR observation failed for lane delta'
assert_count "$test_tmp/github-failure.state" 1 '^AGENT[[:space:]]+delta[[:space:]]+absent'
rm "$fixture_dir/malformed-pr-list"

rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
touch "$fixture_dir/fail-api"
activity_failure_err="$test_tmp/activity-failure.err"
if bash "$watcher" --iterations 1 --state-file "$test_tmp/activity-failure.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >/dev/null 2>"$activity_failure_err"; then
    fail 'watcher accepted an indeterminate GitHub activity observation'
fi
assert_line "$activity_failure_err" 'lane-watch: GitHub activity observation failed for lane alpha'
assert_count "$test_tmp/activity-failure.state" 1 '^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+'
rm "$fixture_dir/fail-api"

# A cold-start window whose provisional deadline has passed now always
# retries promotion_epoch() rather than abandoning the window unexamined --
# so a genuine hard API failure during that retry (not a clean "no such
# event" response; see the cold-start-never-resolves case below) surfaces as
# an observation failure instead of being silently swallowed the way the old
# short-circuit-before-any-API-call code used to swallow it. pr-count is
# seeded to 2 so this iteration's single `gh pr list` call lands on phase 3,
# matching activity_phase, so `fail-api` genuinely fires on the retried
# `gh api` events call. (Verified live: seeding pr-count to 1 instead lands
# on phase 2, which never matches activity_phase, so the exact same
# fail-api fixture is never consulted and this scenario resolves to a clean
# POST-PROMOTION-INDETERMINATE instead -- that is regression (c) below, not
# a hard failure -- which is why pr-count must land on phase 3 here.)
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaa\t\nWINDOW\talpha\t77\t1\t\nWALLCLOCK\trun\t0\t\n' \
    >"$test_tmp/expired.state"
touch "$fixture_dir/fail-api"
expired_out="$test_tmp/activity-expired.out"
expired_err="$test_tmp/activity-expired.err"
if bash "$watcher" --iterations 1 --state-file "$test_tmp/expired.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$expired_out" 2>"$expired_err"; then
    fail 'watcher accepted a hard API failure while resolving a cold-start expired window'
fi
assert_line "$expired_err" 'lane-watch: GitHub activity observation failed for lane alpha'
assert_count "$expired_out" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$expired_out" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$test_tmp/expired.state" 1 '^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+'
rm "$fixture_dir/fail-api"

# A window observed long after `until` -- regardless of how stale, not just
# within one poll interval, now that no interval-based tolerance exists --
# still takes exactly one closing snapshot before the state is torn down, so
# activity in the tail of the window a poll never lands inside is still
# caught.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
tail_now="$(date -u +%s)"
tail_until=$((tail_now - 1200))
tail_since=$((tail_until - 300))
tail_activity_at="$tail_until"
tail_activity_iso="$(date -u -d "@$tail_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$tail_activity_iso" ] || tail_activity_iso="$(date -u -r "$tail_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$tail_activity_iso" >"$fixture_dir/tail-activity-at"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s\nWALLCLOCK\trun\t0\t\n' \
    "$tail_until" "$tail_since" >"$test_tmp/tail-window.state"
tail_out="$test_tmp/tail-window.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/tail-window.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$tail_out"
rm "$fixture_dir/tail-activity-at"
assert_count "$tail_out" 1 '^POST-PROMOTION-ACTIVITY '
assert_count "$test_tmp/tail-window.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$test_tmp/tail-window.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# CLOSING durably means "done," never "in progress": a window whose CLOSING
# flag and the corresponding row's ACTIVITY key are BOTH already durably
# recorded -- exactly the state a crash can leave once poll_activity()'s
# reorder (set CLOSING, persist, THEN delete WINDOW/CLOSING) has completed
# its persist but not yet its deletes -- must skip re-fetching entirely via
# the fast path, not merely avoid re-emitting a row it already knows about.
# Tracking every `gh api` call is the point: ACTIVITY-key dedup alone would
# also suppress a duplicate POST-PROMOTION-ACTIVITY line even if the fast
# path were broken and a re-fetch happened anyway, so counting emitted lines
# cannot distinguish "CLOSING correctly means done" from "CLOSING might be a
# premature lie." Only proving the endpoint was never called can.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase" "$fixture_dir/fast-path-calls"
printf '%s\n' 2 >"$fixture_dir/pr-count"
closing_now="$(date -u +%s)"
closing_until=$((closing_now - 1200))
closing_since=$((closing_until - 900))
touch "$fixture_dir/fast-path-expected"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s\nCLOSING\talpha\t1\t\nACTIVITY\talpha\treview\t501:%s\nWALLCLOCK\trun\t0\t\n' \
    "$closing_until" "$closing_since" "$closing_until" >"$test_tmp/closing-durable.state"
closing_out="$test_tmp/closing-durable.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/closing-durable.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$closing_out"
rm "$fixture_dir/fast-path-expected"
assert_count "$closing_out" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$closing_out" 0 '^POST-PROMOTION-INDETERMINATE '
[ ! -f "$fixture_dir/fast-path-calls" ] ||
    fail 'watcher re-fetched activity for a window already closed durably'
assert_count "$test_tmp/closing-durable.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$test_tmp/closing-durable.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# A cold-start window whose epoch resolves to a real, already-past deadline
# (the provisional deadline had already passed too) still takes exactly one
# snapshot over the REAL [since,until] before the window is torn down --
# resolving late does not abandon the window.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
resolve_now="$(date -u +%s)"
resolve_provisional_until=$((resolve_now - 1200))
resolve_real_since=$((resolve_now - 2200))
resolve_real_until=$((resolve_real_since + 900))
resolve_since_iso="$(date -u -d "@$resolve_real_since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$resolve_since_iso" ] || resolve_since_iso="$(date -u -r "$resolve_real_since" +%Y-%m-%dT%H:%M:%SZ)"
resolve_activity_iso="$(date -u -d "@$resolve_real_until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$resolve_activity_iso" ] || resolve_activity_iso="$(date -u -r "$resolve_real_until" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$resolve_since_iso" >"$fixture_dir/cold-resolve-since"
printf '%s\n' "$resolve_activity_iso" >"$fixture_dir/cold-resolve-activity-at"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t\nWALLCLOCK\trun\t0\t\n' \
    "$resolve_provisional_until" >"$test_tmp/cold-resolve.state"
cold_resolve_out="$test_tmp/cold-resolve.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/cold-resolve.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$cold_resolve_out"
rm "$fixture_dir/cold-resolve-since" "$fixture_dir/cold-resolve-activity-at"
assert_line "$cold_resolve_out" 'POST-PROMOTION-ACTIVITY alpha: trusted-codex review 901'
assert_count "$cold_resolve_out" 1 '^POST-PROMOTION-ACTIVITY '
assert_count "$cold_resolve_out" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$test_tmp/cold-resolve.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$test_tmp/cold-resolve.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# A cold-start window whose epoch never resolves (a clean, valid response
# with no ready_for_review event -- ordinary GitHub eventual consistency,
# not a hard API failure) emits exactly one POST-PROMOTION-INDETERMINATE
# line, zero POST-PROMOTION-ACTIVITY lines, and never calls any activity
# endpoint (reviews, comments, or inline) at all.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase" "$fixture_dir/cold-never-resolves-calls"
printf '%s\n' 2 >"$fixture_dir/pr-count"
never_now="$(date -u +%s)"
never_until=$((never_now - 1200))
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t\nWALLCLOCK\trun\t0\t\n' \
    "$never_until" >"$test_tmp/cold-never.state"
touch "$fixture_dir/cold-never-resolves"
cold_never_out="$test_tmp/cold-never.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/cold-never.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$cold_never_out"
rm "$fixture_dir/cold-never-resolves"
assert_line "$cold_never_out" 'POST-PROMOTION-INDETERMINATE alpha: #77'
assert_count "$cold_never_out" 1 '^POST-PROMOTION-INDETERMINATE '
assert_count "$cold_never_out" 0 '^POST-PROMOTION-ACTIVITY '
[ ! -f "$fixture_dir/cold-never-resolves-calls" ] ||
    fail 'watcher called an activity endpoint for an unresolved cold-start window'
assert_count "$test_tmp/cold-never.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'

# The same asset resolves the repository root and registry in the flattened
# consumer layout when the lane spec supplies its required repository.
flattened_root="$test_tmp/consumer"
flattened_watcher="$flattened_root/.agents/skills/orchestrator/assets/lane-watch.sh"
mkdir -p "$(dirname "$flattened_watcher")" "$flattened_root/.worktrees/alpha"
cp "$watcher" "$flattened_watcher"
cp "$registry" "$flattened_root/agent-registry.json"
cp "$workspace_root/harmon-devkit/.worktrees/alpha/.lane-report.md" \
    "$flattened_root/.worktrees/alpha/.lane-report.md"
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
flattened_out="$test_tmp/flattened.out"
bash "$flattened_watcher" --iterations 1 \
    --state-file "$test_tmp/flattened.state" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/consumer >"$flattened_out"
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
bash "$linked_watcher" --iterations 1 \
    --state-file "$test_tmp/linked.state" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/repo >"$linked_out"
assert_line "$linked_out" 'SENTINEL alpha: LANE-ALPHA-READY-n1'

# Nonces use a literal-safe identity alphabet rather than regex syntax.
invalid_nonce_err="$test_tmp/invalid-nonce.err"
if bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z 'alpha:branch-alpha:n[1:evanharmon1/harmon-devkit' \
    >/dev/null 2>"$invalid_nonce_err"; then
    fail 'watcher accepted an invalid sentinel nonce'
fi
assert_line "$invalid_nonce_err" 'lane-watch: invalid sentinel nonce in spec: alpha:branch-alpha:n[1:evanharmon1/harmon-devkit'

# Repository identity is mandatory; there is no ambient-repository fallback.
missing_repo_err="$test_tmp/missing-repo.err"
if bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1 \
    >/dev/null 2>"$missing_repo_err"; then
    fail 'watcher accepted a lane spec without owner/repo'
fi
assert_line "$missing_repo_err" 'lane-watch: invalid lane spec: alpha:branch-alpha:n1'

# The immutable kickoff registry is validated before any poll begins.
invalid_registry="$test_tmp/invalid-registry.json"
printf '%s\n' '{"finders":"not-an-array"}' >"$invalid_registry"
invalid_registry_err="$test_tmp/invalid-registry.err"
if bash "$watcher" --iterations 1 --registry "$invalid_registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >/dev/null 2>"$invalid_registry_err"; then
    fail 'watcher accepted a malformed kickoff registry'
fi
assert_line "$invalid_registry_err" "lane-watch: invalid agent registry: $invalid_registry"

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

# The watcher's private line-oriented state must never accept or overwrite the
# canonical JSON run monitor. The documented invocation uses a distinct path.
canonical_monitor="$test_tmp/monitor.json"
printf '%s\n' '{"generation":7,"reservations":["preserve-me"]}' >"$canonical_monitor"
cp "$canonical_monitor" "$test_tmp/monitor.before.json"
canonical_monitor_err="$test_tmp/canonical-monitor.err"
if bash "$watcher" --iterations 1 --state-file "$canonical_monitor" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >/dev/null 2>"$canonical_monitor_err"; then
    fail 'watcher accepted the canonical run monitor as private state'
fi
assert_line "$canonical_monitor_err" \
    "lane-watch: refusing canonical run monitor as watcher state: $canonical_monitor"
cmp -s "$canonical_monitor" "$test_tmp/monitor.before.json" ||
    fail 'watcher modified the canonical run monitor'
assert_count "$repo_root/ai/skills/universal/orchestrator/SKILL.md" 1 \
    'state-file <run-dir>/lane-watch.state'
assert_count "$repo_root/ai/skills/universal/orchestrator/SKILL.md" 0 \
    'state-file <run-state>'

# The watcher state implementation stays compatible with macOS Bash 3.2.
assert_count "$watcher" 0 'declare -A'
assert_count "$watcher" 0 '\$\{#state_'

# The warning uses the documented WALLCLOCK shape.
wallclock_out="$test_tmp/wallclock.out"
near_deadline="$(date -u -d '10 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
if [ -z "$near_deadline" ]; then
    near_deadline="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)"
fi
bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    "$near_deadline" epsilon:branch-epsilon:n5:evanharmon1/harmon-devkit \
    >"$wallclock_out"
assert_line "$wallclock_out" "WALLCLOCK run: 10 min to $near_deadline cap"

# A bounded read that crosses the deadline terminates as wall-clock exhaustion.
crossed_deadline="$(date -u -d '1 second' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
if [ -z "$crossed_deadline" ]; then
    crossed_deadline="$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)"
fi
touch "$fixture_dir/hang-pr-list"
deadline_out="$test_tmp/deadline-crossed.out"
bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 2 \
    "$crossed_deadline" epsilon:branch-epsilon:n5:evanharmon1/harmon-devkit \
    >"$deadline_out"
rm "$fixture_dir/hang-pr-list"
assert_line "$deadline_out" "WALLCLOCK run: deadline $crossed_deadline reached"

# Every emitted line belongs to one of the stable event grammars.
if grep -Ev '^(AGENT [^:]+: [^ ]+ -> [^ ]+|SENTINEL [^:]+: LANE-[A-Z0-9-]+-(READY|BLOCKED)-[^ ]+( \(pane only\))?|PR [^:]+: #[0-9]+ draft=(true|false) (OPEN|CLOSED|MERGED) head=[0-9a-f]{8}|POST-PROMOTION-ACTIVITY [^:]+: [^ ]+ (review|comment|inline) [0-9]+|POST-PROMOTION-INDETERMINATE [^:]+: #[0-9]+|USAGE-PAUSED [^ ]+|WALLCLOCK (run|[^:]+): .+)$' \
    "$primary_out" "$skipped_ready_out" "$legacy_draft_out" "$restart_out" "$usage_recovery_out" "$hang_out" "$expired_out" \
    "$tail_out" "$closing_out" "$cold_resolve_out" "$cold_never_out" "$malformed_out" "$flattened_out" "$linked_out" "$wallclock_out" "$deadline_out"; then
    fail 'watcher emitted a line outside the documented event grammar'
fi

echo 'lane-watch tests passed'
