#!/usr/bin/env bash
# Fixture-driven regression tests for the orchestrator lane watcher.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
watcher="$repo_root/ai/skills/universal/orchestrate/assets/lane-watch.sh"
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
    if [ -f "$WATCH_FIXTURES/transient-pr-list" ]; then
        remaining="$(<"$WATCH_FIXTURES/transient-pr-list")"
        if [ "$remaining" -gt 0 ]; then
            printf '%s\n' "$((remaining - 1))" >"$WATCH_FIXTURES/transient-pr-list"
            exit 92
        fi
    fi
    branch=
    previous=
    for arg in "$@"; do
        if [ "$previous" = --head ]; then branch=$arg; fi
        previous=$arg
    done
    if [ -f "$WATCH_FIXTURES/fail-branch-alpha-pr-list" ] && [ "$branch" = branch-alpha ]; then
        count_file="$WATCH_FIXTURES/alpha-pr-list-attempts"
        count=0
        [ ! -f "$count_file" ] || count="$(<"$count_file")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$count_file"
        exit 92
    fi
    if [ "$branch" = branch-healthy ]; then
        count_file="$WATCH_FIXTURES/healthy-pr-list-calls"
        count=0
        [ ! -f "$count_file" ] || count="$(<"$count_file")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$count_file"
        printf '%s\n' '[]'
        exit 0
    fi
    if [ "$branch" = branch-theta ] && [ -f "$WATCH_FIXTURES/dormant-pr-json" ]; then
        cat "$WATCH_FIXTURES/dormant-pr-json"
        exit 0
    fi
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
    if [ -f "$WATCH_FIXTURES/samesecond-events" ]; then
        content="$(<"$WATCH_FIXTURES/samesecond-events")"
        same_iso="${content%%$'\t'*}"
        same_ids="${content#*$'\t'}"
        case "$endpoint" in
        */events?per_page=100)
            events_json='['
            first=1
            for same_id in $same_ids; do
                [ "$first" -eq 1 ] || events_json+=','
                events_json+="{\"id\":$same_id,\"event\":\"ready_for_review\",\"created_at\":\"$same_iso\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}"
                first=0
            done
            events_json+=']'
            printf '%s\n' "$events_json"
            ;;
        */reviews?per_page=100)
            if [ -f "$WATCH_FIXTURES/samesecond-activity-at" ]; then
                same_activity="$(<"$WATCH_FIXTURES/samesecond-activity-at")"
                printf '%s\n' "[{\"id\":902,\"submitted_at\":\"$same_activity\",\"user\":{\"id\":999,\"login\":\"trusted-codex\",\"type\":\"Bot\"}}]"
            else
                printf '%s\n' '[]'
            fi
            ;;
        *) printf '%s\n' '[]' ;;
        esac
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/created-edit-created-at" ]; then
        case "$endpoint" in
        */issues/*/comments?per_page=100)
            ce_created="$(<"$WATCH_FIXTURES/created-edit-created-at")"
            ce_updated="$(<"$WATCH_FIXTURES/created-edit-updated-at")"
            printf '%s\n' "[{\"id\":801,\"created_at\":\"$ce_created\",\"updated_at\":\"$ce_updated\",\"user\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}]"
            ;;
        *) printf '%s\n' '[]' ;;
        esac
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/dormant-events" ]; then
        dphase="$(<"$WATCH_FIXTURES/dormant-phase")"
        dsince1="$(<"$WATCH_FIXTURES/dormant-since1")"
        case "$endpoint" in
        */events?per_page=100)
            if [ "$dphase" = 1 ]; then
                printf '%s\n' "[{\"id\":701,\"event\":\"ready_for_review\",\"created_at\":\"$dsince1\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}]"
            else
                dsince2="$(<"$WATCH_FIXTURES/dormant-since2")"
                printf '%s\n' "[{\"id\":701,\"event\":\"ready_for_review\",\"created_at\":\"$dsince1\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}},{\"id\":702,\"event\":\"ready_for_review\",\"created_at\":\"$dsince2\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}]"
            fi
            ;;
        */reviews?per_page=100)
            if [ "$dphase" = 2 ]; then
                dactivity="$(<"$WATCH_FIXTURES/dormant-activity")"
                printf '%s\n' "[{\"id\":903,\"submitted_at\":\"$dactivity\",\"user\":{\"id\":999,\"login\":\"trusted-codex\",\"type\":\"Bot\"}}]"
            else
                printf '%s\n' '[]'
            fi
            ;;
        *) printf '%s\n' '[]' ;;
        esac
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/rebind-events" ]; then
        rphase="$(<"$WATCH_FIXTURES/rebind-phase")"
        rsince1="$(<"$WATCH_FIXTURES/rebind-since1")"
        case "$endpoint" in
        */events?per_page=100)
            if [ "$rphase" = 1 ]; then
                printf '%s\n' "[{\"id\":301,\"event\":\"ready_for_review\",\"created_at\":\"$rsince1\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}]"
            else
                rsince2="$(<"$WATCH_FIXTURES/rebind-since2")"
                printf '%s\n' "[{\"id\":301,\"event\":\"ready_for_review\",\"created_at\":\"$rsince1\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}},{\"id\":402,\"event\":\"ready_for_review\",\"created_at\":\"$rsince2\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}]"
            fi
            ;;
        */reviews?per_page=100)
            # Unlike dormant-events' phase-gated review row, this one is
            # returned unconditionally on every poll -- the point is that the
            # SAME (kind, id, created_at) row is fetched and re-evaluated
            # against two different armed windows in succession.
            ractivity="$(<"$WATCH_FIXTURES/rebind-activity-at")"
            printf '%s\n' "[{\"id\":950,\"submitted_at\":\"$ractivity\",\"user\":{\"id\":999,\"login\":\"trusted-codex\",\"type\":\"Bot\"}}]"
            ;;
        *) printf '%s\n' '[]' ;;
        esac
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/malformed-promo-events" ]; then
        case "$endpoint" in
        */events?per_page=100)
            mp_valid_at="$(<"$WATCH_FIXTURES/malformed-promo-valid-at")"
            mp_null_at="$(<"$WATCH_FIXTURES/malformed-promo-null-at")"
            if [ -f "$WATCH_FIXTURES/malformed-promo-all-bad" ]; then
                printf '%s\n' "[{\"id\":null,\"event\":\"ready_for_review\",\"created_at\":\"$mp_null_at\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}]"
            else
                # A later-timestamped event with a null id alongside an
                # earlier, validly-identified one: the null-id row has the
                # later created_at, so an unfiltered max-by-created_at
                # selection would pick it (and interpolate its null id into
                # the identity string) unless it is excluded first.
                printf '%s\n' "[{\"id\":555,\"event\":\"ready_for_review\",\"created_at\":\"$mp_valid_at\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}},{\"id\":null,\"event\":\"ready_for_review\",\"created_at\":\"$mp_null_at\",\"actor\":{\"id\":111,\"login\":\"maintainer\",\"type\":\"User\"}}]"
            fi
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
    if [ -f "$WATCH_FIXTURES/warm-events-empty" ]; then
        case "$endpoint" in
        */events?per_page=100)
            printf '%s\n' '[]'
            exit 0
            ;;
        esac
    fi
    if [ -f "$WATCH_FIXTURES/malformed-activity-entry" ]; then
        case "$endpoint" in
        */events?per_page=100)
            printf '%s\n' '[{"id":401,"event":"ready_for_review","created_at":"2098-01-01T00:00:00Z","actor":{"id":111,"login":"maintainer","type":"User"}}]'
            ;;
        */reviews?per_page=100)
            printf '%s\n' '[{"id":999,"user":{"id":999,"login":"trusted-codex","type":"Bot"}}]'
            ;;
        *) printf '%s\n' '[]' ;;
        esac
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

