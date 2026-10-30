#!/usr/bin/env bash
# Watch orchestrated lanes and emit stable, one-line transition events:
#   LANE-STATUS <lane>: seq=<n> state=<state> head=<sha8> request=<id|-> <summary>
#   AGENT <lane>: <from> -> <to>
#   PROMPT <lane>: <approval request>[ (fallback)]
#   STALL <lane>: no pane change for <N>m
#   HEARTBEAT <lane>: state=<state> age=<seconds>s pr=<state>; ...
#   SENTINEL <lane>: <value>[ (pane only)]
#   DRAFT-PUBLISHED <lane>: <value>[ (pane only)]
#   BRANCH <lane>: <branch> head=<sha8> | absent (cloud lanes)
#   PR <lane>: #<n> draft=<bool> <STATE> head=<sha8>
#   PR-ACTIVITY <lane>: #<n> <actor> <review|comment|inline> <id> updated=<epoch> revision=<checksum>
#   PR-THREAD <lane>: #<n> <thread-id> <opened|reopened> generation=<n>
#   PR-CI <lane>: #<n> head=<sha8> required=<canonical-json>
#   PR-BEHIND <lane>: #<n> base=<sha> behind_by=<n>
#   PR-WATCHING <lane>: #<n> head=<sha8> draft=<bool>
#   PR-UNREADABLE <lane>: #<n> reason=<reason>
#   RATE-LIMITED github: until=<epoch>
#   WATCH-COMPLETE run: no active specs
#   PR-MERGED <lane>: #<n> head=<sha8>
#   PR-CLOSED <lane>: #<n> head=<sha8>
#   OBSERVATION-DEGRADED <lane>: <detail> (herdr names the shared list read)
#   USAGE-PAUSED <lane>
#   WALLCLOCK <lane|run>: <text>
#
# Append :cloud to a lane:branch:nonce:owner/repo spec for GitHub-only lane
# observation. A label:pr-number:nonce:owner/repo:pr spec watches a PR directly,
# including parked drafts, with no lane, branch lookup or run deadline.
# PR observations are keyed by repository/number in --state-file, so retiring
# a lane into a PR-only spec preserves deduplication across watcher restarts.
# PR-WATCHING attests a complete observation, never readiness or permission
# to merge. PR monitoring has no quiet-period completion: it ends at merge or
# close, or six consecutive definitive identity/access failures. PR-only specs
# poll at --pr-interval-seconds (default 300); timed lanes retain --interval-seconds. Rate limits pause GitHub reads until reset,
# while local supervision continues. Activity edits carry timestamp and content
# revision markers (reviews have no API updated_at, so revision detects edits).
# behind_by is sampled at most once per 300 seconds, including restarts.
# Reads are bounded; transient failures use independent persisted endpoint
# episodes (timed lanes: 5s/15s/45s backoff, then process-local retirement at
# --degrade-window-seconds; PR-only specs keep polling temporary failures).
# Re-arms retry timed specs; an exhausted lone timed spec still exits 1.
# An exhausted shared Herdr list episode retires local specs for this process;
# cloud and PR-only specs remain active. Failed Herdr reads are indeterminate.
# This watcher never writes through gh or herdr.
set -u

usage() {
    cat <<'EOF'
Usage: lane-watch.sh [options] DEADLINE_ISO lane:branch:nonce:owner/repo ...

Options:
  Local spec: agent:branch:nonce:owner/repo[:/absolute/report-path[:lane-label]]
  agent is the lowercase herdr name; lane-label defaults to agent.
  Report defaults to <checkout>/.worktrees/<agent>/.lane-report.md.
  Sentinels are (MERGE-READY|DRAFT-PUBLISHED|BLOCKED)-<lane-label>-<nonce>, whole final lines.
  Lane specs may end in :cloud (GitHub-only; no local worktree/report).
  PR-only spec: label:pr-number:nonce:owner/repo:pr (ignores DEADLINE_ISO).
  PR-only identity/access failure window: six consecutive failed polls.

  --brief PATH                    Validated rendered lane brief (repeatable)
  --status-file LABEL=PATH        Explicit status path for a lane label (repeatable)
  --state-file PATH               Persist emitted state across restarts
  --registry PATH                 Agent registry (default: repo agent-registry.json)
  --workspace-root PATH           Parent containing repo checkouts (default: repo parent)
  --interval-seconds N            Poll interval (default: 15)
  --pr-interval-seconds N         PR-only observation interval (default: 300; 0 every poll)
  --timeout-seconds N             Per herdr/gh call timeout (default: 30)
  --degrade-window-seconds N      Timed-lane retry window before process-local retirement (default: 600)
  --prompt-reemit-seconds N       Repeat a still-visible prompt (default: 180)
  --stall-minutes N               Unchanged local pane threshold (default: 10)
  --heartbeat-minutes N           All-lane summary interval (default: 15)
  A value of 0 for the three options above means "every poll", not "disabled".
  --iterations N                  Stop after N polls (default: unlimited)
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
    flattened_root="$(cd "$script_dir/../../../.." 2>/dev/null && pwd || true)"
    source_root="$(cd "$script_dir/../../../../.." 2>/dev/null && pwd || true)"
    if [ -f "$flattened_root/agent-registry.json" ]; then
        repo_root=$flattened_root
    else
        repo_root=$source_root
    fi
fi
state_file=
brief_files=()
status_files=()
registry="$repo_root/agent-registry.json"
workspace_root_explicit=0
git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$git_common_dir" ] && [ "$(basename "$git_common_dir")" = .git ]; then
    checkout_root="$(dirname "$git_common_dir")"
    workspace_root="$(dirname "$checkout_root")"
else
    checkout_root=$repo_root
    workspace_root="$(dirname "$repo_root")"
fi
interval_seconds=15
pr_interval_seconds=300
timeout_seconds=30
degrade_window_seconds=600
iterations=0
prompt_reemit_seconds=180
stall_minutes=10
heartbeat_minutes=15
while [ "$#" -gt 0 ]; do
    case "$1" in
    --brief | --status-file | --state-file | --registry | --workspace-root | --interval-seconds | --pr-interval-seconds | --timeout-seconds | --degrade-window-seconds | --prompt-reemit-seconds | --stall-minutes | --heartbeat-minutes | --iterations)
        [ "$#" -ge 2 ] || {
            usage >&2
            exit 2
        }
        case "$1" in
        --brief) brief_files+=("$2") ;;
        --status-file) status_files+=("$2") ;;
        --state-file) state_file=$2 ;;
        --registry) registry=$2 ;;
        --workspace-root)
            workspace_root=$2
            workspace_root_explicit=1
            ;;
        --interval-seconds) interval_seconds=$2 ;;
        --pr-interval-seconds) pr_interval_seconds=$2 ;;
        --timeout-seconds) timeout_seconds=$2 ;;
        --degrade-window-seconds) degrade_window_seconds=$2 ;;
        --prompt-reemit-seconds) prompt_reemit_seconds=$2 ;;
        --stall-minutes) stall_minutes=$2 ;;
        --heartbeat-minutes) heartbeat_minutes=$2 ;;
        --iterations) iterations=$2 ;;
        esac
        shift 2
        ;;
    --help)
        usage
        exit 0
        ;;
    --)
        shift
        break
        ;;
    -*)
        echo "lane-watch: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    *) break ;;
    esac
done

[ "$#" -ge 2 ] || {
    usage >&2
    exit 2
}
deadline_iso=$1
shift
specs=("$@")

if [ -n "$state_file" ] && [ "$(basename "$state_file")" = monitor.json ]; then
    echo "lane-watch: refusing canonical run monitor as watcher state: $state_file" >&2
    exit 2
fi

case "$pr_interval_seconds:$interval_seconds:$timeout_seconds:$degrade_window_seconds:$iterations:$prompt_reemit_seconds:$stall_minutes:$heartbeat_minutes" in
*[!0-9:]* | *::* | :* | *:)
    echo "lane-watch: intervals, windows, thresholds, and iterations must be non-negative integers" >&2
    exit 2
    ;;
esac

