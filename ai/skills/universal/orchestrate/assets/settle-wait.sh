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
#   poll, for the PR's exact head.
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
  settle-wait.sh agent LANE --timeout-seconds N [--until STATE]
  settle-wait.sh checks --repo OWNER/REPO --pr N --timeout-seconds N
                        [--interval-seconds N] [--call-timeout-seconds N]
                        [--per-page N]

Every duration is in SECONDS.

agent   Wait for a herdr lane agent to settle. Runs
        `herdr agent wait LANE [--until STATE] --timeout <N*1000>` (herdr's
        flag is milliseconds; the conversion happens here) and exits with
        herdr's own status, unmodified. A GNU timeout backstop of N+30s kills
        a herdr that overruns its own timeout; that exits 124.

checks  Wait for every GitHub Actions run on the PR's current head to settle.
        Each poll resolves the head SHA, lists the runs for exactly that SHA
        (paged explicitly until a short page), and reads each run's own
        `.status`, `.conclusion`, and `.run_attempt`. Settled means every run
        is `completed`; `skipped` runs are completed and never counted as
        pending. Covers Actions workflow runs only, not external status checks.
        --interval-seconds  poll interval (default 30)
        --call-timeout-seconds  bound on each gh call (default 30)
        --per-page  runs listed per page (default 100; tests)

Exit status:
  0    settled (checks: every run completed with success, neutral or skipped)
  1    checks: settled, but at least one run failed (FAILING lines name them)
  2    usage error, or a required tool is missing
  3    indeterminate: the head moved, or at expiry the last poll could not be
       read or listed no runs; never a settle
  4    expired: the timeout passed with runs still pending
  agent mode exits with herdr's status instead (non-zero on herdr's expiry).

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
    positive_int "$timeout_seconds" ||
        die_usage "--timeout-seconds must be a positive integer of seconds"
    if [ -n "$until_state" ]; then
        case "$until_state" in
        *[!a-z_]*) die_usage "invalid --until state: $until_state" ;;
        esac
    fi
    [ -n "$timeout_bin" ] || die_usage "GNU timeout (timeout or gtimeout) is required"
    command -v herdr >/dev/null 2>&1 || die_usage "herdr is not on PATH"

    timeout_ms=$((timeout_seconds * 1000))
    set -- herdr agent wait "$lane"
    [ -z "$until_state" ] || set -- "$@" --until "$until_state"
    set -- "$@" --timeout "$timeout_ms"
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
interval_seconds=30
call_timeout_seconds=30
per_page=100
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --timeout-seconds | --interval-seconds | --call-timeout-seconds | --per-page)
        [ "$#" -ge 2 ] || die_usage "$1 needs a value"
        case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
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
positive_int "$timeout_seconds" ||
    die_usage "--timeout-seconds must be a positive integer of seconds"
positive_int "$interval_seconds" ||
    die_usage "--interval-seconds must be a positive integer of seconds"
positive_int "$call_timeout_seconds" ||
    die_usage "--call-timeout-seconds must be a positive integer of seconds"
if ! positive_int "$per_page" || [ "$per_page" -gt 100 ]; then
    die_usage "--per-page must be an integer from 1 to 100"
fi
[ -n "$timeout_bin" ] || die_usage "GNU timeout (timeout or gtimeout) is required"
command -v gh >/dev/null 2>&1 || die_usage "gh is not on PATH"
command -v jq >/dev/null 2>&1 || die_usage "jq is not on PATH"

max_pages=50
deadline=$(($(now) + timeout_seconds))

# One bounded REST read. Never outlives the overall deadline by more than the
# kill grace, so a hung gh cannot hold the wait open past its expiry.
api() {
    bound=$call_timeout_seconds
    remaining=$((deadline - $(now)))
    [ "$remaining" -ge 1 ] || remaining=1
    [ "$bound" -le "$remaining" ] || bound=$remaining
    "$timeout_bin" --kill-after=2 "$bound" gh api "$1" </dev/null 2>/dev/null
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

# Every run id for exactly this head, one per line, de-duplicated. Paged by an
# explicit &page=K until a short page; never gh's own --paginate.
run_ids() {
    page=1
    ids=
    while :; do
        [ "$page" -le "$max_pages" ] || return 1
        body="$(api "repos/$repo/actions/runs?head_sha=$1&per_page=$per_page&page=$page")" ||
            return 1
        page_ids="$(printf '%s' "$body" | jq -r --arg sha "$1" '
            if (.workflow_runs | type) != "array" then error("no workflow_runs")
            else .workflow_runs[]
              | if (.id | type) == "number" and .head_sha == $sha then .id
                else error("foreign or malformed run") end
            end' 2>/dev/null)" || return 1
        count="$(printf '%s' "$body" | jq -r '.workflow_runs | length')" || return 1
        [ -z "$page_ids" ] || ids="$ids$page_ids
"
        [ "$count" -ge "$per_page" ] || break
        page=$((page + 1))
    done
    printf '%s' "$ids" | sort -u
}

last=indeterminate
detail="not polled"
poll=0
first_sha=
while :; do
    poll=$((poll + 1))
    verdict=
    if ! sha="$(head_sha)"; then
        last=indeterminate
        detail="could not read the PR head"
    elif [ -n "$first_sha" ] && [ "$sha" != "$first_sha" ]; then
        echo "INDETERMINATE head moved: ${first_sha:0:8} -> ${sha:0:8}"
        exit "$EXIT_INDETERMINATE"
    elif ! ids="$(run_ids "$sha")"; then
        [ -n "$first_sha" ] || first_sha=$sha
        last=indeterminate
        detail="could not list the runs for head ${sha:0:8}"
    elif [ -z "$ids" ]; then
        [ -n "$first_sha" ] || first_sha=$sha
        last=indeterminate
        detail="no runs listed for head ${sha:0:8}"
    else
        [ -n "$first_sha" ] || first_sha=$sha
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
            row="$(printf '%s' "$body" | jq -r --arg sha "$sha" '
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
            echo "POLL $poll head=${sha:0:8} runs=$total pending=$pending failing=$failing skipped=$skipped"
            printf '%s' "$lines"
            if [ "$pending" -eq 0 ] && [ "$failing" -eq 0 ]; then
                verdict=success
            elif [ "$pending" -eq 0 ]; then
                verdict=failure
            else
                last=pending
                detail="$pending of $total runs pending on head ${sha:0:8}"
            fi
        fi
    fi
    case "$verdict" in
    success)
        echo "SETTLED success head=${sha:0:8} runs=$total"
        exit "$EXIT_SETTLED"
        ;;
    failure)
        echo "SETTLED failure head=${sha:0:8} runs=$total failing=$failing"
        exit "$EXIT_FAILING"
        ;;
    esac
    [ "$last" = pending ] || echo "POLL $poll indeterminate: $detail"
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
