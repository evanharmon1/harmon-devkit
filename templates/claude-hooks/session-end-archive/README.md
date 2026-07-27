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
- **Idempotent per session** — if an archive for the `session_id` already
  exists, the hook is a no-op (a session can end more than once via resume).
- **Atomic** — writes through a temp file in the archive dir, so a
  half-written archive never satisfies the idempotency check.
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
gunzip it back to its original name under the project's transcript dir:

```sh
gunzip -c <timestamp>-<slug>-<session-id>.jsonl.gz \
    > ~/.claude/projects/<project-slug>/<session-id>.jsonl
```

The JSONL format is internal to Claude Code and changes between versions —
old transcripts may not resume cleanly across major upgrades, but they remain
readable.
