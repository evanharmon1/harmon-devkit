#!/usr/bin/env bash
# test-migrate-label-family.sh — hermetic tests for the standardize-repo
# label-family migration script. Fully offline: every `gh` call goes to a
# PATH-stubbed fake driven by fixture files and a mutable label-state
# directory.
#
# What this keeps honest:
#   - every `gh api` call is --method GET, never -f/-F (the mock refuses
#     both — this is the regression test for the POST-defaulting bug)
#   - a failed page anywhere aborts the whole command (fail-fast)
#   - `--paginate --slurp` output (an array of PAGES) is flattened with
#     `add // []` before anything indexes into it as a list of items
#   - inventory refuses while any item carries more than one <prefix>:*
#     label
#   - transfer adds-then-verifies every item before deleting the source,
#     and aborts without deleting on the first failure
#   - rename discovers case-insensitively and refuses onto an existing
#     destination
#
# Run via `task test:skills` (wired alongside test-breakdown-labels.sh) or
# directly.
set -euo pipefail
cd "$(dirname "$0")/.."

repo="$(pwd)"
asset="$repo/ai/skills/repo/standardize-repo/assets/migrate-label-family.sh"
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*"
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2
}

[ -x "$asset" ] || {
    echo "TEST FAIL: missing executable asset: $asset" >&2
    exit 1
}

mkdir -p "$tmproot/bin"
cat >"$tmproot/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

fixture="${MIGRATE_LABEL_FIXTURE:?}"
log="${MIGRATE_LABEL_LOG:?}"
printf '%s\n' "$*" >>"$log"

refuse() {
    echo "MOCK REFUSED: $*" >&2
    exit 97
}

# Every failing-page value this fixture wants to simulate, one per line:
# "<endpoint-substring>" — a GET whose endpoint contains it fails outright.
fail_on_file="$fixture/fail-on-endpoint"

if [ "$1" = "api" ]; then
    shift
    method=""
    endpoint=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --method)
            method="$2"
            shift 2
            ;;
        -X)
            method="$2"
            shift 2
            ;;
        --paginate | --slurp) shift ;;
        -f | --raw-field | -F | --field | --input)
            refuse "$1 carries request fields — this flips gh api's default method to POST"
            ;;
        -*) shift ;;
        *)
            endpoint="$1"
            shift
            ;;
        esac
    done
    [ "$method" = "GET" ] || refuse "gh api called without --method GET (got '${method:-<none>}')"
    if [ -f "$fail_on_file" ] && grep -qF "$(cat "$fail_on_file")" <<<"$endpoint"; then
        echo "mock: simulated page failure for $endpoint" >&2
        exit 1
    fi
    case "$endpoint" in
    */labels\?per_page=*)
        cat "$fixture/labels-pages.json"
        ;;
    */issues\?labels=*)
        label="$(printf '%s' "$endpoint" | sed -n 's/.*labels=\([^&]*\)&.*/\1/p')"
        safe="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_-' '_')"
        file="$fixture/issues-$safe.json"
        if [ -f "$file" ]; then
            cat "$file"
        else
            printf '[[]]\n'
        fi
        ;;
    *)
        echo "mock: unrecognized endpoint $endpoint" >&2
        exit 99
        ;;
    esac
    exit 0
fi

state_dir="$fixture/state"
mkdir -p "$state_dir"

if [ "$1" = "label" ]; then
    sub="$2"
    case "$sub" in
    edit)
        name="$3"
        newname=""
        i=4
        args=("$@")
        count=${#args[@]}
        idx=0
        while [ "$idx" -lt "$count" ]; do
            if [ "${args[$idx]}" = "--name" ]; then
                newname="${args[$((idx + 1))]}"
            fi
            idx=$((idx + 1))
        done
        [ -n "$newname" ] || refuse "label edit without --name"
        if [ -f "$fixture/fail-rename" ]; then
            echo "mock: simulated rename failure" >&2
            exit 1
        fi
        echo "$newname" >"$state_dir/renamed-$name"
        exit 0
        ;;
    delete)
        name="$3"
        if [ -f "$fixture/fail-delete" ]; then
            echo "mock: simulated delete failure" >&2
            exit 1
        fi
        echo deleted >"$state_dir/deleted-$name"
        exit 0
        ;;
    esac
fi

