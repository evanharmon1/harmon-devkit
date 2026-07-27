# SessionEnd transcript archive hook

A Claude Code [`SessionEnd` hook](https://code.claude.com/docs/en/hooks) that
gzips every session transcript into an archive directory when the session
exits. Claude Code deletes transcripts after `cleanupPeriodDays` (default
**30 days**); this hook preserves them indefinitely.

**Not wired in this repo** — it is a copy-paste asset. Wiring belongs in your
personal settings (e.g. managed by dotfiles), because sessions and transcripts
are per-machine, not per-repo.

## What it does

Claude Code invokes the hook on session exit with JSON on stdin:

```json
{
  "session_id": "…",
  "transcript_path": "~/.claude/projects/<project-slug>/<session-id>.jsonl",
  "cwd": "/path/to/project",
  "reason": "…"
}
```

The script gzips the transcript to:

```text
${CLAUDE_TRANSCRIPT_ARCHIVE_DIR:-~/.claude/transcript-archive}/<timestamp>-<project-slug>-<session-id>.jsonl.gz
```

Design properties:

- **Never blocks or noisies session exit** — every failure path (missing
  `jq`/`gzip`, absent transcript, unwritable archive dir) exits 0.
- **Resume-safe** — a session can end more than once (exit → resume → exit)
  under the same `session_id`, growing the transcript each time; the hook
  re-archives into the same file whenever the transcript is newer than the
  existing archive, and is a no-op otherwise.
- **Atomic and serialized** — writes through a temp file in the archive dir,
  so a half-written archive never satisfies the freshness check, and a
  per-session lock keeps overlapping hook runs from clobbering each other.
  Locks are PID-named, so reclaiming a crashed owner's lock can never touch
  a live one (the name pins ownership); between live contenders the lowest
  PID wins, and an hour-based expiry backstops recycled PIDs.
- Dependencies: `jq`, `gzip`.

## Install

1. Copy the script somewhere stable and make it executable:

   ```sh
   mkdir -p ~/.claude/hooks
   cp session-end-archive.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/session-end-archive.sh
   ```

2. Merge [`settings-snippet.json`](./settings-snippet.json) into
   `~/.claude/settings.json` (hooks from different settings files are
   additive, so this coexists with existing SessionEnd hooks).

3. Optional: override the archive location by exporting
   `CLAUDE_TRANSCRIPT_ARCHIVE_DIR`.

## Test it

```sh
printf '{"session_id":"t1","transcript_path":"%s","cwd":"%s"}' \
    "$(ls ~/.claude/projects/*/*.jsonl | head -1)" "$PWD" |
    CLAUDE_TRANSCRIPT_ARCHIVE_DIR=/tmp/transcript-archive-test ./session-end-archive.sh
ls /tmp/transcript-archive-test
```

Run it twice — the second run should be a no-op. Piping `{}` (no
`transcript_path`) should exit 0 silently.

## Restore

Transcripts are plain JSONL; to make an archived session resumable again,
restore it to its original name under the project's transcript dir. Go
through a temp file and `mv -n` so a mistyped or corrupt archive can never
truncate a live transcript — if the destination already exists, the restore
is refused:

```sh
dest_dir=~/.claude/projects/<project-slug>
tmp="$(mktemp "$dest_dir/.restore.XXXXXX")"   # same filesystem => atomic mv
gunzip -c <timestamp>-<slug>-<session-id>.jsonl.gz > "$tmp" &&
    mv -n "$tmp" "$dest_dir/<session-id>.jsonl"
rm -f "$tmp"   # no-op if the mv happened; cleans up if it was refused
```

The JSONL format is internal to Claude Code and changes between versions —
old transcripts may not resume cleanly across major upgrades, but they remain
readable.
