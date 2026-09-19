#!/usr/bin/env bash
# Watch orchestrated lanes and emit stable, one-line transition events:
#   AGENT <lane>: <from> -> <to>
#   SENTINEL <lane>: <value>[ (pane only)]
#   PR <lane>: #<n> draft=<bool> <STATE> head=<sha8>
#   POST-PROMOTION-ACTIVITY <lane>: <actor> <review|comment|inline> <id> since=<epoch>:<event_id>
#   POST-PROMOTION-CLOSED <lane>: #<pr_number> since=<epoch>:<event_id>
#   POST-PROMOTION-INDETERMINATE <lane>: #<pr_number>
#   OBSERVATION-DEGRADED <lane|run>: <detail>
#
# Both POST-PROMOTION-ACTIVITY's and POST-PROMOTION-CLOSED's trailing
# "since=<epoch>:<event_id>" is the identity of the promotion window the row
# or close belongs to -- the same epoch:event_id pair ARMED and WINDOW's own
# detail field already carry (see below), and the same one keys
# POST-PROMOTION-ACTIVITY's own durable ACTIVITY dedup entry. Without it the
# event text is textually indistinguishable across two different windows for
# the same lane/PR: a same-head withdrawal-then-re-promotion after an earlier
# close re-arms a brand-new window (see check_repromotion_after_close() below)
# and, on its own eventual close or its own activity, would emit the exact
# same "POST-PROMOTION-CLOSED <lane>: #<pr_number>" / "POST-PROMOTION-ACTIVITY
# <lane>: <actor> <kind> <id>" text an earlier window already emitted, and a
# row dated between the old window's close and the new window's arming could
# dedup against the OLD window's already-recorded key even though it belongs
# to the new one. A consumer watching for "the concrete POST-PROMOTION-CLOSED
# event" could not tell two windows apart without this identity; carrying it
# on both event kinds lets a consumer correlate a given line against whichever
# promotion identity it is currently tracking rather than trusting any
# same-lane line in isolation. <event_id> may be empty (rendering as a
# trailing colon with nothing after it) only when the window was armed from
# state adopted before this identity encoding existed -- the same
# legacy-adoption tolerance this file already documents for WINDOW's own
# "since:event_id" detail field.
#   USAGE-PAUSED <lane>
#   WALLCLOCK <lane|run>: <text>
#
# Timestamp-versioned activity keys may emit one duplicate when adopting legacy state.
# WINDOW's persisted "since" likewise carries a ":<event_id>" suffix once armed by a
# resolved promotion event (see promotion_epoch()/poll_activity()); state adopted from
# before that encoding existed reads back with an empty id and may re-arm once more on
# adoption, the same legacy-adoption tolerance already documented for ACTIVITY keys.
# ARMED persists, per lane, the "since:event_id" identity of the promotion
# epoch the lane's most-recently-armed WINDOW was armed from. Unlike WINDOW,
# it is never deleted when a window closes, so check_repromotion_after_close()
# can still tell a genuinely new promotion apart from the one that already
# closed even once WINDOW itself is gone -- see that function for why WINDOW
# alone cannot do this once its own close/delete has already run.
# Clearing PR state on POST-PROMOTION-INDETERMINATE (so a later observation re-arms
# the window) also re-emits one identical PR line once that observation lands.
# Every herdr/gh call is bounded. Failures mean indeterminate/no event; this watcher
# never writes through either CLI. Pass --state-file so a re-armed watcher does
# not repeat sentinels, transitions, or post-promotion activity.
#
# A single failed herdr/gh read at any of the three observation call sites
# (PR discovery, promotion-identity re-check, activity polling) no longer
# exits the watcher immediately (#1041): that lane is retried with bounded
# backoff (5s/15s/45s, never scheduled past the run deadline) for up to
# --degrade-window-seconds (default 600s), measured from that lane's first
# failure and reset by its next success. The backoff never blocks: a
# degraded lane is simply skipped -- no GitHub call attempted at all -- on
# any poll before its persisted next-retry time, so a lane having a bad time
# never delays a healthy lane sharing the same specs[] list (challenge round
# 1 of #1041 found and fixed a first version of this mechanism that slept in
# place instead, which did exactly that -- see observation_ready()). The
# ordinary --interval-seconds sleep between polls is what paces every retry;
# nothing here adds a wait of its own. OBSERVATION-DEGRADED fires once per
# such episode -- deduplicated across a restart via the persisted DEGRADE
# state -- and only once the episode's window is exceeded does the watcher
# fall through to the original observation_failed() exit-1 behavior (or the
# existing WALLCLOCK exit-0 short-circuit, if the run deadline arrives
# first). resolve_promotion() applies the same OBSERVATION-DEGRADED event, on
# its own bounded-poll-count basis, when a persistently malformed
# ready_for_review row would otherwise leave a lane's promotion tracking
# indeterminate forever -- see that function.
set -u