if [ "$1" = "issue" ] || [ "$1" = "pr" ]; then
    kind="$1"
    sub="$2"
    number="$3"
    labels_file="$state_dir/$kind-$number.labels"
    touch "$labels_file"
    case "$sub" in
    edit)
        label=""
        args=("$@")
        count=${#args[@]}
        idx=0
        while [ "$idx" -lt "$count" ]; do
            if [ "${args[$idx]}" = "--add-label" ]; then
                label="${args[$((idx + 1))]}"
            fi
            idx=$((idx + 1))
        done
        [ -n "$label" ] || refuse "$kind edit without --add-label"
        if [ -f "$fixture/fail-add-$number" ]; then
            echo "mock: simulated add-label failure on $kind #$number" >&2
            exit 1
        fi
        if [ -f "$fixture/silent-fail-add-$number" ]; then
            # "succeeds" but never actually writes the label — exercises the
            # post-add verification, not just the add call's own exit code.
            exit 0
        fi
        grep -qxF "$label" "$labels_file" 2>/dev/null || echo "$label" >>"$labels_file"
        exit 0
        ;;
    view)
        cat "$labels_file" | while read -r l; do
            [ -n "$l" ] && printf '%s\n' "$l"
        done
        exit 0
        ;;
    esac
fi

echo "unexpected fake gh call: $*" >&2
exit 2
FAKE_GH
chmod +x "$tmproot/bin/gh"

run() {
    local out rc=0
    out="$("$@" 2>"$tmproot/stderr")" || rc=$?
    printf '%s' "$out" >"$tmproot/stdout"
    echo "$rc"
}

migrate() {
    MIGRATE_LABEL_FIXTURE="$fixture" MIGRATE_LABEL_LOG="$log" PATH="$tmproot/bin:$PATH" \
        "$asset" "$@"
}

new_fixture() {
    fixture="$tmproot/fixture-$1"
    mkdir -p "$fixture/state"
    log="$fixture/gh.log"
    : >"$log"
}

# Two-page label list: method:oneshot on page 1, strategy:oneshot +
# method:plan on page 2 — proves the mock (and the script's own `add // []`)
# actually flattens rather than reading only the first page.
write_two_page_labels() {
    cat >"$fixture/labels-pages.json" <<'JSON'
[
  [{"name":"method:oneshot","color":"BF3989"}],
  [{"name":"strategy:oneshot","color":"BF3989"},{"name":"method:plan","color":"BF3989"}]
]
JSON
}

# issues-<safe-label>.json fixtures are also page-shaped: [[...],[...]].
write_issue_page() {
    local label="$1" body="$2"
    local safe
    safe="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_-' '_')"
    printf '%s\n' "$body" >"$fixture/issues-$safe.json"
}

echo "==> mock enforcement: the fake gh itself refuses what the script must never send"
new_fixture "mock-self-check"
write_two_page_labels
if MIGRATE_LABEL_FIXTURE="$fixture" MIGRATE_LABEL_LOG="$log" "$tmproot/bin/gh" \
    api -f foo=bar "/repos/o/r/issues" >/dev/null 2>"$tmproot/stderr"; then
    bad "mock should refuse a gh api call carrying -f"
else
    grep -q 'flips gh api' "$tmproot/stderr" && ok "mock refuses -f (would flip default method to POST)" ||
        bad "mock should refuse -f with a POST-method diagnostic"
fi
if MIGRATE_LABEL_FIXTURE="$fixture" MIGRATE_LABEL_LOG="$log" "$tmproot/bin/gh" \
    api --paginate --slurp "/repos/o/r/issues" >/dev/null 2>"$tmproot/stderr"; then
    bad "mock should refuse a gh api call without --method GET"
else
    grep -q 'without --method GET' "$tmproot/stderr" && ok "mock refuses a call with no --method GET" ||
        bad "mock should name the missing --method GET"
fi

echo "==> POST-vs-GET regression: every subcommand's own gh api calls pass the mock"
new_fixture "post-vs-get"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"method:oneshot","color":"BF3989"}]]
JSON
write_issue_page "method:oneshot" '[[{"number":5,"pull_request":null}]]'
[ "$(run migrate inventory method --repo o/r)" = 0 ] ||
    bad "inventory should succeed without tripping the mock's method/field guard: $(cat "$tmproot/stderr")"
[ "$(run migrate rename method:oneshot strategy:oneshot --repo o/r --execute)" = 0 ] ||
    bad "rename should succeed without tripping the mock's method/field guard: $(cat "$tmproot/stderr")"
if grep -q ' -f \| -F \|--raw-field\|--field\|--input' "$log"; then
    bad "no gh api call should ever carry -f/-F/--raw-field/--field/--input"
else
    ok "no subcommand under test ever calls gh api with a request-field flag"
fi
if grep -q '^api ' "$log" && grep '^api ' "$log" | grep -qv -- '--method GET'; then
    bad "every gh api call must pin --method GET"
else
    ok "every gh api call this run made pinned --method GET"
fi

echo "==> multi-page flatten: labels split across pages are all discovered"
new_fixture "flatten"
write_two_page_labels
[ "$(run migrate verify method --repo o/r)" = 4 ] ||
    bad "verify should see method:plan on page 2, not just method:oneshot on page 1"
