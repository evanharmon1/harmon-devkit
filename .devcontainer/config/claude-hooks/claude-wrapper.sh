#!/usr/bin/env bash
# CLAUDE_FABLE_WRAPPER_ID — load-bearing marker, do not remove or reword.
# It is how this script recognises another copy of itself on PATH (see below).
#
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
# Known gap, deliberately not papered over: an executable ~/.local/bin/claude
# would win, because shell startup prepends that directory. Nothing installs
# one here, and no wrapper can defend against a binary placed ahead of it.
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
# maybe seed, exec. A bug here would break Claude Code itself, which is a far
# worse failure than Fable being unavailable.

set -uo pipefail

SEEDER=/etc/claude-code/hooks/seed-fable-consent.sh
WRAPPER_MARKER=CLAUDE_FABLE_WRAPPER_ID

# Resolve the real CLI: the first `claude` on PATH that is neither this file
# nor another copy of this wrapper.
#
# Copies are detected by CONTENT, not by an exported marker variable. An
# exported marker survives exec into the real CLI and every process it starts,
# so a nested `claude` — which Claude Code launches routinely for subagents and
# -p runs — would inherit it and abort.
#
# The scan uses only shell builtins. An earlier version piped `head` into
# `grep`, which fails OPEN when PATH lacks either: detection silently stops
# working and two copies exec each other forever. A wrapper whose whole job is
# to sit in front of every launch must not depend on the caller's PATH being
# sane. Builtins also make this free — no process per candidate.
#
# The marker check subsumes a self-check: this file carries the marker, so it
# skips itself, any copy, and any symlink to either, without resolving paths.
real=""
IFS=':' read -r -a _dirs <<<"$PATH"
for _d in "${_dirs[@]}"; do
    [ -n "$_d" ] || continue
    _cand="$_d/claude"
    [ -x "$_cand" ] || continue

    # Only a text script can be a copy of this wrapper. Bound the probe so a
    # binary with no early newline cannot pull megabytes into a variable.
    _probe=""
    IFS= read -r -n 200 _probe <"$_cand" 2>/dev/null || true
    case "$_probe" in
    "#!"*) ;;
    *)
        real="$_cand"
        break
        ;;
    esac

    _is_copy=0
    _n=0
    while IFS= read -r _l; do
        case "$_l" in *"$WRAPPER_MARKER"*)
            _is_copy=1
            break
            ;;
        esac
        _n=$((_n + 1))
        [ "$_n" -ge 40 ] && break
    done <"$_cand"
    [ "$_is_copy" = 1 ] && continue

    real="$_cand"
    break
done

if [ -z "$real" ]; then
    echo "claude: could not locate the real Claude Code binary on PATH" >&2
    echo "claude: (this wrapper is $0 — see config/claude-hooks/claude-wrapper.sh)" >&2
    exit 127
fi

if [ "${DEVCONTAINER_FABLE_CONSENT:-}" = "true" ] && [ -x "$SEEDER" ]; then
    "$SEEDER" || true
fi

exec "$real" "$@"
