#!/usr/bin/env bash
# Offline behavioral tests for the portable claim identity resolver.
set -euo pipefail
cd "$(dirname "$0")/.."

resolver="ai/skills/universal/claim/assets/resolve-claim-label.sh"
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
available="$tmp/available"
issue="$tmp/issue"
printf '%s\n' claim:claude claim:gpt agent:claude-code agent:codex >"$available"

run() {
    "$resolver" --registry agent-registry.json --available-labels "$available" --issue-labels "$issue" "$@"
}

printf '%s\n' >"$issue"
out="$(run --harness claude-code)" || fail "Claude resolution failed"
printf '%s\n' "$out" | grep -Fx 'family=claude' >/dev/null || fail "Claude family was not selected"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:claude' >/dev/null || fail "Claude claim label was not selected"

out="$(run --harness codex-cli)" || fail "Codex resolution failed"
printf '%s\n' "$out" | grep -Fx 'family=gpt' >/dev/null || fail "Codex must resolve to GPT"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt' >/dev/null || fail "Codex must select claim:gpt"

printf '%s\n' claim:gpt:terra >"$issue"
out="$(run --harness codex-cli)" || fail "same-family model claim must be idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=claim:gpt:terra' >/dev/null || fail "same-family claim was not recognized"

printf '%s\n' claim:claude >"$issue"
if run --harness codex-cli >"$tmp/out" 2>&1; then fail "different-family claim must block"; else status=$?; fi
[ "$status" = 10 ] || fail "different-family claim exited $status, want 10"
grep -Fx 'conflict_label=claim:claude' "$tmp/out" >/dev/null || fail "conflict label was not reported"

printf '%s\n' >"$issue"
if run --harness claude-code --runtime-family gpt >/dev/null 2>&1; then fail "fixed harness mismatch must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "fixed harness mismatch exited $status, want 20"

if run --harness opencode >/dev/null 2>&1; then fail "broker without runtime family must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "broker ambiguity exited $status, want 20"
out="$(run --harness opencode --runtime-family gpt)" || fail "broker with trusted runtime family failed"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt' >/dev/null || fail "broker selected wrong target"

printf '%s\n' agent:codex >"$issue"
out="$(run --harness codex-cli)" || fail "registry-declared Codex legacy marker must be idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=agent:codex' >/dev/null || fail "Codex legacy marker was not recognized"

printf '%s\n' agent:claude-code >"$issue"
if run --harness codex-cli >/dev/null 2>&1; then fail "foreign legacy marker must block"; else status=$?; fi
[ "$status" = 10 ] || fail "foreign legacy marker exited $status, want 10"

printf '%s\n' agent:codex >"$tmp/legacy-available"
printf '%s\n' >"$issue"
out="$("$resolver" --registry agent-registry.json --harness codex-cli --available-labels "$tmp/legacy-available" --issue-labels "$issue")" || fail "registry-declared legacy fallback failed"
printf '%s\n' "$out" | grep -Fx 'target_label=agent:codex' >/dev/null || fail "legacy fallback selected the wrong label"

echo 'PASS: portable claim family resolution'
