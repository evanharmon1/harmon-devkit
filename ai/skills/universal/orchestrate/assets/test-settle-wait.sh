#!/usr/bin/env bash
# Regression tests for settle-wait.sh: the seconds-to-milliseconds conversion
# for herdr lane settles, exit-status propagation, and the CI settle's reading
# of each run's own status across stale attempts, skipped floods, failures,
# empty lists, superseded runs of one workflow, a PR head that lags or moves
# away from the pushed --head, and a final poll that must not be clamped into
# indeterminacy. herdr and gh are stubs on PATH; nothing here reaches GitHub or
# a real herdr. Refs #1192.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wait_sh="$here/settle-wait.sh"
test_tmp="$(mktemp -d -t settle-wait-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

bin_dir="$test_tmp/bin"
fix="$test_tmp/fixtures"
mkdir -p "$bin_dir" "$fix"
export PATH="$bin_dir:$PATH" SW_FIX="$fix"

fail() {
    echo "FAIL: $*" >&2
    exit 1
    return 0
}

sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# herdr stub: `agent wait` exits SW_HERDR_RC; `agent get` prints the lane in
# state SW_HERDR_STATE (herdr's JSON shape), or SW_HERDR_GET verbatim.
cat >"$bin_dir/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SW_FIX/herdr.calls"
if [ "${1:-} ${2:-}" = "agent get" ]; then
    if [ -n "${SW_HERDR_GET+x}" ]; then
        printf '%s\n' "$SW_HERDR_GET"
    else
        printf '{"result":{"agent":{"name":"%s","agent_status":"%s"}}}\n' \
            "$3" "${SW_HERDR_STATE:-idle}"
    fi
    exit 0
fi
exit "${SW_HERDR_RC:-0}"
STUB

# gh stub: only `gh api <endpoint>` is served, from fixture files. Any other
# verb (the watch-style run/pr commands included) is logged and fails.
cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SW_FIX/gh.calls"
printf '%s\n' "$*" >>"$SW_FIX.all-calls"
[ "${1:-}" = api ] || exit 97
case "${3:-}" in
'') ;;
*) exit 98 ;;
esac
endpoint=$2
case "$endpoint" in
repos/o/r/pulls/7 | repos/o/r/pulls/100001)
    n="$(cat "$SW_FIX/pull.count" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" >"$SW_FIX/pull.count"
    if [ -f "$SW_FIX/pull.$n.json" ]; then
        cat "$SW_FIX/pull.$n.json"
    else
        cat "$SW_FIX/pull.json"
    fi
    ;;
'repos/o/r/actions/runs?'*)
    page=${endpoint##*page=}
    if [ -f "$SW_FIX/runs.$page.json" ]; then
        cat "$SW_FIX/runs.$page.json"
    else
        echo '{"total_count":0,"workflow_runs":[]}'
    fi
    ;;
repos/o/r/actions/runs/*)
    sleep "${SW_RUN_DELAY:-0}"
    id=${endpoint##*/}
    [ -f "$SW_FIX/run.$id.json" ] || exit 1
    cat "$SW_FIX/run.$id.json"
    ;;
*) exit 99 ;;
esac
STUB
chmod +x "$bin_dir/herdr" "$bin_dir/gh"

