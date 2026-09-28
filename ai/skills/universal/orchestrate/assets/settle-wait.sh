#!/usr/bin/env bash
# Unit-safe, bounded waits for an orchestrator: a herdr lane settle and a PR's
# GitHub Actions settle. Both take SECONDS and both report their verdict only
# through the exit status (see --help), so a wait that expired can never read
# as settled.
#
# Why this exists:
# - `herdr agent wait --timeout` and `herdr agent prompt --wait --timeout` take
#   MILLISECONDS. A `--timeout 3600` meant as an hour expires in 3.6s, and a
#   trailing `; echo` then makes the expiry look like a settle. `agent` mode
#   converts seconds to herdr's millisecond flag and never masks its status.
# - The watch-style GitHub CLI verbs (the run-watch and pr-checks watch modes)
#   report stale or partial conclusions across re-run attempts: one reported
#   attempt 3 as a success while it was still queued, another exited on a
#   previous attempt's failure. `checks` mode never calls them; it reads each
#   run's own `.status` and `.conclusion` from the REST run endpoint on every
#   poll, for the exact head the caller pushed. A `pull_request` run of this
#   PR superseded by a newer run of the same workflow is dropped once its own
#   read says completed and its latest attempt started before the newest run
#   did, so a cancelled or failed run a re-run replaced cannot pin it red, while
#   an older run manually re-run after the newest one started still counts; a
#   sibling PR's run on the same head is ignored, and every run of any other
#   event counts.
#
# Portable to bash 3.2 (macOS): no arrays of arrays, no mapfile, no GNU-only
# date or sleep flags. GNU `timeout` (or Homebrew `gtimeout`) bounds every
# external call, exactly as lane-watch.sh requires.
set -u

readonly EXIT_SETTLED=0
readonly EXIT_FAILING=1
readonly EXIT_USAGE=2
readonly EXIT_INDETERMINATE=3
readonly EXIT_EXPIRED=4
readonly EXIT_AGENT_UNSETTLED=5

usage() {
    cat <<'EOF'
Usage:
  settle-wait.sh agent LANE --timeout-seconds N [--until STATE]
  settle-wait.sh checks --repo OWNER/REPO --pr N --head SHA --timeout-seconds N
                        [--interval-seconds N] [--call-timeout-seconds N]
                        [--per-page N]

Every duration is in SECONDS.

agent   Wait for a herdr lane agent to settle. Runs
        `herdr agent wait LANE --timeout <N*1000>` (herdr's flag is
        milliseconds; the conversion happens here), which returns on herdr's
        default settled set: idle, done, or blocked. It then reads the
        lane's state with `herdr agent get LANE` and settles only on `idle`
        (tab seen) or `done` (the same state, unseen); `blocked`, `unknown`,
        or a state it cannot read is not settled. With --until STATE it
        waits for that one state instead and settles when herdr does. A GNU
        timeout backstop of N+30s kills a herdr that overruns its own
        timeout.
        Confirm a prompt was delivered first (`herdr agent prompt LANE "..."
        --wait --until working --timeout <ms>`), or this can settle on the
        idle state the lane was in before the prompt landed.

checks  Wait for the GitHub Actions runs on the head you pushed to settle.
        --head is REQUIRED: the full 40-hex SHA you pushed. While the PR
        still reports another head (GitHub lags after a push) the poll is
        not settled. Each poll lists the runs for exactly --head (paged
        explicitly until a short page, up to enough pages to cover GitHub's
        1000-run search cap at --per-page; a list reporting 1000 or more
        runs is indeterminate). A `pull_request` or
        `pull_request_target` run is scoped to --pr by its pull_requests[]:
        one naming only other PRs is ignored; one naming exactly --pr joins
        its workflow's group; one with an empty or unprovable association
        (fork PRs list none, a shared head can list this PR beside another)
        is counted on its own and never collapsed or used to supersede. In
        each group it keeps the NEWEST run -- highest run_number, then
        created_at, then id -- and reads each older run on its own, dropping
        it only when that read says completed AND its latest attempt started
        (run_started_at, else created_at) before the newest run's did, so a
        cancelled or failed run a re-run replaced no longer counts. One whose
        read is not completed stays pending; one re-run after the newest run
        started, or whose start time either read lacks, counts normally and
        its conclusion decides. Every run of any other event counts.
        It reads each counted run's own `.status`, `.conclusion`, and
        `.run_attempt`. The PR head is re-read after the run reads; a
        settle is reported only if it still equals --head. Settled means
        every counted run is `completed`; `skipped` runs are completed and
        never counted as pending. Like GitHub's own check rollup, the newest
        pull_request run is the verdict even when its jobs were skipped, so
        a workflow that skips its tests on an `edited` re-run can hide an
        earlier failure: the readiness gate owns the final verdict.
        Covers Actions workflow runs
        only, not external status checks, and cannot see a run GitHub has
        not created yet.
        --interval-seconds  poll interval (default 30)
        --call-timeout-seconds  bound on each gh call (default 30); the last
                            poll may overrun the deadline by at most about two
                            call timeouts: no new read starts once the deadline
                            plus one call timeout has passed, and that poll is
                            then indeterminate
        --per-page  runs listed per page (default 100; tests)

Exit status, agent mode:
  0    settled: the lane is idle or done (with --until: herdr reached STATE)
  5    herdr's wait returned, but the lane is blocked at an approval or
       question, unknown, or its state could not be read: NOT settled
  any other non-zero status is herdr's own, unmodified, and NOT settled
  (herdr uses 1 for a server error and 2 for a usage error, which overlap
  the checks codes below and mean something different), and 124 when the
  backstop stopped a herdr that overran its own timeout (137 if it had to
  be killed). 2 is also this script's own usage error.

Exit status, checks mode:
  0    settled: every newest run completed with success, neutral or skipped
  1    settled, but at least one newest run failed (FAILING lines name them)
  2    usage error, or a required tool is missing
  3    indeterminate at expiry: the PR head was not --head at the last poll,
       or that poll could not be read, listed no runs, or hit GitHub's
       1000-run search cap; never a settle
  4    expired: the timeout passed with runs on --head still pending

Never follow a wait with `; echo`, `|| true`, or anything else that discards
this status.
EOF
}

