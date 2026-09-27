#!/usr/bin/env bash
# Regression tests for settle-wait.sh: the seconds-to-milliseconds conversion
# for herdr lane settles, exit-status propagation, and the CI settle's reading
# of each run's own status across stale attempts, skipped floods, failures,
# empty lists, and a moved head. herdr and gh are stubs on PATH; nothing here
# reaches GitHub or a real herdr. Refs #1192.
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

# run_json ID STATUS CONCLUSION ATTEMPT [SHA]
run_json() {
    jq -cn --argjson id "$1" --arg s "$2" --arg c "$3" --argjson a "$4" \
        --arg sha "${5:-$sha_a}" \
        '{id: $id, name: ("wf-" + ($id|tostring)), head_sha: $sha, status: $s,
          conclusion: (if $c == "null" then null else $c end), run_attempt: $a}'
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
    out="$("$wait_sh" checks --repo o/r --pr 7 "$@" 2>&1)"
    rc=$?
    set -e
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
out="$("$wait_sh" agent alpha --timeout-seconds 3600 2>&1)"
rc=$?
set -e
expect_rc 0 "agent settle"
[ "$(cat "$fix/herdr.calls")" = "agent wait alpha --timeout 3600000" ] ||
    fail "herdr did not receive milliseconds: $(cat "$fix/herdr.calls")"
expect_out "SETTLED agent alpha" "agent settle"

reset_fixtures
"$wait_sh" agent beta --until blocked --timeout-seconds 5 >/dev/null
[ "$(cat "$fix/herdr.calls")" = "agent wait beta --until blocked --timeout 5000" ] ||
    fail "--until not forwarded before --timeout: $(cat "$fix/herdr.calls")"

reset_fixtures
set +e
out="$(SW_HERDR_RC=7 "$wait_sh" agent alpha --timeout-seconds 2 2>&1)"
rc=$?
set -e
expect_rc 7 "herdr's non-zero status is propagated"
expect_out "NOT-SETTLED agent alpha: herdr exited 7" "agent expiry"

reset_fixtures
for bad in 0 -5 1.5 abc 08 ''; do
    set +e
    "$wait_sh" agent alpha --timeout-seconds "$bad" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "--timeout-seconds '$bad' accepted (exit $rc)"
done
set +e
"$wait_sh" agent alpha >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing --timeout-seconds accepted (exit $rc)"
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

# The head moves between polls: indeterminate at once.
reset_fixtures
write_page 1 "$(run_json 61 in_progress null 1)"
run_json 61 in_progress null 1 >"$fix/run.61.json"
printf '{"head":{"sha":"%s"}}\n' "$sha_b" >"$fix/pull.2.json"
run_checks --timeout-seconds 10 --interval-seconds 1
expect_rc 3 "moved head"
expect_out "INDETERMINATE head moved: aaaaaaaa -> bbbbbbbb" "moved head"

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