# A narrowly-scoped `mv` stub: root bypasses chmod's discretionary permission
# checks entirely, so a `chmod 555` fixture can't simulate an unpersistable
# state directory in a root-run container. Fail only the exact rename
# persist_state() performs into the persistfail fixture directory (gated
# behind $WATCH_FIXTURES/fail-mv); every other `mv` -- the test harness's own,
# and persist_state() calls for every other test in this file -- passes
# straight through to the real binary, resolved once here before bin_dir ever
# shadows PATH.
real_mv="$(command -v mv)"
cat >"$bin_dir/mv" <<STUB
#!/usr/bin/env bash
set -u
if [ -f "\${WATCH_FIXTURES:-}/fail-mv" ]; then
    for arg in "\$@"; do
        case "\$arg" in
        */persist-fail-state/*) exit 1 ;;
        esac
    done
fi
exec "$real_mv" "\$@"
STUB
chmod +x "$bin_dir/mv"

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

# The phase-driven default gh stub fixture (no dedicated WATCH_FIXTURES file)
# always resolves promotion_epoch() to this fixed event/epoch; every
# POST-PROMOTION-ACTIVITY assertion against default-fixture output carries
# this same "since=" identity.
default_since_epoch="$(date -u -d '2098-01-01T00:00:00Z' +%s 2>/dev/null || true)"
[ -n "$default_since_epoch" ] ||
    default_since_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2098-01-01T00:00:00Z' +%s)"

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
assert_line "$primary_out" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 501 since=${default_since_epoch}:401"
assert_line "$primary_out" "POST-PROMOTION-ACTIVITY alpha: maintainer comment 601 since=${default_since_epoch}:401"
assert_count "$primary_out" 1 "^POST-PROMOTION-ACTIVITY alpha: maintainer comment 601 since=${default_since_epoch}:401\$"
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
assert_line "$skipped_ready_out" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 501 since=${default_since_epoch}:401"

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
assert_line "$legacy_draft_out" "POST-PROMOTION-ACTIVITY alpha: maintainer comment 601 since=${default_since_epoch}:401"

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

# #1041: a PR observation that fails once and heals on the very next poll
# degrades exactly once (bounded, non-blocking backoff, not an immediate
# exit) and keeps running -- the episode clears on the recovering success.
# The failing poll schedules its retry 5s out (round 1's own backoff
# schedule) and never sleeps in place (challenge r1 finding 1), so a real
# --interval-seconds longer than that is what lets the second poll land
# after the scheduled retry time.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 1 >"$fixture_dir/transient-pr-list"
transient_out="$test_tmp/transient.out"
transient_state="$test_tmp/transient.state"
bash "$watcher" --iterations 2 --state-file "$transient_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 6 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$transient_out"
rm -f "$fixture_dir/transient-pr-list"
assert_line "$transient_out" 'OBSERVATION-DEGRADED alpha: GitHub PR observation failed for lane alpha'
assert_count "$transient_out" 1 '^OBSERVATION-DEGRADED '
assert_line "$transient_out" 'PR alpha: #77 draft=true OPEN head=aaaaaaaa'
assert_count "$transient_state" 0 '^DEGRADE[[:space:]]+alpha:PR[[:space:]]+'

# #1041 restart-dedup: a DEGRADE episode already announced (notified=1)
# before a restart must not announce again, even though the underlying
# failure is still ongoing -- only the eventual give-up is new. Seeds the
# real shape the watcher actually writes -- detail "<attempt>:<next_retry_at>"
# with next_retry_at already in the past -- so this restart's one and only
# poll makes a real attempt rather than being skipped (#1041 challenge r2
# finding claude-5: an earlier version of this test seeded an empty detail
# field, describing it as a legacy shape, but no shipped version of this
# file ever wrote DEGRADE without one -- unlike WINDOW's genuine legacy
# shape, that state could never actually occur).
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
restart_dedup_state="$test_tmp/restart-dedup.state"
restart_dedup_first_failure=$(($(date -u +%s) - 100))
printf 'DEGRADE\tdelta:PR\t%s\t1\t0:%s\nWALLCLOCK\trun\t0\t\n' \
    "$restart_dedup_first_failure" "$((restart_dedup_first_failure + 5))" \
    >"$restart_dedup_state"
touch "$fixture_dir/malformed-pr-list"
restart_dedup_out="$test_tmp/restart-dedup.out"
restart_dedup_err="$test_tmp/restart-dedup.err"
if bash "$watcher" --iterations 1 --state-file "$restart_dedup_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --degrade-window-seconds 2 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$restart_dedup_out" 2>"$restart_dedup_err"; then
    fail 'watcher accepted a malformed GitHub PR observation after a restart'
fi
rm "$fixture_dir/malformed-pr-list"
assert_line "$restart_dedup_err" 'lane-watch: GitHub PR observation failed for lane delta'
assert_count "$restart_dedup_out" 0 '^OBSERVATION-DEGRADED '

# #1041 restart-dedup, genuine mid-episode case (challenge r1 finding 5): a
# restart against an episode that has NOT yet exceeded its window must
# resume retrying -- not give up just because a restart happened -- while
# still not re-announcing. Distinct from the case above, which restarts
# against an already-expired episode.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
midepisode_state="$test_tmp/restart-dedup-mid.state"
midepisode_now="$(date -u +%s)"
printf 'DEGRADE\tdelta:PR\t%s\t1\t0:%s\nWALLCLOCK\trun\t0\t\n' \
    "$((midepisode_now - 2))" "$((midepisode_now - 1))" >"$midepisode_state"
touch "$fixture_dir/malformed-pr-list"
midepisode_out="$test_tmp/restart-dedup-mid.out"
bash "$watcher" --iterations 1 --state-file "$midepisode_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$midepisode_out"
rm "$fixture_dir/malformed-pr-list"
assert_count "$midepisode_out" 0 '^OBSERVATION-DEGRADED '
assert_count "$midepisode_state" 1 \
    "^DEGRADE[[:space:]]+delta:PR[[:space:]]+$((midepisode_now - 2))[[:space:]]+1[[:space:]]+1:[0-9]+\$"

# Gemini review (PR #1102): state_get can succeed with an EMPTY string (an
# existing entry whose own field is stored empty) -- the `||` fallback
# elsewhere never catches this since it only fires on state_get FAILURE.
# Pre-seeds a DEGRADE row with an empty extra (notified) field alongside a
# real, non-empty first_failure_at, so observation_record_failure() takes
# the "existing episode" branch (first_failure non-empty) with an
# unguarded-empty notified -- exactly the shape that broke `[ -eq 0 ]`
# before the defensive default. Asserts both that the shell never prints
# the bash integer-expression error AND that the fix actually restores the
# correct behavior (still announces once), not merely avoids a crash.
# The detail field must ALSO be empty here, not merely absent a colon:
# `IFS=$'\t' read` collapses CONSECUTIVE tabs because tab is one of bash's
# IFS-whitespace characters, so an empty field followed by a NON-empty
# later field cannot round-trip through this file's tab-separated state
# format at all (the later field's content shifts left into the empty
# one's slot) -- a pre-existing property of every state kind here, not
# something this fix touches. A trailing empty extra+detail (nothing
# non-empty follows) has no such field to shift into it and round-trips
# correctly, which is what actually exercises state_get returning success
# with an empty string rather than accidentally exercising a corrupted parse.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
degrade_empty_extra_first_failure=$(($(date -u +%s) - 5))
degrade_empty_extra_state="$test_tmp/degrade-empty-extra.state"
printf 'DEGRADE\tdelta:PR\t%s\t\t\nWALLCLOCK\trun\t0\t\n' \
    "$degrade_empty_extra_first_failure" \
    >"$degrade_empty_extra_state"
touch "$fixture_dir/malformed-pr-list"
degrade_empty_extra_out="$test_tmp/degrade-empty-extra.out"
degrade_empty_extra_err="$test_tmp/degrade-empty-extra.err"
bash "$watcher" --iterations 1 --state-file "$degrade_empty_extra_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$degrade_empty_extra_out" 2>"$degrade_empty_extra_err"
rm "$fixture_dir/malformed-pr-list"
assert_count "$degrade_empty_extra_err" 0 'integer expression expected'
assert_line "$degrade_empty_extra_out" 'OBSERVATION-DEGRADED delta: GitHub PR observation failed for lane delta'

# Same defect, MALPROMO's notified field: pre-seeds a count already past
# the bound with an empty extra, alongside a still-malformed row, so
# resolve_promotion() takes the "notified" comparison with an
# unguarded-empty value.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
malpromo_empty_extra_now="$(date -u +%s)"
malpromo_empty_extra_valid_at=$((malpromo_empty_extra_now - 50))
malpromo_empty_extra_malformed_at=$((malpromo_empty_extra_now - 40))
malpromo_empty_extra_valid_iso="$(date -u -d "@$malpromo_empty_extra_valid_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$malpromo_empty_extra_valid_iso" ] || malpromo_empty_extra_valid_iso="$(date -u -r "$malpromo_empty_extra_valid_at" +%Y-%m-%dT%H:%M:%SZ)"
malpromo_empty_extra_malformed_iso="$(date -u -d "@$malpromo_empty_extra_malformed_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$malpromo_empty_extra_malformed_iso" ] || malpromo_empty_extra_malformed_iso="$(date -u -r "$malpromo_empty_extra_malformed_at" +%Y-%m-%dT%H:%M:%SZ)"
touch "$fixture_dir/malformed-promo-events"
printf '%s\n' "$malpromo_empty_extra_valid_iso" >"$fixture_dir/malformed-promo-valid-at"
printf '%s\n' "$malpromo_empty_extra_malformed_iso" >"$fixture_dir/malformed-promo-null-at"
malpromo_empty_extra_state="$test_tmp/malpromo-empty-extra.state"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s:11\nMALPROMO\talpha:77\t4\t\t\nWALLCLOCK\trun\t0\t\n' \
    "$((malpromo_empty_extra_now + 900))" "$malpromo_empty_extra_valid_at" \
    >"$malpromo_empty_extra_state"
malpromo_empty_extra_out="$test_tmp/malpromo-empty-extra.out"
malpromo_empty_extra_err="$test_tmp/malpromo-empty-extra.err"
bash "$watcher" --iterations 1 --state-file "$malpromo_empty_extra_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$malpromo_empty_extra_out" 2>"$malpromo_empty_extra_err"
rm "$fixture_dir/malformed-promo-events" "$fixture_dir/malformed-promo-valid-at" \
    "$fixture_dir/malformed-promo-null-at"
assert_count "$malpromo_empty_extra_err" 0 'integer expression expected'
assert_line "$malpromo_empty_extra_out" 'OBSERVATION-DEGRADED alpha: malformed ready_for_review event id=null on #77'

# review-r2-codex-verification-1 / Greptile 4055301833: resolve_promotion()'s
# malpromo_notified==0 branch must echo OBSERVATION-DEGRADED BEFORE
# persisting notified=1, so an interruption between the two can only ever
# risk one duplicate announcement on a later poll -- never lose the
# episode's one and only warning. Pre-seeds MALPROMO already past the bound
# with notified genuinely 0 and proves both halves: (a) the poll that
# observes notified=0 emits the warning exactly once and, by the time it
# returns, has durably persisted notified=1 (the ordering fix does not
# trade "never lost" for "never persisted"); and (b) a second invocation
# against that same now-persisted state -- simulating a restart -- does not
# re-emit it.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
ordering_now="$(date -u +%s)"
ordering_valid_at=$((ordering_now - 50))
ordering_malformed_at=$((ordering_now - 40))
ordering_valid_iso="$(date -u -d "@$ordering_valid_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$ordering_valid_iso" ] || ordering_valid_iso="$(date -u -r "$ordering_valid_at" +%Y-%m-%dT%H:%M:%SZ)"
ordering_malformed_iso="$(date -u -d "@$ordering_malformed_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$ordering_malformed_iso" ] || ordering_malformed_iso="$(date -u -r "$ordering_malformed_at" +%Y-%m-%dT%H:%M:%SZ)"
touch "$fixture_dir/malformed-promo-events"
printf '%s\n' "$ordering_valid_iso" >"$fixture_dir/malformed-promo-valid-at"
printf '%s\n' "$ordering_malformed_iso" >"$fixture_dir/malformed-promo-null-at"
ordering_state="$test_tmp/malpromo-notify-ordering.state"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s:11\nMALPROMO\talpha:77\t4\t0\t\nWALLCLOCK\trun\t0\t\n' \
    "$((ordering_now + 900))" "$ordering_valid_at" \
    >"$ordering_state"
ordering_out1="$test_tmp/malpromo-notify-ordering-1.out"
bash "$watcher" --iterations 1 --state-file "$ordering_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$ordering_out1"
assert_line "$ordering_out1" 'OBSERVATION-DEGRADED alpha: malformed ready_for_review event id=null on #77'
assert_count "$ordering_out1" 1 '^OBSERVATION-DEGRADED '
assert_count "$ordering_state" 1 '^MALPROMO[[:space:]]+alpha:77[[:space:]]+5[[:space:]]+1[[:space:]]*$'

rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
ordering_out2="$test_tmp/malpromo-notify-ordering-2.out"
bash "$watcher" --iterations 1 --state-file "$ordering_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$ordering_out2"
rm "$fixture_dir/malformed-promo-events" "$fixture_dir/malformed-promo-valid-at" \
    "$fixture_dir/malformed-promo-null-at"
assert_count "$ordering_out2" 0 '^OBSERVATION-DEGRADED '

# #1041 challenge r1 finding 1 (multi-lane): a degraded lane's backoff must
# never delay a healthy lane sharing the same specs[] list. alpha fails
# every poll here (never heals, --degrade-window-seconds is generous enough
# that it never gives up either) while a second lane, healthy, always
# succeeds; healthy's own gh pr list call count must equal the number of
# polls exactly, proving it is never skipped or delayed by alpha's ongoing
# backoff -- the empirical regression the challenger reproduced against
# round 1's blocking (sleep-in-place) version of this mechanism.
# #1041 challenge r2 finding claude-2: the healthy-lane assertion alone
# does not prove observation_ready() ever actually returns false -- a
# mutation that always attempts every endpoint still passes it. So this
# also counts ALPHA's own gh pr list attempts: with --interval-seconds 1
# and the first backoff tier at 5s, alpha's degraded PR endpoint must be
# attempted exactly once across all 3 polls (poll 1 fails and schedules a
# retry ~5s out; polls 2 and 3, only 1-2s later, must be genuinely skipped,
# not merely deduplicated in the output) and its persisted DEGRADE detail
# must show exactly one recorded attempt.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase" "$fixture_dir/healthy-pr-list-calls" \
    "$fixture_dir/alpha-pr-list-attempts"
touch "$fixture_dir/fail-branch-alpha-pr-list"
multilane_out="$test_tmp/multilane.out"
multilane_state="$test_tmp/multilane.state"
bash "$watcher" --iterations 3 --state-file "$multilane_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    healthy:branch-healthy:n5:evanharmon1/harmon-devkit \
    >"$multilane_out"
rm "$fixture_dir/fail-branch-alpha-pr-list"
assert_count "$multilane_out" 1 '^OBSERVATION-DEGRADED alpha: GitHub PR observation failed for lane alpha$'
[ -f "$fixture_dir/healthy-pr-list-calls" ] || fail "healthy lane's gh pr list was never called"
healthy_calls="$(<"$fixture_dir/healthy-pr-list-calls")"
[ "$healthy_calls" -eq 3 ] ||
    fail "healthy lane's gh pr list was not called on every poll (expected 3, got $healthy_calls)"
rm -f "$fixture_dir/healthy-pr-list-calls"
[ -f "$fixture_dir/alpha-pr-list-attempts" ] || fail "alpha's degraded gh pr list was never attempted"
alpha_attempts="$(<"$fixture_dir/alpha-pr-list-attempts")"
[ "$alpha_attempts" -eq 1 ] ||
    fail "alpha's degraded gh pr list was not skipped on later polls (expected exactly 1 attempt, got $alpha_attempts)"
rm -f "$fixture_dir/alpha-pr-list-attempts"
assert_count "$multilane_state" 1 '^DEGRADE[[:space:]]+alpha:PR[[:space:]]+[0-9]+[[:space:]]+1[[:space:]]+1:[0-9]+$'

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
# #1041 persistent case: --degrade-window-seconds 0 gives this failure no
# grace period at all, so the give-up happens on the very same (only) poll
# this single-iteration invocation makes -- proving the eventual exit-1
# behavior is unchanged, and that exactly one OBSERVATION-DEGRADED marks the
# episode even when it is also the episode's last poll. A positive window is
# exercised by the transient/bounded-mid-episode cases above/below instead,
# where a real --interval-seconds lets a later poll retry non-blockingly.
touch "$fixture_dir/malformed-pr-list"
github_failure_out="$test_tmp/github-failure.out"
github_failure_err="$test_tmp/github-failure.err"
if bash "$watcher" --iterations 1 --registry "$registry" \
    --state-file "$test_tmp/github-failure.state" \
    --workspace-root "$workspace_root" --interval-seconds 0 --degrade-window-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$github_failure_out" 2>"$github_failure_err"; then
    fail 'watcher accepted a malformed GitHub PR observation'
fi
assert_line "$github_failure_err" 'lane-watch: GitHub PR observation failed for lane delta'
assert_line "$github_failure_out" 'OBSERVATION-DEGRADED delta: GitHub PR observation failed for lane delta'
assert_count "$github_failure_out" 1 '^OBSERVATION-DEGRADED '
assert_count "$test_tmp/github-failure.state" 1 '^AGENT[[:space:]]+delta[[:space:]]+absent'
rm "$fixture_dir/malformed-pr-list"

rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
touch "$fixture_dir/fail-api"
activity_failure_out="$test_tmp/activity-failure.out"
activity_failure_err="$test_tmp/activity-failure.err"
if bash "$watcher" --iterations 1 --state-file "$test_tmp/activity-failure.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --degrade-window-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$activity_failure_out" 2>"$activity_failure_err"; then
    fail 'watcher accepted an indeterminate GitHub activity observation'
fi
assert_line "$activity_failure_err" 'lane-watch: GitHub activity observation failed for lane alpha'
assert_line "$activity_failure_out" 'OBSERVATION-DEGRADED alpha: GitHub activity observation failed for lane alpha'
assert_count "$activity_failure_out" 1 '^OBSERVATION-DEGRADED '
assert_count "$test_tmp/activity-failure.state" 1 '^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+'
rm "$fixture_dir/fail-api"

# Integration-r3-codex-cloud finding #5: activity_rows() computed each row's
# timestamp via `... // empty`, so a selected (trusted-actor) row missing
# every timestamp field it needs silently produced nothing for that one `jq`
# iteration -- the row vanished rather than the fetch failing, so a malformed
# API response (a real activity entry missing its timestamp) was
# indistinguishable from a genuinely quiet window. The malformed-activity-entry
# fixture returns a resolvable ready_for_review event (so the cold-start
# window opens and activity_snapshot() is actually reached) but a review row
# from a trusted actor with none of submitted_at/updated_at/created_at. This
# must now fail the snapshot the same way a hard API error does, not resolve
# to zero activity.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
touch "$fixture_dir/malformed-activity-entry"
malformed_activity_out="$test_tmp/malformed-activity.out"
malformed_activity_err="$test_tmp/malformed-activity.err"
if bash "$watcher" --iterations 1 --state-file "$test_tmp/malformed-activity.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --degrade-window-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$malformed_activity_out" 2>"$malformed_activity_err"; then
    fail 'watcher accepted an activity entry missing its timestamp'
fi
assert_line "$malformed_activity_err" 'lane-watch: GitHub activity observation failed for lane alpha'
assert_count "$malformed_activity_out" 1 '^OBSERVATION-DEGRADED '
rm "$fixture_dir/malformed-activity-entry"

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
    --interval-seconds 0 --post-promotion-seconds 900 --degrade-window-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$expired_out" 2>"$expired_err"; then
    fail 'watcher accepted a hard API failure while resolving a cold-start expired window'
fi
assert_line "$expired_err" 'lane-watch: GitHub activity observation failed for lane alpha'
assert_count "$expired_out" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$expired_out" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$expired_out" 1 '^OBSERVATION-DEGRADED '
assert_count "$test_tmp/expired.state" 1 '^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+'
rm "$fixture_dir/fail-api"

# A window observed long after `until` -- regardless of how stale, not just
# within one poll interval, now that no interval-based tolerance exists --
# still takes exactly one closing snapshot before the state is torn down, so
# activity in the tail of the window a poll never lands inside is still
# caught. The positive `POST-PROMOTION-CLOSED` signal fires exactly once
# alongside that activity line -- both signals coexist on the same
# snapshot; CLOSED is neither suppressed by activity being present nor
# duplicated by it.
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
# This window's persisted WINDOW detail carries no ":event_id" suffix (the
# legacy shape), and this poll's warm re-check resolves no fresh event
# (warm-events-empty is not touched here, but the default gh stub's events
# endpoint returns nothing usable outside its own phase-driven fixture), so
# the closing snapshot trusts the persisted `since` with an empty event id --
# the "since=<epoch>:" trailing-colon legacy-adoption shape documented in the
# header comment and in poll_activity()'s own comments.
assert_line "$tail_out" "POST-PROMOTION-CLOSED alpha: #77 since=${tail_since}:"
assert_count "$tail_out" 1 '^POST-PROMOTION-CLOSED '
assert_count "$test_tmp/tail-window.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$test_tmp/tail-window.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# Round 5's finding #1: a clean close emitted no positive event anywhere --
# the orchestrator could only ever infer "quiet" from silence plus its own
# timer, a signal a stuck cold-start window (see cold-never-resolves below)
# satisfies just as well. A window well past `until`, with genuinely no
# activity pending, must still emit the new `POST-PROMOTION-CLOSED` signal
# exactly once before `WINDOW`/`CLOSING` are torn down. No dedicated "empty"
# gh fixture is needed for this: the phase-driven default rows are dated
# 2098-01-01, far outside this window's [since, until] bounds, so they are
# genuinely fetched (proving the snapshot ran) and then correctly filtered
# to zero activity.
#
# This same fixture also doubles as the crash-recovery proof for echoing
# POST-PROMOTION-CLOSED before persist_state rather than after: a crash in
# that gap leaves CLOSING durably unset, and the state a subsequent poll
# would see -- an expired window, no CLOSING key -- is byte-for-byte the
# state seeded here. There is nothing left for a dedicated "crash" fixture
# to seed differently; this test already proves the retry emits the line.
#
# Since finding challenge-r7-codex-adversarial-1's fix, a warm poll like this
# one also re-resolves promotion_epoch() before deciding to close (exactly so
# a stale schedule cannot emit a false close here -- see the samehead-rearm
# test below for the positive case of that re-check). The `warm-events-empty`
# fixture makes the events endpoint report "no ready_for_review event" for
# this poll, so that re-check safely no-ops and trusts this seeded window
# unchanged, rather than comparing this test's real wall-clock `since` against
# the phase-driven default fixture's unrelated fictional 2098-01-01 event
# (which exists only to give OTHER tests' genuine cold-starts a still-open
# window under real wall-clock time, and is never meant to describe this
# window). It does not touch the reviews/comments/inline endpoints below,
# which stay on the phase-driven default so the "genuinely fetched, then
# filtered to zero" proof above still holds.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
touch "$fixture_dir/warm-events-empty"
closed_now="$(date -u +%s)"
closed_until=$((closed_now - 1200))
closed_since=$((closed_until - 900))
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s\nWALLCLOCK\trun\t0\t\n' \
    "$closed_until" "$closed_since" >"$test_tmp/closed-quiet.state"
closed_quiet_out="$test_tmp/closed-quiet.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/closed-quiet.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$closed_quiet_out"
rm "$fixture_dir/warm-events-empty"
# Same legacy-adoption shape as the tail-window case above: this WINDOW's
# persisted detail also carries no event id, and warm-events-empty makes this
# poll's re-check resolve nothing fresh, so the closing snapshot trusts the
# persisted `since` with an empty event id.
assert_line "$closed_quiet_out" "POST-PROMOTION-CLOSED alpha: #77 since=${closed_since}:"
assert_count "$closed_quiet_out" 1 '^POST-PROMOTION-CLOSED '
assert_count "$closed_quiet_out" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$test_tmp/closed-quiet.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$test_tmp/closed-quiet.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

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
# premature lie." Only proving the endpoint was never called can. The same
# fast path must also never re-announce `POST-PROMOTION-CLOSED`: that event
# belongs solely to the snapshot that first observes and durably records
# CLOSING, never to a later restart that only finds the cleanup left undone.
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
assert_count "$closing_out" 0 '^POST-PROMOTION-CLOSED '
[ ! -f "$fixture_dir/fast-path-calls" ] ||
    fail 'watcher re-fetched activity for a window already closed durably'
assert_count "$test_tmp/closing-durable.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$test_tmp/closing-durable.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# Round 6 confidence found finding #2: the ACTIVITY row loop set the dedup
# key and persisted it BEFORE echoing the line, so a crash between a
# successful persist_state and the echo left that row's key durably set
# with the notification never printed -- permanently and silently
# suppressed, since every later poll's dedup check sees the key already
# present and skips it forever. Mirroring POST-PROMOTION-CLOSED's own
# crash-safe reorder (round 5), the echo must happen before persist_state
# commits the key, so a real crash there can duplicate a notification but
# never lose one. A process-level crash mid-statement cannot be injected
# deterministically from a test, but persist_state() itself calling `exit 1`
# on a save failure is an equally real interruption landing between the
# SAME two statements a crash would -- reachable by making persist_state()'s
# rename fail via the $WATCH_FIXTURES/fail-mv-gated `mv` stub above (a
# chmod-based unwritable directory doesn't work under root, which bypasses
# discretionary permission checks entirely -- finding integration-r1-codex-
# cloud-6). The lane, report, and agent fixtures below are chosen so this is
# the ONLY persist_state call the run ever reaches, isolating the ordering
# this finding is about from every other persist_state call the watcher
# makes.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
touch "$fixture_dir/malformed-list"
persistfail_now="$(date -u +%s)"
persistfail_since=$((persistfail_now - 300))
persistfail_until=$((persistfail_since + 900))
persistfail_activity_at=$((persistfail_since + 50))
persistfail_activity_iso="$(date -u -d "@$persistfail_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$persistfail_activity_iso" ] || persistfail_activity_iso="$(date -u -r "$persistfail_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$persistfail_activity_iso" >"$fixture_dir/tail-activity-at"
persistfail_dir="$test_tmp/persist-fail-state"
mkdir -p "$persistfail_dir"
printf 'PR\tzeta\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\tzeta\t77\t%s\t%s\nWALLCLOCK\trun\t0\t\n' \
    "$persistfail_until" "$persistfail_since" >"$persistfail_dir/watcher.state"
touch "$fixture_dir/fail-mv"
persistfail_out="$test_tmp/persist-fail.out"
persistfail_err="$test_tmp/persist-fail.err"
if bash "$watcher" --iterations 1 --state-file "$persistfail_dir/watcher.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z zeta:branch-alpha:n6:evanharmon1/harmon-devkit \
    >"$persistfail_out" 2>"$persistfail_err"; then
    fail 'watcher exited zero despite an unpersistable state directory'
fi
rm "$fixture_dir/fail-mv"
rm "$fixture_dir/malformed-list" "$fixture_dir/tail-activity-at"
assert_line "$persistfail_err" "lane-watch: could not persist state to $persistfail_dir/watcher.state"
# WINDOW was hand-seeded with the legacy (no event id) detail shape, and this
# poll's tail-activity-at fixture returns no resolvable event, so the warm
# path trusts the persisted since with its empty event id.
assert_line "$persistfail_out" "POST-PROMOTION-ACTIVITY zeta: trusted-codex review 901 since=${persistfail_since}:"
assert_count "$persistfail_out" 1 '^POST-PROMOTION-ACTIVITY '

# Finding integration-r1-codex-cloud-2: activity_rows() computed a
# comment/inline row's single activity instant as `.updated_at // .created_at`
# -- and GitHub always sets updated_at (equal to created_at at creation), so
# that `// .created_at` fallback essentially never triggers. A comment
# CREATED inside a still-open window but EDITED after the window's `until`
# then has an updated_at outside [since,until], so the pre-fix row filter
# dropped it entirely even though real in-window activity happened. Seed a
# WARM, still-open window (until comfortably in the future, so this is purely
# about the row filter, not window expiry) and a comment whose created_at
# falls inside [since,until] but whose updated_at falls after `until`; it
# must still be reported.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
ce_now="$(date -u +%s)"
ce_since=$((ce_now - 300))
ce_until=$((ce_now + 400))
ce_created_at=$((ce_since + 50))
ce_updated_at=$((ce_until + 500))
ce_created_iso="$(date -u -d "@$ce_created_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$ce_created_iso" ] || ce_created_iso="$(date -u -r "$ce_created_at" +%Y-%m-%dT%H:%M:%SZ)"
ce_updated_iso="$(date -u -d "@$ce_updated_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$ce_updated_iso" ] || ce_updated_iso="$(date -u -r "$ce_updated_at" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$ce_created_iso" >"$fixture_dir/created-edit-created-at"
printf '%s\n' "$ce_updated_iso" >"$fixture_dir/created-edit-updated-at"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s\nWALLCLOCK\trun\t0\t\n' \
    "$ce_until" "$ce_since" >"$test_tmp/created-edit.state"
created_edit_out="$test_tmp/created-edit.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/created-edit.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$created_edit_out"
rm "$fixture_dir/created-edit-created-at" "$fixture_dir/created-edit-updated-at"
# Same legacy (no event id) WINDOW shape as the persistfail case above.
assert_line "$created_edit_out" "POST-PROMOTION-ACTIVITY alpha: maintainer comment 801 since=${ce_since}:"
assert_count "$created_edit_out" 1 '^POST-PROMOTION-ACTIVITY '
assert_count "$created_edit_out" 0 '^POST-PROMOTION-CLOSED '

# A cold-start window whose epoch resolves to a real, already-past deadline
# (the provisional deadline had already passed too) still takes exactly one
# snapshot over the REAL [since,until] before the window is torn down --
# resolving late does not abandon the window, and the positive
# `POST-PROMOTION-CLOSED` signal still fires exactly once for it.
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
assert_line "$cold_resolve_out" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 901 since=${resolve_real_since}:401"
assert_count "$cold_resolve_out" 1 '^POST-PROMOTION-ACTIVITY '
assert_count "$cold_resolve_out" 0 '^POST-PROMOTION-INDETERMINATE '
# A cold-start resolution carries the freshly resolved event id (401, from
# the cold-resolve-since fixture branch) in the closed event's identity.
assert_line "$cold_resolve_out" "POST-PROMOTION-CLOSED alpha: #77 since=${resolve_real_since}:401"
assert_count "$cold_resolve_out" 1 '^POST-PROMOTION-CLOSED '
assert_count "$test_tmp/cold-resolve.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$test_tmp/cold-resolve.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# Round 6 confidence found finding #1: `expired` was computed once, from the
# WINDOW's *provisional* deadline (observe_pr()'s placeholder, set before the
# real promotion epoch was known), and never recomputed once the cold-start
# branch resolved the real epoch -- defended by an inline comment claiming
# the real `until` could only be <= the provisional one. That claim fails
# after a watcher restart plus an off-watch withdraw-then-re-promote at an
# unchanged head, where the newly resolved epoch can land LATER than the
# stale provisional deadline. A provisional deadline already in the past
# must not force a still-open real window closed: resolving to a real window
# that has NOT elapsed must persist it and take a normal snapshot, never
# emit POST-PROMOTION-CLOSED on this same poll.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
stillopen_now="$(date -u +%s)"
stillopen_provisional_until=$((stillopen_now - 1200))
stillopen_real_since=$((stillopen_now - 300))
stillopen_activity_at=$((stillopen_real_since + 100))
stillopen_since_iso="$(date -u -d "@$stillopen_real_since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$stillopen_since_iso" ] || stillopen_since_iso="$(date -u -r "$stillopen_real_since" +%Y-%m-%dT%H:%M:%SZ)"
stillopen_activity_iso="$(date -u -d "@$stillopen_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$stillopen_activity_iso" ] || stillopen_activity_iso="$(date -u -r "$stillopen_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$stillopen_since_iso" >"$fixture_dir/cold-resolve-since"
printf '%s\n' "$stillopen_activity_iso" >"$fixture_dir/cold-resolve-activity-at"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t\nWALLCLOCK\trun\t0\t\n' \
    "$stillopen_provisional_until" >"$test_tmp/still-open.state"
stillopen_out="$test_tmp/still-open.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/still-open.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$stillopen_out"
rm "$fixture_dir/cold-resolve-since" "$fixture_dir/cold-resolve-activity-at"
assert_line "$stillopen_out" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 901 since=${stillopen_real_since}:401"
assert_count "$stillopen_out" 1 '^POST-PROMOTION-ACTIVITY '
assert_count "$stillopen_out" 0 '^POST-PROMOTION-CLOSED '
assert_count "$stillopen_out" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$test_tmp/still-open.state" 1 '^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+'
assert_count "$test_tmp/still-open.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# The inverse: a provisional deadline still comfortably in the future must
# not keep a real, already-elapsed window open. Once the real epoch resolves
# to a window whose `until` has already passed, the watcher must close on
# THIS SAME poll -- not be fooled by the stale provisional value into
# treating the window as still open and deferring the close to a later poll
# that a lane whose PR state stops changing may never actually get.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
realexpired_now="$(date -u +%s)"
realexpired_provisional_until=$((realexpired_now + 1200))
realexpired_real_since=$((realexpired_now - 2000))
realexpired_activity_at=$((realexpired_real_since + 100))
realexpired_since_iso="$(date -u -d "@$realexpired_real_since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$realexpired_since_iso" ] || realexpired_since_iso="$(date -u -r "$realexpired_real_since" +%Y-%m-%dT%H:%M:%SZ)"
realexpired_activity_iso="$(date -u -d "@$realexpired_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$realexpired_activity_iso" ] || realexpired_activity_iso="$(date -u -r "$realexpired_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$realexpired_since_iso" >"$fixture_dir/cold-resolve-since"
printf '%s\n' "$realexpired_activity_iso" >"$fixture_dir/cold-resolve-activity-at"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t\nWALLCLOCK\trun\t0\t\n' \
    "$realexpired_provisional_until" >"$test_tmp/real-expired.state"
realexpired_out="$test_tmp/real-expired.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/real-expired.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$realexpired_out"
rm "$fixture_dir/cold-resolve-since" "$fixture_dir/cold-resolve-activity-at"
assert_line "$realexpired_out" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 901 since=${realexpired_real_since}:401"
# Same cold-resolve-since fixture branch, same event id 401.
assert_line "$realexpired_out" "POST-PROMOTION-CLOSED alpha: #77 since=${realexpired_real_since}:401"
assert_count "$realexpired_out" 1 '^POST-PROMOTION-CLOSED '
assert_count "$test_tmp/real-expired.state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$test_tmp/real-expired.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# Integration-stage finding challenge-r7-codex-adversarial-1: a WARM window
# (WINDOW already fully armed from an earlier promotion -- since/until both
# persisted, not the cold-start provisional shape) was never re-validated
# against the actual, current promotion event once armed. Reproduce the exact
# sequence the finding describes: an off-watch withdraw (gh pr ready --undo)
# then re-promote at the SAME PR tuple -- so the single observe_pr() call
# this poll makes sees discover_pr()'s "#N draft=<bool> <STATE> head=<sha>"
# string as byte-for-byte unchanged from the seeded PR state and never
# touches WINDOW -- while the real promotion epoch (from promotion_epoch(),
# i.e. the latest ready_for_review event) has actually advanced far past the
# stale window's own bounds. Activity lands within the NEW promotion's real
# [since,until] but outside the STALE persisted one. Pre-fix, poll_activity()
# never re-resolves promotion_epoch() on a warm poll, so it filters this row
# against the stale bounds (dropping it) and, since the stale `until` has
# long since passed, emits POST-PROMOTION-CLOSED on the wrong schedule -- a
# false all-clear. Fixed, the warm path re-resolves the epoch every poll,
# notices since2 != the persisted since1, re-arms WINDOW to [since2,until2],
# and correctly reports the activity with no premature close.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
samehead_now="$(date -u +%s)"
samehead_since1=$((samehead_now - 3000))
samehead_until1=$((samehead_since1 + 900))
samehead_since2=$((samehead_now - 100))
samehead_until2=$((samehead_since2 + 900))
samehead_activity_at=$((samehead_since2 + 50))
samehead_since2_iso="$(date -u -d "@$samehead_since2" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$samehead_since2_iso" ] || samehead_since2_iso="$(date -u -r "$samehead_since2" +%Y-%m-%dT%H:%M:%SZ)"
samehead_activity_iso="$(date -u -d "@$samehead_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$samehead_activity_iso" ] || samehead_activity_iso="$(date -u -r "$samehead_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
# The cold-resolve-since/-activity-at fixture pair drives the events and
# reviews endpoints unconditionally (regardless of cold vs warm state), which
# is exactly what is needed here: control the RE-RESOLVED epoch on a warm
# poll, not just a cold-start one.
printf '%s\n' "$samehead_since2_iso" >"$fixture_dir/cold-resolve-since"
printf '%s\n' "$samehead_activity_iso" >"$fixture_dir/cold-resolve-activity-at"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s\nWALLCLOCK\trun\t0\t\n' \
    "$samehead_until1" "$samehead_since1" >"$test_tmp/samehead-rearm.state"
samehead_rearm_out="$test_tmp/samehead-rearm.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/samehead-rearm.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$samehead_rearm_out"
rm "$fixture_dir/cold-resolve-since" "$fixture_dir/cold-resolve-activity-at"
assert_line "$samehead_rearm_out" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 901 since=${samehead_since2}:401"
assert_count "$samehead_rearm_out" 1 '^POST-PROMOTION-ACTIVITY '
assert_count "$samehead_rearm_out" 0 '^POST-PROMOTION-CLOSED '
assert_count "$samehead_rearm_out" 0 '^POST-PROMOTION-INDETERMINATE '
# WINDOW must now reflect the NEW epoch, proving a genuine re-arm rather than
# merely surviving with its stale bounds untouched.
assert_count "$test_tmp/samehead-rearm.state" 1 \
    "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+${samehead_until2}[[:space:]]+${samehead_since2}:401\$"
assert_count "$test_tmp/samehead-rearm.state" 0 '^CLOSING[[:space:]]+alpha[[:space:]]+'

# Finding integration-r2-codex-cloud-2: promotion-identity re-checking goes
# dormant once a window closes, because poll_activity() -- the only place
# that re-validates promotion identity against a freshly resolved
# promotion_epoch() -- is only ever called while a WINDOW is active. Once a
# window closes cleanly, WINDOW is deleted, and a same-head withdraw-then-
# re-promote occurring entirely between two polls AFTER that close collapses
# back to the identical discover_pr() tuple: observe_pr() never notices it
# and never re-arms WINDOW, so pre-fix nothing in this file would ever poll
# activity for that lane again. This reproduces the exact sequence: (1) a
# window that closes cleanly through the watcher's OWN normal close path
# (lane theta below reaches that close by resolving, on its very first
# observation, an already-long-expired promotion epoch -- exactly how the
# existing cold-start-expired tests above establish a genuine watcher-
# produced close, not a hand-seeded already-closed state), (2) a same-head
# re-promotion presented between polls two and three with an UNCHANGED
# discover_pr() PR tuple (the dormant-pr-json fixture is byte-for-byte
# identical across all three invocations below) but a freshly resolved,
# LATER promotion_epoch() event, and (3) activity landing inside that new
# promotion's real window. Pre-fix, step (2) would never even attempt a
# promotion_epoch() re-check (poll_activity() is simply never called once
# WINDOW is gone), so the activity in step (3) would never be reported and
# no POST-PROMOTION-ACTIVITY line would ever appear for lane theta again --
# permanent, silent dormancy. Fixed, check_repromotion_after_close() runs
# exactly when WINDOW is absent and the observed tuple still reads promoted,
# compares the freshly resolved epoch:event_id against the ARMED identity
# persisted from the first (closed) window, finds it differs, and re-arms a
# fresh WINDOW from it -- which the same poll's poll_activity() call then
# uses to report the in-window activity.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
dormant_now="$(date -u +%s)"
# Window 1 resolves to an epoch already long expired at the moment of its
# own first observation, so it closes within the same single poll that
# discovers it -- a genuine watcher-produced close, per the existing
# cold-start-expired tests' own established pattern.
dormant_since1=$((dormant_now - 5000))
# Window 2 is the new promotion: a fresh epoch, still comfortably open.
dormant_since2=$((dormant_now - 100))
dormant_until2=$((dormant_since2 + 900))
dormant_activity_at=$((dormant_since2 + 20))
dormant_since1_iso="$(date -u -d "@$dormant_since1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$dormant_since1_iso" ] || dormant_since1_iso="$(date -u -r "$dormant_since1" +%Y-%m-%dT%H:%M:%SZ)"
dormant_since2_iso="$(date -u -d "@$dormant_since2" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$dormant_since2_iso" ] || dormant_since2_iso="$(date -u -r "$dormant_since2" +%Y-%m-%dT%H:%M:%SZ)"
dormant_activity_iso="$(date -u -d "@$dormant_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$dormant_activity_iso" ] || dormant_activity_iso="$(date -u -r "$dormant_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' '[{"number":88,"isDraft":false,"state":"OPEN","headRefOid":"dddddddddddddddddddddddddddddddddddddddd"}]' \
    >"$fixture_dir/dormant-pr-json"
printf '%s\n' "$dormant_since1_iso" >"$fixture_dir/dormant-since1"
touch "$fixture_dir/dormant-events"
dormant_state="$test_tmp/dormant.state"

# Poll 1 (fresh state, lane theta first observed): the tuple is promoted from
# the start, so observe_pr() arms a provisional WINDOW; poll_activity() then
# cold-start-resolves dormant-since1 (already 5000s in the past), finds the
# window already expired, and closes it in this same poll -- genuine watcher
# output, matching the established cold-resolve pattern above.
printf '%s\n' 1 >"$fixture_dir/dormant-phase"
dormant_out1="$test_tmp/dormant-1.out"
bash "$watcher" --iterations 1 --state-file "$dormant_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z theta:branch-theta:n7:evanharmon1/harmon-devkit \
    >"$dormant_out1"
# Window 1 resolves from dormant-phase-1's event id 701.
assert_line "$dormant_out1" "POST-PROMOTION-CLOSED theta: #88 since=${dormant_since1}:701"
assert_count "$dormant_out1" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$dormant_state" 0 '^WINDOW[[:space:]]+theta[[:space:]]+'
assert_count "$dormant_state" 0 '^CLOSING[[:space:]]+theta[[:space:]]+'
assert_count "$dormant_state" 1 "^ARMED[[:space:]]+theta[[:space:]]+${dormant_since1}:701"

# Poll 2: nothing changes -- same tuple, same phase 1 epoch. WINDOW must stay
# absent (dormant, correctly): the already-seen promotion is not a new one.
dormant_out2="$test_tmp/dormant-2.out"
bash "$watcher" --iterations 1 --state-file "$dormant_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z theta:branch-theta:n7:evanharmon1/harmon-devkit \
    >"$dormant_out2"
assert_count "$dormant_out2" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$dormant_out2" 0 '^POST-PROMOTION-CLOSED '
assert_count "$dormant_out2" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$dormant_state" 0 '^WINDOW[[:space:]]+theta[[:space:]]+'

# Poll 3: the off-watch withdraw-then-re-promote. discover_pr()'s tuple is
# STILL byte-for-byte the dormant-pr-json fixture (unchanged), but the events
# endpoint now also reports event 702 at dormant_since2 -- a genuinely later
# ready_for_review event that promotion_epoch() must pick as the new latest.
printf '%s\n' "$dormant_since2_iso" >"$fixture_dir/dormant-since2"
printf '%s\n' "$dormant_activity_iso" >"$fixture_dir/dormant-activity"
printf '%s\n' 2 >"$fixture_dir/dormant-phase"
dormant_out3="$test_tmp/dormant-3.out"
bash "$watcher" --iterations 1 --state-file "$dormant_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z theta:branch-theta:n7:evanharmon1/harmon-devkit \
    >"$dormant_out3"
rm "$fixture_dir/dormant-events" "$fixture_dir/dormant-phase" "$fixture_dir/dormant-since1" \
    "$fixture_dir/dormant-since2" "$fixture_dir/dormant-activity" "$fixture_dir/dormant-pr-json"
assert_line "$dormant_out3" "POST-PROMOTION-ACTIVITY theta: trusted-codex review 903 since=${dormant_since2}:702"
assert_count "$dormant_out3" 1 '^POST-PROMOTION-ACTIVITY '
assert_count "$dormant_out3" 0 '^POST-PROMOTION-CLOSED '
assert_count "$dormant_out3" 0 '^POST-PROMOTION-INDETERMINATE '
# WINDOW is re-armed from the NEW epoch and ARMED tracks it, proving a
# genuine re-arm of a fresh window rather than an accidental reuse of the
# first, already-closed one's bounds.
assert_count "$dormant_state" 1 \
    "^WINDOW[[:space:]]+theta[[:space:]]+88[[:space:]]+${dormant_until2}[[:space:]]+${dormant_since2}:702\$"
assert_count "$dormant_state" 1 "^ARMED[[:space:]]+theta[[:space:]]+${dormant_since2}:702"

# Integration-r3-codex-cloud finding #2: POST-PROMOTION-CLOSED carried no
# identity of which promotion actually closed, so two closes for the same
# lane/PR were textually indistinguishable -- a consumer watching for "the
# concrete POST-PROMOTION-CLOSED event" could not tell a stale close (already
# seen) apart from a fresh one for a genuinely new, still-active window. This
# reproduces a close followed by an off-watch re-promotion whose window is
# ALSO already expired at the moment check_repromotion_after_close() re-arms
# it, so poll_activity() closes it again within that same poll -- producing a
# second POST-PROMOTION-CLOSED for lane iota, PR #88, in one invocation.
# Asserting the two closes' carried "since=<epoch>:<event_id>" identities
# differ is the actual proof: pre-fix, both lines would have been the
# byte-for-byte identical "POST-PROMOTION-CLOSED iota: #88" with nothing to
# distinguish them.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
iota_now="$(date -u +%s)"
iota_since1=$((iota_now - 5000))
iota_since2=$((iota_now - 4000))
iota_until2=$((iota_since2 + 900))
iota_activity_at=$((iota_since2 + 100))
iota_since1_iso="$(date -u -d "@$iota_since1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$iota_since1_iso" ] || iota_since1_iso="$(date -u -r "$iota_since1" +%Y-%m-%dT%H:%M:%SZ)"
iota_since2_iso="$(date -u -d "@$iota_since2" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$iota_since2_iso" ] || iota_since2_iso="$(date -u -r "$iota_since2" +%Y-%m-%dT%H:%M:%SZ)"
iota_activity_iso="$(date -u -d "@$iota_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$iota_activity_iso" ] || iota_activity_iso="$(date -u -r "$iota_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' '[{"number":88,"isDraft":false,"state":"OPEN","headRefOid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}]' \
    >"$fixture_dir/dormant-pr-json"
printf '%s\n' "$iota_since1_iso" >"$fixture_dir/dormant-since1"
touch "$fixture_dir/dormant-events"
iota_state="$test_tmp/iota.state"

# Poll 1: cold-start window resolves to since1, already 5000s in the past, so
# it closes within this same poll -- a genuine watcher-produced close.
printf '%s\n' 1 >"$fixture_dir/dormant-phase"
iota_out1="$test_tmp/iota-1.out"
bash "$watcher" --iterations 1 --state-file "$iota_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z iota:branch-theta:n8:evanharmon1/harmon-devkit \
    >"$iota_out1"
assert_line "$iota_out1" "POST-PROMOTION-CLOSED iota: #88 since=${iota_since1}:701"
assert_count "$iota_out1" 1 '^POST-PROMOTION-CLOSED '

# Poll 2: the off-watch withdraw-then-re-promote. discover_pr()'s tuple is
# unchanged (dormant-pr-json is byte-for-byte identical), but the events
# endpoint now also reports event 702 at since2 -- itself ALSO already
# expired once re-armed (since2 + post_promotion_seconds < now), so
# check_repromotion_after_close() re-arms a fresh window from it and this
# same poll's poll_activity() call closes that fresh window immediately too.
printf '%s\n' "$iota_since2_iso" >"$fixture_dir/dormant-since2"
printf '%s\n' "$iota_activity_iso" >"$fixture_dir/dormant-activity"
printf '%s\n' 2 >"$fixture_dir/dormant-phase"
iota_out2="$test_tmp/iota-2.out"
bash "$watcher" --iterations 1 --state-file "$iota_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z iota:branch-theta:n8:evanharmon1/harmon-devkit \
    >"$iota_out2"
rm "$fixture_dir/dormant-events" "$fixture_dir/dormant-phase" "$fixture_dir/dormant-since1" \
    "$fixture_dir/dormant-since2" "$fixture_dir/dormant-activity" "$fixture_dir/dormant-pr-json"
assert_line "$iota_out2" "POST-PROMOTION-ACTIVITY iota: trusted-codex review 903 since=${iota_since2}:702"
assert_line "$iota_out2" "POST-PROMOTION-CLOSED iota: #88 since=${iota_since2}:702"
assert_count "$iota_out2" 1 '^POST-PROMOTION-CLOSED '
# The two closes' carried identities are distinguishable: different epochs,
# different event ids -- proving a consumer correlating against whichever
# promotion it is tracking can tell them apart, which a bare
# "POST-PROMOTION-CLOSED iota: #88" on both polls never could.
[ "$iota_since1" != "$iota_since2" ] || fail 'test setup error: iota since1/since2 must differ'
grep -Fxq "POST-PROMOTION-CLOSED iota: #88 since=${iota_since1}:701" "$iota_out1"
grep -Fxq "POST-PROMOTION-CLOSED iota: #88 since=${iota_since2}:702" "$iota_out2"
assert_count "$iota_state" 0 '^WINDOW[[:space:]]+iota[[:space:]]+'
assert_count "$iota_state" 1 "^ARMED[[:space:]]+iota[[:space:]]+${iota_since2}:702"

# Finding integration-r1-codex-cloud-1: a withdrawal and a same-head
# re-promotion that both land inside the same wall-clock second produce two
# ready_for_review timeline events with an IDENTICAL created_at but distinct
# event ids. promotion_epoch()'s pre-fix epoch-only result, and
# poll_activity()'s pre-fix `since != persisted_since` check, cannot tell
# those two events apart: seeing "no change," the window is never re-armed.
# Poll 1 establishes a real window from a single event (id 401) via the
# watcher's own cold-start code path -- so the persisted WINDOW state is
# genuine watcher output, not a hand-crafted shape. Poll 2 then presents BOTH
# events (401 and 402) tied at the identical created_at, simulating the
# collision. The fix must select 402 (the later, higher-id event) and
# persist a re-armed window keyed to it -- something no pre-fix build could
# ever produce, since pre-fix code neither resolves nor persists an event id
# at all, proving this assertion fails against the pre-fix implementation and
# passes only once the fix is applied.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
samesecond_now="$(date -u +%s)"
samesecond_t=$((samesecond_now - 200))
samesecond_t_iso="$(date -u -d "@$samesecond_t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$samesecond_t_iso" ] || samesecond_t_iso="$(date -u -r "$samesecond_t" +%Y-%m-%dT%H:%M:%SZ)"
samesecond_provisional_until=$((samesecond_now + 1200))
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t\nWALLCLOCK\trun\t0\t\n' \
    "$samesecond_provisional_until" >"$test_tmp/samesecond.state"

# Poll 1: exactly one ready_for_review event (401) resolves the cold-start window.
printf '%s\t401\n' "$samesecond_t_iso" >"$fixture_dir/samesecond-events"
samesecond_out1="$test_tmp/samesecond-1.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/samesecond.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$samesecond_out1"
assert_count "$test_tmp/samesecond.state" 1 \
    "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+$((samesecond_t + 900))[[:space:]]+${samesecond_t}:401\$"

# Poll 2: an off-watch withdraw-then-re-promote lands a SECOND ready_for_review
# event tied to the identical created_at as the first (401 and 402 both at
# $samesecond_t). Real new activity lands just before "now," well inside a
# freshly re-armed window.
printf '%s\t401\t402\n' "$samesecond_t_iso" >"$fixture_dir/samesecond-events"
samesecond_activity_at=$((samesecond_now - 5))
samesecond_activity_iso="$(date -u -d "@$samesecond_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$samesecond_activity_iso" ] || samesecond_activity_iso="$(date -u -r "$samesecond_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$samesecond_activity_iso" >"$fixture_dir/samesecond-activity-at"
samesecond_out2="$test_tmp/samesecond-2.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/samesecond.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$samesecond_out2"
rm "$fixture_dir/samesecond-events" "$fixture_dir/samesecond-activity-at"
assert_line "$samesecond_out2" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 902 since=${samesecond_t}:402"
assert_count "$samesecond_out2" 1 '^POST-PROMOTION-ACTIVITY '
assert_count "$samesecond_out2" 0 '^POST-PROMOTION-CLOSED '
# The persisted window must now be re-keyed to event 402 -- proving the
# collision was detected and re-armed from the correct, later event, not
# merely left unchanged because the timestamp alone still matched.
assert_count "$test_tmp/samesecond.state" 1 \
    "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+$((samesecond_t + 900))[[:space:]]+${samesecond_t}:402\$"

# A cold-start window whose epoch never resolves (a clean, valid response
# with no ready_for_review event -- ordinary GitHub eventual consistency,
# not a hard API failure) emits exactly one POST-PROMOTION-INDETERMINATE
# line, zero POST-PROMOTION-ACTIVITY lines, and never calls any activity
# endpoint (reviews, comments, or inline) at all. It also drops the lane's
# `PR` state entry, not just `WINDOW`/`CLOSING` -- round 5's live repro
# proved that without this, the documented recovery ("restart with the same
# --state-file") never actually re-watches the lane, because observe_pr()
# only re-creates WINDOW on a PR-state change, and a promoted PR's observed
# state ordinarily stops changing once promotion lands.
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
assert_count "$test_tmp/cold-never.state" 0 '^PR[[:space:]]+alpha[[:space:]]+'

# The single most important regression in this round: round 5's live repro
# proved that restarting lane-watch.sh against that SAME --state-file -- the
# only documented recovery for POST-PROMOTION-INDETERMINATE -- was a dead
# end, because nothing ever recreated WINDOW once the PR's observed state
# stopped changing (three consecutive invocations, only the first ever
# produced output). A fresh invocation against the exact state file just
# produced above must now genuinely re-arm: observe_pr() sees the
# still-promoted PR as newly observed (its PR entry is gone) and opens a
# fresh WINDOW on its own, and the watcher goes on to produce a real
# activity snapshot again in the same poll -- proving the recovery is a
# working pipeline, not just a state-file key with nothing reading it.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
rearm_restart_out="$test_tmp/rearm-restart.out"
bash "$watcher" --iterations 1 --state-file "$test_tmp/cold-never.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$rearm_restart_out"
assert_count "$test_tmp/cold-never.state" 1 '^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+'
assert_line "$rearm_restart_out" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 501 since=${default_since_epoch}:401"

# The same asset resolves the repository root and registry in the flattened
# consumer layout when the lane spec supplies its required repository.
flattened_root="$test_tmp/consumer"
flattened_watcher="$flattened_root/.agents/skills/orchestrate/assets/lane-watch.sh"
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
mkdir -p "$linked_main/ai/skills/universal/orchestrate/assets"
cp "$watcher" "$linked_main/ai/skills/universal/orchestrate/assets/lane-watch.sh"
cp "$registry" "$linked_main/agent-registry.json"
git -C "$linked_main" add .
git -C "$linked_main" commit -qm initial
git -C "$linked_main" worktree add -q -b monitor "$linked_main/.worktrees/monitor"
mkdir -p "$linked_main/.worktrees/alpha"
cp "$workspace_root/harmon-devkit/.worktrees/alpha/.lane-report.md" \
    "$linked_main/.worktrees/alpha/.lane-report.md"
linked_watcher="$linked_main/.worktrees/monitor/ai/skills/universal/orchestrate/assets/lane-watch.sh"
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
assert_count "$repo_root/ai/skills/universal/orchestrate/SKILL.md" 1 \
    'state-file <run-dir>/lane-watch.state'
assert_count "$repo_root/ai/skills/universal/orchestrate/SKILL.md" 0 \
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

# Integration-r4-codex-cloud finding #4: activity_rows() emitted and
# globally deduplicated a row's ACTIVITY key using only (lane, kind, id,
# activity_at) -- no promotion identity. When a same-head re-promotion opens
# a NEW window whose bounds still cover a row already reported under the OLD
# window, the row's dedup key was byte-for-byte identical across both
# windows, so the second (legitimately new-window) occurrence was silently
# suppressed as "already reported." Reproduce with two real, live polls: poll
# 1 cold-starts a window from event 301 and reports one review row inside it;
# poll 2 resolves a NEWER event 402 whose window (since2 comfortably inside
# window 1's still-open bounds, mimicking a re-promotion that lands before
# the prior window would otherwise have expired) also covers that exact same
# row (same id, same created_at, refetched unconditionally by the
# rebind-events fixture regardless of phase). Pre-fix, the second poll's key
# collides with the first poll's and the row is dropped; fixed, the key now
# also carries the window's own since_event_id, so the two windows' keys
# differ and the row is correctly reported again under window 2's identity.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
rebind_now="$(date -u +%s)"
rebind_since1=$((rebind_now - 400))
rebind_since2=$((rebind_since1 + 10))
rebind_activity_at=$((rebind_since1 + 50))
rebind_since1_iso="$(date -u -d "@$rebind_since1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$rebind_since1_iso" ] || rebind_since1_iso="$(date -u -r "$rebind_since1" +%Y-%m-%dT%H:%M:%SZ)"
rebind_since2_iso="$(date -u -d "@$rebind_since2" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$rebind_since2_iso" ] || rebind_since2_iso="$(date -u -r "$rebind_since2" +%Y-%m-%dT%H:%M:%SZ)"
rebind_activity_iso="$(date -u -d "@$rebind_activity_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$rebind_activity_iso" ] || rebind_activity_iso="$(date -u -r "$rebind_activity_at" +%Y-%m-%dT%H:%M:%SZ)"
touch "$fixture_dir/rebind-events"
printf '%s\n' 1 >"$fixture_dir/rebind-phase"
printf '%s\n' "$rebind_since1_iso" >"$fixture_dir/rebind-since1"
printf '%s\n' "$rebind_activity_iso" >"$fixture_dir/rebind-activity-at"
rebind_state="$test_tmp/rebind.state"

# Poll 1: cold start resolves event 301 at since1; the review row (id 950,
# created at since1+50) falls inside [since1, since1+900] and is reported,
# durably keyed to window 1's own identity (301).
rebind_out1="$test_tmp/rebind-1.out"
bash "$watcher" --iterations 1 --state-file "$rebind_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$rebind_out1"
assert_line "$rebind_out1" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 950 since=${rebind_since1}:301"
assert_count "$rebind_out1" 1 '^POST-PROMOTION-ACTIVITY '

# Poll 2: a newer event (402) at since2 = since1+10 -- still comfortably
# inside window 1's un-expired bounds, i.e. a re-promotion landing mid-window
# -- differs from the persisted event id, so the warm path re-arms window 2.
# The SAME row (id 950, same created_at) is fetched again and still falls
# inside window 2's bounds too (since1+50 >= since2, <= since2+900), so it is
# evaluated again -- and must be reported again, not suppressed by window 1's
# already-durable key.
printf '%s\n' 2 >"$fixture_dir/rebind-phase"
printf '%s\n' "$rebind_since2_iso" >"$fixture_dir/rebind-since2"
rebind_out2="$test_tmp/rebind-2.out"
bash "$watcher" --iterations 1 --state-file "$rebind_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$rebind_out2"
rm "$fixture_dir/rebind-events" "$fixture_dir/rebind-phase" "$fixture_dir/rebind-since1" \
    "$fixture_dir/rebind-since2" "$fixture_dir/rebind-activity-at"
assert_line "$rebind_out2" "POST-PROMOTION-ACTIVITY alpha: trusted-codex review 950 since=${rebind_since2}:402"
assert_count "$rebind_out2" 1 '^POST-PROMOTION-ACTIVITY '

# #1041 P2 follow-up (was integration-r4-codex-cloud finding #6): a
# ready_for_review event with a missing/null id must never be accepted with
# its id interpolated as the literal text "null" -- that would let two
# distinct malformed same-second promotions collapse to the same
# "<epoch>:null" identity, reproducing the exact silent-loss defect the
# event-id tie-break exists to prevent. The original fix for that simply
# dropped the malformed row and armed from the valid row alone; the bounded
# rule replaces that with: the malformed row's mere presence makes the
# snapshot indeterminate for malformed_promo_poll_bound consecutive polls
# before falling back to the valid row (see promotion_epoch()). This first,
# single-iteration poll is a cold start whose provisional window has not
# expired yet, so it stays exactly as silent as a plain "no event yet"
# indeterminate always has -- no POST-PROMOTION-INDETERMINATE line, and
# WINDOW stays at its provisional (not yet resolved) value rather than being
# armed from the tainted resolution.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
mp_now="$(date -u +%s)"
mp_valid_at=$((mp_now - 300))
mp_null_at=$((mp_now - 100))
mp_valid_iso="$(date -u -d "@$mp_valid_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$mp_valid_iso" ] || mp_valid_iso="$(date -u -r "$mp_valid_at" +%Y-%m-%dT%H:%M:%SZ)"
mp_null_iso="$(date -u -d "@$mp_null_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$mp_null_iso" ] || mp_null_iso="$(date -u -r "$mp_null_at" +%Y-%m-%dT%H:%M:%SZ)"
touch "$fixture_dir/malformed-promo-events"
printf '%s\n' "$mp_valid_iso" >"$fixture_dir/malformed-promo-valid-at"
printf '%s\n' "$mp_null_iso" >"$fixture_dir/malformed-promo-null-at"
mp_out="$test_tmp/malformed-promo.out"
mp_state="$test_tmp/malformed-promo.state"
bash "$watcher" --iterations 1 --state-file "$mp_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$mp_out"
assert_count "$mp_out" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$mp_out" 0 '^OBSERVATION-DEGRADED '
assert_count "$mp_state" 0 "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+$((mp_valid_at + 900))[[:space:]]+${mp_valid_at}:555\$"
assert_count "$mp_state" 1 "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+[0-9]+[[:space:]]*\$"
assert_count "$mp_state" 1 '^MALPROMO[[:space:]]+alpha:77[[:space:]]+1[[:space:]]+0[[:space:]]*$'
assert_count "$mp_state" 0 'null'

# The bound bites after malformed_promo_poll_bound consecutive polls: a warm
# window already armed from the valid row, with the same malformed row still
# present, stays indeterminate (silently trusting the already-armed window,
# same as any other transient events-API gap) through the bound, then falls
# back to the valid row and emits exactly one OBSERVATION-DEGRADED naming the
# malformed row -- so one persistently malformed GitHub row cannot wedge a
# lane's promotion tracking forever. MALPROMO is pre-seeded to 2 so the first
# of these two invocations lands exactly on the bound (3) and the second
# exceeds it (4).
bounded_state="$test_tmp/malformed-promo-bounded.state"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s\nMALPROMO\talpha:77\t2\t0\t\nWALLCLOCK\trun\t0\t\n' \
    "$((mp_valid_at + 900))" "${mp_valid_at}:555" >"$bounded_state"
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
bounded_out1="$test_tmp/malformed-promo-bounded-1.out"
bash "$watcher" --iterations 1 --state-file "$bounded_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$bounded_out1"
assert_count "$bounded_out1" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$bounded_out1" 0 '^OBSERVATION-DEGRADED '
assert_count "$bounded_state" 1 '^MALPROMO[[:space:]]+alpha:77[[:space:]]+3[[:space:]]+0[[:space:]]*$'

rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
bounded_out2="$test_tmp/malformed-promo-bounded-2.out"
bash "$watcher" --iterations 1 --state-file "$bounded_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$bounded_out2"
assert_line "$bounded_out2" 'OBSERVATION-DEGRADED alpha: malformed ready_for_review event id=null on #77'
assert_count "$bounded_out2" 1 '^OBSERVATION-DEGRADED '
assert_count "$bounded_out2" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$bounded_state" 1 '^MALPROMO[[:space:]]+alpha:77[[:space:]]+4[[:space:]]+1[[:space:]]*$'
assert_count "$bounded_state" 1 "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+$((mp_valid_at + 900))[[:space:]]+${mp_valid_at}:555\$"

# A third consecutive malformed poll, still past the bound, must not
# re-announce the same episode.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
bounded_out3="$test_tmp/malformed-promo-bounded-3.out"
bash "$watcher" --iterations 1 --state-file "$bounded_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$bounded_out3"
assert_count "$bounded_out3" 0 '^OBSERVATION-DEGRADED '

# When every ready_for_review event is malformed, resolution must fall
# through to the existing "no resolvable event" indeterminate path -- never
# accept the malformed one for lack of an alternative. Unlike the mixed
# case above there is no valid row to ever fall back to, so this stays
# unbounded and unchanged by the #1041 P2 follow-up.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
touch "$fixture_dir/malformed-promo-all-bad"
mp_allbad_until=$((mp_now - 1200))
mp_allbad_out="$test_tmp/malformed-promo-allbad.out"
mp_allbad_state="$test_tmp/malformed-promo-allbad.state"
# Seed an already-expired provisional deadline (mirroring the cold-never-
# resolves case above) so this single poll's cold-start resolution, finding
# no usable event at all, reports indeterminate immediately rather than
# waiting for a future poll to notice the provisional deadline has passed.
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t\nWALLCLOCK\trun\t0\t\n' \
    "$mp_allbad_until" >"$mp_allbad_state"
bash "$watcher" --iterations 1 --state-file "$mp_allbad_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$mp_allbad_out"
rm "$fixture_dir/malformed-promo-events" "$fixture_dir/malformed-promo-all-bad" \
    "$fixture_dir/malformed-promo-valid-at" "$fixture_dir/malformed-promo-null-at"
assert_line "$mp_allbad_out" 'POST-PROMOTION-INDETERMINATE alpha: #77'
assert_count "$mp_allbad_out" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$mp_allbad_state" 0 '^WINDOW[[:space:]]+alpha[[:space:]]+'
assert_count "$mp_allbad_state" 0 'null'

# #1041 P2 follow-up: malformed-row detection does not depend on tie-break
# ordering -- an older malformed row alongside a newer valid one is caught
# exactly like the newer-malformed case above.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
mp2_null_at=$((mp_now - 500))
mp2_valid_at=$((mp_now - 300))
mp2_null_iso="$(date -u -d "@$mp2_null_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$mp2_null_iso" ] || mp2_null_iso="$(date -u -r "$mp2_null_at" +%Y-%m-%dT%H:%M:%SZ)"
mp2_valid_iso="$(date -u -d "@$mp2_valid_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$mp2_valid_iso" ] || mp2_valid_iso="$(date -u -r "$mp2_valid_at" +%Y-%m-%dT%H:%M:%SZ)"
touch "$fixture_dir/malformed-promo-events"
printf '%s\n' "$mp2_valid_iso" >"$fixture_dir/malformed-promo-valid-at"
printf '%s\n' "$mp2_null_iso" >"$fixture_dir/malformed-promo-null-at"
mp_order_out="$test_tmp/malformed-promo-order.out"
mp_order_state="$test_tmp/malformed-promo-order.state"
bash "$watcher" --iterations 1 --state-file "$mp_order_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$mp_order_out"
rm "$fixture_dir/malformed-promo-events" "$fixture_dir/malformed-promo-valid-at" \
    "$fixture_dir/malformed-promo-null-at"
assert_count "$mp_order_out" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$mp_order_out" 0 '^OBSERVATION-DEGRADED '
assert_count "$mp_order_state" 0 "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+[0-9]+[[:space:]]+${mp2_valid_at}:555\$"
assert_count "$mp_order_state" 1 "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+[0-9]+[[:space:]]*\$"
assert_count "$mp_order_state" 1 '^MALPROMO[[:space:]]+alpha:77[[:space:]]+1[[:space:]]+0[[:space:]]*$'

# #1041 challenge r1 finding codex-2 (adapted from Codex's own extracted-
# function repro): a VALID, NEWER promotion must never be silently dropped
# by trusting an already-expired OLD armed window just because a malformed
# row is also present and still within its bound. resolve_promotion()
# returning status 11 must mean "touch nothing this poll" -- no closing, no
# arming -- never status 10's "trust the old window" (which is only correct
# when nothing has actually changed). Pre-seeds an armed window whose
# identity (old_since:11) is long expired, with MALPROMO already at 0 so
# this poll's malformed row lands within the bound (count becomes 1).
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
codex2_now="$(date -u +%s)"
codex2_old_since=$((codex2_now - 2000))
codex2_old_until=$((codex2_old_since + 900))
codex2_new_valid_at=$((codex2_now - 50))
codex2_new_malformed_at=$((codex2_now - 40))
codex2_valid_iso="$(date -u -d "@$codex2_new_valid_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$codex2_valid_iso" ] || codex2_valid_iso="$(date -u -r "$codex2_new_valid_at" +%Y-%m-%dT%H:%M:%SZ)"
codex2_malformed_iso="$(date -u -d "@$codex2_new_malformed_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$codex2_malformed_iso" ] || codex2_malformed_iso="$(date -u -r "$codex2_new_malformed_at" +%Y-%m-%dT%H:%M:%SZ)"
touch "$fixture_dir/malformed-promo-events"
printf '%s\n' "$codex2_valid_iso" >"$fixture_dir/malformed-promo-valid-at"
printf '%s\n' "$codex2_malformed_iso" >"$fixture_dir/malformed-promo-null-at"
codex2_state="$test_tmp/codex2-stale-window.state"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s:11\nWALLCLOCK\trun\t0\t\n' \
    "$codex2_old_until" "$codex2_old_since" >"$codex2_state"
codex2_out="$test_tmp/codex2-stale-window.out"
bash "$watcher" --iterations 1 --state-file "$codex2_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --post-promotion-seconds 900 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$codex2_out"
rm "$fixture_dir/malformed-promo-events" "$fixture_dir/malformed-promo-valid-at" \
    "$fixture_dir/malformed-promo-null-at"
assert_count "$codex2_out" 0 '^POST-PROMOTION-CLOSED '
assert_count "$codex2_out" 0 '^POST-PROMOTION-ACTIVITY '
assert_count "$codex2_out" 0 '^POST-PROMOTION-INDETERMINATE '
assert_count "$codex2_state" 1 \
    "^WINDOW[[:space:]]+alpha[[:space:]]+77[[:space:]]+${codex2_old_until}[[:space:]]+${codex2_old_since}:11\$"

# #1041 challenge r1 finding codex-3: a still-genuinely-failing ACTIVITY
# endpoint's own DEGRADE episode must survive a poll where PR discovery
# (a DIFFERENT endpoint) succeeds -- proving the per-endpoint key actually
# isolates them, not just that dedup happens to hold by coincidence. Seeds
# an already-armed, unexpired WINDOW (so PR discovery succeeds cleanly and
# poll_activity is reached) alongside an in-progress, already-notified
# "alpha:ACTIVITY" episode; fail-api then fails this poll's activity fetch
# again.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 2 >"$fixture_dir/pr-count"
codex3_now="$(date -u +%s)"
codex3_state="$test_tmp/codex3-endpoint-episode.state"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nWINDOW\talpha\t77\t%s\t%s:401\nDEGRADE\talpha:ACTIVITY\t%s\t1\t0:%s\nWALLCLOCK\trun\t0\t\n' \
    "$((codex3_now + 900))" "$codex3_now" "$((codex3_now - 5))" "$((codex3_now - 1))" >"$codex3_state"
touch "$fixture_dir/fail-api"
codex3_out="$test_tmp/codex3-endpoint-episode.out"
bash "$watcher" --iterations 1 --state-file "$codex3_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --post-promotion-seconds 900 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$codex3_out"
rm "$fixture_dir/fail-api"
assert_count "$codex3_out" 0 '^OBSERVATION-DEGRADED '
assert_count "$codex3_state" 0 '^DEGRADE[[:space:]]+alpha:PR[[:space:]]+'
assert_count "$codex3_state" 1 \
    "^DEGRADE[[:space:]]+alpha:ACTIVITY[[:space:]]+$((codex3_now - 5))[[:space:]]+1[[:space:]]+1:[0-9]+\$"

# Every emitted line belongs to one of the stable event grammars.
if grep -Ev '^(AGENT [^:]+: [^ ]+ -> [^ ]+|SENTINEL [^:]+: LANE-[A-Z0-9-]+-(READY|BLOCKED)-[^ ]+( \(pane only\))?|PR [^:]+: #[0-9]+ draft=(true|false) (OPEN|CLOSED|MERGED) head=[0-9a-f]{8}|POST-PROMOTION-ACTIVITY [^:]+: [^ ]+ (review|comment|inline) [0-9]+ since=[0-9]+:[0-9]*|POST-PROMOTION-CLOSED [^:]+: #[0-9]+ since=[0-9]+:[0-9]*|POST-PROMOTION-INDETERMINATE [^:]+: #[0-9]+|OBSERVATION-DEGRADED [^:]+: .+|USAGE-PAUSED [^ ]+|WALLCLOCK (run|[^:]+): .+)$' \
    "$primary_out" "$skipped_ready_out" "$legacy_draft_out" "$restart_out" "$usage_recovery_out" "$hang_out" "$expired_out" \
    "$tail_out" "$closed_quiet_out" "$closing_out" "$persistfail_out" "$cold_resolve_out" "$stillopen_out" "$realexpired_out" \
    "$samehead_rearm_out" "$cold_never_out" "$rearm_restart_out" "$created_edit_out" \
    "$dormant_out1" "$dormant_out2" "$dormant_out3" \
    "$samesecond_out1" "$samesecond_out2" \
    "$rebind_out1" "$rebind_out2" "$mp_out" "$mp_allbad_out" "$mp_order_out" \
    "$codex2_out" "$codex3_out" \
    "$bounded_out1" "$bounded_out2" "$bounded_out3" \
    "$ordering_out1" "$ordering_out2" \
    "$transient_out" "$restart_dedup_out" "$midepisode_out" "$multilane_out" \
    "$degrade_empty_extra_out" "$malpromo_empty_extra_out" \
    "$github_failure_out" "$activity_failure_out" "$malformed_activity_out" \
    "$malformed_out" "$flattened_out" "$linked_out" "$wallclock_out" "$deadline_out"; then
    fail 'watcher emitted a line outside the documented event grammar'
fi

echo 'lane-watch tests passed'