reset_fixtures() {
    rm -f "$fix"/*
    printf '{"head":{"sha":"%s"}}\n' "$sha_a" >"$fix/pull.json"
}

# run_json ID STATUS CONCLUSION ATTEMPT [SHA [WORKFLOW_ID EVENT RUN_NUMBER CREATED_AT [PR_NUMBERS]]]
# By default every run is its own workflow, so nothing supersedes anything,
# and every run is associated with PR 7 alone (PR_NUMBERS is a JSON array).
run_json() {
    jq -cn --argjson id "$1" --arg s "$2" --arg c "$3" --argjson a "$4" \
        --arg sha "${5:-$sha_a}" --argjson w "${6:-$1}" --arg e "${7:-pull_request}" \
        --argjson n "${8:-1}" --arg t "${9:-2026-09-27T00:00:00Z}" \
        --argjson prs "${10:-[7]}" \
        '{id: $id, name: ("wf-" + ($id|tostring)), head_sha: $sha, status: $s,
          conclusion: (if $c == "null" then null else $c end), run_attempt: $a,
          workflow_id: $w, event: $e, run_number: $n, created_at: $t,
          pull_requests: ($prs | map({number: .}))}'
}

# run_files ID...: each listed run's own read is its list entry.
run_files() {
    for id in "$@"; do
        jq -c --argjson id "$id" '.workflow_runs[] | select(.id == $id)' \
            "$fix/runs.1.json" >"$fix/run.$id.json"
    done
}

# write_page PAGE RUN_JSON...
write_page() {
    page=$1
    shift
    printf '%s\n' "$@" | jq -cs '{total_count: length, workflow_runs: .}' \
        >"$fix/runs.$page.json"
}

run_checks() {
    set +e
    out="$("$wait_sh" checks --repo o/r --pr 7 --head "$sha_a" "$@" 2>&1)"
    rc=$?
    set -e
}

# pull_head N SHA: the Nth read of the PR endpoint reports SHA.
pull_head() {
    printf '{"head":{"sha":"%s"}}\n' "$2" >"$fix/pull.$1.json"
}

expect_rc() {
    [ "$rc" -eq "$1" ] || fail "$2: expected exit $1, got $rc; output:
$out"
}

expect_out() {
    case "$out" in
    *"$1"*) ;;
    *) fail "$2: output lacks '$1':
$out" ;;
    esac
}

# ── agent mode ────────────────────────────────────────────────────────
run_agent() {
    set +e
    out="$("$wait_sh" agent "$@" 2>&1)"
    rc=$?
    set -e
}

# No --until: herdr's default settled set, then the state decides. idle and
# done (the unseen form of idle) settle.
for state in idle done; do
    reset_fixtures
    SW_HERDR_STATE=$state run_agent alpha --timeout-seconds 3600
    expect_rc 0 "agent settle on $state"
    [ "$(cat "$fix/herdr.calls")" = "agent wait alpha --timeout 3600000
agent get alpha" ] ||
        fail "herdr did not receive milliseconds, or the state was not read: $(cat "$fix/herdr.calls")"
    expect_out "SETTLED agent alpha state=$state" "agent settle on $state"
done

# blocked (an approval or question), unknown, and an unreadable state all
# return from herdr's default wait with 0, and none of them is a settle.
reset_fixtures
SW_HERDR_STATE=blocked run_agent alpha --timeout-seconds 5
expect_rc 5 "a blocked lane is not settled"
expect_out "NOT-SETTLED agent alpha: state=blocked" "blocked lane"
reset_fixtures
SW_HERDR_STATE=unknown run_agent alpha --timeout-seconds 5
expect_rc 5 "an unknown lane is not settled"
for get in '' 'not json' '{"result":{"agent":{"name":"alpha"}}}'; do
    reset_fixtures
    SW_HERDR_GET=$get run_agent alpha --timeout-seconds 5
    expect_rc 5 "an unreadable state ('$get') is not settled"
    expect_out "state=unreadable" "unreadable state"
done

# --until STATE: the state-specific wait passes through, no state read.
reset_fixtures
SW_HERDR_STATE=idle run_agent beta --until blocked --timeout-seconds 5
expect_rc 0 "--until settles when herdr does"
[ "$(cat "$fix/herdr.calls")" = "agent wait beta --until blocked --timeout 5000" ] ||
    fail "--until not forwarded before --timeout: $(cat "$fix/herdr.calls")"

# herdr's own non-zero status is propagated, with or without --until, and
# the state is never read over it.
for until in '' '--until idle'; do
    reset_fixtures
    # shellcheck disable=SC2086 # $until is deliberately split
    SW_HERDR_RC=7 run_agent alpha $until --timeout-seconds 2
    expect_rc 7 "herdr's non-zero status is propagated ($until)"
    expect_out "NOT-SETTLED agent alpha: herdr exited 7" "agent expiry"
    if grep -q '^agent get' "$fix/herdr.calls"; then
        fail "the state was read over herdr's non-zero status"
    fi
done

reset_fixtures
for bad in 0 -5 1.5 abc 08 '' 86401 99999999999999999999; do
    set +e
    "$wait_sh" agent alpha --timeout-seconds "$bad" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "--timeout-seconds '$bad' accepted (exit $rc)"
done
for args in 'alpha' 'alpha --timeout-seconds 5 --until' 'alpha --timeout-seconds 5 --until Idle'; do
    set +e
    # shellcheck disable=SC2086 # $args is deliberately split
    "$wait_sh" agent $args >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "agent $args accepted (exit $rc)"
done
set +e
"$wait_sh" agent alpha --timeout-seconds 5 --until '' >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "an empty --until accepted (exit $rc)"
[ ! -s "$fix/herdr.calls" ] || fail "herdr was called on a usage error"

# ── checks mode ───────────────────────────────────────────────────────
# A PR number is an identifier, not a duration: it has no one-day cap.
reset_fixtures
write_page 1 "$(run_json 1 completed success 1 "$sha_a" 1 pull_request 1 2026-09-27T00:00:00Z '[100001]')"
run_files 1
set +e
"$wait_sh" checks --repo o/r --pr 100001 --head "$sha_a" --timeout-seconds 5 --interval-seconds 1 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "a PR number above 86400 was refused (exit $rc)"

# All completed: success, neutral, and skipped all settle green.
reset_fixtures
write_page 1 "$(run_json 11 completed success 1)" \
    "$(run_json 12 completed skipped 1)" "$(run_json 13 completed neutral 1)"
for id in 11 12 13; do
    jq -c --argjson id "$id" '.workflow_runs[] | select(.id == $id)' \
        "$fix/runs.1.json" >"$fix/run.$id.json"
done
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 0 "all completed"
expect_out "SETTLED success head=aaaaaaaa runs=3" "all completed"

# Stale attempt: the list still shows attempt 2's conclusion, but the run's
# own read is attempt 3, queued. Not settled; expiry exits non-zero.
reset_fixtures
write_page 1 "$(run_json 21 completed success 2)" "$(run_json 22 completed success 1)"
run_json 21 queued null 3 >"$fix/run.21.json"
run_json 22 completed success 1 >"$fix/run.22.json"
run_checks --timeout-seconds 1 --interval-seconds 1
expect_rc 4 "stale attempt must expire, not settle"
expect_out "PENDING 21 wf-21 attempt=3 status=queued" "stale attempt"
expect_out "EXPIRED after 1s" "stale attempt"
case "$out" in *SETTLED*) fail "stale attempt reported SETTLED: $out" ;; esac

# Skipped flood: a full first page of skipped runs, the in-progress run on
# page 2. Not settled.
reset_fixtures
page1=()
for id in 101 102 103 104 105; do
    page1+=("$(run_json "$id" completed skipped 1)")
    run_json "$id" completed skipped 1 >"$fix/run.$id.json"
done
write_page 1 "${page1[@]}"
write_page 2 "$(run_json 106 in_progress null 1)"
run_json 106 in_progress null 1 >"$fix/run.106.json"
run_checks --timeout-seconds 1 --interval-seconds 1 --per-page 5
expect_rc 4 "skipped flood must not hide page 2"
expect_out "runs=6 pending=1 failing=0 skipped=5" "skipped flood"
expect_out "PENDING 106" "skipped flood"
grep -Fq 'per_page=5&page=2' "$fix/gh.calls" || fail "page 2 was never requested"
if grep -Fq -- '--paginate' "$fix/gh.calls"; then
    fail "gh --paginate was used"
fi

# Failure conclusion: settled, reported, exit 1.
reset_fixtures
write_page 1 "$(run_json 31 completed success 1)" "$(run_json 32 completed failure 2)"
run_json 31 completed success 1 >"$fix/run.31.json"
run_json 32 completed failure 2 >"$fix/run.32.json"
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 1 "failing run"
expect_out "FAILING 32 wf-32 attempt=2 conclusion=failure" "failing run"
expect_out "SETTLED failure head=aaaaaaaa runs=2 failing=1" "failing run"

# Empty run list: indeterminate, never settled.
reset_fixtures
run_checks --timeout-seconds 1 --interval-seconds 1
expect_rc 3 "empty run list"
expect_out "INDETERMINATE at expiry: no runs listed" "empty run list"

# A failed per-run read is indeterminate, never settled.
reset_fixtures
write_page 1 "$(run_json 41 completed success 1)"
run_checks --timeout-seconds 1 --interval-seconds 1
expect_rc 3 "failed run read"
expect_out "could not read run 41" "failed run read"

# A run listed for another head is refused rather than counted.
reset_fixtures
write_page 1 "$(run_json 51 completed success 1 "$sha_b")"
run_json 51 completed success 1 "$sha_b" >"$fix/run.51.json"
run_checks --timeout-seconds 1 --interval-seconds 1
expect_rc 3 "foreign-head run"

# C1-2: the PR still reports the previous head right after the push. The
# first poll must not settle (it reports head-mismatch and lists nothing);
# once GitHub catches up, the same completed runs settle.
reset_fixtures
write_page 1 "$(run_json 61 completed success 1)"
run_json 61 completed success 1 >"$fix/run.61.json"
pull_head 1 "$sha_b"
run_checks --timeout-seconds 10 --interval-seconds 1
expect_rc 0 "lagging PR head then caught up"
expect_out "POLL 1 head-mismatch: PR head bbbbbbbb is not the pushed head aaaaaaaa" \
    "lagging PR head"
expect_out "SETTLED success head=aaaaaaaa runs=1" "lagging PR head"
case "$out" in *"POLL 1 head=aaaaaaaa"*) fail "poll 1 read runs while the PR reported another head: $out" ;; esac

# C1-2: the head matches when the poll starts but moves before the verdict;
# the re-read after the run reads refuses the settle for that poll.
reset_fixtures
write_page 1 "$(run_json 62 completed success 1)"
run_json 62 completed success 1 >"$fix/run.62.json"
pull_head 2 "$sha_b"
run_checks --timeout-seconds 10 --interval-seconds 1
expect_rc 0 "head moved during a poll, then back"
expect_out "POLL 1 head-mismatch: PR head moved to bbbbbbbb during the poll" \
    "head re-read after the run reads"
# The only settle is on poll 2, after the poll-1 refusal.
[ "$(printf '%s\n' "$out" | grep -c '^SETTLED')" -eq 1 ] || fail "expected one SETTLED line: $out"
expect_out "POLL 2 head=aaaaaaaa" "settled on poll 2"

# C1-2: the PR never reports the pushed head: never settled, indeterminate.
reset_fixtures
printf '{"head":{"sha":"%s"}}\n' "$sha_b" >"$fix/pull.json"
write_page 1 "$(run_json 63 completed success 1 "$sha_a")"
run_json 63 completed success 1 >"$fix/run.63.json"
run_checks --timeout-seconds 2 --interval-seconds 1
expect_rc 3 "PR head never reaches --head"
expect_out "INDETERMINATE at expiry: PR head bbbbbbbb is not the pushed head aaaaaaaa" \
    "PR head never reaches --head"
case "$out" in *SETTLED*) fail "settled for a head the PR never reported: $out" ;; esac

# --head is required and must be a full lowercase 40-hex SHA.
for bad in '' abc "${sha_a:0:39}" "${sha_a}a" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; do
    set +e
    "$wait_sh" checks --repo o/r --pr 7 --timeout-seconds 1 --head "$bad" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "--head '$bad' accepted (exit $rc)"
done
set +e
"$wait_sh" checks --repo o/r --pr 7 --timeout-seconds 1 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing --head accepted (exit $rc)"

# C1-1: one workflow (id 900) and one event, three runs on one head: a
# cancelled run superseded by a failed re-run superseded by a passing one.
# Only the newest counts, so the head settles green; each superseded run is
# read on its own and dropped because that read says completed.
reset_fixtures
write_page 1 \
    "$(run_json 71 completed cancelled 1 "$sha_a" 900 pull_request 10 2026-09-27T00:00:00Z)" \
    "$(run_json 72 completed failure 1 "$sha_a" 900 pull_request 11 2026-09-27T00:01:00Z)" \
    "$(run_json 73 completed success 1 "$sha_a" 900 pull_request 12 2026-09-27T00:02:00Z)" \
    "$(run_json 74 completed success 1 "$sha_a" 901 pull_request 3 2026-09-27T00:00:00Z)"
for id in 71 72 73 74; do
    jq -c --argjson id "$id" '.workflow_runs[] | select(.id == $id)' \
        "$fix/runs.1.json" >"$fix/run.$id.json"
done
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 0 "superseded cancelled and failed runs"
expect_out "runs=2 pending=0 failing=0 skipped=0 superseded=2" "superseded runs"
expect_out "SETTLED success head=aaaaaaaa runs=2" "superseded runs"
for id in 71 72; do
    grep -Fxq "api repos/o/r/actions/runs/$id" "$fix/gh.calls" ||
        fail "superseded run $id was dropped without its own read"
done

# 4117760555: the list still says a superseded run completed, but its own
# read says a re-run queued it. It counts as pending, never settled.
reset_fixtures
write_page 1 \
    "$(run_json 76 completed failure 1 "$sha_a" 900 pull_request 10 2026-09-27T00:00:00Z)" \
    "$(run_json 77 completed success 1 "$sha_a" 900 pull_request 11 2026-09-27T00:01:00Z)"
run_files 77
run_json 76 queued null 2 "$sha_a" 900 pull_request 10 2026-09-27T00:00:00Z >"$fix/run.76.json"
run_checks --timeout-seconds 1 --interval-seconds 1
expect_rc 4 "a superseded run re-queued by a re-run is pending"
expect_out "PENDING 76 wf-76 attempt=2 status=queued" "re-queued superseded run"
case "$out" in *SETTLED*) fail "settled over a re-queued superseded run: $out" ;; esac

# 4117760546: two PRs share the head. The sibling PR 8's newer green run of
# the same workflow must not supersede this PR's failing run; it is ignored.
reset_fixtures
write_page 1 \
    "$(run_json 78 completed failure 1 "$sha_a" 900 pull_request 10 2026-09-27T00:00:00Z '[7]')" \
    "$(run_json 79 completed success 1 "$sha_a" 900 pull_request 11 2026-09-27T00:01:00Z '[8]')"
run_files 78 79
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 1 "a sibling PR's run does not supersede ours"
expect_out "FAILING 78" "sibling PR run"
expect_out "runs=1 pending=0 failing=1 skipped=0 superseded=0 other_pr=1" "sibling PR run"
if grep -Fxq "api repos/o/r/actions/runs/79" "$fix/gh.calls"; then
    fail "the sibling PR's run 79 was read"
fi

# 4117760546: an empty association (a fork PR) or one naming this PR beside
# another is unprovable: counted on its own, never collapsed, and never
# superseding this PR's older failing run nor superseded by a newer run.
reset_fixtures
write_page 1 \
    "$(run_json 81 completed failure 1 "$sha_a" 900 pull_request 10 2026-09-27T00:00:00Z '[7]')" \
    "$(run_json 82 completed success 1 "$sha_a" 900 pull_request 11 2026-09-27T00:01:00Z '[]')" \
    "$(run_json 83 completed failure 1 "$sha_a" 900 pull_request 9 2026-09-27T00:00:00Z '[7,8]')" \
    "$(run_json 84 completed success 1 "$sha_a" 900 pull_request 12 2026-09-27T00:02:00Z '[]')"
run_files 81 82 83 84
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 1 "unprovable associations are counted individually"
expect_out "runs=4 pending=0 failing=2 skipped=0 superseded=0 other_pr=0" "unprovable associations"
expect_out "FAILING 81" "unprovable associations"
expect_out "FAILING 83" "unprovable associations"

# 4117760549: a run list at GitHub's 1000-run search cap cannot be paged
# past, so the poll is indeterminate even when every listed run is green.
reset_fixtures
write_page 1 "$(run_json 85 completed success 1)"
run_files 85
jq -c '.total_count = 1000' "$fix/runs.1.json" >"$fix/runs.capped" &&
    mv "$fix/runs.capped" "$fix/runs.1.json"
run_checks --timeout-seconds 1 --interval-seconds 1
expect_rc 3 "a capped run list is indeterminate"
expect_out "reports 1000 or more runs" "capped run list"
case "$out" in *SETTLED*) fail "settled on a capped run list: $out" ;; esac

# 4117906308: run 10 (id 201) was superseded by run 11 (id 202, success),
# then manually re-run: its attempt 2 started after run 11 did and failed.
# That attempt is fresher evidence, so it counts and the head fails.
reset_fixtures
write_page 1 \
    "$(run_json 201 completed failure 2 "$sha_a" 900 pull_request 10 2026-09-27T00:00:00Z)" \
    "$(run_json 202 completed success 1 "$sha_a" 900 pull_request 11 2026-09-27T00:01:00Z)"
run_files 201 202
jq -c '.run_started_at = "2026-09-27T00:01:00Z"' "$fix/run.202.json" >"$fix/run.tmp" &&
    mv "$fix/run.tmp" "$fix/run.202.json"
jq -c '.run_started_at = "2026-09-27T00:05:00Z"' "$fix/run.201.json" >"$fix/run.tmp" &&
    mv "$fix/run.tmp" "$fix/run.201.json"
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 1 "a superseded run re-run after the newest run started counts"
expect_out "FAILING 201 wf-201 attempt=2 conclusion=failure" "re-run superseded run"
expect_out "runs=2 pending=0 failing=1 skipped=0 superseded=0" "re-run superseded run"

# 4117906308: the same pair, but run 10's latest attempt started before run 11
# (fractional seconds parse too): superseded and dropped, the head settles.
jq -c '.run_started_at = "2026-09-27T00:00:30.123Z"' "$fix/run.201.json" >"$fix/run.tmp" &&
    mv "$fix/run.tmp" "$fix/run.201.json"
rm -f "$fix/pull.count"
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 0 "a superseded run whose latest attempt predates the newest run is dropped"
expect_out "runs=1 pending=0 failing=0 skipped=0 superseded=1" "earlier superseded attempt"

# 4117906308: fail closed when a start time is missing or unparseable on
# either read: the superseded run counts on its own conclusion.
for bad in 201 202; do
    jq -c '.run_started_at = "not-a-time" | .created_at = null' "$fix/run.$bad.json" \
        >"$fix/run.tmp" && cp "$fix/run.tmp" "$fix/run.$bad.bad"
done
for bad in 201 202; do
    run_files 201 202
    jq -c '.run_started_at = "2026-09-27T00:00:30Z"' "$fix/run.201.json" >"$fix/run.tmp" &&
        mv "$fix/run.tmp" "$fix/run.201.json"
    cp "$fix/run.$bad.bad" "$fix/run.$bad.json"
    rm -f "$fix/pull.count"
    run_checks --timeout-seconds 5 --interval-seconds 1
    expect_rc 1 "an unreadable start time on run $bad keeps the superseded run counted"
    expect_out "FAILING 201" "unreadable start time on run $bad"
done

# 4117906313: --per-page 1 over 60 runs pages past the old fixed 50-page
# guard: every result under the 1000 cap is traversable, so it settles.
reset_fixtures
for id in $(seq 301 360); do
    run_json "$id" completed success 1 >"$fix/run.$id.json"
    jq -c '{total_count: 60, workflow_runs: [.]}' "$fix/run.$id.json" \
        >"$fix/runs.$((id - 300)).json"
done
run_checks --timeout-seconds 5 --interval-seconds 1 --per-page 1
expect_rc 0 "a small --per-page traverses every page under the cap"
expect_out "SETTLED success head=aaaaaaaa runs=60" "small --per-page"

# C1-1: the newest run of the workflow is the failing one: exit 1. The same
# workflow under another event is its own group and is evaluated separately.
reset_fixtures
write_page 1 \
    "$(run_json 81 completed success 1 "$sha_a" 900 pull_request 10 2026-09-27T00:00:00Z)" \
    "$(run_json 82 completed failure 1 "$sha_a" 900 pull_request 11 2026-09-27T00:01:00Z)" \
    "$(run_json 83 completed success 1 "$sha_a" 900 push 11 2026-09-27T00:02:00Z)"
for id in 81 82 83; do
    jq -c --argjson id "$id" '.workflow_runs[] | select(.id == $id)' \
        "$fix/runs.1.json" >"$fix/run.$id.json"
done
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 1 "newest run of the workflow fails"
expect_out "FAILING 82" "newest run fails"
expect_out "runs=2 pending=0 failing=1 skipped=0 superseded=1" "newest run fails"

# C2-1: outside pull_request*, runs of one workflow on one head run side by
# side (a workflow_run fan-in here), so none supersedes another: the older
# failing one still counts.
reset_fixtures
write_page 1 \
    "$(run_json 86 completed failure 1 "$sha_a" 950 workflow_run 10 2026-09-27T00:00:00Z)" \
    "$(run_json 87 completed success 1 "$sha_a" 950 workflow_run 11 2026-09-27T00:01:00Z)"
for id in 86 87; do
    jq -c --argjson id "$id" '.workflow_runs[] | select(.id == $id)' \
        "$fix/runs.1.json" >"$fix/run.$id.json"
done
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 1 "parallel workflow_run runs are not collapsed"
expect_out "FAILING 86" "parallel workflow_run runs"
expect_out "superseded=0" "parallel workflow_run runs"

# C3-1: a superseded pull_request run still in flight counts as pending (no
# cancel-in-progress: an `edited` re-run whose jobs skip finishes first).
reset_fixtures
write_page 1 \
    "$(run_json 11 in_progress null 1 "$sha_a" 5 pull_request 1 2026-09-27T00:00:00Z)" \
    "$(run_json 12 completed success 1 "$sha_a" 5 pull_request 2 2026-09-27T00:01:00Z)"
for id in 11 12; do
    jq -c --argjson id "$id" '.workflow_runs[] | select(.id == $id)' \
        "$fix/runs.1.json" >"$fix/run.$id.json"
done
run_checks --timeout-seconds 2 --interval-seconds 1
expect_rc 4 "an in-flight superseded run is still pending"
expect_out "PENDING 11" "in-flight superseded run"

# C1-1: equal run_numbers break ties on created_at, then id.
reset_fixtures
write_page 1 \
    "$(run_json 91 completed success 1 "$sha_a" 900 pull_request 5 2026-09-27T00:05:00Z)" \
    "$(run_json 92 completed failure 1 "$sha_a" 900 pull_request 5 2026-09-27T00:01:00Z)"
for id in 91 92; do
    jq -c --argjson id "$id" '.workflow_runs[] | select(.id == $id)' \
        "$fix/runs.1.json" >"$fix/run.$id.json"
done
run_checks --timeout-seconds 5 --interval-seconds 1
expect_rc 0 "run_number tie broken by created_at"

# C1-6: the last poll's calls keep the full --call-timeout-seconds. The run
# read takes 2s against a 1s wait: a clamped call would be killed and the
# wait would report indeterminate (3); unclamped, the pending run is read and
# the wait expires (4).
reset_fixtures
write_page 1 "$(run_json 95 in_progress null 1)"
run_json 95 in_progress null 1 >"$fix/run.95.json"
set +e
out="$(SW_RUN_DELAY=2 "$wait_sh" checks --repo o/r --pr 7 --head "$sha_a" \
    --timeout-seconds 1 --interval-seconds 1 --call-timeout-seconds 10 2>&1)"
rc=$?
set -e
expect_rc 4 "final poll's call is not clamped to the time left"
expect_out "PENDING 95" "unclamped final poll"
expect_out "EXPIRED after 1s: 1 of 1 runs pending on head aaaaaaaa" "unclamped final poll"

# Codex 4118042216: many runs on a slow API cannot stretch the wait past the
# deadline plus about one call timeout. Eight pending runs at 2s a read would
# take 16s; the poll stops once the hard ceiling (1s + 3s) passes and is
# indeterminate.
reset_fixtures
set --
for id in 61 62 63 64 65 66 67 68; do
    set -- "$@" "$(run_json "$id" in_progress null 1)"
    run_json "$id" in_progress null 1 >"$fix/run.$id.json"
done
write_page 1 "$@"
hard_start=$(date +%s)
set +e
out="$(SW_RUN_DELAY=2 "$wait_sh" checks --repo o/r --pr 7 --head "$sha_a" \
    --timeout-seconds 1 --interval-seconds 1 --call-timeout-seconds 3 2>&1)"
rc=$?
set -e
hard_took=$(($(date +%s) - hard_start))
expect_rc 3 "a slow many-run poll stops at the hard ceiling"
expect_out "the overall deadline passed mid-poll" "hard ceiling"
[ "$hard_took" -le 10 ] || fail "the poll ran ${hard_took}s, past the hard ceiling"

# The stub logs every gh invocation across every scenario (a log the
# per-scenario reset does not clear); none may be a watch verb.
if grep -Ev '^api ' "$fix.all-calls"; then
    fail "settle-wait called gh outside 'gh api'"
fi

# Source guard: the executable lines never call the watch-style verbs.
if grep -Ev '^[[:space:]]*#' "$wait_sh" |
    grep -En 'gh +(run +watch|pr +checks)|--exit-status|--paginate'; then
    fail "settle-wait.sh calls a watch-style gh verb or --paginate"
fi

echo "settle-wait: ok"