usage() {
    cat <<'EOF'
Usage: lane-watch.sh [options] DEADLINE_ISO lane:branch:nonce:owner/repo ...

Options:
  --state-file PATH               Persist emitted state across restarts
  --registry PATH                 Agent registry (default: repo agent-registry.json)
  --workspace-root PATH           Parent containing repo checkouts (default: repo parent)
  --interval-seconds N            Poll interval (default: 15)
  --post-promotion-seconds N      Review activity window (default: 900)
  --timeout-seconds N             Per herdr/gh call timeout (default: 30)
  --degrade-window-seconds N      Retry episode window before giving up (default: 600)
  --iterations N                  Stop after N polls (tests; default: unlimited)
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
post_promotion_seconds=900
timeout_seconds=30
degrade_window_seconds=600
iterations=0
# Consecutive polls a malformed (non-numeric-id) ready_for_review row is
# allowed to leave promotion_epoch() indeterminate before it falls back to
# resolving from the valid rows alone -- see promotion_epoch(). A fixed
# script constant, not a flag or a .devflow.toml field (#1041 ruling 5): the
# 10-minute retry episode above is the operator-facing threshold; this one
# only bounds how long one malformed GitHub row can wedge a single lane's
# promotion tracking, which does not warrant its own knob.
malformed_promo_poll_bound=3

while [ "$#" -gt 0 ]; do
    case "$1" in
    --state-file | --registry | --workspace-root | --interval-seconds | --post-promotion-seconds | --timeout-seconds | --degrade-window-seconds | --iterations)
        [ "$#" -ge 2 ] || {
            usage >&2
            exit 2
        }
        case "$1" in
        --state-file) state_file=$2 ;;
        --registry) registry=$2 ;;
        --workspace-root)
            workspace_root=$2
            workspace_root_explicit=1
            ;;
        --interval-seconds) interval_seconds=$2 ;;
        --post-promotion-seconds) post_promotion_seconds=$2 ;;
        --timeout-seconds) timeout_seconds=$2 ;;
        --degrade-window-seconds) degrade_window_seconds=$2 ;;
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

case "$interval_seconds:$post_promotion_seconds:$timeout_seconds:$degrade_window_seconds:$iterations" in
*[!0-9:]* | *::* | :* | *:)
    echo "lane-watch: interval, window, degrade window, and iterations must be non-negative integers" >&2
    exit 2
    ;;
esac

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
        AGENT | PR | USAGE | CLOSING | ARMED) state_set "$kind" "$lane" "$value" ;;
        SENTINEL) state_set SENTINEL "$lane:$value" 1 ;;
        WINDOW) state_set WINDOW "$lane" "$value" "$extra" "$detail" ;;
        DEGRADE) state_set DEGRADE "$lane" "$value" "$extra" "$detail" ;;
        MALPROMO) state_set MALPROMO "$lane" "$value" "$extra" ;;
        ACTIVITY) state_set ACTIVITY "$lane:$value:$extra" 1 ;;
        WALLCLOCK) warned=$value ;;
        esac
    done <"$state_file"
}

save_state() {
    local state_dir state_tmp index kind key value extra detail lane rest
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
            AGENT | PR | USAGE | CLOSING | ARMED)
                printf '%s\t%s\t%s\t\n' "$kind" "$key" "$value"
                ;;
            SENTINEL) printf 'SENTINEL\t%s\t%s\t\n' "${key%%:*}" "${key#*:}" ;;
            WINDOW) printf 'WINDOW\t%s\t%s\t%s\t%s\n' "$key" "$value" "$extra" "$detail" ;;
            DEGRADE) printf 'DEGRADE\t%s\t%s\t%s\t%s\n' "$key" "$value" "$extra" "$detail" ;;
            MALPROMO) printf 'MALPROMO\t%s\t%s\t%s\t\n' "$key" "$value" "$extra" ;;
            ACTIVITY)
                lane=${key%%:*}
                rest=${key#*:}
                printf 'ACTIVITY\t%s\t%s\t%s\n' "$lane" "${rest%%:*}" "${rest#*:}"
                ;;
            esac
            index=$((index + 1))
        done
        printf 'WALLCLOCK\trun\t%s\t\n' "$warned"
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
    if [ "$(date -u +%s)" -ge "$deadline" ]; then
        persist_state
        echo "WALLCLOCK run: deadline $deadline_iso reached"
        exit 0
    fi
    echo "lane-watch: $label" >&2
    persist_state
    exit 1
}

# A lane's DEGRADE entry (value=first_failure_at, extra=notified 0/1,
# detail="<attempt>:<next_retry_at>") marks an in-progress retry episode.
# Keyed by "$lane:<endpoint>" (endpoint one of PR/REPROMO/ACTIVITY), not
# just $lane: #1041 challenge r1 finding codex-3 found that a single
# shared-per-lane episode let PR discovery's recovery on a restart silently
# reset a still-genuinely-failing activity or promotion-identity episode,
# repeatedly resetting the advertised degrade-window bound across restarts.
# Each endpoint now tracks -- and clears -- its own episode independently.
observation_recover() {
    local key=$1
    if [ -n "$(state_get DEGRADE "$key" || true)" ]; then
        state_delete DEGRADE "$key"
        persist_state
    fi
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
    detail_raw="$(state_get DEGRADE "$key" detail || true)"
    IFS=: read -r _ next_retry_at <<<"$detail_raw"
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
# observation_failed(), unchanged: still a process-wide exit 1 (or the
# WALLCLOCK exit-0 short-circuit), only reached across many polls now instead
# of one blocking wait.
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
# the WALLCLOCK exit-0 correctly, and announcing/persisting first left a
# spurious OBSERVATION-DEGRADED at the very moment of a normal run-end, plus
# a stray episode that could suppress a real future one's announcement
# after a restart (notified=1 with no failure having actually been
# reported to a human).
observation_record_failure() {
    local key=$1 lane=$2 detail=$3
    now="$(date -u +%s)"
    [ "$now" -lt "$deadline" ] || return 1
    local first_failure notified detail_raw attempt discard delay cap
    first_failure="$(state_get DEGRADE "$key" || true)"
    notified="$(state_get DEGRADE "$key" extra || printf 0)"
    detail_raw="$(state_get DEGRADE "$key" detail || true)"
    IFS=: read -r attempt discard <<<"$detail_raw"
    if [ -z "$first_failure" ]; then
        first_failure=$now
        notified=0
        attempt=0
    fi
    [ -n "$attempt" ] || attempt=0
    if [ "$notified" -eq 0 ]; then
        echo "OBSERVATION-DEGRADED $lane: $detail"
        notified=1
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
    cap=$((deadline - now))
    [ "$delay" -le "$cap" ] || delay=$cap
    cap=$((first_failure + degrade_window_seconds - now))
    [ "$delay" -le "$cap" ] || delay=$cap
    [ "$delay" -ge 0 ] || delay=0
    attempt=$((attempt + 1))
    state_set DEGRADE "$key" "$first_failure" "$notified" "$attempt:$((now + delay))"
    persist_state
    return 0
}

bounded() {
    seconds=$1
    shift
    remaining=$((deadline - $(date -u +%s)))
    [ "$remaining" -gt 0 ] || return 124
    [ "$seconds" -le "$remaining" ] || seconds=$remaining
    "$timeout_bin" --kill-after=2 "$seconds" "$@" </dev/null 2>/dev/null
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
trusted_actor_ids="$(jq -r '.finders[].trusted_actor_id // empty' "$registry")"

for spec in "${specs[@]}"; do
    IFS=: read -r lane branch nonce repo extra <<<"$spec"
    if [ -z "${lane:-}" ] || [ -z "${branch:-}" ] || [ -z "${nonce:-}" ] ||
        [ -z "${repo:-}" ] || [ -n "${extra:-}" ]; then
        echo "lane-watch: invalid lane spec: $spec" >&2
        exit 2
    fi
    case "$nonce" in
    *[!A-Za-z0-9_-]*)
        echo "lane-watch: invalid sentinel nonce in spec: $spec" >&2
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

sentinel_from_report() {
    report=$1
    nonce=$2
    [ -f "$report" ] || return 0
    grep -E "^LANE-[A-Z0-9-]+-(READY|BLOCKED)-${nonce}$" "$report" 2>/dev/null | tail -1
}

sentinel_from_pane() {
    lane=$1
    nonce=$2
    agent_state=$3
    case "$agent_state" in
    idle | done | blocked) ;;
    *) return 0 ;;
    esac
    pane="$(bounded "$timeout_seconds" herdr agent read "$lane" --source recent-unwrapped --lines 80 || true)"
    awk 'NF { last = $0 } END { print last }' <<<"$pane" |
        grep -E "^LANE-[A-Z0-9-]+-(READY|BLOCKED)-${nonce}$" 2>/dev/null
}