# Numeric validation above permits leading zeroes; these thresholds are decimal.
pr_interval_seconds=$((10#$pr_interval_seconds))
prompt_reemit_seconds=$((10#$prompt_reemit_seconds))
stall_minutes=$((10#$stall_minutes))
heartbeat_minutes=$((10#$heartbeat_minutes))

timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$timeout_bin" ] || {
    echo "lane-watch: GNU timeout (timeout or gtimeout) is required" >&2
    exit 2
}

deadline="$(date -u -d "$deadline_iso" +%s 2>/dev/null || true)"
if [ -z "$deadline" ]; then
    deadline="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$deadline_iso" +%s 2>/dev/null || true)"
fi
[ -n "$deadline" ] || {
    echo "lane-watch: invalid UTC deadline: $deadline_iso" >&2
    exit 2
}

state_kinds=()
state_keys=()
state_values=()
state_extras=()
state_details=()
state_count=0
warned=0

state_get() {
    wanted_kind=$1
    wanted_key=$2
    wanted_field=${3:-value}
    index=0
    while [ "$index" -lt "$state_count" ]; do
        if [ "${state_kinds[$index]}" = "$wanted_kind" ] && [ "${state_keys[$index]}" = "$wanted_key" ]; then
            case "$wanted_field" in
            value) printf '%s' "${state_values[$index]}" ;;
            extra) printf '%s' "${state_extras[$index]}" ;;
            detail) printf '%s' "${state_details[$index]}" ;;
            esac
            return 0
        fi
        index=$((index + 1))
    done
    return 1
}

state_set() {
    wanted_kind=$1
    wanted_key=$2
    wanted_value=$3
    wanted_extra=${4:-}
    wanted_detail=${5:-}
    index=0
    while [ "$index" -lt "$state_count" ]; do
        if [ "${state_kinds[$index]}" = "$wanted_kind" ] && [ "${state_keys[$index]}" = "$wanted_key" ]; then
            state_values[$index]=$wanted_value
            state_extras[$index]=$wanted_extra
            state_details[$index]=$wanted_detail
            return 0
        fi
        index=$((index + 1))
    done
    state_kinds[$state_count]=$wanted_kind
    state_keys[$state_count]=$wanted_key
    state_values[$state_count]=$wanted_value
    state_extras[$state_count]=$wanted_extra
    state_details[$state_count]=$wanted_detail
    state_count=$((state_count + 1))
}

state_delete() {
    wanted_kind=$1
    wanted_key=$2
    index=0
    while [ "$index" -lt "$state_count" ]; do
        if [ "${state_kinds[$index]}" = "$wanted_kind" ] && [ "${state_keys[$index]}" = "$wanted_key" ]; then
            last=$((state_count - 1))
            while [ "$index" -lt "$last" ]; do
                next=$((index + 1))
                state_kinds[$index]=${state_kinds[$next]}
                state_keys[$index]=${state_keys[$next]}
                state_values[$index]=${state_values[$next]}
                state_extras[$index]=${state_extras[$next]}
                state_details[$index]=${state_details[$next]}
                index=$next
            done
            unset 'state_kinds[last]' 'state_keys[last]' 'state_values[last]' \
                'state_extras[last]' 'state_details[last]'
            state_count=$last
            return 0
        fi
        index=$((index + 1))
    done
}

load_state() {
    [ -n "$state_file" ] && [ -f "$state_file" ] || return 0
    while IFS=$'\t' read -r kind lane value extra detail; do
        case "$kind" in
        AGENT | BRANCH | PR | USAGE | METADATA | PRSEEN | THREAD | CI | BEHIND | BEHIND-POLL | WATCHING | TERMINAL | PR-POLL | RATE) state_set "$kind" "$lane" "$value" ;;
        # Legacy entries recorded no source and cannot attest confirmation.
        SENTINEL) state_set SENTINEL-PANE "$lane:$value" 1 ;;
        SENTINEL-PANE | SENTINEL-REPORT) state_set "$kind" "$lane:$value" 1 ;;
        PROGRESS)
            [[ "$extra" =~ ^[0-9]+$ && "$detail" =~ ^[0-9]+$ ]] || continue
            state_set "$kind" "$lane" "$value" "$((10#$extra))" "$((10#$detail))"
            ;;
        PROMPT)
            [[ "$value" =~ ^[0-9]+$ && "$extra" =~ ^[0-9]+$ ]] || continue
            state_set "$kind" "$lane" "$((10#$value))" "$((10#$extra))" "$detail"
            ;;
        HEARTBEAT)
            [[ "$value" =~ ^[0-9]+$ ]] || continue
            state_set "$kind" "$lane" "$((10#$value))" "$extra" "$detail"
            ;;
        LANE-STATUS)
            [[ "$value" =~ ^[1-9][0-9]*$ && "$extra" =~ ^[0-9]+:[0-9]+$ ]] || continue
            state_set "$kind" "$lane" "$value" "$extra"
            ;;
        DEGRADE) state_set DEGRADE "$lane" "$value" "$extra" "$detail" ;;
        WALLCLOCK) [ "$extra" != "$deadline" ] || warned=$value ;;
        esac
    done <"$state_file"
}

save_state() {
    local state_dir state_tmp index kind key value extra detail
    [ -n "$state_file" ] || return 0
    state_dir="$(dirname "$state_file")"
    [ -d "$state_dir" ] || mkdir -p "$state_dir" || return 1
    state_tmp="${state_file}.tmp.$$"
    {
        index=0
        while [ "$index" -lt "$state_count" ]; do
            kind=${state_kinds[$index]}
            key=${state_keys[$index]}
            value=${state_values[$index]}
            extra=${state_extras[$index]}
            detail=${state_details[$index]}
            case "$kind" in
            AGENT | BRANCH | PR | USAGE | METADATA | PRSEEN | THREAD | CI | BEHIND | BEHIND-POLL | WATCHING | TERMINAL | PR-POLL | RATE)
                printf '%s\t%s\t%s\t\n' "$kind" "$key" "$value"
                ;;
            SENTINEL-PANE | SENTINEL-REPORT)
                printf '%s\t%s\t%s\t\n' "$kind" "${key%%:*}" "${key#*:}"
                ;;
            PROGRESS | PROMPT | HEARTBEAT | LANE-STATUS) printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$key" "$value" "$extra" "$detail" ;;
            DEGRADE) printf 'DEGRADE\t%s\t%s\t%s\t%s\n' "$key" "$value" "$extra" "$detail" ;;
            esac
            index=$((index + 1))
        done
        printf 'WALLCLOCK\trun\t%s\t%s\n' "$warned" "$deadline"
    } >"$state_tmp" || return 1
    mv "$state_tmp" "$state_file" 2>/dev/null || return 1
}

persist_state() {
    save_state || {
        echo "lane-watch: could not persist state to $state_file" >&2
        exit 1
    }
}

observation_failed() {
    local label=$1
    if [ "${deadline_applies:-1}" -eq 1 ] && [ "$(date -u +%s)" -ge "$deadline" ]; then
        persist_state
        if [ "$warned" -ne 2 ]; then
            echo "WALLCLOCK run: deadline $deadline_iso reached"
            warned=2
            persist_state
        fi
        return 0
    fi
    if [ "$extra" = pr ]; then
        echo "PR-UNREADABLE $lane: #$branch reason=$label"
        state_set TERMINAL "$repo#$branch" UNREADABLE
        state_delete WATCHING "$repo#$branch"
        persist_state
        return 0
    fi
    echo "lane-watch: $label" >&2
    # Remove it only from this process; a re-arm rebuilds specs from argv.
    unset 'specs[spec_index]'
    exit_status=1
}

# A lane's DEGRADE entry (value=first_failure_at, extra=notified 0/1,
# detail="<attempt>:<next_retry_at>") marks an in-progress retry episode.
# PR-only attempts are tagged identity=<count>, counting definitive answers only.
# Keyed by "$lane:PR", "$lane:BRANCH", or
# "$repo#<n>:activity|threads|ci|behind", not
# just $lane: #1041 challenge r1 finding codex-3 found that a single
# shared-per-lane episode let PR discovery's recovery on a restart silently
# reset a still-genuinely-failing PR observation or branch episode,
# repeatedly resetting the advertised degrade-window bound across restarts.
# Each endpoint now tracks -- and clears -- its own episode independently.
# Herdr uses per-lane endpoint keys and the shared run:HERDR-LIST key.
observation_recover() {
    local key=$1
    if state_get DEGRADE "$key" >/dev/null; then
        state_delete DEGRADE "$key"
        persist_state
    fi
}

# Herdr episodes are cleared only by positive evidence: a successful endpoint
# read, or evidence that proves the endpoint does not apply on this poll. When
# eligibility is unknown or a read was skipped, preserve the episode so an
# intervening outage cannot restart its degrade window.
herdr_episode_recover() {
    local key=$1 evidence=$2
    case "$key" in
    run:HERDR-LIST | *:HERDR-VISIBLE | *:HERDR-EXPLAIN | *:HERDR-RECENT) ;;
    *)
        echo "lane-watch: invalid Herdr episode key: $key" >&2
        return 2
        ;;
    esac
    case "$evidence" in
    read-succeeded) ;;
    lane-absent)
        case "$key" in
        *:HERDR-VISIBLE | *:HERDR-EXPLAIN | *:HERDR-RECENT) ;;
        *)
            echo "lane-watch: invalid absent-lane Herdr episode key: $key" >&2
            return 2
            ;;
        esac
        ;;
    explained-working | report-sentinel)
        case "$key" in
        *:HERDR-RECENT) ;;
        *)
            echo "lane-watch: invalid inapplicable Herdr episode key: $key" >&2
            return 2
            ;;
        esac
        ;;
    cloud-spec)
        case "$key" in
        *:HERDR-VISIBLE | *:HERDR-EXPLAIN | *:HERDR-RECENT) ;;
        *)
            echo "lane-watch: invalid cloud Herdr episode key: $key" >&2
            return 2
            ;;
        esac
        ;;
    no-local-lanes)
        [ "$key" = run:HERDR-LIST ] || {
            echo "lane-watch: invalid no-local-lanes Herdr episode key: $key" >&2
            return 2
        }
        ;;
    unknown | not-attempted) return 0 ;;
    *)
        echo "lane-watch: invalid Herdr recovery evidence: $evidence" >&2
        return 2
        ;;
    esac
    observation_recover "$key"
}

