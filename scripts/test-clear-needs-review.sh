#!/usr/bin/env bash
# Offline behavioral tests: the review marker is independent of claim ownership.
set -euo pipefail
cd "$(dirname "$0")/.."

script="$PWD/ai/skills/universal/track-work/assets/clear-needs-review.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NR_CALLS"
case "$*" in
'issue view 42 --repo test-owner/test.repo --json labels --jq .labels[].name')
    [ "$NR_SCENARIO" != read-fail ] || exit 7
    printf '%s\n' 'feature' 'claim:gpt' 'needs-review-extra'
    case "$NR_SCENARIO" in
    absent) ;;
    case-variant) printf '%s\n' 'Needs-Review' ;;
    *) printf '%s\n' 'needs-review' ;;
    esac
    ;;
'issue edit 42 --repo test-owner/test.repo --remove-label needs-review')
    [ "$NR_SCENARIO" != write-fail ] || exit 8
    ;;
'issue edit 42 --repo test-owner/test.repo --remove-label Needs-Review')
    [ "$NR_SCENARIO" = case-variant ] || exit 9
    ;;
*) exit 9 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

run_helper() {
    local rc=0
    : >"$tmp/calls"
    env PATH="$tmp/bin:$PATH" NR_CALLS="$tmp/calls" NR_SCENARIO="$scenario" \
        "$script" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
    printf '%s\n' "$rc"
}

scenario=present
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "present label should be removed"
[ "$(wc -l <"$tmp/calls" | tr -d ' ')" = 2 ] || fail "present label needs exactly one read and one removal"
grep -Fxq 'issue edit 42 --repo test-owner/test.repo --remove-label needs-review' "$tmp/calls" || fail "only needs-review may be removed"

scenario=case-variant
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "mixed-case label should be removed"
[ "$(wc -l <"$tmp/calls" | tr -d ' ')" = 2 ] || fail "mixed-case label needs exactly one read and one removal"
grep -Fxq 'issue edit 42 --repo test-owner/test.repo --remove-label Needs-Review' "$tmp/calls" || fail "mixed-case removal must use the exact live name"

# A second call after removal sees no marker: no write, including similarly named labels.
scenario=absent
[ "$(run_helper --repo test-owner/test.repo --issue 42)" = 0 ] || fail "absent label should succeed"
[ "$(wc -l <"$tmp/calls" | tr -d ' ')" = 1 ] || fail "absent label must not write"

scenario=read-fail
[ "$(run_helper --repo test-owner/test.repo --issue 42)" != 0 ] || fail "read failure must propagate"
[ "$(wc -l <"$tmp/calls" | tr -d ' ')" = 1 ] || fail "read failure must not write"

scenario=write-fail
[ "$(run_helper --repo test-owner/test.repo --issue 42)" != 0 ] || fail "write failure must propagate"
[ "$(wc -l <"$tmp/calls" | tr -d ' ')" = 2 ] || fail "write failure must not attempt other mutations"

scenario=present
for bad_issue in abc 0 -1 '42;echo bad' '42/1'; do
    [ "$(run_helper --repo test-owner/test.repo --issue "$bad_issue")" != 0 ] || fail "invalid issue accepted: $bad_issue"
    [ ! -s "$tmp/calls" ] || fail "invalid issue must be refused before gh"
done
for bad_repo in owner owner/repo/extra 'owner/repo;bad' 'owner name/repo' /repo owner/; do
    [ "$(run_helper --repo "$bad_repo" --issue 42)" != 0 ] || fail "invalid repo accepted: $bad_repo"
    [ ! -s "$tmp/calls" ] || fail "invalid repo must be refused before gh"
done
for missing in --repo --issue; do
    [ "$(run_helper "$missing")" != 0 ] || fail "missing argument accepted"
    [ ! -s "$tmp/calls" ] || fail "missing argument must be refused before gh"
done
[ "$(run_helper --issue 42)" != 0 ] || fail "missing repo accepted"
[ ! -s "$tmp/calls" ] || fail "missing repo must be refused before gh"
[ "$(run_helper --repo test-owner/test.repo)" != 0 ] || fail "missing issue accepted"
[ ! -s "$tmp/calls" ] || fail "missing issue must be refused before gh"
[ "$(run_helper --help)" = 0 ] || fail "help should succeed"
[ ! -s "$tmp/calls" ] || fail "help must not call gh"

echo "ALL PASS"