activity_rows() {
    repo=$1
    pr_number=$2
    kind=$3
    endpoint=$4
    payload="$(bounded "$timeout_seconds" gh api --paginate --slurp "$endpoint")" || return 1
    [ -n "$payload" ] || return 1
    jq -e 'if (.[0]? | type) == "array" then all(.[]; type == "array") else type == "array" end' \
        >/dev/null 2>&1 <<<"$payload" || return 1
    # A row this function would otherwise select (a trusted actor's review,
    # comment, or inline finding) must carry the timestamp field its kind
    # needs -- a review needs at least one of submitted_at/updated_at/
    # created_at, a comment/inline row needs created_at. Missing that field
    # is not "no activity": the extraction pipeline below computes
    # $created_at via `... // empty`, so a row missing it silently produces
    # nothing for that one iteration and the caller cannot tell a malformed
    # API response apart from a genuinely quiet window. Fail the snapshot
    # (same as the structural array-shape check above) instead of silently
    # dropping the row. Narrowed to selected rows only: an entry from an
    # untrusted, non-User actor is already excluded from activity regardless
    # of whether it carries a timestamp, so it is not checked here.
    jq -e --arg kind "$kind" --arg trusted "$trusted_actor_ids" '
      (if (.[0]? | type) == "array" then add else . end)
      | map(select((.user.id | tostring) as $actor_id
          | .user.type == "User" or ($trusted | split("\n") | index($actor_id))))
      | all(.[];
          if $kind == "review" then
            (.submitted_at != null) or (.updated_at != null) or (.created_at != null)
          else
            .created_at != null
          end)
    ' >/dev/null 2>&1 <<<"$payload" || return 1
    jq -r --arg kind "$kind" --arg trusted "$trusted_actor_ids" '
      (if (.[0]? | type) == "array" then add else . end)[]?
      | (.user.id | tostring) as $actor_id
      | select(.user.type == "User" or ($trusted | split("\n") | index($actor_id)))
      | (if $kind == "review" then (.submitted_at // .updated_at // .created_at) else .created_at end // empty
          | fromdateiso8601) as $created_at
      | (if $kind == "review" then $created_at else ((.updated_at // .created_at) // empty | fromdateiso8601) end) as $updated_at
      | [.user.login, $kind, (.id | tostring), ($created_at | tostring), ($updated_at | tostring)] | @tsv
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
        part="$(activity_rows "$repo" "$pr_number" "$kind" "$endpoint")" || return 1
        if [ -n "$part" ]; then
            rows="${rows}${rows:+$'\n'}${part}"
        fi
    done
    printf '%s' "$rows"
}

poll_activity() {
    lane=$1
    repo=$2
    pr_number=$3
    now=$4
    # WINDOW's detail field carries "since:event_id" once a window has been
    # armed by a promotion_epoch() resolution (event_id empty only for state
    # adopted from before this encoding existed). Splitting on the first ':'
    # keeps `since` a pure epoch integer for the arithmetic below while
    # giving the warm re-arm check below the event identity it needs.
    persisted_since_raw="$(state_get WINDOW "$lane" detail || true)"
    persisted_until="$(state_get WINDOW "$lane" extra || printf 0)"
    cold_start=0
    [ -n "$persisted_since_raw" ] || cold_start=1
    IFS=: read -r persisted_since persisted_since_event_id <<<"$persisted_since_raw"

    # A warm window already durably marked CLOSING -- its closing
    # determination and every row from that fetch already fully persisted,
    # per the crash-safe reorder below, and only the final WINDOW/CLOSING
    # delete left undone -- needs no re-resolution of anything: that
    # decision is already made and recorded. Checking this first, from the
    # already-persisted `until` alone, before the epoch re-check just below
    # ever runs, is what keeps a restart landing here from re-fetching
    # anything at all (including the epoch itself). A window that has
    # merely passed its persisted `until` but has NOT yet recorded CLOSING
    # is not this case -- it is exactly the moment a stale schedule would
    # otherwise wrongly emit a false close, so it still goes through the
    # re-check below.
    if [ "$cold_start" -eq 0 ]; then
        persisted_expired=0
        [ "$now" -le "$persisted_until" ] || persisted_expired=1
        if [ "$persisted_expired" -eq 1 ] && [ "$(state_get CLOSING "$lane" || printf 0)" = 1 ]; then
            state_delete WINDOW "$lane"
            state_delete CLOSING "$lane"
            return 0
        fi
    fi

    provisional_expired=0
    [ "$now" -le "$persisted_until" ] || provisional_expired=1

    # Re-resolve the promotion epoch every poll, not only at cold start.
    # observe_pr()'s change detection is a bare string compare of
    # discover_pr()'s "#N draft=<bool> <STATE> head=<sha>" tuple; a PR
    # withdrawn (gh pr ready --undo) and re-promoted at the same head,
    # entirely between two observations of this lane, collapses back to
    # that identical tuple, so observe_pr() never notices and never re-arms
    # WINDOW. promotion_epoch() is immune to that collapse: it reports the
    # *latest* ready_for_review event's timestamp, which a genuine
    # re-promotion always advances even though the PR tuple string does
    # not. Comparing the freshly resolved epoch against whichever epoch
    # WINDOW was last armed from (persisted as WINDOW's "since"/detail) is
    # what lets the warm path notice and re-arm. This costs one extra
    # bounded gh api call per poll while a window is active -- on top of
    # the three activity_snapshot calls already made every such poll --
    # which is an acceptable, bounded addition given this file's existing
    # per-poll API budget and its already fail-closed handling of a failed
    # call (observation_failed halts the watcher either way).
    resolve_promotion "$lane" "$repo" "$pr_number"
    promotion_status=$?
    rearmed=0
    if [ "$promotion_status" -eq 11 ]; then
        # #1041 challenge r1 finding codex-2: a VALID resolution exists but
        # is being withheld for the malformed-row bound (see
        # resolve_promotion()) -- touch NOTHING this poll: no closing, no
        # (re)arming. Falling through to status 10's "trust the old armed
        # window" handling here was the bug: it could close a stale,
        # already-expired window using its stale identity while this valid,
        # newer promotion sat unused right here, silently dropping it.
        return 0
    fi
    if [ "$promotion_status" -eq 10 ]; then
        if [ "$cold_start" -eq 1 ]; then
            if [ "$provisional_expired" -eq 1 ]; then
                state_delete WINDOW "$lane"
                state_delete CLOSING "$lane"
                state_delete PR "$lane"
                echo "POST-PROMOTION-INDETERMINATE $lane: #$pr_number"
            fi
            return 0
        fi
        # Warm poll, no resolvable ready_for_review event this time around
        # (ordinary GitHub eventual consistency, not a hard failure): trust
        # whichever window is already armed rather than tearing down a real
        # window over one transient events-API gap.
        since=$persisted_since
        since_event_id=$persisted_since_event_id
        until=$persisted_until
    elif [ "$promotion_status" -ne 0 ]; then
        return 1
    else
        since=$promo_since
        since_event_id=$promo_since_event_id
        until=$((since + post_promotion_seconds))
        # ARMED tracks the identity of the epoch actually resolved here,
        # independent of whether it turns out to be a change (rearmed=1
        # below) or, on an already-expired resolution, whether the window
        # ever gets persisted via the rearmed/expired block further down.
        # Keeping it current on every fresh resolution -- not only on a
        # detected change -- is what lets check_repromotion_after_close()
        # correctly recognize "this promotion was already seen and closed"
        # once WINDOW itself is gone, instead of mistaking an
        # already-handled promotion for a new one and re-arming a duplicate,
        # already-expired window for it every poll.
        state_set ARMED "$lane" "$since:$since_event_id"
        # A same-second withdrawal-then-re-promotion resolves to an
        # identical `since` epoch but a different event id; comparing the
        # epoch alone (the pre-fix check) sees "no change" and never
        # re-arms, silently reproducing the original silent-loss defect in
        # that one-second collision window. Comparing the id too tells the
        # two events apart even when their timestamps tie.
        if [ "$cold_start" -eq 1 ] || [ "$since" != "$persisted_since" ] ||
            [ "$since_event_id" != "$persisted_since_event_id" ]; then
            rearmed=1
        fi
    fi

    # `expired` is computed exactly once, here, from whichever `until` is
    # currently in scope: the real deadline just resolved above on a cold
    # start or a same-tuple re-promotion, or the already-real deadline read
    # from state on an unchanged warm poll -- never the provisional
    # placeholder observe_pr() seeds WINDOW with before the real epoch is
    # known. A resolved real epoch is not guaranteed <= that provisional
    # guess, so the two must not be conflated.
    expired=0
    [ "$now" -le "$until" ] || expired=1
    if [ "$rearmed" -eq 1 ] && [ "$expired" -eq 0 ]; then
        state_set WINDOW "$lane" "$pr_number" "$until" "$since:$since_event_id"
        # A re-arm can follow a PRIOR window's CLOSING flag left behind by a
        # crash between persisting it and deleting it (see the ordering
        # comment below); that flag belongs to the window that just expired,
        # not this freshly armed one, and must not be read later as "this
        # new window's closing snapshot is already done."
        state_delete CLOSING "$lane"
    fi

    if [ "$expired" -eq 1 ]; then
        if [ "$(state_get CLOSING "$lane" || printf 0)" = 1 ]; then
            state_delete WINDOW "$lane"
            state_delete CLOSING "$lane"
            return 0
        fi
    fi

    rows="$(activity_snapshot "$repo" "$pr_number")" || return 1

    # A comment/inline row carries two candidate instants -- its creation and
    # its current updated_at, which GitHub sets equal to created_at at
    # creation and only diverges from on a real edit. A comment CREATED
    # inside [since,until] is in-window activity even when a LATER edit moved
    # its updated_at past `until`; using .updated_at // .created_at alone
    # (the pre-fix shape) silently dropped exactly that case, since GitHub
    # always sets updated_at, so the // .created_at fallback never actually
    # ran. Prefer created_at when it alone qualifies; fall back to updated_at
    # when only the edit instant falls in-window (creation happened before
    # the window opened). When BOTH instants fall in-window they describe one
    # comment's one activity, not two: report it once, keyed off created_at,
    # rather than manufacturing a second dedup key for the same id.
    while IFS=$'\t' read -r actor kind id created_at updated_at; do
        [ -n "$id" ] || continue
        activity_at=
        if [ -n "$created_at" ] && [ "$created_at" -ge "$since" ] && [ "$created_at" -le "$until" ]; then
            activity_at=$created_at
        elif [ -n "$updated_at" ] && [ "$updated_at" -ge "$since" ] && [ "$updated_at" -le "$until" ]; then
            activity_at=$updated_at
        fi
        [ -n "$activity_at" ] || continue
        # Bind this row to the exact window's promotion identity, in both the
        # durable dedup key and the emitted line: a same-head withdraw and
        # re-promotion that lands its own ready_for_review event before this
        # row's poll observes it, but after the OLD window's key was already
        # recorded, must not have this row suppressed as "already reported"
        # for a promotion it never actually belonged to -- and a consumer
        # correlating POST-PROMOTION-ACTIVITY against POST-PROMOTION-CLOSED's
        # own carried "since=" identity needs the same identity on this line.
        key="$lane:$since_event_id:$kind:$id:$activity_at"
        if ! state_get ACTIVITY "$key" >/dev/null; then
            echo "POST-PROMOTION-ACTIVITY $lane: $actor $kind $id since=$since:$since_event_id"
            state_set ACTIVITY "$key" 1
            persist_state
        fi
    done <<<"$rows"

    # CLOSING is recorded only once every row from this fetch has already
    # been durably persisted (the loop above), never before or during the
    # fetch/processing itself: a flag set earlier would still read back as 1
    # after a crash mid-fetch or mid-loop, letting a restart skip the
    # still-needed retry and silently lose whatever hadn't been recorded yet
    # -- the exact gap round 4 found via live repro. Recording it only here,
    # then persisting BEFORE the cleanup delete, means a restart's fast path
    # only ever skips a fetch+process cycle that has already, verifiably,
    # completed in full.
    #
    # POST-PROMOTION-CLOSED is echoed before persist_state, deliberately: a
    # crash between the echo and persist_state leaves CLOSING durably unset,
    # so the next poll finds no fast-path shortcut above, retakes this same
    # closing snapshot from scratch (every row already durably keyed under
    # ACTIVITY is deduped, so only the CLOSING determination and its echo
    # actually repeat), and emits the line again -- at worst one duplicate,
    # the same tolerance this file already documents for ACTIVITY-key
    # adoption. Echoing after persist_state instead would trade that
    # duplicate for the opposite failure: a crash between persist_state and
    # the echo leaves CLOSING durably 1, so the next poll's fast path
    # (above) deletes WINDOW/CLOSING and returns without ever reaching the
    # echo -- permanently losing the one signal this event exists to
    # guarantee, with no later poll left to retry it. A harmless duplicate
    # beats a signal that can never be recovered.
    #
    # The per-row POST-PROMOTION-ACTIVITY echo above (inside the read loop)
    # is ordered the same way -- echo, then state_set, then persist_state --
    # for the identical reason: a crash before persist_state leaves that
    # row's ACTIVITY key durably unset, so it is simply refetched and
    # re-emitted next poll, never silently dropped.
    if [ "$expired" -eq 1 ]; then
        state_set CLOSING "$lane" 1
        # Carry the closing window's own promotion identity (the same
        # epoch:event_id pair recorded in WINDOW's detail field and in
        # ARMED) so a consumer can bind this exact close to the promotion it
        # closed -- see the header comment's event-grammar note above.
        echo "POST-PROMOTION-CLOSED $lane: #$pr_number since=$since:$since_event_id"
        persist_state
        state_delete WINDOW "$lane"
        state_delete CLOSING "$lane"
    fi
}

promotion_epoch() {
    repo=$1
    pr_number=$2
    endpoint="repos/$repo/issues/$pr_number/events?per_page=100"
    payload="$(bounded "$timeout_seconds" gh api --paginate --slurp "$endpoint")" || return 1
    [ -n "$payload" ] || return 1
    jq -e 'if (.[0]? | type) == "array" then all(.[]; type == "array") else type == "array" end' \
        >/dev/null 2>&1 <<<"$payload" || return 1
    # A withdrawal and a same-head re-promotion inside the same second can
    # both land ready_for_review events with an identical created_at -- an
    # epoch-only result cannot tell those two events apart. Every GitHub
    # timeline event carries its own immutable `id`, so among the event(s)
    # sharing the latest created_at, break the tie on the highest id (GitHub
    # assigns timeline event ids in creation order, so the higher id is
    # always the later, correct event) and return both epoch and id. That
    # tie-break runs over the valid (numeric-id) ready_for_review rows only.
    #
    # #1041 (settling PR #1043's P2, carried as this issue's own comment): a
    # row missing a usable numeric id is never accepted with a null one --
    # interpolating a null id would resolve as the literal identity
    # "<epoch>:null", so two distinct malformed same-second promotions would
    # collapse to the same string and reproduce exactly the silent
    # re-promotion loss this tie-break exists to prevent. The original fix
    # for that simply dropped the malformed row and resolved from the valid
    # rows alone -- but that can silently miss a genuinely newer promotion
    # whose id GitHub simply has not populated yet, arming a stale window as
    # if it were the only one. So this function now always reports whether a
    # malformed row was present (as a third and fourth tab-separated output
    # field, has_malformed/malformed_id) rather than silently excluding it,
    # and leaves the bounded-indeterminate decision to resolve_promotion()
    # below, which -- unlike this function -- is never invoked through
    # command substitution and so can safely persist the MALPROMO state that
    # decision needs. A payload with zero valid rows at all (every
    # ready_for_review row malformed, or none present) still falls through
    # to the plain indeterminate result below -- there is no valid fallback
    # to bound towards, so that case is unaffected and unbounded, as before.
    resolution="$(jq -r '
      (if (.[0]? | type) == "array" then add else . end) as $all
      | ($all | map(select(.event == "ready_for_review"))) as $promotions
      | ($promotions | map(select((.id | type) == "number"))) as $valid
      | ($promotions | map(select((.id | type) != "number"))) as $malformed
      | if ($valid | length) == 0 then
          empty
        else
          ($valid | map(.created_at | fromdateiso8601) | max) as $max_epoch
          | ($valid | map(select((.created_at | fromdateiso8601) == $max_epoch)) | max_by(.id)) as $latest
          | (($malformed | length) > 0) as $has_malformed
          | (if $has_malformed then $malformed[0].id else "" end) as $malformed_id
          | "\($max_epoch)\t\($latest.id)\t\($has_malformed)\t\($malformed_id)"
        end
    ' <<<"$payload" 2>/dev/null)" || return 1
    [ -n "$resolution" ] || return 10
    printf '%s' "$resolution"
}

# promotion_epoch() is pure (no state mutation) because its callers invoke it
# through command substitution ("x=$(promotion_epoch ...)"), which runs it in
# a subshell -- any state_set()/persist_state() there would be silently lost
# the moment the subshell exits, invisible to the parent's own later
# persist_state() at the end of the poll. This wrapper is called directly
# (never substituted) by poll_activity()/check_repromotion_after_close(), so
# it is the one safe place to persist the bounded-malformed-row bookkeeping
# (#1041, settling PR #1043's P2). Return contract: 0 sets globals
# promo_since/promo_since_event_id -- a real resolution the caller should
# use. 1 is a hard failure, unchanged from promotion_epoch()'s own contract.
# 10 means promotion_epoch() itself found nothing resolvable at all --
# ordinary GitHub eventual consistency, safe for a caller to trust whatever
# it already has armed. 11 (#1041 challenge r1 finding codex-2) means a
# valid resolution DOES exist but is being withheld for the malformed-row
# bound -- callers must NOT treat this like 10: 10's "trust the old armed
# window" is only safe when nothing has actually changed, and applying it
# here let a stale, already-expired window get closed with its stale
# identity while this valid, newer promotion sat unused. A caller that can
# close a window must special-case 11 to touch nothing at all this poll.
resolve_promotion() {
    lane=$1
    repo=$2
    pr_number=$3
    # Keyed by "$lane:$pr_number", not just $lane: a lane's count must not
    # survive to taint a DIFFERENT PR the lane later promotes (#1041
    # challenge r1 finding 2: a stale count from a since-closed PR let a
    # brand-new PR's own, unrelated malformed row fall back after fewer than
    # malformed_promo_poll_bound real polls of it). The key alone is the
    # complete fix -- a different PR number is already a different key, so
    # nothing needs clearing on a clean close. An earlier version of this
    # fix ALSO cleared this key at every WINDOW teardown point, reasoning
    # (wrongly) that a clean close should reset the count; but the SAME PR
    # re-arming after a close is exactly the case where that clearing broke
    # this function's own once-per-episode contract -- it let the identical
    # still-malformed row re-withhold resolution for another full bound
    # period and double-announce (#1041 challenge r2 finding claude-3, with
    # a live repro). Deleted, not restructured: the clearing added nothing
    # the per-PR key didn't already provide.
    malpromo_key="$lane:$pr_number"
    epoch_id_pair="$(promotion_epoch "$repo" "$pr_number")"
    promotion_status=$?
    [ "$promotion_status" -eq 0 ] || return "$promotion_status"
    IFS=$'\t' read -r promo_since promo_since_event_id has_malformed malformed_id <<<"$epoch_id_pair"
    if [ "$has_malformed" != "true" ]; then
        if [ -n "$(state_get MALPROMO "$malpromo_key" || true)" ]; then
            state_delete MALPROMO "$malpromo_key"
            persist_state
        fi
        return 0
    fi
    malpromo_count="$(state_get MALPROMO "$malpromo_key" || printf 0)"
    malpromo_notified="$(state_get MALPROMO "$malpromo_key" extra || printf 0)"
    malpromo_count=$((malpromo_count + 1))
    if [ "$malpromo_count" -le "$malformed_promo_poll_bound" ]; then
        state_set MALPROMO "$malpromo_key" "$malpromo_count" "$malpromo_notified"
        persist_state
        # #1041 challenge r1 finding codex-2: this is NOT status 10's original
        # meaning ("no ready_for_review event resolvable at all" -- ordinary
        # GitHub eventual consistency, safe to trust whichever window is
        # already armed). A VALID resolution exists here (promotion_epoch()
        # already required $valid non-empty to reach this branch at all) --
        # it is only being withheld for the bound. Conflating the two under
        # one status let a caller's "trust the old armed window" warm-path
        # close a STALE, already-expired window using its stale identity
        # while a genuinely newer valid promotion sat right here, unused --
        # silently dropping it, exactly the class of loss the event-id
        # tie-break exists to prevent. Status 11 tells the caller to touch
        # NOTHING this poll -- no closing, no (re)arming -- rather than
        # reusing 10's "the old window is still the current truth" handling.
        return 11
    fi
    if [ "$malpromo_notified" -eq 0 ]; then
        state_set MALPROMO "$malpromo_key" "$malpromo_count" 1
        persist_state
        # #1041 challenge r2 finding claude-6: $malformed_id is GitHub input
        # that, by definition, already failed numeric validation -- never
        # interpolate it into the one-line event grammar unsanitized. Strip
        # to a safe token and bound its length so no value (a newline, a
        # tab, or an implausibly long string) can break line-oriented
        # parsing of this event.
        malformed_id_safe="$(printf '%s' "$malformed_id" | tr -cd 'A-Za-z0-9_-' | cut -c1-64)"
        [ -n "$malformed_id_safe" ] || malformed_id_safe="<non-numeric>"
        echo "OBSERVATION-DEGRADED $lane: malformed ready_for_review event id=$malformed_id_safe on #$pr_number"
    else
        state_set MALPROMO "$malpromo_key" "$malpromo_count" 1
        persist_state
    fi
    return 0
}

# Once a post-promotion window closes cleanly, WINDOW is deleted by design --
# the window itself really is over -- but poll_activity() (the only place
# that re-validates promotion identity against a freshly resolved
# promotion_epoch()) only ever runs while a WINDOW is active, because the
# main loop below gates the call on WINDOW existing. A PR withdrawn (gh pr
# ready --undo) and re-promoted at the same head, entirely between two polls
# and entirely AFTER its previous window already closed and was torn down,
# collapses back to the identical discover_pr() tuple: observe_pr() never
# notices it and never re-arms WINDOW, so without this check nothing in this
# file would ever detect it again -- the lane goes dormant for that PR
# forever, even though a brand-new promotion with its own legitimate window
# genuinely started.
#
# Called from the main loop only when there is currently no active WINDOW
# for the lane, so this never duplicates poll_activity()'s own per-poll
# promotion_epoch() re-check while a window is live. It further gates its one
# extra `gh api` call on discover_pr()'s own freshly observed PR tuple still
# reading as promoted (non-draft) at all: a dormant lane whose PR has since
# gone back to draft, was never promoted, or was observed some other way
# costs nothing extra here -- the added cost is bounded to one
# promotion_epoch() call per poll per lane that is BOTH windowless AND
# currently promoted, not one per poll for every lane that has ever been
# promoted.
#
# ARMED (see the header comment and poll_activity()) is what makes the
# comparison possible after WINDOW's own close/delete has already run: it
# persists the epoch:event_id identity of whichever promotion this lane's
# WINDOW was most recently armed from, and unlike WINDOW it survives a clean
# close. A freshly resolved epoch that still matches ARMED is the same
# promotion this lane already watched and closed -- stay dormant. One that
# differs (or no ARMED yet recorded) is a promotion this lane has not armed a
# window for yet -- arm a fresh one from it, exactly as poll_activity()'s own
# cold-start path would.
check_repromotion_after_close() {
    lane=$1
    repo=$2
    pr=$3
    now=$4
    [[ "$pr" =~ ^#([0-9]+)\ draft=false\ (OPEN|CLOSED|MERGED)\ head=[0-9A-Fa-f]{8,64}$ ]] || return 0
    promoted_pr=${BASH_REMATCH[1]}

    resolve_promotion "$lane" "$repo" "$promoted_pr"
    promotion_status=$?
    if [ "$promotion_status" -eq 10 ] || [ "$promotion_status" -eq 11 ]; then
        # No resolvable ready_for_review event this poll (10), or one exists
        # but is being withheld for the malformed-row bound (11) -- either
        # way ordinary GitHub eventual consistency, not a hard failure, and
        # this function never has an existing window to mishandle (called
        # only when there is none). Nothing to compare against yet; stay
        # dormant rather than arming from an unresolved or withheld epoch.
        return 0
    elif [ "$promotion_status" -ne 0 ]; then
        return 1
    fi
    since=$promo_since
    since_event_id=$promo_since_event_id

    armed_raw="$(state_get ARMED "$lane" || true)"
    IFS=: read -r armed_since armed_event_id <<<"$armed_raw"
    # Record the freshly resolved identity unconditionally, mirroring
    # poll_activity()'s own unconditional ARMED update, before deciding
    # whether it differs from what was previously armed.
    state_set ARMED "$lane" "$since:$since_event_id"

    if [ -n "$armed_raw" ] && [ "$since" = "$armed_since" ] && [ "$since_event_id" = "$armed_event_id" ]; then
        return 0
    fi

    until=$((since + post_promotion_seconds))
    state_set WINDOW "$lane" "$promoted_pr" "$until" "$since:$since_event_id"
    state_delete CLOSING "$lane"
    return 0
}

discover_pr() {
    repo=$1
    branch=$2
    payload="$(bounded "$timeout_seconds" gh pr list --repo "$repo" --head "$branch" --state all \
        --limit 1 --json number,isDraft,state,headRefOid)" || return 1
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
    if [[ "$pr" =~ ^#([0-9]+)\ draft=false\ (OPEN|CLOSED|MERGED)\ head=[0-9A-Fa-f]{8,64}$ ]]; then
        promoted_pr=${BASH_REMATCH[1]}
        if [ -z "$old_pr" ] || [[ "$old_pr" =~ draft=true\ OPEN(\ head=[0-9A-Fa-f]{8,64})?$ ]]; then
            state_set WINDOW "$lane" "$promoted_pr" "$((now + post_promotion_seconds))" ""
        fi
    fi
    persist_state
    head_oid=${pr##* head=}
    echo "PR $lane: ${pr%head=*}head=${head_oid:0:8}"
}

load_state
[ "$timeout_seconds" -gt 0 ] || {
    echo "lane-watch: timeout must be greater than zero" >&2
    exit 2
}
poll_count=0
while true; do
    now="$(date -u +%s)"
    if [ "$warned" -eq 0 ] && [ $((deadline - now)) -le 1800 ]; then
        remaining_minutes=$(((deadline - now + 59) / 60))
        warned=1
        persist_state
        echo "WALLCLOCK run: $remaining_minutes min to $deadline_iso cap"
    fi
    if [ "$now" -ge "$deadline" ]; then
        echo "WALLCLOCK run: deadline $deadline_iso reached"
        save_state || {
            echo "lane-watch: could not persist state to $state_file" >&2
            exit 1
        }
        exit 0
    fi

    agents_available=0
    if agents="$(bounded "$timeout_seconds" herdr agent list)" &&
        jq -e '.result.agents | type == "array"' >/dev/null 2>&1 <<<"$agents"; then
        agents_available=1
    fi

    for spec in "${specs[@]}"; do
        IFS=: read -r lane branch nonce repo extra <<<"$spec"
        agent_state=unknown
        if [ "$agents_available" -eq 1 ]; then
            agent_state="$(jq -r --arg lane "$lane" '.result.agents[]? | select(.name == $lane) | .agent_status' <<<"$agents" 2>/dev/null | tail -1)"
            agent_state=${agent_state:-absent}
            previous="$(state_get AGENT "$lane" || printf init)"
            if [ "$previous" != "$agent_state" ]; then
                state_set AGENT "$lane" "$agent_state"
                persist_state
                echo "AGENT $lane: $previous -> $agent_state"
            fi
        fi

        if [ "$workspace_root_explicit" -eq 1 ]; then
            report="$workspace_root/${repo#*/}/.worktrees/$lane/.lane-report.md"
        else
            report="$checkout_root/.worktrees/$lane/.lane-report.md"
        fi
        sentinel="$(sentinel_from_report "$report" "$nonce")"
        pane_only=0
        if [ -z "$sentinel" ]; then
            sentinel="$(sentinel_from_pane "$lane" "$nonce" "$agent_state")"
            [ -z "$sentinel" ] || pane_only=1
        fi
        sentinel_key="$lane:$sentinel"
        if [ -n "$sentinel" ] && ! state_get SENTINEL "$sentinel_key" >/dev/null; then
            state_set SENTINEL "$sentinel_key" 1
            persist_state
            if [ "$pane_only" -eq 1 ]; then
                echo "SENTINEL $lane: $sentinel (pane only)"
            else
                echo "SENTINEL $lane: $sentinel"
            fi
        fi

        if pane_visible="$(bounded "$timeout_seconds" herdr agent read "$lane" --source visible --lines 8)"; then
            if grep -Fq 'Usage limit reached' <<<"$pane_visible"; then
                if [ "$(state_get USAGE "$lane" || printf 0)" -eq 0 ]; then
                    state_set USAGE "$lane" 1
                    persist_state
                    echo "USAGE-PAUSED $lane"
                fi
            else
                state_set USAGE "$lane" 0
            fi
        fi

        # #1041 challenge r1 finding 1: a degraded lane never blocks a later
        # lane in specs[] -- observation_ready() is a pure state check (no
        # sleep), and a skipped endpoint simply falls through with no GitHub
        # call attempted at all this poll. #1041 challenge r1 finding
        # codex-3: each of the three endpoints below is gated and tracked
        # independently ("$lane:PR"/"$lane:REPROMO"/"$lane:ACTIVITY") rather
        # than sharing one per-lane episode, so PR discovery recovering (e.g.
        # on a restart) never silently resets a still-genuinely-failing
        # activity or promotion-identity episode. See
        # observation_ready()/observation_record_failure() above.
        if observation_ready "$lane:PR"; then
            now="$(date -u +%s)"
            if pr="$(discover_pr "$repo" "$branch")"; then
                observation_recover "$lane:PR"
                observe_pr "$lane" "$pr" "$now"

                active_pr="$(state_get WINDOW "$lane" || true)"
                # #1041 challenge r2 finding claude-1: an endpoint's episode
                # must never persist past the point where that endpoint
                # stops being reachable for this lane -- REPROMO is only
                # ever visited while no WINDOW exists, and ACTIVITY only
                # while one does. Without this, a REPROMO episode already
                # in progress when observe_pr() arms a WINDOW directly
                # (independent of REPROMO, e.g. a withdraw-then-re-promote)
                # sat parked: neither cleared nor retried, its wall-clock
                # give-up ticking unseen until a later, ordinary transient
                # failure at that now-unreachable-then-reachable-again site
                # exited the watcher with no fresh announcement. Clearing
                # here, every poll, the moment the OTHER site becomes
                # unreachable, means a parked episode's clock never
                # survives to matter.
                if [ -n "$active_pr" ]; then
                    observation_recover "$lane:REPROMO"
                else
                    observation_recover "$lane:ACTIVITY"
                fi
                if [ -z "$active_pr" ] && observation_ready "$lane:REPROMO"; then
                    now="$(date -u +%s)"
                    if check_repromotion_after_close "$lane" "$repo" "$pr" "$now"; then
                        observation_recover "$lane:REPROMO"
                        active_pr="$(state_get WINDOW "$lane" || true)"
                    else
                        observation_record_failure "$lane:REPROMO" "$lane" "GitHub promotion-identity observation failed for lane $lane" ||
                            observation_failed "GitHub promotion-identity observation failed for lane $lane"
                    fi
                fi
                if [ -n "$active_pr" ] && observation_ready "$lane:ACTIVITY"; then
                    now="$(date -u +%s)"
                    if poll_activity "$lane" "$repo" "$active_pr" "$now"; then
                        observation_recover "$lane:ACTIVITY"
                    else
                        observation_record_failure "$lane:ACTIVITY" "$lane" "GitHub activity observation failed for lane $lane" ||
                            observation_failed "GitHub activity observation failed for lane $lane"
                    fi
                fi
            else
                observation_record_failure "$lane:PR" "$lane" "GitHub PR observation failed for lane $lane" ||
                    observation_failed "GitHub PR observation failed for lane $lane"
            fi
        fi
    done

    persist_state
    poll_count=$((poll_count + 1))
    if [ "$iterations" -gt 0 ] && [ "$poll_count" -ge "$iterations" ]; then
        exit 0
    fi
    sleep "$interval_seconds"
done