# #1041 challenge r1 finding 1: an earlier version of this mechanism slept
# in place inside the per-lane loop below, retrying the SAME lane
# immediately -- which blocked the single-threaded main loop from ever
# reaching a LATER, healthy lane in specs[] for the sleeping lane's entire
# backoff/episode window (empirically reproduced: a healthy lane's first
# observation delayed ~20s by an unrelated lane's transient failure; in the
# persistent case, a healthy lane never observed at all before the process
# exited at the window boundary). This function never sleeps. It only
# decides, from persisted state alone, whether $lane's observation should be
# attempted THIS poll at all.
#
# Returns 0 (attempt it) when there is no in-progress episode for this
# endpoint, or its persisted next_retry_at has arrived; returns 1 (skip just
# this endpoint this poll, no sleep) while still backing off. A later
# endpoint for the same lane (or a later lane in specs[]) is unaffected --
# each is gated independently. The next poll's own "$now" -- paced only by
# the ordinary --interval-seconds sleep the main loop already does between
# polls -- is what advances the retry schedule; this function adds no wait
# of its own.
observation_ready() {
    local key=$1 detail_raw next_retry_at
    case "$key" in run:HERDR-LIST | *:HERDR-*) ;; *) github_paused && return 1 ;; esac
    detail_raw="$(state_get DEGRADE "$key" detail || true)"
    # Gemini review (PR #1102): a pure parameter expansion avoids the
    # here-string's extra process substitution on every poll of every
    # lane, and is simpler than an IFS-scoped read for extracting just the
    # trailing field.
    next_retry_at="${detail_raw#*:}"
    case "$next_retry_at" in *[!0-9]*) next_retry_at= ;; esac
    [ -z "$next_retry_at" ] || [ "$now" -ge "$next_retry_at" ]
}

# Called after a failed observation, once observation_ready() has already
# authorized this poll's attempt for this endpoint. Emits OBSERVATION-DEGRADED
# exactly once per episode (deduplicated via the persisted `notified` flag,
# so a restart mid-episode does not repeat it), then either schedules the
# next bounded backoff (5s/15s/45s, capped by both the run deadline and this
# episode's own degrade_window_seconds window) and returns 0 -- the caller
# abandons the rest of this lane's work for this poll and moves on, nothing
# sleeps -- or returns 1 once the episode has run for degrade_window_seconds,
# at which point the caller falls through to the existing
# observation_failed(): timed lanes retire for this process; PR-only specs
# instead count six consecutive definitive identity/access failures, leaving
# temporary outages active at their quiescent cadence.
#
# Refreshes the shared `now` itself, first thing: the caller's own `now` was
# captured before invoking the (possibly slow, or -- via bounded()'s own
# timeout -- multi-second) call that just failed, so deciding the deadline
# and episode window against that stale value could miss a deadline that was
# crossed DURING the call. A hard-hang test that expects the run deadline
# (set only 1s out) to be recognized once its bounded discover_pr() timeout
# expires is what caught this.
#
# Checks the run deadline BEFORE touching any DEGRADE state or announcing
# anything (#1041 challenge r2 finding claude-4): a read failing only
# because the RUN CLOCK ran out, not a real degradation, must not be
# reported as one -- the caller's own observation_failed() already handles
# retirement of the timed spec, and announcing/persisting first left a
# spurious OBSERVATION-DEGRADED at the very moment of a normal run-end, plus
# a stray episode that could suppress a real future one's announcement
# after a restart (notified=1 with no failure having actually been
# reported to a human).
observation_record_failure() {
    local key=$1 lane=$2 detail=$3 status=${4:-1}
    now="$(date -u +%s)"
    if [[ "$key" != run:HERDR-LIST && "$key" != *:HERDR-* ]] && github_paused; then
        rate_until="$(cat "$read_dir/rate-until")"
        if [ "$(state_get RATE github || true)" != "$rate_until" ]; then
            echo "RATE-LIMITED github: until=$rate_until"
            state_set RATE github "$rate_until"
            persist_state
        fi
        return 0
    fi
    [ "${deadline_applies:-1}" -eq 0 ] || [ "$now" -lt "$deadline" ] || return 1
    local first_failure notified detail_raw attempt delay cap
    first_failure="$(state_get DEGRADE "$key" || true)"
    # Gemini 4055704932 / 4055704941 (PR #1102, #1041 remediation round 5):
    # a numeric field read back from a corrupted or hand-edited state file
    # can carry non-digit garbage, which the arithmetic and `-eq` tests
    # below would reject with a hard error rather than the "absent" case
    # the existing empty-string guards already handle safely. A corrupted
    # (non-empty, non-numeric) first_failure is folded into the SAME
    # empty-string branch just below, not reset to 0 -- unlike the other
    # numeric fields in this function, 0 is not first_failure's safe
    # default: it is a real epoch, and forcing every corrupted read to it
    # would make the episode look decades old and exceed the give-up window.
    # Treating corruption as "no prior episode" instead restarts a fresh
    # backoff cleanly, exactly as an absent entry already does.
    case "$first_failure" in *[!0-9]*) first_failure= ;; esac
    # Gemini review (PR #1102): state_get can succeed with an empty string
    # (an existing entry whose field itself is stored empty), which `||`
    # never catches since that only fires on FAILURE -- an unguarded empty
    # string then fails the `-eq` integer test below. Default explicitly.
    notified="$(state_get DEGRADE "$key" extra || true)"
    case "$notified" in '' | *[!0-9]*) notified=0 ;; esac
    detail_raw="$(state_get DEGRADE "$key" detail || true)"
    # Gemini review: a pure parameter expansion avoids the here-string's
    # extra process substitution for extracting just the leading field.
    attempt="${detail_raw%%:*}"
    if [ -z "$first_failure" ]; then
        first_failure=$now
        notified=0
        attempt=0
    fi
    if [ "$extra" = pr ]; then
        # Older numeric retry counts do not attest identity failures.
        case "$attempt" in identity=*) attempt=${attempt#identity=} ;; *) attempt=0 ;; esac
    fi
    case "$attempt" in '' | *[!0-9]*) attempt=0 ;; esac
    if [ "${notified:-0}" -eq 0 ]; then
        echo "OBSERVATION-DEGRADED $lane: $detail"
        notified=1
    fi
    if [ "$extra" = pr ]; then
        # Only definitive identity/access answers (bounded status 77) count
        # toward retirement. Temporary failures reset the consecutive count.
        if [ "$status" -eq 77 ]; then attempt=$((attempt + 1)); else attempt=0; fi
        state_set DEGRADE "$key" "$first_failure" "$notified" "identity=$attempt:$now"
        persist_state
        [ "$attempt" -lt 6 ]
        return $?
    fi
    if [ $((now - first_failure)) -ge "$degrade_window_seconds" ]; then
        state_set DEGRADE "$key" "$first_failure" "$notified" "$attempt:$now"
        persist_state
        return 1
    fi
    case "$attempt" in
    0) delay=5 ;;
    1) delay=15 ;;
    *) delay=45 ;;
    esac
    if [ "${deadline_applies:-1}" -eq 1 ]; then
        cap=$((deadline - now))
        [ "$delay" -le "$cap" ] || delay=$cap
    fi
    cap=$((first_failure + degrade_window_seconds - now))
    [ "$delay" -le "$cap" ] || delay=$cap
    [ "$delay" -ge 0 ] || delay=0
    attempt=$((attempt + 1))
    state_set DEGRADE "$key" "$first_failure" "$notified" "$attempt:$((now + delay))"
    persist_state
    return 0
}

# Read scratch is private to this process, shared by command substitutions.
# No debug response (including gh's redacted request trace) reaches the stream.
read_dir="$(mktemp -d "${TMPDIR:-/tmp}/lane-watch-read.XXXXXX")" || exit 1
trap 'rm -rf "$read_dir"' EXIT

github_paused() {
    local until
    [ -f "$read_dir/rate-until" ] || return 1
    until="$(cat "$read_dir/rate-until")"
    [ "$(date -u +%s)" -lt "$until" ]
}