die_usage() {
    echo "settle-wait: $*" >&2
    exit "$EXIT_USAGE"
}

positive_int() {
    case "$1" in
    '' | *[!0-9]* | 0*) return 1 ;;
    esac
    return 0
}

# A duration in seconds: a positive integer no larger than one day, so no
# later arithmetic (the seconds-to-milliseconds conversion) can overflow.
# Identifiers such as --pr use positive_int, which has no such cap.
seconds_value() {
    positive_int "$1" && [ "${#1}" -le 5 ] && [ "$1" -le 86400 ]
}

now() {
    date -u +%s
}

timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

[ "$#" -gt 0 ] || {
    usage >&2
    exit "$EXIT_USAGE"
}
case "$1" in
-h | --help)
    usage
    exit 0
    ;;
esac
mode=$1
shift

timeout_seconds=
case "$mode" in
agent)
    lane=
    until_state=
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --timeout-seconds)
            [ "$#" -ge 2 ] || die_usage "--timeout-seconds needs a value"
            timeout_seconds=$2
            shift 2
            ;;
        --until)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "--until needs a value"
            until_state=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*) die_usage "unknown agent option: $1" ;;
        *)
            [ -z "$lane" ] || die_usage "unexpected argument: $1"
            lane=$1
            shift
            ;;
        esac
    done
    [ -n "$lane" ] || die_usage "agent mode needs a LANE"
    seconds_value "$timeout_seconds" ||
        die_usage "--timeout-seconds must be a positive integer of seconds"
    case "$until_state" in
    *[!a-z_]*) die_usage "invalid --until state: $until_state" ;;
    esac
    [ -n "$timeout_bin" ] || die_usage "GNU timeout (timeout or gtimeout) is required"
    command -v herdr >/dev/null 2>&1 || die_usage "herdr is not on PATH"
    command -v jq >/dev/null 2>&1 || die_usage "jq is not on PATH"

    timeout_ms=$((timeout_seconds * 1000))
    if [ -n "$until_state" ]; then
        set -- herdr agent wait "$lane" --until "$until_state" --timeout "$timeout_ms"
    else
        set -- herdr agent wait "$lane" --timeout "$timeout_ms"
    fi
    "$timeout_bin" --kill-after=5 "$((timeout_seconds + 30))" "$@"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "NOT-SETTLED agent $lane: herdr exited $status"
        exit "$status"
    fi
    if [ -n "$until_state" ]; then
        echo "SETTLED agent $lane"
        exit 0
    fi
    # herdr's default settled set is idle, done and blocked, so its 0 does
    # not say which: read the state and settle only on idle (tab seen) or
    # done (the same state, unseen). Anything else -- blocked at an approval
    # or question, unknown, or a state that cannot be read -- is not settled.
    state="$("$timeout_bin" --kill-after=2 30 herdr agent get "$lane" </dev/null 2>/dev/null |
        jq -r '[.result.agent.agent_status?, .result.agent_status?, .agent_status?]
               | map(select(type == "string")) | first // empty' 2>/dev/null)" || state=
    case "$state" in
    idle | done)
        echo "SETTLED agent $lane state=$state"
        exit 0
        ;;
    esac
    echo "NOT-SETTLED agent $lane: state=${state:-unreadable} (not idle or done)"
    exit "$EXIT_AGENT_UNSETTLED"
    ;;
