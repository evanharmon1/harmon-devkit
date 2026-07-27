#!/usr/bin/env bash
# test-archive-hook.sh — offline regression tests for the SessionEnd
# transcript-archive hook template
# (templates/claude-hooks/session-end-archive/session-end-archive.sh).
# The hook deliberately converts every runtime failure into silent exit 0,
# so `task verify` would stay green if its behavior regressed — these tests
# pin the behavior explicitly. Run via `task test:archive-hook`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

HOOK="$repo/templates/claude-hooks/session-end-archive/session-end-archive.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Fast lock knobs for every invocation (contention tests must not wait 60s).
run_hook() {
    SESSION_END_ARCHIVE_LOCK_RETRIES=2 SESSION_END_ARCHIVE_LOCK_SLEEP=0 \
        CLAUDE_TRANSCRIPT_ARCHIVE_DIR="$work/archive" "$HOOK"
}

payload() { # payload <session_id> <transcript_path>
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$1" "$2" "$work"
}

# A transcript inside a Claude-style project dir so the slug derives from it.
projdir="$work/projects/-Users-dev-git-demo"
mkdir -p "$projdir"
transcript="$projdir/sess1.jsonl"
printf '{"a":1}\n{"b":2}\n' >"$transcript"

echo "==> happy path archives, names by project slug + session id, is silent"
out="$(payload sess1 "$transcript" | run_hook 2>&1)" || fail "hook exited nonzero"
[ -z "$out" ] || fail "hook produced output: $out"
archive="$(find "$work/archive" -name '*--Users-dev-git-demo-sess1.jsonl.gz' | head -1)"
[ -n "$archive" ] || fail "no archive produced (found: $(ls "$work/archive"))"
gunzip -c "$archive" | cmp -s - "$transcript" || fail "archive content differs from transcript"

echo "==> unchanged transcript is a no-op (single archive file remains)"
payload sess1 "$transcript" | run_hook || fail "no-op run exited nonzero"
count="$(find "$work/archive" -name '*.jsonl.gz' | wc -l | tr -d ' ')"
[ "$count" = "1" ] || fail "expected 1 archive, found $count"

echo "==> growth with an identical mtime still re-archives (size check)"
printf '{"c":3}\n' >>"$transcript"
touch -r "$archive" "$transcript" # defeat the mtime comparison on purpose
payload sess1 "$transcript" | run_hook || fail "re-archive run exited nonzero"
gunzip -c "$archive" | cmp -s - "$transcript" || fail "grown transcript was not re-archived"

echo "==> missing transcript, empty JSON, and invalid JSON all exit 0 silently"
for bad in '{"session_id":"x","transcript_path":"/nonexistent"}' '{}' 'not json'; do
    out="$(printf '%s' "$bad" | run_hook 2>&1)" || fail "hook exited nonzero on: $bad"
    [ -z "$out" ] || fail "hook was noisy on: $bad ($out)"
done

echo "==> unwritable archive dir exits 0 silently"
mkdir -p "$work/ro"
chmod 555 "$work/ro"
out="$(payload sess1 "$transcript" | SESSION_END_ARCHIVE_LOCK_RETRIES=2 \
    SESSION_END_ARCHIVE_LOCK_SLEEP=0 \
    CLAUDE_TRANSCRIPT_ARCHIVE_DIR="$work/ro/sub" "$HOOK" 2>&1)" ||
    fail "hook exited nonzero on unwritable dir"
[ -z "$out" ] || fail "hook was noisy on unwritable dir: $out"
chmod 755 "$work/ro"

echo "==> dead-owner lock is stolen and the run archives"
mkdir -p "$work/archive/.lock-sess1.999999"
printf '{"d":4}\n' >>"$transcript"
payload sess1 "$transcript" | run_hook || fail "dead-owner run exited nonzero"
gunzip -c "$archive" | cmp -s - "$transcript" || fail "dead-owner lock was not stolen"
[ ! -d "$work/archive/.lock-sess1.999999" ] || fail "dead-owner lock left behind"

echo "==> live same-user lower-PID contender is respected (skip, lock intact)"
sleep 30 &
spid=$!
mkdir -p "$work/archive/.lock-sess1.$spid"
printf '{"e":5}\n' >>"$transcript"
payload sess1 "$transcript" | run_hook || fail "contended run exited nonzero"
gunzip -c "$archive" | cmp -s - "$transcript" &&
    fail "contended run archived despite a live lower-PID lock"
[ -d "$work/archive/.lock-sess1.$spid" ] || fail "live contender's lock was removed"
kill "$spid" 2>/dev/null || true
rm -rf "$work/archive/.lock-sess1.$spid"

echo "==> no lock/stamp/temp litter remains after a normal run"
payload sess1 "$transcript" | run_hook || fail "final run exited nonzero"
litter="$(find "$work/archive" -name '.lock-*' -o -name '.stamp.*' -o -name '.archive.*' | wc -l | tr -d ' ')"
[ "$litter" = "0" ] || fail "leftover lock/stamp/temp files: $litter"

echo "==> archive-hook tests OK"
