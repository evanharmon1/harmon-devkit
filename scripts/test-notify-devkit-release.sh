#!/usr/bin/env bash
# test-notify-devkit-release.sh — offline unit tests for
# notify-devkit-release.sh, the harmon-init release dispatch.
#
# `gh` is replaced by a stub on PATH that records its argv, so what would be
# sent is asserted exactly. Nothing here touches the network or GitHub.
# Run via `task test:notify-release`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
helper="${repo}/scripts/notify-devkit-release.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cases=0
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$STUB_LOG"
exit "${STUB_GH_RC:-0}"
STUB
chmod +x "$tmp/bin/gh"

LOG="$tmp/log"
OUT="$tmp/out"

# run TAG… -> echoes the exit code; argv lands in $LOG, output in $OUT.
run() {
    : >"$LOG"
    _rc=0
    PATH="$tmp/bin:$PATH" STUB_LOG="$LOG" STUB_GH_RC="${STUB_GH_RC:-0}" \
        TARGET_REPO="evanharmon1/harmon-init" \
        "$helper" "$@" >"$OUT" 2>&1 || _rc=$?
    echo "$_rc"
}

start() {
    cases=$((cases + 1))
    echo "==> $1"
}

start "a stable tag dispatches exactly the event the receiver listens for"
STUB_GH_RC=0
[ "$(run v0.9.0)" = 0 ] || fail "a stable tag was rejected: $(cat "$OUT")"
grep -qF 'api repos/evanharmon1/harmon-init/dispatches' "$LOG" ||
    fail "the dispatch did not target harmon-init: $(cat "$LOG")"
grep -qF 'event_type=harmon-devkit-released' "$LOG" ||
    fail "wrong event type — the receiver would never fire: $(cat "$LOG")"
grep -qF 'client_payload[tag]=v0.9.0' "$LOG" ||
    fail "the tag was not in the payload: $(cat "$LOG")"

start "malformed and metacharacter-bearing tags never reach gh"
for bad in "v1.2" "1.2.3" "v1.2.3.4" "v1.2.3-rc.1" "v1.2.3; rm -rf /" \
    'v1.2.3 && touch pwned' "v1.2.3$(printf '\n')v0.9.0" "v" "v1..3" "v1.2." ""; do
    [ "$(run "$bad")" != 0 ] || fail "tag '$bad' was accepted"
    [ ! -s "$LOG" ] || fail "tag '$bad' still invoked gh: $(cat "$LOG")"
done
[ ! -e "$repo/pwned" ] || fail "a metacharacter payload reached a shell"
[ ! -e "pwned" ] || fail "a metacharacter payload reached a shell (cwd)"

start "a failed dispatch fails the release step, loudly and actionably"
STUB_GH_RC=1
[ "$(run v0.9.0)" != 0 ] || fail "a failed dispatch was swallowed"
grep -q "dispatch to evanharmon1/harmon-init failed" "$OUT" ||
    fail "the failure was not reported: $(cat "$OUT")"
grep -q "reconciliation" "$OUT" || fail "the failure does not explain the fallback path"
grep -qF "gh api repos/evanharmon1/harmon-init/dispatches" "$OUT" ||
    fail "the failure does not give a copy-pasteable manual re-send"
STUB_GH_RC=0

start "no tag is a usage error"
[ "$(run)" != 0 ] || fail "a missing tag was accepted"
[ ! -s "$LOG" ] || fail "a missing tag still invoked gh"

echo "notify-devkit-release: all ${cases} cases passed"
