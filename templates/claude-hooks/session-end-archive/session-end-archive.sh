#!/usr/bin/env bash
# Claude Code SessionEnd hook: archive the session transcript before Claude
# Code's cleanupPeriodDays retention (default 30 days) deletes it.
#
# Reads the hook JSON on stdin ({session_id, transcript_path, cwd, ...}) and
# gzips the transcript into CLAUDE_TRANSCRIPT_ARCHIVE_DIR (default
# ~/.claude/transcript-archive). Idempotent per session. Every failure path
# exits 0 — a SessionEnd hook must never make session exit noisy.
set -euo pipefail

trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
command -v gzip >/dev/null 2>&1 || exit 0

input="$(cat)"
session_id="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
[[ -n "$session_id" && -n "$transcript" && -f "$transcript" ]] || exit 0

archive_dir="${CLAUDE_TRANSCRIPT_ARCHIVE_DIR:-$HOME/.claude/transcript-archive}"
mkdir -p "$archive_dir"

# Idempotent per session: an existing archive of this session_id wins.
if compgen -G "$archive_dir/*-${session_id}.jsonl.gz" >/dev/null; then
    exit 0
fi

slug="$(basename "${cwd:-unknown}")"
dest="$archive_dir/$(date +%Y%m%d-%H%M%S)-${slug}-${session_id}.jsonl.gz"

# Write via a temp file in the same directory so the final mv is atomic and
# a half-written archive never matches the idempotency glob.
tmp="$(mktemp "$archive_dir/.archive.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
gzip -c "$transcript" >"$tmp"
mv "$tmp" "$dest"
