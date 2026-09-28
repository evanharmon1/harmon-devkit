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
#   poll, for the exact head the caller pushed. A completed `pull_request`
#   run superseded by a newer run of the same workflow is dropped, so a
#   cancelled or failed run a re-run replaced cannot pin it red; every run of
#   any other event counts.
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

usage() {
    cat <<'EOF'
Usage:
  settle-wait.sh agent LANE --until STATE --timeout-seconds N
  settle-wait.sh checks --repo OWNER/REPO --pr N --head SHA --timeout-seconds N
                        [--interval-seconds N] [--call-timeout-seconds N]
                        [--per-page N]

Every duration is in SECONDS.

agent   Wait for a herdr lane agent to settle. Runs
        `herdr agent wait LANE --until STATE --timeout <N*1000>` (herdr's
        flag is milliseconds; the conversion happens here). A GNU timeout
        backstop of N+30s kills a herdr that overruns its own timeout.
        Confirm a prompt was delivered first (`herdr agent prompt LANE "..."
        --wait --until working --timeout <ms>`), or this can settle on the
        idle state the lane was in before the prompt landed.

checks  Wait for the GitHub Actions runs on the head you pushed to settle.
        --head is REQUIRED: the full 40-hex SHA you pushed. While the PR
        still reports another head (GitHub lags after a push) the poll is
        not settled. Each poll lists the runs for exactly --head (paged
        explicitly until a short page). For `pull_request` and
        `pull_request_target` runs it keeps the NEWEST run of each workflow
        -- highest run_number, then created_at, then id -- and drops an
        older run once the run list reports it completed, so a cancelled
        or failed run a re-run replaced no longer counts; an older run
        still in flight stays pending. Every run of any other event counts.
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
                            poll may overrun the deadline by up to one call
                            timeout per call it makes (2 head reads, the list
                            pages, and one read per counted run)
        --per-page  runs listed per page (default 100; tests)

Exit status, agent mode:
  herdr's own status, unmodified: 0 settled, anything else NOT settled
  (herdr uses 1 for a server error and 2 for a usage error, which overlap
  the checks codes below and mean something different), and 124 when the
  backstop stopped a herdr that overran its own timeout (137 if it had to
  be killed). 2 is also this
  script's own usage error.

Exit status, checks mode:
  0    settled: every newest run completed with success, neutral or skipped
  1    settled, but at least one newest run failed (FAILING lines name them)
  2    usage error, or a required tool is missing
  3    indeterminate at expiry: the PR head was not --head at the last poll,
       or that poll could not be read or listed no runs; never a settle
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
            [ "$#" -ge 2 ] || die_usage "--until needs a value"
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
    # --until is required: herdr's default settled set includes `blocked`, so
    # a lane stopped at an approval prompt would otherwise read as settled.
    [ -n "$until_state" ] || die_usage "agent mode needs --until STATE"
    case "$until_state" in
    *[!a-z_]*) die_usage "invalid --until state: $until_state" ;;
    esac
    [ -n "$timeout_bin" ] || die_usage "GNU timeout (timeout or gtimeout) is required"
    command -v herdr >/dev/null 2>&1 || die_usage "herdr is not on PATH"

    timeout_ms=$((timeout_seconds * 1000))
    set -- herdr agent wait "$lane" --until "$until_state" --timeout "$timeout_ms"
    "$timeout_bin" --kill-after=5 "$((timeout_seconds + 30))" "$@"
    status=$?
    if [ "$status" -eq 0 ]; then
        echo "SETTLED agent $lane"
    else
        echo "NOT-SETTLED agent $lane: herdr exited $status"
    fi
    exit "$status"
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

max_pages=50
deadline=$(($(now) + timeout_seconds))
short=${want_head:0:8}

# One bounded REST read, always given the full --call-timeout-seconds: a call
# is never clamped to the time left before the deadline, so the final poll can
# still classify what it reads (the last poll may overrun the deadline, by at
# most that one poll) instead of timing out into an indeterminate verdict.
api() {
    "$timeout_bin" --kill-after=2 "$call_timeout_seconds" gh api "$1" </dev/null 2>/dev/null
}

