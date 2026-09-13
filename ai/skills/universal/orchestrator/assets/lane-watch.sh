#!/usr/bin/env bash
# Watch orchestrated lanes and emit stable, one-line transition events:
#   AGENT <lane>: <from> -> <to>
#   SENTINEL <lane>: <value>[ (pane only)]
#   PR <lane>: #<n> draft=<bool> <STATE>
#   POST-PROMOTION-ACTIVITY <lane>: <actor> <review|comment|inline> <id>
#   USAGE-PAUSED <lane>
#   WALLCLOCK <lane|run>: <text>
#
# Every herdr/gh call is bounded. Failures mean absent/no event; this watcher
# never writes through either CLI. Pass --state-file so a re-armed watcher does
# not repeat sentinels, transitions, or post-promotion activity.
set -u

usage() {
    cat <<'EOF'
Usage: lane-watch.sh [options] DEADLINE_ISO lane:branch:nonce[:owner/repo] ...

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
repo_root="$(cd "$script_dir/../../../../.." && pwd)"
state_file=
registry="$repo_root/agent-registry.json"
workspace_root="$(dirname "$repo_root")"
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
        --workspace-root) workspace_root=$2 ;;
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

declare -A prev_agent prev_pr usage_paused seen_sentinel
declare -A window_pr window_until seen_activity
warned=0

load_state() {
    [ -n "$state_file" ] && [ -f "$state_file" ] || return 0
    while IFS=$'\t' read -r kind lane value extra; do
        case "$kind" in
        AGENT) prev_agent["$lane"]=$value ;;
        SENTINEL) seen_sentinel["$lane:$value"]=1 ;;
        PR) prev_pr["$lane"]=$value ;;
        USAGE) usage_paused["$lane"]=$value ;;
        WINDOW)
            window_pr["$lane"]=$value
            window_until["$lane"]=$extra
            ;;
        ACTIVITY) seen_activity["$lane:$value:$extra"]=1 ;;
        WALLCLOCK) warned=$value ;;
        esac
    done <"$state_file"
}