bounded() {
    local seconds=$1 remaining rc=0 reset retry current headers primary=0 secondary=0
    shift
    if [ "${deadline_applies:-1}" -eq 1 ]; then
        remaining=$((deadline - $(date -u +%s)))
        [ "$remaining" -gt 0 ] || return 124
        [ "$seconds" -le "$remaining" ] || seconds=$remaining
    fi
    if [ "$1" != gh ]; then
        "$timeout_bin" --kill-after=2 "$seconds" "$@" </dev/null 2>/dev/null
        return $?
    fi
    github_paused && return 75
    # gh debug includes response headers even for pr list/view. Capture them
    # privately so CLI and API reads share the same rate-limit contract.
    GH_DEBUG=api "$timeout_bin" --kill-after=2 "$seconds" "$@" </dev/null \
        >"$read_dir/body" 2>"$read_dir/headers" || rc=$?
    headers="$(sed -n 's/^< //p' "$read_dir/headers" | tr '[:upper:]' '[:lower:]')"
    if grep -Eq '^x-ratelimit-remaining: *0([^0-9]|$)' <<<"$headers" ||
        grep -Eiq '^(gh|HTTP [0-9]+|GraphQL): API rate limit exceeded' "$read_dir/headers"; then
        primary=1
    elif grep -Eq '^(http/[0-9.]+ 429|retry-after:)' <<<"$headers" ||
        grep -Eiq '^(gh|HTTP [0-9]+|GraphQL): .*secondary rate limit' "$read_dir/headers" ||
        jq -e 'if type == "array" then . else [.] end
          | any(.[]; type == "object" and any(.errors[]?; .type == "RATE_LIMITED"))' \
            "$read_dir/body" >/dev/null 2>&1; then
        secondary=1
    fi
    if [ "$primary" -eq 1 ] || [ "$secondary" -eq 1 ]; then
        current="$(date -u +%s)"
        if [ "$primary" -eq 1 ]; then
            reset="$(sed -nE 's/^x-ratelimit-reset: *([0-9]+).*$/\1/p' <<<"$headers" | sort -n | tail -1)"
            reset=${reset:-$((current + 3600))}
        else
            retry="$(sed -nE 's/^retry-after: *([0-9]+).*$/\1/p' <<<"$headers" | sort -n | tail -1)"
            reset=$((current + ${retry:-60}))
        fi
        [ "$reset" -gt "$current" ] || reset=$((current + 60))
        printf '%s\n' "$reset" >"$read_dir/rate-until"
        return 75
    fi
    cat "$read_dir/body"
    # Preserve a definitive identity/access answer separately from outages.
    # Timeout/transport statuses never become a terminal PR observation.
    if [ "$rc" -eq 1 ] && {
        grep -Eq '^http/[0-9.]+ 404' <<<"$headers" ||
            grep -Eq '^(HTTP 404:|GraphQL: Could not resolve to a (PullRequest|Repository)|gh: .* \(HTTP 404\))' "$read_dir/headers" ||
            jq -e 'if type == "array" then . else [.] end
              | any(.[]; type == "object" and any(.errors[]?; .type == "NOT_FOUND"))' \
                "$read_dir/body" >/dev/null 2>&1
    }; then
        return 77
    fi
    return "$rc"
}

if ! jq -e '
  (.finders | type) == "array"
  and all(.finders[];
    type == "object"
    and has("trusted_actor_id")
    and (.trusted_actor_id == null
      or ((.trusted_actor_id | type) == "string"
        and (.trusted_actor_id | test("^[0-9]+$")))))
' "$registry" >/dev/null 2>&1; then
    echo "lane-watch: invalid agent registry: $registry" >&2
    exit 2
fi

trusted_actor_ids="$(jq -c '[.finders[].trusted_actor_id | select(. != null)]' "$registry")"

# Keep spec decoding identical at validation and observation time. Colon is
# the field separator and cannot occur in a report path or lane label.
parse_spec() {
    IFS=: read -r lane branch nonce repo report_path lane_label remainder <<<"$1"
    extra=
    deadline_applies=1
    if [ "$report_path" = cloud ] || [ "$report_path" = pr ]; then
        extra=$report_path
        if [ "$extra" = pr ]; then
            [[ "$branch" =~ ^[1-9][0-9]*$ ]] || return 1
            deadline_applies=0
        fi
        report_path=
        [ -z "$lane_label" ] && [ -z "$remainder" ] || return 1
    fi
    [ -z "$remainder" ] || return 1
    lane_label=${lane_label:-$lane}
}

for spec in "${specs[@]}"; do
    if ! parse_spec "$spec" || [ -z "$lane" ] || [ -z "$branch" ] ||
        [ -z "$nonce" ] || [ -z "$repo" ]; then
        echo "lane-watch: invalid lane spec: $spec" >&2
        exit 2
    fi
    case "$nonce" in
    *[!A-Za-z0-9_-]*)
        echo "lane-watch: invalid sentinel nonce in spec: $spec" >&2
        exit 2
        ;;
    esac
    case "$lane_label" in
    *[!A-Za-z0-9_-]*)
        echo "lane-watch: invalid sentinel lane label in spec: $spec" >&2
        exit 2
        ;;
    esac
    case "$report_path" in
    '' | /*) ;;
    *)
        echo "lane-watch: report path must be absolute in spec: $spec" >&2
        exit 2
        ;;
    esac
    case "$repo" in
    */*) ;;
    *)
        echo "lane-watch: invalid repository in spec: $spec" >&2
        exit 2
        ;;
    esac
done

# Brief facts are validated before any path is consumed. The status path is
# derived, preserving compatibility with briefs that predate lane status.
support_dir="$script_dir/../../dev-flow-support/assets"
status_validator="$support_dir/validate-result-schemas.mjs"
for brief_file in "${brief_files[@]}"; do
    node "$status_validator" brief "$brief_file" >/dev/null || exit 2
done
for status_entry in "${status_files[@]}"; do
    case "$status_entry" in
    *=/*) ;;
    *)
        echo "lane-watch: expected --status-file LABEL=/absolute/path" >&2
        exit 2
        ;;
    esac
done

observe_lane_status() {
    local status_path= brief_json brief_file status_entry snapshot current_head branch_root
    local status_seq status_state status_head request_id summary previous checksum previous_checksum
    # An explicit path wins; otherwise a matching brief supplies its record dir.
    for status_entry in "${status_files[@]}"; do
        if [ "${status_entry%%=*}" = "$lane_label" ]; then
            status_path=${status_entry#*=}
        fi
    done
    if [ -z "$status_path" ]; then
        for brief_file in "${brief_files[@]}"; do
            brief_json="$(sed -n '/^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/,/^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/p' "$brief_file" |
                sed '1d;$d' | sed '/^```/d')"
            status_path="$(jq -r --arg branch "$branch" --arg nonce "$nonce" \
                --arg handoff "DRAFT-PUBLISHED-$lane_label-$nonce" '
                select(.branch == $branch and .sentinels.attempt_nonce == $nonce and .sentinels.handoff == $handoff) |
                .record_directory + "/lane-status-" + $nonce + ".json"' <<<"$brief_json")"
            [ -z "$status_path" ] || break
        done
    fi
    if [ -z "$status_path" ] && [ -n "$report_path" ]; then
        status_path="$(dirname "$report_path")/lane-status-$nonce.json"
    fi
    [ -n "$status_path" ] && [ -f "$status_path" ] || return 1
    # Validate exactly the snapshot parsed below, even if the writer renames a
    # newer file while this poll is in progress.
    snapshot="$(cat "$status_path")" || return 1
    printf '%s' "$snapshot" | node "$status_validator" lane-status /dev/stdin >/dev/null 2>&1 || return 1
    branch_root=$checkout_root
    if [ "$workspace_root_explicit" -eq 1 ]; then
        branch_root="$workspace_root/${repo#*/}"
    fi
    current_head="$(git -C "$branch_root" rev-parse --verify "refs/heads/$branch^{commit}" 2>/dev/null)" || return 1
    status_head="$(jq -r .head <<<"$snapshot")"
    [ "$(printf '%s' "$status_head" | tr '[:upper:]' '[:lower:]')" = "$current_head" ] || return 1
    status_seq="$(jq -r .seq <<<"$snapshot")"
    status_state="$(jq -r .state <<<"$snapshot")"
    request_id="$(jq -r '.request_id // "-"' <<<"$snapshot")"
    summary="$(jq -r .summary <<<"$snapshot")"
    previous="$(state_get LANE-STATUS "$repo:$branch:$lane_label:$nonce" || true)"
    checksum="$(printf '%s' "$snapshot" | cksum | awk '{print $1 ":" $2}')"
    if [ -n "$previous" ]; then
        [ "$status_seq" -ge "$previous" ] || return 1
        previous_checksum="$(state_get LANE-STATUS "$repo:$branch:$lane_label:$nonce" extra || true)"
        [ "$status_seq" != "$previous" ] || [ "$checksum" = "$previous_checksum" ] || return 1
    fi
    [ "$(git -C "$branch_root" rev-parse --verify "refs/heads/$branch^{commit}" 2>/dev/null)" = "$current_head" ] || return 1
    if [ "$status_seq" != "$previous" ]; then
        state_set LANE-STATUS "$repo:$branch:$lane_label:$nonce" "$status_seq" "$checksum"
        persist_state
        echo "LANE-STATUS $lane: seq=$status_seq state=$status_state head=${status_head:0:8} request=$request_id $summary"
    fi
    case "$status_state" in
    decision-request | handoff | blocked) return 0 ;;
    *) return 1 ;;
    esac
}