checks) ;;
*) die_usage "unknown mode: $mode (expected agent or checks)" ;;
esac

repo=
pr=
want_head=
interval_seconds=30
call_timeout_seconds=30
per_page=100
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --head | --timeout-seconds | --interval-seconds | --call-timeout-seconds | --per-page)
        [ "$#" -ge 2 ] || die_usage "$1 needs a value"
        case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --head) want_head=$2 ;;
        --timeout-seconds) timeout_seconds=$2 ;;
        --interval-seconds) interval_seconds=$2 ;;
        --call-timeout-seconds) call_timeout_seconds=$2 ;;
        --per-page) per_page=$2 ;;
        esac
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die_usage "unknown checks argument: $1" ;;
    esac
done
case "$repo" in
*/*/* | /* | */ | *[!A-Za-z0-9._/-]*) die_usage "--repo must be OWNER/REPO" ;;
*/*) ;;
*) die_usage "--repo must be OWNER/REPO" ;;
esac
positive_int "$pr" || die_usage "--pr must be a positive integer"
case "$want_head" in
'' | *[!0-9a-f]*) die_usage "--head must be the full 40-hex SHA you pushed" ;;
esac
[ "${#want_head}" -eq 40 ] || die_usage "--head must be the full 40-hex SHA you pushed"
seconds_value "$timeout_seconds" ||
    die_usage "--timeout-seconds must be a positive integer of seconds"
seconds_value "$interval_seconds" ||
    die_usage "--interval-seconds must be a positive integer of seconds"
seconds_value "$call_timeout_seconds" ||
    die_usage "--call-timeout-seconds must be a positive integer of seconds"
if ! positive_int "$per_page" || [ "$per_page" -gt 100 ]; then
    die_usage "--per-page must be an integer from 1 to 100"
fi
[ -n "$timeout_bin" ] || die_usage "GNU timeout (timeout or gtimeout) is required"
command -v gh >/dev/null 2>&1 || die_usage "gh is not on PATH"
command -v jq >/dev/null 2>&1 || die_usage "jq is not on PATH"

# Enough pages to traverse every result under GitHub's 1000-run cap at this
# page size, plus the short (possibly empty) page that ends the listing.
max_pages=$(((1000 + per_page - 1) / per_page + 1))
deadline=$(($(now) + timeout_seconds))
# The hard ceiling on any one poll: the last poll may still classify what it
# reads past the deadline, but never for longer than one more call timeout, so
# a head with many runs on a slow API cannot stretch the wait by hours. A poll
# that reaches it stops reading and is indeterminate.
hard_deadline=$((deadline + call_timeout_seconds))
short=${want_head:0:8}

past_hard_deadline() {
    [ "$(now)" -ge "$hard_deadline" ]
}

# One bounded REST read, always given the full --call-timeout-seconds: a call
# is never clamped to the time left before the deadline, so the final poll can
# still classify what it reads (the last poll may overrun the deadline, by at
# most that one poll) instead of timing out into an indeterminate verdict.
api() {
    "$timeout_bin" --kill-after=2 "$call_timeout_seconds" gh api "$1" </dev/null 2>/dev/null
}

head_sha() {
    local body sha
    body="$(api "repos/$repo/pulls/$pr")" || return 1
    sha="$(printf '%s' "$body" | jq -r '.head.sha // empty' 2>/dev/null)" || return 1
    case "$sha" in
    '' | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#sha}" -eq 40 ] || return 1
    printf '%s\n' "$sha"
}

# Every run to consider for exactly this head, one token per line, then a
# final "other_pr=N" line. "C:ID" is a run to count. "S:ID:NEWEST" is a
# pull_request run superseded by the newer run NEWEST of the same workflow and
# event for this PR (a cancelled `pull_request` run replaced by its `edited`
# re-run, a failed guard that passed after a body edit): the caller reads it
# on its own and drops it only if that read says completed and its latest
# attempt started before NEWEST did, since the list can lag a re-run of it.
# Every C line precedes every S line, so NEWEST has been read by then. Paged by an explicit &page=K until a short page; never gh's
# own --paginate. Returns 2 when the list reports GitHub's 1000-run search
# cap, which it cannot page past, and 1 on any other failure.
newest_run_ids() {
    local page rows body listed_total page_rows count
    page=1
    rows=
    while :; do
        [ "$page" -le "$max_pages" ] || return 1
        ! past_hard_deadline || return 1
        body="$(api "repos/$repo/actions/runs?head_sha=$1&per_page=$per_page&page=$page")" ||
            return 1
        listed_total="$(printf '%s' "$body" | jq -r '.total_count | if type == "number" then . else error("no total_count") end' 2>/dev/null)" ||
            return 1
        [ "$listed_total" -lt 1000 ] || return 2
        page_rows="$(printf '%s' "$body" | jq -c --arg sha "$1" '
            if (.workflow_runs | type) != "array" then error("no workflow_runs")
            else .workflow_runs[]
              | if (.id | type) == "number" and .head_sha == $sha
                   and (.workflow_id | type) == "number"
                   and (.event | type) == "string"
                   and (.run_number | type) == "number"
                then {w: .workflow_id, e: .event, n: .run_number,
                      c: (.created_at // ""), id: .id,
                      p: (if (.pull_requests | type) == "array"
                          then [.pull_requests[] | .number?] else null end)}
                else error("foreign or malformed run") end
            end' 2>/dev/null)" || return 1
        count="$(printf '%s' "$body" | jq -r '.workflow_runs | length')" || return 1
        [ -z "$page_rows" ] || rows="$rows$page_rows
"
        [ "$count" -ge "$per_page" ] || break
        page=$((page + 1))
    done
    printf '%s' "$rows" | jq -rs --argjson pr "$pr" '
        # A pull_request / pull_request_target run belongs to this PR only
        # when its pull_requests[] names exactly --pr. The same head can back
        # a sibling PR: a run naming only other PRs is ignored, and a run with
        # an empty or unprovable association (fork PRs list none; a run
        # naming this PR beside another is shared) is counted on its own and
        # never collapsed or used to supersede. Only the runs of this PR are
        # replaced by a newer run of the same workflow (a push or an edit
        # re-runs it). For any other event two runs of one workflow on one
        # head run side by side (workflow_run fan-in, a branch and a tag push,
        # repeated dispatches), so every such run counts.
        def is_pr: .e == "pull_request" or .e == "pull_request_target";
        def scope:
            if (.p | type) != "array" or (.p | length) == 0
               or any(.p[]; type != "number") then "unproven"
            elif (.p | unique) == [$pr] then "ours"
            elif any(.p[]; . == $pr) then "unproven"
            else "other" end;
        (unique_by(.id)) as $all
        | ($all | map(select(is_pr) | . + {k: scope})) as $prs
        | ($prs | map(select(.k == "ours")) | group_by([.w, .e])
            | map(max_by([.n, .c, .id]) as $m
                  | {keep: $m.id, sup: map(select(.id != $m.id) | .id)})) as $groups
        | (($groups | map("C:\(.keep)")),
           ($prs | map(select(.k == "unproven") | "C:\(.id)")),
           ($all | map(select(is_pr | not) | "C:\(.id)")),
           ($groups | map(.keep as $k | .sup[] | "S:\(.):\($k)"))
           | .[]),
          "other_pr=\($prs | map(select(.k == "other")) | length)"'
}

last=indeterminate
detail="not polled"
poll=0
while :; do
    poll=$((poll + 1))
    verdict=
    if ! sha="$(head_sha)"; then
        last=indeterminate
        detail="could not read the PR head"
    elif [ "$sha" != "$want_head" ]; then
        last=head-mismatch
        detail="PR head ${sha:0:8} is not the pushed head $short"
    elif
        listed="$(newest_run_ids "$want_head")"
        list_rc=$?
        [ "$list_rc" -ne 0 ]
    then
        last=indeterminate
        if [ "$list_rc" -eq 2 ]; then
            detail="the run list for head $short reports 1000 or more runs (GitHub's search cap)"
        else
            detail="could not list the runs for head $short"
        fi
    else
        other_pr="${listed##*other_pr=}"
        ids="$(printf '%s\n' "$listed" | grep -v '^other_pr=' || true)"
        if [ -z "$ids" ]; then
            last=indeterminate
            detail="no runs listed for head $short"
        else
            total=0
            pending=0
            failing=0
            skipped=0
            superseded=0
            lines=
            read_failed=
            starts=
            for entry in $ids; do
                kind=${entry%%:*}
                id=${entry#*:}
                keep=
                if [ "$kind" = S ]; then
                    keep=${id#*:}
                    id=${id%%:*}
                fi
                if past_hard_deadline; then
                    read_failed=deadline
                    break
                fi
                body="$(api "repos/$repo/actions/runs/$id")" || {
                    read_failed=$id
                    break
                }
                row="$(printf '%s' "$body" | jq -r --arg sha "$want_head" '
                    if (.status | type) == "string" and .head_sha == $sha
                    then [.status, (.conclusion // "none"), (.run_attempt // 0 | tostring),
                          # The start of the current attempt as epoch seconds, or
                          # "none" when absent or unparseable.
                          ((.run_started_at // .created_at)
                           | if type == "string"
                             then (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | tostring)
                                   catch "none")
                             else "none" end),
                          ((.name // "unnamed") | gsub("[\t\n]"; " "))] | @tsv
                    else error("malformed run") end' 2>/dev/null)" || {
                    read_failed=$id
                    break
                }
                IFS=$'\t' read -r status conclusion attempt started name <<EOF
$row
EOF
                [ "$kind" = S ] || starts="$starts $id=$started "
                # A superseded run is dropped only on its own completed read
                # whose latest attempt started before the newest run's did.
                # One a re-run put back in flight still counts as pending, and
                # one re-run after the newest run started (or with a start
                # time either read lacks) counts on its own conclusion.
                if [ "$kind" = S ] && [ "$status" = completed ]; then
                    keep_started=none
                    case "$starts" in
                    *" $keep="*)
                        keep_started=${starts#*" $keep="}
                        keep_started=${keep_started%% *}
                        ;;
                    esac
                    if positive_int "$started" && positive_int "$keep_started" &&
                        [ "$started" -lt "$keep_started" ]; then
                        superseded=$((superseded + 1))
                        continue
                    fi
                fi
                total=$((total + 1))
                if [ "$status" != completed ]; then
                    pending=$((pending + 1))
                    lines="${lines}PENDING $id $name attempt=$attempt status=$status
"
                else
                    case "$conclusion" in
                    success | neutral) ;;
                    skipped) skipped=$((skipped + 1)) ;;
                    *)
                        failing=$((failing + 1))
                        lines="${lines}FAILING $id $name attempt=$attempt conclusion=$conclusion
"
                        ;;
                    esac
                fi
            done
            if [ -n "$read_failed" ]; then
                last=indeterminate
                if [ "$read_failed" = deadline ]; then
                    detail="the overall deadline passed mid-poll"
                else
                    detail="could not read run $read_failed"
                fi
            else
                echo "POLL $poll head=$short runs=$total pending=$pending failing=$failing skipped=$skipped superseded=$superseded other_pr=$other_pr"
                printf '%s' "$lines"
                if [ "$pending" -eq 0 ]; then
                    # Bind the verdict to the pushed head: re-read the PR
                    # head after the run reads and settle only if it is
                    # still --head.
                    if ! sha="$(head_sha)"; then
                        last=indeterminate
                        detail="could not re-read the PR head after the run reads"
                    elif [ "$sha" != "$want_head" ]; then
                        last=head-mismatch
                        detail="PR head moved to ${sha:0:8} during the poll; not the pushed head $short"
                    elif [ "$failing" -eq 0 ]; then
                        verdict=success
                    else
                        verdict=failure
                    fi
                else
                    last=pending
                    detail="$pending of $total runs pending on head $short"
                fi
            fi
        fi
    fi
    case "$verdict" in
    success)
        echo "SETTLED success head=$short runs=$total"
        exit "$EXIT_SETTLED"
        ;;
    failure)
        echo "SETTLED failure head=$short runs=$total failing=$failing"
        exit "$EXIT_FAILING"
        ;;
    esac
    [ "$last" = pending ] || echo "POLL $poll $last: $detail"
    remaining=$((deadline - $(now)))
    if [ "$remaining" -le 0 ]; then
        if [ "$last" = pending ]; then
            echo "EXPIRED after ${timeout_seconds}s: $detail"
            exit "$EXIT_EXPIRED"
        fi
        echo "INDETERMINATE at expiry: $detail"
        exit "$EXIT_INDETERMINATE"
    fi
    wait_for=$interval_seconds
    [ "$wait_for" -le "$remaining" ] || wait_for=$remaining
    sleep "$wait_for"
done