save_state() {
    [ -n "$state_file" ] || return 0
    state_dir="$(dirname "$state_file")"
    [ -d "$state_dir" ] || mkdir -p "$state_dir" || return 0
    state_tmp="${state_file}.tmp.$$"
    {
        for lane in "${!prev_agent[@]}"; do
            printf 'AGENT\t%s\t%s\t\n' "$lane" "${prev_agent[$lane]}"
        done
        for key in "${!seen_sentinel[@]}"; do
            lane=${key%%:*}
            sentinel=${key#*:}
            printf 'SENTINEL\t%s\t%s\t\n' "$lane" "$sentinel"
        done
        for lane in "${!prev_pr[@]}"; do
            printf 'PR\t%s\t%s\t\n' "$lane" "${prev_pr[$lane]}"
        done
        for lane in "${!usage_paused[@]}"; do
            printf 'USAGE\t%s\t%s\t\n' "$lane" "${usage_paused[$lane]}"
        done
        for lane in "${!window_pr[@]}"; do
            printf 'WINDOW\t%s\t%s\t%s\n' "$lane" "${window_pr[$lane]}" "${window_until[$lane]}"
        done
        for key in "${!seen_activity[@]}"; do
            lane=${key%%:*}
            rest=${key#*:}
            kind=${rest%%:*}
            id=${rest#*:}
            printf 'ACTIVITY\t%s\t%s\t%s\n' "$lane" "$kind" "$id"
        done
        printf 'WALLCLOCK\trun\t%s\t\n' "$warned"
    } >"$state_tmp" || return 0
    mv "$state_tmp" "$state_file" 2>/dev/null || true
}

bounded() {
    seconds=$1
    shift
    "$timeout_bin" "$seconds" "$@" </dev/null 2>/dev/null
}

trusted_actor_ids="$(jq -r '.finders[]? | .trusted_actor_id // empty | tostring' "$registry" 2>/dev/null || true)"

sentinel_from_report() {
    report=$1
    nonce=$2
    [ -f "$report" ] || return 0
    grep -E "^LANE-[A-Z0-9-]+-(READY|BLOCKED)-${nonce}$" "$report" 2>/dev/null | tail -1
}

sentinel_from_pane() {
    lane=$1
    nonce=$2
    pane="$(bounded "$timeout_seconds" herdr agent read "$lane" --source recent-unwrapped --lines 80 || true)"
    grep -E "^LANE-[A-Z0-9-]+-(READY|BLOCKED)-${nonce}$" <<<"$pane" 2>/dev/null | tail -1
}

activity_rows() {
    repo=$1
    pr_number=$2
    kind=$3
    endpoint=$4
    payload="$(bounded "$timeout_seconds" gh api --paginate --slurp "$endpoint" || true)"
    [ -n "$payload" ] || return 0
    jq -r --arg kind "$kind" --arg trusted "$trusted_actor_ids" '
      (if (.[0]? | type) == "array" then add else . end)[]?
      | (.user.id | tostring) as $actor_id
      | select(.user.type == "User" or ($trusted | split("\n") | index($actor_id)))
      | [.user.login, $kind, (.id | tostring)] | @tsv
    ' <<<"$payload" 2>/dev/null || true
}

poll_activity() {
    lane=$1
    repo=$2
    pr_number=$3
    now=$4
    until=${window_until[$lane]:-0}
    [ "$now" -le "$until" ] || {
        unset 'window_pr[$lane]' 'window_until[$lane]'
        return 0
    }

    while IFS=$'\t' read -r actor kind id; do
        [ -n "$id" ] || continue
        key="$lane:$kind:$id"
        if [ -z "${seen_activity[$key]:-}" ]; then
            echo "POST-PROMOTION-ACTIVITY $lane: $actor $kind $id"
            seen_activity[$key]=1
        fi
    done < <(
        activity_rows "$repo" "$pr_number" review "repos/$repo/pulls/$pr_number/reviews?per_page=100"
        activity_rows "$repo" "$pr_number" comment "repos/$repo/issues/$pr_number/comments?per_page=100"
        activity_rows "$repo" "$pr_number" inline "repos/$repo/pulls/$pr_number/comments?per_page=100"
    )
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
        echo "WALLCLOCK run: 30 min to $deadline_iso cap"
        warned=1
    fi
    if [ "$now" -ge "$deadline" ]; then
        echo "WALLCLOCK run: deadline $deadline_iso reached"
        save_state
        exit 0
    fi

    agents="$(bounded "$timeout_seconds" herdr agent list || true)"
    [ -n "$agents" ] || agents='{}'

    for spec in "${specs[@]}"; do
        IFS=: read -r lane branch nonce repo extra <<<"$spec"
        if [ -z "${lane:-}" ] || [ -z "${branch:-}" ] || [ -z "${nonce:-}" ] || [ -n "${extra:-}" ]; then
            echo "lane-watch: invalid lane spec: $spec" >&2
            continue
        fi
        repo=${repo:-evanharmon1/harmon-devkit}
        case "$repo" in
        */*) ;;
        *)
            echo "lane-watch: invalid repository in spec: $spec" >&2
            continue
            ;;
        esac

        agent_state="$(jq -r --arg lane "$lane" '.result.agents[]? | select(.name == $lane) | .agent_status' <<<"$agents" 2>/dev/null | tail -1)"
        agent_state=${agent_state:-absent}
        previous=${prev_agent[$lane]:-init}
        if [ "$previous" != "$agent_state" ]; then
            echo "AGENT $lane: $previous -> $agent_state"
            prev_agent[$lane]=$agent_state
        fi

        report="$workspace_root/${repo#*/}/.worktrees/$lane/.lane-report.md"
        sentinel="$(sentinel_from_report "$report" "$nonce")"
        pane_only=0
        if [ -z "$sentinel" ]; then
            sentinel="$(sentinel_from_pane "$lane" "$nonce")"
            [ -z "$sentinel" ] || pane_only=1
        fi
        sentinel_key="$lane:$sentinel"
        if [ -n "$sentinel" ] && [ -z "${seen_sentinel[$sentinel_key]:-}" ]; then
            if [ "$pane_only" -eq 1 ]; then
                echo "SENTINEL $lane: $sentinel (pane only)"
            else
                echo "SENTINEL $lane: $sentinel"
            fi
            seen_sentinel[$sentinel_key]=1
        fi

        pane_visible="$(bounded "$timeout_seconds" herdr agent read "$lane" --source visible --lines 8 || true)"
        if grep -Fq 'Usage limit reached' <<<"$pane_visible"; then
            if [ "${usage_paused[$lane]:-0}" -eq 0 ]; then
                echo "USAGE-PAUSED $lane"
                usage_paused[$lane]=1
            fi
        else
            usage_paused[$lane]=0
        fi

        pr="$(bounded "$timeout_seconds" gh pr list --repo "$repo" --head "$branch" --state all --json number,isDraft,state \
            -q 'if length > 0 then .[0] | "#\(.number) draft=\(.isDraft) \(.state)" else empty end' || true)"
        if [ -n "$pr" ] && [ "${prev_pr[$lane]:-}" != "$pr" ]; then
            old_pr=${prev_pr[$lane]:-}
            echo "PR $lane: $pr"
            prev_pr[$lane]=$pr
            if [[ "$pr" =~ ^#([0-9]+)\ draft=false\ OPEN$ ]]; then
                promoted_pr=${BASH_REMATCH[1]}
                if [[ "$old_pr" =~ draft=true\ OPEN$ ]]; then
                    window_pr[$lane]=$promoted_pr
                    window_until[$lane]=$((now + post_promotion_seconds))
                fi
            fi
        fi

        # Seed activity while the PR is still draft. The first ready-state poll
        # can then report anything that arrived after the last draft snapshot,
        # including activity racing the promotion transition itself.
        if [[ "$pr" =~ ^#([0-9]+)\ draft=true\ OPEN$ ]]; then
            draft_pr=${BASH_REMATCH[1]}
            while IFS=$'\t' read -r _actor kind id; do
                [ -z "$id" ] || seen_activity["$lane:$kind:$id"]=1
            done < <(
                activity_rows "$repo" "$draft_pr" review "repos/$repo/pulls/$draft_pr/reviews?per_page=100"
                activity_rows "$repo" "$draft_pr" comment "repos/$repo/issues/$draft_pr/comments?per_page=100"
                activity_rows "$repo" "$draft_pr" inline "repos/$repo/pulls/$draft_pr/comments?per_page=100"
            )
        fi

        if [ -n "${window_pr[$lane]:-}" ]; then
            poll_activity "$lane" "$repo" "${window_pr[$lane]}" "$now"
        fi
    done

    save_state
    poll_count=$((poll_count + 1))
    if [ "$iterations" -gt 0 ] && [ "$poll_count" -ge "$iterations" ]; then
        exit 0
    fi
    sleep "$interval_seconds"
done
