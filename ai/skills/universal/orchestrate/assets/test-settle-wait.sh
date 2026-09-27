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

cat >"$bin_dir/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SW_FIX/herdr.calls"
exit "${SW_HERDR_RC:-0}"
STUB

# gh stub: only `gh api <endpoint>` is served, from fixture files. Any other
# verb (the watch-style run/pr commands included) is logged and fails.
cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SW_FIX/gh.calls"
[ "${1:-}" = api ] || exit 97
case "${3:-}" in
'') ;;
*) exit 98 ;;
esac
endpoint=$2
case "$endpoint" in
repos/o/r/pulls/7)
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

# run_json ID STATUS CONCLUSION ATTEMPT [SHA [WORKFLOW_ID EVENT RUN_NUMBER CREATED_AT]]
# By default every run is its own workflow, so nothing supersedes anything.
run_json() {
    jq -cn --argjson id "$1" --arg s "$2" --arg c "$3" --argjson a "$4" \
        --arg sha "${5:-$sha_a}" --argjson w "${6:-$1}" --arg e "${7:-pull_request}" \
        --argjson n "${8:-1}" --arg t "${9:-2026-09-27T00:00:00Z}" \
        '{id: $id, name: ("wf-" + ($id|tostring)), head_sha: $sha, status: $s,
          conclusion: (if $c == "null" then null else $c end), run_attempt: $a,
          workflow_id: $w, event: $e, run_number: $n, created_at: $t}'
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
reset_fixtures
set +e
out="$("$wait_sh" agent alpha --until idle --timeout-seconds 3600 2>&1)"
rc=$?
set -e
expect_rc 0 "agent settle"
[ "$(cat "$fix/herdr.calls")" = "agent wait alpha --until idle --timeout 3600000" ] ||
    fail "herdr did not receive milliseconds: $(cat "$fix/herdr.calls")"
expect_out "SETTLED agent alpha" "agent settle"

reset_fixtures
"$wait_sh" agent beta --until blocked --timeout-seconds 5 >/dev/null
[ "$(cat "$fix/herdr.calls")" = "agent wait beta --until blocked --timeout 5000" ] ||
    fail "--until not forwarded before --timeout: $(cat "$fix/herdr.calls")"

reset_fixtures
set +e
out="$(SW_HERDR_RC=7 "$wait_sh" agent alpha --until idle --timeout-seconds 2 2>&1)"
rc=$?
set -e
expect_rc 7 "herdr's non-zero status is propagated"
expect_out "NOT-SETTLED agent alpha: herdr exited 7" "agent expiry"

reset_fixtures
for bad in 0 -5 1.5 abc 08 '' 86401 99999999999999999999; do
    set +e
    "$wait_sh" agent alpha --until idle --timeout-seconds "$bad" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "--timeout-seconds '$bad' accepted (exit $rc)"
done
set +e
"$wait_sh" agent alpha --until idle >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing --timeout-seconds accepted (exit $rc)"
set +e
"$wait_sh" agent alpha --timeout-seconds 5 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing --until accepted (exit $rc): a blocked lane would read as settled"
[ ! -s "$fix/herdr.calls" ] || fail "herdr was called on a usage error"

# ── checks mode ───────────────────────────────────────────────────────
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
# Only the newest counts, so the head settles green, and the superseded runs
# are never read one by one.
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
    if grep -Fxq "api repos/o/r/actions/runs/$id" "$fix/gh.calls"; then
        fail "superseded run $id was read individually (REST budget)"
    fi
done

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

# The stub logs every gh invocation; none may be a watch verb.
if grep -Ev '^api ' "$fix/gh.calls"; then
    fail "settle-wait called gh outside 'gh api'"
fi

# Source guard: the executable lines never call the watch-style verbs.
if grep -Ev '^[[:space:]]*#' "$wait_sh" |
    grep -En 'gh +(run +watch|pr +checks)|--exit-status|--paginate'; then
    fail "settle-wait.sh calls a watch-style gh verb or --paginate"
fi

echo "settle-wait: ok"
