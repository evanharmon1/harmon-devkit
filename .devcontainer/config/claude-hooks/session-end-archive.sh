#!/usr/bin/env bash
# Claude Code SessionEnd hook: archive the session transcript before Claude
# Code's cleanupPeriodDays retention (default 30 days) deletes it.
#
# Reads the hook JSON on stdin ({session_id, transcript_path, cwd, ...}) and
# gzips the transcript into CLAUDE_TRANSCRIPT_ARCHIVE_DIR (default
# ~/.claude/transcript-archive). Idempotent per session. Every failure path
# exits 0 — a SessionEnd hook must never make session exit noisy.
set -euo pipefail

# Best-effort by design: swallow both failure statuses and their diagnostics
# (a full disk or unwritable archive dir must not noisy up session exit).
trap 'exit 0' ERR
exec 2>/dev/null

command -v jq >/dev/null || exit 0
command -v gzip >/dev/null || exit 0

input="$(cat)"
session_id="$(jq -r '.session_id // empty' <<<"$input")"
transcript="$(jq -r '.transcript_path // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"
[[ -n "$session_id" && -n "$transcript" && -f "$transcript" ]] || exit 0

archive_dir="${CLAUDE_TRANSCRIPT_ARCHIVE_DIR:-$HOME/.claude/transcript-archive}"
mkdir -p "$archive_dir"

# Serialize per session so overlapping hook runs (rapid exit/resume/exit)
# cannot clobber each other. Locks are PID-named directories
# (.lock-<sid>.<pid>): the owner's identity is pinned in the name itself,
# so removing a dead owner's lock can never remove a lock a live process
# holds — there is no inspect-then-delete race. Between live contenders the
# lowest PID wins; the loser backs off and retries. Wait up to 60s (the
# hook runs async with a 120s timeout, so nothing user-facing blocks)
# rather than dropping the run — this invocation may be the last chance to
# archive, e.g. when the transcript grew after a slow contender's gzip
# already read it. An hour-old lock expires as the recycled-PID backstop.
# Retry count/interval are overridable so the offline regression test can
# exercise contention without real 60s waits.
lock_retries="${SESSION_END_ARCHIVE_LOCK_RETRIES:-60}"
lock_sleep="${SESSION_END_ARCHIVE_LOCK_SLEEP:-1}"
# Election: create my PID-named lock, then defer to any live lock that has
# already won (an `acquired` marker) or is still electing with a lower PID.
# Winning is two-phase — mark acquired, wait a grace tick, re-scan — so two
# simultaneous electors both mark, then the higher PID sees the marked
# lower PID and withdraws. Late arrivals see the winner's marker and defer
# regardless of PID order.
mylock="$archive_dir/.lock-${session_id}.$$"
acquired=""
for ((attempt = 0; attempt < lock_retries; attempt++)); do
    if ! mkdir "$mylock"; then
        # A leftover lock bearing our own (recycled) PID: no live process
        # but us can own this name, so reap it and retry the create.
        rm -rf "$mylock" || true
        mkdir "$mylock" || exit 0
    fi
    defer=""
    for other in "$archive_dir/.lock-${session_id}."*; do
        [[ -d "$other" && "$other" != "$mylock" ]] || continue
        opid="${other##*.}"
        if ! kill -0 "$opid" 2>/dev/null; then
            rm -rf "$other" || true # dead owner — name pins identity, safe
        elif [[ -n "$(find "$other" -maxdepth 0 -mmin +60)" ]]; then
            rm -rf "$other" || true # recycled-PID backstop
        elif [[ -e "$other/acquired" || "$opid" -lt $$ ]]; then
            defer=1 # a winner, or a live lower-PID elector
        fi
    done
    if [[ -z "$defer" ]]; then
        : >"$mylock/acquired"
        sleep "$lock_sleep"
        for other in "$archive_dir/.lock-${session_id}."*; do
            [[ -d "$other" && "$other" != "$mylock" ]] || continue
            opid="${other##*.}"
            if [[ -e "$other/acquired" && "$opid" -lt $$ ]] &&
                kill -0 "$opid" 2>/dev/null; then
                defer=1 # simultaneous mark — lowest PID wins the tie
            fi
        done
        if [[ -z "$defer" ]]; then
            acquired=1
            break
        fi
    fi
    rm -rf "$mylock" || true
    sleep "$lock_sleep"
    mylock="$archive_dir/.lock-${session_id}.$$" # recreate next round
done
[[ -n "$acquired" ]] || {
    rm -rf "$mylock"
    exit 0
}
trap 'rm -rf "$mylock"' EXIT

# A session can end more than once (exit, resume, exit again) under the same
# session_id, growing the transcript each time. Reuse the existing archive
# path and re-archive when the transcript changed; skip only when the
# existing archive is already up to date. mtime alone can miss growth on
# coarse-timestamp filesystems or after a clock rollback, so also compare
# the source size against the archive's stored uncompressed size.
existing="$(find "$archive_dir" -maxdepth 1 -name "*-${session_id}.jsonl.gz" | head -1)"
if [[ -n "$existing" && ! "$transcript" -nt "$existing" ]]; then
    src_size="$(wc -c <"$transcript" | tr -d ' ')"
    arch_size="$(gzip -l "$existing" | awk 'NR==2{print $2}')"
    [[ "$src_size" != "$arch_size" ]] || exit 0
fi

# Use Claude's own project slug (the transcript's parent directory name,
# which encodes the full project path) so restoration is unambiguous even
# across same-named checkouts; fall back to the cwd basename. Sanitize for
# filename use either way.
slug="$(basename "$(dirname "$transcript")")"
[[ -n "$slug" && "$slug" != "/" && "$slug" != "." ]] || slug="$(basename "${cwd:-unknown}")"
slug="${slug//[^[:alnum:]._-]/-}"
[[ -n "${slug//-/}" ]] || slug="unknown"

dest="${existing:-$archive_dir/$(date +%Y%m%d-%H%M%S)-${slug}-${session_id}.jsonl.gz}"

# Write via a temp file in the same directory so the final mv is atomic and
# a half-written archive never matches the idempotency glob.
tmp="$(mktemp "$archive_dir/.archive.XXXXXX")"
stamp="$(mktemp "$archive_dir/.stamp.XXXXXX")"
trap 'rm -f "$tmp" "$stamp"; rm -rf "$mylock"' EXIT

# Snapshot the transcript's pre-compression mtime on a separate stamp file
# (never the lock — its mtime must keep representing lock age) and copy it
# onto the finished archive: if the transcript grows while gzip runs, it
# ends up newer than the archive and the next hook run re-archives it.
touch -r "$transcript" "$stamp"
gzip -c "$transcript" >"$tmp"
mv "$tmp" "$dest"
touch -r "$stamp" "$dest"