# The same exact matcher consumes either source. Earlier report entries and
# pane history are not terminal evidence; only the final nonblank line counts.
terminal_sentinel() {
    local label=$1 nonce=$2
    awk 'NF { last = $0 } END { print last }' |
        grep -E "^(MERGE-READY|DRAFT-PUBLISHED|BLOCKED)-${label}-${nonce}$" 2>/dev/null
}

sentinel_from_report() {
    local report=$1 label=$2 nonce=$3
    [ -f "$report" ] || return 0
    terminal_sentinel "$label" "$nonce" <"$report"
}

# Herdr-classified lanes use blocked state, never pane layout, for existence.
# The pane is only a best-effort quote; a missing quote cannot hide a prompt.
approval_excerpt() {
    tail -n 20 | awk '
      /^[[:space:]│›>❯]*(Would you like to (run the following command|make the following edits|grant these permissions|send input to (the existing terminal|terminal .+))[?]|Do you want to (proceed|allow|approve network access|make this edit to|create|run)|.+ needs your approval[.])/ {line = $0}
      END {print (line != "" ? line : "(input requested; text not captured)")}
    ' | tr '\t\r' '  ' | cut -c 1-300
}

# agy/fallback lanes have no authoritative blocked classification. Retain
# their pane-text detection, restricted to agy approval strings near the bottom.
fallback_approval_request() {
    tail -n 8 | awk '
      /^[[:space:]│›>❯]*Requesting permission for:/ {
        quote = $0
        if (getline > 0) quote = quote " " $0
        next
      }
      /^[[:space:]│›>❯]*(Run this command[?]|Allow (access to this (file|URL)|calling this tool)[?])/ {
        if (quote == "") quote = $0
        live = 1
        next
      }
      live && $0 !~ /^[[:space:]]*$/ &&
        $0 !~ /^[[:space:]]*(❯|›|>)?[[:space:]]*([0-9]+[.)][[:space:]]*)?(Yes|No)([[:space:],]|$)/ {
        live = 0
        quote = ""
      }
      END {if (live) print quote}
    ' | tr '\t\r' '  ' | cut -c 1-300
}

observe_pane_progress() {
    local key=$1 pane=$2 metadata=$3 terminal=$4
    local fingerprint previous changed stalled
    fingerprint="$(printf '%s\n%s' "$pane" "$metadata" | cksum | awk '{print $1 ":" $2}')"
    previous="$(state_get PROGRESS "$key" || true)"
    changed="$(state_get PROGRESS "$key" extra || true)"
    stalled="$(state_get PROGRESS "$key" detail || true)"
    if [ "$previous" != "$fingerprint" ]; then
        changed=$now
        stalled=0
    fi
    # Terminal evidence suppresses stalls even if it appeared only in the
    # report; resuming work starts a fresh stall episode.
    if [ -n "$terminal" ]; then
        stalled=2
    elif [ "$stalled" = 2 ]; then
        changed=$now
        stalled=0
    elif [ "$stalled" != 1 ] && [ $((now - changed)) -ge $((stall_minutes * 60)) ]; then
        stalled=1
        echo "STALL $lane: no pane change for $(((now - changed) / 60))m"
        state_set PROGRESS "$key" "$fingerprint" "$changed" "$stalled"
        persist_state
    fi
    state_set PROGRESS "$key" "$fingerprint" "$changed" "$stalled"
}

observe_prompt() {
    local key=$1 prompt=$2 fallback=$3 first emitted suffix
    if [ -n "$prompt" ]; then
        first="$(state_get PROMPT "$key" || true)"
        emitted="$(state_get PROMPT "$key" extra || true)"
        if [ -z "$first" ] || [ $((now - emitted)) -ge "$prompt_reemit_seconds" ]; then
            first=${first:-$now}
            state_set PROMPT "$key" "$first" "$now"
            persist_state
            suffix=
            [ "$fallback" -eq 0 ] || suffix=' (fallback)'
            echo "PROMPT $lane: $prompt$suffix"
        fi
    else
        state_delete PROMPT "$key"
    fi
}

emit_heartbeat() {
    local last
    last="$(state_get HEARTBEAT run || true)"
    if [ -z "$last" ]; then
        # Start the clock on first observation, rather than emitting a startup
        # summary that duplicates the transition events already printed.
        state_set HEARTBEAT run "$now"
    elif [ $((now - last)) -ge $((heartbeat_minutes * 60)) ]; then
        state_set HEARTBEAT run "$now"
        persist_state
        echo "HEARTBEAT $heartbeat_summary"
    fi
}