if MIGRATE_LABEL_FIXTURE="$fixture" MIGRATE_LABEL_LOG="$log" PATH="$tmproot/bin:$PATH" \
    "$asset" verify method --repo o/r >"$tmproot/out" 2>&1; then
    bad "verify should exit non-zero while method:* labels remain"
else
    grep -q 'method:oneshot' "$tmproot/out" && grep -q 'method:plan' "$tmproot/out" &&
        ok "verify's live-label listing spans both pages (oneshot page 1, plan page 2)" ||
        bad "verify should report both page-1 and page-2 method:* labels: $(cat "$tmproot/out")"
fi

echo "==> multi-page flatten: issues split across pages are all counted"
new_fixture "flatten-issues"
write_two_page_labels
write_issue_page "method:oneshot" '[[{"number":1,"pull_request":null}],[{"number":2,"pull_request":{}}]]'
if [ "$(run migrate transfer method:oneshot strategy:oneshot --repo o/r)" = 0 ] &&
    grep -q '2 item' "$tmproot/stdout"; then
    ok "transfer's dry-run item count spans both pages (expected 2, page 1 + page 2)"
else
    bad "dry-run transfer should count both page-1 and page-2 items (expected 2): $(cat "$tmproot/stdout") $(cat "$tmproot/stderr")"
fi

echo "==> multi-label refusal: an item carrying two <prefix>:* labels blocks inventory"
new_fixture "multi-label"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"method:oneshot","color":"BF3989"},{"name":"method:plan","color":"BF3989"}]]
JSON
write_issue_page "method:oneshot" '[[{"number":5,"pull_request":null}]]'
write_issue_page "method:plan" '[[{"number":5,"pull_request":null},{"number":9,"pull_request":null}]]'
rc="$(run migrate inventory method --repo o/r)"
[ "$rc" = 3 ] || bad "inventory should exit 3 when an item carries more than one method:* label (got $rc)"
grep -q '#5' "$tmproot/stderr" && grep -q 'method:oneshot' "$tmproot/stderr" && grep -q 'method:plan' "$tmproot/stderr" ||
    bad "inventory should name the conflicting issue and both values: $(cat "$tmproot/stderr")"
grep -q '#9' "$tmproot/stderr" && bad "inventory should not flag #9, which carries only one method:* label" ||
    ok "inventory flags exactly the multi-labeled item, naming both its values"

echo "==> case-insensitive discovery: rename finds a live label regardless of case"
new_fixture "case-insensitive"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"Method:OneShot","color":"BF3989"}]]
JSON
[ "$(run migrate rename method:oneshot strategy:oneshot --repo o/r --execute)" = 0 ] ||
    bad "rename should find Method:OneShot when asked to rename method:oneshot: $(cat "$tmproot/stderr")"
[ "$(cat "$fixture/state/renamed-Method:OneShot" 2>/dev/null)" = "strategy:oneshot" ] ||
    bad "rename should have edited the exact live spelling 'Method:OneShot'"
grep -qi 'renamed' "$tmproot/stdout" && ok "case-insensitive discovery finds and renames the live spelling" ||
    bad "rename should report success"

echo "==> rename refuses onto an existing destination (points to transfer)"
new_fixture "destination-exists"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"method:oneshot","color":"BF3989"},{"name":"strategy:oneshot","color":"BF3989"}]]
JSON
rc="$(run migrate rename method:oneshot strategy:oneshot --repo o/r --execute)"
[ "$rc" = 2 ] || bad "rename onto an existing destination should exit 2 (got $rc)"
grep -qi 'transfer' "$tmproot/stderr" ||
    bad "rename's refusal should point at the transfer subcommand: $(cat "$tmproot/stderr")"
[ -f "$fixture/state/renamed-method:oneshot" ] &&
    bad "rename must not touch the label when it refuses" ||
    ok "rename refuses a collision and points to transfer, without touching either label"

echo "==> transfer: destination-exists path adds, verifies, then deletes the source"
new_fixture "transfer-happy"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"method:oneshot","color":"BF3989"},{"name":"strategy:oneshot","color":"BF3989"}]]
JSON
write_issue_page "method:oneshot" '[[{"number":5,"pull_request":null},{"number":6,"pull_request":{}}]]'
[ "$(run migrate transfer method:oneshot strategy:oneshot --repo o/r --execute)" = 0 ] ||
    bad "transfer --execute should succeed when every add verifies: $(cat "$tmproot/stderr")"
[ "$(cat "$fixture/state/issue-5.labels" 2>/dev/null)" = "strategy:oneshot" ] &&
    [ "$(cat "$fixture/state/pr-6.labels" 2>/dev/null)" = "strategy:oneshot" ] ||
    bad "transfer should add strategy:oneshot to both the issue and the PR"
[ -f "$fixture/state/deleted-method:oneshot" ] ||
    bad "transfer should delete method:oneshot once every item is confirmed transferred"