head_sha() {
    body="$(api "repos/$repo/pulls/$pr")" || return 1
    sha="$(printf '%s' "$body" | jq -r '.head.sha // empty' 2>/dev/null)" || return 1
    case "$sha" in
    '' | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#sha}" -eq 40 ] || return 1
    printf '%s\n' "$sha"
}

# The id of every run to count for exactly this head, one per line, followed
# by a final "superseded=N" line. A completed pull_request run superseded by a
# later run of the same workflow and event (a cancelled
# `pull_request` run replaced by its `edited` re-run, a failed guard that
# passed after a body edit) is dropped here, so it is never read or counted.
# Paged by an explicit &page=K until a short page; never gh's own --paginate.
newest_run_ids() {
    page=1
    rows=
    while :; do
        [ "$page" -le "$max_pages" ] || return 1
        body="$(api "repos/$repo/actions/runs?head_sha=$1&per_page=$per_page&page=$page")" ||
            return 1
        page_rows="$(printf '%s' "$body" | jq -c --arg sha "$1" '
            if (.workflow_runs | type) != "array" then error("no workflow_runs")
            else .workflow_runs[]
              | if (.id | type) == "number" and .head_sha == $sha
                   and (.workflow_id | type) == "number"
                   and (.event | type) == "string"
                   and (.run_number | type) == "number"
                then {w: .workflow_id, e: .event, n: .run_number,
                      c: (.created_at // ""), id: .id, s: (.status // "")}
                else error("foreign or malformed run") end
            end' 2>/dev/null)" || return 1
        count="$(printf '%s' "$body" | jq -r '.workflow_runs | length')" || return 1
        [ -z "$page_rows" ] || rows="$rows$page_rows
"
        [ "$count" -ge "$per_page" ] || break
        page=$((page + 1))
    done
    printf '%s' "$rows" | jq -rs '
        # Only a pull_request / pull_request_target run is replaced by a newer
        # run of the same workflow (a push or an edit re-runs it), and only
        # once it has completed: a superseded run still in flight counts, since
        # without cancel-in-progress it can still fail. For any other event two
        # runs of one workflow on one head run side by side (workflow_run
        # fan-in, a branch and a tag push, repeated dispatches), so every such
        # run counts.
        (unique_by(.id)) as $all
        | ($all | map(select(.e == "pull_request" or .e == "pull_request_target"))
            | group_by([.w, .e])
            | map(max_by([.n, .c, .id]) as $m
                  | [$m] + map(select(.id != $m.id and .s != "completed")))
            | add // []) as $pr_newest
        | ($pr_newest + ($all | map(select(.e != "pull_request" and .e != "pull_request_target")))) as $newest
        | ($newest[] | .id), "superseded=\(($all | length) - ($newest | length))"'
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
    elif ! listed="$(newest_run_ids "$want_head")"; then
        last=indeterminate
        detail="could not list the runs for head $short"
    else
        superseded="${listed##*superseded=}"
        ids="$(printf '%s\n' "$listed" | grep -v '^superseded=' || true)"
        if [ -z "$ids" ]; then
            last=indeterminate
            detail="no runs listed for head $short"
        else
            total=0
            pending=0
            failing=0
            skipped=0
            lines=
            read_failed=
            for id in $ids; do
                body="$(api "repos/$repo/actions/runs/$id")" || {
                    read_failed=$id
                    break
                }
                row="$(printf '%s' "$body" | jq -r --arg sha "$want_head" '
                    if (.status | type) == "string" and .head_sha == $sha
                    then [.status, (.conclusion // "none"), (.run_attempt // 0 | tostring),
                          ((.name // "unnamed") | gsub("[\t\n]"; " "))] | @tsv
                    else error("malformed run") end' 2>/dev/null)" || {
                    read_failed=$id
                    break
                }
                IFS='	' read -r status conclusion attempt name <<EOF
$row
EOF
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
                detail="could not read run $read_failed"
            else
                echo "POLL $poll head=$short runs=$total pending=$pending failing=$failing skipped=$skipped superseded=$superseded"
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
