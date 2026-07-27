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
# cannot clobber each other. Retry briefly rather than dropping the run —
# this invocation may be the last chance to archive. A lock left by a
# crashed run expires after an hour.
lock="$archive_dir/.lock-${session_id}"
acquired=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$lock"; then
        acquired=1
        break
    fi
    # The owner may release the lock between mkdir and find — a vanished
    # lock is a normal retry condition, not an error.
    find "$lock" -maxdepth 0 -mmin +60 -exec rmdir {} \; || true
    sleep 1
done
[[ -n "$acquired" ]] || exit 0
trap 'rmdir "$lock"' EXIT

# A session can end more than once (exit, resume, exit again) under the same
# session_id, growing the transcript each time. Reuse the existing archive
# path and re-archive when the transcript is newer; skip only when the
# existing archive is already up to date.
existing="$(find "$archive_dir" -maxdepth 1 -name "*-${session_id}.jsonl.gz" | head -1)"
if [[ -n "$existing" && ! "$transcript" -nt "$existing" ]]; then
    exit 0
fi

# Sanitize the project slug for use in a filename (cwd may be "/" or contain
# characters that would create unintended paths).
slug="$(basename "${cwd:-unknown}")"
slug="${slug//[^[:alnum:]._-]/-}"
[[ -n "${slug//-/}" ]] || slug="unknown"

dest="${existing:-$archive_dir/$(date +%Y%m%d-%H%M%S)-${slug}-${session_id}.jsonl.gz}"

# Write via a temp file in the same directory so the final mv is atomic and
# a half-written archive never matches the idempotency glob.
tmp="$(mktemp "$archive_dir/.archive.XXXXXX")"
stamp="$(mktemp "$archive_dir/.stamp.XXXXXX")"
trap 'rm -f "$tmp" "$stamp"; rmdir "$lock"' EXIT

# Snapshot the transcript's pre-compression mtime on a separate stamp file
# (never the lock — its mtime must keep representing lock age) and copy it
# onto the finished archive: if the transcript grows while gzip runs, it
# ends up newer than the archive and the next hook run re-archives it.
touch -r "$transcript" "$stamp"
gzip -c "$transcript" >"$tmp"
mv "$tmp" "$dest"
touch -r "$stamp" "$dest"