[ -f "$fixture/state/issue-5.labels" ] && [ -f "$fixture/state/deleted-method:oneshot" ] &&
    ok "transfer added the destination to every item (issue and PR) and only then deleted the source"

echo "==> transfer aborts without deleting on a failed add (partial failure)"
new_fixture "transfer-add-fails"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"method:oneshot","color":"BF3989"},{"name":"strategy:oneshot","color":"BF3989"}]]
JSON
write_issue_page "method:oneshot" '[[{"number":5,"pull_request":null},{"number":6,"pull_request":null}]]'
touch "$fixture/fail-add-6"
rc="$(run migrate transfer method:oneshot strategy:oneshot --repo o/r --execute)"
[ "$rc" = 1 ] || bad "transfer should exit 1 when an add-label call fails (got $rc)"
[ -f "$fixture/state/deleted-method:oneshot" ] &&
    bad "transfer must not delete the source when any item's add failed" ||
    ok "a failed add-label call aborts the transfer before the source is deleted"

echo "==> transfer aborts without deleting when an add 'succeeds' but does not verify"
new_fixture "transfer-verify-fails"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"method:oneshot","color":"BF3989"},{"name":"strategy:oneshot","color":"BF3989"}]]
JSON
write_issue_page "method:oneshot" '[[{"number":5,"pull_request":null}]]'
touch "$fixture/silent-fail-add-5"
rc="$(run migrate transfer method:oneshot strategy:oneshot --repo o/r --execute)"
[ "$rc" = 1 ] || bad "transfer should exit 1 when a post-add verification fails (got $rc)"
[ -f "$fixture/state/deleted-method:oneshot" ] &&
    bad "transfer must not delete the source when a verification failed, even if the add call itself exited 0" ||
    ok "a silently-no-op add is caught by the post-add verification, not just the add call's exit code"

echo "==> transfer dry-run writes nothing"
new_fixture "transfer-dry-run"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"method:oneshot","color":"BF3989"},{"name":"strategy:oneshot","color":"BF3989"}]]
JSON
write_issue_page "method:oneshot" '[[{"number":5,"pull_request":null}]]'
[ "$(run migrate transfer method:oneshot strategy:oneshot --repo o/r)" = 0 ] ||
    bad "transfer dry-run should resolve cleanly"
[ -f "$fixture/state/issue-5.labels" ] && [ -s "$fixture/state/issue-5.labels" ] &&
    bad "transfer dry-run must not add the destination label" ||
    ok "transfer dry-run adds nothing (DRY-RUN by default, --execute required to write)"
[ -f "$fixture/state/deleted-method:oneshot" ] &&
    bad "transfer dry-run must not delete the source" ||
    ok "transfer dry-run deletes nothing"

echo "==> rename dry-run writes nothing"
new_fixture "rename-dry-run"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"method:plan","color":"BF3989"}]]
JSON
[ "$(run migrate rename method:plan strategy:plan --repo o/r)" = 0 ] ||
    bad "rename dry-run should resolve cleanly"
[ -f "$fixture/state/renamed-method:plan" ] &&
    bad "rename dry-run must not call gh label edit" ||
    ok "rename dry-run renames nothing (DRY-RUN by default, --execute required to write)"

echo "==> rename/verify report cleanly when the source is already gone"
new_fixture "already-migrated"
cat >"$fixture/labels-pages.json" <<'JSON'
[[{"name":"strategy:plan","color":"BF3989"}]]
JSON
[ "$(run migrate rename method:plan strategy:plan --repo o/r --execute)" = 0 ] ||
    bad "rename should no-op cleanly when the source is not live"
[ "$(run migrate verify method --repo o/r)" = 0 ] ||
    bad "verify should exit 0 when no method:* labels remain"

echo "==> a failed page mid-inventory aborts rather than reporting a partial clean result"
new_fixture "fail-fast"
write_two_page_labels
write_issue_page "method:oneshot" '[[{"number":5,"pull_request":null}]]'
printf 'labels=method:plan' >"$fixture/fail-on-endpoint"
rc="$(run migrate inventory method --repo o/r)"
[ "$rc" != 0 ] || bad "inventory must not exit 0 when a page fetch failed partway through"
[ "$rc" != 3 ] || bad "a fetch failure must not be reported as a (wrong) multi-label conflict"
grep -qi 'clean' "$tmproot/stdout" 2>/dev/null &&
    bad "inventory must not report 'clean' when it could not complete the fetch" ||
    ok "a failed page aborts inventory outright — it is never reported as clean or as a conflict"

if [ "$fail" -gt 0 ]; then
    echo "test-migrate-label-family: $fail failure(s), $pass passing." >&2
    exit 1
fi
echo "All migrate-label-family tests passed ($pass)."
