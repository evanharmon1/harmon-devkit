#!/usr/bin/env bash
# claude-wrapper.sh — installed as /usr/local/bin/claude.
#
# Records Fable 5's usage-credit consent (opt-in) and then execs the real CLI.
#
# Why a PATH wrapper rather than a shell function: a function is only visible
# to the shell that defined it. agent-deck is this image's primary launcher
# (`default_tool = "claude"`, conductor enabled, the `adl` alias) and it spawns
# Claude OUT OF PROCESS, so a function never applies to it. /usr/local/bin
# precedes /usr/bin — where npm installs the real binary — in the default PATH
# for daemons and interactive shells alike, so this is seen by every launcher.
#
# Why seeding has to happen HERE and not inside Claude: the CLI caches
# ~/.claude.json in memory at startup and never re-reads it, so a write from
# within a session cannot reach that session, and the CLI's next config write
# serializes its stale copy back over the file. Immediately before exec is the
# one moment that is after a previous session wrote .oauthAccount and before
# the next CLI reads its config, with no session live to overwrite it.
#
# This shadows `claude` for EVERY process in the container, including opted-out
# ones, so it is written to be as close to a pass-through as possible: resolve,
# maybe seed, exec. It never exits non-zero on its own account — a bug here
# would break Claude Code itself, which is a far worse failure than Fable being
# unavailable.

set -uo pipefail

SEEDER=/etc/claude-code/hooks/seed-fable-consent.sh

# Recursion guard. Resolution below skips THIS file, but two distinct copies of
# the wrapper on PATH would each resolve to the other and exec forever. The
# marker survives exec, so the second entry stops instead of looping. The real
# CLI inherits an unknown variable, which is harmless.
if [ -n "${_CLAUDE_FABLE_WRAPPER_ACTIVE:-}" ]; then
    echo "claude: wrapper recursion detected — more than one copy on PATH" >&2
    exit 127
fi
export _CLAUDE_FABLE_WRAPPER_ACTIVE=1

# Resolve the real CLI: the first `claude` on PATH that is not this wrapper.
# Comparing resolved paths rather than hardcoding /usr/bin/claude means an npm
# prefix change cannot turn this into an infinite exec loop — it would simply
# find the binary at its new location, or fail loudly below.
self="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
real=""
IFS=':' read -r -a _dirs <<<"$PATH"
for _d in "${_dirs[@]}"; do
    [ -n "$_d" ] || continue
    _cand="$_d/claude"
    [ -x "$_cand" ] || continue
    _resolved="$(readlink -f "$_cand" 2>/dev/null || printf '%s' "$_cand")"
    [ "$_resolved" = "$self" ] && continue
    real="$_cand"
    break
done

if [ -z "$real" ]; then
    echo "claude: could not locate the real Claude Code binary on PATH" >&2
    echo "claude: (this wrapper is $self — see config/claude-hooks/claude-wrapper.sh)" >&2
    exit 127
fi

if [ "${DEVCONTAINER_FABLE_CONSENT:-}" = "true" ] && [ -x "$SEEDER" ]; then
    "$SEEDER" || true
fi

exec "$real" "$@"