activity_rows() {
    repo=$1
    pr_number=$2
    kind=$3
    endpoint=$4
    payload="$(bounded "$timeout_seconds" gh api --paginate --slurp "$endpoint")" || return $?
    [ -n "$payload" ] || return 1
    jq -e 'if (.[0]? | type) == "array" then all(.[]; type == "array") else type == "array" end' \
        >/dev/null 2>&1 <<<"$payload" || return 1
    # Keep human users and explicitly registered bots. Pending draft reviews
    # are not submitted activity. Reject malformed selected rows rather than
    # treating an unreadable snapshot as silence.
    jq -e --arg kind "$kind" --argjson trusted "$trusted_actor_ids" '
      (if (.[0]? | type) == "array" then add else . end)
      | map(select(.state != "PENDING")
          | select(.user.type == "User" or ((.user.id | tostring) as $id | $trusted | index($id))))
      | all(.[]; (.id | type) == "number" and .id > 0
          and (.user.login | type) == "string"
          and (.user.login | test("^[A-Za-z0-9_\\[\\]-]+$"))
          and (if $kind == "review" then
            (.submitted_at != null) or (.updated_at != null) or (.created_at != null)
          else .created_at != null end))
    ' >/dev/null 2>&1 <<<"$payload" || return 1
    jq -r --arg kind "$kind" --argjson trusted "$trusted_actor_ids" '
      (if (.[0]? | type) == "array" then add else . end)[]?
      | select(.state != "PENDING")
      | select(.user.type == "User" or ((.user.id | tostring) as $id | $trusted | index($id)))
      | (if $kind == "review" then (.submitted_at // .updated_at // .created_at) else .created_at end
          | fromdateiso8601) as $created_at
      | ((.updated_at // (if $kind == "review" then .submitted_at else .created_at end) // .created_at)
          | fromdateiso8601) as $updated_at
      | [.user.login, $kind, (.id | tostring), ($created_at | tostring), ($updated_at | tostring), ([.body // "", .state // ""] | @base64)] | @tsv
    ' <<<"$payload" 2>/dev/null
}

activity_snapshot() {
    repo=$1
    pr_number=$2
    rows=
    for kind_endpoint in \
        "review repos/$repo/pulls/$pr_number/reviews?per_page=100" \
        "comment repos/$repo/issues/$pr_number/comments?per_page=100" \
        "inline repos/$repo/pulls/$pr_number/comments?per_page=100"; do
        kind=${kind_endpoint%% *}
        endpoint=${kind_endpoint#* }
        part="$(activity_rows "$repo" "$pr_number" "$kind" "$endpoint")" || return $?
        if [ -n "$part" ]; then
            rows="${rows}${rows:+$'\n'}${part}"
        fi
    done
    printf '%s' "$rows"
}

# Every event is emitted before its state is persisted, matching lane events:
# an unsuccessful persistence is fatal and never silently consumes an event.
poll_activity() {
    local rows actor kind id created updated content revision key
    rows="$(activity_snapshot "$repo" "$pr_number")" || return $?
    while IFS=$'\t' read -r actor kind id created updated content; do
        [ -n "$id" ] || continue
        revision="$(printf '%s' "$content" | cksum | awk '{print $1}')"
        key="$pr_key:$kind:$id"
        if [ "$(state_get PRSEEN "$key" || true)" != "$updated:$revision" ]; then
            echo "PR-ACTIVITY $lane: #$pr_number $actor $kind $id updated=$updated revision=$revision"
            state_set PRSEEN "$key" "$updated:$revision"
            persist_state
        fi
    done <<<"$rows"
}

# Paginate GraphQL connections rather than using the Checks REST API, which
# rejects fine-grained agent tokens. isRequired is evaluated for this PR by
# GitHub, so optional checks cannot masquerade as required CI.
pr_connection() {
    local selection=$1 connection=$2 payload
    payload="$(bounded "$timeout_seconds" gh api graphql --paginate --slurp \
        -f owner="${repo%%/*}" -f name="${repo#*/}" -F number="$pr_number" \
        -f query="query(\$owner:String!,\$name:String!,\$number:Int!,\$endCursor:String){
          repository(owner:\$owner,name:\$name){pullRequest(number:\$number){headRefOid $selection}}
        }")" || return $?
    jq -e 'type == "array" and length > 0 and all(.[]; .errors == null)' >/dev/null 2>&1 <<<"$payload" || return 1
    jq -e 'all(.[]; (.data.repository.pullRequest | type) == "object")' >/dev/null 2>&1 <<<"$payload" || return 1
    jq -e --arg head "$head_oid" 'all(.[]; .data.repository.pullRequest.headRefOid == $head)' >/dev/null 2>&1 <<<"$payload" || return 76
    jq -ce --arg connection "$connection" '
      if type != "array" or length == 0 or any(.[]; .errors != null) then error("invalid pages") else . end
      | map(.data.repository.pullRequest
          | if $connection == "threads" then .reviewThreads
            else .commits.nodes[0].commit.statusCheckRollup.contexts end)
      | if all(.[]; ($connection == "ci" and . == null) or ((.nodes | type) == "array"))
        then [.[].nodes[]?] else error("invalid connection") end
    ' <<<"$payload" 2>/dev/null
}

poll_threads() {
    local rows id resolved previous generation
    rows="$(pr_connection 'reviewThreads(first:100,after:$endCursor){nodes{id isResolved} pageInfo{hasNextPage endCursor}}' threads)" || return $?
    jq -e 'all(.[]; (.id | type) == "string" and (.id | test("^[A-Za-z0-9_=-]+$"))
      and (.isResolved | type) == "boolean")' >/dev/null <<<"$rows" || return 1
    while IFS=$'\t' read -r id resolved; do
        [ -n "$id" ] || continue
        previous="$(state_get THREAD "$pr_key:$id" || true)"
        generation=${previous#*:}
        case "$generation" in '' | *[!0-9]*) generation=0 ;; esac
        if [ -z "$previous" ] || { [ "$resolved" = false ] && [[ "$previous" == true:* ]]; }; then
            generation=$((generation + 1))
            if [ -z "$previous" ]; then
                echo "PR-THREAD $lane: #$pr_number $id opened generation=$generation"
            else
                echo "PR-THREAD $lane: #$pr_number $id reopened generation=$generation"
            fi
        fi
        state_set THREAD "$pr_key:$id" "$resolved:$generation"
    done < <(jq -r '.[] | [.id,.isResolved] | @tsv' <<<"$rows")
    persist_state
}

poll_ci() {
    local rows snapshot
    rows="$(pr_connection 'commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100,after:$endCursor){nodes{__typename ... on CheckRun{name status conclusion isRequired(pullRequestNumber:$number)} ... on StatusContext{context state isRequired(pullRequestNumber:$number)}} pageInfo{hasNextPage endCursor}}}}}}' ci)" || return $?
    snapshot="$(jq -ce '
      if all(.[]; (.isRequired | type) == "boolean"
        and (if .__typename == "CheckRun" then (.name | type) == "string" and (.status | type) == "string"
          elif .__typename == "StatusContext" then (.context | type) == "string" and (.state | type) == "string"
          else false end)) then . else error("invalid checks") end
      | map(select(.isRequired) | if .__typename == "CheckRun"
          then {name:.name,conclusion:(if .status == "COMPLETED" then (.conclusion // "UNKNOWN") else .status end)}
          else {name:.context,conclusion:.state} end)
      | sort_by(.name,.conclusion)
    ' <<<"$rows" 2>/dev/null)" || return 1
    if [ "$(state_get CI "$pr_key" || true)" != "$head_oid:$snapshot" ]; then
        echo "PR-CI $lane: #$pr_number head=${head_oid:0:8} required=$snapshot"
        state_set CI "$pr_key" "$head_oid:$snapshot"
        persist_state
    fi
}

poll_behind() {
    local last meta base base_name encoded_base head comparison behind value
    last="$(state_get BEHIND-POLL "$pr_key" || true)"
    case "$last" in '' | *[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge 300 ] || return 0
    meta="$(bounded "$timeout_seconds" gh pr view "$pr_number" --repo "$repo" --json baseRefName,headRefOid)" || return 1
    base_name="$(jq -er '.baseRefName | select(type == "string" and length > 0)' <<<"$meta")" || return 1
    encoded_base="$(jq -rn --arg base "$base_name" '$base | @uri')" || return 1
    head="$(jq -er '.headRefOid | select(type == "string" and test("^[0-9a-fA-F]{40,64}$"))' <<<"$meta")" || return 1
    [ "$head" = "$head_oid" ] || return 76
    comparison="$(bounded "$timeout_seconds" gh api "repos/$repo/compare/$encoded_base...$head")" || return 1
    # baseRefOid on a PR may lag its branch. The compare response identifies
    # the live tip actually compared, including when a base name contains #.
    base="$(jq -er '.base_commit.sha | select(type == "string" and test("^[0-9a-fA-F]{40,64}$"))' <<<"$comparison")" || return 1
    behind="$(jq -er '.behind_by | select(type == "number" and . >= 0 and floor == .)' <<<"$comparison")" || return 1
    value="$base:$head:$behind"
    if [ "$behind" -gt 0 ] && [ "$(state_get BEHIND "$pr_key" || true)" != "$value" ]; then
        echo "PR-BEHIND $lane: #$pr_number base=$base behind_by=$behind"
    fi
    state_set BEHIND "$pr_key" "$value"
    state_set BEHIND-POLL "$pr_key" "$now"
    persist_state
}

observe_lifecycle() {
    local pr=$1 pr_number head_oid pr_key endpoint all_observed=1 terminal draft rc
    [[ "$pr" =~ ^#([0-9]+)\ draft=(true|false)\ (OPEN|CLOSED|MERGED)\ head=([0-9A-Fa-f]{8,64})$ ]] || return 0
    pr_number=${BASH_REMATCH[1]}
    draft=${BASH_REMATCH[2]}
    terminal=${BASH_REMATCH[3]}
    head_oid=${BASH_REMATCH[4]}
    pr_key="$repo#$pr_number"
    if [ "$terminal" != OPEN ]; then
        if [ "$(state_get TERMINAL "$pr_key" || true)" != "$terminal:$head_oid" ]; then
            echo "PR-$terminal $lane: #$pr_number head=${head_oid:0:8}"
            state_set TERMINAL "$pr_key" "$terminal:$head_oid"
            persist_state
        fi
        return 0
    fi
    state_delete TERMINAL "$pr_key"
    for endpoint in activity threads ci behind; do
        now="$(date -u +%s)"
        if observation_ready "$pr_key:$endpoint"; then
            if "poll_$endpoint"; then
                observation_recover "$pr_key:$endpoint"
            else
                rc=$?
                all_observed=0
                if [ "$rc" -eq 76 ]; then
                    state_delete WATCHING "$pr_key"
                    persist_state
                    return "$rc"
                fi
                observation_record_failure "$pr_key:$endpoint" "$lane" "GitHub $endpoint observation failed for PR #$pr_number" "$rc" || {
                    observation_failed "GitHub $endpoint observation failed for PR #$pr_number"
                    return 0
                }
            fi
        else
            all_observed=0
        fi
    done
    if [ "$all_observed" -eq 0 ]; then
        state_delete WATCHING "$pr_key"
        persist_state
    fi
    if [ "$all_observed" -eq 1 ] && [ "$(state_get WATCHING "$pr_key" || true)" != "$head_oid:$draft" ]; then
        echo "PR-WATCHING $lane: #$pr_number head=${head_oid:0:8} draft=$draft"
        state_set WATCHING "$pr_key" "$head_oid:$draft"
        persist_state
    fi
}

discover_pr() {
    repo=$1
    branch=$2
    if [ "$extra" = pr ]; then
        payload="$(bounded "$timeout_seconds" gh pr view "$branch" --repo "$repo" --json number,isDraft,state,headRefOid)" || return $?
        payload="[$payload]"
    else
        payload="$(bounded "$timeout_seconds" gh pr list --repo "$repo" --head "$branch" --state all \
            --limit 1 --json number,isDraft,state,headRefOid)" || return $?
    fi
    jq -e '
      type == "array"
      and length <= 1
      and all(.[];
        (.number | type) == "number"
        and (.number | floor) == .number
        and .number > 0
        and (.isDraft | type) == "boolean"
        and (.state == "OPEN" or .state == "CLOSED" or .state == "MERGED")
        and (.headRefOid | type) == "string"
        and (.headRefOid | test("^[0-9A-Fa-f]{8,64}$")))
    ' >/dev/null 2>&1 <<<"$payload" || return 1
    jq -r '
      .[0] // empty
      | "#\(.number) draft=\(.isDraft) \(.state) head=\(.headRefOid)"
    ' <<<"$payload" 2>/dev/null
}

observe_pr() {
    lane=$1
    pr=$2
    now=$3
    [ -n "$pr" ] || return 0
    old_pr="$(state_get PR "$lane" || true)"
    [ "$old_pr" != "$pr" ] || return 0
    state_set PR "$lane" "$pr"
    persist_state
    head_oid=${pr##* head=}
    echo "PR $lane: ${pr%head=*}head=${head_oid:0:8}"
}

observe_branch() {
    local lane=$1 repo=$2 branch=$3 response status payload head previous value rc=0
    response="$(bounded "$timeout_seconds" gh api --include "repos/$repo/git/ref/heads/$branch")" || rc=$?
    status="$(awk 'NR == 1 && /^HTTP\// {print $2}' <<<"$response")"
    if [ "$status" = 404 ]; then
        value="$branch absent"
    else
        [ "$rc" -eq 0 ] && [ "$status" = 200 ] || return 1
        payload="$(awk 'body {print} /^\r?$/ {body=1}' <<<"$response")"
        head="$(jq -er --arg ref "refs/heads/$branch" '
      select(.ref == $ref and .object.type == "commit") | .object.sha
      | select(type == "string" and test("^[0-9A-Fa-f]{40,64}$"))
    ' <<<"$payload")" || return 1
        value="$branch head=$head"
    fi
    previous="$(state_get BRANCH "$lane" || true)"
    if [ "$previous" != "$value" ]; then
        state_set BRANCH "$lane" "$value"
        persist_state
        if [ "$status" = 404 ]; then
            echo "BRANCH $lane: absent"
        else
            echo "BRANCH $lane: $branch head=${head:0:8}"
        fi
    fi
}

local_lanes=0
timed_specs=0
for spec in "${specs[@]}"; do
    parse_spec "$spec"
    [ -n "$extra" ] || local_lanes=1
    [ "$extra" = pr ] || timed_specs=1
done

load_state
rate_until="$(state_get RATE github || true)"
case "$rate_until" in '' | *[!0-9]*) ;; *) printf '%s\n' "$rate_until" >"$read_dir/rate-until" ;; esac
[ "$timeout_seconds" -gt 0 ] || {
    echo "lane-watch: timeout must be greater than zero" >&2
    exit 2
}
poll_count=0
exit_status=0
herdr_list_retired=0
while true; do
    now="$(date -u +%s)"
    if [ "$timed_specs" -eq 1 ] && [ "$warned" -eq 0 ] && [ $((deadline - now)) -le 1800 ]; then
        remaining_minutes=$(((deadline - now + 59) / 60))
        warned=1
        persist_state
        echo "WALLCLOCK run: $remaining_minutes min to $deadline_iso cap"
    fi
    if [ "$timed_specs" -eq 1 ] && [ "$now" -ge "$deadline" ] && [ "$warned" -ne 2 ]; then
        echo "WALLCLOCK run: deadline $deadline_iso reached"
        warned=2
        persist_state
    fi
    active_specs=0

    # A structured wait is visible even when Herdr or GitHub is unavailable.
    # Return on every current wait snapshot; only its event emission deduplicates.
    for spec in "${specs[@]}"; do
        parse_spec "$spec"
        if [ -z "$extra" ] && [ "$now" -lt "$deadline" ] && observe_lane_status; then
            persist_state
            exit 0
        fi
    done

    local_lanes=0
    for spec in "${specs[@]}"; do
        parse_spec "$spec"
        [ -n "$extra" ] || local_lanes=1
    done
    deadline_applies=1
    extra=
    agents_available=0
    agents=
    if [ "$local_lanes" -eq 1 ] && [ "$now" -lt "$deadline" ] && [ "$herdr_list_retired" -eq 0 ]; then
        now="$(date -u +%s)"
        if observation_ready 'run:HERDR-LIST'; then
            if agents="$(bounded "$timeout_seconds" herdr agent list)" &&
                jq -e '
                  .result.agents | type == "array" and
                  all(.[];
                    type == "object" and
                    (.name | type == "string" and length > 0) and
                    (.agent_status | type == "string" and length > 0))
                ' >/dev/null 2>&1 <<<"$agents"; then
                herdr_episode_recover 'run:HERDR-LIST' read-succeeded
                agents_available=1
            else
                observation_record_failure 'run:HERDR-LIST' herdr \
                    'Herdr agent list observation failed' ||
                    herdr_list_retired=1
            fi
        else
            herdr_episode_recover 'run:HERDR-LIST' not-attempted
        fi
    elif [ "$local_lanes" -eq 0 ] && [ "$herdr_list_retired" -eq 0 ]; then
        herdr_episode_recover 'run:HERDR-LIST' no-local-lanes
    fi

    heartbeat_summary=
    for spec_index in "${!specs[@]}"; do
        spec=${specs[$spec_index]}
        parse_spec "$spec"
        now="$(date -u +%s)"
        if [ "$extra" = pr ]; then
            [ -z "$(state_get TERMINAL "$repo#$branch" || true)" ] || continue
            last_pr_poll="$(state_get PR-POLL "$repo#$branch" || true)"
            case "$last_pr_poll" in '' | *[!0-9]*) last_pr_poll=0 ;; esac
            if [ $((now - last_pr_poll)) -lt "$pr_interval_seconds" ]; then
                active_specs=$((active_specs + 1))
                # Quiescent PRs still belong in every all-spec heartbeat.
                changed="$(state_get PROGRESS "$lane:$nonce" extra || true)"
                age=unknown
                [ -z "$changed" ] || age="$((now - changed))s"
                pr_summary="$(state_get PR "$lane" || printf absent)"
                heartbeat_summary="${heartbeat_summary:+$heartbeat_summary; }$lane: state=cloud age=$age pr=$pr_summary"
                continue
            fi
            state_set PR-POLL "$repo#$branch" "$now"
        else
            [ "$now" -lt "$deadline" ] || continue
        fi
        active_specs=$((active_specs + 1))
        if [ -z "$extra" ] && [ "$herdr_list_retired" -eq 1 ]; then
            observation_failed "Herdr agent list observation failed"
            active_specs=$((active_specs - 1))
            continue
        fi
        progress_key="$lane:$nonce"
        agent_state=cloud
        if [ -z "$extra" ]; then
            agent_state=unknown
            pane_available=0
            pane_visible=
            prompt=
            prompt_observed=0
            fallback=0
            explain_available=0
            listed_state=
            previous="$(state_get AGENT "$lane" || printf unknown)"
            if [ "$agents_available" -eq 1 ]; then
                listed_state="$(jq -r --arg lane "$lane" '.result.agents[]? | select(.name == $lane) | .agent_status' <<<"$agents" 2>/dev/null | tail -1)"
                if [ -z "$listed_state" ]; then
                    # A successful list is authoritative about disappearance,
                    # regardless of what a pane or explain call would report.
                    agent_state=absent
                    prompt_observed=1
                else
                    agent_state=$previous
                fi
            fi
            if [ "$agents_available" -eq 0 ] || [ -n "$listed_state" ]; then
                now="$(date -u +%s)"
                if observation_ready "$lane:HERDR-VISIBLE"; then
                    if pane_visible="$(bounded "$timeout_seconds" herdr agent read "$lane" --source visible --lines 80)"; then
                        herdr_episode_recover "$lane:HERDR-VISIBLE" read-succeeded
                        pane_available=1
                    else
                        observation_record_failure "$lane:HERDR-VISIBLE" "$lane" \
                            "Herdr visible-pane observation failed for lane $lane" ||
                            {
                                observation_failed "Herdr visible-pane observation failed for lane $lane"
                                active_specs=$((active_specs - 1))
                                continue
                            }
                    fi
                else
                    herdr_episode_recover "$lane:HERDR-VISIBLE" not-attempted
                fi
            else
                herdr_episode_recover "$lane:HERDR-VISIBLE" lane-absent
            fi
            if [ "$agents_available" -eq 1 ] && [ -n "$listed_state" ]; then
                now="$(date -u +%s)"
                if observation_ready "$lane:HERDR-EXPLAIN"; then
                    if explanation="$(bounded "$timeout_seconds" herdr agent explain "$lane" --json)" &&
                        jq -e 'type == "object" and has("fallback_reason") and (.fallback_reason == null or (.fallback_reason | type == "string"))' >/dev/null 2>&1 <<<"$explanation"; then
                        herdr_episode_recover "$lane:HERDR-EXPLAIN" read-succeeded
                        explain_available=1
                        agent_state=$listed_state
                        if jq -e '.fallback_reason != null' >/dev/null 2>&1 <<<"$explanation"; then
                            fallback=1
                            agent_state=$previous
                            if [ "$pane_available" -eq 1 ]; then
                                agent_state=unknown
                                prompt_observed=1
                                prompt="$(fallback_approval_request <<<"$pane_visible")"
                                [ -z "$prompt" ] || agent_state=blocked
                                agent_state="$agent_state (fallback)"
                            else
                                # Fallback state comes from the pane; a failed
                                # capture conveys no new state either.
                                explain_available=0
                            fi
                        else
                            prompt_observed=1
                        fi
                    else
                        observation_record_failure "$lane:HERDR-EXPLAIN" "$lane" \
                            "Herdr agent-state explanation failed for lane $lane" ||
                            {
                                observation_failed "Herdr agent-state explanation failed for lane $lane"
                                active_specs=$((active_specs - 1))
                                continue
                            }
                    fi
                else
                    herdr_episode_recover "$lane:HERDR-EXPLAIN" not-attempted
                fi
            else
                if [ "$agents_available" -eq 1 ] && [ -z "$listed_state" ]; then
                    herdr_episode_recover "$lane:HERDR-EXPLAIN" lane-absent
                else
                    herdr_episode_recover "$lane:HERDR-EXPLAIN" unknown
                fi
            fi
            # A successful absence is authoritative; otherwise a failed
            # explain on a listed lane conveys no new state.
            if [ "$agent_state" = absent ] || [ "$explain_available" -eq 1 ]; then
                previous="$(state_get AGENT "$lane" || printf init)"
                if [ "$previous" != "$agent_state" ]; then
                    state_set AGENT "$lane" "$agent_state"
                    persist_state
                    echo "AGENT $lane: $previous -> $agent_state"
                fi
            fi
            # A retained classified blocked state still owns its episode when
            # explain transiently fails; pane failure cannot stop re-emission.
            if [ "$agents_available" -eq 1 ] && [ "$agent_state" = blocked ]; then
                prompt_observed=1
                prompt="$(approval_excerpt <<<"$pane_visible")"
                prompt=${prompt:-'(input requested; text not captured)'}
            elif [ "$agents_available" -eq 1 ] && [ "$agent_state" = 'blocked (fallback)' ] && [ "$pane_available" -eq 1 ]; then
                fallback=1
                prompt_observed=1
                prompt="$(fallback_approval_request <<<"$pane_visible")"
            fi
            if [ "$prompt_observed" -eq 1 ]; then
                now="$(date -u +%s)"
                observe_prompt "$progress_key" "$prompt" "$fallback"
            fi

            if [ -n "$report_path" ]; then
                report=$report_path
            elif [ "$workspace_root_explicit" -eq 1 ]; then
                report="$workspace_root/${repo#*/}/.worktrees/$lane/.lane-report.md"
            else
                report="$checkout_root/.worktrees/$lane/.lane-report.md"
            fi
            sentinel="$(sentinel_from_report "$report" "$lane_label" "$nonce")"
            pane_only=0
            recent_working_explained=0
            if [ "$agents_available" -eq 1 ] && [ "$listed_state" = working ] &&
                [ "$explain_available" -eq 1 ] && [ "$fallback" -eq 0 ]; then
                recent_working_explained=1
            fi
            if [ -z "$sentinel" ] && [ "$agents_available" -eq 1 ] &&
                [ "$recent_working_explained" -eq 0 ] &&
                [[ "$agent_state" =~ ^(idle|done|blocked)(\ \(fallback\))?$ || "$agent_state" = "unknown (fallback)" ]]; then
                # Keep historical sentinel reads separate from visible approval UI.
                pane_recent=
                now="$(date -u +%s)"
                if observation_ready "$lane:HERDR-RECENT"; then
                    if pane_recent="$(bounded "$timeout_seconds" herdr agent read "$lane" --source recent-unwrapped --lines 80)"; then
                        herdr_episode_recover "$lane:HERDR-RECENT" read-succeeded
                        sentinel="$(terminal_sentinel "$lane_label" "$nonce" <<<"$pane_recent")"
                        [ -z "$sentinel" ] || pane_only=1
                    else
                        observation_record_failure "$lane:HERDR-RECENT" "$lane" \
                            "Herdr recent-pane observation failed for lane $lane" ||
                            {
                                observation_failed "Herdr recent-pane observation failed for lane $lane"
                                active_specs=$((active_specs - 1))
                                continue
                            }
                    fi
                else
                    herdr_episode_recover "$lane:HERDR-RECENT" not-attempted
                fi
            elif [ "$agents_available" -eq 1 ] && [ -z "$listed_state" ]; then
                herdr_episode_recover "$lane:HERDR-RECENT" lane-absent
            elif [ "$recent_working_explained" -eq 1 ]; then
                herdr_episode_recover "$lane:HERDR-RECENT" explained-working
            elif [ -n "$sentinel" ]; then
                herdr_episode_recover "$lane:HERDR-RECENT" report-sentinel
            else
                herdr_episode_recover "$lane:HERDR-RECENT" unknown
            fi
            sentinel_key="$lane:$sentinel"
            sentinel_kind=SENTINEL-REPORT
            [ "$pane_only" -eq 0 ] || sentinel_kind=SENTINEL-PANE
            # A pane observation is advisory, so it must not consume the
            # report confirmation. Once confirmed, neither source repeats it.
            if [ -n "$sentinel" ] &&
                ! state_get SENTINEL-REPORT "$sentinel_key" >/dev/null &&
                ! state_get "$sentinel_kind" "$sentinel_key" >/dev/null; then
                state_set "$sentinel_kind" "$sentinel_key" 1
                persist_state
                suffix=
                [ "$pane_only" -eq 0 ] || suffix=' (pane only)'
                echo "SENTINEL $lane: $sentinel$suffix"
                case "$sentinel" in
                DRAFT-PUBLISHED-*) echo "DRAFT-PUBLISHED $lane: $sentinel$suffix" ;;
                esac
            fi

            if [ "$pane_available" -eq 1 ]; then
                metadata="$(state_get METADATA "$progress_key" || true)"
                if [ "$agents_available" -eq 1 ]; then
                    metadata="$(jq -c --arg lane "$lane" '.result.agents[]? | select(.name == $lane) | [.revision, .state_change_seq]' <<<"$agents" | tail -1)"
                    state_set METADATA "$progress_key" "$metadata"
                fi
                pane_terminal="$(terminal_sentinel "$lane_label" "$nonce" <<<"$pane_visible")"
                now="$(date -u +%s)"
                observe_pane_progress "$progress_key" "$pane_visible" "$metadata" "${sentinel:-$pane_terminal}"
                if tail -n 8 <<<"$pane_visible" | grep -F 'Usage limit reached' >/dev/null; then
                    if [ "$(state_get USAGE "$lane" || printf 0)" -eq 0 ]; then
                        state_set USAGE "$lane" 1
                        persist_state
                        echo "USAGE-PAUSED $lane"
                    fi
                else
                    state_set USAGE "$lane" 0
                fi
            fi

        elif [ "$extra" = cloud ]; then
            herdr_episode_recover "$lane:HERDR-VISIBLE" cloud-spec
            herdr_episode_recover "$lane:HERDR-EXPLAIN" cloud-spec
            herdr_episode_recover "$lane:HERDR-RECENT" cloud-spec
            now="$(date -u +%s)"
            if observation_ready "$lane:BRANCH"; then
                if observe_branch "$lane" "$repo" "$branch"; then
                    observation_recover "$lane:BRANCH"
                else
                    observation_record_failure "$lane:BRANCH" "$lane" "GitHub branch observation failed for lane $lane" ||
                        observation_failed "GitHub branch observation failed for lane $lane"
                fi
            fi
        fi

        if [ -z "${specs[$spec_index]:-}" ]; then
            active_specs=$((active_specs - 1))
            continue
        fi
        now="$(date -u +%s)"
        if observation_ready "$lane:PR"; then
            if pr="$(discover_pr "$repo" "$branch")"; then
                observation_recover "$lane:PR"
                observe_pr "$lane" "$pr" "$now"
                if observe_lifecycle "$pr"; then
                    :
                else
                    rc=$?
                    if [ "$rc" -eq 76 ]; then
                        # A push is an ordinary transition, not an outage.
                        if pr="$(discover_pr "$repo" "$branch")"; then
                            observe_pr "$lane" "$pr" "$(date -u +%s)"
                            observe_lifecycle "$pr" || true
                        else
                            rc=$?
                            observation_record_failure "$lane:PR" "$lane" "GitHub PR observation failed for lane $lane" "$rc" ||
                                observation_failed "GitHub PR observation failed for lane $lane"
                        fi
                    fi
                fi
            else
                rc=$?
                observation_record_failure "$lane:PR" "$lane" "GitHub PR observation failed for lane $lane" "$rc" ||
                    observation_failed "GitHub PR observation failed for lane $lane"
            fi
        fi
        if [ -z "${specs[$spec_index]:-}" ] ||
            { [ "$extra" = pr ] && state_get TERMINAL "$repo#$branch" >/dev/null; }; then
            active_specs=$((active_specs - 1))
            continue
        fi
        if [ -n "$extra" ]; then
            cloud_progress="$(state_get BRANCH "$lane" || true)|$(state_get PR "$lane" || true)"
            if [ "$(state_get PROGRESS "$progress_key" || true)" != "$cloud_progress" ]; then
                state_set PROGRESS "$progress_key" "$cloud_progress" "$now" 0
            fi
        fi
        changed="$(state_get PROGRESS "$progress_key" extra || true)"
        age=unknown
        if [ -n "$extra" ] || [ "$pane_available" -eq 1 ]; then
            [ -z "$changed" ] || age="$((now - changed))s"
        fi
        pr_summary="$(state_get PR "$lane" || printf absent)"
        heartbeat_summary="${heartbeat_summary:+$heartbeat_summary; }$lane: state=$agent_state age=$age pr=$pr_summary"
    done

    now="$(date -u +%s)"
    if [ "$active_specs" -eq 0 ]; then
        [ "$exit_status" -eq 0 ] || exit "$exit_status"
        echo "WATCH-COMPLETE run: no active specs"
        persist_state
        exit 0
    fi
    emit_heartbeat
    persist_state
    poll_count=$((poll_count + 1))
    if [ "$iterations" -gt 0 ] && [ "$poll_count" -ge "$iterations" ]; then
        exit 0
    fi
    sleep "$interval_seconds"
done
