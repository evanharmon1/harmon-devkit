#!/usr/bin/env bash
# Watch orchestrated lanes and emit stable, one-line transition events:
#   AGENT <lane>: <from> -> <to>
#   SENTINEL <lane>: <value>[ (pane only)]
#   PR <lane>: #<n> draft=<bool> <STATE> head=<sha8>
#   POST-PROMOTION-ACTIVITY <lane>: <actor> <review|comment|inline> <id>
#   POST-PROMOTION-CLOSED <lane>: #<pr_number>
#   POST-PROMOTION-INDETERMINATE <lane>: #<pr_number>
#   USAGE-PAUSED <lane>
#   WALLCLOCK <lane|run>: <text>
#
# Timestamp-versioned activity keys may emit one duplicate when adopting legacy state.
# Clearing PR state on POST-PROMOTION-INDETERMINATE (so a later observation re-arms
# the window) also re-emits one identical PR line once that observation lands.
# Every herdr/gh call is bounded. Failures mean indeterminate/no event; this watcher
# never writes through either CLI. Pass --state-file so a re-armed watcher does
# not repeat sentinels, transitions, or post-promotion activity.
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
iterations=0

while [ "$#" -gt 0 ]; do
    case "$1" in
    --state-file | --registry | --workspace-root | --interval-seconds | --post-promotion-seconds | --timeout-seconds | --iterations)
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

case "$interval_seconds:$post_promotion_seconds:$timeout_seconds:$iterations" in
*[!0-9:]* | *::* | :* | *:)
    echo "lane-watch: interval, window, and iterations must be non-negative integers" >&2
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
        AGENT | PR | USAGE | CLOSING) state_set "$kind" "$lane" "$value" ;;
        SENTINEL) state_set SENTINEL "$lane:$value" 1 ;;
        WINDOW) state_set WINDOW "$lane" "$value" "$extra" "$detail" ;;
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
            AGENT | PR | USAGE | CLOSING)
                printf '%s\t%s\t%s\t\n' "$kind" "$key" "$value"
                ;;
            SENTINEL) printf 'SENTINEL\t%s\t%s\t\n' "${key%%:*}" "${key#*:}" ;;
            WINDOW) printf 'WINDOW\t%s\t%s\t%s\t%s\n' "$key" "$value" "$extra" "$detail" ;;
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
    jq -r --arg kind "$kind" --arg trusted "$trusted_actor_ids" '
      (if (.[0]? | type) == "array" then add else . end)[]?
      | (.user.id | tostring) as $actor_id
      | select(.user.type == "User" or ($trusted | split("\n") | index($actor_id)))
      | (if $kind == "review"
          then .submitted_at // .updated_at // .created_at
          else .updated_at // .created_at
        end // empty | fromdateiso8601) as $activity_at
      | [.user.login, $kind, (.id | tostring), ($activity_at | tostring)] | @tsv
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
    persisted_since="$(state_get WINDOW "$lane" detail || true)"
    persisted_until="$(state_get WINDOW "$lane" extra || printf 0)"
    cold_start=0
    [ -n "$persisted_since" ] || cold_start=1

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
    since="$(promotion_epoch "$repo" "$pr_number")"
    promotion_status=$?
    rearmed=0
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
        until=$persisted_until
    elif [ "$promotion_status" -ne 0 ]; then
        return 1
    else
        until=$((since + post_promotion_seconds))
        if [ "$cold_start" -eq 1 ] || [ "$since" != "$persisted_since" ]; then
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
        state_set WINDOW "$lane" "$pr_number" "$until" "$since"
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

    while IFS=$'\t' read -r actor kind id activity_at; do
        [ -n "$id" ] || continue
        [ "$activity_at" -ge "$since" ] || continue
        [ "$activity_at" -le "$until" ] || continue
        key="$lane:$kind:$id:$activity_at"
        if ! state_get ACTIVITY "$key" >/dev/null; then
            echo "POST-PROMOTION-ACTIVITY $lane: $actor $kind $id"
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
        echo "POST-PROMOTION-CLOSED $lane: #$pr_number"
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
    epoch="$(jq -r '
      (if (.[0]? | type) == "array" then add else . end)
      | map(select(.event == "ready_for_review") | .created_at | fromdateiso8601)
      | if length > 0 then max else empty end
    ' <<<"$payload" 2>/dev/null)" || return 1
    [ -n "$epoch" ] || return 10
    printf '%s' "$epoch"
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

        if ! pr="$(discover_pr "$repo" "$branch")"; then
            observation_failed "GitHub PR observation failed for lane $lane"
        fi
        observe_pr "$lane" "$pr" "$now"

        active_pr="$(state_get WINDOW "$lane" || true)"
        if [ -n "$active_pr" ]; then
            if ! poll_activity "$lane" "$repo" "$active_pr" "$now"; then
                observation_failed "GitHub activity observation failed for lane $lane"
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
